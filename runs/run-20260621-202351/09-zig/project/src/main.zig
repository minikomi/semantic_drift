const std = @import("std");

const Allocator = std.mem.Allocator;

const AppError = anyerror;

const Type = enum { undefined, null, bool, number, string, array, object };

const Field = struct {
    key: []const u8,
    value: *Jv,
};

const Jv = struct {
    typ: Type,
    b: bool = false,
    n: f64 = 0,
    s: []const u8 = "",
    arr: std.array_list.Managed(*Jv) = undefined,
    obj: std.array_list.Managed(Field) = undefined,
};

const Summary = struct {
    user_id: *Jv,
    completed: i64 = 0,
    missed: i64 = 0,
};

const Context = struct {
    gpa: Allocator,
    err: ?[]const u8 = null,

    fn fail(self: *Context, comptime fmt: []const u8, args: anytype) AppError {
        self.err = std.fmt.allocPrint(self.gpa, fmt, args) catch "out of memory";
        return error.App;
    }

    fn jv(self: *Context, typ: Type) AppError!*Jv {
        const v = try self.gpa.create(Jv);
        v.* = .{ .typ = typ };
        return v;
    }
};

const Parser = struct {
    ctx: *Context,
    text: []const u8,
    pos: usize = 0,

    fn skipWs(self: *Parser) void {
        while (self.pos < self.text.len) : (self.pos += 1) {
            switch (self.text[self.pos]) {
                ' ', '\n', '\r', '\t' => {},
                else => break,
            }
        }
    }

    fn peek(self: *Parser) AppError!u8 {
        if (self.pos >= self.text.len) return self.ctx.fail("unexpected end of input", .{});
        return self.text[self.pos];
    }

    fn consume(self: *Parser, c: u8) bool {
        if (self.pos < self.text.len and self.text[self.pos] == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, c: u8) AppError!void {
        if (!self.consume(c)) return self.ctx.fail("expected '{c}'", .{c});
    }

    fn literal(self: *Parser, word: []const u8) AppError!void {
        if (self.pos + word.len <= self.text.len and std.mem.eql(u8, self.text[self.pos .. self.pos + word.len], word)) {
            self.pos += word.len;
        } else return self.ctx.fail("unexpected token", .{});
    }

    fn hexValue(c: u8) ?u21 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => 10 + c - 'a',
            'A'...'F' => 10 + c - 'A',
            else => null,
        };
    }

    fn parseHex4(self: *Parser) AppError!u21 {
        if (self.pos + 4 > self.text.len) return self.ctx.fail("invalid unicode escape", .{});
        var acc: u21 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const hv = hexValue(self.text[self.pos]) orelse return self.ctx.fail("invalid unicode escape", .{});
            acc = (acc << 4) + hv;
            self.pos += 1;
        }
        return acc;
    }

    fn appendCodepoint(out: *std.array_list.Managed(u8), cp: u21) AppError!void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidUtf8;
        try out.appendSlice(buf[0..len]);
    }

    fn parseString(self: *Parser) AppError![]const u8 {
        try self.expect('"');
        var out = std.array_list.Managed(u8).init(self.ctx.gpa);
        while (true) {
            if (self.pos >= self.text.len) return self.ctx.fail("unterminated string", .{});
            const c = self.text[self.pos];
            self.pos += 1;
            if (c == '"') break;
            if (c < 0x20) return self.ctx.fail("control character in string", .{});
            if (c == '\\') {
                if (self.pos >= self.text.len) return self.ctx.fail("invalid escape", .{});
                const esc = self.text[self.pos];
                self.pos += 1;
                switch (esc) {
                    '"' => try out.append('"'),
                    '\\' => try out.append('\\'),
                    '/' => try out.append('/'),
                    'b' => try out.append(8),
                    'f' => try out.append(12),
                    'n' => try out.append('\n'),
                    'r' => try out.append('\r'),
                    't' => try out.append('\t'),
                    'u' => {
                        var cp = try self.parseHex4();
                        if (cp >= 0xD800 and cp <= 0xDBFF) {
                            if (self.pos + 6 > self.text.len or self.text[self.pos] != '\\' or self.text[self.pos + 1] != 'u') {
                                return self.ctx.fail("invalid unicode surrogate", .{});
                            }
                            self.pos += 2;
                            const low = try self.parseHex4();
                            if (low < 0xDC00 or low > 0xDFFF) return self.ctx.fail("invalid unicode surrogate", .{});
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                        }
                        try appendCodepoint(&out, cp);
                    },
                    else => return self.ctx.fail("invalid escape", .{}),
                }
            } else {
                try out.append(c);
            }
        }
        return out.toOwnedSlice();
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn consumeDigits(self: *Parser) void {
        while (self.pos < self.text.len and isDigit(self.text[self.pos])) self.pos += 1;
    }

    fn parseNumber(self: *Parser) AppError!*Jv {
        const begin = self.pos;
        if (self.pos < self.text.len and (self.text[self.pos] == '+' or self.text[self.pos] == '-')) self.pos += 1;
        self.consumeDigits();
        if (self.pos < self.text.len and self.text[self.pos] == '.') {
            self.pos += 1;
            self.consumeDigits();
        }
        if (self.pos < self.text.len and (self.text[self.pos] == 'e' or self.text[self.pos] == 'E')) {
            const save = self.pos;
            self.pos += 1;
            if (self.pos < self.text.len and (self.text[self.pos] == '+' or self.text[self.pos] == '-')) self.pos += 1;
            const exp_begin = self.pos;
            self.consumeDigits();
            if (exp_begin == self.pos) self.pos = save;
        }
        const end = self.pos;
        if (begin == end or (end == begin + 1 and (self.text[begin] == '+' or self.text[begin] == '-'))) {
            return self.ctx.fail("unexpected token", .{});
        }
        const n = std.fmt.parseFloat(f64, self.text[begin..end]) catch return self.ctx.fail("unexpected token", .{});
        const v = try self.ctx.jv(.number);
        v.n = n;
        return v;
    }

    fn addOrReplace(self: *Parser, obj: *std.array_list.Managed(Field), key: []const u8, value: *Jv) AppError!void {
        for (obj.items) |*field| {
            if (std.mem.eql(u8, field.key, key)) {
                field.value = value;
                return;
            }
        }
        try obj.append(.{ .key = key, .value = value });
        _ = self;
    }

    fn parseArray(self: *Parser) AppError!*Jv {
        try self.expect('[');
        self.skipWs();
        const v = try self.ctx.jv(.array);
        v.arr = std.array_list.Managed(*Jv).init(self.ctx.gpa);
        if (self.consume(']')) return v;
        while (true) {
            try v.arr.append(try self.parseValue());
            self.skipWs();
            if (self.consume(']')) return v;
            try self.expect(',');
        }
    }

    fn parseObject(self: *Parser) AppError!*Jv {
        try self.expect('{');
        self.skipWs();
        const v = try self.ctx.jv(.object);
        v.obj = std.array_list.Managed(Field).init(self.ctx.gpa);
        if (self.consume('}')) return v;
        while (true) {
            self.skipWs();
            const key = try self.parseString();
            self.skipWs();
            try self.expect(':');
            const val = try self.parseValue();
            try self.addOrReplace(&v.obj, key, val);
            self.skipWs();
            if (self.consume('}')) return v;
            try self.expect(',');
        }
    }

    fn parseValue(self: *Parser) AppError!*Jv {
        self.skipWs();
        switch (try self.peek()) {
            'n' => {
                try self.literal("null");
                return self.ctx.jv(.null);
            },
            't' => {
                try self.literal("true");
                const v = try self.ctx.jv(.bool);
                v.b = true;
                return v;
            },
            'f' => {
                try self.literal("false");
                const v = try self.ctx.jv(.bool);
                v.b = false;
                return v;
            },
            '"' => {
                const v = try self.ctx.jv(.string);
                v.s = try self.parseString();
                return v;
            },
            '[' => return self.parseArray(),
            '{' => return self.parseObject(),
            else => return self.parseNumber(),
        }
    }
};

fn parseJson(ctx: *Context, s: []const u8) AppError!*Jv {
    var p = Parser{ .ctx = ctx, .text = s };
    const v = try p.parseValue();
    p.skipWs();
    if (p.pos != s.len) return ctx.fail("unexpected token at '{c}'", .{s[p.pos]});
    return v;
}

fn appendJsonString(out: *std.array_list.Managed(u8), s: []const u8) AppError!void {
    try out.append('"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            8 => try out.appendSlice("\\b"),
            12 => try out.appendSlice("\\f"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            0...7, 11, 14...31 => try out.print("\\u{x:0>4}", .{c}),
            else => try out.append(c),
        }
    }
    try out.append('"');
}

fn isInteger(n: f64) bool {
    return !std.math.isNan(n) and !std.math.isInf(n) and @floor(n) == n and n >= -9223372036854775808.0 and n <= 9223372036854775808.0;
}

fn appendNumber(out: *std.array_list.Managed(u8), n: f64) AppError!void {
    if (isInteger(n) and n >= 9223372036854775808.0) {
        try out.appendSlice("9223372036854775807");
    } else if (isInteger(n) and n <= -9223372036854775808.0) {
        try out.appendSlice("-9223372036854775808");
    } else if (isInteger(n)) {
        try out.print("{d}", .{@as(i64, @intFromFloat(n))});
    } else {
        try out.print("{d:.15}", .{n});
        while (out.items.len > 0 and out.items[out.items.len - 1] == '0') _ = out.pop();
        if (out.items.len > 0 and out.items[out.items.len - 1] == '.') _ = out.pop();
    }
}

fn appendPyRepr(out: *std.array_list.Managed(u8), v: *Jv) AppError!void {
    switch (v.typ) {
        .undefined => try out.appendSlice("undefined"),
        .null => try out.appendSlice("None"),
        .bool => try out.appendSlice(if (v.b) "True" else "False"),
        .number => try appendNumber(out, v.n),
        .string => try appendJsonString(out, v.s),
        .array => {
            try out.append('[');
            for (v.arr.items, 0..) |item, i| {
                if (i != 0) try out.appendSlice(", ");
                try appendPyRepr(out, item);
            }
            try out.append(']');
        },
        .object => {
            try out.append('{');
            for (v.obj.items, 0..) |field, i| {
                if (i != 0) try out.appendSlice(", ");
                try appendPyReprString(out, field.key);
                try out.appendSlice(": ");
                try appendPyRepr(out, field.value);
            }
            try out.append('}');
        },
    }
}

fn appendPyReprString(out: *std.array_list.Managed(u8), s: []const u8) AppError!void {
    try appendJsonString(out, s);
}

fn pyRepr(ctx: *Context, v: *Jv) AppError![]const u8 {
    var out = std.array_list.Managed(u8).init(ctx.gpa);
    try appendPyRepr(&out, v);
    return out.toOwnedSlice();
}

fn appendJsonStringify(out: *std.array_list.Managed(u8), v: *Jv) AppError!void {
    switch (v.typ) {
        .undefined => try out.appendSlice("undefined"),
        .null => try out.appendSlice("null"),
        .bool => try out.appendSlice(if (v.b) "true" else "false"),
        .number => try appendNumber(out, v.n),
        .string => try appendJsonString(out, v.s),
        .array => {
            try out.append('[');
            for (v.arr.items, 0..) |item, i| {
                if (i != 0) try out.append(',');
                try appendJsonStringify(out, item);
            }
            try out.append(']');
        },
        .object => {
            try out.append('{');
            for (v.obj.items, 0..) |field, i| {
                if (i != 0) try out.append(',');
                try appendJsonString(out, field.key);
                try out.append(':');
                try appendJsonStringify(out, field.value);
            }
            try out.append('}');
        },
    }
}

fn jsonStringify(ctx: *Context, v: *Jv) AppError![]const u8 {
    var out = std.array_list.Managed(u8).init(ctx.gpa);
    try appendJsonStringify(&out, v);
    return out.toOwnedSlice();
}

fn jsString(ctx: *Context, v: *Jv) AppError![]const u8 {
    return switch (v.typ) {
        .undefined => "undefined",
        .null => "null",
        .bool => if (v.b) "true" else "false",
        .string => v.s,
        .number => blk: {
            var out = std.array_list.Managed(u8).init(ctx.gpa);
            try appendNumber(&out, v.n);
            break :blk try out.toOwnedSlice();
        },
        .array, .object => pyRepr(ctx, v),
    };
}

fn pyStr(ctx: *Context, v: *Jv) AppError![]const u8 {
    return switch (v.typ) {
        .null => "None",
        .bool => if (v.b) "True" else "False",
        .array, .object => pyRepr(ctx, v),
        else => jsString(ctx, v),
    };
}

fn truthy(v: *Jv) bool {
    return switch (v.typ) {
        .undefined => true,
        .null => false,
        .bool => v.b,
        .number => v.n != 0.0,
        .string => v.s.len > 0,
        .array => v.arr.items.len > 0,
        .object => v.obj.items.len > 0,
    };
}

fn undefinedValue() Jv {
    return .{ .typ = .undefined };
}

fn objectGet(v: *Jv, key: []const u8) *Jv {
    if (v.typ != .object) return &global_undefined;
    for (v.obj.items) |field| {
        if (std.mem.eql(u8, field.key, key)) return field.value;
    }
    return &global_undefined;
}

var global_undefined = undefinedValue();

fn leapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (leapYear(year)) 29 else 28,
        else => 0,
    };
}

fn daysFromCivil(y_: i64, m_: i64, d_: i64) i64 {
    var y = y_;
    const m = m_;
    const d = d_;
    y -= if (m <= 2) 1 else 0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = m + @as(i64, if (m > 2) -3 else 9);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn parseDateParts(ctx: *Context, txt: []const u8, stringify: []const u8) AppError!i64 {
    const shape = txt.len == 10 and
        Parser.isDigit(txt[0]) and Parser.isDigit(txt[1]) and Parser.isDigit(txt[2]) and Parser.isDigit(txt[3]) and
        txt[4] == '-' and Parser.isDigit(txt[5]) and Parser.isDigit(txt[6]) and
        txt[7] == '-' and Parser.isDigit(txt[8]) and Parser.isDigit(txt[9]);
    if (!shape) return ctx.fail("parsing time {s} as \"2006-01-02\": cannot parse date", .{stringify});
    const year = try std.fmt.parseInt(i64, txt[0..4], 10);
    const month = try std.fmt.parseInt(i64, txt[5..7], 10);
    const day = try std.fmt.parseInt(i64, txt[8..10], 10);
    if ((year >= 0 and year <= 99) or month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) {
        return ctx.fail("parsing time {s}: day out of range", .{stringify});
    }
    return daysFromCivil(year, month, day);
}

fn parseDateOnly(ctx: *Context, v: *Jv) AppError!i64 {
    const txt = try jsString(ctx, v);
    const str = try jsonStringify(ctx, v);
    return parseDateParts(ctx, txt, str);
}

fn canonicalKey(ctx: *Context, v: *Jv) AppError![]const u8 {
    return jsonStringify(ctx, v);
}

fn adjustSummary(ctx: *Context, summaries: *std.array_list.Managed(Summary), user_id: *Jv, completed_delta: i64, missed_delta: i64) AppError!void {
    const key = try canonicalKey(ctx, user_id);
    for (summaries.items) |*s| {
        const other = try canonicalKey(ctx, s.user_id);
        if (std.mem.eql(u8, key, other)) {
            s.completed += completed_delta;
            s.missed += missed_delta;
            return;
        }
    }
    try summaries.append(.{ .user_id = user_id, .completed = completed_delta, .missed = missed_delta });
}

fn nextCodepoint(bytes: []const u8, idx: *usize) u21 {
    const cp = std.unicode.utf8Decode(bytes[idx.*..]) catch {
        const c = bytes[idx.*];
        idx.* += 1;
        return c;
    };
    idx.* += std.unicode.utf8CodepointSequenceLength(bytes[idx.*]) catch 1;
    return cp;
}

fn compareJavaString(a: []const u8, b: []const u8) i32 {
    var ia: usize = 0;
    var ib: usize = 0;
    while (ia < a.len and ib < b.len) {
        const cpa = nextCodepoint(a, &ia);
        const cpb = nextCodepoint(b, &ib);
        if (cpa <= 0xFFFF and cpb <= 0xFFFF) {
            if (cpa < cpb) return -1;
            if (cpa > cpb) return 1;
        } else {
            var ua: [2]u21 = undefined;
            var ub: [2]u21 = undefined;
            const la: usize = if (cpa <= 0xFFFF) blk: {
                ua[0] = cpa;
                break :blk 1;
            } else blk: {
                const x = cpa - 0x10000;
                ua[0] = 0xD800 + @divFloor(x, 0x400);
                ua[1] = 0xDC00 + @mod(x, 0x400);
                break :blk 2;
            };
            const lb: usize = if (cpb <= 0xFFFF) blk: {
                ub[0] = cpb;
                break :blk 1;
            } else blk: {
                const x = cpb - 0x10000;
                ub[0] = 0xD800 + @divFloor(x, 0x400);
                ub[1] = 0xDC00 + @mod(x, 0x400);
                break :blk 2;
            };
            var j: usize = 0;
            while (j < la and j < lb) : (j += 1) {
                if (ua[j] < ub[j]) return -1;
                if (ua[j] > ub[j]) return 1;
            }
            if (la < lb) return -1;
            if (la > lb) return 1;
        }
    }
    if (ia == a.len and ib == b.len) return 0;
    return if (ia == a.len) -1 else 1;
}

const PyKey = struct { group: i32, num: f64, text: []const u8 };

fn pyKey(ctx: *Context, v: *Jv) AppError!PyKey {
    return switch (v.typ) {
        .null => .{ .group = 0, .num = 0, .text = "" },
        .bool => .{ .group = 1, .num = if (v.b) 1 else 0, .text = "" },
        .number => .{ .group = 1, .num = v.n, .text = "" },
        .string => .{ .group = 2, .num = 0, .text = v.s },
        else => .{ .group = 3, .num = 0, .text = try jsString(ctx, v) },
    };
}

fn summaryLess(ctx: *Context, a: Summary, b: Summary) AppError!bool {
    if (a.completed != b.completed) return a.completed > b.completed;
    if (a.missed != b.missed) return a.missed > b.missed;
    const ka = try pyKey(ctx, a.user_id);
    const kb = try pyKey(ctx, b.user_id);
    if (ka.group != kb.group) return ka.group < kb.group;
    if (ka.group == 1 and ka.num != kb.num) return ka.num < kb.num;
    return compareJavaString(ka.text, kb.text) < 0;
}

fn javaLength(s: []const u8) usize {
    var idx: usize = 0;
    var n: usize = 0;
    while (idx < s.len) {
        const cp = nextCodepoint(s, &idx);
        n += if (cp > 0xFFFF) 2 else 1;
    }
    return n;
}

fn appendLjust(out: *std.array_list.Managed(u8), s: []const u8, width: usize) AppError!void {
    try out.appendSlice(s);
    const len = javaLength(s);
    if (len < width) {
        var i: usize = len;
        while (i < width) : (i += 1) try out.append(' ');
    }
}

fn splitHttpResponse(ctx: *Context, s: []const u8) AppError!struct { status: ?i64, reason: []const u8, body: []const u8 } {
    const crlf = "\r\n\r\n";
    const lflf = "\n\n";
    const crlf_pos = std.mem.indexOf(u8, s, crlf);
    const lf_pos = std.mem.indexOf(u8, s, lflf);
    const sep = crlf_pos orelse lf_pos;
    const sep_len: usize = if (sep != null and sep.? + 4 <= s.len and std.mem.eql(u8, s[sep.? .. sep.? + 4], crlf)) 4 else 2;
    const header = if (sep) |p| s[0..p] else s;
    const body = if (sep) |p| s[p + sep_len ..] else "";
    var line_end = header.len;
    if (std.mem.indexOfScalar(u8, header, '\r')) |p| line_end = p;
    if (std.mem.indexOfScalar(u8, header, '\n')) |p| line_end = @min(line_end, p);
    const status_line = header[0..line_end];
    var words = std.mem.tokenizeAny(u8, status_line, " \t");
    const proto = words.next();
    const code_txt = words.next();
    var status: ?i64 = null;
    if (proto != null and code_txt != null and
        (std.mem.eql(u8, proto.?, "HTTP/1.0") or std.mem.eql(u8, proto.?, "HTTP/1.1") or std.mem.eql(u8, proto.?, "HTTP/2") or std.mem.eql(u8, proto.?, "HTTP/3")))
    {
        var all_digits = code_txt.?.len > 0;
        for (code_txt.?) |c| all_digits = all_digits and Parser.isDigit(c);
        if (all_digits) status = std.fmt.parseInt(i64, code_txt.?, 10) catch null;
    }
    var reason_list = std.array_list.Managed(u8).init(ctx.gpa);
    var first = true;
    while (words.next()) |w| {
        if (!first) try reason_list.append(' ');
        first = false;
        try reason_list.appendSlice(w);
    }
    return .{ .status = status, .reason = try reason_list.toOwnedSlice(), .body = body };
}

fn trimTrailingNewline(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == '\n') end -= 1;
    return s[0..end];
}

fn fetchJson(ctx: *Context, io: std.Io, url: []const u8) AppError!*Jv {
    const res = try std.process.run(ctx.gpa, io, .{
        .argv = &.{ "curl", "--silent", "--show-error", "--include", "--max-time", "10", "--connect-timeout", "10", url },
    });
    switch (res.term) {
        .exited => |code| if (code == 0) {
            const parsed = try splitHttpResponse(ctx, res.stdout);
            if (parsed.status) |status| {
                if (status >= 200 and status < 300) return parseJson(ctx, parsed.body);
                if (parsed.reason.len == 0) return ctx.fail("bad status: {d}", .{status});
                return ctx.fail("bad status: {d} {s}", .{ status, parsed.reason });
            }
            return ctx.fail("bad status: 000", .{});
        },
        else => {},
    }
    return ctx.fail("{s}", .{trimTrailingNewline(res.stderr)});
}

fn today(ctx: *Context, io: std.Io) AppError!i64 {
    const res = try std.process.run(ctx.gpa, io, .{ .argv = &.{ "date", "+%Y-%m-%d" } });
    switch (res.term) {
        .exited => |code| if (code == 0) {
            const txt = trimTrailingNewline(res.stdout);
            return parseDateParts(ctx, txt, txt);
        },
        else => {},
    }
    return ctx.fail("{s}", .{trimTrailingNewline(res.stderr)});
}

fn processTodos(ctx: *Context, today_day: i64, todos: *Jv) AppError![]const u8 {
    var summaries = std.array_list.Managed(Summary).init(ctx.gpa);
    if (todos.typ == .array) {
        for (todos.arr.items) |todo| {
            const user_id = objectGet(todo, "userId");
            const completed = objectGet(todo, "completed");
            if (truthy(completed)) {
                try adjustSummary(ctx, &summaries, user_id, 1, 0);
            } else {
                const due = try parseDateOnly(ctx, objectGet(todo, "dueDate"));
                if (due < today_day) {
                    try adjustSummary(ctx, &summaries, user_id, 0, 1);
                } else {
                    try adjustSummary(ctx, &summaries, user_id, 0, 0);
                }
            }
        }
    }

    var i: usize = 1;
    while (i < summaries.items.len) : (i += 1) {
        var j = i;
        const item = summaries.items[i];
        while (j > 0 and try summaryLess(ctx, item, summaries.items[j - 1])) : (j -= 1) {
            summaries.items[j] = summaries.items[j - 1];
        }
        summaries.items[j] = item;
    }

    var out = std.array_list.Managed(u8).init(ctx.gpa);
    try out.appendSlice("USER  COMPLETED  MISSED\n");
    for (summaries.items) |s| {
        const u = try pyStr(ctx, s.user_id);
        try appendLjust(&out, u, 5);
        try out.append(' ');
        var cbuf = std.array_list.Managed(u8).init(ctx.gpa);
        try cbuf.print("{d}", .{s.completed});
        try appendLjust(&out, cbuf.items, 10);
        try out.print(" {d}\n", .{s.missed});
    }
    return out.toOwnedSlice();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var ctx = Context{ .gpa = gpa };

    if (args.len != 2) {
        try std.Io.File.stderr().writeStreamingAll(io, "usage: TodoReport <todos-url>\n");
        return std.process.exit(1);
    }

    const t = today(&ctx, io) catch {
        const msg = ctx.err orelse "unknown error";
        try std.Io.File.stderr().writeStreamingAll(io, msg);
        try std.Io.File.stderr().writeStreamingAll(io, "\n");
        return std.process.exit(1);
    };
    const todos = fetchJson(&ctx, io, args[1]) catch {
        const msg = ctx.err orelse "unknown error";
        try std.Io.File.stderr().writeStreamingAll(io, msg);
        try std.Io.File.stderr().writeStreamingAll(io, "\n");
        return std.process.exit(1);
    };
    const output = processTodos(&ctx, t, todos) catch {
        const msg = ctx.err orelse "unknown error";
        try std.Io.File.stderr().writeStreamingAll(io, msg);
        try std.Io.File.stderr().writeStreamingAll(io, "\n");
        return std.process.exit(1);
    };
    try std.Io.File.stdout().writeStreamingAll(io, output);
    return std.process.cleanExit(io);
}

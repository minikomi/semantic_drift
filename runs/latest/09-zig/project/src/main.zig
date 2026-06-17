const std = @import("std");

const ProgramError = error{ProgramError};

const JsonValue = union(enum) {
    null,
    bool: bool,
    num: JsonNumber,
    str: []const u8,
    array: []JsonValue,
    object: []Pair,
};

const JsonNumber = struct {
    raw: []const u8,
    int_value: i128,
    float_value: f64,
    integer: bool,
};

const Pair = struct {
    key: []const u8,
    value: JsonValue,
};

const Summary = struct {
    user_id: JsonValue,
    completed: i64,
    missed: i64,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,

    fn parse(self: *Parser) anyerror!JsonValue {
        const value = try self.parseValue();
        self.skipWs();
        if (self.pos != self.text.len) return fail("trailing data after JSON", .{});
        return value;
    }

    fn skipWs(self: *Parser) void {
        while (self.pos < self.text.len) : (self.pos += 1) {
            switch (self.text[self.pos]) {
                ' ', '\t', '\n', '\r' => {},
                else => break,
            }
        }
    }

    fn expect(self: *Parser, expected: u8) !void {
        if (self.pos < self.text.len and self.text[self.pos] == expected) {
            self.pos += 1;
            return;
        }
        return fail("unexpected character while parsing JSON", .{});
    }

    fn parseValue(self: *Parser) anyerror!JsonValue {
        self.skipWs();
        if (self.pos >= self.text.len) return fail("unexpected end of JSON", .{});
        return switch (self.text[self.pos]) {
            'n' => self.parseLiteral("null", JsonValue.null),
            't' => self.parseLiteral("true", JsonValue{ .bool = true }),
            'f' => self.parseLiteral("false", JsonValue{ .bool = false }),
            '"' => JsonValue{ .str = try self.parseString() },
            '[' => self.parseArray(),
            '{' => self.parseObject(),
            else => self.parseNumber(),
        };
    }

    fn parseLiteral(self: *Parser, literal: []const u8, value: JsonValue) anyerror!JsonValue {
        if (self.pos + literal.len <= self.text.len and std.mem.eql(u8, self.text[self.pos .. self.pos + literal.len], literal)) {
            self.pos += literal.len;
            return value;
        }
        return fail("invalid literal", .{});
    }

    fn parseString(self: *Parser) anyerror![]const u8 {
        try self.expect('"');
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        while (true) {
            if (self.pos >= self.text.len) return fail("unterminated string", .{});
            const ch = self.text[self.pos];
            self.pos += 1;
            if (ch == '"') return try out.toOwnedSlice(self.allocator);
            if (ch != '\\') {
                try out.append(self.allocator, ch);
                continue;
            }
            if (self.pos >= self.text.len) return fail("unterminated escape", .{});
            const esc = self.text[self.pos];
            self.pos += 1;
            switch (esc) {
                '"' => try out.append(self.allocator, '"'),
                '\\' => try out.append(self.allocator, '\\'),
                '/' => try out.append(self.allocator, '/'),
                'b' => try out.append(self.allocator, 8),
                'f' => try out.append(self.allocator, 12),
                'n' => try out.append(self.allocator, '\n'),
                'r' => try out.append(self.allocator, '\r'),
                't' => try out.append(self.allocator, '\t'),
                'u' => {
                    if (self.pos + 4 > self.text.len) return fail("short unicode escape", .{});
                    var code: u21 = 0;
                    for (0..4) |i| {
                        code = code * 16 + try hexValue(self.text[self.pos + i]);
                    }
                    self.pos += 4;
                    var buf: [4]u8 = undefined;
                    const len = try std.unicode.utf8Encode(code, &buf);
                    try out.appendSlice(self.allocator, buf[0..len]);
                },
                else => return fail("invalid escape", .{}),
            }
        }
    }

    fn parseArray(self: *Parser) anyerror!JsonValue {
        try self.expect('[');
        self.skipWs();
        var values = std.ArrayList(JsonValue).empty;
        errdefer values.deinit(self.allocator);
        if (self.pos < self.text.len and self.text[self.pos] == ']') {
            self.pos += 1;
            return JsonValue{ .array = try values.toOwnedSlice(self.allocator) };
        }
        while (true) {
            try values.append(self.allocator, try self.parseValue());
            self.skipWs();
            if (self.pos < self.text.len and self.text[self.pos] == ',') {
                self.pos += 1;
                self.skipWs();
            } else if (self.pos < self.text.len and self.text[self.pos] == ']') {
                self.pos += 1;
                return JsonValue{ .array = try values.toOwnedSlice(self.allocator) };
            } else {
                return fail("expected comma or closing bracket", .{});
            }
        }
    }

    fn parseObject(self: *Parser) anyerror!JsonValue {
        try self.expect('{');
        self.skipWs();
        var pairs = std.ArrayList(Pair).empty;
        errdefer pairs.deinit(self.allocator);
        if (self.pos < self.text.len and self.text[self.pos] == '}') {
            self.pos += 1;
            return JsonValue{ .object = try pairs.toOwnedSlice(self.allocator) };
        }
        while (true) {
            if (!(self.pos < self.text.len and self.text[self.pos] == '"')) return fail("expected object key", .{});
            const key = try self.parseString();
            self.skipWs();
            try self.expect(':');
            self.skipWs();
            try pairs.append(self.allocator, .{ .key = key, .value = try self.parseValue() });
            self.skipWs();
            if (self.pos < self.text.len and self.text[self.pos] == ',') {
                self.pos += 1;
                self.skipWs();
            } else if (self.pos < self.text.len and self.text[self.pos] == '}') {
                self.pos += 1;
                return JsonValue{ .object = try pairs.toOwnedSlice(self.allocator) };
            } else {
                return fail("expected comma or closing brace", .{});
            }
        }
    }

    fn parseNumber(self: *Parser) anyerror!JsonValue {
        const start = self.pos;
        while (self.pos < self.text.len and numberChar(self.text[self.pos])) : (self.pos += 1) {}
        const raw = self.text[start..self.pos];
        const integer = std.mem.indexOfAny(u8, raw, ".eE") == null;
        if (integer) {
            const value = std.fmt.parseInt(i128, raw, 10) catch return fail("invalid number", .{});
            return JsonValue{ .num = .{ .raw = raw, .int_value = value, .float_value = @floatFromInt(value), .integer = true } };
        } else {
            const value = std.fmt.parseFloat(f64, raw) catch return fail("invalid number", .{});
            return JsonValue{ .num = .{ .raw = raw, .int_value = 0, .float_value = value, .integer = false } };
        }
    }
};

fn hexValue(ch: u8) !u21 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return 10 + ch - 'a';
    if (ch >= 'A' and ch <= 'F') return 10 + ch - 'A';
    return fail("invalid unicode escape", .{});
}

fn numberChar(ch: u8) bool {
    return std.ascii.isDigit(ch) or ch == '+' or ch == '-' or ch == '.' or ch == 'e' or ch == 'E';
}

fn fail(comptime fmt: []const u8, args: anytype) ProgramError {
    std.debug.print(fmt ++ "\n", args);
    return ProgramError.ProgramError;
}

fn stringify(allocator: std.mem.Allocator, value: JsonValue) ![]const u8 {
    switch (value) {
        .null => return try allocator.dupe(u8, ""),
        .bool => |b| return try allocator.dupe(u8, if (b) "true" else "false"),
        .str => |s| return s,
        .num => |num| {
            if (num.integer) return try std.fmt.allocPrint(allocator, "{}", .{num.int_value});
            return try formatFloatLikeLisp(allocator, num.float_value);
        },
        .array => |items| {
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(allocator);
            try out.append(allocator, '[');
            for (items, 0..) |item, i| {
                if (i != 0) try out.appendSlice(allocator, ", ");
                const text = try stringify(allocator, item);
                try out.appendSlice(allocator, text);
            }
            try out.append(allocator, ']');
            return try out.toOwnedSlice(allocator);
        },
        .object => |pairs| {
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(allocator);
            try out.append(allocator, '{');
            for (pairs, 0..) |pair, i| {
                if (i != 0) try out.appendSlice(allocator, ", ");
                const text = try stringify(allocator, pair.value);
                const chunk = try std.fmt.allocPrint(allocator, "{s}={s}", .{ pair.key, text });
                try out.appendSlice(allocator, chunk);
            }
            try out.append(allocator, '}');
            return try out.toOwnedSlice(allocator);
        },
    }
}

fn formatFloatLikeLisp(allocator: std.mem.Allocator, value: f64) ![]const u8 {
    const raw = try std.fmt.allocPrint(allocator, "{d}", .{value});
    for (raw) |*ch| ch.* = std.ascii.toLower(ch.*);
    return raw;
}

fn objectLookup(key: []const u8, object: JsonValue) JsonValue {
    if (object != .object) return JsonValue.null;
    for (object.object) |pair| {
        if (std.mem.eql(u8, pair.key, key)) return pair.value;
    }
    return JsonValue.null;
}

fn truthy(allocator: std.mem.Allocator, value: JsonValue) !bool {
    return switch (value) {
        .null => false,
        .bool => |b| b,
        .num => |n| if (n.integer) n.int_value != 0 else n.float_value != 0,
        else => blk: {
            const text = try stringify(allocator, value);
            break :blk !std.mem.eql(u8, text, "");
        },
    };
}

fn looksDateOnly(value: []const u8) bool {
    return value.len == 10 and
        allDigits(value[0..4]) and
        value[4] == '-' and
        allDigits(value[5..7]) and
        value[7] == '-' and
        allDigits(value[8..10]);
}

fn allDigits(value: []const u8) bool {
    for (value) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

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

fn parseZoneHours(zone: []const u8) f64 {
    if (zone.len != 5) return 0;
    if (!(zone[0] == '+' or zone[0] == '-')) return 0;
    if (!allDigits(zone[1..5])) return 0;
    const sign: f64 = if (zone[0] == '+') 1 else -1;
    const hours = std.fmt.parseInt(i64, zone[1..3], 10) catch return 0;
    const minutes = std.fmt.parseInt(i64, zone[3..5], 10) catch return 0;
    const offset = @as(f64, @floatFromInt(hours)) + @as(f64, @floatFromInt(minutes)) / 60.0;
    return -(sign * offset);
}

fn dateToTime(value: []const u8, zone_hours: f64) !i64 {
    if (!looksDateOnly(value)) {
        return fail("parsing time \"{s}\" as \"2006-01-02\": cannot parse \"{s}\" as \"2006\"", .{ value, value });
    }
    const year = std.fmt.parseInt(i64, value[0..4], 10) catch unreachable;
    const month = std.fmt.parseInt(i64, value[5..7], 10) catch unreachable;
    const day = std.fmt.parseInt(i64, value[8..10], 10) catch unreachable;
    if (year < 1 or year > 9999) return fail("year {} is out of range", .{year});
    if (month < 1 or month > 12) return fail("month must be in 1..12", .{});
    if (day < 1 or day > daysInMonth(year, month)) return fail("parsing time \"{s}\": day out of range", .{value});
    const days = daysFromCivil(year, month, day);
    return days * 86400 + @as(i64, @intFromFloat(zone_hours * 3600.0));
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    var y = year;
    const m = month;
    y -= if (m <= 2) @as(i64, 1) else @as(i64, 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = m + if (m > 2) @as(i64, -3) else @as(i64, 9);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn localStartOfToday(io: std.Io, allocator: std.mem.Allocator) !i64 {
    const argv = [_][]const u8{ "date", "+%Y-%m-%dT00:00:00%z" };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const text = std.mem.trim(u8, result.stdout, "\n\r \t");
    const date = if (text.len >= 10) text[0..10] else "1970-01-01";
    const zone = if (text.len >= 24) text[19..24] else "+0000";
    return dateToTime(date, parseZoneHours(zone));
}

fn fetchUrl(io: std.Io, allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const argv = [_][]const u8{ "curl", "-sS", "-X", "GET", "-w", "%{http_code}", url };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(64 * 1024 * 1024),
    });
    defer allocator.free(result.stderr);
    if (result.stderr.len > 0) {
        std.debug.print("{s}", .{result.stderr});
    }
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.CurlFailed;
    }
    if (result.stdout.len < 3) {
        allocator.free(result.stdout);
        return fail("bad status: 0", .{});
    }
    const status_text = result.stdout[result.stdout.len - 3 ..];
    const status = std.fmt.parseInt(i64, std.mem.trim(u8, status_text, "\n\r \t"), 10) catch 0;
    if (status < 200 or status >= 300) {
        allocator.free(result.stdout);
        return fail("bad status: {}", .{status});
    }
    return try allocator.dupe(u8, result.stdout[0 .. result.stdout.len - 3]);
}

fn compareJsonValues(allocator: std.mem.Allocator, left: JsonValue, right: JsonValue) !i32 {
    if (left == .num and right == .num) {
        const lv = if (left.num.integer) @as(f64, @floatFromInt(left.num.int_value)) else left.num.float_value;
        const rv = if (right.num.integer) @as(f64, @floatFromInt(right.num.int_value)) else right.num.float_value;
        if (lv < rv) return -1;
        if (lv > rv) return 1;
        return 0;
    }
    const ls = try stringify(allocator, left);
    const rs = try stringify(allocator, right);
    if (std.mem.lessThan(u8, ls, rs)) return -1;
    if (std.mem.lessThan(u8, rs, ls)) return 1;
    return 0;
}

fn summaryLess(ctx: std.mem.Allocator, left: Summary, right: Summary) bool {
    if (left.completed != right.completed) return left.completed > right.completed;
    if (left.missed != right.missed) return left.missed > right.missed;
    return (compareJsonValues(ctx, left.user_id, right.user_id) catch 0) < 0;
}

fn summarize(allocator: std.mem.Allocator, today: i64, todos: []JsonValue) ![]Summary {
    var summaries = std.ArrayList(Summary).empty;
    for (todos) |todo| {
        const user_id = objectLookup("userId", todo);
        const key = try stringify(allocator, user_id);
        var found: ?usize = null;
        for (summaries.items, 0..) |summary, i| {
            const existing_key = try stringify(allocator, summary.user_id);
            if (std.mem.eql(u8, key, existing_key)) {
                found = i;
                break;
            }
        }
        if (found == null) {
            try summaries.append(allocator, .{ .user_id = user_id, .completed = 0, .missed = 0 });
            found = summaries.items.len - 1;
        }
        if (try truthy(allocator, objectLookup("completed", todo))) {
            summaries.items[found.?].completed += 1;
        } else {
            const due_text = try stringify(allocator, objectLookup("dueDate", todo));
            const due = try dateToTime(due_text, 0);
            if (due < today) summaries.items[found.?].missed += 1;
        }
    }
    const rows = try summaries.toOwnedSlice(allocator);
    std.mem.sort(Summary, rows, allocator, summaryLess);
    return rows;
}

fn writePadded(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, width: usize) !void {
    try out.appendSlice(allocator, text);
    if (text.len < width) {
        try out.appendNTimes(allocator, ' ', width - text.len);
    }
}

fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len != 2) {
        std.debug.print("usage: ./run.sh <url>\n", .{});
        return 2;
    }

    const body = try fetchUrl(io, allocator, args[1]);
    defer allocator.free(body);
    var parser = Parser{ .allocator = allocator, .text = body };
    const value = try parser.parse();
    if (value != .array) return fail("expected JSON array", .{});

    const rows = try summarize(allocator, try localStartOfToday(io, allocator), value.array);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "USER  COMPLETED  MISSED\n");
    for (rows) |row| {
        try writePadded(allocator, &out, try stringify(allocator, row.user_id), 5);
        try out.append(allocator, ' ');
        try writePadded(allocator, &out, try std.fmt.allocPrint(allocator, "{}", .{row.completed}), 10);
        const chunk = try std.fmt.allocPrint(allocator, " {}\n", .{row.missed});
        try out.appendSlice(allocator, chunk);
    }
    try std.Io.File.stdout().writeStreamingAll(io, out.items);
    return 0;
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(1);
    const code = run(init.io, allocator, args) catch |err| switch (err) {
        ProgramError.ProgramError => 1,
        else => blk: {
            std.debug.print("{}\n", .{err});
            break :blk 1;
        },
    };
    std.process.exit(code);
}

const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
    @cInclude("unistd.h");
});

const Summary = struct {
    user_id: std.json.Value,
    key: []const u8,
    completed: i64 = 0,
    missed: i64 = 0,
};

const AppError = error{
    BadStatus,
    ExpectedJsonArray,
    MissingKey,
    BadDate,
    RequestFailed,
    InvalidArgs,
};

const DateParseError = struct {
    value: []const u8,
};

var date_parse_error: ?DateParseError = null;
var missing_key: ?[]const u8 = null;
var bad_status: ?struct { status: u16, reason: ?[]const u8 } = null;
var generic_error_message: ?[]const u8 = null;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();

    _ = args.next();
    const url = args.next() orelse {
        try writeAllFd(2, "usage: todo-summary <todos-url>\n");
        std.process.exit(1);
    };
    if (args.next() != null) {
        try writeAllFd(2, "usage: todo-summary <todos-url>\n");
        std.process.exit(1);
    }

    run(allocator, init.io, url) catch |err| {
        switch (err) {
            AppError.BadStatus => {
                const status = bad_status.?;
                if (status.reason) |reason| {
                    try printFd(allocator, 2, "bad status: {d} {s}\n", .{ status.status, reason });
                } else {
                    try printFd(allocator, 2, "bad status: {d}\n", .{status.status});
                }
            },
            AppError.ExpectedJsonArray => try writeAllFd(2, "expected JSON array\n"),
            AppError.MissingKey => try printFd(allocator, 2, "key '{s}' not found\n", .{missing_key.?}),
            AppError.BadDate => {
                const value = date_parse_error.?.value;
                try printFd(allocator, 2, "parsing time \"{s}\" as \"2006-01-02\": cannot parse \"{s}\" as \"2006\"\n", .{ value, value });
            },
            AppError.RequestFailed => try printFd(allocator, 2, "{s}\n", .{generic_error_message orelse "request failed"}),
            else => try printFd(allocator, 2, "{s}\n", .{@errorName(err)}),
        }
        std.process.exit(1);
    };
}

fn run(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !void {
    const response = try httpGet(allocator, io, url);
    defer allocator.free(response.body);
    if (response.reason) |reason| {
        defer allocator.free(reason);
    }

    if (response.status < 200 or response.status >= 300) {
        bad_status = .{ .status = response.status, .reason = response.reason };
        return AppError.BadStatus;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch |err| {
        generic_error_message = @errorName(err);
        return AppError.RequestFailed;
    };
    defer parsed.deinit();

    const today = localMidnightNow();
    var rows = try foldTodos(allocator, today, parsed.value);
    defer {
        for (rows.items) |row| allocator.free(row.key);
        rows.deinit(allocator);
    }

    std.mem.sort(Summary, rows.items, {}, summaryLessThan);

    try writeAllFd(1, "USER  COMPLETED  MISSED\n");
    for (rows.items) |row| {
        var user_buf: std.ArrayList(u8) = .empty;
        defer user_buf.deinit(allocator);
        try displayValue(allocator, row.user_id, &user_buf);
        try padRight(1, 5, user_buf.items);
        try writeAllFd(1, " ");
        var completed_buf: [64]u8 = undefined;
        const completed = try std.fmt.bufPrint(&completed_buf, "{d}", .{row.completed});
        try padRight(1, 10, completed);
        try printFd(allocator, 1, " {d}\n", .{row.missed});
    }
}

const HttpResponse = struct {
    body: []u8,
    status: u16,
    reason: ?[]u8,
};

fn httpGet(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !HttpResponse {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    _ = std.Uri.parse(url) catch |err| {
        generic_error_message = @errorName(err);
        return AppError.RequestFailed;
    };

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    errdefer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_body.writer,
    }) catch |err| {
        generic_error_message = @errorName(err);
        return AppError.RequestFailed;
    };

    const status: u16 = @intFromEnum(result.status);
    const reason = try reasonPhrase(allocator, status);

    return .{
        .body = try response_body.toOwnedSlice(),
        .status = status,
        .reason = reason,
    };
}

fn reasonPhrase(allocator: std.mem.Allocator, status: u16) !?[]u8 {
    const phrase: ?[]const u8 = switch (status) {
        400 => "Bad Request",
        401 => "Unauthorized",
        402 => "Payment Required",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        407 => "Proxy Authentication Required",
        408 => "Request Timeout",
        409 => "Conflict",
        410 => "Gone",
        411 => "Length Required",
        412 => "Precondition Failed",
        413 => "Payload Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        416 => "Range Not Satisfiable",
        417 => "Expectation Failed",
        421 => "Misdirected Request",
        426 => "Upgrade Required",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        505 => "HTTP Version Not Supported",
        else => null,
    };
    return if (phrase) |p| try allocator.dupe(u8, p) else null;
}

fn foldTodos(allocator: std.mem.Allocator, today: i64, todos: std.json.Value) !std.ArrayList(Summary) {
    if (todos != .array) return AppError.ExpectedJsonArray;

    var rows: std.ArrayList(Summary) = .empty;
    errdefer rows.deinit(allocator);
    var keys = std.StringHashMap(usize).init(allocator);
    defer keys.deinit();

    for (todos.array.items) |todo| {
        const user_id = try required(todo, "userId");
        const completed_value = try required(todo, "completed");
        const due_date = try required(todo, "dueDate");

        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(allocator);
        try jsonKey(allocator, user_id, &key_buf);

        const entry = try keys.getOrPut(key_buf.items);
        if (!entry.found_existing) {
            entry.key_ptr.* = try allocator.dupe(u8, key_buf.items);
            entry.value_ptr.* = rows.items.len;
            try rows.append(allocator, .{ .user_id = user_id, .key = entry.key_ptr.* });
        }
        const row = &rows.items[entry.value_ptr.*];

        if (asBoolean(completed_value)) {
            row.completed += 1;
        } else {
            var text_buf: std.ArrayList(u8) = .empty;
            defer text_buf.deinit(allocator);
            try displayValue(allocator, due_date, &text_buf);
            const due = try parseDateOnlyInLocalTime(text_buf.items);
            if (due < today) row.missed += 1;
        }
    }

    return rows;
}

fn required(todo: std.json.Value, field: []const u8) !std.json.Value {
    if (todo != .object) {
        missing_key = field;
        return AppError.MissingKey;
    }
    if (todo.object.get(field)) |value| return value;
    missing_key = field;
    return AppError.MissingKey;
}

fn asBoolean(value: std.json.Value) bool {
    return switch (value) {
        .bool => |b| b,
        .string => |s| std.mem.eql(u8, s, "true"),
        .integer => |n| n == 1,
        .float => |n| n == 1.0,
        .number_string => |s| std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "1.0"),
        else => false,
    };
}

fn displayValue(allocator: std.mem.Allocator, value: std.json.Value, out: *std.ArrayList(u8)) !void {
    switch (value) {
        .string => |s| try out.appendSlice(allocator, s),
        .integer => |n| try out.print(allocator, "{d}", .{n}),
        .float => |n| try displayFloat(allocator, n, out),
        .number_string => |s| try out.appendSlice(allocator, s),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .null => {},
        else => try jsonKey(allocator, value, out),
    }
}

fn displayFloat(allocator: std.mem.Allocator, value: f64, out: *std.ArrayList(u8)) !void {
    if (std.math.isFinite(value) and @trunc(value) == value) {
        try out.print(allocator, "{d}", .{@as(i64, @intFromFloat(value))});
    } else {
        try out.print(allocator, "{d}", .{value});
    }
}

fn jsonKey(allocator: std.mem.Allocator, value: std.json.Value, out: *std.ArrayList(u8)) !void {
    try out.print(allocator, "{f}", .{std.json.fmt(value, .{})});
}

fn parseDateOnlyInLocalTime(value: []const u8) !i64 {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') {
        date_parse_error = .{ .value = value };
        return AppError.BadDate;
    }
    for (value, 0..) |ch, idx| {
        if (idx == 4 or idx == 7) continue;
        if (ch < '0' or ch > '9') {
            date_parse_error = .{ .value = value };
            return AppError.BadDate;
        }
    }

    const year = std.fmt.parseInt(c_int, value[0..4], 10) catch {
        date_parse_error = .{ .value = value };
        return AppError.BadDate;
    };
    const month = std.fmt.parseInt(c_int, value[5..7], 10) catch {
        date_parse_error = .{ .value = value };
        return AppError.BadDate;
    };
    const day = std.fmt.parseInt(c_int, value[8..10], 10) catch {
        date_parse_error = .{ .value = value };
        return AppError.BadDate;
    };

    var tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
    tm.tm_year = year - 1900;
    tm.tm_mon = month - 1;
    tm.tm_mday = day;
    tm.tm_isdst = -1;

    const timestamp = c.mktime(&tm);
    if (timestamp == -1 or tm.tm_year != year - 1900 or tm.tm_mon != month - 1 or tm.tm_mday != day) {
        date_parse_error = .{ .value = value };
        return AppError.BadDate;
    }
    return @intCast(timestamp);
}

fn localMidnightNow() i64 {
    var now = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&now, &tm);
    tm.tm_sec = 0;
    tm.tm_min = 0;
    tm.tm_hour = 0;
    tm.tm_isdst = -1;
    return @intCast(c.mktime(&tm));
}

fn padRight(fd: c_int, width: usize, value: []const u8) !void {
    try writeAllFd(fd, value);
    if (value.len < width) {
        for (0..(width - value.len)) |_| try writeAllFd(fd, " ");
    }
}

fn summaryLessThan(_: void, a: Summary, b: Summary) bool {
    if (a.completed != b.completed) return a.completed > b.completed;
    if (a.missed != b.missed) return a.missed > b.missed;
    return compareUserId(a, b);
}

fn compareUserId(a: Summary, b: Summary) bool {
    if (a.user_id == .integer and b.user_id == .integer) return a.user_id.integer < b.user_id.integer;
    if ((a.user_id == .integer or a.user_id == .float) and (b.user_id == .integer or b.user_id == .float)) return toFloat(a.user_id) < toFloat(b.user_id);
    if (a.user_id == .string and b.user_id == .string) return std.mem.lessThan(u8, a.user_id.string, b.user_id.string);
    if (a.user_id == .bool and b.user_id == .bool) return !a.user_id.bool and b.user_id.bool;
    return std.mem.lessThan(u8, a.key, b.key);
}

fn toFloat(value: std.json.Value) f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => 0,
    };
}

fn writeAllFd(fd: c_int, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(fd, bytes.ptr + written, bytes.len - written);
        if (n < 0) return error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

fn printFd(allocator: std.mem.Allocator, fd: c_int, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try writeAllFd(fd, text);
}

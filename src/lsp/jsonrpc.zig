const std = @import("std");

pub const HeaderError = error{
    MissingContentLength,
    InvalidContentLength,
    UnsupportedHeader,
    MessageTooLarge,
};

pub const Request = struct {
    arena: std.heap.ArenaAllocator,
    root: std.json.Value,
    id: ?std.json.Value,
    method: []const u8,
    params: ?std.json.Value,

    pub fn deinit(self: *Request) void {
        self.arena.deinit();
    }
};

pub fn readRequest(allocator: std.mem.Allocator, reader: anytype, max_bytes: usize) !?Request {
    var content_length: ?usize = null;
    var saw_header = false;

    while (true) {
        const line = (try readHeaderLine(allocator, reader, 8 * 1024)) orelse {
            if (!saw_header) return null;
            return error.InvalidRequest;
        };
        defer allocator.free(line);
        saw_header = true;
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) break;

        if (std.ascii.startsWithIgnoreCase(trimmed, "Content-Length:")) {
            const raw_value = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
            content_length = std.fmt.parseUnsigned(usize, raw_value, 10) catch return HeaderError.InvalidContentLength;
            continue;
        }

        if (std.ascii.startsWithIgnoreCase(trimmed, "Content-Type:")) continue;
        return HeaderError.UnsupportedHeader;
    }

    const length = content_length orelse return HeaderError.MissingContentLength;
    if (length > max_bytes) return HeaderError.MessageTooLarge;

    const payload = try reader.*.readAlloc(allocator, length);
    errdefer allocator.free(payload);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), payload, .{});
    const root = parsed.value;

    const object = switch (root) {
        .object => |object| object,
        else => return error.InvalidRequest,
    };

    const method_value = object.get("method") orelse return error.InvalidRequest;
    const method = switch (method_value) {
        .string => |value| value,
        else => return error.InvalidRequest,
    };

    const id = object.get("id");
    const params = object.get("params");

    allocator.free(payload);

    return .{
        .arena = arena,
        .root = root,
        .id = id,
        .method = method,
        .params = params,
    };
}

fn readHeaderLine(allocator: std.mem.Allocator, reader: anytype, max_bytes: usize) !?[]u8 {
    var line = try std.array_list.Managed(u8).initCapacity(allocator, 64);
    defer line.deinit();

    while (line.items.len < max_bytes) {
        var byte: [1]u8 = undefined;
        reader.*.readSliceAll(&byte) catch |err| switch (err) {
            error.EndOfStream => {
                if (line.items.len == 0) return null;
                return error.InvalidRequest;
            },
            error.ReadFailed => return error.ReadFailed,
        };

        if (byte[0] == '\n') return try line.toOwnedSlice();
        try line.append(byte[0]);
    }

    return HeaderError.MessageTooLarge;
}

pub fn sendResult(writer: anytype, id: std.json.Value, result_json: []const u8) !void {
    var body = try std.array_list.Managed(u8).initCapacity(std.heap.page_allocator, 256);
    defer body.deinit();

    try body.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
    try body.print("{f}", .{std.json.fmt(id, .{})});
    try body.appendSlice(",\"result\":");
    try body.appendSlice(result_json);
    try body.append('}');

    try writer.print("Content-Length: {}\r\n\r\n", .{body.items.len});
    try writer.writeAll(body.items);
    try writer.flush();
}

pub fn sendError(writer: anytype, id: ?std.json.Value, code: i32, message: []const u8) !void {
    var body = try std.array_list.Managed(u8).initCapacity(std.heap.page_allocator, 256);
    defer body.deinit();

    try body.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |value| {
        try body.print("{f}", .{std.json.fmt(value, .{})});
    } else {
        try body.appendSlice("null");
    }
    try body.appendSlice(",\"error\":{\"code\":");
    try body.print("{}", .{code});
    try body.appendSlice(",\"message\":");
    try body.print("{f}", .{std.json.fmt(message, .{})});
    try body.appendSlice("}}");

    try writer.print("Content-Length: {}\r\n\r\n", .{body.items.len});
    try writer.writeAll(body.items);
    try writer.flush();
}

pub fn sendNotification(writer: anytype, method: []const u8, params_json: []const u8) !void {
    var body = try std.array_list.Managed(u8).initCapacity(std.heap.page_allocator, 256);
    defer body.deinit();

    try body.appendSlice("{\"jsonrpc\":\"2.0\",\"method\":");
    try body.print("{f}", .{std.json.fmt(method, .{})});
    try body.appendSlice(",\"params\":");
    try body.appendSlice(params_json);
    try body.append('}');

    try writer.print("Content-Length: {}\r\n\r\n", .{body.items.len});
    try writer.writeAll(body.items);
    try writer.flush();
}

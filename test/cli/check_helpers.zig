const std = @import("std");

const check_api = @import("check_api");

pub const compat = check_api.compat;
const check_mod = check_api.check;

pub fn expectCheckSuccess(path: ?[]const u8) !void {
    var outcome = try check_mod.checkCommand(std.testing.allocator, path, .{});
    defer outcome.deinit(std.testing.allocator);
    switch (outcome) {
        .success => |success| {
            try std.testing.expect(success.function_count != 0);
        },
        .reported_failure => |text| {
            std.debug.print("{s}", .{text});
            return error.TestUnexpectedResult;
        },
    }
}

pub fn expectCheckFailure(path: ?[]const u8, expected: []const u8) !void {
    var outcome = try check_mod.checkCommand(std.testing.allocator, path, .{});
    defer outcome.deinit(std.testing.allocator);
    switch (outcome) {
        .success => |success| {
            std.debug.print("unexpected check success for {s}\n", .{success.display_path});
            return error.TestUnexpectedResult;
        },
        .reported_failure => |text| {
            try std.testing.expect(std.mem.indexOf(u8, text, expected) != null);
        },
    }
}

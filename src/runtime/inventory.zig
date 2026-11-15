const std = @import("std");

pub const text = @embedFile("inventory.txt");

pub fn paths(comptime group: []const u8) []const []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var count: usize = 0;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (std.mem.startsWith(u8, trimmed, group ++ " ")) count += 1;
        }
        var result: [count][]const u8 = undefined;
        lines.reset();
        var index: usize = 0;
        while (lines.next()) |line| {
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (std.mem.startsWith(u8, trimmed, group ++ " ")) {
                result[index] = trimmed[group.len + 1 ..];
                index += 1;
            }
        }
        const final = result;
        break :blk &final;
    };
}

pub const runtime = paths("runtime");
pub const memory = paths("memory");
pub const std_base = paths("std");
pub const hosted = paths("hosted");
pub const headers = paths("header");

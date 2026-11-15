const std = @import("std");

const helpers = @import("../helpers.zig");
const test_exec = @import("../support.zig");

fn expectHelp(argv: []const []const u8, expected: []const u8) !void {
    const result = try test_exec.runCommand(argv);
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    if (result.term.exited != 0 and result.stderr.len != 0) {
        std.debug.print("{s}", .{result.stderr});
    }
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try helpers.expectStderrContains(result.stderr, expected);
}

test "top-level help exits cleanly" {
    try expectHelp(&.{ "zig", "build", "run", "--", "--help" }, "usage: cyna <command>");
    try expectHelp(&.{ "zig", "build", "run", "--", "help" }, "usage: cyna <command>");
}

test "command help exits cleanly" {
    try expectHelp(&.{ "zig", "build", "run", "--", "build", "--help" }, "usage: cyna build");
    try expectHelp(&.{ "zig", "build", "run", "--", "run", "--help" }, "usage: cyna run");
    try expectHelp(&.{ "zig", "build", "run", "--", "test", "--help" }, "usage: cyna test");
    try expectHelp(&.{ "zig", "build", "run", "--", "check", "--help" }, "usage: cyna check");
    try expectHelp(&.{ "zig", "build", "run", "--", "package", "--help" }, "usage: cyna package");
}

test "package subcommand help exits cleanly" {
    try expectHelp(&.{ "zig", "build", "run", "--", "package", "build", "--help" }, "usage: cyna package build");
    try expectHelp(&.{ "zig", "build", "run", "--", "package", "pack", "--help" }, "usage: cyna package pack");
    try expectHelp(&.{ "zig", "build", "run", "--", "package", "publish", "--help" }, "usage: cyna package publish");
}

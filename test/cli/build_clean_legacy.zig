const std = @import("std");
const compat = @import("cyna").compat;

const test_exec = @import("../support.zig");

const expectCommandExitedZero = test_exec.expectCommandExitedZero;

test "clean removes convention-based project build directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
        \\fn main(): i32 {
        \\    return 0;
        \\}
        \\
    });
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const stem = std.fs.path.basename(root);
    const artifact = try std.fs.path.join(std.testing.allocator, &.{ root, "build", stem });
    defer std.testing.allocator.free(artifact);
    try expectCommandExitedZero(&.{ "zig", "build", "run", "--", "build", root });
    try compat.access(artifact, .{});
    try expectCommandExitedZero(&.{ "zig", "build", "run", "--", "clean", root });
    try std.testing.expectError(error.FileNotFound, compat.access(artifact, .{}));
}

test "clean removes single-file emitted artifacts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app.cy", .data =
        \\fn main(): i32 {
        \\    return 0;
        \\}
        \\
    });
    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app.cy");
    defer std.testing.allocator.free(source_path);
    const base = try std.fs.path.join(std.testing.allocator, &.{ std.fs.path.dirname(source_path) orelse ".", "app" });
    defer std.testing.allocator.free(base);
    const sir_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.sir", .{base});
    defer std.testing.allocator.free(sir_path);
    try expectCommandExitedZero(&.{ "zig", "build", "run", "--", "build", source_path, "--emit-sir" });
    try compat.access(sir_path, .{});
    try expectCommandExitedZero(&.{ "zig", "build", "run", "--", "clean", source_path });
    try std.testing.expectError(error.FileNotFound, compat.access(sir_path, .{}));
}

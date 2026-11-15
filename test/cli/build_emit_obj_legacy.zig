const std = @import("std");
const compat = @import("cyna").compat;

const test_helpers = @import("../helpers.zig");
const test_exec = @import("../support.zig");

const expectStderrContains = test_helpers.expectStderrContains;
const expectStderrNotContains = test_helpers.expectStderrNotContains;
const runCommand = test_exec.runCommand;

test "build emit-obj does not require main or link a native artifact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "isp.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\pub fn init_sensor(): void {
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "isp.cy");
    defer std.testing.allocator.free(source_path);
    const base = try std.fs.path.join(std.testing.allocator, &.{ std.fs.path.dirname(source_path) orelse ".", "isp" });
    defer std.testing.allocator.free(base);

    const header_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.h", .{base});
    defer std.testing.allocator.free(header_path);
    const object_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.o", .{base});
    defer std.testing.allocator.free(object_path);
    const native_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.native", .{base});
    defer std.testing.allocator.free(native_path);

    const result = try runCommand(&.{
        "zig",
        "build",
        "run",
        "--",
        "build",
        source_path,
        "--emit-c-header",
        "--emit-obj",
    });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try compat.access(header_path, .{});
    try compat.access(object_path, .{});
    try std.testing.expectError(error.FileNotFound, compat.access(native_path, .{}));
    try expectStderrContains(result.stderr, "wrote object file to");
    try expectStderrNotContains(result.stderr, "wrote native artifact to");
}

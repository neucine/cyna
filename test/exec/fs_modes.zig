const std = @import("std");
const compat = @import("cyna").compat;
const helpers = @import("../helpers.zig");

test "native std.fs open modes and directory helpers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "modes.txt" });
    defer std.testing.allocator.free(path);
    const literal_path = try helpers.cynaPathLiteralAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(literal_path);
    const source = try std.mem.replaceOwned(u8, std.testing.allocator, @embedFile("fs_modes_fixture.cy"), "__FILE_PATH__", literal_path);
    defer std.testing.allocator.free(source);

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_std_fs_modes.cy", source, 42);
}

const std = @import("std");
const compat = @import("cyna").compat;
const helpers = @import("../helpers.zig");

test "native std.fs File uses byte reader and writer helpers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "stream.txt" });
    defer std.testing.allocator.free(path);
    const source = try std.mem.replaceOwned(u8, std.testing.allocator, @embedFile("fs_stream_fixture.cy"), "__FILE_PATH__", path);
    defer std.testing.allocator.free(source);

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_std_fs_stream.cy", source, 42);
}

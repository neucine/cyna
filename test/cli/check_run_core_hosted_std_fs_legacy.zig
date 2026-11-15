const std = @import("std");
const helpers = @import("check_helpers.zig");
const compat = helpers.compat;

test "check command accepts hosted std.fs import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.fs;
            \\
            \\fn main(): i32 {
            \\    return 0;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try helpers.expectCheckSuccess(source_path);
}

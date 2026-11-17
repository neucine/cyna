const std = @import("std");
const helpers = @import("check_helpers.zig");
const compat = helpers.compat;

test "check command accepts hosted std.thread import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\
            \\@concurrency.isolated
            \\fn worker(value: i32): void {
            \\    const ignored = value;
            \\}
            \\
            \\fn main(): i32 {
            \\    const payload: i32 = 7;
            \\    const handle = thread.spawn(worker, payload) catch (problem) { return 0; };
            \\    const ignored = handle;
            \\    return 1;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try helpers.expectCheckSuccess(source_path);
}

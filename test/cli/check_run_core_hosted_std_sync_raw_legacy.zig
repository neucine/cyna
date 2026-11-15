const std = @import("std");
const helpers = @import("check_helpers.zig");
const compat = helpers.compat;

test "check command rejects direct std.sync raw field access" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.sync;
            \\import { AtomicI32 } from std.sync;
            \\
            \\fn main(): i32 {
            \\    const cell = AtomicI32.init(0);
            \\    const raw = cell.raw;
            \\    return raw as i32;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try helpers.expectCheckFailure(source_path, "field `raw`");
}

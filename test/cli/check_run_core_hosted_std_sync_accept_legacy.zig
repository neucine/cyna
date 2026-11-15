const std = @import("std");
const helpers = @import("check_helpers.zig");
const compat = helpers.compat;

test "check command accepts hosted std.sync import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.sync;
            \\import { AtomicBool, AtomicI32, AtomicUsize, Condvar, MemoryOrder, Mutex, SyncStatus } from std.sync;
            \\
            \\fn main(): i32 {
            \\    const order = MemoryOrder.seq_cst;
            \\    const ignored = order;
            \\    const status = SyncStatus.invalid_handle;
            \\    const ignored_status = status;
            \\    const condvar = Condvar.init();
            \\    const ignored_condvar = condvar;
            \\    return 0;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try helpers.expectCheckSuccess(source_path);
}

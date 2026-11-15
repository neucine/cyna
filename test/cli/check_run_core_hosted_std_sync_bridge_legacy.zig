const std = @import("std");
const helpers = @import("check_helpers.zig");
const compat = helpers.compat;

test "check command rejects direct std.sync bridge primitive imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.sync;
            \\import { atomic_i32_fetch_add } from std.sync;
            \\
            \\fn main(): i32 {
            \\    const ignored = atomic_i32_fetch_add;
            \\    return 0;
            \\}
            \\
        );
    }
    {
        const file = try compat.dirCreateFile(tmp.dir, "init.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.sync;
            \\import { atomic_i32_init } from std.sync;
            \\
            \\fn main(): i32 {
            \\    const ignored = atomic_i32_init;
            \\    return 0;
            \\}
            \\
        );
    }
    {
        const file = try compat.dirCreateFile(tmp.dir, "valid.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.sync;
            \\import { atomic_i32_is_valid_raw } from std.sync;
            \\
            \\fn main(): i32 {
            \\    const ignored = atomic_i32_is_valid_raw;
            \\    return 0;
            \\}
            \\
        );
    }
    {
        const file = try compat.dirCreateFile(tmp.dir, "try_lock.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.sync;
            \\import { mutex_try_lock } from std.sync;
            \\
            \\fn main(): i32 {
            \\    const ignored = mutex_try_lock;
            \\    return 0;
            \\}
            \\
        );
    }
    {
        const file = try compat.dirCreateFile(tmp.dir, "condvar.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.sync;
            \\import { condvar_wait } from std.sync;
            \\
            \\fn main(): i32 {
            \\    const ignored = condvar_wait;
            \\    return 0;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);
    const init_source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "init.cy");
    defer std.testing.allocator.free(init_source_path);
    const valid_source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "valid.cy");
    defer std.testing.allocator.free(valid_source_path);
    const try_lock_source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "try_lock.cy");
    defer std.testing.allocator.free(try_lock_source_path);
    const condvar_source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "condvar.cy");
    defer std.testing.allocator.free(condvar_source_path);

    try helpers.expectCheckFailure(source_path, "atomic_i32_fetch_add");
    try helpers.expectCheckFailure(init_source_path, "atomic_i32_init");
    try helpers.expectCheckFailure(valid_source_path, "atomic_i32_is_valid_raw");
    try helpers.expectCheckFailure(try_lock_source_path, "mutex_try_lock");
    try helpers.expectCheckFailure(condvar_source_path, "condvar_wait");
}

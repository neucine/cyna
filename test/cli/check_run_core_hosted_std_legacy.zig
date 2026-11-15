const std = @import("std");
const compat = @import("cyna").compat;

const test_exec = @import("../support.zig");

const runCommand = test_exec.runCommand;

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

    const result = try runCommand(&.{ "zig", "build", "run", "--", "check", source_path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "check command accepts hosted std.thread import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\
            \\@isolated
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

    const result = try runCommand(&.{ "zig", "build", "run", "--", "check", source_path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    if (result.term.exited != 0 and result.stderr.len != 0) {
        std.debug.print("{s}", .{result.stderr});
    }
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "check command rejects direct std.thread handle bridge import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\import { join } from std.thread;
            \\
            \\fn main(): i32 {
            \\    const ignored = join;
            \\    return 0;
            \\}
            \\
        );
    }
    {
        const file = try compat.dirCreateFile(tmp.dir, "id.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\import { current_id_raw } from std.thread;
            \\
            \\fn main(): i32 {
            \\    const ignored = current_id_raw;
            \\    return 0;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);
    const id_source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "id.cy");
    defer std.testing.allocator.free(id_source_path);

    const result = try runCommand(&.{ "zig", "build", "run", "--", "check", source_path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expect(result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "join") != null);

    const id_result = try runCommand(&.{ "zig", "build", "run", "--", "check", id_source_path });
    defer {
        std.testing.allocator.free(id_result.stdout);
        std.testing.allocator.free(id_result.stderr);
    }
    try std.testing.expect(id_result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, id_result.stderr, "current_id_raw") != null);
}

test "check command rejects direct std.thread spawn bridge imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\import { spawn_i32 } from std.thread;
            \\
            \\fn main(): i32 {
            \\    const ignored = spawn_i32;
            \\    return 0;
            \\}
            \\
        );
    }
    {
        const file = try compat.dirCreateFile(tmp.dir, "boxed.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\import { spawn_boxed } from std.thread;
            \\
            \\fn main(): i32 {
            \\    const ignored = spawn_boxed;
            \\    return 0;
            \\}
            \\
        );
    }
    {
        const file = try compat.dirCreateFile(tmp.dir, "raw.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\import { spawn_raw } from std.thread;
            \\
            \\fn main(): i32 {
            \\    const ignored = spawn_raw;
            \\    return 0;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);
    const boxed_source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "boxed.cy");
    defer std.testing.allocator.free(boxed_source_path);
    const raw_source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "raw.cy");
    defer std.testing.allocator.free(raw_source_path);

    const result = try runCommand(&.{ "zig", "build", "run", "--", "check", source_path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expect(result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "spawn_i32") != null);

    const boxed_result = try runCommand(&.{ "zig", "build", "run", "--", "check", boxed_source_path });
    defer {
        std.testing.allocator.free(boxed_result.stdout);
        std.testing.allocator.free(boxed_result.stderr);
    }
    try std.testing.expect(boxed_result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, boxed_result.stderr, "spawn_boxed") != null);

    const raw_result = try runCommand(&.{ "zig", "build", "run", "--", "check", raw_source_path });
    defer {
        std.testing.allocator.free(raw_result.stdout);
        std.testing.allocator.free(raw_result.stderr);
    }
    try std.testing.expect(raw_result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, raw_result.stderr, "spawn_raw") != null);
}

test "check command rejects direct std.thread raw field access" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\
            \\fn main(): i32 {
            \\    const id = thread.current_id();
            \\    const raw = id.raw;
            \\    return raw as i32;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    const result = try runCommand(&.{ "zig", "build", "run", "--", "check", source_path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expect(result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "field `raw`") != null);
}

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

    const result = try runCommand(&.{ "zig", "build", "run", "--", "check", source_path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expect(result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "field `raw`") != null);
}

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

    const result = try runCommand(&.{ "zig", "build", "run", "--", "check", source_path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    if (result.term.exited != 0 and result.stderr.len != 0) {
        std.debug.print("{s}", .{result.stderr});
    }
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

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

    const result = try runCommand(&.{ "zig", "build", "run", "--", "check", source_path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expect(result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "atomic_i32_fetch_add") != null);

    const init_result = try runCommand(&.{ "zig", "build", "run", "--", "check", init_source_path });
    defer {
        std.testing.allocator.free(init_result.stdout);
        std.testing.allocator.free(init_result.stderr);
    }
    try std.testing.expect(init_result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, init_result.stderr, "atomic_i32_init") != null);

    const valid_result = try runCommand(&.{ "zig", "build", "run", "--", "check", valid_source_path });
    defer {
        std.testing.allocator.free(valid_result.stdout);
        std.testing.allocator.free(valid_result.stderr);
    }
    try std.testing.expect(valid_result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, valid_result.stderr, "atomic_i32_is_valid_raw") != null);

    const try_lock_result = try runCommand(&.{ "zig", "build", "run", "--", "check", try_lock_source_path });
    defer {
        std.testing.allocator.free(try_lock_result.stdout);
        std.testing.allocator.free(try_lock_result.stderr);
    }
    try std.testing.expect(try_lock_result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, try_lock_result.stderr, "mutex_try_lock") != null);

    const condvar_result = try runCommand(&.{ "zig", "build", "run", "--", "check", condvar_source_path });
    defer {
        std.testing.allocator.free(condvar_result.stdout);
        std.testing.allocator.free(condvar_result.stderr);
    }
    try std.testing.expect(condvar_result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, condvar_result.stderr, "condvar_wait") != null);
}

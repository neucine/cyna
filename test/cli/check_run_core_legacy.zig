const std = @import("std");
const compat = @import("cyna").compat;

const compiler = @import("cyna").compiler;
const sema = compiler.sema;
const loader = compiler.loader;
const test_exec = @import("../support.zig");

const runCommand = test_exec.runCommand;
const runNativeFileExitCodeFast = test_exec.runNativeFileExitCodeFast;
const runNativeFileExitCodeWithArgv = test_exec.runNativeFileExitCodeWithArgv;

test "check command accepts project directory manifest entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "check-project"
        \\src = "src"
        \\entry = "src/main.cy"
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
        \\import .util;
        \\
        \\fn main(): i32 {
        \\    return util.answer();
        \\}
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/util.cy", .data =
        \\pub fn answer(): i32 {
        \\    return 42;
        \\}
        \\
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root_path);

    const result = try runCommand(&.{ "zig", "build", "run", "--", "check", root_path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    if (result.term.exited != 0 and result.stderr.len != 0) {
        std.debug.print("{s}", .{result.stderr});
    }
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "ok") != null);
}

test "check command reports parse diagnostics for invalid source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "parse-invalid"
        \\src = "src"
        \\entry = "src/main.cy"
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
        \\fn main(): i32 {
        \\    const value = ;
        \\    return 0;
        \\}
        \\
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root_path);

    const result = try runCommand(&.{ "zig", "build", "run", "--", "check", root_path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "expected expression") != null);
}

test "check command reports semantic diagnostics for invalid source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "semantic-invalid"
        \\src = "src"
        \\entry = "src/main.cy"
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
        \\fn main(): i32 {
        \\    return "oops";
        \\}
        \\
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root_path);

    const result = try runCommand(&.{ "zig", "build", "run", "--", "check", root_path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "type mismatch: expected i32, got string") != null);
}

test "check command accepts standalone source file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\fn main(): i32 {
        \\    return 0;
        \\}
        \\
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    const result = try runCommand(&.{ "zig", "build", "run", "--", "check", source_path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, ": ok (") != null);
}

test "check command reports standalone parse diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\fn main(): i32 {
        \\    const value = ;
        \\    return 0;
        \\}
        \\
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    const result = try runCommand(&.{ "zig", "build", "run", "--", "check", source_path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "expected expression") != null);
}

test "check command reports standalone semantic diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\fn main(): i32 {
        \\    return "oops";
        \\}
        \\
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    const result = try runCommand(&.{ "zig", "build", "run", "--", "check", source_path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "type mismatch: expected i32, got string") != null);
}

test "check command reports unresolved project import with attempted path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "missing-import"
        \\src = "src"
        \\entry = "src/main.cy"
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
        \\import .missing;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        \\
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root_path);

    const result = try runCommand(&.{ "zig", "build", "run", "--", "check", root_path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unresolved import `missing`") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "attempted path") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "current source root") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "FileNotFound") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "std/") == null);
}

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

test "check command accepts prelude List Map and Set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\fn main(): i32 {
            \\    var xs: List<i32> = list<i32>();
            \\    var scores: Map<string, i32> = map<string, i32>();
            \\    var names: Set<string> = set<string>();
            \\    xs.push(1);
            \\    scores["ok"] = 42;
            \\    names.add("Ada");
            \\    if xs.len() == 1 and scores["ok"] == 42 and names.contains("Ada") {
            \\        return 0;
            \\    }
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
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "check command accepts prelude List method calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\fn main(): i32 {
            \\    var xs: List<i32> = list<i32>();
            \\    xs.reserve(4);
            \\    xs.push(1);
            \\    xs.push(2);
            \\    const last = xs.pop();
            \\    if last == 2 and xs.len() == 1 {
            \\        return 0;
            \\    }
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
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "check command accepts prelude Map and Set method calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\fn main(): i32 {
            \\    var scores: Map<string, i32> = map<string, i32>();
            \\    scores["ok"] = 42;
            \\    var names: Set<string> = set<string>();
            \\    names.add("Ada");
            \\    if scores.contains("ok") and not scores.contains("bad") and names.contains("Ada") and scores.len() == 1 and names.len() == 1 {
            \\        return 0;
            \\    }
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
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "check command accepts prelude Map keys values and Set clear methods" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\fn main(): i32 {
            \\    var scores: Map<string, i32> = map<string, i32>();
            \\    scores["Ada"] = 10;
            \\    scores["Ken"] = 12;
            \\    var names: Set<string> = set<string>();
            \\    names.add("Ada");
            \\    names.add("Ken");
            \\    names.clear();
            \\    var key_count: i32 = 0;
            \\    for name in scores.keys() {
            \\        if name == "Ada" or name == "Ken" {
            \\            key_count = key_count + 1;
            \\        }
            \\    }
            \\    var total: i32 = 0;
            \\    var value_count: i32 = 0;
            \\    for value in scores.values() {
            \\        total = total + value;
            \\        value_count = value_count + 1;
            \\    }
            \\    if key_count == 2 and total == 22 and value_count == 2 and names.len() == 0 {
            \\        return 0;
            \\    }
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
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "emit-sir shows std.fs as hidden implementation ABI imports" {
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

    var loaded = try loader.loadProgram(std.testing.allocator, source_path);
    defer loaded.deinit(std.testing.allocator);
    const module = try sema.buildSirWithOptions(std.testing.allocator, source_path, loaded.program, .{});
    defer module.deinit(std.testing.allocator);

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    var text_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &text);
    try module.dump(&text_writer.writer);
    text = text_writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, text.items, "extern c fn read_file(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "= \"cyna_std_fs_read_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "fn ls(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "extern c fn open_dir(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "= \"cyna_std_fs_open_dir\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "extern c fn read_dir_next(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "= \"cyna_std_fs_read_dir_next\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "extern c fn close_dir(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "= \"cyna_std_fs_close_dir\"") != null);
}

test "check rejects redundant module import alias" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "lib");

    {
        const dep = try compat.dirCreateFile(tmp.dir, "lib/math.cy", .{});
        defer compat.closeFile(dep);
        try compat.fileWriteAll(dep,
            \\pub fn forty_two(): i32 {
            \\    return 42;
            \\}
            \\
        );
    }

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import lib.math as math;
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
    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "redundant import alias") != null);
}

test "check rejects redundant selected import alias" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "lib");

    {
        const dep = try compat.dirCreateFile(tmp.dir, "lib/math.cy", .{});
        defer compat.closeFile(dep);
        try compat.fileWriteAll(dep,
            \\pub fn forty_two(): i32 {
            \\    return 42;
            \\}
            \\
        );
    }

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import { forty_two as forty_two } from lib.math;
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
    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "redundant import alias") != null);
}

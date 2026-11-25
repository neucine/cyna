const std = @import("std");
const compat = @import("cyna").compat;

const test_exec = @import("../support.zig");

const runCommand = test_exec.runCommand;
const runNativeFileExitCodeFast = test_exec.runNativeFileExitCodeFast;
const runNativeFileExitCodeWithArgv = test_exec.runNativeFileExitCodeWithArgv;

test "native run supports hosted std.fs string and byte io" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const data = try compat.dirCreateFile(tmp.dir, "input.bin", .{});
        defer compat.closeFile(data);
        try compat.fileWriteAll(data, "ABC");
    }

    const input_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "input.bin");
    defer std.testing.allocator.free(input_path);
    const output_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(output_path);
    const written_path = try std.fs.path.join(std.testing.allocator, &.{ output_path, "written.bin" });
    defer std.testing.allocator.free(written_path);

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\import std.fs;
            \\import {{ FsError }} from std.fs;
            \\
            \\fn run(): i32!FsError {{
            \\    const text = try fs.read_file("{s}");
            \\    if text != "ABC" {{
            \\        return 1;
            \\    }}
            \\    const bytes = try fs.read_bytes("{s}");
            \\    if bytes[0] != 65 or bytes[1] != 66 or bytes[2] != 67 {{
            \\        return 2;
            \\    }}
            \\    const view = bytes[..];
            \\    if view.len() != 3 {{
            \\        return 3;
            \\    }}
            \\    try fs.write_bytes("{s}", view);
            \\    const written = try fs.read_file("{s}");
            \\    if written != "ABC" {{
            \\        return 4;
            \\    }}
            \\    return 42;
            \\}}
            \\
            \\fn main(): i32 {{
            \\    const code = run() catch (problem) {{
            \\        const ignored = problem;
            \\        return 99;
            \\    }};
            \\    return code;
            \\}}
            \\
        , .{ input_path, input_path, written_path, written_path });
        defer std.testing.allocator.free(source);
        try compat.fileWriteAll(file, source);
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.fs releases owned path arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "input.txt", .data = "ABC" });

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ root, "input.txt" });
    defer std.testing.allocator.free(input_path);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root, "owned-output.txt" });
    defer std.testing.allocator.free(output_path);
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ root, "owned-dir" });
    defer std.testing.allocator.free(dir_path);

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\import std.fs;
        \\import {{ FsError }} from std.fs;
        \\
        \\fn owned(raw: []const u8): string {{
        \\    return string.from(raw);
        \\}}
        \\
        \\fn run(): i32!FsError {{
        \\    const exists_path = owned("{s}".bytes());
        \\    const found = try fs.exists(exists_path);
        \\    if found == false {{
        \\        return 3;
        \\    }}
        \\
        \\    const input_path = owned("{s}".bytes());
        \\    const text = try fs.read_file(input_path);
        \\    if text != "ABC" {{
        \\        return 1;
        \\    }}
        \\
        \\    const bytes_path = owned("{s}".bytes());
        \\    const bytes = try fs.read_bytes(bytes_path);
        \\    if bytes.len() != 3 {{
        \\        return 2;
        \\    }}
        \\
        \\    const output_path = owned("{s}".bytes());
        \\    try fs.write_bytes(output_path, bytes[..]);
        \\
        \\    const dir_path = owned("{s}".bytes());
        \\    try fs.mkdir(dir_path);
        \\
        \\    const list_path = owned("{s}".bytes());
        \\    const entries = try fs.ls(list_path);
        \\    if entries.len() == 0 {{
        \\        return 4;
        \\    }}
        \\    return 42;
        \\}}
        \\
        \\fn main(): i32 {{
        \\    const code = run() catch (problem) {{
        \\        const ignored = problem;
        \\        return 99;
        \\    }};
        \\    return code;
        \\}}
        \\
    , .{ input_path, input_path, input_path, output_path, dir_path, root });
    defer std.testing.allocator.free(source);

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.process args list releases argv storage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import std.process;
        \\
        \\fn consume(value: string): i32 {
        \\    if value == "sentinel" {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    const values = process.args();
        \\    if values.len() != 2 {
        \\        return 2;
        \\    }
        \\    return consume(values[1]);
        \\}
        \\
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeWithArgv(std.testing.allocator, source_path, &.{"sentinel"}));
}

test "native std.process command run releases owned program boundary copy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import std.process;
        \\import { ProcessError, Stdio } from std.process;
        \\
        \\fn run(): i32!ProcessError {
        \\    const program = string.from("/usr/bin/true".bytes());
        \\    const status = try process.command(program)
        \\        .stdout(Stdio.null)
        \\        .stderr(Stdio.null)
        \\        .run();
        \\    if status.success == false {
        \\        drop program;
        \\        return 1;
        \\    }
        \\    drop program;
        \\    return 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    const code = run() catch (problem) {
        \\        const ignored = problem;
        \\        return 99;
        \\    };
        \\    return code;
        \\}
        \\
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.process command output releases owned boundary copies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import std.process;
        \\import { ProcessError, Stdio } from std.process;
        \\
        \\fn run(): i32!ProcessError {
        \\    const program = string.from("/bin/echo".bytes());
        \\    const arg = string.from("sentinel".bytes());
        \\    const out = try process.command(program)
        \\        .arg(arg)
        \\        .stdout(Stdio.piped)
        \\        .stderr(Stdio.piped)
        \\        .output();
        \\    if out.status.success == false {
        \\        drop out;
        \\        drop arg;
        \\        drop program;
        \\        return 1;
        \\    }
        \\    if out.stdout.bytes().len() != 9 {
        \\        drop out;
        \\        drop arg;
        \\        drop program;
        \\        return 2;
        \\    }
        \\    if out.stdout.bytes()[0] != 115 or out.stdout.bytes()[8] != 10 {
        \\        drop out;
        \\        drop arg;
        \\        drop program;
        \\        return 3;
        \\    }
        \\    drop out;
        \\    drop arg;
        \\    drop program;
        \\    return 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    const code = run() catch (problem) {
        \\        const ignored = problem;
        \\        return 99;
        \\    };
        \\    return code;
        \\}
        \\
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "hosted std.fs shim avoids raw libc allocation helpers" {
    const source = try compat.readFileAlloc(std.testing.allocator, "packages/std/src/std_fs.c", 64 * 1024);
    defer std.testing.allocator.free(source);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        try std.testing.expect(!std.mem.startsWith(u8, trimmed, "malloc("));
        try std.testing.expect(!std.mem.startsWith(u8, trimmed, "free("));
        try std.testing.expect(std.mem.indexOf(u8, trimmed, "= (char *)malloc(") == null);
        try std.testing.expect(std.mem.indexOf(u8, trimmed, "= (unsigned char *)malloc(") == null);
    }
}

test "native run supports hosted std.path utilities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.path;
            \\
            \\fn main(): i32 {
            \\    var parts: List<string> = list<string>();
            \\    parts.push("/tmp/");
            \\    parts.push("cyna");
            \\    parts.push("main.cy");
            \\    const joined = path.join(parts[..]);
            \\    if joined != "/tmp/cyna/main.cy" {
            \\        return 1;
            \\    }
            \\    const base = path.basename(joined);
            \\    if base != "main.cy" {
            \\        return 2;
            \\    }
            \\    const dir = path.dirname(joined);
            \\    if dir != "/tmp/cyna" {
            \\        return 3;
            \\    }
            \\    if not path.is_absolute(joined) {
            \\        return 4;
            \\    }
            \\    if path.is_absolute("relative/path") {
            \\        return 5;
            \\    }
            \\    if path.extension(joined) is ext {
            \\        if ext != "cy" {
            \\            return 6;
            \\        }
            \\    } else {
            \\        return 7;
            \\    }
            \\    const stem = path.stem(joined);
            \\    if stem != "main" {
            \\        return 8;
            \\    }
            \\    if path.extension(".gitignore") is hidden_ext {
            \\        const ignored = hidden_ext;
            \\        return 9;
            \\    }
            \\    const hidden_stem = path.stem(".gitignore");
            \\    if hidden_stem != ".gitignore" {
            \\        return 10;
            \\    }
            \\    if path.extension("archive.tar.gz") is gz {
            \\        if gz != "gz" {
            \\            return 11;
            \\        }
            \\    } else {
            \\        return 12;
            \\    }
            \\    const archive_stem = path.stem("archive.tar.gz");
            \\    if archive_stem != "archive.tar" {
            \\        return 13;
            \\    }
            \\    return 42;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native run supports hosted std.time nanosecond clocks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.time;
            \\import { TimeError } from std.time;
            \\
            \\fn run(): i32!TimeError {
            \\    const now = try time.now_ns();
            \\    if now <= 0 {
            \\        return 1;
            \\    }
            \\    const start = try time.monotonic_ns();
            \\    var total: i64 = 0;
            \\    var i: i64 = 0;
            \\    while i < 1000 {
            \\        total = total + i;
            \\        i = i + 1;
            \\    }
            \\    const finish = try time.monotonic_ns();
            \\    if finish < start {
            \\        return 2;
            \\    }
            \\    if total != 499500 {
            \\        return 3;
            \\    }
            \\    const elapsed = try time.elapsed_ns(start);
            \\    if elapsed < 0 {
            \\        return 4;
            \\    }
            \\    const elapsed_ms = try time.elapsed_ms(start);
            \\    if elapsed_ms < 0 {
            \\        return 5;
            \\    }
            \\    if time.ns_to_ms(2500000) != 2 {
            \\        return 6;
            \\    }
            \\    const converted = try time.ms_to_ns(3);
            \\    if converted != 3000000 {
            \\        return 7;
            \\    }
            \\    try time.sleep_ns(0);
            \\    try time.sleep_ms(0);
            \\    time.sleep_ms(9223372036855) catch (code) {
            \\        if code != TimeError.overflow { return 9; }
            \\    };
            \\    return 42;
            \\}
            \\
            \\fn main(): i32 {
            \\    return run() catch (code) { yield 99; };
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.thread spawn accepts string payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\
            \\@concurrency.isolated
            \\fn worker(value: string): void {
            \\    const ignored = value;
            \\}
            \\
            \\fn main(): i32 {
            \\    const handle = thread.spawn(worker, "payload") catch (spawn_problem) {
            \\        const ignored = spawn_problem;
            \\        return 1;
            \\    };
            \\    switch handle.join() {
            \\    .settled => {
            \\        return 42;
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 2;
            \\    }
            \\    }
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.thread generic spawn starts and joins i32 worker" {
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
            \\    const payload: i32 = 42;
            \\    const handle = thread.spawn(worker, payload) catch (spawn_problem) {
            \\        const ignored = spawn_problem;
            \\        return 1;
            \\    };
            \\    switch handle.join() {
            \\    .settled => {
            \\        return 42;
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 2;
            \\    }
            \\    }
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.thread exposes opaque thread ids" {
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
            \\    const current = thread.current_id();
            \\    if not current.is_valid() {
            \\        return 1;
            \\    }
            \\    if not current.equals(thread.current_id()) {
            \\        return 2;
            \\    }
            \\    const payload: i32 = 42;
            \\    const handle = thread.spawn(worker, payload) catch (spawn_problem) {
            \\        const ignored = spawn_problem;
            \\        return 4;
            \\    };
            \\    if not handle.id().is_valid() {
            \\        return 3;
            \\    }
            \\    switch handle.join() {
            \\    .settled => {
            \\        return 42;
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 5;
            \\    }
            \\    }
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.thread generic spawn routes i32 payload to hosted worker" {
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
            \\    const payload: i32 = 42;
            \\    const handle = thread.spawn(worker, payload) catch (spawn_problem) {
            \\        const ignored = spawn_problem;
            \\        return 1;
            \\    };
            \\    switch handle.join() {
            \\    .settled => {
            \\        return 42;
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 2;
            \\    }
            \\    }
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.thread generic spawn copies structured transferable payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\
            \\struct Job {
            \\    id: i32;
            \\    name: string;
            \\}
            \\
            \\@concurrency.isolated
            \\fn worker(job: Job): void {
            \\    assert(job.id == 40);
            \\    assert(job.name == "Ada");
            \\}
            \\
            \\fn main(): i32 {
            \\    const payload = Job { id: 40, name: "Ada" };
            \\    const handle = thread.spawn(worker, payload) catch (spawn_problem) {
            \\        const ignored = spawn_problem;
            \\        return 1;
            \\    };
            \\    switch handle.join() {
            \\    .settled => {
            \\        return 42;
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 2;
            \\    }
            \\    }
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.thread spawn_boxed copies payload and joins hosted worker" {
    const source =
        \\import std.thread;
        \\
        \\extern c("call_spawn_boxed_i32") fn call_spawn_boxed_i32(): c_int;
        \\extern c("call_spawn_boxed_aligned") fn call_spawn_boxed_aligned(): c_int;
        \\extern c("set_spawn_boxed_seen") fn set_spawn_boxed_seen(value: c_int): void;
        \\
        \\@concurrency.isolated
        \\fn unused_worker(value: i32): void {
        \\    const ignored = value;
        \\}
        \\
        \\export c("boxed_i32_worker") fn boxed_i32_worker(ctx: *c_void): void {
        \\    unchecked {
        \\        const payload = ctx as! *i32;
        \\        set_spawn_boxed_seen(*payload as c_int);
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const result = call_spawn_boxed_i32();
        \\    if result == -1 {
        \\        const zero: i32 = 0;
        \\        const handle = thread.spawn(unused_worker, zero) catch (spawn_problem) {
        \\            const ignored = spawn_problem;
        \\            return result as i32;
        \\        };
        \\        const ignored = handle;
        \\    }
        \\    if result != 42 {
        \\        return result as i32;
        \\    }
        \\    const aligned = call_spawn_boxed_aligned();
        \\    return aligned as i32;
        \\}
        \\
    ;
    const c_source =
        \\#include <stdint.h>
        \\#include <stddef.h>
        \\#include <string.h>
        \\
        \\typedef struct CynaTypeDesc CynaTypeDesc;
        \\typedef void (*CynaCopyFn)(void *dst, const void *src, const CynaTypeDesc *desc);
        \\typedef void (*CynaDropFn)(void *value, const CynaTypeDesc *desc);
        \\typedef uint8_t (*CynaEqFn)(const void *lhs, const void *rhs, const CynaTypeDesc *desc);
        \\typedef uint64_t (*CynaHashFn)(const void *value, const CynaTypeDesc *desc);
        \\struct CynaTypeDesc {
        \\    int64_t size;
        \\    int64_t align;
        \\    uint32_t flags;
        \\    CynaCopyFn copy;
        \\    CynaDropFn drop;
        \\    CynaEqFn eq;
        \\    CynaHashFn hash;
        \\    const void *extra;
        \\};
        \\typedef struct {
        \\    unsigned long raw;
        \\} CynaThread;
        \\typedef struct {
        \\    uint8_t is_ok;
        \\    CynaThread ok;
        \\    int32_t err;
        \\} CynaResultThreadThreadError;
        \\typedef struct {
        \\    _Bool settled;
        \\    int32_t code;
        \\    CynaThread handle;
        \\} CynaThreadOpRaw;
        \\
        \\extern const CynaTypeDesc cyna_desc_i32;
        \\extern void boxed_i32_worker(void *);
        \\extern CynaResultThreadThreadError cyna_std_thread_spawn_boxed(void (*entry)(void *), const void *value, const CynaTypeDesc *desc);
        \\extern CynaThreadOpRaw cyna_std_thread_join(CynaThread thread);
        \\
        \\static int32_t seen = 0;
        \\typedef struct {
        \\    unsigned char bytes[64];
        \\} AlignedPayload;
        \\static int32_t aligned_seen = 0;
        \\
        \\void set_spawn_boxed_seen(int32_t value) {
        \\    __atomic_store_n(&seen, value, __ATOMIC_SEQ_CST);
        \\}
        \\
        \\static void copy_aligned_payload(void *dst, const void *src, const CynaTypeDesc *desc) {
        \\    (void)desc;
        \\    memcpy(dst, src, sizeof(AlignedPayload));
        \\}
        \\
        \\static const CynaTypeDesc aligned_payload_desc = {
        \\    sizeof(AlignedPayload), 64, 0, copy_aligned_payload, NULL, NULL, NULL, NULL
        \\};
        \\
        \\static void aligned_worker(void *ctx) {
        \\    uintptr_t addr = (uintptr_t)ctx;
        \\    AlignedPayload *payload = (AlignedPayload *)ctx;
        \\    int ok = (addr % 64u) == 0u && payload->bytes[0] == 42u;
        \\    __atomic_store_n(&aligned_seen, ok ? 42 : 7, __ATOMIC_SEQ_CST);
        \\}
        \\
        \\int32_t call_spawn_boxed_i32(void) {
        \\    int32_t value = 42;
        \\    __atomic_store_n(&seen, 0, __ATOMIC_SEQ_CST);
        \\    CynaResultThreadThreadError spawned = cyna_std_thread_spawn_boxed(boxed_i32_worker, &value, &cyna_desc_i32);
        \\    if (spawned.is_ok != 0) return 1;
        \\    CynaThreadOpRaw joined = cyna_std_thread_join(spawned.ok);
        \\    if (not joined.settled) return 2;
        \\    return __atomic_load_n(&seen, __ATOMIC_SEQ_CST) == 42 ? 42 : 3;
        \\}
        \\
        \\int32_t call_spawn_boxed_aligned(void) {
        \\    AlignedPayload value;
        \\    memset(&value, 0, sizeof(value));
        \\    value.bytes[0] = 42u;
        \\    __atomic_store_n(&aligned_seen, 0, __ATOMIC_SEQ_CST);
        \\    CynaResultThreadThreadError spawned = cyna_std_thread_spawn_boxed(aligned_worker, &value, &aligned_payload_desc);
        \\    if (spawned.is_ok != 0) return 4;
        \\    CynaThreadOpRaw joined = cyna_std_thread_join(spawned.ok);
        \\    if (not joined.settled) return 5;
        \\    return __atomic_load_n(&aligned_seen, __ATOMIC_SEQ_CST) == 42 ? 42 : 6;
        \\}
        \\
    ;

    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCodeWithCSources(
        std.testing.allocator,
        "native_std_thread_spawn_boxed_i32.cy",
        source,
        &.{.{ .name = "spawn_boxed_i32.c", .source = c_source }},
    ));
}

test "native std.sync supports atomic and mutex basics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.sync;
            \\import { AtomicBool, AtomicI32, AtomicUsize, MemoryOrder, Mutex, SyncStatus } from std.sync;
            \\
            \\fn main(): i32 {
            \\    const order = MemoryOrder.seq_cst;
            \\    const cell = AtomicI32.init(41);
            \\    if not cell.is_valid() {
            \\        return 1;
            \\    }
            \\    if cell.load(order) != 41 {
            \\        return 2;
            \\    }
            \\    if cell.fetch_add(1, order) != 41 {
            \\        return 3;
            \\    }
            \\    if cell.load(order) != 42 {
            \\        return 4;
            \\    }
            \\    if not cell.compare_exchange(42, 7, order, MemoryOrder.acquire) {
            \\        return 5;
            \\    }
            \\    if cell.exchange(11, order) != 7 {
            \\        return 6;
            \\    }
            \\    if cell.store(42, order) != SyncStatus.ok {
            \\        return 7;
            \\    }
            \\    if cell.load(order) != 42 {
            \\        return 8;
            \\    }
            \\    if cell.deinit() != SyncStatus.ok {
            \\        return 9;
            \\    }
            \\
            \\    const index = AtomicUsize.init(40);
            \\    if not index.is_valid() {
            \\        return 20;
            \\    }
            \\    if index.load(order) != 40 {
            \\        return 21;
            \\    }
            \\    if index.fetch_add(2, order) != 40 {
            \\        return 22;
            \\    }
            \\    if index.load(order) != 42 {
            \\        return 23;
            \\    }
            \\    if not index.compare_exchange(42, 7, order, MemoryOrder.acquire) {
            \\        return 24;
            \\    }
            \\    if index.exchange(11, order) != 7 {
            \\        return 25;
            \\    }
            \\    if index.store(42, order) != SyncStatus.ok {
            \\        return 26;
            \\    }
            \\    if index.load(order) != 42 {
            \\        return 27;
            \\    }
            \\    if index.deinit() != SyncStatus.ok {
            \\        return 28;
            \\    }
            \\
            \\    const flag = AtomicBool.init(false);
            \\    if not flag.is_valid() {
            \\        return 10;
            \\    }
            \\    if flag.load(order) {
            \\        return 11;
            \\    }
            \\    if flag.store(true, order) != SyncStatus.ok {
            \\        return 12;
            \\    }
            \\    if not flag.exchange(false, order) {
            \\        return 13;
            \\    }
            \\    if not flag.compare_exchange(false, true, order, MemoryOrder.relaxed) {
            \\        return 14;
            \\    }
            \\    if flag.deinit() != SyncStatus.ok {
            \\        return 15;
            \\    }
            \\
            \\    const mutex = Mutex.init();
            \\    if not mutex.is_valid() {
            \\        return 16;
            \\    }
            \\    if mutex.try_lock() != SyncStatus.ok {
            \\        return 17;
            \\    }
            \\    if mutex.try_lock() != SyncStatus.busy {
            \\        return 18;
            \\    }
            \\    if mutex.unlock() != SyncStatus.ok {
            \\        return 19;
            \\    }
            \\    if mutex.lock() != SyncStatus.ok {
            \\        return 29;
            \\    }
            \\    if mutex.unlock() != SyncStatus.ok {
            \\        return 30;
            \\    }
            \\    if mutex.destroy() != SyncStatus.ok {
            \\        return 31;
            \\    }
            \\    return 42;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.sync condvar wakes hosted worker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\import std.sync;
            \\import { AtomicBool, Condvar, MemoryOrder, Mutex, SyncStatus } from std.sync;
            \\
            \\struct Work {
            \\    mutex: Mutex;
            \\    condvar: Condvar;
            \\    ready: AtomicBool;
            \\    done: AtomicBool;
            \\}
            \\
            \\@concurrency.isolated
            \\fn waiter(work: Work): void {
            \\    if work.mutex.lock() != SyncStatus.ok {
            \\        return;
            \\    }
            \\    const ignored_ready = work.ready.store(true, MemoryOrder.seq_cst);
            \\    const waited = work.condvar.wait(work.mutex);
            \\    if waited != SyncStatus.ok {
            \\        const ignored_unlock = work.mutex.unlock();
            \\        return;
            \\    }
            \\    const ignored_done = work.done.store(true, MemoryOrder.seq_cst);
            \\    const ignored_unlock = work.mutex.unlock();
            \\}
            \\
            \\fn main(): i32 {
            \\    const mutex = Mutex.init();
            \\    if not mutex.is_valid() {
            \\        return 1;
            \\    }
            \\    const condvar = Condvar.init();
            \\    if not condvar.is_valid() {
            \\        return 2;
            \\    }
            \\    const ready = AtomicBool.init(false);
            \\    if not ready.is_valid() {
            \\        return 3;
            \\    }
            \\    const done = AtomicBool.init(false);
            \\    if not done.is_valid() {
            \\        return 4;
            \\    }
            \\    const work = Work { mutex: mutex, condvar: condvar, ready: ready, done: done };
            \\    const handle = thread.spawn(waiter, work) catch (spawn_problem) {
            \\        const ignored = spawn_problem;
            \\        return 9;
            \\    };
            \\    while not ready.load(MemoryOrder.seq_cst) {
            \\    }
            \\    if mutex.lock() != SyncStatus.ok {
            \\        return 5;
            \\    }
            \\    if condvar.signal() != SyncStatus.ok {
            \\        return 6;
            \\    }
            \\    if mutex.unlock() != SyncStatus.ok {
            \\        return 7;
            \\    }
            \\    switch handle.join() {
            \\    .settled => {
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 8;
            \\    }
            \\    }
            \\    if not done.load(MemoryOrder.seq_cst) {
            \\        return 10;
            \\    }
            \\    if condvar.broadcast() != SyncStatus.ok {
            \\        return 11;
            \\    }
            \\    if condvar.destroy() != SyncStatus.ok {
            \\        return 12;
            \\    }
            \\    if mutex.destroy() != SyncStatus.ok {
            \\        return 13;
            \\    }
            \\    if ready.deinit() != SyncStatus.ok {
            \\        return 14;
            \\    }
            \\    if done.deinit() != SyncStatus.ok {
            \\        return 15;
            \\    }
            \\    return 42;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.thread workers share std.sync atomic handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\import std.sync;
            \\import { AtomicI32, MemoryOrder, SyncStatus } from std.sync;
            \\
            \\struct Work {
            \\    counter: AtomicI32;
            \\    amount: i32;
            \\}
            \\
            \\@concurrency.isolated
            \\fn worker(work: Work): void {
            \\    const ignored = work.counter.fetch_add(work.amount, MemoryOrder.seq_cst);
            \\}
            \\
            \\fn main(): i32 {
            \\    const counter = AtomicI32.init(0);
            \\    if not counter.is_valid() {
            \\        return 1;
            \\    }
            \\
            \\    const first = thread.spawn(worker, Work { counter: counter, amount: 10 }) catch (first_spawn_problem) {
            \\        const ignored = first_spawn_problem;
            \\        return 5;
            \\    };
            \\    const second = thread.spawn(worker, Work { counter: counter, amount: 32 }) catch (second_spawn_problem) {
            \\        const ignored = second_spawn_problem;
            \\        return 4;
            \\    };
            \\    switch first.join() {
            \\    .settled => {
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 2;
            \\    }
            \\    }
            \\    switch second.join() {
            \\    .settled => {
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 3;
            \\    }
            \\    }
            \\
            \\    const total = counter.load(MemoryOrder.seq_cst);
            \\    if counter.deinit() != SyncStatus.ok {
            \\        return 6;
            \\    }
            \\    if total != 42 {
            \\        return 7;
            \\    }
            \\    return 42;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.thread workers share std.sync atomic usize handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\import std.sync;
            \\import { AtomicUsize, MemoryOrder, SyncStatus } from std.sync;
            \\
            \\struct Work {
            \\    counter: AtomicUsize;
            \\    amount: usize;
            \\}
            \\
            \\@concurrency.isolated
            \\fn worker(work: Work): void {
            \\    const ignored = work.counter.fetch_add(work.amount, MemoryOrder.seq_cst);
            \\}
            \\
            \\fn main(): i32 {
            \\    const counter = AtomicUsize.init(0);
            \\    if not counter.is_valid() {
            \\        return 1;
            \\    }
            \\
            \\    const first = thread.spawn(worker, Work { counter: counter, amount: 10 }) catch (first_spawn_problem) {
            \\        const ignored = first_spawn_problem;
            \\        return 5;
            \\    };
            \\    const second = thread.spawn(worker, Work { counter: counter, amount: 32 }) catch (second_spawn_problem) {
            \\        const ignored = second_spawn_problem;
            \\        return 4;
            \\    };
            \\    switch first.join() {
            \\    .settled => {
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 2;
            \\    }
            \\    }
            \\    switch second.join() {
            \\    .settled => {
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 3;
            \\    }
            \\    }
            \\
            \\    const total = counter.load(MemoryOrder.seq_cst);
            \\    if counter.deinit() != SyncStatus.ok {
            \\        return 6;
            \\    }
            \\    if total != 42 {
            \\        return 7;
            \\    }
            \\    return 42;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.fs read_file strings survive list copies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const data = try compat.dirCreateFile(tmp.dir, "input.txt", .{});
        defer compat.closeFile(data);
        try compat.fileWriteAll(data, "ABC");
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ root, "input.txt" });
    defer std.testing.allocator.free(input_path);

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\import std.fs;
        \\import {{ FsError }} from std.fs;
        \\
        \\fn run(): i32!FsError {{
        \\    var values: List<string> = list<string>();
        \\    const text = try fs.read_file("{s}");
        \\    values.push(text);
        \\    const copied = values[0];
        \\    if text == "ABC" and copied == "ABC" {{
        \\        return 42;
        \\    }}
        \\    return 1;
        \\}}
        \\
        \\fn main(): i32 {{
        \\    const code = run() catch (problem) {{
        \\        const ignored = problem;
        \\        return 99;
        \\    }};
        \\    return code;
        \\}}
        \\
    , .{input_path});
    defer std.testing.allocator.free(source);

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.fs read_file strings survive set membership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const data = try compat.dirCreateFile(tmp.dir, "input.txt", .{});
        defer compat.closeFile(data);
        try compat.fileWriteAll(data, "ABC");
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ root, "input.txt" });
    defer std.testing.allocator.free(input_path);

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\import std.fs;
        \\import {{ FsError }} from std.fs;
        \\
        \\fn run(): i32!FsError {{
        \\    var names: Set<string> = set<string>();
        \\    const text = try fs.read_file("{s}");
        \\    names.add(text);
        \\    if names.contains(text) and names.contains("ABC") {{
        \\        return 42;
        \\    }}
        \\    return 1;
        \\}}
        \\
        \\fn main(): i32 {{
        \\    const code = run() catch (problem) {{
        \\        const ignored = problem;
        \\        return 99;
        \\    }};
        \\    return code;
        \\}}
        \\
    , .{input_path});
    defer std.testing.allocator.free(source);

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

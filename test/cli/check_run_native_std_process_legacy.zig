const std = @import("std");
const compat = @import("cyna").compat;

const test_exec = @import("../support.zig");

const runNativeFileExitCodeFast = test_exec.runNativeFileExitCodeFast;
const runNativeFileExitCodeWithArgv = test_exec.runNativeFileExitCodeWithArgv;

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

const std = @import("std");
const compat = @import("cyna").compat;

const test_exec = @import("../support.zig");

const runNativeFileExitCodeFast = test_exec.runNativeFileExitCodeFast;

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

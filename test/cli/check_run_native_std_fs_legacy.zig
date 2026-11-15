const std = @import("std");
const compat = @import("cyna").compat;

const test_exec = @import("../support.zig");

const runCommand = test_exec.runCommand;
const runNativeFileExitCodeFast = test_exec.runNativeFileExitCodeFast;
const runNativeFileExitCodeWithArgv = test_exec.runNativeFileExitCodeWithArgv;

test "native std.fs exists catch bridges scalar C result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var long_name: [256]u8 = undefined;
    @memset(&long_name, 'a');
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\import {{ exists }} from std.fs;
        \\fn main(): i32 {{
        \\    const present = exists(".") catch (code) => false;
        \\    const invalid = exists("{s}") catch (code) => false;
        \\    if present and not invalid {{ return 7; }}
        \\    return 1;
        \\}}
    , .{long_name});
    defer std.testing.allocator.free(source);
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);
    try std.testing.expectEqual(@as(i64, 7), try runNativeFileExitCodeFast(source_path));
}

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
        \\    try fs.create_dir(dir_path);
        \\
        \\    const list_path = owned("{s}".bytes());
        \\    const entries = try fs.read_dir(list_path);
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

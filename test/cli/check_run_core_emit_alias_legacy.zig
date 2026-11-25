const std = @import("std");
const compat = @import("cyna").compat;

const compiler = @import("cyna").compiler;
const sema = compiler.sema;
const loader = compiler.loader;
const test_exec = @import("../support.zig");

const runCommand = test_exec.runCommand;

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

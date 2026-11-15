const std = @import("std");
const compat = @import("cyna").compat;

const test_exec = @import("../support.zig");

const runCommand = test_exec.runCommand;

test "build rejects hosted std.fs import on freestanding target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const file = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
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
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "fs-demo"
            \\entry = "src/main.cy"
            \\
            \\[build]
            \\target = "aarch64-none-elf"
            \\
        );
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);

    const result = try runCommand(&.{ "zig", "build", "run", "--", "build", root });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "std.fs is not available for target") != null);
}

test "build rejects hosted std.path import on freestanding target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const file = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.path;
            \\
            \\fn main(): i32 {
            \\    return 0;
            \\}
            \\
        );
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "path-demo"
            \\entry = "src/main.cy"
            \\
            \\[build]
            \\target = "aarch64-none-elf"
            \\
        );
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);

    const result = try runCommand(&.{ "zig", "build", "run", "--", "build", root });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "std.path is not available for target") != null);
}

test "build rejects hosted std.time import on freestanding target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const file = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.time;
            \\
            \\fn main(): i32 {
            \\    return 0;
            \\}
            \\
        );
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "time-demo"
            \\entry = "src/main.cy"
            \\
            \\[build]
            \\target = "aarch64-none-elf"
            \\
        );
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);

    const result = try runCommand(&.{ "zig", "build", "run", "--", "build", root });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "std.time is not available for target") != null);
}

test "build rejects hosted std.thread import on freestanding target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const file = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\
            \\fn main(): i32 {
            \\    return 0;
            \\}
            \\
        );
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "thread-demo"
            \\entry = "src/main.cy"
            \\
            \\[build]
            \\target = "aarch64-none-elf"
            \\
        );
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);

    const result = try runCommand(&.{ "zig", "build", "run", "--", "build", root });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "std.thread is not available for target") != null);
}

test "build rejects hosted std.sync import on freestanding target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const file = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.sync;
            \\
            \\fn main(): i32 {
            \\    return 0;
            \\}
            \\
        );
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "sync-demo"
            \\entry = "src/main.cy"
            \\
            \\[build]
            \\target = "aarch64-none-elf"
            \\
        );
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);

    const result = try runCommand(&.{ "zig", "build", "run", "--", "build", root });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "std.sync is not available for target") != null);
}

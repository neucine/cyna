const std = @import("std");
const helpers = @import("check_helpers.zig");
const compat = helpers.compat;

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

    try helpers.expectCheckFailure(source_path, "join");
    try helpers.expectCheckFailure(id_source_path, "current_id_raw");
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

    try helpers.expectCheckFailure(source_path, "spawn_i32");
    try helpers.expectCheckFailure(boxed_source_path, "spawn_boxed");
    try helpers.expectCheckFailure(raw_source_path, "spawn_raw");
}

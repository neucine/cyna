const std = @import("std");
const compat = @import("compat.zig");
const build_options = @import("build_options");

pub fn relativePathFromExe(allocator: std.mem.Allocator, exe_path: []const u8, relative_path: []const u8) ![]u8 {
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.InvalidPath;
    const parent = std.fs.path.dirname(exe_dir) orelse return error.InvalidPath;
    const root = if (std.mem.eql(u8, std.fs.path.basename(exe_dir), "bin") and
        std.mem.eql(u8, std.fs.path.basename(parent), "zig-out"))
        std.fs.path.dirname(parent) orelse return error.InvalidPath
    else
        parent;
    return std.fs.path.join(allocator, &.{ root, relative_path });
}

/// An installed package directory identifies a self-contained distribution.
/// Missing inputs in that layout must not fall back to the build machine's
/// checkout and conceal an incomplete package.
pub fn sourcePathFromExe(allocator: std.mem.Allocator, exe_path: []const u8, relative_path: []const u8) ![]u8 {
    const packages = try relativePathFromExe(allocator, exe_path, "packages");
    defer allocator.free(packages);
    if (compat.access(packages, .{})) |_| {
        return relativePathFromExe(allocator, exe_path, relative_path);
    } else |err| {
        if (err != error.FileNotFound) return err;
    }
    return std.fs.path.join(allocator, &.{ build_options.source_root, relative_path });
}

pub fn sourcePath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const exe_path = try compat.executablePathAlloc(allocator);
    defer allocator.free(exe_path);
    return sourcePathFromExe(allocator, exe_path, relative_path);
}

test "installed source resolution never falls back for a missing packaged input" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "packages");
    try compat.dirMakePath(tmp.dir, "bin");
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    const exe = try std.fs.path.join(allocator, &.{ root, "bin", "cyna" });
    defer allocator.free(exe);
    const resolved = try sourcePathFromExe(allocator, exe, "src/runtime/runtime.c");
    defer allocator.free(resolved);
    const expected = try std.fs.path.join(allocator, &.{ root, "src/runtime/runtime.c" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, resolved);
    try std.testing.expectError(error.FileNotFound, compat.access(resolved, .{}));
}

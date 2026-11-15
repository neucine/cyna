const std = @import("std");
const compat = @import("../compat.zig");

pub fn cleanCommand(allocator: std.mem.Allocator, input_path: ?[]const u8) !void {
    const path = input_path orelse ".";
    if (try pathLooksLikeFile(path)) {
        try cleanFileOutputs(allocator, path);
        return;
    }
    try cleanProjectOutputs(allocator, path);
}

fn pathLooksLikeFile(path: []const u8) !bool {
    if (std.mem.endsWith(u8, path, ".cy") or std.mem.endsWith(u8, path, ".toml")) return true;

    const dir = compat.openDir(path, .{}) catch |err| switch (err) {
        error.NotDir, error.FileNotFound => return true,
        else => return err,
    };
    compat.closeDir(dir);
    return false;
}

fn cleanProjectOutputs(allocator: std.mem.Allocator, input_path: []const u8) !void {
    const root_dir = try resolveProjectRootForClean(allocator, input_path);
    defer allocator.free(root_dir);

    const build_dir = try std.fs.path.join(allocator, &.{ root_dir, "build" });
    defer allocator.free(build_dir);
    if (deleteTreeIfExists(build_dir)) {
        std.debug.print("removed {s}\n", .{build_dir});
    }

    const cache_dir = try std.fs.path.join(allocator, &.{ root_dir, ".cyna-cache" });
    defer allocator.free(cache_dir);
    if (deleteTreeIfExists(cache_dir)) {
        std.debug.print("removed {s}\n", .{cache_dir});
    }
}

fn resolveProjectRootForClean(allocator: std.mem.Allocator, input_path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, input_path, ".toml")) {
        const manifest_path = try compat.cwdRealpathAlloc(allocator, input_path);
        errdefer allocator.free(manifest_path);
        const root = std.fs.path.dirname(manifest_path) orelse ".";
        return allocator.dupe(u8, root);
    }

    const dir = compat.openDir(input_path, .{}) catch |err| switch (err) {
        error.NotDir => {
            const canonical = try compat.cwdRealpathAlloc(allocator, input_path);
            defer allocator.free(canonical);
            const root = std.fs.path.dirname(canonical) orelse ".";
            return allocator.dupe(u8, root);
        },
        error.FileNotFound => {
            if (std.mem.eql(u8, input_path, ".")) return compat.cwdRealpathAlloc(allocator, ".");
            return allocator.dupe(u8, input_path);
        },
        else => return err,
    };
    compat.closeDir(dir);
    return compat.cwdRealpathAlloc(allocator, input_path);
}

fn cleanFileOutputs(allocator: std.mem.Allocator, input_path: []const u8) !void {
    const canonical = compat.cwdRealpathAlloc(allocator, input_path) catch try allocator.dupe(u8, input_path);
    defer allocator.free(canonical);

    const base = try fileArtifactBase(allocator, canonical);
    defer allocator.free(base);

    const extensions = [_][]const u8{ ".native", ".tok", ".ast", ".sir", ".lir", ".ll", ".h", ".o", ".elf", ".bin", ".hex" };
    for (extensions) |ext| {
        const path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, ext });
        defer allocator.free(path);
        if (deleteFileIfExists(path)) {
            std.debug.print("removed {s}\n", .{path});
        }
    }
}

fn fileArtifactBase(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const stem = std.fs.path.stem(path);
    const dir = std.fs.path.dirname(path) orelse ".";
    return std.fs.path.join(allocator, &.{ dir, stem });
}

fn deleteFileIfExists(path: []const u8) bool {
    compat.access(path, .{}) catch return false;
    compat.deleteFile(path) catch return false;
    return true;
}

fn deleteTreeIfExists(path: []const u8) bool {
    compat.access(path, .{}) catch return false;
    compat.deleteTree(path) catch return deleteFileIfExists(path);
    return true;
}

test "clean removes all project cache layers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "build/output");
    try compat.dirMakePath(tmp.dir, ".cyna-cache/builds");
    try compat.dirMakePath(tmp.dir, ".cyna-cache/modules");
    try compat.dirMakePath(tmp.dir, ".cyna-cache/native-objects");
    try compat.dirMakePath(tmp.dir, ".cyna-cache/native-artifacts");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "build/output/app", .data = "artifact" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = ".cyna-cache/builds/app.meta", .data = "metadata" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = ".cyna-cache/modules/app.ll", .data = "llvm" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = ".cyna-cache/native-objects/app.o", .data = "object" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = ".cyna-cache/native-artifacts/app.native", .data = "native" });

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    try cleanCommand(std.testing.allocator, root);
    const build_path = try std.fs.path.join(std.testing.allocator, &.{ root, "build" });
    defer std.testing.allocator.free(build_path);
    const cache_path = try std.fs.path.join(std.testing.allocator, &.{ root, ".cyna-cache" });
    defer std.testing.allocator.free(cache_path);
    try std.testing.expectError(error.FileNotFound, compat.access(build_path, .{}));
    try std.testing.expectError(error.FileNotFound, compat.access(cache_path, .{}));
}

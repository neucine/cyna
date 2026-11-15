const builtin = @import("builtin");
const std = @import("std");

var runtime_io: ?std.Io = null;

pub const TempWorkspace = struct {
    path: []u8,

    pub fn cleanup(self: TempWorkspace, allocator: std.mem.Allocator) void {
        deleteTreeAbsolute(self.path) catch {};
        allocator.free(self.path);
    }
};

pub fn initRuntimeIo(io_impl: std.Io) void {
    runtime_io = io_impl;
}

pub fn io() std.Io {
    if (builtin.is_test) return std.testing.io;
    return runtime_io orelse @panic("runtime IO not initialized");
}

pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

pub fn currentPathAlloc(allocator: std.mem.Allocator) ![:0]u8 {
    return std.process.currentPathAlloc(io(), allocator);
}

pub fn executablePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = try std.process.executablePath(io(), &exe_buf);
    return allocator.dupe(u8, exe_buf[0..exe_len]);
}

pub fn cwdRealpathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
    const cwd_path = try currentPathAlloc(allocator);
    defer allocator.free(cwd_path);
    return std.fs.path.resolve(allocator, &.{ cwd_path, path });
}

pub fn relativeAlloc(allocator: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
    const cwd_path = try currentPathAlloc(allocator);
    defer allocator.free(cwd_path);
    return std.fs.path.relative(allocator, cwd_path, null, from, to);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const key_z = try allocator.dupeSentinel(u8, key, 0);
    defer allocator.free(key_z);
    const value = std.c.getenv(key_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.sliceTo(value, 0));
}

pub fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir, sub_path: []const u8) ![]u8 {
    const cwd_path = try currentPathAlloc(allocator);
    defer allocator.free(cwd_path);
    return std.fs.path.join(allocator, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path, sub_path });
}

pub fn makeTempWorkspace(allocator: std.mem.Allocator, prefix: []const u8) !TempWorkspace {
    const base = try cwdRealpathAlloc(allocator, ".zig-cache/tmp");
    defer allocator.free(base);
    try makePath(base);

    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        var random: [16]u8 = undefined;
        std.Io.random(io(), &random);
        const suffix = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, std.fmt.bytesToHex(random, .lower) });
        defer allocator.free(suffix);
        const candidate = try std.fs.path.join(allocator, &.{ base, suffix });
        errdefer allocator.free(candidate);
        std.Io.Dir.createDirAbsolute(io(), candidate, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(candidate);
                continue;
            },
            else => return err,
        };
        return .{ .path = candidate };
    }
    return error.NoSpaceLeft;
}

pub fn access(path: []const u8, options: std.Io.Dir.AccessOptions) !void {
    if (std.fs.path.isAbsolute(path)) return accessAbsolute(path, options);
    try cwd().access(io(), path, options);
}

pub fn accessAbsolute(path: []const u8, options: std.Io.Dir.AccessOptions) !void {
    const file = std.Io.Dir.openFileAbsolute(io(), path, .{}) catch |file_err| switch (file_err) {
        error.FileNotFound => return file_err,
        else => {
            const dir = std.Io.Dir.openDirAbsolute(io(), path, .{}) catch |dir_err| switch (dir_err) {
                error.FileNotFound => return dir_err,
                else => return file_err,
            };
            closeDir(dir);
            return;
        },
    };
    closeFile(file);
    _ = options;
}

pub fn openDir(path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return openDirAbsolute(path, options);
    return cwd().openDir(io(), path, options);
}

pub fn openDirAbsolute(path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    return std.Io.Dir.openDirAbsolute(io(), path, options);
}

pub fn openFile(path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) return openFileAbsolute(path, options);
    return cwd().openFile(io(), path, options);
}

pub fn openFileAbsolute(path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
    return std.Io.Dir.openFileAbsolute(io(), path, options);
}

pub fn closeDir(dir: std.Io.Dir) void {
    dir.close(io());
}

pub fn closeFile(file: std.Io.File) void {
    file.close(io());
}

pub fn fileWriteAll(file: std.Io.File, bytes: []const u8) !void {
    var writer = file.writerStreaming(io(), &.{});
    writer.interface.writeAll(bytes) catch |err| switch (err) {
        error.WriteFailed => return writer.err.?,
    };
}

pub fn dirAccess(dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.AccessOptions) !void {
    try dir.access(io(), sub_path, options);
}

pub fn walkerNext(walker: *std.Io.Dir.Walker) !?std.Io.Dir.Walker.Entry {
    return walker.next(io());
}

pub fn dirIteratorNext(iterator: *std.Io.Dir.Iterator) !?std.Io.Dir.Entry {
    return iterator.next(io());
}

pub fn createFile(path: []const u8, flags: std.Io.Dir.CreateFileOptions) !std.Io.File {
    return cwd().createFile(io(), path, flags);
}

pub fn writeFile(options: std.Io.Dir.WriteFileOptions) !void {
    try cwd().writeFile(io(), options);
}

pub fn writeTextFile(path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try makePath(parent);
    }
    const file = try createFile(path, .{ .truncate = true });
    defer closeFile(file);
    try fileWriteAll(file, text);
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        var file = try openFileAbsolute(path, .{});
        defer closeFile(file);
        var file_reader = file.reader(io(), &.{});
        return file_reader.interface.allocRemaining(allocator, .limited(limit)) catch |err| switch (err) {
            error.ReadFailed => return file_reader.err.?,
            error.OutOfMemory, error.StreamTooLong => |e| return e,
        };
    }
    return cwd().readFileAlloc(io(), path, allocator, .limited(limit));
}

pub fn makePath(path: []const u8) !void {
    var dir = try cwd().createDirPathOpen(io(), path, .{});
    dir.close(io());
}

pub fn deleteFile(path: []const u8) !void {
    try cwd().deleteFile(io(), path);
}

pub fn deleteTree(path: []const u8) !void {
    try cwd().deleteTree(io(), path);
}

pub fn deleteTreeAbsolute(path: []const u8) !void {
    try std.Io.Dir.cwd().deleteTree(io(), path);
}

pub fn renamePath(old_path: []const u8, new_path: []const u8) !void {
    try cwd().rename(old_path, cwd(), new_path, io());
}

pub fn symLink(target: []const u8, link_path: []const u8, flags: std.Io.Dir.SymLinkFlags) !void {
    try cwd().symLink(io(), target, link_path, flags);
}

pub fn runProcess(allocator: std.mem.Allocator, options: std.process.RunOptions) !std.process.RunResult {
    return std.process.run(allocator, io(), options);
}

pub fn dirMakePath(dir: std.Io.Dir, sub_path: []const u8) !void {
    var opened = try dir.createDirPathOpen(io(), sub_path, .{});
    opened.close(io());
}

pub fn dirWriteFile(dir: std.Io.Dir, options: std.Io.Dir.WriteFileOptions) !void {
    try dir.writeFile(io(), options);
}

pub fn dirCreateFile(dir: std.Io.Dir, sub_path: []const u8, flags: std.Io.Dir.CreateFileOptions) !std.Io.File {
    return dir.createFile(io(), sub_path, flags);
}

pub fn copyTreeAbsolute(from_root: []const u8, to_root: []const u8) !void {
    try makePath(to_root);

    var src_dir = try openDirAbsolute(from_root, .{ .iterate = true });
    defer closeDir(src_dir);
    var walker = try src_dir.walk(std.heap.page_allocator);
    defer walker.deinit();

    while (try walkerNext(&walker)) |entry| {
        const src_path = try std.fs.path.join(std.heap.page_allocator, &.{ from_root, entry.path });
        defer std.heap.page_allocator.free(src_path);
        const dst_path = try std.fs.path.join(std.heap.page_allocator, &.{ to_root, entry.path });
        defer std.heap.page_allocator.free(dst_path);

        switch (entry.kind) {
            .directory => try makePath(dst_path),
            .file => {
                if (std.fs.path.dirname(dst_path)) |parent| {
                    try makePath(parent);
                }
                try std.Io.Dir.copyFileAbsolute(src_path, dst_path, io(), .{});
            },
            else => {},
        }
    }
}

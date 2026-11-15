const std = @import("std");
const compat = @import("../compat.zig");

const magic = "cyna-cache-bundle-v1\n";
const digest_len = std.crypto.hash.sha2.Sha256.digest_length;

/// Metadata and the complete artifact set share one checksummed publication.
/// Names are logical roles, never destination paths supplied by the cache.
pub const Artifact = struct {
    name: []const u8,
    contents: []const u8,
    mode: u32 = 0o644,
};

pub const Entry = struct {
    bytes: []u8,
    metadata: []const u8,
    artifacts: []Artifact,

    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.artifacts);
        allocator.free(self.bytes);
    }

    pub fn artifact(self: Entry, name: []const u8) ?Artifact {
        for (self.artifacts) |item| if (std.mem.eql(u8, item.name, name)) return item;
        return null;
    }
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !?Entry {
    const bytes = compat.readFileAlloc(allocator, path, 512 * 1024 * 1024) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    errdefer allocator.free(bytes);
    const result = try decode(allocator, bytes);
    if (result == null) allocator.free(bytes);
    return result;
}

fn decode(allocator: std.mem.Allocator, bytes: []u8) !?Entry {
    if (bytes.len < magic.len + digest_len or !std.mem.startsWith(u8, bytes, magic)) return null;
    const body = bytes[0 .. bytes.len - digest_len];
    var digest: [digest_len]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[body.len..])) return null;
    var cursor = Cursor{ .bytes = body, .offset = magic.len };
    const metadata = cursor.string() orelse return null;
    const count = cursor.integer() orelse return null;
    if (count > 64) return null;
    const artifacts = try allocator.alloc(Artifact, count);
    var retained = false;
    defer if (!retained) allocator.free(artifacts);
    for (artifacts, 0..) |*item, index| {
        const name = cursor.string() orelse return null;
        if (name.len == 0 or name.len > 256) return null;
        for (artifacts[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, name)) return null;
        }
        const mode = cursor.integer() orelse return null;
        if (mode > 0o7777) return null;
        item.* = .{ .name = name, .mode = @intCast(mode), .contents = cursor.string() orelse return null };
    }
    if (cursor.offset != body.len) return null;
    retained = true;
    return .{ .bytes = bytes, .metadata = metadata, .artifacts = artifacts };
}

const Cursor = struct {
    bytes: []const u8,
    offset: usize,

    fn integer(self: *Cursor) ?usize {
        if (self.bytes.len - self.offset < 8) return null;
        const value = std.mem.readInt(u64, self.bytes[self.offset..][0..8], .little);
        self.offset += 8;
        return std.math.cast(usize, value);
    }

    fn string(self: *Cursor) ?[]const u8 {
        const len = self.integer() orelse return null;
        if (len > self.bytes.len - self.offset) return null;
        const result = self.bytes[self.offset..][0..len];
        self.offset += len;
        return result;
    }
};

fn appendInteger(allocator: std.mem.Allocator, bytes: *std.ArrayListUnmanaged(u8), value: usize) !void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    try bytes.appendSlice(allocator, &encoded);
}

fn appendString(allocator: std.mem.Allocator, bytes: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    try appendInteger(allocator, bytes, value.len);
    try bytes.appendSlice(allocator, value);
}

pub fn publish(allocator: std.mem.Allocator, path: []const u8, metadata: []const u8, artifacts: []const Artifact) !void {
    if (artifacts.len > 64) return error.InvalidCacheArtifactSet;
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, magic);
    try appendString(allocator, &bytes, metadata);
    try appendInteger(allocator, &bytes, artifacts.len);
    for (artifacts, 0..) |item, index| {
        if (item.name.len == 0 or item.name.len > 256 or item.mode > 0o7777) return error.InvalidCacheArtifactSet;
        for (artifacts[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, item.name)) return error.InvalidCacheArtifactSet;
        }
        try appendString(allocator, &bytes, item.name);
        try appendInteger(allocator, &bytes, item.mode);
        try appendString(allocator, &bytes, item.contents);
    }
    var digest: [digest_len]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes.items, &digest, .{});
    try bytes.appendSlice(allocator, &digest);
    try writeAtomic(path, bytes.items, 0o600);
}

/// Same-directory atomic replacement avoids shared .tmp names and prevents a
/// reader from observing a partial entry, even across separate processes.
pub fn writeAtomic(path: []const u8, bytes: []const u8, mode: u32) !void {
    const is_windows = @import("builtin").os.tag == .windows;
    const permissions = if (is_windows)
        std.Io.File.Permissions.default_file
    else
        std.Io.File.Permissions.fromMode(@intCast(mode));
    var file = try compat.cwd().createFileAtomic(compat.io(), path, .{
        .make_path = true,
        .replace = true,
        .permissions = permissions,
    });
    defer file.deinit(compat.io());
    if (!is_windows) try file.file.setPermissions(compat.io(), permissions);
    try compat.fileWriteAll(file.file, bytes);
    try file.file.sync(compat.io());
    try file.replace(compat.io());
}

pub fn restoreArtifact(item: Artifact, path: []const u8) !void {
    try writeAtomic(path, item.contents, item.mode);
}

test "cache bundles publish metadata artifacts and permissions together" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "entry" });
    defer allocator.free(path);
    try publish(allocator, path, "input fingerprint", &.{
        .{ .name = "primary", .contents = "executable", .mode = 0o751 },
        .{ .name = "link-metadata", .contents = "dependencies" },
    });
    const entry = (try load(allocator, path)).?;
    defer entry.deinit(allocator);
    try std.testing.expectEqualStrings("input fingerprint", entry.metadata);
    try std.testing.expectEqualStrings("executable", entry.artifact("primary").?.contents);
    try std.testing.expectEqual(@as(u32, 0o751), entry.artifact("primary").?.mode);
    try std.testing.expectEqualStrings("dependencies", entry.artifact("link-metadata").?.contents);
    const output = try std.fs.path.join(allocator, &.{ root, "absent", "output" });
    defer allocator.free(output);
    try restoreArtifact(entry.artifact("primary").?, output);
    const file = try compat.openFile(output, .{});
    defer compat.closeFile(file);
    if (@import("builtin").os.tag != .windows) {
        try std.testing.expectEqual(@as(u32, 0o751), @as(u32, @intCast((try file.stat(compat.io())).permissions.toMode())) & 0o777);
    }
    entry.bytes[entry.bytes.len - 1] ^= 1;
    try compat.writeTextFile(path, entry.bytes);
    try std.testing.expect((try load(allocator, path)) == null);
}

test "concurrent cache bundle writers never mix metadata and artifacts" {
    const allocator = std.testing.allocator;
    const Worker = struct {
        path: []const u8,
        value: []const u8,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            for (0..24) |_| {
                publish(std.testing.allocator, self.path, self.value, &.{
                    .{ .name = "primary", .contents = self.value },
                    .{ .name = "sidecar", .contents = self.value },
                }) catch |err| {
                    self.failure = err;
                    return;
                };
            }
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "concurrent.entry" });
    defer allocator.free(path);
    try publish(allocator, path, "initial", &.{
        .{ .name = "primary", .contents = "initial" },
        .{ .name = "sidecar", .contents = "initial" },
    });
    var first = Worker{ .path = path, .value = "first" };
    var second = Worker{ .path = path, .value = "second" };
    {
        const a = try std.Thread.spawn(.{}, Worker.run, .{&first});
        defer a.join();
        const b = try std.Thread.spawn(.{}, Worker.run, .{&second});
        defer b.join();
        for (0..96) |_| {
            const entry = (try load(allocator, path)) orelse continue;
            defer entry.deinit(allocator);
            try std.testing.expectEqualStrings(entry.metadata, entry.artifact("primary").?.contents);
            try std.testing.expectEqualStrings(entry.metadata, entry.artifact("sidecar").?.contents);
        }
    }
    try std.testing.expect(first.failure == null);
    try std.testing.expect(second.failure == null);
    const final = (try load(allocator, path)).?;
    defer final.deinit(allocator);
    try std.testing.expectEqualStrings(final.metadata, final.artifact("primary").?.contents);
    try std.testing.expectEqualStrings(final.metadata, final.artifact("sidecar").?.contents);
}

fn allocationRoundTrip(allocator: std.mem.Allocator, path: []const u8) !void {
    try publish(allocator, path, "metadata", &.{.{ .name = "primary", .contents = "payload" }});
    const entry = (try load(allocator, path)) orelse return error.MissingCacheEntry;
    defer entry.deinit(allocator);
    try std.testing.expectEqualStrings("payload", entry.artifact("primary").?.contents);
}

test "cache bundle allocation failures retain one owner for every buffer" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "allocation.entry" });
    defer allocator.free(path);
    try std.testing.checkAllAllocationFailures(allocator, allocationRoundTrip, .{path});
}

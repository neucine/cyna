const std = @import("std");

pub const SourceId = enum(u32) { _ };

pub const Source = struct {
    path: []const u8,
    text: []const u8,
};

pub const Line = struct {
    number: usize,
    start: usize,
    end: usize,
    text: []const u8,
};

/// Request-owned source text used by diagnostic presentation adapters.
///
/// The registry deliberately does not read files. Callers decide whether the
/// authoritative text comes from disk, an editor overlay, generated input, or
/// another source provider.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    sources: std.ArrayListUnmanaged(Source) = .empty,
    by_path: std.StringHashMapUnmanaged(SourceId) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.by_path.deinit(self.allocator);
        for (self.sources.items) |source| {
            self.allocator.free(source.path);
            self.allocator.free(source.text);
        }
        self.sources.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *Registry, path: []const u8, text: []const u8) !SourceId {
        if (self.by_path.contains(path)) return error.DuplicateSource;

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        const id: SourceId = @fromBackingInt(@intCast(@as(u32, @intCast(self.sources.items.len))));
        try self.sources.append(self.allocator, .{
            .path = owned_path,
            .text = owned_text,
        });
        errdefer _ = self.sources.pop();
        try self.by_path.put(self.allocator, owned_path, id);
        return id;
    }

    pub fn find(self: *const Registry, path: []const u8) ?SourceId {
        return self.by_path.get(path);
    }

    pub fn get(self: *const Registry, id: SourceId) ?*const Source {
        const index: usize = @backingInt(id);
        if (index >= self.sources.items.len) return null;
        return &self.sources.items[index];
    }

    pub fn sourceForPath(self: *const Registry, path: []const u8) ?*const Source {
        return self.get(self.find(path) orelse return null);
    }

    pub fn lineAt(self: *const Registry, id: SourceId, offset: usize) ?Line {
        const source = self.get(id) orelse return null;
        if (offset > source.text.len) return null;

        var line_number: usize = 1;
        var line_start: usize = 0;
        var index: usize = 0;
        while (index < offset) : (index += 1) {
            if (source.text[index] == '\n') {
                line_number += 1;
                line_start = index + 1;
            }
        }

        var line_end = offset;
        while (line_end < source.text.len and source.text[line_end] != '\n') : (line_end += 1) {}
        if (line_end > line_start and source.text[line_end - 1] == '\r') line_end -= 1;

        return .{
            .number = line_number,
            .start = line_start,
            .end = line_end,
            .text = source.text[line_start..line_end],
        };
    }
};

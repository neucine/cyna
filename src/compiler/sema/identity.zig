const std = @import("std");

pub const SourceId = enum(u32) { _ };
pub const ModuleId = enum(u32) { _ };
pub const DeclId = enum(u32) { _ };
pub const BindingId = enum(u64) { _ };
pub const TemporaryId = enum(u64) { _ };
pub const GenericScopeId = enum(u32) { _ };
pub const GenericParamId = struct { scope: GenericScopeId, ordinal: u32 };

pub const DeclKind = enum {
    global,
    function,
    type_alias,
    @"enum",
    @"union",
    protocol,
    protocol_method,
    @"struct",
};

pub const Source = struct {
    path: []const u8,
};

pub const Module = struct {
    source: SourceId,
    name: []const u8,
};

pub const Decl = struct {
    module: ModuleId,
    owner: ?[]const u8,
    name: []const u8,
    kind: DeclKind,
};

pub const RegisterError = error{
    DuplicateSource,
    DuplicateModule,
    DuplicateDecl,
    InvalidSource,
    InvalidModule,
    OutOfMemory,
};

/// Compilation-owned identity registry. Text is used only at its registration
/// and source-lookup boundary; successful resolution returns compact IDs.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    sources: std.ArrayListUnmanaged(Source) = .empty,
    modules: std.ArrayListUnmanaged(Module) = .empty,
    decls: std.ArrayListUnmanaged(Decl) = .empty,
    source_by_path: std.StringHashMapUnmanaged(SourceId) = .empty,
    module_by_name: std.StringHashMapUnmanaged(ModuleId) = .empty,
    decl_by_key: std.StringHashMapUnmanaged(DeclId) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.sources.items) |source_record| self.allocator.free(source_record.path);
        for (self.modules.items) |module_record| self.allocator.free(module_record.name);
        for (self.decls.items) |decl_record| {
            if (decl_record.owner) |owner| self.allocator.free(owner);
            self.allocator.free(decl_record.name);
        }
        var keys = self.decl_by_key.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.source_by_path.deinit(self.allocator);
        self.module_by_name.deinit(self.allocator);
        self.decl_by_key.deinit(self.allocator);
        self.sources.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.decls.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn registerSource(self: *Registry, path: []const u8) RegisterError!SourceId {
        if (self.source_by_path.contains(path)) return error.DuplicateSource;
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const id: SourceId = @fromBackingInt(@intCast(@as(u32, @intCast(self.sources.items.len))));
        try self.sources.append(self.allocator, .{ .path = owned_path });
        errdefer _ = self.sources.pop();
        try self.source_by_path.put(self.allocator, owned_path, id);
        return id;
    }

    pub fn registerModule(self: *Registry, source_id: SourceId, name: []const u8) RegisterError!ModuleId {
        if (self.source(source_id) == null) return error.InvalidSource;
        if (self.module_by_name.contains(name)) return error.DuplicateModule;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const id: ModuleId = @fromBackingInt(@intCast(@as(u32, @intCast(self.modules.items.len))));
        try self.modules.append(self.allocator, .{ .source = source_id, .name = owned_name });
        errdefer _ = self.modules.pop();
        try self.module_by_name.put(self.allocator, owned_name, id);
        return id;
    }

    pub fn registerDecl(
        self: *Registry,
        module_id: ModuleId,
        owner: ?[]const u8,
        name: []const u8,
        kind: DeclKind,
    ) RegisterError!DeclId {
        if (self.module(module_id) == null) return error.InvalidModule;
        const key = try declKey(self.allocator, module_id, owner, name, kind);
        errdefer self.allocator.free(key);
        if (self.decl_by_key.contains(key)) return error.DuplicateDecl;

        const owned_owner = if (owner) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_owner) |value| self.allocator.free(value);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const id: DeclId = @fromBackingInt(@intCast(@as(u32, @intCast(self.decls.items.len))));
        try self.decls.append(self.allocator, .{
            .module = module_id,
            .owner = owned_owner,
            .name = owned_name,
            .kind = kind,
        });
        errdefer _ = self.decls.pop();
        try self.decl_by_key.put(self.allocator, key, id);
        return id;
    }

    pub fn source(self: *const Registry, id: SourceId) ?*const Source {
        const index: usize = @backingInt(id);
        if (index >= self.sources.items.len) return null;
        return &self.sources.items[index];
    }

    pub fn module(self: *const Registry, id: ModuleId) ?*const Module {
        const index: usize = @backingInt(id);
        if (index >= self.modules.items.len) return null;
        return &self.modules.items[index];
    }

    pub fn decl(self: *const Registry, id: DeclId) ?*const Decl {
        const index: usize = @backingInt(id);
        if (index >= self.decls.items.len) return null;
        return &self.decls.items[index];
    }

    pub fn findSource(self: *const Registry, path: []const u8) ?SourceId {
        return self.source_by_path.get(path);
    }

    pub fn findModule(self: *const Registry, name: []const u8) ?ModuleId {
        return self.module_by_name.get(name);
    }

    pub fn findDecl(
        self: *const Registry,
        module_id: ModuleId,
        owner: ?[]const u8,
        name: []const u8,
        kind: DeclKind,
    ) !?DeclId {
        return self.decl_by_key.getAdapted(DeclQuery{ .module = module_id, .owner = owner orelse "", .name = name, .kind = kind }, DeclQueryContext{});
    }
};

const DeclQuery = struct { module: ModuleId, owner: []const u8, name: []const u8, kind: DeclKind };

/// Adapted lookup hashes the exact registration key without allocating it.
/// Optional lookup must not turn a failed temporary allocation into absence.
const DeclQueryContext = struct {
    pub fn hash(_: @This(), query: DeclQuery) u64 {
        var prefix_buffer: [128]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buffer, "{d}:{s}:{d}:", .{ @backingInt(query.module), @tagName(query.kind), query.owner.len }) catch unreachable;
        var suffix_buffer: [64]u8 = undefined;
        const suffix = std.fmt.bufPrint(&suffix_buffer, ":{d}:", .{query.name.len}) catch unreachable;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(prefix);
        hasher.update(query.owner);
        hasher.update(suffix);
        hasher.update(query.name);
        return hasher.final();
    }

    pub fn eql(_: @This(), query: DeclQuery, key: []const u8) bool {
        var prefix_buffer: [128]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buffer, "{d}:{s}:{d}:", .{ @backingInt(query.module), @tagName(query.kind), query.owner.len }) catch unreachable;
        if (!std.mem.startsWith(u8, key, prefix)) return false;
        var remaining = key[prefix.len..];
        if (!std.mem.startsWith(u8, remaining, query.owner)) return false;
        remaining = remaining[query.owner.len..];
        var suffix_buffer: [64]u8 = undefined;
        const suffix = std.fmt.bufPrint(&suffix_buffer, ":{d}:", .{query.name.len}) catch unreachable;
        if (!std.mem.startsWith(u8, remaining, suffix)) return false;
        return std.mem.eql(u8, remaining[suffix.len..], query.name);
    }
};

fn declKey(
    allocator: std.mem.Allocator,
    module: ModuleId,
    owner: ?[]const u8,
    name: []const u8,
    kind: DeclKind,
) ![]u8 {
    const owner_text = owner orelse "";
    return std.fmt.allocPrint(
        allocator,
        "{d}:{s}:{d}:{s}:{d}:{s}",
        .{ @backingInt(module), @tagName(kind), owner_text.len, owner_text, name.len, name },
    );
}

test "declaration adapted lookup matches framed registration keys without allocation" {
    const allocator = std.testing.allocator;
    for ([_]usize{ 0, 1, 16, 32, 48, 63, 64, 100, 1024 }) |len| {
        const owner = try allocator.alloc(u8, len);
        defer allocator.free(owner);
        @memset(owner, ':');
        const query = DeclQuery{ .module = @fromBackingInt(@intCast(123)), .owner = owner, .name = "name::λ", .kind = .function };
        const key = try declKey(allocator, query.module, query.owner, query.name, query.kind);
        defer allocator.free(key);
        try std.testing.expectEqual(std.hash.Wyhash.hash(0, key), (DeclQueryContext{}).hash(query));
        try std.testing.expect((DeclQueryContext{}).eql(query, key));
    }
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var registry = Registry.init(failing.allocator());
    defer registry.deinit();
    const source = try registry.registerSource("main.cy");
    const module = try registry.registerModule(source, "main");
    const decl = try registry.registerDecl(module, "owner::λ", "run", .function);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectEqual(decl, (try registry.findDecl(module, "owner::λ", "run", .function)).?);
    try std.testing.expect((try registry.findDecl(module, "owner::λ", "missing", .function)) == null);
    try std.testing.expect(!failing.has_induced_failure);
}

test "registry assigns distinct declaration identity across module and owner scopes" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const source_a = try registry.registerSource("a.cy");
    const source_b = try registry.registerSource("b.cy");
    const module_a = try registry.registerModule(source_a, "a");
    const module_b = try registry.registerModule(source_b, "b");

    const a_value = try registry.registerDecl(module_a, null, "value", .global);
    const b_value = try registry.registerDecl(module_b, null, "value", .global);
    const method = try registry.registerDecl(module_a, "Thing", "value", .function);

    try std.testing.expect(a_value != b_value);
    try std.testing.expect(a_value != method);
    try std.testing.expectEqual(a_value, (try registry.findDecl(module_a, null, "value", .global)).?);
    try std.testing.expectEqual(b_value, (try registry.findDecl(module_b, null, "value", .global)).?);
    try std.testing.expectEqual(method, (try registry.findDecl(module_a, "Thing", "value", .function)).?);
}

test "registry rejects duplicates and invalid parents" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const source = try registry.registerSource("main.cy");
    try std.testing.expectError(error.DuplicateSource, registry.registerSource("main.cy"));
    const module = try registry.registerModule(source, "main");
    try std.testing.expectError(error.DuplicateModule, registry.registerModule(source, "main"));
    _ = try registry.registerDecl(module, null, "run", .function);
    try std.testing.expectError(error.DuplicateDecl, registry.registerDecl(module, null, "run", .function));

    const invalid_source: SourceId = @fromBackingInt(@intCast(99));
    const invalid_module: ModuleId = @fromBackingInt(@intCast(99));
    try std.testing.expectError(error.InvalidSource, registry.registerModule(invalid_source, "bad"));
    try std.testing.expectError(error.InvalidModule, registry.registerDecl(invalid_module, null, "bad", .global));
}

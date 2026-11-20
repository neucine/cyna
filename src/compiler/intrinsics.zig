const std = @import("std");
const ast = @import("parser/ast.zig");

/// Stable compiler identity for language surfaces and compiler-known package
/// contracts. Source spellings are resolved here once; downstream phases
/// should carry `Id` rather than repeat textual comparisons.
pub const Id = enum {
    builtin_print,
    builtin_println,
    builtin_assert,
    /// Compare the values behind two immutable borrows. Declared explicitly
    /// by compiler-owned core source as `@intrinsic("value.eq")`.
    value_eq,
    string_from,
    std_sync_share,
    std_own_arc,
    std_thread_spawn,
    embedded_task_spawn,
    std_sync_share_boxed,
    std_own_arc_new_boxed,
    std_thread_spawn_boxed,
    std_task_group_spawn_impl,
    std_task_group_spawn_context_impl,
    std_task_context_spawn_impl,
    std_task_group_spawn_boxed,
    std_task_context_spawn_boxed,
    std_task_result_take_impl,
    string_len,
    string_is_empty,
    string_bytes,
    string_starts_with,
    string_ends_with,
    string_contains,
    string_find,
    string_rfind,
    string_slice,
    sequence_len,
    sequence_clone,
    sequence_clear,
    sequence_push,
    sequence_reserve,
    sequence_pop,
    sparse_len,
    sparse_clear,
    sparse_contains_index,
    sparse_indices,
    sparse_insert,
    sparse_take,
    slice_len,
    owned_ptr,
    owned_leak,
    resource_leak,
    resource_from_raw,
    syntax_index,
    syntax_index_set,
    syntax_iter,
    syntax_iter_has_next,
    syntax_iter_next,
    syntax_iter_item,
    std_own_arc_type,
};

pub const Category = enum {
    language_builtin,
    compiler_primitive,
    standard_library,
    embedded_contract,
    hosted_primitive,
    receiver_method,
    language_syntax,
    standard_type,
};

pub const Receiver = enum {
    string,
    sequence,
    sparse,
    slice,
    owned,
};

pub const Definition = struct {
    id: Id,
    category: Category,
    module_name: ?[]const u8 = null,
    owner: ?[]const u8 = null,
    name: []const u8,
    receiver: ?Receiver = null,
    mutates_receiver: bool = false,
};

pub const definitions = [_]Definition{
    .{ .id = .builtin_print, .category = .language_builtin, .name = "print" },
    .{ .id = .builtin_println, .category = .language_builtin, .name = "println" },
    .{ .id = .builtin_assert, .category = .language_builtin, .name = "assert" },
    .{ .id = .value_eq, .category = .compiler_primitive, .name = "value.eq" },
    .{ .id = .string_from, .category = .language_builtin, .owner = "string", .name = "from" },
    .{ .id = .std_sync_share, .category = .standard_library, .module_name = "std.sync", .name = "share" },
    .{ .id = .std_own_arc, .category = .standard_library, .module_name = "std.own", .name = "arc" },
    .{ .id = .std_thread_spawn, .category = .standard_library, .module_name = "std.thread", .name = "spawn" },
    .{ .id = .embedded_task_spawn, .category = .embedded_contract, .module_name = "embedded.task", .name = "spawn" },
    .{ .id = .std_sync_share_boxed, .category = .hosted_primitive, .module_name = "std.sync", .name = "share_boxed" },
    .{ .id = .std_own_arc_new_boxed, .category = .hosted_primitive, .module_name = "std.own", .name = "arc_new_boxed" },
    .{ .id = .std_thread_spawn_boxed, .category = .hosted_primitive, .module_name = "std.thread", .name = "spawn_boxed" },
    .{ .id = .std_task_group_spawn_impl, .category = .hosted_primitive, .module_name = "std.thread", .name = "group_spawn_impl" },
    .{ .id = .std_task_group_spawn_context_impl, .category = .hosted_primitive, .module_name = "std.thread", .name = "group_spawn_context_impl" },
    .{ .id = .std_task_context_spawn_impl, .category = .hosted_primitive, .module_name = "std.thread", .name = "task_context_spawn_impl" },
    .{ .id = .std_task_group_spawn_boxed, .category = .hosted_primitive, .module_name = "std.thread", .name = "task_group_spawn_boxed" },
    .{ .id = .std_task_context_spawn_boxed, .category = .hosted_primitive, .module_name = "std.thread", .name = "task_context_spawn_boxed" },
    .{ .id = .std_task_result_take_impl, .category = .hosted_primitive, .module_name = "std.thread", .name = "task_result_take_impl" },
    .{ .id = .string_len, .category = .receiver_method, .name = "len", .receiver = .string },
    .{ .id = .string_is_empty, .category = .receiver_method, .name = "is_empty", .receiver = .string },
    .{ .id = .string_bytes, .category = .receiver_method, .name = "bytes", .receiver = .string },
    .{ .id = .string_starts_with, .category = .receiver_method, .name = "starts_with", .receiver = .string },
    .{ .id = .string_ends_with, .category = .receiver_method, .name = "ends_with", .receiver = .string },
    .{ .id = .string_contains, .category = .receiver_method, .name = "contains", .receiver = .string },
    .{ .id = .string_find, .category = .receiver_method, .name = "find", .receiver = .string },
    .{ .id = .string_rfind, .category = .receiver_method, .name = "rfind", .receiver = .string },
    .{ .id = .string_slice, .category = .receiver_method, .name = "slice", .receiver = .string },
    .{ .id = .sequence_len, .category = .receiver_method, .name = "len", .receiver = .sequence },
    .{ .id = .sequence_clone, .category = .receiver_method, .name = "clone", .receiver = .sequence },
    .{ .id = .sequence_clear, .category = .receiver_method, .name = "clear", .receiver = .sequence, .mutates_receiver = true },
    .{ .id = .sequence_push, .category = .receiver_method, .name = "push", .receiver = .sequence, .mutates_receiver = true },
    .{ .id = .sequence_reserve, .category = .receiver_method, .name = "reserve", .receiver = .sequence, .mutates_receiver = true },
    .{ .id = .sequence_pop, .category = .receiver_method, .name = "pop", .receiver = .sequence, .mutates_receiver = true },
    .{ .id = .sparse_len, .category = .receiver_method, .name = "len", .receiver = .sparse },
    .{ .id = .sparse_clear, .category = .receiver_method, .name = "clear", .receiver = .sparse, .mutates_receiver = true },
    .{ .id = .sparse_contains_index, .category = .receiver_method, .name = "contains_index", .receiver = .sparse },
    .{ .id = .sparse_indices, .category = .receiver_method, .name = "indices", .receiver = .sparse },
    .{ .id = .sparse_insert, .category = .receiver_method, .name = "insert", .receiver = .sparse, .mutates_receiver = true },
    .{ .id = .sparse_take, .category = .receiver_method, .name = "take", .receiver = .sparse, .mutates_receiver = true },
    .{ .id = .slice_len, .category = .receiver_method, .name = "len", .receiver = .slice },
    .{ .id = .owned_ptr, .category = .receiver_method, .name = "ptr", .receiver = .owned },
    .{ .id = .owned_leak, .category = .receiver_method, .name = "leak", .receiver = .owned, .mutates_receiver = true },
    .{ .id = .resource_leak, .category = .language_builtin, .owner = "resource", .name = "leak", .mutates_receiver = true },
    .{ .id = .resource_from_raw, .category = .language_builtin, .owner = "resource", .name = "from_raw" },
    .{ .id = .syntax_index, .category = .language_syntax, .name = "index" },
    .{ .id = .syntax_index_set, .category = .language_syntax, .name = "index_set", .mutates_receiver = true },
    .{ .id = .syntax_iter, .category = .language_syntax, .name = "iter" },
    .{ .id = .syntax_iter_has_next, .category = .language_syntax, .name = "iter_has_next" },
    .{ .id = .syntax_iter_next, .category = .language_syntax, .name = "iter_next", .mutates_receiver = true },
    .{ .id = .syntax_iter_item, .category = .language_syntax, .name = "iter_item" },
    .{ .id = .std_own_arc_type, .category = .standard_type, .module_name = "std.own", .name = "Arc" },
};

comptime {
    @setEvalBranchQuota(10_000);
    if (definitions.len != @typeInfo(Id).@"enum".field_names.len) {
        @compileError("intrinsic registry must define every Id exactly once");
    }
    for (definitions, 0..) |candidate, i| {
        if (@backingInt(candidate.id) != i) {
            @compileError("intrinsic registry definitions must follow Id order");
        }
        for (definitions[i + 1 ..]) |other| {
            if (candidate.module_name != null and
                other.module_name != null and
                optionalEql(candidate.module_name, other.module_name) and
                optionalEql(candidate.owner, other.owner) and
                std.mem.eql(u8, candidate.name, other.name))
            {
                @compileError("intrinsic registry contains a duplicate declaration key");
            }
            if (candidate.receiver != null and other.receiver != null and
                candidate.receiver == other.receiver and
                std.mem.eql(u8, candidate.name, other.name))
            {
                @compileError("intrinsic registry contains a duplicate receiver method");
            }
            if (candidate.receiver == null and other.receiver == null and
                candidate.category != .language_syntax and
                other.category != .language_syntax and
                candidate.category != .hosted_primitive and
                other.category != .hosted_primitive and
                optionalEql(callOwner(candidate), callOwner(other)) and
                std.mem.eql(u8, candidate.name, other.name))
            {
                @compileError("intrinsic registry contains an ambiguous call surface");
            }
        }
    }
}

pub fn definition(id: Id) Definition {
    return definitions[@backingInt(id)];
}

/// Resolve an AST call surface. A qualified namespace call uses its source
/// owner as the module name for package contracts.
pub fn resolveCall(owner: ?[]const u8, name: []const u8) ?Id {
    for (definitions) |candidate| {
        if (candidate.receiver != null) continue;
        if (candidate.category == .language_syntax) continue;
        if (candidate.category == .standard_type) continue;
        if (candidate.category == .hosted_primitive) continue;
        if (!optionalEql(owner, callOwner(candidate))) continue;
        if (std.mem.eql(u8, name, candidate.name)) return candidate.id;
    }
    return null;
}

pub fn resolveSyntaxRole(role: ?ast.SyntaxRole) ?Id {
    return switch (role orelse return null) {
        .index => .syntax_index,
        .index_set => .syntax_index_set,
        .iter => .syntax_iter,
        .iter_has_next => .syntax_iter_has_next,
        .iter_next => .syntax_iter_next,
        .iter_item => .syntax_iter_item,
    };
}

/// Resolve the stable identifier written in an explicit `@intrinsic`
/// declaration. This deliberately does not resolve ordinary call spellings.
pub fn resolveExplicit(name: []const u8) ?Id {
    for (definitions) |candidate| {
        if (candidate.category != .compiler_primitive) continue;
        if (std.mem.eql(u8, name, candidate.name)) return candidate.id;
    }
    return null;
}

pub fn resolveMethod(receiver: Receiver, name: []const u8) ?Id {
    for (definitions) |candidate| {
        if (candidate.receiver != receiver) continue;
        if (std.mem.eql(u8, name, candidate.name)) return candidate.id;
    }
    return null;
}

pub fn mutatesReceiver(id: Id) bool {
    return definition(id).mutates_receiver;
}

pub const ModuleCapability = enum {
    declare_concurrency_shareable,
    trusted_isolated_extern,
    trusted_internal_abi,
};

pub fn moduleHasCapability(module_name: []const u8, capability: ModuleCapability) bool {
    return switch (capability) {
        .declare_concurrency_shareable => moduleInNamespace(module_name, "std") or moduleInNamespace(module_name, "core"),
        .trusted_isolated_extern => std.mem.eql(u8, module_name, "std.sync"),
        .trusted_internal_abi => moduleInNamespace(module_name, "std"),
    };
}

fn moduleInNamespace(module_name: []const u8, namespace: []const u8) bool {
    if (std.mem.eql(u8, module_name, namespace)) return true;
    return module_name.len > namespace.len and
        std.mem.startsWith(u8, module_name, namespace) and
        module_name[namespace.len] == '.';
}

/// Resolve an already-bound declaration. This is the authoritative lookup
/// after ordinary name resolution has established the declaration owner.
pub fn resolveDeclaration(module_name: []const u8, owner: ?[]const u8, name: []const u8) ?Id {
    for (definitions) |candidate| {
        const candidate_module = candidate.module_name orelse continue;
        if (!std.mem.eql(u8, module_name, candidate_module)) continue;
        if (!optionalEql(owner, candidate.owner)) continue;
        if (std.mem.eql(u8, name, candidate.name)) return candidate.id;
    }
    return null;
}

pub fn isPrint(id: Id) bool {
    return id == .builtin_print or id == .builtin_println;
}

pub fn displayName(id: Id) []const u8 {
    const candidate = definition(id);
    return candidate.name;
}

fn callOwner(candidate: Definition) ?[]const u8 {
    return candidate.owner orelse candidate.module_name;
}

fn optionalEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

test "registry covers every intrinsic identity exactly once" {
    try std.testing.expectEqual(@typeInfo(Id).@"enum".field_names.len, definitions.len);
    for (definitions, 0..) |candidate, i| {
        try std.testing.expectEqual(i, @backingInt(candidate.id));
        for (definitions[i + 1 ..]) |other| {
            try std.testing.expect(candidate.id != other.id);
            try std.testing.expect(
                candidate.receiver != null or
                    other.receiver != null or
                    candidate.category == .language_syntax or
                    other.category == .language_syntax or
                    !optionalEql(callOwner(candidate), callOwner(other)) or
                    !std.mem.eql(u8, candidate.name, other.name) or
                    candidate.category == .hosted_primitive or
                    other.category == .hosted_primitive,
            );
        }
    }
}

test "call resolution distinguishes language and package contracts" {
    try std.testing.expectEqual(Id.builtin_print, resolveCall(null, "print").?);
    try std.testing.expectEqual(Id.builtin_println, resolveCall(null, "println").?);
    try std.testing.expectEqual(Id.builtin_assert, resolveCall(null, "assert").?);
    try std.testing.expectEqual(Id.string_from, resolveCall("string", "from").?);
    try std.testing.expectEqual(Id.std_thread_spawn, resolveCall("std.thread", "spawn").?);
    try std.testing.expectEqual(Id.embedded_task_spawn, resolveCall("embedded.task", "spawn").?);
    try std.testing.expect(resolveCall("app.worker", "spawn") == null);
    try std.testing.expect(resolveCall(null, "spawn") == null);
}

test "declaration resolution includes hosted primitives" {
    try std.testing.expectEqual(Id.std_sync_share, resolveDeclaration("std.sync", null, "share").?);
    try std.testing.expectEqual(Id.std_sync_share_boxed, resolveDeclaration("std.sync", null, "share_boxed").?);
    try std.testing.expectEqual(Id.std_own_arc_new_boxed, resolveDeclaration("std.own", null, "arc_new_boxed").?);
    try std.testing.expectEqual(Id.std_thread_spawn_boxed, resolveDeclaration("std.thread", null, "spawn_boxed").?);
    try std.testing.expect(resolveDeclaration("app.sync", null, "share") == null);
}

test "receiver method resolution is typed" {
    try std.testing.expectEqual(Id.string_len, resolveMethod(.string, "len").?);
    try std.testing.expect(resolveMethod(.string, "clone") == null);
    try std.testing.expectEqual(Id.sequence_len, resolveMethod(.sequence, "len").?);
    try std.testing.expectEqual(Id.sequence_clone, resolveMethod(.sequence, "clone").?);
    try std.testing.expectEqual(Id.sparse_len, resolveMethod(.sparse, "len").?);
    try std.testing.expectEqual(Id.slice_len, resolveMethod(.slice, "len").?);
    try std.testing.expectEqual(Id.owned_leak, resolveMethod(.owned, "leak").?);
    try std.testing.expectEqual(Id.resource_leak, resolveCall("resource", "leak").?);
    try std.testing.expectEqual(Id.resource_from_raw, resolveCall("resource", "from_raw").?);
    try std.testing.expect(resolveMethod(.string, "push") == null);
    try std.testing.expect(mutatesReceiver(.sequence_push));
    try std.testing.expect(!mutatesReceiver(.string_bytes));
}

test "syntax roles and module capabilities are centralized" {
    try std.testing.expectEqual(Id.syntax_index_set, resolveSyntaxRole(.index_set).?);
    try std.testing.expect(resolveSyntaxRole(null) == null);
    try std.testing.expect(moduleHasCapability("std.sync", .trusted_isolated_extern));
    try std.testing.expect(!moduleHasCapability("std.thread", .trusted_isolated_extern));
    try std.testing.expect(moduleHasCapability("core.alloc", .declare_concurrency_shareable));
}

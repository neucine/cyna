const type_resolution = @import("type_resolution.zig");
const std = @import("std");
const intrinsics = @import("../intrinsics.zig");
const lexer = @import("../lexer/lexer.zig");
const ast = @import("../parser/ast.zig");
const identity = @import("identity.zig");
const semantic_types = @import("types.zig");
const sir = @import("sir.zig");
const generated_names = @import("../generated_names.zig");
const declaration_owner = @import("declarations.zig");

/// Trusted declaration identities for the hosted owned-input concurrency
/// slice. The checker and lowering use resolved identities; this table is not
/// authority for arbitrary user declarations with matching spellings.
pub const Effect = enum {
    must_settle_owner,
    affine_result_interest,
    unique_handle,
    spawn_owned,
    terminal_finish,
    terminal_cancel_and_wait,
    request_cancel,
    join_result,
    poll_result,
};

pub const Declaration = struct {
    module_name: []const u8,
    owner: ?[]const u8,
    name: []const u8,
    effect: Effect,
};

pub const declarations = [_]Declaration{
    .{ .module_name = "std.thread", .owner = null, .name = "TaskGroup", .effect = .must_settle_owner },
    .{ .module_name = "std.thread", .owner = null, .name = "Task", .effect = .affine_result_interest },
    .{ .module_name = "std.thread", .owner = null, .name = "Thread", .effect = .unique_handle },
    .{ .module_name = "std.thread", .owner = "TaskGroup", .name = "spawn", .effect = .spawn_owned },
    .{ .module_name = "std.thread", .owner = "TaskGroup", .name = "spawn_context", .effect = .spawn_owned },
    .{ .module_name = "std.thread", .owner = "TaskContext", .name = "spawn", .effect = .spawn_owned },
    .{ .module_name = "std.thread", .owner = "TaskGroup", .name = "finish", .effect = .terminal_finish },
    .{ .module_name = "std.thread", .owner = "TaskGroup", .name = "cancel_and_wait", .effect = .terminal_cancel_and_wait },
    .{ .module_name = "std.thread", .owner = "Task", .name = "cancel", .effect = .request_cancel },
    .{ .module_name = "std.thread", .owner = "Task", .name = "join", .effect = .join_result },
    .{ .module_name = "std.thread", .owner = "Task", .name = "try_join", .effect = .poll_result },
};

/// Call only after ordinary name resolution has bound the declaration. Text at
/// a call site is insufficient authority, even for an imported alias.
pub fn resolveDeclaration(module_name: []const u8, owner: ?[]const u8, name: []const u8) ?Effect {
    for (declarations) |declaration| {
        if (!std.mem.eql(u8, module_name, declaration.module_name)) continue;
        if (!optionalEql(owner, declaration.owner)) continue;
        if (std.mem.eql(u8, name, declaration.name)) return declaration.effect;
    }
    return null;
}

pub fn dischargesGroup(effect: Effect) bool {
    return effect == .terminal_finish or effect == .terminal_cancel_and_wait;
}

fn optionalEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

test "trusted concurrency contracts require resolved declaration identity" {
    try std.testing.expectEqual(Effect.must_settle_owner, resolveDeclaration("std.thread", null, "TaskGroup").?);
    try std.testing.expectEqual(Effect.affine_result_interest, resolveDeclaration("std.thread", null, "Task").?);
    try std.testing.expectEqual(Effect.spawn_owned, resolveDeclaration("std.thread", "TaskGroup", "spawn").?);
    try std.testing.expectEqual(Effect.terminal_finish, resolveDeclaration("std.thread", "TaskGroup", "finish").?);
    try std.testing.expectEqual(Effect.join_result, resolveDeclaration("std.thread", "Task", "join").?);
    try std.testing.expect(resolveDeclaration("app.thread", "TaskGroup", "finish") == null);
    try std.testing.expect(resolveDeclaration("std.thread", "OtherGroup", "finish") == null);
    try std.testing.expect(resolveDeclaration("std.thread", null, "finish") == null);
}

test "only terminal group operations discharge settlement" {
    for (declarations) |declaration| {
        const expected = declaration.effect == .terminal_finish or declaration.effect == .terminal_cancel_and_wait;
        try std.testing.expectEqual(expected, dischargesGroup(declaration.effect));
    }
}

/// The caller supplies an already resolved declaration. Names at a call site
/// are never sufficient to grant the trusted concurrency contract.
pub fn isOwnedSpawnMethod(module_name: []const u8, owner: ?[]const u8, name: []const u8) bool {
    return resolveDeclaration(module_name, owner, name) == .spawn_owned;
}

pub fn isTrustedResource(registry: *const identity.Registry, decl_id: identity.DeclId) bool {
    const decl = registry.decl(decl_id) orelse return false;
    if (decl.kind != .@"struct") return false;
    const module = registry.module(decl.module) orelse return false;
    return switch (resolveDeclaration(module.name, decl.owner, decl.name) orelse return false) {
        .must_settle_owner, .affine_result_interest, .unique_handle => true,
        else => false,
    };
}

pub fn isTrustedIsolatedExtern(callee: ast.Function) bool {
    if (!callee.is_extern) return false;
    if (callee.is_concurrency_trusted_extern) return true;
    return intrinsics.moduleHasCapability(callee.module_name, .trusted_isolated_extern);
}

pub fn payloadKind(ty: *const semantic_types.Type) PayloadKind {
    return switch (ty.*) {
        .ref_ => .borrowed_ref,
        .slice => .borrowed_view,
        .raw => .raw_pointer,
        else => .other,
    };
}

pub const ThreadBoundaryTrace = struct {
    chain: []const u8,
    reason: []const u8,
    resource: ?[]const u8 = null,

    pub fn deinit(self: ThreadBoundaryTrace, allocator: std.mem.Allocator) void {
        allocator.free(self.chain);
        allocator.free(self.reason);
        if (self.resource) |resource| allocator.free(resource);
    }
};

pub const ThreadBoundaryMode = enum {
    strict_isolated_contract,
    resource_reachability,
};

/// Value provenance, not a property of a shared callable signature. Only an
/// immutable binding can retain a resolved target. Unknown bindings still
/// shadow outer declarations and must never fall through to name resolution.
pub const ThreadBoundaryBinding = struct {
    name: []const u8,
    target: ?ast.Function = null,
};

pub fn threadBoundaryBinding(bindings: []const ThreadBoundaryBinding, name: []const u8) ?ThreadBoundaryBinding {
    var index = bindings.len;
    while (index != 0) {
        index -= 1;
        if (std.mem.eql(u8, bindings[index].name, name)) return bindings[index];
    }
    return null;
}

pub fn sameFunction(a: ast.Function, b: ast.Function) bool {
    return std.mem.eql(u8, a.module_name, b.module_name) and
        optionalStringEqual(a.owner, b.owner) and std.mem.eql(u8, a.name, b.name);
}

pub const CallableReturnFacts = struct {
    seen: bool = false,
    target: ?ast.Function = null,

    pub fn merge(self: *CallableReturnFacts, target: ?ast.Function) void {
        if (!self.seen) {
            self.seen = true;
            self.target = target;
        } else if (self.target) |previous| {
            if (target == null or !sameFunction(previous, target.?)) self.target = null;
        }
    }
};

pub const ThreadBoundaryEnvironment = struct {
    bindings: std.ArrayListUnmanaged(ThreadBoundaryBinding) = .empty,
    returns: CallableReturnFacts = .{},
    value_target: ?ast.Function = null,

    pub fn deinit(self: *ThreadBoundaryEnvironment, allocator: std.mem.Allocator) void {
        self.bindings.deinit(allocator);
    }
};

pub const ThreadBoundaryFrame = struct {
    function: ast.Function,
    parameters: []const ThreadBoundaryBinding,

    pub fn matches(self: ThreadBoundaryFrame, function: ast.Function, parameters: []const ThreadBoundaryBinding) bool {
        if (!sameFunction(self.function, function) or self.parameters.len != parameters.len) return false;
        for (self.parameters, parameters) |left, right| {
            if (left.target) |target| {
                if (right.target == null or !sameFunction(target, right.target.?)) return false;
            } else if (right.target != null) return false;
        }
        return true;
    }
};

pub fn plainFunctionValue(ty: ast.TypeName) bool {
    return ty.is_function and !ty.is_ref and !ty.is_raw and !ty.is_owned and
        !ty.is_optional and !ty.is_slice and ty.array_len == null and ty.array_len_name == null;
}

pub fn makeThreadBoundaryTrace(
    allocator: std.mem.Allocator,
    stack: []const ast.Function,
    reason: []const u8,
    resource: ?[]const u8,
) !ThreadBoundaryTrace {
    const owned_reason = try allocator.dupe(u8, reason);
    errdefer allocator.free(owned_reason);
    const chain = try renderFunctionChain(allocator, stack);
    errdefer allocator.free(chain);
    const owned_resource = if (resource) |name| try allocator.dupe(u8, name) else null;
    errdefer if (owned_resource) |name| allocator.free(name);
    return .{
        .chain = chain,
        .reason = owned_reason,
        .resource = owned_resource,
    };
}

pub fn makeFormattedThreadBoundaryTrace(
    allocator: std.mem.Allocator,
    stack: []const ast.Function,
    comptime fmt: []const u8,
    args: anytype,
    resource: ?[]const u8,
) !ThreadBoundaryTrace {
    const reason = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(reason);
    return makeThreadBoundaryTrace(allocator, stack, reason, resource);
}

pub fn functionInStack(stack: []const ast.Function, function: ast.Function) bool {
    for (stack) |item| {
        if (std.mem.eql(u8, item.module_name, function.module_name) and
            optionalStringEqual(item.owner, function.owner) and
            std.mem.eql(u8, item.name, function.name)) return true;
    }
    return false;
}

pub fn renderFunctionChain(allocator: std.mem.Allocator, stack: []const ast.Function) ![]const u8 {
    var rendered: std.ArrayListUnmanaged(u8) = .empty;
    errdefer rendered.deinit(allocator);
    for (stack, 0..) |function, i| {
        if (i != 0) try rendered.appendSlice(allocator, " -> ");
        try rendered.appendSlice(allocator, function.name);
    }
    return rendered.toOwnedSlice(allocator);
}

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn Walker(comptime host: anytype) type {
    return struct {
        const SemaContext = host.SemaContext;
        const SemaError = host.SemaError;
        const GlobalBinding = host.GlobalBinding;
        const canonicalStructLookup = lookup.canonicalStructLookup;
        const canonicalUnionLookup = lookup.canonicalUnionLookup;
        const canonical = type_resolution.Canonical(SemaContext);
        const lookup = declaration_owner.Lookup(SemaContext);
        const canonicalUnwrapOwned = canonical.unwrapOwnedType;
        const canonicalTypeNode = canonical.typeNode;
        const findAstFunction = host.findAstFunction;
        const findGlobal = declaration_owner.GlobalLookup(SemaContext, GlobalBinding).findGlobal;
        const lookupStructField = lookup.lookupStructField;
        const structFieldTypeId = host.structFieldTypeId;
        const firstExprToken = ast.firstExprToken;
        const parseTypeWithBindings = host.parseTypeWithBindings;
        const parseType = host.parseType;
        const formatTypeDisplay = canonical.formatType;
        const formatCanonicalTypeDisplay = canonical.formatType;
        const maybeRegisteredDeclId = lookup.maybeRegisteredDeclId;
        const canonicalTypeVisited = canonical.typeVisited;

        pub fn typeIsThreadTransferable(context: *SemaContext, path: []const u8, program: ast.Program, type_id: semantic_types.TypeId) SemaError!bool {
            var visited: std.ArrayListUnmanaged(semantic_types.TypeId) = .empty;
            defer visited.deinit(context.allocator);
            return canonicalTypeIsThreadTransferable(context, path, program, type_id, &visited);
        }

        pub fn typeIsThreadShareable(context: *SemaContext, path: []const u8, program: ast.Program, type_id: semantic_types.TypeId) SemaError!bool {
            var visited: std.ArrayListUnmanaged(semantic_types.TypeId) = .empty;
            defer visited.deinit(context.allocator);
            return canonicalTypeIsThreadShareable(context, path, program, type_id, &visited);
        }

        pub fn firstNonTransferableResourcePath(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
        ) SemaError!?[]const u8 {
            const root = try formatCanonicalTypeDisplay(context, type_id);
            defer allocator.free(root);

            var visited: std.ArrayListUnmanaged(semantic_types.TypeId) = .empty;
            defer visited.deinit(allocator);
            return canonicalFirstNonTransferableResourcePath(context, allocator, path, program, type_id, root, &visited);
        }

        fn canonicalTypeIsConcurrencyShareable(context: *SemaContext, program: ast.Program, type_id: semantic_types.TypeId) bool {
            const decl = canonicalStructLookup(context, program, type_id) orelse return false;
            return decl.is_concurrency_shareable;
        }

        fn canonicalArcPayloadType(context: *SemaContext, type_id: semantic_types.TypeId) ?semantic_types.TypeId {
            const node = canonicalTypeNode(context, type_id);
            if (node.* != .generic_instance or node.generic_instance.kind != .@"struct") return null;
            const arc_contract = intrinsics.definition(.std_own_arc_type);
            const arc_decl_id = maybeRegisteredDeclId(context, arc_contract.module_name.?, arc_contract.owner, arc_contract.name, .@"struct") orelse return null;
            if (node.generic_instance.base_decl_id != arc_decl_id or node.generic_instance.args.len != 1) return null;
            return switch (node.generic_instance.args[0]) {
                .type => |payload| payload,
                .const_usize => null,
            };
        }

        fn isMutableLibraryContainer(context: *SemaContext, type_id: semantic_types.TypeId) bool {
            const decl_id = switch (canonicalTypeNode(context, type_id).*) {
                .nominal => |nominal| nominal.decl_id,
                .generic_instance => |instance| instance.base_decl_id,
                else => return false,
            };
            for ([_][]const u8{ "List", "SlotMap", "Set", "Map" }) |name| {
                if (maybeRegisteredDeclId(context, "std.prelude", null, name, .@"struct") == decl_id) return true;
            }
            return false;
        }

        fn canonicalTypeIsThreadTransferable(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
            visited: *std.ArrayListUnmanaged(semantic_types.TypeId),
        ) SemaError!bool {
            return canonicalTypeSatisfiesThreadCapability(context, path, program, type_id, visited, false);
        }

        fn canonicalTypeIsThreadShareable(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
            visited: *std.ArrayListUnmanaged(semantic_types.TypeId),
        ) SemaError!bool {
            return canonicalTypeSatisfiesThreadCapability(context, path, program, type_id, visited, true);
        }

        fn canonicalTypeSatisfiesThreadCapability(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
            visited: *std.ArrayListUnmanaged(semantic_types.TypeId),
            require_shareable: bool,
        ) SemaError!bool {
            return switch (canonicalTypeNode(context, type_id).*) {
                .primitive, .inferred_integer, .inferred_float, .integer, .float => true,
                .optional => |child| canonicalTypeSatisfiesThreadCapability(context, path, program, child, visited, require_shareable),
                .array => |array| canonicalTypeSatisfiesThreadCapability(context, path, program, array.item, visited, require_shareable),
                .tuple => |members| blk: {
                    for (members) |member| {
                        if (!try canonicalTypeSatisfiesThreadCapability(context, path, program, member, visited, require_shareable)) break :blk false;
                    }
                    break :blk true;
                },
                .result => |result| try canonicalTypeSatisfiesThreadCapability(context, path, program, result.ok, visited, require_shareable) and
                    try canonicalTypeSatisfiesThreadCapability(context, path, program, result.err, visited, require_shareable),
                .dense_array, .sparse_array => |item| if (require_shareable)
                    false
                else
                    canonicalTypeSatisfiesThreadCapability(context, path, program, item, visited, false),
                .error_union => |members| blk: {
                    for (members) |member| {
                        if (!try canonicalTypeSatisfiesThreadCapability(context, path, program, member, visited, require_shareable)) break :blk false;
                    }
                    break :blk true;
                },
                .generic_parameter => false,
                .nominal => |nominal| switch (nominal.kind) {
                    .@"enum" => true,
                    .@"struct" => canonicalStructSatisfiesThreadCapability(context, path, program, type_id, visited, require_shareable),
                    .@"union" => canonicalUnionSatisfiesThreadCapability(context, path, program, type_id, visited, require_shareable),
                    .type_alias => if (nominal.underlying) |underlying|
                        canonicalTypeSatisfiesThreadCapability(context, path, program, underlying, visited, require_shareable)
                    else
                        false,
                    else => false,
                },
                .generic_instance => |instance| switch (instance.kind) {
                    .@"struct" => canonicalStructSatisfiesThreadCapability(context, path, program, type_id, visited, require_shareable),
                    else => false,
                },
                .slice, .ref_, .raw, .owned, .callable => false,
            };
        }

        fn canonicalStructSatisfiesThreadCapability(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
            visited: *std.ArrayListUnmanaged(semantic_types.TypeId),
            require_shareable: bool,
        ) SemaError!bool {
            if (canonicalArcPayloadType(context, type_id)) |payload| {
                return canonicalTypeSatisfiesThreadCapability(context, path, program, payload, visited, true);
            }
            if (canonicalTypeIsConcurrencyShareable(context, program, type_id)) return true;
            if (canonicalTypeVisited(visited.items, type_id)) return true;
            try visited.append(context.allocator, type_id);
            defer _ = visited.pop();

            const decl = canonicalStructLookup(context, program, type_id) orelse return false;
            if (isMutableLibraryContainer(context, type_id)) return false;
            switch (decl.fields) {
                .ast_fields => |fields| for (fields) |field| {
                    const field_type = try parseType(context, path, program, decl.module_name, field.type_name);
                    if (!try canonicalTypeSatisfiesThreadCapability(
                        context,
                        path,
                        program,
                        field_type,
                        visited,
                        require_shareable,
                    )) return false;
                },
                .inst_fields => |fields| for (fields) |field| {
                    if (!try canonicalTypeSatisfiesThreadCapability(
                        context,
                        path,
                        program,
                        field.type_id,
                        visited,
                        require_shareable,
                    )) return false;
                },
            }
            return true;
        }

        fn canonicalUnionSatisfiesThreadCapability(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
            visited: *std.ArrayListUnmanaged(semantic_types.TypeId),
            require_shareable: bool,
        ) SemaError!bool {
            if (canonicalTypeVisited(visited.items, type_id)) return true;
            try visited.append(context.allocator, type_id);
            defer _ = visited.pop();

            const decl = canonicalUnionLookup(context, program, type_id) orelse return false;
            for (decl.fields) |field| {
                const type_name = field.type_name orelse continue;
                const field_type = try parseType(context, path, program, decl.module_name, type_name);
                if (!try canonicalTypeSatisfiesThreadCapability(context, path, program, field_type, visited, require_shareable)) return false;
            }
            for (decl.variants) |variant| {
                const variant_type = try parseType(context, path, program, decl.module_name, variant);
                if (!try canonicalTypeSatisfiesThreadCapability(context, path, program, variant_type, visited, require_shareable)) return false;
            }
            return true;
        }

        fn canonicalFirstNonTransferableResourcePath(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
            prefix: []const u8,
            visited: *std.ArrayListUnmanaged(semantic_types.TypeId),
        ) SemaError!?[]const u8 {
            return switch (canonicalTypeNode(context, type_id).*) {
                .primitive, .inferred_integer, .inferred_float, .integer, .float => null,
                // A definition-site binder names no concrete resource of its own.
                .generic_parameter => null,
                .optional => |child| canonicalFirstNonTransferableResourcePath(context, allocator, path, program, child, prefix, visited),
                .array => |array| canonicalFirstNonTransferableResourcePath(context, allocator, path, program, array.item, prefix, visited),
                .tuple => |members| blk: {
                    for (members) |member| {
                        if (try canonicalFirstNonTransferableResourcePath(context, allocator, path, program, member, prefix, visited)) |found| break :blk found;
                    }
                    break :blk null;
                },
                .result => |result| blk: {
                    if (try canonicalFirstNonTransferableResourcePath(context, allocator, path, program, result.ok, prefix, visited)) |found|
                        break :blk found;
                    break :blk try canonicalFirstNonTransferableResourcePath(context, allocator, path, program, result.err, prefix, visited);
                },
                .error_union => |members| blk: {
                    for (members) |member| {
                        if (try canonicalFirstNonTransferableResourcePath(context, allocator, path, program, member, prefix, visited)) |found| break :blk found;
                    }
                    break :blk null;
                },
                .dense_array, .sparse_array => |item| blk: {
                    const item_path = try appendFieldPath(allocator, prefix, "item");
                    defer allocator.free(item_path);
                    break :blk try canonicalFirstNonTransferableResourcePath(context, allocator, path, program, item, item_path, visited);
                },
                .nominal => |nominal| switch (nominal.kind) {
                    .@"enum" => null,
                    .@"struct" => canonicalStructFirstNonTransferableResourcePath(context, allocator, path, program, type_id, prefix, visited),
                    .@"union" => canonicalUnionFirstNonTransferableResourcePath(context, allocator, path, program, type_id, prefix, visited),
                    .type_alias => if (nominal.underlying) |underlying|
                        canonicalFirstNonTransferableResourcePath(context, allocator, path, program, underlying, prefix, visited)
                    else
                        try allocator.dupe(u8, prefix),
                    else => try allocator.dupe(u8, prefix),
                },
                .generic_instance => |instance| switch (instance.kind) {
                    .@"struct" => canonicalStructFirstNonTransferableResourcePath(context, allocator, path, program, type_id, prefix, visited),
                    else => try allocator.dupe(u8, prefix),
                },
                .slice, .ref_, .raw, .owned, .callable => try allocator.dupe(u8, prefix),
            };
        }

        fn canonicalStructFirstNonTransferableResourcePath(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
            prefix: []const u8,
            visited: *std.ArrayListUnmanaged(semantic_types.TypeId),
        ) SemaError!?[]const u8 {
            if (canonicalArcPayloadType(context, type_id)) |payload| {
                return canonicalFirstNonTransferableResourcePath(context, allocator, path, program, payload, prefix, visited);
            }
            if (canonicalTypeIsConcurrencyShareable(context, program, type_id)) return null;
            if (canonicalTypeVisited(visited.items, type_id)) return null;
            try visited.append(allocator, type_id);
            defer _ = visited.pop();

            const decl = canonicalStructLookup(context, program, type_id) orelse return try allocator.dupe(u8, prefix);
            if (isMutableLibraryContainer(context, type_id)) return try allocator.dupe(u8, prefix);
            switch (decl.fields) {
                .ast_fields => |fields| for (fields) |field| {
                    const field_type = try parseType(context, path, program, decl.module_name, field.type_name);
                    const field_path = try appendFieldPath(allocator, prefix, field.name);
                    defer allocator.free(field_path);
                    if (try canonicalFirstNonTransferableResourcePath(
                        context,
                        allocator,
                        path,
                        program,
                        field_type,
                        field_path,
                        visited,
                    )) |resource| return resource;
                },
                .inst_fields => |fields| for (fields) |field| {
                    const field_path = try appendFieldPath(allocator, prefix, field.name);
                    defer allocator.free(field_path);
                    if (try canonicalFirstNonTransferableResourcePath(
                        context,
                        allocator,
                        path,
                        program,
                        field.type_id,
                        field_path,
                        visited,
                    )) |resource| return resource;
                },
            }
            return null;
        }

        fn canonicalUnionFirstNonTransferableResourcePath(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
            prefix: []const u8,
            visited: *std.ArrayListUnmanaged(semantic_types.TypeId),
        ) SemaError!?[]const u8 {
            if (canonicalTypeVisited(visited.items, type_id)) return null;
            try visited.append(allocator, type_id);
            defer _ = visited.pop();

            const decl = canonicalUnionLookup(context, program, type_id) orelse return try allocator.dupe(u8, prefix);
            for (decl.fields) |field| {
                const type_name = field.type_name orelse continue;
                const field_type = try parseType(context, path, program, decl.module_name, type_name);
                const field_path = try appendFieldPath(allocator, prefix, field.name);
                defer allocator.free(field_path);
                if (try canonicalFirstNonTransferableResourcePath(context, allocator, path, program, field_type, field_path, visited)) |resource| return resource;
            }
            for (decl.variants) |variant| {
                const variant_type = try parseType(context, path, program, decl.module_name, variant);
                if (try canonicalFirstNonTransferableResourcePath(context, allocator, path, program, variant_type, prefix, visited)) |resource| return resource;
            }
            return null;
        }

        fn appendFieldPath(allocator: std.mem.Allocator, prefix: []const u8, field_name: []const u8) ![]const u8 {
            return std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, field_name });
        }

        pub fn rejectIsolatedMutableGlobalAccess(context: *SemaContext, path: []const u8, token: lexer.Token, global: GlobalBinding, action: []const u8) SemaError!void {
            const isolated = context.function_state.active_isolated_function orelse return;
            if (!global.is_mutable) return;
            try context.diagnostic_context.emitToken(path, token, "isolated function `{s}` cannot {s} mutable global `{s}`", .{ isolated.name, action, global.name });
            return SemaError.SemanticFailed;
        }

        pub fn rejectIsolatedCallToFunction(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            token: lexer.Token,
            callee: ast.Function,
        ) SemaError!void {
            const isolated = context.function_state.active_isolated_function orelse return;
            if (callee.is_isolated and !callee.is_extern) return;
            if (isTrustedIsolatedExtern(callee)) return;
            const trace = if (!callee.is_extern)
                try analyzeThreadBoundaryEntrypoint(context, allocator, program, current_module, globals, callee, .strict_isolated_contract)
            else
                null;
            defer if (trace) |details| details.deinit(allocator);
            if (callee.is_extern) {
                try context.diagnostic_context.emitToken(path, token, "isolated function `{s}` cannot call extern function `{s}`", .{ isolated.name, callee.name });
            } else if (trace) |details| {
                try context.diagnostic_context.emitToken(path, token, "isolated function `{s}` cannot call non-isolated function `{s}`; thread-boundary chain: {s}; root violation: {s}", .{ isolated.name, callee.name, details.chain, details.reason });
            } else {
                try context.diagnostic_context.emitToken(path, token, "isolated function `{s}` cannot call non-isolated function `{s}`", .{ isolated.name, callee.name });
            }
            return SemaError.SemanticFailed;
        }

        pub fn validateBoundaryCall(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            call: ast.Call,
            callee: ast.Function,
            generic_params: ?[]const ast.GenericParam,
            generic_args: ?[]const semantic_types.GenericArgument,
        ) SemaError!void {
            const intrinsic = intrinsics.resolveCall(call.owner, call.callee) orelse return;
            const contract = contractForIntrinsic(intrinsic) orelse return;
            const owner = call.owner orelse return;
            return validateBoundaryArguments(context, allocator, path, program, current_module, globals, owner, call.callee, call.callee_token, call.args, callee, generic_params, generic_args, contract);
        }

        pub fn validateBoundaryArguments(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            owner: []const u8,
            name: []const u8,
            token: lexer.Token,
            args: []const ast.CallArg,
            callee: ast.Function,
            generic_params: ?[]const ast.GenericParam,
            generic_args: ?[]const semantic_types.GenericArgument,
            contract: Contract,
        ) SemaError!void {
            if (contract.entry_arg_index >= args.len) {
                try context.diagnostic_context.emitToken(path, token, "concurrency boundary `{s}.{s}` is missing entry argument", .{ owner, name });
                return SemaError.SemanticFailed;
            }
            if (contract.entry_arg_index >= callee.params.len) {
                try context.diagnostic_context.emitToken(path, token, "concurrency boundary `{s}.{s}` has invalid entry contract", .{ owner, name });
                return SemaError.SemanticFailed;
            }

            const entry_expr = args[contract.entry_arg_index].value;
            if (entry_expr.* != .name) {
                try context.diagnostic_context.emitToken(path, firstExprToken(entry_expr), "concurrency boundary `{s}.{s}` requires a named function entrypoint", .{ owner, name });
                return SemaError.SemanticFailed;
            }
            const entry_name = entry_expr.name;
            const entry = (findAstFunction(context, program, current_module, null, entry_name.text) orelse {
                try context.diagnostic_context.emitToken(path, entry_name.token, "concurrency boundary `{s}.{s}` entrypoint `{s}` is not a known function", .{ owner, name, entry_name.text });
                return SemaError.SemanticFailed;
            }).decl;
            if (contract.entry_must_be_isolated) {
                if (!entry.is_isolated or entry.is_extern) {
                    try context.diagnostic_context.emitToken(path, entry_name.token, "concurrency boundary `{s}.{s}` entrypoint `{s}` must be marked @concurrency.isolated", .{ owner, name, entry.name });
                    return SemaError.SemanticFailed;
                }
            } else if (try analyzeThreadBoundaryEntrypoint(context, allocator, program, current_module, globals, entry, .resource_reachability)) |trace| {
                defer trace.deinit(allocator);
                if (trace.resource) |resource| {
                    try context.diagnostic_context.emitToken(path, entry_name.token, "concurrency boundary `{s}.{s}` entrypoint `{s}` reaches thread-unsafe code; call chain: {s}; resource: {s}; reason: {s}; help: protect shared mutable state with a sync resource such as Mutex, RwLock, Atomic, Channel, or a std concurrent container", .{ owner, name, entry.name, trace.chain, resource, trace.reason });
                } else {
                    try context.diagnostic_context.emitToken(path, entry_name.token, "concurrency boundary `{s}.{s}` entrypoint `{s}` reaches thread-unsafe code; call chain: {s}; reason: {s}", .{ owner, name, entry.name, trace.chain, trace.reason });
                }
                return SemaError.SemanticFailed;
            }

            if (contract.payload_must_be_transferable) {
                for (contract.payload_arg_indices) |arg_index| {
                    if (arg_index >= args.len or arg_index >= callee.params.len) {
                        try context.diagnostic_context.emitToken(path, token, "concurrency boundary `{s}.{s}` has invalid payload contract", .{ owner, name });
                        return SemaError.SemanticFailed;
                    }
                    const param = callee.params[arg_index];
                    const param_type = if (generic_params) |params|
                        try parseTypeWithBindings(context, path, program, callee.module_name, param.type_name, null, params, generic_args orelse &.{})
                    else
                        try parseType(context, path, program, callee.module_name, param.type_name);
                    const param_type_id = param_type;
                    if (try typeIsThreadTransferable(context, path, program, param_type_id)) continue;
                    const rendered = try formatTypeDisplay(context, param_type);
                    defer allocator.free(rendered);
                    const resource = try firstNonTransferableResourcePath(context, allocator, path, program, param_type_id);
                    defer if (resource) |resource_name| allocator.free(resource_name);
                    const payload_kind = payloadKind(canonicalTypeNode(context, param_type));
                    const reason = payloadNonTransferReason(payload_kind);
                    if (resource) |resource_name| {
                        if (reason) |text| {
                            try context.diagnostic_context.emitToken(path, firstExprToken(args[arg_index].value), "concurrency boundary `{s}.{s}` payload type `{s}` is not thread-safe to transfer; resource: {s}; reason: {s}; help: {s}", .{ owner, name, rendered, resource_name, text, payloadNonTransferHelp(payload_kind) });
                        } else {
                            try context.diagnostic_context.emitToken(path, firstExprToken(args[arg_index].value), "concurrency boundary `{s}.{s}` payload type `{s}` is not thread-safe to transfer; resource: {s}; help: wrap shared mutable resources in a sync resource such as Mutex, RwLock, Atomic, Channel, or a std concurrent container", .{ owner, name, rendered, resource_name });
                        }
                    } else {
                        try context.diagnostic_context.emitToken(path, firstExprToken(args[arg_index].value), "concurrency boundary `{s}.{s}` payload type `{s}` is not thread-safe to transfer", .{ owner, name, rendered });
                    }
                    return SemaError.SemanticFailed;
                }
            }
        }

        pub fn analyzeThreadBoundaryEntrypoint(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            callee: ast.Function,
            mode: ThreadBoundaryMode,
        ) SemaError!?ThreadBoundaryTrace {
            var stack: std.ArrayListUnmanaged(ast.Function) = .empty;
            defer stack.deinit(allocator);
            var locals: ThreadBoundaryEnvironment = .{};
            defer locals.deinit(allocator);
            var frames: std.ArrayListUnmanaged(ThreadBoundaryFrame) = .empty;
            defer frames.deinit(allocator);
            const previous_frames = context.thread_boundary_frames;
            context.thread_boundary_frames = &frames;
            defer context.thread_boundary_frames = previous_frames;
            for (callee.params) |param| try locals.bindings.append(allocator, .{ .name = param.name });
            return try analyzeThreadBoundaryInFunction(context, allocator, program, current_module, globals, callee, mode, &stack, &locals);
        }

        fn analyzeThreadBoundaryInFunction(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            function: ast.Function,
            mode: ThreadBoundaryMode,
            stack: *std.ArrayListUnmanaged(ast.Function),
            locals: *ThreadBoundaryEnvironment,
        ) SemaError!?ThreadBoundaryTrace {
            try stack.append(allocator, function);
            defer _ = stack.pop();

            const local_start = locals.bindings.items.len;
            defer locals.bindings.shrinkRetainingCapacity(local_start);
            // Snapshot parameter provenance: appending locals may relocate bindings.
            const parameters = try allocator.dupe(ThreadBoundaryBinding, locals.bindings.items);
            defer allocator.free(parameters);
            const frames = context.thread_boundary_frames.?;
            try frames.append(allocator, .{ .function = function, .parameters = parameters });
            defer _ = frames.pop();

            for (function.body) |stmt| {
                if (try analyzeThreadBoundaryInStmt(context, allocator, program, current_module, globals, stmt, mode, stack, locals)) |trace| return trace;
            }

            if (mode == .resource_reachability) return null;
            return try makeFormattedThreadBoundaryTrace(
                allocator,
                stack.items,
                "function `{s}` is not marked `@concurrency.isolated`",
                .{function.name},
                null,
            );
        }

        fn analyzeThreadBoundaryInStmt(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            stmt: ast.Stmt,
            mode: ThreadBoundaryMode,
            stack: *std.ArrayListUnmanaged(ast.Function),
            locals: *ThreadBoundaryEnvironment,
        ) SemaError!?ThreadBoundaryTrace {
            const function = stack.items[stack.items.len - 1];
            switch (stmt) {
                .discard => |expr| return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, expr, mode, stack, locals),
                .local => |local| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, local.init, mode, stack, locals)) |trace| return trace;
                    try locals.bindings.append(allocator, .{
                        .name = local.name,
                        .target = if (!local.is_mutable) locals.value_target else null,
                    });
                },
                .assign => |assign| {
                    if (findThreadBoundaryMutableGlobalUse(context, program, globals, function.module_name, locals.bindings.items, assign.name)) |global| {
                        return try makeFormattedThreadBoundaryTrace(
                            allocator,
                            stack.items,
                            "function `{s}` mutates mutable global `{s}`",
                            .{ function.name, global.name },
                            global.name,
                        );
                    }
                    return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, assign.value, mode, stack, locals);
                },
                .field_assign => |assign| {
                    if (try traceMutableGlobalFieldMutation(context, allocator, program, current_module, globals, function, locals.bindings.items, stack.items, assign.object, assign.fields)) |trace| return trace;
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, assign.object, mode, stack, locals)) |trace| return trace;
                    return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, assign.value, mode, stack, locals);
                },
                .index_assign => |assign| {
                    if (try traceMutableGlobalIndexMutation(context, allocator, program, current_module, globals, function, locals.bindings.items, stack.items, assign.object)) |trace| return trace;
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, assign.object, mode, stack, locals)) |trace| return trace;
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, assign.index, mode, stack, locals)) |trace| return trace;
                    return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, assign.value, mode, stack, locals);
                },
                .deref_assign => |assign| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, assign.pointer, mode, stack, locals)) |trace| return trace;
                    return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, assign.value, mode, stack, locals);
                },
                .deref_field_assign => |assign| {
                    if (try traceMutableGlobalFieldMutation(context, allocator, program, current_module, globals, function, locals.bindings.items, stack.items, assign.pointer, assign.fields)) |trace| return trace;
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, assign.pointer, mode, stack, locals)) |trace| return trace;
                    return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, assign.value, mode, stack, locals);
                },
                .using_alloc => |using_alloc| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, using_alloc.allocator_expr, mode, stack, locals)) |trace| return trace;
                    return try analyzeThreadBoundaryInStmts(context, allocator, program, current_module, globals, using_alloc.body, mode, stack, locals);
                },
                .unchecked => |body| return try analyzeThreadBoundaryInStmts(context, allocator, program, current_module, globals, body, mode, stack, locals),
                .asm_stmt => |asm_stmt| {
                    for (asm_stmt.inputs) |input| {
                        if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, input.value, mode, stack, locals)) |trace| return trace;
                    }
                },
                .@"if" => |if_stmt| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, if_stmt.condition, mode, stack, locals)) |trace| return trace;
                    if (try analyzeThreadBoundaryInStmts(context, allocator, program, current_module, globals, if_stmt.then_body, mode, stack, locals)) |trace| return trace;
                    return try analyzeThreadBoundaryInStmts(context, allocator, program, current_module, globals, if_stmt.else_body, mode, stack, locals);
                },
                .@"while" => |while_stmt| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, while_stmt.condition, mode, stack, locals)) |trace| return trace;
                    return try analyzeThreadBoundaryInStmts(context, allocator, program, current_module, globals, while_stmt.body, mode, stack, locals);
                },
                .@"for" => |for_stmt| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, for_stmt.iterable, mode, stack, locals)) |trace| return trace;
                    try locals.bindings.append(allocator, .{ .name = for_stmt.name });
                    defer _ = locals.bindings.pop();
                    return try analyzeThreadBoundaryInStmts(context, allocator, program, current_module, globals, for_stmt.body, mode, stack, locals);
                },
                .@"continue", .@"break" => {},
                .yield => |yield_stmt| if (yield_stmt.value) |value| return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, value, mode, stack, locals),
                .@"switch" => |switch_stmt| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, switch_stmt.value, mode, stack, locals)) |trace| return trace;
                    for (switch_stmt.cases) |case| {
                        const local_start = locals.bindings.items.len;
                        defer locals.bindings.shrinkRetainingCapacity(local_start);
                        if (case.payload_name) |payload| try locals.bindings.append(allocator, .{ .name = payload });
                        if (try analyzeThreadBoundaryInStmts(context, allocator, program, current_module, globals, case.body, mode, stack, locals)) |trace| return trace;
                    }
                    return try analyzeThreadBoundaryInStmts(context, allocator, program, current_module, globals, switch_stmt.else_body, mode, stack, locals);
                },
                .@"try", .@"defer", .expr => |expr| return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, expr, mode, stack, locals),
                .drop => {},
                .@"return" => |ret| {
                    if (ret.value) |value| {
                        if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, value, mode, stack, locals)) |trace| return trace;
                        locals.returns.merge(locals.value_target);
                    } else locals.returns.merge(null);
                },
            }
            return null;
        }

        fn analyzeThreadBoundaryInStmts(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            body: []const ast.Stmt,
            mode: ThreadBoundaryMode,
            stack: *std.ArrayListUnmanaged(ast.Function),
            locals: *ThreadBoundaryEnvironment,
        ) SemaError!?ThreadBoundaryTrace {
            const local_start = locals.bindings.items.len;
            defer locals.bindings.shrinkRetainingCapacity(local_start);
            for (body) |stmt| {
                if (try analyzeThreadBoundaryInStmt(context, allocator, program, current_module, globals, stmt, mode, stack, locals)) |trace| return trace;
            }
            return null;
        }

        fn analyzeThreadBoundaryInExpr(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            expr: *const ast.Expr,
            mode: ThreadBoundaryMode,
            stack: *std.ArrayListUnmanaged(ast.Function),
            locals: *ThreadBoundaryEnvironment,
        ) SemaError!?ThreadBoundaryTrace {
            var preserve_target = false;
            locals.value_target = null;
            defer if (!preserve_target) {
                locals.value_target = null;
            };
            const function = stack.items[stack.items.len - 1];
            switch (expr.*) {
                .@"switch" => |switch_expr| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, switch_expr.value, mode, stack, locals)) |trace| return trace;
                    for (switch_expr.cases) |case| {
                        const local_start = locals.bindings.items.len;
                        defer locals.bindings.shrinkRetainingCapacity(local_start);
                        if (case.payload_name) |payload| try locals.bindings.append(allocator, .{ .name = payload });
                        if (try analyzeThreadBoundaryInStmts(context, allocator, program, current_module, globals, case.body, mode, stack, locals)) |trace| return trace;
                    }
                    return try analyzeThreadBoundaryInStmts(context, allocator, program, current_module, globals, switch_expr.else_body, mode, stack, locals);
                },
                .int, .float, .rune, .string, .bool, .none, .enum_case => {},
                .name => |name| {
                    if (findThreadBoundaryMutableGlobalUse(context, program, globals, function.module_name, locals.bindings.items, name.text)) |global| {
                        return try makeFormattedThreadBoundaryTrace(
                            allocator,
                            stack.items,
                            "function `{s}` reads mutable global `{s}`",
                            .{ function.name, global.name },
                            global.name,
                        );
                    }
                    locals.value_target = resolveThreadBoundaryTarget(context, program, function.module_name, locals.bindings.items, name.text);
                    preserve_target = true;
                },
                .interpolated_string => |interpolated| for (interpolated.parts) |part| switch (part) {
                    .literal => {},
                    .hole => |hole| {
                        // Interpolation holes are projection paths rather than Expr
                        // trees. Their root still participates in execution effects.
                        var root = ast.Expr{ .name = hole.base };
                        if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, &root, mode, stack, locals)) |trace| return trace;
                    },
                },
                .address_of => |address_of| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, address_of.expr, mode, stack, locals)) |trace| return trace;
                    if (locals.value_target != null) return try makeFormattedThreadBoundaryTrace(
                        allocator,
                        stack.items,
                        "callable target cannot retain its execution contract through an address",
                        .{},
                        null,
                    );
                },
                .@"try" => |try_expr| return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, try_expr.expr, mode, stack, locals),
                .deref => |deref| return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, deref.expr, mode, stack, locals),
                .unary => |unary| return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, unary.expr, mode, stack, locals),
                .is_test => |is_test| return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, is_test.subject, mode, stack, locals),
                .cast => |cast| return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, cast.subject, mode, stack, locals),
                .@"comptime" => |ct| return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, ct.expr, mode, stack, locals),
                .binary => |binary| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, binary.left, mode, stack, locals)) |trace| return trace;
                    return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, binary.right, mode, stack, locals);
                },
                .call => |call| {
                    const targets = try allocator.alloc(?ast.Function, call.args.len);
                    defer allocator.free(targets);
                    for (call.args, 0..) |arg, index| {
                        if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, arg.value, mode, stack, locals)) |trace| return trace;
                        targets[index] = locals.value_target;
                    }
                    locals.value_target = null;
                    if (try analyzeThreadBoundaryInCall(context, allocator, program, current_module, globals, call, mode, stack, locals, targets)) |trace| return trace;
                    preserve_target = true;
                },
                .method_call => |call| {
                    if (try traceMutableGlobalMethodCall(context, allocator, program, current_module, globals, function, locals.bindings.items, stack.items, call.object, call.method)) |trace| return trace;
                    if (!(try mutableGlobalReceiverIsSyncResource(context, "", program, current_module, globals, locals.bindings.items, call.object))) {
                        if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, call.object, mode, stack, locals)) |trace| return trace;
                    }
                    for (call.args) |arg|
                        if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, arg.value, mode, stack, locals)) |trace| return trace;
                },
                .function_expr => {},
                .union_case => |case| if (case.value) |value| return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, value, mode, stack, locals),
                .slice_range => |slice| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, slice.object, mode, stack, locals)) |trace| return trace;
                    if (slice.start) |start| if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, start, mode, stack, locals)) |trace| return trace;
                    if (slice.end) |end| return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, end, mode, stack, locals);
                },
                .index => |index| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, index.object, mode, stack, locals)) |trace| return trace;
                    return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, index.index, mode, stack, locals);
                },
                .array_literal => |literal| for (literal.items) |item| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, item, mode, stack, locals)) |trace| return trace;
                },
                .sequence_repeat => |repeat| {
                    for (repeat.items) |item| {
                        if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, item, mode, stack, locals)) |trace| return trace;
                    }
                    return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, repeat.count, mode, stack, locals);
                },
                .typed_sequence_literal => |literal| for (literal.items) |item| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, item, mode, stack, locals)) |trace| return trace;
                },
                .keyed_literal => |literal| for (literal.entries) |entry| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, entry.key, mode, stack, locals)) |trace| return trace;
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, entry.value, mode, stack, locals)) |trace| return trace;
                },
                .fixed_array_construct => |construct| for (construct.items) |item| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, item, mode, stack, locals)) |trace| return trace;
                },
                .new_array => |new_array| return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, new_array.len, mode, stack, locals),
                .new_sparse => |new_sparse| return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, new_sparse.capacity, mode, stack, locals),
                .new_owned, .struct_literal => |literal| for (literal.fields) |field| {
                    if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, field.value, mode, stack, locals)) |trace| return trace;
                },
                .asm_expr => |asm_expr| {
                    if (asm_expr.inout) |inout| if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, inout.value, mode, stack, locals)) |trace| return trace;
                    for (asm_expr.inputs) |input| {
                        if (try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, input.value, mode, stack, locals)) |trace| return trace;
                    }
                },
                .field => |field| return try analyzeThreadBoundaryInExpr(context, allocator, program, current_module, globals, field.object, mode, stack, locals),
            }
            return null;
        }

        fn analyzeThreadBoundaryInCall(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            call: ast.Call,
            mode: ThreadBoundaryMode,
            stack: *std.ArrayListUnmanaged(ast.Function),
            locals: *ThreadBoundaryEnvironment,
            argument_targets: []const ?ast.Function,
        ) SemaError!?ThreadBoundaryTrace {
            const caller = stack.items[stack.items.len - 1];
            // Use resolved value provenance before looking up a named declaration.
            // An unknown lexical binding must shadow a same-named global function.
            const callee = if (call.owner == null) blk: {
                if (threadBoundaryBinding(locals.bindings.items, call.callee)) |binding| {
                    break :blk binding.target orelse return try makeFormattedThreadBoundaryTrace(
                        allocator,
                        stack.items,
                        "indirect callable `{s}` has no preserved execution contract; call a known named helper or preserve an explicit callable contract",
                        .{call.callee},
                        call.callee,
                    );
                }
                break :blk (findAstFunction(context, program, caller.module_name, null, call.callee) orelse return null).decl;
            } else (findAstFunction(context, program, caller.module_name, call.owner, call.callee) orelse return null).decl;
            if ((callee.is_isolated and !callee.is_extern) or isTrustedIsolatedExtern(callee)) return null;
            if (callee.is_extern) {
                try stack.append(allocator, callee);
                defer _ = stack.pop();
                return try makeFormattedThreadBoundaryTrace(
                    allocator,
                    stack.items,
                    "function `{s}` calls extern function `{s}`",
                    .{ caller.name, callee.name },
                    callee.name,
                );
            }
            var callee_locals: ThreadBoundaryEnvironment = .{};
            defer callee_locals.deinit(allocator);
            for (callee.params, 0..) |param, index| {
                const target = if (index < argument_targets.len) argument_targets[index] else null;
                if (target != null and !plainFunctionValue(param.type_name)) return try makeFormattedThreadBoundaryTrace(
                    allocator,
                    stack.items,
                    "callable argument `{s}` requires a by-value function parameter to preserve its execution contract",
                    .{param.name},
                    param.name,
                );
                try callee_locals.bindings.append(allocator, .{
                    .name = param.name,
                    .target = target,
                });
            }
            if (mode == .resource_reachability) {
                for (context.thread_boundary_frames.?.items) |frame| {
                    // Only an identical callback context closes the recursive edge.
                    // Its return remains unknown until a fixed-point return analysis.
                    if (frame.matches(callee, callee_locals.bindings.items)) return null;
                }
                if (stack.items.len >= 128) return try makeFormattedThreadBoundaryTrace(
                    allocator,
                    stack.items,
                    "callback analysis exceeded its recursion limit at `{s}`",
                    .{callee.name},
                    callee.name,
                );
            } else if (functionInStack(stack.items, callee)) {
                return try makeFormattedThreadBoundaryTrace(
                    allocator,
                    stack.items,
                    "recursive non-isolated call reaches `{s}`",
                    .{callee.name},
                    null,
                );
            }
            if (try analyzeThreadBoundaryInFunction(context, allocator, program, current_module, globals, callee, mode, stack, &callee_locals)) |trace| return trace;
            locals.value_target = if (callee.return_type != null and plainFunctionValue(callee.return_type.?)) callee_locals.returns.target else null;
            return null;
        }

        fn traceMutableGlobalFieldMutation(
            context: *const SemaContext,
            allocator: std.mem.Allocator,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            function: ast.Function,
            locals: []const ThreadBoundaryBinding,
            stack: []const ast.Function,
            object: *const ast.Expr,
            fields: []const ast.DerefFieldAssignStep,
        ) SemaError!?ThreadBoundaryTrace {
            if (object.* != .name) return null;
            const root = object.name;
            const global = findThreadBoundaryMutableGlobalUse(context, program, globals, current_module, locals, root.text) orelse return null;
            const resource = try renderThreadBoundaryFieldResource(allocator, global.name, fields);
            defer allocator.free(resource);
            return try makeFormattedThreadBoundaryTrace(
                allocator,
                stack,
                "function `{s}` mutates mutable global resource `{s}`",
                .{ function.name, resource },
                resource,
            );
        }

        fn traceMutableGlobalIndexMutation(
            context: *const SemaContext,
            allocator: std.mem.Allocator,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            function: ast.Function,
            locals: []const ThreadBoundaryBinding,
            stack: []const ast.Function,
            object: *const ast.Expr,
        ) SemaError!?ThreadBoundaryTrace {
            if (object.* != .name) return null;
            const root = object.name;
            const global = findThreadBoundaryMutableGlobalUse(context, program, globals, current_module, locals, root.text) orelse return null;
            const resource = try std.fmt.allocPrint(allocator, "{s}[..]", .{global.name});
            defer allocator.free(resource);
            return try makeFormattedThreadBoundaryTrace(
                allocator,
                stack,
                "function `{s}` mutates mutable global resource `{s}`",
                .{ function.name, resource },
                resource,
            );
        }

        fn traceMutableGlobalMethodCall(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            function: ast.Function,
            locals: []const ThreadBoundaryBinding,
            stack: []const ast.Function,
            object: *const ast.Expr,
            method: []const u8,
        ) SemaError!?ThreadBoundaryTrace {
            const resource = try renderThreadBoundaryReceiverResource(context, allocator, program, current_module, globals, locals, object) orelse return null;
            defer allocator.free(resource);
            if (try mutableGlobalReceiverIsSyncResource(context, "", program, current_module, globals, locals, object)) return null;
            return try makeFormattedThreadBoundaryTrace(
                allocator,
                stack,
                "function `{s}` calls method `{s}` on mutable global resource `{s}`",
                .{ function.name, method, resource },
                resource,
            );
        }

        fn renderThreadBoundaryFieldResource(
            allocator: std.mem.Allocator,
            root: []const u8,
            fields: []const ast.DerefFieldAssignStep,
        ) SemaError![]const u8 {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, root);
            for (fields) |field| {
                try out.append(allocator, '.');
                try out.appendSlice(allocator, field.field);
            }
            return try out.toOwnedSlice(allocator);
        }

        fn renderThreadBoundaryReceiverResource(
            context: *const SemaContext,
            allocator: std.mem.Allocator,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const ThreadBoundaryBinding,
            object: *const ast.Expr,
        ) SemaError!?[]const u8 {
            return switch (object.*) {
                .name => |name| blk: {
                    const global = findThreadBoundaryMutableGlobalUse(context, program, globals, current_module, locals, name.text) orelse break :blk null;
                    break :blk try allocator.dupe(u8, global.name);
                },
                .field => |field| blk: {
                    const base = try renderThreadBoundaryReceiverResource(context, allocator, program, current_module, globals, locals, field.object) orelse break :blk null;
                    defer allocator.free(base);
                    break :blk try appendFieldPath(allocator, base, field.field);
                },
                else => null,
            };
        }

        fn mutableGlobalReceiverIsSyncResource(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const ThreadBoundaryBinding,
            object: *const ast.Expr,
        ) SemaError!bool {
            const ty = (try mutableGlobalReceiverType(context, path, program, current_module, globals, locals, object)) orelse return false;
            return canonicalTypeIsConcurrencyShareable(context, program, ty);
        }

        fn mutableGlobalReceiverType(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const ThreadBoundaryBinding,
            object: *const ast.Expr,
        ) SemaError!?semantic_types.TypeId {
            return switch (object.*) {
                .name => |name| blk: {
                    const global = findThreadBoundaryMutableGlobalUse(context, program, globals, current_module, locals, name.text) orelse break :blk null;
                    break :blk global.type_id;
                },
                .field => |field| blk: {
                    const base = (try mutableGlobalReceiverType(context, path, program, current_module, globals, locals, field.object)) orelse break :blk null;
                    break :blk try threadBoundaryFieldType(context, path, program, current_module, base, field.field);
                },
                else => null,
            };
        }

        fn threadBoundaryFieldType(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            base: semantic_types.TypeId,
            field_name: []const u8,
        ) SemaError!?semantic_types.TypeId {
            _ = current_module;
            const object_type = canonicalUnwrapOwned(context, base);
            const decl = canonicalStructLookup(context, program, object_type) orelse return null;
            const field = lookupStructField(decl, field_name) orelse return null;
            return try structFieldTypeId(context, path, program, decl, field);
        }

        fn resolveThreadBoundaryTarget(
            context: *SemaContext,
            program: ast.Program,
            module_name: []const u8,
            locals: []const ThreadBoundaryBinding,
            name: []const u8,
        ) ?ast.Function {
            if (threadBoundaryBinding(locals, name)) |binding| return binding.target;
            return (findAstFunction(context, program, module_name, null, name) orelse return null).decl;
        }

        fn findThreadBoundaryMutableGlobalUse(
            context: *const SemaContext,
            program: ast.Program,
            globals: []const GlobalBinding,
            module_name: []const u8,
            locals: []const ThreadBoundaryBinding,
            name: []const u8,
        ) ?GlobalBinding {
            if (threadBoundaryBinding(locals, name) != null) return null;
            const global = findGlobal(context, program, globals, module_name, name) orelse return null;
            if (!global.is_mutable) return null;
            return global;
        }
    };
}

pub const Kind = enum {
    concurrent_spawn,
};

pub const Contract = struct {
    kind: Kind,
    entry_arg_index: usize,
    payload_arg_indices: []const usize,
    entry_must_be_isolated: bool = true,
    payload_must_be_transferable: bool = true,
    allows_borrowed_payloads: bool = false,
    requires_static_lifetime: bool = true,
};

pub const PayloadKind = enum {
    borrowed_ref,
    borrowed_view,
    raw_pointer,
    other,
};

const spawn_payload_arg_indices = [_]usize{1};

pub fn contractForIntrinsic(id: intrinsics.Id) ?Contract {
    return switch (id) {
        .std_thread_spawn, .embedded_task_spawn => .{
            .kind = .concurrent_spawn,
            .entry_arg_index = 0,
            .payload_arg_indices = spawn_payload_arg_indices[0..],
            .entry_must_be_isolated = false,
        },
        else => null,
    };
}

pub fn payloadNonTransferReason(kind: PayloadKind) ?[]const u8 {
    return switch (kind) {
        .borrowed_ref => "alias pointers cannot cross a detached thread boundary",
        .borrowed_view => "borrowed views cannot cross a detached thread boundary",
        .raw_pointer => "raw pointers are opaque to thread-boundary safety analysis",
        .other => null,
    };
}

pub fn payloadNonTransferHelp(kind: PayloadKind) []const u8 {
    return switch (kind) {
        .borrowed_ref, .borrowed_view => "pass owned state or an explicit sync resource; scoped concurrency can allow borrows only for join-before-return work, not detached threads",
        .raw_pointer => "wrap the pointer behind a typed sync resource or an unchecked foreign boundary",
        .other => "pass an owned transferable value or use a sync resource",
    };
}

test "contract lookup recognizes hosted thread spawn" {
    const contract = contractForIntrinsic(.std_thread_spawn) orelse return error.TestExpectedEqual;
    try std.testing.expect(contract.kind == .concurrent_spawn);
    try std.testing.expect(contract.entry_arg_index == 0);
    try std.testing.expect(contract.payload_arg_indices.len == 1);
    try std.testing.expect(contract.payload_arg_indices[0] == 1);
    try std.testing.expect(!contract.entry_must_be_isolated);
    try std.testing.expect(contract.payload_must_be_transferable);
    try std.testing.expect(!contract.allows_borrowed_payloads);
    try std.testing.expect(contract.requires_static_lifetime);
}

test "contract lookup recognizes embedded task spawn" {
    const contract = contractForIntrinsic(.embedded_task_spawn) orelse return error.TestExpectedEqual;
    try std.testing.expect(contract.kind == .concurrent_spawn);
    try std.testing.expect(contract.entry_arg_index == 0);
    try std.testing.expect(contract.payload_arg_indices.len == 1);
    try std.testing.expect(contract.payload_arg_indices[0] == 1);
    try std.testing.expect(!contract.entry_must_be_isolated);
}

test "contract lookup ignores ordinary calls" {
    try std.testing.expect(contractForIntrinsic(.builtin_print) == null);
    try std.testing.expect(contractForIntrinsic(.std_sync_share) == null);
}

test "payload diagnostics explain detached boundary categories" {
    try std.testing.expectEqualStrings("alias pointers cannot cross a detached thread boundary", payloadNonTransferReason(.borrowed_ref).?);
    try std.testing.expectEqualStrings("borrowed views cannot cross a detached thread boundary", payloadNonTransferReason(.borrowed_view).?);
    try std.testing.expectEqualStrings("raw pointers are opaque to thread-boundary safety analysis", payloadNonTransferReason(.raw_pointer).?);
    try std.testing.expect(payloadNonTransferReason(.other) == null);
    try std.testing.expect(std.mem.indexOf(u8, payloadNonTransferHelp(.borrowed_ref), "join-before-return") != null);
}

pub fn TrampolineOwner(comptime host: anytype) type {
    return struct {
        const SemaContext = host.SemaContext;
        const SemaError = host.SemaError;
        const makeTypedExprFromId = host.makeTypedExprFromId;
        const finalizeAndRecordExprSemantics = host.finalizeAndRecordExprSemantics;
        const canonical = type_resolution.Canonical(SemaContext);
        const lookup = declaration_owner.Lookup(SemaContext);
        const canonicalRawTypeId = canonical.rawType;
        const canonicalPrimitiveTypeId = canonical.primitiveType;
        const canonicalNominalTypeId = canonical.nominalType;
        const canonicalRefTypeId = canonical.refType;
        const canonicalTypeIsVoidLike = canonical.voidLike;
        const recordGeneratedBindingRoot = host.recordGeneratedBindingRoot;
        const registeredDeclId = lookup.registeredDeclId;
        const internCallableType = host.internCallableType;
        const nextBindingId = lookup.nextBindingId;
        const semanticExprMetadata = host.semanticExprMetadata;
        const recordExprMetadata = host.recordExprMetadata;
        const recordExprSink = host.recordExprSink;
        const registerGeneratedDecl = lookup.registerGeneratedDecl;
        const maybeRegisteredDeclId = lookup.maybeRegisteredDeclId;
        const parseType = host.parseType;
        const attachCheckedCallUse = host.attachCheckedCallUse;

        fn taskTrampolineLocal(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            module_name: []const u8,
            name: []const u8,
            binding_id: identity.BindingId,
            type_id: semantic_types.TypeId,
        ) SemaError!*sir.Expr {
            const expr = try allocator.create(sir.Expr);
            errdefer allocator.destroy(expr);
            expr.* = .{ .local = name };
            var typed = makeTypedExprFromId(expr, type_id);
            try finalizeAndRecordExprSemantics(context, path, program, module_name, &typed);
            try recordGeneratedBindingRoot(context, expr, binding_id, false);
            return expr;
        }

        fn taskTrampolineCast(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            module_name: []const u8,
            subject: *sir.Expr,
            target_type: semantic_types.TypeId,
        ) SemaError!*sir.Expr {
            const expr = try allocator.create(sir.Expr);
            errdefer allocator.destroy(expr);
            expr.* = .{ .cast = .{
                .subject = subject,
                .target_type_id = target_type,
                .union_case_name = null,
                .fallible = false,
                .reinterpret = true,
            } };
            var typed = makeTypedExprFromId(expr, target_type);
            try finalizeAndRecordExprSemantics(context, path, program, module_name, &typed);
            return expr;
        }

        pub fn synthesizeTaskGroupTrampoline(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            module_name: []const u8,
            debug_token: lexer.Token,
            input_type: semantic_types.TypeId,
            result_type: semantic_types.TypeId,
            with_context: bool,
        ) SemaError![]const u8 {
            const name = try std.fmt.allocPrint(allocator, "{s}{d}", .{ generated_names.task_group_trampoline_prefix, context.anonymous_function_counter });
            context.anonymous_function_counter += 1;
            try context.output.generated_strings.append(allocator, name);
            const raw_void = try canonicalRawTypeId(context, try canonicalPrimitiveTypeId(context, .c_void), false);
            const context_type = if (with_context)
                try canonicalNominalTypeId(context, .@"struct", try registeredDeclId(context, "std.thread", null, "TaskContext", .@"struct"), null)
            else
                null;
            const entry_type = if (context_type) |ctx_type|
                try internCallableType(context, .function, .cyna, &.{ try canonicalRefTypeId(context, ctx_type), input_type }, result_type)
            else
                try internCallableType(context, .function, .cyna, &.{input_type}, result_type);

            const params = try allocator.alloc(sir.Param, 5);
            params[0] = .{ .name = "entry_ctx", .binding_id = try nextBindingId(context), .type_id = raw_void };
            params[1] = .{ .name = "input_ctx", .binding_id = try nextBindingId(context), .type_id = raw_void };
            params[2] = .{ .name = "result_ctx", .binding_id = try nextBindingId(context), .type_id = raw_void };
            params[3] = .{ .name = "cancel_ctx", .binding_id = try nextBindingId(context), .type_id = raw_void };
            params[4] = .{ .name = "task_ctx", .binding_id = try nextBindingId(context), .type_id = raw_void };

            const entry_local = try taskTrampolineLocal(context, allocator, path, program, module_name, "entry_ctx", params[0].binding_id.?, raw_void);
            const entry_cast = try taskTrampolineCast(context, allocator, path, program, module_name, entry_local, entry_type);
            const input_local = try taskTrampolineLocal(context, allocator, path, program, module_name, "input_ctx", params[1].binding_id.?, raw_void);
            const input_ptr_type = try canonicalRawTypeId(context, input_type, false);
            const input_cast = try taskTrampolineCast(context, allocator, path, program, module_name, input_local, input_ptr_type);
            const input_value = try allocator.create(sir.Expr);
            input_value.* = .{ .raw_deref = .{ .expr = input_cast, .is_volatile = false } };
            var input_typed = makeTypedExprFromId(input_value, input_type);
            try finalizeAndRecordExprSemantics(context, path, program, module_name, &input_typed);
            var input_metadata = semanticExprMetadata(context, input_value) orelse return error.SemanticFailed;
            input_metadata.checked_generated_payload_binding = params[1].binding_id.?;
            try recordExprMetadata(context, input_value, input_metadata);
            const args = try allocator.alloc(sir.CallArg, if (with_context) 2 else 1);
            var body_index: usize = 0;
            const body = try allocator.alloc(sir.Stmt, if (with_context) 2 else 1);
            if (context_type) |ctx_type| {
                const raw_context = try taskTrampolineLocal(context, allocator, path, program, module_name, "task_ctx", params[4].binding_id.?, raw_void);
                const fields = try allocator.alloc(sir.StructLiteralField, 1);
                fields[0] = .{ .name = "raw", .value = raw_context };
                const context_literal = try allocator.create(sir.Expr);
                context_literal.* = .{ .struct_literal = .{
                    .decl_id = try registeredDeclId(context, "std.thread", null, "TaskContext", .@"struct"),
                    .type_name = "TaskContext",
                    .type_module_name = "std.thread",
                    .fields = fields,
                } };
                var context_typed = makeTypedExprFromId(context_literal, ctx_type);
                try finalizeAndRecordExprSemantics(context, path, program, module_name, &context_typed);
                try recordExprSink(context, context_literal, .initialize);
                body[0] = .{ .local = .{ .name = "__task_context", .binding_id = try nextBindingId(context), .type_id = ctx_type, .init = context_literal } };
                body_index = 1;
                const context_ref = try allocator.create(sir.Expr);
                context_ref.* = .{ .ref_local = "__task_context" };
                var ref_typed = makeTypedExprFromId(context_ref, try canonicalRefTypeId(context, ctx_type));
                try finalizeAndRecordExprSemantics(context, path, program, module_name, &ref_typed);
                try recordGeneratedBindingRoot(context, context_ref, body[0].local.binding_id.?, true);
                args[0] = .{ .value = context_ref };
            }
            args[body_index] = .{ .value = input_value };
            const call_expr = try allocator.create(sir.Expr);
            call_expr.* = .{ .indirect_call = .{
                .callee = entry_cast,
                .args = args,
                .return_type_id = result_type,
            } };
            var call_typed = makeTypedExprFromId(call_expr, result_type);
            try finalizeAndRecordExprSemantics(context, path, program, module_name, &call_typed);

            if (canonicalTypeIsVoidLike(context, result_type)) {
                body[body_index] = .{ .expr = call_expr };
            } else {
                try recordExprSink(context, call_expr, .initialize);
                const result_local = try taskTrampolineLocal(context, allocator, path, program, module_name, "result_ctx", params[2].binding_id.?, raw_void);
                const result_ptr_type = try canonicalRawTypeId(context, result_type, false);
                const result_cast = try taskTrampolineCast(context, allocator, path, program, module_name, result_local, result_ptr_type);
                body[body_index] = .{ .deref_assign = .{
                    .pointer = result_cast,
                    .value = call_expr,
                    .is_init = true,
                } };
            }

            const decl_id = (try registerGeneratedDecl(context, module_name, null, name, .function)) orelse return error.SemanticFailed;
            if (input_metadata.semantics.ownership == .owned or input_metadata.semantics.ownership == .shared) {
                const payload_index: u32 = if (with_context) 1 else 0;
                const record: sir.Record = .{ .effect = .{ .move = .{
                    .source = .{ .generated_payload = params[1].binding_id.? },
                    .destination = .{ .call_slot = .{ .function_decl_id = decl_id, .index = payload_index } },
                } } };
                record.validate() catch return error.SemanticFailed;
                call_expr.indirect_call.checked_payload_transfer = record;
            }
            const indirect = &call_expr.indirect_call;
            if (indirect.args.len + 2 > indirect.checked_evaluation_sites.len) return error.SemanticFailed;
            var site_count: usize = 0;
            indirect.checked_evaluation_sites[site_count] = .{ .callee_value = indirect.callee };
            site_count += 1;
            for (indirect.args, 0..) |arg, index| {
                indirect.checked_evaluation_sites[site_count] = .{ .argument_value = arg.value };
                site_count += 1;
                if (index == body_index) {
                    if (indirect.checked_payload_transfer) |record| {
                        indirect.checked_evaluation_sites[site_count] = .{ .effect = record };
                        site_count += 1;
                    }
                }
            }
            indirect.checked_evaluation_sites_len = @intCast(site_count);
            try context.generic.instantiated_functions.append(allocator, .{
                .decl_id = decl_id,
                .module_name = module_name,
                .owner = null,
                .name = name,
                .abi_name = null,
                .is_extern = false,
                .is_export = false,
                .is_isolated = true,
                .calling_convention = .c,
                .params = params,
                .return_type_id = try canonicalPrimitiveTypeId(context, .void),
                .debug_token = debug_token,
                .body = body,
            });
            return name;
        }

        pub fn synthesizeHostedThreadTrampoline(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            entry: ast.Function,
            payload_type: semantic_types.TypeId,
        ) SemaError![]const u8 {
            const name = try std.fmt.allocPrint(allocator, "{s}{d}", .{ generated_names.thread_boxed_trampoline_prefix, context.anonymous_function_counter });
            context.anonymous_function_counter += 1;
            try context.output.generated_strings.append(allocator, name);

            const ctx_type = try canonicalRawTypeId(context, try canonicalPrimitiveTypeId(context, .c_void), false);
            const params = try allocator.alloc(sir.Param, 1);
            errdefer allocator.free(params);
            params[0] = .{
                .name = "ctx",
                .binding_id = try nextBindingId(context),
                .type_id = ctx_type,
            };

            const ctx_expr = try allocator.create(sir.Expr);
            var ctx_owned = true;
            errdefer if (ctx_owned) ctx_expr.destroy(allocator);
            ctx_expr.* = .{ .local = "ctx" };
            var ctx_typed = makeTypedExprFromId(ctx_expr, ctx_type);
            try finalizeAndRecordExprSemantics(context, path, program, entry.module_name, &ctx_typed);
            try recordGeneratedBindingRoot(context, ctx_expr, params[0].binding_id.?, false);

            const cast_expr = try allocator.create(sir.Expr);
            var cast_owned = true;
            errdefer if (cast_owned) cast_expr.destroy(allocator);
            const cast_type = try canonicalRawTypeId(context, payload_type, false);
            cast_expr.* = .{ .cast = .{
                .subject = ctx_expr,
                .target_type_id = cast_type,
                .union_case_name = null,
                .fallible = false,
                .reinterpret = true,
            } };
            var cast_typed = makeTypedExprFromId(cast_expr, cast_type);
            try finalizeAndRecordExprSemantics(context, path, program, entry.module_name, &cast_typed);
            ctx_owned = false;

            const payload_expr = try allocator.create(sir.Expr);
            var payload_owned = true;
            errdefer if (payload_owned) payload_expr.destroy(allocator);
            payload_expr.* = .{ .raw_deref = .{
                .expr = cast_expr,
                .is_volatile = false,
            } };
            var payload_typed = makeTypedExprFromId(payload_expr, payload_type);
            try finalizeAndRecordExprSemantics(context, path, program, entry.module_name, &payload_typed);
            var payload_metadata = semanticExprMetadata(context, payload_expr) orelse return error.SemanticFailed;
            payload_metadata.checked_generated_payload_binding = params[0].binding_id.?;
            try recordExprMetadata(context, payload_expr, payload_metadata);
            cast_owned = false;

            const args = try allocator.alloc(sir.CallArg, 1);
            var args_owned = true;
            errdefer if (args_owned) {
                for (args) |arg| switch (arg) {
                    .value => |value| value.destroy(allocator),
                };
                allocator.free(args);
            };
            args[0] = .{ .value = payload_expr };
            payload_owned = false;

            const call_expr = try allocator.create(sir.Expr);
            var call_owned = true;
            errdefer if (call_owned) call_expr.destroy(allocator);
            call_expr.* = .{ .call = .{
                .intrinsic_id = intrinsics.resolveDeclaration(entry.module_name, entry.owner, entry.name),
                .decl_id = maybeRegisteredDeclId(context, entry.module_name, entry.owner, entry.name, .function),
                .module_name = entry.module_name,
                .owner = entry.owner,
                .callee = entry.name,
                .args = args,
            } };
            const entry_return_type = if (entry.return_type) |type_name|
                try parseType(context, path, program, entry.module_name, type_name)
            else
                try canonicalPrimitiveTypeId(context, .void);
            try attachCheckedCallUse(context, call_expr, entry_return_type, context.function_state.active_source_decl_id, entry.name_token.offset);
            var call_typed = makeTypedExprFromId(call_expr, entry_return_type);
            try finalizeAndRecordExprSemantics(context, path, program, entry.module_name, &call_typed);
            args_owned = false;

            const body = try allocator.alloc(sir.Stmt, 1);
            var body_owned = true;
            errdefer if (body_owned) {
                for (body) |stmt| stmt.deinit(allocator);
                allocator.free(body);
            };
            body[0] = .{ .expr = call_expr };
            call_owned = false;

            const decl_id = (try registerGeneratedDecl(context, entry.module_name, null, name, .function)) orelse
                return error.SemanticFailed;
            try context.generic.instantiated_functions.append(allocator, .{
                .decl_id = decl_id,
                .module_name = entry.module_name,
                .owner = null,
                .name = name,
                .abi_name = null,
                .is_extern = false,
                .is_export = false,
                .is_isolated = true,
                .calling_convention = .c,
                .params = params,
                .return_type_id = try canonicalPrimitiveTypeId(context, .void),
                .debug_token = entry.name_token,
                .body = body,
            });
            body_owned = false;

            return name;
        }
    };
}

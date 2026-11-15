const std = @import("std");
const ast = @import("../parser/ast.zig");
const lexer = @import("../lexer/lexer.zig");
const diagnostics = @import("../diagnostics.zig");
const identity = @import("identity.zig");
const semantic_types = @import("types.zig");
const sir = @import("sir.zig");
const intrinsics = @import("../intrinsics.zig");
const declarations = @import("declarations.zig");
const generic_origins = @import("generic_origins.zig");
const generics = @import("generics.zig");
const session = @import("session.zig");
const type_resolution = @import("type_resolution.zig");

/// Canonical identity for one protocol conformance.
///
/// Source spellings and import aliases are deliberately absent: coherence is
/// a property of the resolved subject type and protocol declaration.
pub const Key = struct {
    subject: semantic_types.TypeId,
    protocol: identity.DeclId,
};

/// The implementation selected for one protocol method requirement.
///
/// This is semantic evidence, not a second overload-resolution system. Every
/// witness is fixed when its conformance is checked.
pub const Witness = union(enum) {
    source_function: identity.DeclId,
    derived_type_union,
    builtin_dense_clone,
};

pub const MethodWitness = struct {
    requirement_index: u32,
    implementation: Witness,
};

pub const AssociatedTypeBinding = struct {
    requirement_index: u32,
    type_id: semantic_types.TypeId,
};

pub const Record = struct {
    key: Key,
    /// Concrete arguments captured when a generic impl family materializes
    /// this conformance. Empty for an ordinary non-generic impl.
    generic_args: []semantic_types.GenericArgument,
    associated_types: []AssociatedTypeBinding,
    witnesses: []MethodWitness,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(Record) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.records.items) |record| {
            self.allocator.free(record.generic_args);
            self.allocator.free(record.associated_types);
            self.allocator.free(record.witnesses);
        }
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    /// Registers a resolved conformance. Returns false when the same canonical
    /// subject/protocol pair was already registered.
    pub fn register(self: *Registry, key: Key) !bool {
        if (self.find(key) != null) return false;
        const empty_generic_args = try self.allocator.alloc(semantic_types.GenericArgument, 0);
        errdefer self.allocator.free(empty_generic_args);
        const empty_witnesses = try self.allocator.alloc(MethodWitness, 0);
        errdefer self.allocator.free(empty_witnesses);
        const empty_associated_types = try self.allocator.alloc(AssociatedTypeBinding, 0);
        errdefer self.allocator.free(empty_associated_types);
        try self.records.append(self.allocator, .{
            .key = key,
            .generic_args = empty_generic_args,
            .associated_types = empty_associated_types,
            .witnesses = empty_witnesses,
        });
        return true;
    }

    pub fn setAssociatedTypes(self: *Registry, key: Key, bindings: []const AssociatedTypeBinding) !void {
        for (self.records.items) |*record| {
            if (record.key.subject != key.subject or record.key.protocol != key.protocol) continue;
            const owned = try self.allocator.dupe(AssociatedTypeBinding, bindings);
            self.allocator.free(record.associated_types);
            record.associated_types = owned;
            return;
        }
        unreachable;
    }

    /// Records the concrete substitution captured by a materialized generic
    /// impl family. Dispatch consumes these arguments directly; it never
    /// infers them again from method names or call arguments.
    pub fn setGenericArgs(self: *Registry, key: Key, args: []const semantic_types.GenericArgument) !void {
        for (self.records.items) |*record| {
            if (record.key.subject != key.subject or record.key.protocol != key.protocol) continue;
            const owned = try self.allocator.dupe(semantic_types.GenericArgument, args);
            self.allocator.free(record.generic_args);
            record.generic_args = owned;
            return;
        }
        unreachable;
    }

    pub fn find(self: *const Registry, key: Key) ?*const Record {
        for (self.records.items) |*record| {
            if (record.key.subject == key.subject and record.key.protocol == key.protocol) return record;
        }
        return null;
    }

    /// Completes a previously registered conformance after its implementation
    /// has been validated. Keeping this separate from registration makes
    /// conformance visibility independent of source order.
    pub fn setWitnesses(self: *Registry, key: Key, witnesses: []const MethodWitness) !void {
        for (self.records.items) |*record| {
            if (record.key.subject != key.subject or record.key.protocol != key.protocol) continue;
            const owned = try self.allocator.dupe(MethodWitness, witnesses);
            self.allocator.free(record.witnesses);
            record.witnesses = owned;
            return;
        }
        unreachable;
    }
};

test "conformance coherence uses canonical identities" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const subject_a: semantic_types.TypeId = @fromBackingInt(@intCast(1));
    const subject_b: semantic_types.TypeId = @fromBackingInt(@intCast(2));
    const protocol_a: identity.DeclId = @fromBackingInt(@intCast(10));
    const protocol_b: identity.DeclId = @fromBackingInt(@intCast(11));

    try std.testing.expect(try registry.register(.{ .subject = subject_a, .protocol = protocol_a }));
    try std.testing.expect(!(try registry.register(.{ .subject = subject_a, .protocol = protocol_a })));
    try std.testing.expect(try registry.register(.{ .subject = subject_a, .protocol = protocol_b }));
    try std.testing.expect(try registry.register(.{ .subject = subject_b, .protocol = protocol_a }));
}

test "conformance records own explicit method witnesses" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const key: Key = .{
        .subject = @fromBackingInt(@intCast(1)),
        .protocol = @fromBackingInt(@intCast(10)),
    };
    try std.testing.expect(try registry.register(key));
    try registry.setWitnesses(key, &.{
        .{ .requirement_index = 0, .implementation = .{ .source_function = @fromBackingInt(@intCast(20)) } },
        .{ .requirement_index = 1, .implementation = .derived_type_union },
    });

    const record = registry.find(key).?;
    try std.testing.expectEqual(@as(usize, 2), record.witnesses.len);
    try std.testing.expectEqual(@as(u32, 0), record.witnesses[0].requirement_index);
    try std.testing.expectEqual(@as(identity.DeclId, @fromBackingInt(@intCast(20))), record.witnesses[0].implementation.source_function);
    try std.testing.expect(record.witnesses[1].implementation == .derived_type_union);
}

test "materialized conformance owns its concrete generic arguments" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const key: Key = .{
        .subject = @fromBackingInt(@intCast(1)),
        .protocol = @fromBackingInt(@intCast(10)),
    };
    try std.testing.expect(try registry.register(key));
    try registry.setGenericArgs(key, &.{
        .{ .type = @fromBackingInt(@intCast(20)) },
        .{ .const_usize = 8 },
    });

    const record = registry.find(key).?;
    try std.testing.expectEqual(@as(usize, 2), record.generic_args.len);
    try std.testing.expectEqual(@as(semantic_types.TypeId, @fromBackingInt(@intCast(20))), record.generic_args[0].type);
    try std.testing.expectEqual(@as(usize, 8), record.generic_args[1].const_usize);
}

test "conformance records own concrete associated type bindings" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const key: Key = .{
        .subject = @fromBackingInt(@intCast(1)),
        .protocol = @fromBackingInt(@intCast(10)),
    };
    try std.testing.expect(try registry.register(key));
    try registry.setAssociatedTypes(key, &.{
        .{ .requirement_index = 0, .type_id = @fromBackingInt(@intCast(20)) },
        .{ .requirement_index = 1, .type_id = @fromBackingInt(@intCast(21)) },
    });

    const record = registry.find(key).?;
    try std.testing.expectEqual(@as(usize, 2), record.associated_types.len);
    try std.testing.expectEqual(@as(u32, 1), record.associated_types[1].requirement_index);
    try std.testing.expectEqual(@as(semantic_types.TypeId, @fromBackingInt(@intCast(21))), record.associated_types[1].type_id);
}

pub const Error = error{ SemanticFailed, OutOfMemory };

pub const Context = struct {
    allocator: std.mem.Allocator,
    diagnostic_context: *diagnostics.Context,
    policy: declarations.resolution.AccessPolicy,
    identity_registry: ?*identity.Registry,
    conformances: ?*Registry,
    interner: ?*semantic_types.TypeInterner,
    generic_scopes: ?*generic_origins.ScopeRegistry,
    display_context: type_resolution.DisplayContext,
};

pub fn contextFromSession(comptime SemaContext: type, context: *SemaContext) Context {
    return .{
        .allocator = context.allocator,
        .diagnostic_context = &context.diagnostic_context,
        .policy = .{ .friend = if (context.options.test_friend) |friend| .{
            .test_module = friend.test_module,
            .production_module = friend.production_module,
        } else null },
        .identity_registry = if (context.declarations.registry) |*registry| registry else null,
        .conformances = if (context.protocol_conformances) |*registry| registry else null,
        .interner = if (context.canonical.types) |*interner| interner else null,
        .generic_scopes = if (context.generic_scopes) |*scopes| scopes else null,
        .display_context = .{
            .types = .{
                .allocator = context.allocator,
                .abi_layout = context.abi_layout,
                .interner = if (context.canonical.types) |*interner| interner else null,
                .generated_strings = &context.output.generated_strings,
            },
            .registry = if (context.declarations.registry) |*registry| registry else null,
        },
    };
}

fn intern(context: Context, value: semantic_types.Type) Error!semantic_types.TypeId {
    const interner = context.interner orelse return error.SemanticFailed;
    return interner.intern(value) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidTypeId => error.SemanticFailed,
    };
}

fn genericParameterOf(context: Context, type_id: semantic_types.TypeId) ?semantic_types.GenericParameterRef {
    const interner = context.interner orelse unreachable;
    const node = interner.get(type_id) catch unreachable;
    return if (node.* == .generic_parameter) node.generic_parameter else null;
}

pub const ResolvedProtocolDecl = struct {
    id: identity.DeclId,
    decl: ast.ProtocolDecl,
};

pub fn resolveProtocolConstraint(context: Context, path: []const u8, program: ast.Program, current_module: []const u8, constraint: ast.TypeName) Error!ResolvedProtocolDecl {
    if (constraint.is_ref or constraint.is_owned or constraint.is_raw or constraint.is_volatile_raw or constraint.is_optional or constraint.is_slice or constraint.array_len != null or constraint.array_len_name != null or constraint.args.len != 0) {
        const notes = [_][]const u8{"generic constraints describe required protocols, not storage or container types"};
        try context.diagnostic_context.emitTokenWith(path, constraint.token, .{
            .code = .generic_constraint,
            .notes = &notes,
            .help = "name a protocol directly or use an `&`-separated protocol set",
        }, "generic constraints must be plain protocol names or `&` protocol sets", .{});
        return Error.SemanticFailed;
    }
    const decl = declarations.resolution.accessibleProtocol(context.policy, program, current_module, constraint.name) orelse {
        const notes = [_][]const u8{"constraint lookup searches visible protocol declarations"};
        try context.diagnostic_context.emitTokenWith(path, constraint.token, .{
            .code = .generic_constraint,
            .notes = &notes,
            .help = "declare or import the protocol before using it as a constraint",
        }, "unknown protocol constraint `{s}`", .{constraint.name});
        return Error.SemanticFailed;
    };
    return .{
        .id = try declarations.registration.find(context.identity_registry, decl.module_name, null, decl.name, .protocol),
        .decl = decl,
    };
}

pub fn applyAssociatedProjectionShape(
    context: Context,
    path: []const u8,
    type_name: ast.TypeName,
    base: semantic_types.TypeId,
) Error!semantic_types.TypeId {
    if (type_name.args.len != 0 or type_name.array_len != null or type_name.array_len_name != null or type_name.is_slice or type_name.is_function or type_name.is_arrow_callable or type_name.is_owned or type_name.is_raw) {
        try context.diagnostic_context.emitToken(path, type_name.token, "associated type projections support only direct values, references, and optionals", .{});
        return Error.SemanticFailed;
    }
    var result = base;
    if (type_name.is_ref) result = if (type_name.ref_is_const) try intern(context, .{ .ref_ = .{ .target = result, .is_const = true } }) else try intern(context, .{ .ref_ = .{ .target = result, .is_const = false } });
    if (type_name.is_optional) result = try intern(context, .{ .optional = result });
    return result;
}

pub fn resolveAssociatedTypeProjection(
    context: Context,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    type_name: ast.TypeName,
    self_type: ?semantic_types.TypeId,
    generic_params: []const ast.GenericParam,
    generic_args: []const semantic_types.GenericArgument,
) Error!?semantic_types.TypeId {
    const qualifier = type_name.module_name orelse return null;
    var subject: ?semantic_types.TypeId = null;
    var candidate_protocol: ?ResolvedProtocolDecl = null;

    if (std.mem.eql(u8, qualifier, "Self")) {
        subject = self_type orelse return null;
        const subject_is_binder = genericParameterOf(context, subject.?) != null;
        for (program.protocols) |protocol_decl| {
            const associated_index = for (protocol_decl.associated_types, 0..) |associated, index| {
                if (std.mem.eql(u8, associated.name, type_name.name)) break @as(u32, @intCast(index));
            } else continue;
            // At the definition site `Self` is a binder with no witness yet, so
            // the associated type has no concrete type to name; it stays
            // deferred and every specialization re-resolves it after substituting.
            if (subject_is_binder) return subject.?;
            const protocol_id = try declarations.registration.find(context.identity_registry, protocol_decl.module_name, null, protocol_decl.name, .protocol);
            const conformances = context.conformances orelse return Error.SemanticFailed;
            if (conformances.find(.{ .subject = subject.?, .protocol = protocol_id }) == null) continue;
            _ = associated_index;
            if (candidate_protocol != null) {
                try context.diagnostic_context.emitToken(path, type_name.token, "associated type projection `Self.{s}` is ambiguous", .{type_name.name});
                return Error.SemanticFailed;
            }
            candidate_protocol = .{ .id = protocol_id, .decl = protocol_decl };
        }
    } else {
        for (generic_params, 0..) |param, index| {
            if (!std.mem.eql(u8, qualifier, param.name) or param.is_const_value) continue;
            if (index >= generic_args.len or generic_args[index] != .type) return null;
            subject = generic_args[index].type;
            var constraints: std.ArrayListUnmanaged(ast.TypeName) = .empty;
            defer constraints.deinit(context.allocator);
            if (param.constraint) |constraint| try constraints.append(context.allocator, constraint);
            try constraints.appendSlice(context.allocator, param.extra_constraints);
            for (constraints.items) |constraint| {
                const protocol = try resolveProtocolConstraint(context, path, program, current_module, constraint);
                const defines = for (protocol.decl.associated_types) |associated| {
                    if (std.mem.eql(u8, associated.name, type_name.name)) break true;
                } else false;
                if (!defines) continue;
                if (candidate_protocol != null) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "associated type projection `{s}.{s}` is ambiguous between protocol bounds", .{ qualifier, type_name.name });
                    return Error.SemanticFailed;
                }
                candidate_protocol = protocol;
            }
            break;
        }
    }

    const resolved_subject = subject orelse return null;
    const protocol = candidate_protocol orelse return null;
    const requirement_index = for (protocol.decl.associated_types, 0..) |associated, index| {
        if (std.mem.eql(u8, associated.name, type_name.name)) break @as(u32, @intCast(index));
    } else return null;
    const conformances = context.conformances orelse return Error.SemanticFailed;
    const record = conformances.find(.{ .subject = resolved_subject, .protocol = protocol.id }) orelse blk: {
        // At the definition site the `Self` subject is a binder with no witness
        // yet, so the associated type stays deferred until a specialization
        // supplies the concrete type.
        if (genericParameterOf(context, resolved_subject) != null) {
            break :blk null;
        }
        try context.diagnostic_context.emitToken(path, type_name.token, "type does not provide associated type `{s}` for protocol `{s}`", .{ type_name.name, protocol.decl.name });
        return Error.SemanticFailed;
    };
    if (record == null) return resolved_subject;
    const base = for (record.?.associated_types) |binding| {
        if (binding.requirement_index == requirement_index) break binding.type_id;
    } else return Error.SemanticFailed;
    return try applyAssociatedProjectionShape(context, path, type_name, base);
}

pub fn validateGenericParamProtocolConstraints(context: Context, path: []const u8, program: ast.Program, current_module: []const u8, param: ast.GenericParam) Error!void {
    if (param.constraint == null) {
        if (param.extra_constraints.len != 0) {
            try context.diagnostic_context.emitToken(path, param.name_token, "protocol constraint set requires an initial protocol name", .{});
            return Error.SemanticFailed;
        }
        return;
    }

    const first = (try resolveProtocolConstraint(context, path, program, current_module, param.constraint.?)).decl;
    for (param.extra_constraints) |constraint| {
        const next = (try resolveProtocolConstraint(context, path, program, current_module, constraint)).decl;
        try checkProtocolRequirementConflicts(context, path, first, next, constraint.token);
    }
    for (param.extra_constraints, 0..) |left_constraint, i| {
        const left = (try resolveProtocolConstraint(context, path, program, current_module, left_constraint)).decl;
        for (param.extra_constraints[i + 1 ..]) |right_constraint| {
            const right = (try resolveProtocolConstraint(context, path, program, current_module, right_constraint)).decl;
            try checkProtocolRequirementConflicts(context, path, left, right, right_constraint.token);
        }
    }
}

/// A definition-site binder may rely on the protocols declared on its own
/// generic parameter. Concrete substitutions are checked separately.
pub fn binderDeclaresProtocolConstraint(context: Context, program: ast.Program, protocol: ResolvedProtocolDecl, subject: semantic_types.TypeId) bool {
    const scopes = context.generic_scopes orelse return false;
    const ref = genericParameterOf(context, subject) orelse return false;
    const id: generic_origins.ParamId = .{ .scope = ref.scope, .ordinal = ref.ordinal };
    const param = scopes.paramDecl(id) orelse return false;
    const module_name = scopes.paramModule(id) orelse return false;
    if (param.constraint) |constraint| {
        if (constraintNamesProtocol(context, program, module_name, constraint, protocol)) return true;
    }
    for (param.extra_constraints) |constraint| {
        if (constraintNamesProtocol(context, program, module_name, constraint, protocol)) return true;
    }
    return false;
}

fn constraintNamesProtocol(context: Context, program: ast.Program, requester_module: []const u8, constraint: ast.TypeName, protocol: ResolvedProtocolDecl) bool {
    const decl = declarations.resolution.accessibleProtocol(context.policy, program, requester_module, constraint.name) orelse return false;
    return std.mem.eql(u8, decl.module_name, protocol.decl.module_name) and
        std.mem.eql(u8, decl.name, protocol.decl.name);
}

fn checkProtocolRequirementConflicts(context: Context, path: []const u8, left: ast.ProtocolDecl, right: ast.ProtocolDecl, token: lexer.Token) Error!void {
    for (left.associated_types) |left_associated| {
        for (right.associated_types) |right_associated| {
            if (!std.mem.eql(u8, left_associated.name, right_associated.name)) continue;
            try context.diagnostic_context.emitToken(path, token, "protocol constraint set has ambiguous associated type `{s}`", .{left_associated.name});
            return Error.SemanticFailed;
        }
    }
    for (left.methods) |left_method| {
        for (right.methods) |right_method| {
            if (!std.mem.eql(u8, left_method.name, right_method.name)) continue;
            if (sameProtocolMethodRequirement(left_method, right_method)) continue;
            try context.diagnostic_context.emitToken(path, token, "protocol constraint set has conflicting method requirement `{s}`", .{left_method.name});
            return Error.SemanticFailed;
        }
    }
}

fn sameProtocolMethodRequirement(left: ast.ProtocolMethod, right: ast.ProtocolMethod) bool {
    if (left.params.len != right.params.len) return false;
    for (left.params, right.params) |left_param, right_param| {
        if (!declarations.sameTypeName(left_param.type_name, right_param.type_name)) return false;
    }
    if (left.return_type == null and right.return_type == null) return true;
    if (left.return_type == null or right.return_type == null) return false;
    return declarations.sameTypeName(left.return_type.?, right.return_type.?);
}

pub fn expectGenericParamProtocolConformance(
    comptime SemaContext: type,
    comptime typeIsOwned: anytype,
    session_context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    param: ast.GenericParam,
    token: lexer.Token,
    ty: semantic_types.TypeId,
) Error!void {
    const context = contextFromSession(SemaContext, session_context);
    if (param.constraint) |constraint| {
        const protocol = try resolveProtocolConstraint(context, path, program, current_module, constraint);
        try expectProtocolConformance(SemaContext, typeIsOwned, session_context, path, program, current_module, token, ty, protocol, param);
    }
    for (param.extra_constraints) |constraint| {
        const protocol = try resolveProtocolConstraint(context, path, program, current_module, constraint);
        try expectProtocolConformance(SemaContext, typeIsOwned, session_context, path, program, current_module, token, ty, protocol, param);
    }
}

pub fn expectProtocolConformance(
    comptime SemaContext: type,
    comptime typeIsOwned: anytype,
    session_context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    generic_module: []const u8,
    token: lexer.Token,
    ty: semantic_types.TypeId,
    protocol: ResolvedProtocolDecl,
    generic_param: ?ast.GenericParam,
) Error!void {
    const context = contextFromSession(SemaContext, session_context);
    const conformances = context.conformances orelse return Error.SemanticFailed;
    if (conformances.find(.{ .subject = ty, .protocol = protocol.id }) != null) return;
    if (try isTrustedDenseCloneConformance(SemaContext, typeIsOwned, session_context, path, program, ty, protocol)) return;
    return emitMissingProtocolConformance(context, path, program, generic_module, token, ty, protocol, generic_param);
}

pub fn isTrustedDenseCloneConformance(
    comptime SemaContext: type,
    comptime typeIsOwned: anytype,
    session_context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    subject: semantic_types.TypeId,
    protocol: ResolvedProtocolDecl,
) Error!bool {
    const context = contextFromSession(SemaContext, session_context);
    const interner = context.interner orelse return Error.SemanticFailed;
    const node = interner.get(subject) catch unreachable;
    if (node.* != .dense_array) return false;
    if (!std.mem.eql(u8, protocol.decl.module_name, "std.prelude") or
        !std.mem.eql(u8, protocol.decl.name, "Clone")) return false;
    if (protocol.decl.methods.len != 1) return false;
    if (!std.mem.eql(u8, protocol.decl.methods[0].name, "clone")) return false;
    // Dense copy uses the element descriptor. An owned element would be copied
    // as a handle and cannot be a lawful Clone witness.
    if (try typeIsOwned(session_context, path, program, protocol.decl.module_name, node.dense_array)) return false;
    const conformances = context.conformances orelse return Error.SemanticFailed;
    const key: Key = .{ .subject = subject, .protocol = protocol.id };
    if (conformances.find(key) == null) {
        _ = try conformances.register(key);
        try conformances.setWitnesses(key, &.{.{
            .requirement_index = 0,
            .implementation = .builtin_dense_clone,
        }});
    }
    return true;
}

fn emitMissingProtocolConformance(
    context: Context,
    path: []const u8,
    program: ast.Program,
    generic_module: []const u8,
    token: lexer.Token,
    ty: semantic_types.TypeId,
    protocol: ResolvedProtocolDecl,
    generic_param: ?ast.GenericParam,
) Error!void {
    const conformances = context.conformances orelse return Error.SemanticFailed;
    if (conformances.find(.{ .subject = ty, .protocol = protocol.id }) != null) return;
    if (binderDeclaresProtocolConstraint(context, program, protocol, ty)) return;

    const type_display = try type_resolution.formatDisplay(context.display_context, ty, .diagnostic);
    defer context.allocator.free(type_display);
    const protocol_display = try qualifiedDeclDisplay(context.allocator, protocol.decl.module_name, protocol.decl.name);
    defer context.allocator.free(protocol_display);
    if (generic_param) |param| {
        const substitution = try std.fmt.allocPrint(context.allocator, "concrete substitution: {s} = {s}", .{ param.name, type_display });
        defer context.allocator.free(substitution);
        const notes = [_][]const u8{
            substitution,
            "the substituted type must satisfy every declared protocol constraint",
        };
        const labels = [_]diagnostics.Label{
            .{
                .span = declarationSpan(program, path, generic_module, param.name_token),
                .message = "generic parameter declared here",
            },
            .{
                .span = declarationSpan(program, path, protocol.decl.module_name, protocol.decl.name_token),
                .message = "required protocol declared here",
            },
        };
        try context.diagnostic_context.emitTokenWith(path, token, .{
            .code = .generic_constraint,
            .labels = &labels,
            .notes = &notes,
            .help = "use a type with a matching impl or relax the generic constraint",
        }, "type `{s}` does not implement protocol `{s}`", .{ type_display, protocol_display });
    } else {
        const labels = [_]diagnostics.Label{.{
            .span = declarationSpan(program, path, protocol.decl.module_name, protocol.decl.name_token),
            .message = "required protocol declared here",
        }};
        const notes = [_][]const u8{"this type must have a matching protocol implementation"};
        try context.diagnostic_context.emitTokenWith(path, token, .{
            .code = .generic_constraint,
            .labels = &labels,
            .notes = &notes,
            .help = "add a matching impl or use a conforming type",
        }, "type `{s}` does not implement protocol `{s}`", .{ type_display, protocol_display });
    }
    return Error.SemanticFailed;
}

fn qualifiedDeclDisplay(allocator: std.mem.Allocator, module_name: []const u8, name: []const u8) Error![]const u8 {
    if (module_name.len == 0) return try allocator.dupe(u8, name);
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ module_name, name });
}

fn declarationSpan(program: ast.Program, fallback_path: []const u8, module_name: []const u8, token: lexer.Token) diagnostics.SourceSpan {
    for (program.module_infos) |info| {
        if (std.mem.eql(u8, info.name, module_name) and info.source_path.len != 0) return diagnostics.SourceSpan.fromToken(info.source_path, token);
    }
    return diagnostics.SourceSpan.fromToken(fallback_path, token);
}

pub fn validateAssociatedProjectionName(
    context: Context,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    type_name: ast.TypeName,
    generic_params: []const ast.GenericParam,
) Error!bool {
    const qualifier = type_name.module_name orelse return false;
    const param = for (generic_params) |candidate| {
        if (!candidate.is_const_value and std.mem.eql(u8, candidate.name, qualifier)) break candidate;
    } else return false;
    if (type_name.args.len != 0 or type_name.array_len != null or type_name.array_len_name != null or type_name.is_slice or type_name.is_function or type_name.is_arrow_callable or type_name.is_owned or type_name.is_raw) {
        try context.diagnostic_context.emitToken(path, type_name.token, "associated type projections support only direct values, references, and optionals", .{});
        return Error.SemanticFailed;
    }
    var matches: usize = 0;
    if (param.constraint) |constraint| {
        const protocol = try resolveProtocolConstraint(context, path, program, current_module, constraint);
        for (protocol.decl.associated_types) |associated| {
            if (std.mem.eql(u8, associated.name, type_name.name)) matches += 1;
        }
    }
    for (param.extra_constraints) |constraint| {
        const protocol = try resolveProtocolConstraint(context, path, program, current_module, constraint);
        for (protocol.decl.associated_types) |associated| {
            if (std.mem.eql(u8, associated.name, type_name.name)) matches += 1;
        }
    }
    if (matches == 0) {
        try context.diagnostic_context.emitToken(path, type_name.token, "no protocol bound on `{s}` declares associated type `{s}`", .{ qualifier, type_name.name });
        return Error.SemanticFailed;
    }
    if (matches > 1) {
        try context.diagnostic_context.emitToken(path, type_name.token, "associated type projection `{s}.{s}` is ambiguous between protocol bounds", .{ qualifier, type_name.name });
        return Error.SemanticFailed;
    }
    return true;
}

pub fn checkDeclarations(
    comptime SemaContext: type,
    comptime parseTypeDepth: anytype,
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
) Error!void {
    const placeholder_self = try type_resolution.primitive(contextFromSession(SemaContext, context).display_context.types, .bool);

    for (program.protocols) |decl| {
        for (decl.associated_types, 0..) |associated, associated_index| {
            for (decl.associated_types[0..associated_index]) |existing| {
                if (!std.mem.eql(u8, associated.name, existing.name)) continue;
                try context.diagnostic_context.emitToken(path, associated.name_token, "duplicate associated type `{s}`", .{associated.name});
                return Error.SemanticFailed;
            }
        }
        for (decl.methods) |method| {
            if (method.params.len == 0) {
                try context.diagnostic_context.emitToken(path, method.name_token, "protocol methods must declare a `self` parameter", .{});
                return Error.SemanticFailed;
            }

            if (!isProtocolSelfReceiverTypeName(method.params[0].type_name)) {
                try context.diagnostic_context.emitToken(path, method.params[0].name_token, "protocol method receiver must be `Self` or `&Self`", .{});
                return Error.SemanticFailed;
            }

            for (method.params[1..]) |param| {
                if (protocolAssociatedProjection(decl, param.type_name) == null)
                    _ = try parseTypeDepth(context, path, program, decl.module_name, param.type_name, placeholder_self, &.{}, &.{}, 0);
            }
            if (method.return_type) |return_type| {
                if (protocolAssociatedProjection(decl, return_type) == null)
                    _ = try parseTypeDepth(context, path, program, decl.module_name, return_type, placeholder_self, &.{}, &.{}, 0);
            }
        }
    }
}

pub fn protocolAssociatedProjection(decl: ast.ProtocolDecl, type_name: ast.TypeName) ?u32 {
    const qualifier = type_name.module_name orelse return null;
    if (!std.mem.eql(u8, qualifier, "Self")) return null;
    for (decl.associated_types, 0..) |associated, index| {
        if (std.mem.eql(u8, associated.name, type_name.name)) return @intCast(index);
    }
    return null;
}

fn isProtocolSelfReceiverTypeName(type_name: ast.TypeName) bool {
    return !type_name.is_const_value_arg and
        type_name.const_value == null and
        !type_name.is_owned and
        !type_name.is_raw and
        !type_name.is_volatile_raw and
        !type_name.is_optional and
        !type_name.is_function and
        !type_name.is_arrow_callable and
        !type_name.is_slice and
        type_name.array_len == null and
        type_name.array_len_name == null and
        type_name.module_name == null and
        type_name.args.len == 0 and
        std.mem.eql(u8, type_name.name, "Self");
}

fn findAssociatedTypeBinding(decl: ast.ImplDecl, name: []const u8) ?ast.AssociatedTypeBinding {
    for (decl.associated_types) |binding| {
        if (std.mem.eql(u8, binding.name, name)) return binding;
    }
    return null;
}

pub fn validateAssociatedTypeBindings(
    context: Context,
    path: []const u8,
    protocol_decl: ast.ProtocolDecl,
    impl_decl: ast.ImplDecl,
) Error!void {
    for (impl_decl.associated_types, 0..) |binding, binding_index| {
        for (impl_decl.associated_types[0..binding_index]) |existing| {
            if (!std.mem.eql(u8, binding.name, existing.name)) continue;
            try context.diagnostic_context.emitToken(path, binding.name_token, "duplicate associated type binding `{s}`", .{binding.name});
            return Error.SemanticFailed;
        }
        const declared = for (protocol_decl.associated_types) |required| {
            if (std.mem.eql(u8, binding.name, required.name)) break true;
        } else false;
        if (!declared) {
            try context.diagnostic_context.emitToken(path, binding.name_token, "associated type `{s}` is not declared by protocol `{s}`", .{ binding.name, protocol_decl.name });
            return Error.SemanticFailed;
        }
    }
    for (protocol_decl.associated_types) |required| {
        if (findAssociatedTypeBinding(impl_decl, required.name) != null) continue;
        try context.diagnostic_context.emitToken(path, impl_decl.token, "protocol impl is missing associated type `{s}`", .{required.name});
        return Error.SemanticFailed;
    }
}

pub fn materializeAssociatedTypeBindings(
    comptime SemaContext: type,
    comptime parseTypeDepth: anytype,
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    protocol: ResolvedProtocolDecl,
    impl_decl: ast.ImplDecl,
    key: Key,
    generic_params: []const ast.GenericParam,
    generic_args: []const semantic_types.GenericArgument,
) Error!void {
    const conformances = contextFromSession(SemaContext, context).conformances orelse return Error.SemanticFailed;
    var bindings: std.ArrayListUnmanaged(AssociatedTypeBinding) = .empty;
    defer bindings.deinit(context.allocator);
    for (protocol.decl.associated_types, 0..) |required, index| {
        const binding = findAssociatedTypeBinding(impl_decl, required.name) orelse return Error.SemanticFailed;
        const type_id = try parseTypeDepth(context, path, program, impl_decl.module_name, binding.type_name, null, generic_params, generic_args, 0);
        try bindings.append(context.allocator, .{ .requirement_index = @intCast(index), .type_id = type_id });
    }
    try conformances.setAssociatedTypes(key, bindings.items);
}

pub fn checkGenericImplDeclaration(
    context: Context,
    path: []const u8,
    decl: ast.ImplDecl,
    protocol_decl: ast.ProtocolDecl,
    target_decl: ast.StructDecl,
) Error!void {
    try validateAssociatedTypeBindings(context, path, protocol_decl, decl);
    if (decl.methods.len == 0) {
        try context.diagnostic_context.emitToken(path, decl.token, "generic struct protocol impl must declare its method bodies", .{});
        return Error.SemanticFailed;
    }
    for (decl.methods, 0..) |method, method_index| {
        if (method.type_params.len != 0) {
            try context.diagnostic_context.emitToken(path, method.name_token, "protocol implementation methods cannot be generic", .{});
            return Error.SemanticFailed;
        }
        for (decl.methods[0..method_index]) |existing| {
            if (!std.mem.eql(u8, method.name, existing.name)) continue;
            try context.diagnostic_context.emitToken(path, method.name_token, "duplicate protocol implementation method `{s}`", .{method.name});
            return Error.SemanticFailed;
        }
        const declared = for (protocol_decl.methods) |required| {
            if (std.mem.eql(u8, method.name, required.name)) break true;
        } else false;
        if (!declared) {
            try context.diagnostic_context.emitToken(path, method.name_token, "method `{s}` is not declared by protocol `{s}`", .{ method.name, protocol_decl.name });
            return Error.SemanticFailed;
        }
        if (findMethodInStruct(target_decl, method.name) != null) {
            try context.diagnostic_context.emitToken(path, method.name_token, "protocol method `{s}` conflicts with an inherent method of `{s}`", .{ method.name, target_decl.name });
            return Error.SemanticFailed;
        }
    }
    for (protocol_decl.methods) |required| {
        if (findMethodInImpl(decl, required.name) != null) continue;
        try context.diagnostic_context.emitToken(path, decl.token, "type family `{s}` is missing required protocol method `{s}`", .{ target_decl.name, required.name });
        return Error.SemanticFailed;
    }
}

pub fn findMethodInStruct(decl: ast.StructDecl, name: []const u8) ?ast.Function {
    for (decl.methods) |method| {
        if (std.mem.eql(u8, method.name, name)) return method;
    }
    return null;
}

pub fn findMethodInImpl(decl: ast.ImplDecl, name: []const u8) ?ast.Function {
    for (decl.methods) |method| {
        if (std.mem.eql(u8, method.name, name)) return method;
    }
    return null;
}

pub fn checkProtocolMethodSignature(
    comptime SemaContext: type,
    comptime parseTypeDepth: anytype,
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    protocol_decl: ast.ProtocolDecl,
    required: ast.ProtocolMethod,
    method: ast.Function,
    self_type: semantic_types.TypeId,
    generic_params: []const ast.GenericParam,
    generic_args: []const semantic_types.GenericArgument,
) Error!void {
    if (method.params.len != required.params.len) {
        try context.diagnostic_context.emitToken(path, method.name_token, "method `{s}` does not match protocol parameter count", .{method.name});
        return Error.SemanticFailed;
    }

    for (required.params, method.params, 0..) |required_param, actual_param, param_i| {
        const expected = try parseProtocolRequirementType(SemaContext, parseTypeDepth, context, path, program, protocol_decl, required_param.type_name, self_type);
        const actual = try parseTypeDepth(context, path, program, method.module_name, actual_param.type_name, null, generic_params, generic_args, 0);
        if (expected != actual) {
            const token = if (param_i == 0) method.name_token else actual_param.name_token;
            try context.diagnostic_context.emitToken(path, token, "method `{s}` does not match protocol parameter type", .{method.name});
            return Error.SemanticFailed;
        }
    }

    const expected_return = if (required.return_type) |return_type|
        try parseProtocolRequirementType(SemaContext, parseTypeDepth, context, path, program, protocol_decl, return_type, self_type)
    else
        try type_resolution.primitive(contextFromSession(SemaContext, context).display_context.types, .void);
    const actual_return = if (method.return_type) |return_type|
        try parseTypeDepth(context, path, program, method.module_name, return_type, null, generic_params, generic_args, 0)
    else
        try type_resolution.primitive(contextFromSession(SemaContext, context).display_context.types, .void);
    if (expected_return != actual_return) {
        try context.diagnostic_context.emitToken(path, method.name_token, "method `{s}` does not match protocol return type", .{method.name});
        return Error.SemanticFailed;
    }
}

fn parseProtocolRequirementType(
    comptime SemaContext: type,
    comptime parseTypeDepth: anytype,
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    protocol_decl: ast.ProtocolDecl,
    type_name: ast.TypeName,
    self_type: semantic_types.TypeId,
) Error!semantic_types.TypeId {
    if (protocolAssociatedProjection(protocol_decl, type_name)) |requirement_index| {
        const protocol_id = try declarations.registration.find(if (context.declarations.registry) |*registry| registry else null, protocol_decl.module_name, null, protocol_decl.name, .protocol);
        const conformances = contextFromSession(SemaContext, context).conformances orelse return Error.SemanticFailed;
        const record = conformances.find(.{ .subject = self_type, .protocol = protocol_id }) orelse return Error.SemanticFailed;
        const associated = for (record.associated_types) |binding| {
            if (binding.requirement_index == requirement_index) break binding.type_id;
        } else return Error.SemanticFailed;
        return applyAssociatedProjectionShape(contextFromSession(SemaContext, context), path, type_name, associated);
    }
    return parseTypeDepth(context, path, program, protocol_decl.module_name, type_name, self_type, context.function_state.current_generic_params, context.function_state.current_generic_args, 0);
}

/// A binder may rely on its declared bounds at the definition site. A
/// concrete substitution is checked again when its family is instantiated.
fn conformanceHolds(
    comptime SemaContext: type,
    comptime typeIsOwned: anytype,
    session_context: *SemaContext,
    context: Context,
    path: []const u8,
    program: ast.Program,
    subject: semantic_types.TypeId,
    protocol: ResolvedProtocolDecl,
) Error!bool {
    const conformances = context.conformances orelse return Error.SemanticFailed;
    if (conformances.find(.{ .subject = subject, .protocol = protocol.id }) != null) return true;
    if (try isTrustedDenseCloneConformance(SemaContext, typeIsOwned, session_context, path, program, subject, protocol)) return true;
    return binderDeclaresProtocolConstraint(context, program, protocol, subject);
}

pub fn genericConditionsSatisfied(
    comptime SemaContext: type,
    comptime typeIsOwned: anytype,
    session_context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    module_name: []const u8,
    params: []const ast.GenericParam,
    args: []const semantic_types.GenericArgument,
) Error!bool {
    const context = contextFromSession(SemaContext, session_context);
    if (context.conformances == null) return Error.SemanticFailed;
    for (params, args) |param, arg| {
        if (param.is_const_value) continue;
        const subject = switch (arg) {
            .type => |type_id| type_id,
            .const_usize => return false,
        };
        if (param.constraint) |constraint| {
            const protocol = try resolveProtocolConstraint(context, path, program, module_name, constraint);
            if (!try conformanceHolds(SemaContext, typeIsOwned, session_context, context, path, program, subject, protocol)) return false;
        }
        for (param.extra_constraints) |constraint| {
            const protocol = try resolveProtocolConstraint(context, path, program, module_name, constraint);
            if (!try conformanceHolds(SemaContext, typeIsOwned, session_context, context, path, program, subject, protocol)) return false;
        }
    }
    return true;
}

pub const ResolvedImplStruct = struct {
    id: identity.DeclId,
    decl: ast.StructDecl,
};

pub const ResolvedImplTypeUnion = struct {
    id: identity.DeclId,
    decl: ast.UnionDecl,
};

pub const ImplTarget = union(enum) {
    @"struct": ResolvedImplStruct,
    type_union: ResolvedImplTypeUnion,
    builtin: semantic_types.TypeId,
};

pub const GenericImplTarget = struct {
    id: identity.DeclId,
    decl: ast.StructDecl,
};

fn isPlainGenericImplArgument(type_name: ast.TypeName) bool {
    return !type_name.is_const_value_arg and
        type_name.const_value == null and
        !type_name.is_ref and
        !type_name.is_owned and
        !type_name.is_raw and
        !type_name.is_volatile_raw and
        !type_name.is_optional and
        !type_name.is_function and
        !type_name.is_arrow_callable and
        !type_name.is_slice and
        type_name.array_len == null and
        type_name.array_len_name == null and
        type_name.module_name == null and
        type_name.args.len == 0;
}

pub fn resolveGenericImplTarget(context: Context, path: []const u8, program: ast.Program, decl: ast.ImplDecl) Error!GenericImplTarget {
    if (decl.type_params.len == 0) return error.SemanticFailed;
    if (decl.type_name.is_ref or decl.type_name.is_owned or decl.type_name.is_raw or decl.type_name.is_volatile_raw or decl.type_name.is_optional or decl.type_name.is_slice or decl.type_name.array_len != null) {
        try context.diagnostic_context.emitToken(path, decl.type_name.token, "generic impl target must be an owned nominal type family", .{});
        return Error.SemanticFailed;
    }
    const target_module = if (decl.type_name.module_name) |module_alias| blk: {
        const module_name = declarations.resolution.rootPackageImportedModulePath(program, decl.module_name, module_alias) orelse {
            try context.diagnostic_context.emitToken(path, decl.type_name.token, "impl target module `{s}` is not owned by this package", .{module_alias});
            return Error.SemanticFailed;
        };
        break :blk module_name;
    } else decl.module_name;
    const target = declarations.resolution.structInModule(program, target_module, decl.type_name.name) orelse {
        try context.diagnostic_context.emitToken(path, decl.type_name.token, "generic impl target must name a generic struct owned by this package", .{});
        return Error.SemanticFailed;
    };
    if (target.type_params.len == 0) {
        try context.diagnostic_context.emitToken(path, decl.type_name.token, "generic impl parameters require a generic subject type", .{});
        return Error.SemanticFailed;
    }
    if (decl.type_params.len != target.type_params.len or decl.type_name.args.len != target.type_params.len) {
        try context.diagnostic_context.emitToken(path, decl.type_name.token, "generic impl must bind every subject type parameter exactly once", .{});
        return Error.SemanticFailed;
    }
    for (decl.type_params, target.type_params, decl.type_name.args) |impl_param, target_param, argument| {
        if (impl_param.is_const_value != target_param.is_const_value or
            !isPlainGenericImplArgument(argument) or
            !std.mem.eql(u8, argument.name, impl_param.name))
        {
            try context.diagnostic_context.emitToken(path, argument.token, "generic impl subject arguments must directly match their declared impl parameters", .{});
            return Error.SemanticFailed;
        }
    }
    return .{
        .id = try declarations.registration.find(context.identity_registry, target.module_name, null, target.name, .@"struct"),
        .decl = target,
    };
}

pub fn resolveImplTarget(context: Context, path: []const u8, program: ast.Program, decl: ast.ImplDecl) Error!ImplTarget {
    if (decl.type_name.is_ref or decl.type_name.is_owned or decl.type_name.is_raw or decl.type_name.is_volatile_raw or decl.type_name.is_optional or decl.type_name.is_slice or decl.type_name.array_len != null or decl.type_name.args.len != 0) {
        try context.diagnostic_context.emitToken(path, decl.type_name.token, "impl target must be a plain struct or type-union name", .{});
        return Error.SemanticFailed;
    }
    const target_module = if (decl.type_name.module_name) |module_alias| blk: {
        const module_name = declarations.resolution.rootPackageImportedModulePath(program, decl.module_name, module_alias) orelse {
            try context.diagnostic_context.emitToken(path, decl.type_name.token, "impl target module `{s}` is not owned by this package", .{module_alias});
            return Error.SemanticFailed;
        };
        break :blk module_name;
    } else decl.module_name;
    if (declarations.resolution.structInModule(program, target_module, decl.type_name.name)) |target| {
        if (target.type_params.len != 0) {
            try context.diagnostic_context.emitToken(path, decl.type_name.token, "generic struct impl must declare matching impl parameters and subject arguments", .{});
            return Error.SemanticFailed;
        }
        return .{ .@"struct" = .{
            .id = try declarations.registration.find(context.identity_registry, target.module_name, null, target.name, .@"struct"),
            .decl = target,
        } };
    }
    if (declarations.resolution.unionInModule(program, target_module, decl.type_name.name)) |target| {
        if (target.kind != .type_union) {
            try context.diagnostic_context.emitToken(path, decl.type_name.token, "impl target `{s}` must be a struct or type union", .{decl.type_name.name});
            return Error.SemanticFailed;
        }
        return .{ .type_union = .{
            .id = try declarations.registration.find(context.identity_registry, target.module_name, null, target.name, .@"union"),
            .decl = target,
        } };
    }
    try context.diagnostic_context.emitToken(path, decl.type_name.token, "impl target must name a struct or type union owned by this package", .{});
    return Error.SemanticFailed;
}

pub fn resolveImplProtocol(context: Context, path: []const u8, program: ast.Program, decl: ast.ImplDecl) Error!ResolvedProtocolDecl {
    if (decl.protocol_name.is_ref or decl.protocol_name.is_owned or decl.protocol_name.is_raw or decl.protocol_name.is_volatile_raw or decl.protocol_name.is_optional or decl.protocol_name.is_slice or decl.protocol_name.array_len != null or decl.protocol_name.args.len != 0) {
        try context.diagnostic_context.emitToken(path, decl.protocol_name.token, "impl protocol must be a plain protocol name", .{});
        return Error.SemanticFailed;
    }
    if (decl.protocol_name.module_name) |module_alias| {
        const module_name = declarations.resolution.importedModulePath(program, decl.module_name, module_alias) orelse {
            try context.diagnostic_context.emitToken(path, decl.protocol_name.token, "unknown imported module `{s}` in impl protocol", .{module_alias});
            return Error.SemanticFailed;
        };
        const protocol_decl = declarations.resolution.protocolInModule(program, module_name, decl.protocol_name.name) orelse {
            try context.diagnostic_context.emitToken(path, decl.protocol_name.token, "unknown protocol `{s}` in imported module", .{decl.protocol_name.name});
            return Error.SemanticFailed;
        };
        if (!protocol_decl.is_pub) {
            try context.diagnostic_context.emitToken(path, decl.protocol_name.token, "protocol `{s}` is not public in imported module", .{decl.protocol_name.name});
            return Error.SemanticFailed;
        }
        return .{
            .id = try declarations.registration.find(context.identity_registry, protocol_decl.module_name, null, protocol_decl.name, .protocol),
            .decl = protocol_decl,
        };
    }
    const protocol_decl = declarations.resolution.accessibleProtocol(context.policy, program, decl.module_name, decl.protocol_name.name) orelse {
        try context.diagnostic_context.emitToken(path, decl.protocol_name.token, "unknown protocol `{s}`", .{decl.protocol_name.name});
        return Error.SemanticFailed;
    };
    return .{
        .id = try declarations.registration.find(context.identity_registry, protocol_decl.module_name, null, protocol_decl.name, .protocol),
        .decl = protocol_decl,
    };
}

pub fn materializeGenericImplConformances(
    comptime SemaContext: type,
    comptime parseTypeDepth: anytype,
    comptime typeIsOwned: anytype,
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    instantiated: session.InstantiatedStructDecl,
) Error!void {
    const protocol_context = contextFromSession(SemaContext, context);
    const conformances = protocol_context.conformances orelse return Error.SemanticFailed;
    for (program.impls) |decl| {
        if (decl.type_params.len == 0) continue;
        const target = try resolveGenericImplTarget(protocol_context, path, program, decl);
        if (instantiated.base_decl_id == null or target.id != instantiated.base_decl_id.?) continue;
        if (!try genericConditionsSatisfied(SemaContext, typeIsOwned, context, path, program, decl.module_name, decl.type_params, instantiated.type_args)) continue;

        const resolved_protocol = try resolveImplProtocol(protocol_context, path, program, decl);
        const self_type = try type_resolution.genericStructInstance(protocol_context.display_context.types, instantiated.base_decl_id orelse return Error.SemanticFailed, instantiated.id orelse return Error.SemanticFailed, instantiated.type_args);
        const key: Key = .{
            .subject = self_type,
            .protocol = resolved_protocol.id,
        };
        if (conformances.find(key) != null) continue;
        _ = try conformances.register(key);
        try conformances.setGenericArgs(key, instantiated.type_args);
        try materializeAssociatedTypeBindings(SemaContext, parseTypeDepth, context, path, program, resolved_protocol, decl, key, decl.type_params, instantiated.type_args);

        var witnesses: std.ArrayListUnmanaged(MethodWitness) = .empty;
        defer witnesses.deinit(context.allocator);
        for (resolved_protocol.decl.methods, 0..) |required, requirement_index| {
            const method = findMethodInImpl(decl, required.name) orelse {
                try context.diagnostic_context.emitToken(path, decl.token, "type family `{s}` is missing required protocol method `{s}`", .{ target.decl.name, required.name });
                return Error.SemanticFailed;
            };
            try checkProtocolMethodSignature(
                SemaContext,
                parseTypeDepth,
                context,
                path,
                program,
                resolved_protocol.decl,
                required,
                method,
                self_type,
                decl.type_params,
                instantiated.type_args,
            );
            try witnesses.append(context.allocator, .{
                .requirement_index = @intCast(requirement_index),
                .implementation = .{ .source_function = try declarations.registration.find(protocol_context.identity_registry, method.module_name, decl.method_owner, method.name, .function) },
            });
        }
        try conformances.setWitnesses(key, witnesses.items);
    }
}

pub fn resolveConcreteImplTarget(
    comptime SemaContext: type,
    comptime parseTypeDepth: anytype,
    session_context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    decl: ast.ImplDecl,
) Error!ImplTarget {
    const context = contextFromSession(SemaContext, session_context);
    const module_info = declarations.resolution.moduleInfo(program, decl.module_name);
    if (module_info != null and module_info.?.compiler_owned) {
        const candidate = try parseTypeDepth(session_context, path, program, decl.module_name, decl.type_name, null, session_context.function_state.current_generic_params, session_context.function_state.current_generic_args, 0);
        switch (type_resolution.typeKind(context.display_context.types, candidate)) {
            .int, .float, .rune, .bool, .string => return .{ .builtin = candidate },
            else => {},
        }
    }
    return resolveImplTarget(context, path, program, decl);
}

pub fn implSelfType(comptime SemaContext: type, session_context: *SemaContext, target: ImplTarget) Error!semantic_types.TypeId {
    return switch (target) {
        .@"struct" => |resolved| try type_resolution.nominalForSession(SemaContext, session_context, .@"struct", resolved.id, null),
        .type_union => |resolved| try type_resolution.nominalForSession(SemaContext, session_context, .@"union", resolved.id, null),
        .builtin => |builtin| builtin,
    };
}

pub fn registerImplConformances(
    comptime SemaContext: type,
    comptime parseTypeDepth: anytype,
    comptime typeIsOwned: anytype,
    session_context: *SemaContext,
    path: []const u8,
    program: ast.Program,
) Error!void {
    const context = contextFromSession(SemaContext, session_context);
    const conformances = context.conformances orelse return Error.SemanticFailed;
    for (program.impls, 0..) |decl, decl_index| {
        const resolved_protocol = try resolveImplProtocol(context, path, program, decl);
        if (decl.type_params.len != 0) {
            try generics.validateGenericParams(SemaContext, session_context, path, program, decl.module_name, decl.type_params);
            const generic_target = try resolveGenericImplTarget(context, path, program, decl);
            for (program.impls[0..decl_index]) |other| {
                if (other.type_params.len == 0) continue;
                const other_protocol = try resolveImplProtocol(context, path, program, other);
                if (other_protocol.id != resolved_protocol.id) continue;
                const other_target = try resolveGenericImplTarget(context, path, program, other);
                if (other_target.id != generic_target.id) continue;
                try context.diagnostic_context.emitToken(path, decl.token, "duplicate generic impl declaration for the same type family and protocol", .{});
                return Error.SemanticFailed;
            }
            continue;
        }
        const target = try resolveConcreteImplTarget(SemaContext, parseTypeDepth, session_context, path, program, decl);
        const self_type = try implSelfType(SemaContext, session_context, target);
        if (!try conformances.register(.{ .subject = self_type, .protocol = resolved_protocol.id })) {
            try context.diagnostic_context.emitToken(path, decl.token, "duplicate impl declaration for the same type and protocol", .{});
            return Error.SemanticFailed;
        }
    }

    // Alias validation may already have instantiated generic structs. Finish
    // ordinary keys before checking conditional family bounds, independent of
    // source order.
    while (true) {
        const before = conformances.records.items.len;
        var instantiated_index: usize = 0;
        while (instantiated_index < session_context.generic.instantiated_structs.items.len) : (instantiated_index += 1) {
            const instantiated = session_context.generic.instantiated_structs.items[instantiated_index];
            try materializeGenericImplConformances(SemaContext, parseTypeDepth, typeIsOwned, session_context, path, program, instantiated);
        }
        if (conformances.records.items.len == before) break;
    }
}

pub fn checkImpls(
    comptime SemaContext: type,
    comptime parseTypeDepth: anytype,
    comptime typeIsOwned: anytype,
    session_context: *SemaContext,
    path: []const u8,
    program: ast.Program,
) Error!void {
    const context = contextFromSession(SemaContext, session_context);
    const PendingImpl = struct {
        decl: ast.ImplDecl,
        protocol: ResolvedProtocolDecl,
        target: ImplTarget,
        self_type: semantic_types.TypeId,
    };
    var pending_impls: std.ArrayListUnmanaged(PendingImpl) = .empty;
    defer pending_impls.deinit(session_context.allocator);
    const conformances = context.conformances orelse return Error.SemanticFailed;

    for (program.impls) |decl| {
        const resolved_protocol = try resolveImplProtocol(context, path, program, decl);
        if (decl.type_params.len != 0) {
            const generic_target = try resolveGenericImplTarget(context, path, program, decl);
            try checkGenericImplDeclaration(context, path, decl, resolved_protocol.decl, generic_target.decl);
            continue;
        }
        const target = try resolveConcreteImplTarget(SemaContext, parseTypeDepth, session_context, path, program, decl);
        const self_type = try implSelfType(SemaContext, session_context, target);
        try pending_impls.append(session_context.allocator, .{
            .decl = decl,
            .protocol = resolved_protocol,
            .target = target,
            .self_type = self_type,
        });
    }

    for (pending_impls.items) |pending| {
        const decl = pending.decl;
        const resolved_protocol = pending.protocol;
        const protocol_decl = resolved_protocol.decl;
        const target = pending.target;
        const self_type = pending.self_type;
        const key: Key = .{
            .subject = self_type,
            .protocol = resolved_protocol.id,
        };
        try validateAssociatedTypeBindings(context, path, protocol_decl, decl);
        try materializeAssociatedTypeBindings(SemaContext, parseTypeDepth, session_context, path, program, resolved_protocol, decl, key, &.{}, &.{});
        var witnesses: std.ArrayListUnmanaged(MethodWitness) = .empty;
        defer witnesses.deinit(session_context.allocator);

        switch (target) {
            .@"struct" => if (decl.methods.len == 0) {
                try context.diagnostic_context.emitToken(path, decl.token, "struct protocol impl must declare its method bodies", .{});
                return Error.SemanticFailed;
            },
            .builtin => if (decl.methods.len == 0) {
                try context.diagnostic_context.emitToken(path, decl.token, "primitive protocol impl must declare its method bodies", .{});
                return Error.SemanticFailed;
            },
            .type_union => if (decl.methods.len != 0) {
                try context.diagnostic_context.emitToken(path, decl.token, "derived type-union impl cannot declare method bodies", .{});
                return Error.SemanticFailed;
            },
        }

        for (decl.methods, 0..) |method, method_index| {
            if (method.type_params.len != 0) {
                try context.diagnostic_context.emitToken(path, method.name_token, "protocol implementation methods cannot be generic", .{});
                return Error.SemanticFailed;
            }
            for (decl.methods[0..method_index]) |existing| {
                if (!std.mem.eql(u8, method.name, existing.name)) continue;
                try context.diagnostic_context.emitToken(path, method.name_token, "duplicate protocol implementation method `{s}`", .{method.name});
                return Error.SemanticFailed;
            }
            var declared = false;
            for (protocol_decl.methods) |required| {
                if (std.mem.eql(u8, method.name, required.name)) {
                    declared = true;
                    break;
                }
            }
            if (!declared) {
                try context.diagnostic_context.emitToken(path, method.name_token, "method `{s}` is not declared by protocol `{s}`", .{ method.name, protocol_decl.name });
                return Error.SemanticFailed;
            }
        }

        for (protocol_decl.methods, 0..) |required, requirement_index| {
            switch (target) {
                .@"struct" => |target_struct| {
                    const method = findMethodInImpl(decl, required.name) orelse {
                        try context.diagnostic_context.emitToken(path, decl.token, "type `{s}` is missing required protocol method `{s}`", .{ target_struct.decl.name, required.name });
                        return Error.SemanticFailed;
                    };
                    if (findMethodInStruct(target_struct.decl, required.name) != null) {
                        try context.diagnostic_context.emitToken(path, method.name_token, "protocol method `{s}` conflicts with an inherent method of `{s}`", .{ required.name, target_struct.decl.name });
                        return Error.SemanticFailed;
                    }
                    try checkProtocolMethodSignature(SemaContext, parseTypeDepth, session_context, path, program, protocol_decl, required, method, self_type, &.{}, &.{});
                    try witnesses.append(session_context.allocator, .{
                        .requirement_index = @intCast(requirement_index),
                        .implementation = .{ .source_function = try declarations.registration.find(context.identity_registry, method.module_name, decl.method_owner, method.name, .function) },
                    });
                },
                .builtin => {
                    const method = findMethodInImpl(decl, required.name) orelse {
                        const display = try type_resolution.formatDisplay(context.display_context, self_type, .display);
                        defer session_context.allocator.free(display);
                        try context.diagnostic_context.emitToken(path, decl.token, "type `{s}` is missing required protocol method `{s}`", .{ display, required.name });
                        return Error.SemanticFailed;
                    };
                    try checkProtocolMethodSignature(SemaContext, parseTypeDepth, session_context, path, program, protocol_decl, required, method, self_type, &.{}, &.{});
                    try witnesses.append(session_context.allocator, .{
                        .requirement_index = @intCast(requirement_index),
                        .implementation = .{ .source_function = try declarations.registration.find(context.identity_registry, method.module_name, decl.method_owner, method.name, .function) },
                    });
                },
                .type_union => |target_union| {
                    const target_union_decl = target_union.decl;
                    if (required.params.len == 0) {
                        try context.diagnostic_context.emitToken(path, required.name_token, "protocol methods must declare a `self` parameter", .{});
                        return Error.SemanticFailed;
                    }
                    const union_self = try parseTypeDepth(session_context, path, program, protocol_decl.module_name, required.params[0].type_name, self_type, session_context.function_state.current_generic_params, session_context.function_state.current_generic_args, 0);
                    if (type_resolution.typeKind(context.display_context.types, union_self) == .ref) {
                        try context.diagnostic_context.emitToken(path, required.params[0].name_token, "derived type-union impls require value `Self` receivers", .{});
                        return Error.SemanticFailed;
                    }
                    if (union_self != self_type) {
                        try context.diagnostic_context.emitToken(path, required.params[0].name_token, "protocol method receiver must be `Self` for derived type-union impls", .{});
                        return Error.SemanticFailed;
                    }
                    for (target_union_decl.variants) |variant| {
                        const variant_type = try parseTypeDepth(session_context, path, program, target_union_decl.module_name, variant, null, session_context.function_state.current_generic_params, session_context.function_state.current_generic_args, 0);
                        if (type_resolution.typeKind(context.display_context.types, variant_type) != .@"struct") {
                            const display = try type_resolution.formatDisplay(context.display_context, variant_type, .display);
                            defer session_context.allocator.free(display);
                            try context.diagnostic_context.emitToken(path, variant.token, "type-union protocol forwarding requires struct variants; `{s}` is not supported", .{display});
                            return Error.SemanticFailed;
                        }
                        try expectProtocolConformance(SemaContext, typeIsOwned, session_context, path, program, resolved_protocol.decl.module_name, variant.token, variant_type, resolved_protocol, null);
                    }
                    try witnesses.append(session_context.allocator, .{
                        .requirement_index = @intCast(requirement_index),
                        .implementation = .derived_type_union,
                    });
                },
            }
        }
        try conformances.setWitnesses(key, witnesses.items);
    }
}

pub const TypeUnionProtocolMethod = struct {
    union_decl: ast.UnionDecl,
    protocol_decl: ast.ProtocolDecl,
    method: ast.ProtocolMethod,
};

pub fn declarationForId(context: Context, program: ast.Program, protocol_id: identity.DeclId) Error!ast.ProtocolDecl {
    for (program.protocols) |candidate| {
        if (try declarations.registration.find(context.identity_registry, candidate.module_name, null, candidate.name, .protocol) == protocol_id) return candidate;
    }
    return Error.SemanticFailed;
}

pub fn methodOf(decl: ast.ProtocolDecl, name: []const u8) Error!ast.ProtocolMethod {
    for (decl.methods) |candidate| if (std.mem.eql(u8, candidate.name, name)) return candidate;
    return Error.SemanticFailed;
}

pub fn resolveProtocolMethodForType(
    comptime SemaContext: type,
    session_context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    subject: semantic_types.TypeId,
    method_name: []const u8,
    token: lexer.Token,
    forced_protocol: ?identity.DeclId,
    forced_method: ?identity.DeclId,
) Error!?declarations.ResolvedFunction {
    const context = contextFromSession(SemaContext, session_context);
    const conformances = context.conformances orelse return Error.SemanticFailed;
    var resolved: ?declarations.ResolvedFunction = null;
    for (conformances.records.items) |record| {
        if (record.key.subject != subject) continue;
        if (forced_protocol) |required_protocol| {
            if (record.key.protocol != required_protocol) continue;
        }
        const protocol_decl = for (program.protocols) |candidate| {
            const candidate_id = try declarations.registration.find(context.identity_registry, candidate.module_name, null, candidate.name, .protocol);
            if (candidate_id == record.key.protocol) break candidate;
        } else continue;
        for (protocol_decl.methods, 0..) |required, requirement_index| {
            if (!std.mem.eql(u8, required.name, method_name)) continue;
            if (forced_method) |expected| {
                const actual = try declarations.registration.find(context.identity_registry, protocol_decl.module_name, protocol_decl.name, required.name, .protocol_method);
                if (actual != expected) return error.SemanticFailed;
            }
            const function_id = for (record.witnesses) |witness| {
                if (witness.requirement_index != requirement_index) continue;
                break switch (witness.implementation) {
                    .source_function => |id| id,
                    else => continue,
                };
            } else continue;
            var candidate = findImplMethodById(context, program, function_id) orelse return Error.SemanticFailed;
            try bindGenericImplMethod(&candidate, record.generic_args);
            if (resolved != null) {
                try generics.recordAdmission(SemaContext, session_context, path, token, .{
                    .code = .generic_constraint,
                    .help = "qualify the call with the protocol whose method is intended",
                }, "protocol method call `{s}` is ambiguous for this type", .{method_name});
                return Error.SemanticFailed;
            }
            resolved = candidate;
        }
    }
    return resolved;
}

fn findImplMethodById(context: Context, program: ast.Program, function_id: identity.DeclId) ?declarations.ResolvedFunction {
    for (program.impls) |decl| {
        for (decl.methods) |method| {
            const candidate_id = declarations.registration.findOptional(context.identity_registry, method.module_name, decl.method_owner, method.name, .function) orelse continue;
            if (candidate_id == function_id) return .{ .id = candidate_id, .decl = method, .impl_decl = decl };
        }
    }
    return null;
}

fn bindGenericImplMethod(resolved: *declarations.ResolvedFunction, generic_args: []const semantic_types.GenericArgument) Error!void {
    const impl_decl = resolved.impl_decl orelse return;
    if (impl_decl.type_params.len == 0) return;
    if (generic_args.len != impl_decl.type_params.len) return error.SemanticFailed;
    resolved.generic_params = impl_decl.type_params;
    resolved.generic_args = generic_args;
}

pub fn resolveSourceProtocolWitness(
    context: Context,
    program: ast.Program,
    subject: semantic_types.TypeId,
    protocol: identity.DeclId,
    requirement_index: u32,
) ?declarations.ResolvedFunction {
    const conformances = context.conformances orelse return null;
    const record = conformances.find(.{ .subject = subject, .protocol = protocol }) orelse return null;
    for (record.witnesses) |witness| {
        if (witness.requirement_index != requirement_index) continue;
        return switch (witness.implementation) {
            .source_function => |function_id| blk: {
                var resolved = findImplMethodById(context, program, function_id) orelse break :blk null;
                bindGenericImplMethod(&resolved, record.generic_args) catch break :blk null;
                break :blk resolved;
            },
            else => null,
        };
    }
    return null;
}

pub fn resolveTypeUnionProtocolMethod(
    comptime SemaContext: type,
    session_context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    requester_module: []const u8,
    union_type: semantic_types.TypeId,
    method_name: []const u8,
    token: lexer.Token,
) Error!?TypeUnionProtocolMethod {
    _ = requester_module;
    const context = contextFromSession(SemaContext, session_context);
    const union_decl = declarations.Lookup(SemaContext).canonicalUnionLookup(session_context, program, union_type) orelse return null;
    if (union_decl.kind != .type_union) return null;
    const union_id = type_resolution.Canonical(SemaContext).nominalDecl(session_context, union_type) orelse return null;
    const self_type = try type_resolution.nominalForSession(SemaContext, session_context, .@"union", union_id, null);
    const conformances = context.conformances orelse return Error.SemanticFailed;
    for (conformances.records.items) |record| {
        if (record.key.subject != self_type) continue;
        const protocol_decl = for (program.protocols) |candidate| {
            const candidate_id = try declarations.registration.find(context.identity_registry, candidate.module_name, null, candidate.name, .protocol);
            if (candidate_id == record.key.protocol) break candidate;
        } else continue;
        for (protocol_decl.methods, 0..) |method, requirement_index| {
            if (std.mem.eql(u8, method.name, method_name)) {
                const has_derived_witness = for (record.witnesses) |witness| {
                    if (witness.requirement_index != requirement_index) continue;
                    break witness.implementation == .derived_type_union;
                } else false;
                if (!has_derived_witness) continue;
                return .{
                    .union_decl = union_decl,
                    .protocol_decl = protocol_decl,
                    .method = method,
                };
            }
        }
    }
    _ = path;
    _ = token;
    return null;
}

/// A type union that conforms to a protocol through a derived witness gets its
/// method body materialised here: the generated method switches on the union
/// variant and calls that variant's own impl for the requirement. This is the
/// construction half of the witness workflow; `resolveTypeUnionProtocolMethod`
/// above is the lookup half.
pub const witness_synthesis = struct {
    pub fn Owner(comptime host: anytype) type {
        return struct {
            const SemaContext = host.SemaContext;
            const SemaError = host.SemaError;
            const canonical = type_resolution.Canonical(SemaContext);
            const canonicalTypeKind = canonical.sirType;
            const canonicalNominalTypeId = canonical.nominalType;
            const canonicalNominalDeclId = canonical.nominalDecl;
            const canonicalPrimitiveTypeId = canonical.primitiveType;
            const formatType = canonical.formatType;
            const lookup = declarations.Lookup(SemaContext);
            const registeredDeclId = lookup.registeredDeclId;
            const parseType = host.parseType;
            const parseTypeWithSelf = host.parseTypeWithSelf;
            const makeTypedExprFromId = host.makeTypedExprFromId;
            const nextBindingId = lookup.nextBindingId;
            const finalizeAndRecordExprSemantics = host.finalizeAndRecordExprSemantics;
            const recordGeneratedBindingRoot = host.recordGeneratedBindingRoot;
            const attachCheckedCallUse = host.attachCheckedCallUse;
            const recordExprSink = host.recordExprSink;
            const checkedCapturePath = host.checkedCapturePath;
            const checkedCaptureOrigin = host.checkedCaptureOrigin;
            const canonicalNominalDeclName = lookup.canonicalNominalDeclName;
            const registeredOrGeneratedDeclId = host.registeredOrGeneratedDeclId;

            pub fn synthesizeTypeUnionProtocolMethod(
                context: *SemaContext,
                path: []const u8,
                program: ast.Program,
                union_decl: ast.UnionDecl,
                protocol_decl: ast.ProtocolDecl,
                protocol_id: identity.DeclId,
                requirement_index: u32,
                method: ast.ProtocolMethod,
            ) SemaError!sir.Function {
                const protocol_context = contextFromSession(SemaContext, context);
                const allocator = context.allocator;
                const self_type = try canonicalNominalTypeId(context, .@"union", try registeredDeclId(context, union_decl.module_name, null, union_decl.name, .@"union"), null);
                const return_type = if (method.return_type) |type_name|
                    try parseTypeWithSelf(context, path, program, protocol_decl.module_name, type_name, self_type)
                else
                    try canonicalPrimitiveTypeId(context, .void);

                var params = try allocator.alloc(sir.Param, method.params.len);
                errdefer allocator.free(params);
                for (method.params, 0..) |param, i| {
                    const ty = try parseTypeWithSelf(context, path, program, protocol_decl.module_name, param.type_name, self_type);
                    params[i] = .{
                        .name = param.name,
                        .binding_id = try nextBindingId(context),
                        .type_id = ty,
                    };
                }

                const switch_value = try allocator.create(sir.Expr);
                errdefer switch_value.destroy(allocator);
                switch_value.* = .{ .local = method.params[0].name };
                var switch_typed = makeTypedExprFromId(switch_value, self_type);
                try finalizeAndRecordExprSemantics(context, path, program, union_decl.module_name, &switch_typed);
                try recordGeneratedBindingRoot(context, switch_value, params[0].binding_id.?, false);

                var cases = try allocator.alloc(sir.SwitchCase, union_decl.variants.len);
                errdefer allocator.free(cases);
                for (union_decl.variants, 0..) |variant, i| {
                    const variant_type = try parseType(context, path, program, union_decl.module_name, variant);
                    const case_name = try formatType(context, variant_type);
                    errdefer allocator.free(case_name);
                    try context.output.generated_strings.append(allocator, case_name);

                    const payload_name = try std.fmt.allocPrint(allocator, "__{s}_{d}", .{ method.name, i });
                    errdefer allocator.free(payload_name);
                    try context.output.generated_strings.append(allocator, payload_name);
                    const payload_binding_id = try nextBindingId(context);

                    const variant_name = canonicalNominalDeclName(context, program, variant_type) orelse return error.SemanticFailed;
                    const resolved_target_method = resolveSourceProtocolWitness(protocol_context, program, variant_type, protocol_id, requirement_index) orelse {
                        try context.diagnostic_context.emitToken(path, method.name_token, "type `{s}` is missing required protocol method `{s}`", .{ variant_name, method.name });
                        return SemaError.SemanticFailed;
                    };
                    const target_method = resolved_target_method.decl;

                    var call_args = try allocator.alloc(sir.CallArg, method.params.len);
                    errdefer allocator.free(call_args);
                    const payload_expr = try allocator.create(sir.Expr);
                    errdefer payload_expr.destroy(allocator);
                    payload_expr.* = .{ .local = payload_name };
                    var payload_typed = makeTypedExprFromId(payload_expr, variant_type);
                    try finalizeAndRecordExprSemantics(context, path, program, union_decl.module_name, &payload_typed);
                    try recordGeneratedBindingRoot(context, payload_expr, payload_binding_id, false);
                    call_args[0] = .{ .value = payload_expr };
                    for (method.params[1..], 1..) |param, arg_i| {
                        const arg_expr = try allocator.create(sir.Expr);
                        errdefer arg_expr.destroy(allocator);
                        arg_expr.* = .{ .local = param.name };
                        var arg_typed = makeTypedExprFromId(arg_expr, params[arg_i].type_id orelse return error.SemanticFailed);
                        try finalizeAndRecordExprSemantics(context, path, program, union_decl.module_name, &arg_typed);
                        try recordGeneratedBindingRoot(context, arg_expr, params[arg_i].binding_id.?, false);
                        call_args[arg_i] = .{ .value = arg_expr };
                    }

                    const call_expr = try allocator.create(sir.Expr);
                    errdefer call_expr.destroy(allocator);
                    call_expr.* = .{ .call = .{
                        .intrinsic_id = intrinsics.resolveDeclaration(target_method.module_name, target_method.owner, method.name),
                        .decl_id = resolved_target_method.id,
                        .module_name = target_method.module_name,
                        .owner = target_method.owner,
                        .callee = method.name,
                        .args = call_args,
                    } };
                    try attachCheckedCallUse(context, call_expr, return_type, context.function_state.active_source_decl_id, method.name_token.offset);
                    var call_typed = makeTypedExprFromId(call_expr, return_type);
                    try finalizeAndRecordExprSemantics(context, path, program, union_decl.module_name, &call_typed);
                    if (canonicalTypeKind(context, return_type) != .void) try recordExprSink(context, call_expr, .@"return");

                    const body = try allocator.alloc(sir.Stmt, 1);
                    errdefer allocator.free(body);
                    body[0] = if (canonicalTypeKind(context, return_type) == .void)
                        .{ .expr = call_expr }
                    else
                        .{ .@"return" = call_expr };

                    cases[i] = .{
                        .case_name = case_name,
                        .payload_name = payload_name,
                        .payload_binding_id = payload_binding_id,
                        .payload_type_id = variant_type,
                        .payload_path = checkedCapturePath(checkedCaptureOrigin(context, switch_value), .{ .union_field = .{ .owner_decl_id = canonicalNominalDeclId(context, self_type) orelse return error.SemanticFailed, .ordinal = @intCast(i) } }),
                        .body = body,
                    };
                }

                const switch_stmt = sir.Stmt{ .@"switch" = .{
                    .value = switch_value,
                    .subject_type_id = self_type,
                    .subject_decl_id = canonicalNominalDeclId(context, self_type),
                    .subject_type_name = union_decl.name,
                    .cases = cases,
                    .has_else = false,
                    .else_body = try allocator.alloc(sir.Stmt, 0),
                } };
                const body = try allocator.alloc(sir.Stmt, 1);
                errdefer allocator.free(body);
                body[0] = switch_stmt;

                return .{
                    .module_name = union_decl.module_name,
                    .owner = union_decl.name,
                    .name = method.name,
                    .params = params,
                    .return_type_id = return_type,
                    .debug_token = method.name_token,
                    .body = body,
                };
            }
            /// Materialise every derived witness a type union owes a protocol at
            /// module completion: each requirement answered by the union itself
            /// becomes a dispatchable SIR function.
            pub fn materializeDerivedWitnesses(
                context: *SemaContext,
                path: []const u8,
                program: ast.Program,
                functions: *std.ArrayListUnmanaged(sir.Function),
            ) SemaError!void {
                const allocator = context.allocator;
                const conformances = contextFromSession(SemaContext, context).conformances orelse return SemaError.SemanticFailed;
                for (conformances.records.items) |record| {
                    if (canonicalTypeKind(context, record.key.subject) != .@"union") continue;
                    const target_decl_id = canonicalNominalDeclId(context, record.key.subject) orelse continue;
                    const target_union = for (program.unions) |candidate| {
                        if (candidate.kind != .type_union) continue;
                        const candidate_id = try registeredDeclId(context, candidate.module_name, null, candidate.name, .@"union");
                        if (candidate_id == target_decl_id) break candidate;
                    } else continue;
                    const protocol_decl = for (program.protocols) |candidate| {
                        const candidate_id = try registeredDeclId(context, candidate.module_name, null, candidate.name, .protocol);
                        if (candidate_id == record.key.protocol) break candidate;
                    } else continue;
                    for (record.witnesses) |witness| {
                        if (witness.implementation != .derived_type_union) continue;
                        const method = protocol_decl.methods[witness.requirement_index];
                        var synthesized = try synthesizeTypeUnionProtocolMethod(context, path, program, target_union, protocol_decl, record.key.protocol, witness.requirement_index, method);
                        synthesized.decl_id = try registeredOrGeneratedDeclId(context, synthesized.module_name, synthesized.owner, synthesized.name, .function);
                        try functions.append(allocator, synthesized);
                    }
                }
            }
        };
    }
};

pub const syntax_roles = struct {
    pub fn Owner(comptime host: anytype) type {
        return struct {
            const SemaContext = host.SemaContext;
            const SemaError = host.SemaError;
            const GlobalBinding = host.GlobalBinding;
            const canonicalBaseStructDecl = host.canonicalBaseStructDecl;
            const lookup = declarations.Lookup(SemaContext);
            const canAccessDecl = lookup.canAccessDecl;
            const canonical = type_resolution.Canonical(SemaContext);
            const canonicalTypeNode = canonical.typeNode;
            const canonicalTypeKind = canonical.sirType;
            const canonicalRefTarget = canonical.refTargetType;
            const canonicalNominalDeclName = lookup.canonicalNominalDeclName;
            const findInstantiatedStructForCanonicalType = lookup.findInstantiatedStructForCanonicalType;
            const instantiateMethodCall = host.instantiateMethodCall;
            const parseTypeWithBindings = host.parseTypeWithBindings;

            pub fn validateSliceViewMethods(context: *SemaContext, path: []const u8, decl: ast.StructDecl) SemaError!void {
                var const_method: ?ast.Function = null;
                var mutable_method: ?ast.Function = null;
                for (decl.methods) |method| {
                    if (!method.is_slice_view) continue;
                    const valid = method.params.len == 1 and method.type_params.len == 0 and
                        method.return_type != null and !method.is_extern and !method.is_isolated and
                        std.mem.eql(u8, method.params[0].name, "self") and
                        method.params[0].type_name.is_ref and
                        !method.params[0].type_name.is_owned and !method.params[0].type_name.is_optional and
                        !method.params[0].type_name.is_raw and !method.params[0].type_name.is_slice and
                        method.params[0].type_name.array_len == null and method.params[0].type_name.array_len_name == null and
                        std.mem.eql(u8, method.params[0].type_name.name, decl.name) and
                        method.params[0].type_name.args.len == decl.type_params.len and
                        method.return_type.?.is_slice and !method.return_type.?.is_optional and
                        !method.return_type.?.is_ref and !method.return_type.?.is_raw and !method.return_type.?.is_owned and
                        method.return_type.?.slice_flags.is_const == method.params[0].type_name.ref_is_const;
                    if (!valid) {
                        try context.diagnostic_context.emitToken(path, method.name_token, "attribute `syntax.slice_view` requires an instance method with only `self: &Owner` returning `[]Item`, or `self: &const Owner` returning `[]const Item`, without method generic parameters", .{});
                        return SemaError.SemanticFailed;
                    }
                    for (method.params[0].type_name.args, decl.type_params) |arg, param| {
                        const expected = ast.TypeName{ .name = param.name, .args = &.{}, .token = param.name_token };
                        if (!declarations.sameTypeName(arg, expected)) {
                            try context.diagnostic_context.emitToken(path, method.name_token, "attribute `syntax.slice_view` receiver must use its enclosing type's generic parameters", .{});
                            return SemaError.SemanticFailed;
                        }
                    }
                    const slot = if (method.params[0].type_name.ref_is_const) &const_method else &mutable_method;
                    if (slot.*) |previous| {
                        try context.diagnostic_context.emitToken(path, method.name_token, "duplicate `syntax.slice_view` methods `{s}` and `{s}` for the same receiver access", .{ previous.name, method.name });
                        return SemaError.SemanticFailed;
                    }
                    slot.* = method;
                }
                if (const_method != null and mutable_method != null) {
                    var const_result = const_method.?.return_type.?;
                    var mutable_result = mutable_method.?.return_type.?;
                    const_result.slice_flags.is_const = false;
                    mutable_result.slice_flags.is_const = false;
                    if (!declarations.sameTypeName(const_result, mutable_result)) {
                        try context.diagnostic_context.emitToken(path, mutable_method.?.name_token, "attribute `syntax.slice_view` methods must expose the same item type for both receiver access modes", .{});
                        return SemaError.SemanticFailed;
                    }
                }
            }

            pub fn validateSyntaxMethods(context: *SemaContext, path: []const u8, decl: ast.StructDecl) SemaError!void {
                var roles: [@typeInfo(ast.SyntaxRole).@"enum".field_names.len]?ast.Function = @splat(null);
                for (decl.methods) |method| {
                    const role = method.syntax_role orelse continue;
                    const slot = &roles[@backingInt(role)];
                    const count: usize = switch (role) {
                        .iter => 1,
                        .index_set => 3,
                        else => 2,
                    };
                    var valid = slot.* == null and method.params.len == count and method.type_params.len == 0 and method.return_type != null;
                    if (valid) {
                        var receiver = method.params[0].type_name;
                        valid = std.mem.eql(u8, method.params[0].name, "self") and receiver.is_ref and receiver.ref_is_const == (role != .index_set);
                        receiver.is_ref = false;
                        receiver.ref_is_const = false;
                        const expected = ast.TypeName{ .name = decl.name, .args = receiver.args, .token = decl.name_token };
                        valid = valid and declarations.sameTypeName(receiver, expected) and receiver.args.len == decl.type_params.len;
                        if (valid) for (receiver.args, decl.type_params) |arg, param| {
                            if (!declarations.sameTypeName(arg, .{ .name = param.name, .args = &.{}, .token = param.name_token })) valid = false;
                        };
                        const result = method.return_type.?;
                        const void_type = ast.TypeName{ .name = "void", .args = &.{}, .token = method.name_token };
                        const bool_type = ast.TypeName{ .name = "bool", .args = &.{}, .token = method.name_token };
                        valid = valid and switch (role) {
                            .index_set => declarations.sameTypeName(result, void_type),
                            .iter_has_next => declarations.sameTypeName(result, bool_type),
                            else => !declarations.sameTypeName(result, void_type),
                        };
                    }
                    if (!valid) {
                        try context.diagnostic_context.emitToken(path, method.name_token, "attribute `syntax.{s}` requires one unique inherent method with the role's receiver, parameters, and return type, without method generic parameters", .{@tagName(role)});
                        return error.SemanticFailed;
                    }
                    slot.* = method;
                }
                var iteration_count: usize = 0;
                for (roles[2..]) |method| if (method != null) {
                    iteration_count += 1;
                };
                if (iteration_count == 0) return;
                if (iteration_count != 4) {
                    try context.diagnostic_context.emitToken(path, decl.name_token, "iteration requires all four attributes: `syntax.iter`, `syntax.iter_has_next`, `syntax.iter_next`, and `syntax.iter_item`", .{});
                    return error.SemanticFailed;
                }
                const init = roles[@backingInt(ast.SyntaxRole.iter)].?;
                const has_next = roles[@backingInt(ast.SyntaxRole.iter_has_next)].?;
                const next = roles[@backingInt(ast.SyntaxRole.iter_next)].?;
                const item = roles[@backingInt(ast.SyntaxRole.iter_item)].?;
                for ([_]ast.Function{ has_next, next }) |method| {
                    var state = method.params[1].type_name;
                    const valid_ref = state.is_ref and state.ref_is_const == (method.syntax_role == .iter_has_next);
                    state.is_ref = false;
                    state.ref_is_const = false;
                    if (!valid_ref or !declarations.sameTypeName(state, init.return_type.?)) {
                        try context.diagnostic_context.emitToken(path, method.name_token, "iteration state must match `syntax.iter`: `&const State` for has-next and `&State` for next", .{});
                        return error.SemanticFailed;
                    }
                }
                if (!declarations.sameTypeName(item.params[1].type_name, next.return_type.?)) {
                    try context.diagnostic_context.emitToken(path, item.name_token, "iteration cursor must match the return type of `syntax.iter_next`", .{});
                    return error.SemanticFailed;
                }
            }

            pub const ResolvedStructHook = struct {
                decl_id: identity.DeclId,
                method: ast.Function,
                owner: ?[]const u8,
                name: []const u8,
                params: ?[]const ast.GenericParam,
                args: ?[]const semantic_types.GenericArgument,
                owns_bindings: bool,
            };

            pub fn selectSyntaxMethod(context: *SemaContext, program: ast.Program, current_module: []const u8, subject_type: semantic_types.TypeId, role: ast.SyntaxRole) ?ast.Function {
                const decl = canonicalBaseStructDecl(context, program, subject_type) orelse return null;
                for (decl.methods) |method| {
                    if (method.syntax_role == role and canAccessDecl(context, current_module, method.module_name, method.is_pub)) return method;
                }
                return null;
            }

            fn syntaxSubjectType(context: *SemaContext, type_id: semantic_types.TypeId) semantic_types.TypeId {
                return switch (canonicalTypeNode(context, type_id).*) {
                    .ref_ => |reference| syntaxSubjectType(context, reference.target),
                    .owned => |target| syntaxSubjectType(context, target),
                    else => type_id,
                };
            }

            fn resolveSyntaxMethodCall(context: *SemaContext, allocator: std.mem.Allocator, path: []const u8, program: ast.Program, current_module: []const u8, globals: []const GlobalBinding, subject_type: semantic_types.TypeId, role: ast.SyntaxRole) SemaError!?ResolvedStructHook {
                const method = selectSyntaxMethod(context, program, current_module, subject_type, role) orelse return null;
                const base_decl = canonicalBaseStructDecl(context, program, subject_type) orelse return null;
                const canonical_subject = syntaxSubjectType(context, subject_type);
                const owner = canonicalNominalDeclName(context, program, canonical_subject) orelse return null;
                const instance = findInstantiatedStructForCanonicalType(context, canonical_subject);
                const params = if (instance != null) base_decl.type_params else &.{};
                const args = if (instance) |value| value.type_args else &.{};
                const concrete = try instantiateMethodCall(context, allocator, path, program, globals, current_module, owner, method.name_token, method, params, args, &.{}, null);
                return .{ .decl_id = concrete.decl_id, .method = method, .owner = concrete.owner, .name = concrete.name, .params = concrete.params, .args = concrete.args, .owns_bindings = concrete.owns_bindings };
            }

            pub fn syntaxMethodReturnType(context: *SemaContext, path: []const u8, program: ast.Program, subject_type: semantic_types.TypeId, method: ast.Function) SemaError!semantic_types.TypeId {
                const base_decl = canonicalBaseStructDecl(context, program, subject_type) orelse return error.SemanticFailed;
                const canonical_subject = syntaxSubjectType(context, subject_type);
                const instance = findInstantiatedStructForCanonicalType(context, canonical_subject);
                return parseTypeWithBindings(context, path, program, method.module_name, method.return_type.?, null, if (instance != null) base_decl.type_params else &.{}, if (instance) |value| value.type_args else &.{});
            }

            pub const TypeIteratorHookRole = struct {
                cursor_type_id: semantic_types.TypeId,
                has_next_decl_id: identity.DeclId,
                next_decl_id: identity.DeclId,
                has_next_args: ?[]const semantic_types.GenericArgument = null,
                next_args: ?[]const semantic_types.GenericArgument = null,
            };

            pub const TypeIteratorInitRole = struct {
                iterator_type_id: semantic_types.TypeId,
                init_decl_id: identity.DeclId,
                args: ?[]const semantic_types.GenericArgument = null,
            };

            pub const TypeIteratorReadRole = struct {
                item_type_id: semantic_types.TypeId,
                /// The type the `syntax.iter_item` hook itself settles, which may be a
                /// borrowed view of the loop's item type.
                result_type_id: semantic_types.TypeId,
                index_decl_id: ?identity.DeclId,
                args: ?[]const semantic_types.GenericArgument = null,
            };

            pub fn typeIteratorHookRole(
                context: *SemaContext,
                allocator: std.mem.Allocator,
                path: []const u8,
                program: ast.Program,
                current_module: []const u8,
                globals: []const GlobalBinding,
                iterable_type_id: semantic_types.TypeId,
                iterator_type_id: semantic_types.TypeId,
            ) SemaError!?TypeIteratorHookRole {
                const protocol_has_next = (try resolveSyntaxMethodCall(context, allocator, path, program, current_module, globals, iterable_type_id, .iter_has_next)) orelse return null;
                const protocol_next = (try resolveSyntaxMethodCall(context, allocator, path, program, current_module, globals, iterable_type_id, .iter_next)) orelse return null;
                _ = iterator_type_id;
                const cursor_type = try syntaxMethodReturnType(context, path, program, iterable_type_id, protocol_next.method);
                return .{
                    .cursor_type_id = cursor_type,
                    .has_next_decl_id = protocol_has_next.decl_id,
                    .next_decl_id = protocol_next.decl_id,
                    .has_next_args = protocol_has_next.args,
                    .next_args = protocol_next.args,
                };
            }

            pub fn typeIteratorInitRole(
                context: *SemaContext,
                allocator: std.mem.Allocator,
                path: []const u8,
                program: ast.Program,
                current_module: []const u8,
                globals: []const GlobalBinding,
                iterable_type_id: semantic_types.TypeId,
            ) SemaError!?TypeIteratorInitRole {
                const protocol_init = (try resolveSyntaxMethodCall(context, allocator, path, program, current_module, globals, iterable_type_id, .iter)) orelse return null;
                const state_type = try syntaxMethodReturnType(context, path, program, iterable_type_id, protocol_init.method);
                return .{
                    .iterator_type_id = state_type,
                    .init_decl_id = protocol_init.decl_id,
                    .args = protocol_init.args,
                };
            }

            pub fn typeIteratorReadRole(
                context: *SemaContext,
                allocator: std.mem.Allocator,
                path: []const u8,
                program: ast.Program,
                current_module: []const u8,
                globals: []const GlobalBinding,
                iterable_type_id: semantic_types.TypeId,
                cursor_type_id: semantic_types.TypeId,
            ) SemaError!?TypeIteratorReadRole {
                const item = (try resolveSyntaxMethodCall(context, allocator, path, program, current_module, globals, iterable_type_id, .iter_item)) orelse return null;
                _ = cursor_type_id;
                const declared_item = try syntaxMethodReturnType(context, path, program, iterable_type_id, item.method);
                return .{
                    .item_type_id = if (canonicalTypeKind(context, declared_item) == .ref) canonicalRefTarget(context, declared_item) else declared_item,
                    .result_type_id = declared_item,
                    .index_decl_id = item.decl_id,
                    .args = item.args,
                };
            }
        };
    }
};

const std = @import("std");
const identity = @import("identity.zig");
const ast = @import("../parser/ast.zig");
const semantic_types = @import("types.zig");
const sir = @import("sir.zig");
const language_contracts = @import("../language_contracts.zig");

/// Generic binders receive compilation-local identities during resolution.
/// Their source spelling is only diagnostic data.
pub const GenericScopeId = identity.GenericScopeId;
pub const ParamId = identity.GenericParamId;

/// Named binders use canonical declaration identity. An impl binder is
/// identified by its module and ordinal among that module's source impls.
pub const ScopeKey = union(enum) {
    declaration: identity.DeclId,
    implementation: struct { module: identity.ModuleId, ordinal: u32 },
};

pub const Scope = struct {
    key: ScopeKey,
    param_count: u32,
};

/// Register scopes in lexical source order before origin transfer. The IDs
/// remain stable across repeated analysis of the same compilation context.
pub const ScopeRegistry = struct {
    allocator: std.mem.Allocator,
    declarations: *const identity.Registry,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    /// Every binder source occurrence carries its declaring parameter list so
    /// a definition-site body can recover the binder's declared constraints
    /// from its canonical identity alone.
    source_params: std.ArrayListUnmanaged(struct {
        module: identity.ModuleId,
        offset: usize,
        id: ParamId,
        ordinal: u32,
        params: []const ast.GenericParam,
    }) = .empty,

    pub fn init(allocator: std.mem.Allocator, declarations: *const identity.Registry) ScopeRegistry {
        return .{ .allocator = allocator, .declarations = declarations };
    }

    pub fn deinit(self: *ScopeRegistry) void {
        self.scopes.deinit(self.allocator);
        self.source_params.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *ScopeRegistry, key: ScopeKey, param_count: u32) error{ OutOfMemory, InvalidBinder, ConflictingArity }!GenericScopeId {
        switch (key) {
            .declaration => |id| {
                const decl = self.declarations.decl(id) orelse return error.InvalidBinder;
                if (decl.kind != .function and decl.kind != .@"struct" and decl.kind != .@"union" and decl.kind != .type_alias) return error.InvalidBinder;
            },
            .implementation => |impl| if (self.declarations.module(impl.module) == null) return error.InvalidBinder,
        }
        for (self.scopes.items, 0..) |scope, index| {
            if (!std.meta.eql(scope.key, key)) continue;
            if (scope.param_count != param_count) return error.ConflictingArity;
            return @fromBackingInt(@intCast(@as(u32, @intCast(index))));
        }
        if (self.scopes.items.len >= std.math.maxInt(u32)) return error.InvalidBinder;
        const id: GenericScopeId = @fromBackingInt(@intCast(@as(u32, @intCast(self.scopes.items.len))));
        try self.scopes.append(self.allocator, .{ .key = key, .param_count = param_count });
        return id;
    }

    /// Populate binder identities from the same resolved declarations used by
    /// sema. Source offsets restore lexical order across the AST's kind arrays.
    pub fn registerProgram(self: *ScopeRegistry, program: ast.Program) error{ OutOfMemory, InvalidBinder, ConflictingArity }!void {
        const Candidate = struct { offset: usize, key: ScopeKey, params: []const ast.GenericParam };
        var candidates: std.ArrayListUnmanaged(Candidate) = .empty;
        defer candidates.deinit(self.allocator);
        for (program.aliases) |decl| {
            if (decl.type_params.len == 0) continue;
            try candidates.append(self.allocator, .{ .offset = decl.name_token.offset, .key = .{ .declaration = try self.findDecl(decl.module_name, null, decl.name, .type_alias) }, .params = decl.type_params });
        }
        for (program.structs) |decl| {
            if (decl.type_params.len != 0) try candidates.append(self.allocator, .{ .offset = decl.name_token.offset, .key = .{ .declaration = try self.findDecl(decl.module_name, null, decl.name, .@"struct") }, .params = decl.type_params });
            for (decl.methods) |method| {
                if (method.type_params.len == 0) continue;
                try candidates.append(self.allocator, .{ .offset = method.name_token.offset, .key = .{ .declaration = try self.findDecl(method.module_name, method.owner orelse decl.name, method.name, .function) }, .params = method.type_params });
            }
        }
        for (program.functions) |decl| {
            if (decl.type_params.len == 0) continue;
            try candidates.append(self.allocator, .{ .offset = decl.name_token.offset, .key = .{ .declaration = try self.findDecl(decl.module_name, decl.owner, decl.name, .function) }, .params = decl.type_params });
        }
        for (program.impls, 0..) |decl, index| {
            const module = self.declarations.findModule(decl.module_name) orelse return error.InvalidBinder;
            var ordinal: u32 = 0;
            for (program.impls[0..index]) |previous| {
                if (std.mem.eql(u8, previous.module_name, decl.module_name)) ordinal = std.math.add(u32, ordinal, 1) catch return error.InvalidBinder;
            }
            if (decl.type_params.len != 0) try candidates.append(self.allocator, .{ .offset = decl.token.offset, .key = .{ .implementation = .{ .module = module, .ordinal = ordinal } }, .params = decl.type_params });
            for (decl.methods) |method| {
                if (method.type_params.len == 0) continue;
                try candidates.append(self.allocator, .{ .offset = method.name_token.offset, .key = .{ .declaration = try self.findDecl(method.module_name, decl.method_owner, method.name, .function) }, .params = method.type_params });
            }
        }
        std.mem.sort(Candidate, candidates.items, {}, struct {
            fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                return a.offset < b.offset;
            }
        }.lessThan);
        for (candidates.items) |candidate| {
            const scope_id = try self.register(candidate.key, try paramCount(candidate.params.len));
            const module = switch (candidate.key) {
                .declaration => |decl_id| (self.declarations.decl(decl_id) orelse return error.InvalidBinder).module,
                .implementation => |impl| impl.module,
            };
            for (candidate.params, 0..) |param_decl, ordinal| {
                const id: ParamId = .{ .scope = scope_id, .ordinal = @intCast(ordinal) };
                try self.source_params.append(self.allocator, .{
                    .module = module,
                    .offset = param_decl.name_token.offset,
                    .id = id,
                    .ordinal = @intCast(ordinal),
                    .params = candidate.params,
                });
            }
        }
    }

    fn findDecl(self: *const ScopeRegistry, module_name: []const u8, owner: ?[]const u8, name: []const u8, kind: identity.DeclKind) error{ OutOfMemory, InvalidBinder }!identity.DeclId {
        const module = self.declarations.findModule(module_name) orelse return error.InvalidBinder;
        return (try self.declarations.findDecl(module, owner, name, kind)) orelse error.InvalidBinder;
    }

    fn paramCount(count: usize) error{InvalidBinder}!u32 {
        return std.math.cast(u32, count) orelse error.InvalidBinder;
    }

    pub fn param(self: *const ScopeRegistry, scope_id: GenericScopeId, ordinal: u32) error{ InvalidBinder, InvalidParameter }!ParamId {
        const index: usize = @backingInt(scope_id);
        if (index >= self.scopes.items.len) return error.InvalidBinder;
        if (ordinal >= self.scopes.items[index].param_count) return error.InvalidParameter;
        return .{ .scope = scope_id, .ordinal = ordinal };
    }

    pub fn verifyParam(self: *const ScopeRegistry, id: ParamId) bool {
        _ = self.param(id.scope, id.ordinal) catch return false;
        return true;
    }

    /// The declared binder a canonical placeholder names.
    pub fn paramDecl(self: *const ScopeRegistry, id: ParamId) ?ast.GenericParam {
        for (self.source_params.items) |source| {
            if (source.id.scope != id.scope or source.id.ordinal != id.ordinal) continue;
            if (source.ordinal >= source.params.len) return null;
            return source.params[source.ordinal];
        }
        return null;
    }

    pub fn sourceParam(self: *const ScopeRegistry, module_name: []const u8, offset: usize) ?ParamId {
        const module = self.declarations.findModule(module_name) orelse return null;
        for (self.source_params.items) |source| {
            if (source.module == module and source.offset == offset) return source.id;
        }
        return null;
    }

    /// The module a binder's declaration lives in, needed to resolve the
    /// protocols that binder declares as constraints.
    pub fn paramModule(self: *const ScopeRegistry, id: ParamId) ?[]const u8 {
        for (self.source_params.items) |source| {
            if (source.id.scope != id.scope or source.id.ordinal != id.ordinal) continue;
            const module = self.declarations.module(source.module) orelse return null;
            return module.name;
        }
        return null;
    }

    pub fn verifySourceParam(self: *const ScopeRegistry, module_name: []const u8, offset: usize, id: ParamId) bool {
        return if (self.sourceParam(module_name, offset)) |expected| std.meta.eql(expected, id) else false;
    }
};

/// Assigned by the checked symbolic type adapter. Equal IDs mean that the
/// corresponding receiver and child slots have compatible type structure.
pub const TypeTermId = enum(u32) { _ };

pub const Atom = union(enum) {
    concrete,
    parameter: ParamId,
    projection: ParamId,
};

/// An empty set means no reachable value. An unresolved receiver is top, not
/// an empty set and not a generic inference slot waiting for its first actual.
pub const Origin = union(enum) {
    unresolved,
    set: []const Atom,

    pub fn leq(a: *const Origin, b: *const Origin) bool {
        if (b.* == .unresolved) return true;
        if (a.* == .unresolved) return false;
        var b_index: usize = 0;
        for (a.set) |wanted| {
            while (b_index < b.set.len and atomLessThan({}, b.set[b_index], wanted)) : (b_index += 1) {}
            if (b_index == b.set.len or !std.meta.eql(b.set[b_index], wanted)) return false;
            b_index += 1;
        }
        return true;
    }
};

pub const unresolved: Origin = .unresolved;
pub const bottom: Origin = .{ .set = &.{} };

/// The slot state belongs to inference, outside the origin lattice. A bound
/// unresolved actual must never be mistaken for an unbound formal.
pub const OriginSlot = union(enum) {
    unbound,
    bound: *const Origin,

    pub fn bind(self: OriginSlot, store: *Store, actual: *const Origin) error{OutOfMemory}!OriginSlot {
        return switch (self) {
            .unbound => .{ .bound = actual },
            .bound => |previous| .{ .bound = try store.join(previous, actual) },
        };
    }
};

/// Child keys are resolved positions, not source spellings. The adapter must
/// supply a complete finite layout for each TypeTermId before flow analysis.
pub const ChildKey = union(enum) {
    type_argument: u32,
    field: u32,
    case_payload: u32,
    sequence_item,
    call_parameter: u32,
    call_result,
    ref_target,
    owned_target,
    optional_item,
    result_ok,
    result_err,
    /// Captured values travel through the resolved closure environment layout.
    closure_capture: u32,
    /// Declared inline-assembly operand positions.
    asm_input: u32,
    asm_inout,
    /// Boxed spawn payloads and their entry points are resolved child positions.
    spawn_payload,
    spawn_entry,
    spawn_group,
};

pub const Child = struct {
    key: ChildKey,
    fact: *const Fact,
};

/// Bridge from checked canonical types to finite fact layouts. Nominal fields
/// require resolved declaration layout and are added by the later body adapter.
pub const TypeAdapter = struct {
    types: *const semantic_types.TypeInterner,

    pub fn term(self: TypeAdapter, id: semantic_types.TypeId) error{InvalidTypeId}!TypeTermId {
        _ = try self.types.get(id);
        return @fromBackingInt(@intCast(@backingInt(id)));
    }

    pub fn unknownFact(self: TypeAdapter, store: *Store, id: semantic_types.TypeId) error{ OutOfMemory, InvalidTypeId, DuplicateChild }!*const Fact {
        const ty = try self.types.get(id);
        var children: std.ArrayListUnmanaged(Child) = .empty;
        defer children.deinit(store.allocator);
        switch (ty.*) {
            .generic_instance => |instance| for (instance.args, 0..) |arg, index| {
                if (arg == .type) try children.append(store.allocator, .{ .key = .{ .type_argument = @intCast(index) }, .fact = try self.unknownFact(store, arg.type) });
            },
            .optional => |item| try self.addChild(store, &children, .optional_item, item),
            .array => |array| try self.addChild(store, &children, .sequence_item, array.item),
            .dense_array, .sparse_array => |item| try self.addChild(store, &children, .sequence_item, item),
            .owned => |item| try self.addChild(store, &children, .owned_target, item),
            .slice => |slice| try self.addChild(store, &children, .sequence_item, slice.item),
            .result => |result| {
                try self.addChild(store, &children, .result_ok, result.ok);
                try self.addChild(store, &children, .result_err, result.err);
            },
            .error_union => |members| {
                for (members, 0..) |member, index| try self.addChild(store, &children, .{ .case_payload = @intCast(index) }, member);
            },
            .ref_ => |ref_| try self.addChild(store, &children, .ref_target, ref_.target),
            .raw => |raw| try self.addChild(store, &children, .ref_target, raw.target),
            .callable => |callable| {
                for (callable.params, 0..) |param, index| try self.addChild(store, &children, .{ .call_parameter = @intCast(index) }, param);
                try self.addChild(store, &children, .call_result, callable.return_type);
            },
            else => {},
        }
        return store.internFact(try self.term(id), &unresolved, children.items);
    }

    /// Resolve one nominal field layer from checked SIR declarations. A field
    /// fact remains finite even when its type refers back to this nominal.
    pub fn nominalFact(self: TypeAdapter, store: *Store, id: semantic_types.TypeId, structs: []const sir.StructDecl) error{ OutOfMemory, InvalidTypeId, DuplicateChild, MissingNominalLayout, MissingFieldType }!*const Fact {
        const ty = try self.types.get(id);
        const decl_id = structDeclId(ty.*) orelse return error.MissingNominalLayout;
        const decl = for (structs) |*candidate| {
            if (candidate.decl_id == decl_id) break candidate;
        } else return error.MissingNominalLayout;
        var children: std.ArrayListUnmanaged(Child) = .empty;
        defer children.deinit(store.allocator);
        for (decl.fields, 0..) |field, index| {
            const field_type = field.type_id orelse return error.MissingFieldType;
            try self.addChild(store, &children, .{ .field = @intCast(index) }, field_type);
        }
        return store.internFact(try self.term(id), &unresolved, children.items);
    }

    pub fn projectField(self: TypeAdapter, fact: *const Fact, access: sir.FieldAccess, structs: []const sir.StructDecl) error{ InvalidTypeId, MissingNominalLayout, IncorrectFieldOwner, MissingField, MissingFieldType, MissingFieldFact, IncorrectFieldType }!*const Fact {
        return self.projectNamedField(fact, access.struct_decl_id, access.field, structs);
    }

    pub fn projectNamedField(self: TypeAdapter, fact: *const Fact, checked_owner: ?identity.DeclId, field_name: []const u8, structs: []const sir.StructDecl) error{ InvalidTypeId, MissingNominalLayout, IncorrectFieldOwner, MissingField, MissingFieldType, MissingFieldFact, IncorrectFieldType }!*const Fact {
        const ty = try self.types.get(@fromBackingInt(@intCast(@backingInt(fact.type_term))));
        const owner = structDeclId(ty.*) orelse return error.MissingNominalLayout;
        if (checked_owner == null or checked_owner.? != owner) return error.IncorrectFieldOwner;
        const decl = for (structs) |*candidate| {
            if (candidate.decl_id == owner) break candidate;
        } else return error.MissingNominalLayout;
        for (decl.fields, 0..) |field_decl, index| {
            if (!std.mem.eql(u8, field_decl.name, field_name)) continue;
            const declared_type = field_decl.type_id orelse return error.MissingFieldType;
            const child = fact.child(.{ .field = @intCast(index) }) orelse return error.MissingFieldFact;
            if (child.type_term != try self.term(declared_type)) return error.IncorrectFieldType;
            return child;
        }
        return error.MissingField;
    }

    pub fn projectSequenceItem(self: TypeAdapter, fact: *const Fact) error{ InvalidTypeId, MissingCaptureFact, IncorrectResultType, UnsupportedExpression }!*const Fact {
        const ty = try self.types.get(@fromBackingInt(@intCast(@backingInt(fact.type_term))));
        const item_type = switch (ty.*) {
            .array => |array| array.item,
            .dense_array, .sparse_array => |item| item,
            .slice => |slice| slice.item,
            else => return error.UnsupportedExpression,
        };
        const item = fact.child(.sequence_item) orelse return error.MissingCaptureFact;
        if (item.type_term != try self.term(item_type)) return error.IncorrectResultType;
        return item;
    }

    pub fn replaceFieldPath(self: TypeAdapter, store: *Store, fact: *const Fact, steps: []const sir.StructFieldPathStep, replacement: *const Fact, structs: []const sir.StructDecl) error{ OutOfMemory, InvalidTypeId, DuplicateChild, MissingNominalLayout, IncorrectFieldOwner, MissingField, MissingFieldType, MissingFieldFact, IncorrectFieldType, IncorrectPayloadFactType }!*const Fact {
        if (steps.len == 0) {
            if (fact.type_term != replacement.type_term) return error.IncorrectPayloadFactType;
            return replacement;
        }
        const ty = try self.types.get(@fromBackingInt(@intCast(@backingInt(fact.type_term))));
        const owner = structDeclId(ty.*) orelse return error.MissingNominalLayout;
        if (steps[0].struct_decl_id == null or steps[0].struct_decl_id.? != owner) return error.IncorrectFieldOwner;
        const decl = for (structs) |*candidate| {
            if (candidate.decl_id == owner) break candidate;
        } else return error.MissingNominalLayout;
        const index = for (decl.fields, 0..) |field, field_index| {
            if (std.mem.eql(u8, field.name, steps[0].field)) break field_index;
        } else return error.MissingField;
        const field_type = decl.fields[index].type_id orelse return error.MissingFieldType;
        const key: ChildKey = .{ .field = @intCast(index) };
        // A skeleton binding may not record the field layer yet; recover the
        // declared layout of the field so nested path steps stay checked.
        const before: *const Fact = fact.child(key) orelse blk: {
            const declared_type = try self.types.get(field_type);
            if (structDeclId(declared_type.*) != null) break :blk try self.nominalFact(store, field_type, structs);
            break :blk try self.unknownFact(store, field_type);
        };
        if (before.type_term != try self.term(field_type)) return error.IncorrectFieldType;
        const after = try self.replaceFieldPath(store, before, steps[1..], replacement, structs);
        var children: std.ArrayListUnmanaged(Child) = .empty;
        defer children.deinit(store.allocator);
        var recorded = false;
        for (fact.children) |child| {
            if (std.meta.eql(child.key, key)) recorded = true;
            try children.append(store.allocator, .{ .key = child.key, .fact = if (std.meta.eql(child.key, key)) after else child.fact });
        }
        // A skeleton fact names only its declared type, so the first write to a
        // field layer has to create that layer instead of dropping it.
        if (!recorded) try children.append(store.allocator, .{ .key = key, .fact = after });
        return store.internFact(fact.type_term, fact.receiver, children.items);
    }

    /// Resolve the fact recorded at a checked field path. A skeleton binding
    /// that has not recorded a field layer yet recovers the declared layout so
    /// nested place writes stay checked against the resolved declaration.
    pub fn projectFieldPath(self: TypeAdapter, store: *Store, fact: *const Fact, steps: []const sir.StructFieldPathStep, structs: []const sir.StructDecl) error{ OutOfMemory, InvalidTypeId, DuplicateChild, MissingNominalLayout, IncorrectFieldOwner, MissingField, MissingFieldType, IncorrectFieldType }!*const Fact {
        var current = fact;
        for (steps) |step| {
            const ty = try self.types.get(@fromBackingInt(@intCast(@backingInt(current.type_term))));
            const owner = structDeclId(ty.*) orelse return error.MissingNominalLayout;
            if (step.struct_decl_id != null and step.struct_decl_id.? != owner) return error.IncorrectFieldOwner;
            const decl = for (structs) |*candidate| {
                if (candidate.decl_id == owner) break candidate;
            } else return error.MissingNominalLayout;
            const index = for (decl.fields, 0..) |field, field_index| {
                if (std.mem.eql(u8, field.name, step.field)) break field_index;
            } else return error.MissingField;
            const field_type = decl.fields[index].type_id orelse return error.MissingFieldType;
            const key: ChildKey = .{ .field = @intCast(index) };
            current = current.child(key) orelse blk: {
                const declared = try self.types.get(field_type);
                if (structDeclId(declared.*) != null) break :blk try self.nominalFact(store, field_type, structs);
                break :blk try self.unknownFact(store, field_type);
            };
            if (current.type_term != try self.term(field_type)) return error.IncorrectFieldType;
        }
        return current;
    }

    pub fn unionFact(self: TypeAdapter, store: *Store, id: semantic_types.TypeId, unions: []const sir.UnionDecl) error{ OutOfMemory, InvalidTypeId, DuplicateChild, MissingNominalLayout, MissingPayloadType }!*const Fact {
        const ty = try self.types.get(id);
        const owner = unionDeclId(ty.*) orelse return error.MissingNominalLayout;
        const decl = for (unions) |*candidate| {
            if (candidate.decl_id == owner) break candidate;
        } else return error.MissingNominalLayout;
        var children: std.ArrayListUnmanaged(Child) = .empty;
        defer children.deinit(store.allocator);
        for (decl.fields, 0..) |case_decl, index| {
            if (!case_decl.has_payload) continue;
            try self.addChild(store, &children, .{ .case_payload = @intCast(index) }, case_decl.type_id orelse return error.MissingPayloadType);
        }
        return store.internFact(try self.term(id), &unresolved, children.items);
    }

    pub fn projectCasePayload(self: TypeAdapter, fact: *const Fact, cast: sir.CastExpr, unions: []const sir.UnionDecl) error{ InvalidTypeId, MissingNominalLayout, IncorrectCaseOwner, MissingCase, MissingPayload, MissingPayloadType, IncorrectPayloadType, MissingPayloadFact, IncorrectPayloadFactType }!*const Fact {
        return self.projectNamedCasePayload(fact, cast.source_union_decl_id, cast.union_case_name orelse return error.MissingCase, cast.target_type_id, unions);
    }

    pub fn projectNamedCasePayload(self: TypeAdapter, fact: *const Fact, checked_owner: ?identity.DeclId, case_name: []const u8, expected_type: ?semantic_types.TypeId, unions: []const sir.UnionDecl) error{ InvalidTypeId, MissingNominalLayout, IncorrectCaseOwner, MissingCase, MissingPayload, MissingPayloadType, IncorrectPayloadType, MissingPayloadFact, IncorrectPayloadFactType }!*const Fact {
        const ty = try self.types.get(@fromBackingInt(@intCast(@backingInt(fact.type_term))));
        const owner = unionDeclId(ty.*) orelse return error.MissingNominalLayout;
        if (checked_owner == null or checked_owner.? != owner) return error.IncorrectCaseOwner;
        const decl = for (unions) |*candidate| {
            if (candidate.decl_id == owner) break candidate;
        } else return error.MissingNominalLayout;
        for (decl.fields, 0..) |case_decl, index| {
            if (!std.mem.eql(u8, case_decl.name, case_name)) continue;
            if (!case_decl.has_payload) return error.MissingPayload;
            const payload_type = case_decl.type_id orelse return error.MissingPayloadType;
            if (expected_type == null or expected_type.? != payload_type) return error.IncorrectPayloadType;
            const child = fact.child(.{ .case_payload = @intCast(index) }) orelse return error.MissingPayloadFact;
            if (child.type_term != try self.term(payload_type)) return error.IncorrectPayloadFactType;
            return child;
        }
        return error.MissingCase;
    }

    pub fn optionalPayload(self: TypeAdapter, fact: *const Fact) error{ InvalidTypeId, IncorrectConditionType, MissingCaptureFact }!*const Fact {
        const ty = try self.types.get(@fromBackingInt(@intCast(@backingInt(fact.type_term))));
        return switch (ty.*) {
            .optional => |item| blk: {
                const child = fact.child(.optional_item) orelse return error.MissingCaptureFact;
                if (child.type_term != try self.term(item)) return error.IncorrectConditionType;
                break :blk child;
            },
            .ref_ => |ref_| blk: {
                const child = fact.child(.ref_target) orelse return error.MissingCaptureFact;
                if (child.type_term != try self.term(ref_.target)) return error.IncorrectConditionType;
                break :blk try self.optionalPayload(child);
            },
            else => error.IncorrectConditionType,
        };
    }

    fn structDeclId(ty: semantic_types.Type) ?identity.DeclId {
        return switch (ty) {
            .nominal => |nominal| if (nominal.kind == .@"struct") nominal.decl_id else null,
            .generic_instance => |instance| if (instance.kind == .@"struct") instance.decl_id else null,
            else => null,
        };
    }

    fn unionDeclId(ty: semantic_types.Type) ?identity.DeclId {
        return switch (ty) {
            .nominal => |nominal| if (nominal.kind == .@"union") nominal.decl_id else null,
            .generic_instance => |instance| if (instance.kind == .@"union") instance.decl_id else null,
            else => null,
        };
    }

    fn addChild(self: TypeAdapter, store: *Store, children: *std.ArrayListUnmanaged(Child), key: ChildKey, id: semantic_types.TypeId) error{ OutOfMemory, InvalidTypeId, DuplicateChild }!void {
        try children.append(store.allocator, .{ .key = key, .fact = try self.unknownFact(store, id) });
    }
};

fn declaredTypeId(term: TypeTermId) semantic_types.TypeId {
    return @fromBackingInt(@intCast(@backingInt(term)));
}

pub const Fact = struct {
    type_term: TypeTermId,
    receiver: *const Origin,
    children: []const Child,

    pub fn child(self: *const Fact, key: ChildKey) ?*const Fact {
        for (self.children) |entry| if (std.meta.eql(entry.key, key)) return entry.fact;
        return null;
    }
};

/// One generic method use the checked flow reaches, with the receiver fact the
/// body actually evaluates it against. Admission is checked against this record
/// instead of an independent source-level shape walk.
pub const MethodUse = struct {
    expr: *const sir.Expr,
    /// Stable identity of the source use this expression came from, so one
    /// checked record can never settle a different use.
    use_id: u32,
    receiver: *const Fact,
    /// The concrete declaration the use lowered to, the type that use settles,
    /// and the canonical type ids the specialization substituted for the
    /// callee's generic parameters.
    callee_declaration_id: identity.DeclId,
    result_type_id: semantic_types.TypeId,
    substitution: []const semantic_types.TypeId,
};

/// A witness receiver is settled when neither the carrier nor the layer it
/// points at names a reachable value. An unresolved layer is still reachable:
/// it is top, not the bottom of the origin lattice.
fn receiverIsSettled(fact: *const Fact) bool {
    if (fact.receiver.* == .set and fact.receiver.set.len == 0) return false;
    if (fact.child(.ref_target)) |target| return receiverIsSettled(target);
    if (fact.child(.optional_item)) |item| return receiverIsSettled(item);
    return true;
}

/// A typed slice of expression transfer. Local reads are supplied by resolved
/// expression identity, not by shadowable source names. Direct calls can
/// analyze supported callee bodies with the caller's checked argument facts.
pub const PureExprAdapter = struct {
    types: TypeAdapter,
    metadata: []const sir.ExprMetadataEntry,
    structs: []const sir.StructDecl,
    unions: []const sir.UnionDecl = &.{},
    local_reads: []const LocalRead,
    /// Optional sink for the generic method uses the flow evaluates.
    method_uses: ?*std.ArrayListUnmanaged(MethodUse) = null,
    resolved_reads: []const ResolvedRead = &.{},
    binding_values: []const ?*const Fact = &.{},
    functions: []const sir.Function = &.{},
    active_calls: []const identity.DeclId = &.{},
    /// Checked view bindings and the binding whose place each view reaches.
    /// A call that receives a view can write through it, so the viewed binding's
    /// origin must be refreshed rather than trusted.
    alias_edges: []const AliasEdge = &.{},
    /// Enclosing function return type, required to route a propagated `try`
    /// error out of a nested expression.
    return_type: ?semantic_types.TypeId = null,
    exit: ?*ExitEdge = null,

    /// Per-statement early-exit edge. A nested `try` records the propagated
    /// error on its error edge; `definite` means that edge is taken
    /// statically, so the success edge never reaches later operands.
    pub const ExitEdge = struct {
        propagated: ?*const Fact = null,
        recorded: bool = false,
        definite: bool = false,
    };

    pub const LocalRead = struct { expr: *const sir.Expr, fact: *const Fact };
    pub const ResolvedRead = struct { expr: *const sir.Expr, slot: u32 };
    pub const AliasEdge = struct { slot: u32, target: u32 };
    pub const Error = error{ OutOfMemory, InvalidTypeId, DuplicateChild, IncompatibleType, IncompatibleChildren, MissingMetadata, DuplicateMetadata, MissingLocalRead, InvalidBindingSlot, UninitializedBinding, IncorrectResultType, IncorrectResultCaseType, IncorrectReturnType, UnsupportedExpression, MissingNominalLayout, IncorrectFieldOwner, MissingField, MissingFieldType, MissingFieldFact, MissingCaptureFact, DuplicateField, IncorrectFieldType, IncorrectCaseOwner, MissingCase, MissingPayload, MissingPayloadType, MissingPayloadFact, IncorrectPayloadType, IncorrectPayloadFactType, MissingCallTarget, MissingCallResult, IncorrectCallSignature, MissingPlaceIdentity, MissingGlobalIdentity, IncorrectGlobalIdentity, MissingFunctionIdentity, MissingCaptureIdentity, MissingIntrinsicIdentity, MissingDerefIdentity, IncorrectDerefContract, IncorrectAssemblyContract, IncorrectCallableContract, UnverifiedMethodReceiver, MissingMethodUseIdentity, MissingMethodUseSignature };

    fn admitOptionalPayload(self: PureExprAdapter, store: *Store, value: *const Fact, expected: TypeTermId) Error!*const Fact {
        if (value.type_term == expected) return value;
        const carrier = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
        if (carrier.* != .optional) return error.IncorrectPayloadFactType;
        const item_term = try self.types.term(carrier.optional);
        const origin = if (value.receiver.* == .unresolved) &unresolved else try store.intern(value.receiver.set);
        var payload = value;
        if (value.type_term != item_term) {
            const item = try self.types.types.get(carrier.optional);
            const source = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(value.type_term))));
            const admitted = (source.* == .inferred_integer and (item.* == .integer or item.* == .inferred_integer)) or
                (source.* == .inferred_float and (item.* == .float or item.* == .inferred_float));
            if (!admitted) return error.IncorrectPayloadFactType;
            payload = try store.internFact(item_term, origin, &.{});
        }
        // Keep projected fields and borrowed roots when a whole value becomes
        // the present payload, rather than rebuilding it as an empty scalar.
        return store.internFact(expected, origin, &.{.{ .key = .optional_item, .fact = payload }});
    }

    pub fn eval(self: PureExprAdapter, store: *Store, expr: *const sir.Expr) Error!*const Fact {
        const expected = try self.expectedTerm(expr);
        // When a `try` in this statement errors statically, evaluation order
        // stops: the operands after it are never reached.
        if (self.exit != null and self.exit.?.definite) return try self.unreachableCarrier(store, expected);
        const fact = switch (expr.*) {
            .@"switch" => try self.types.unknownFact(store, @fromBackingInt(@intCast(@backingInt(expected)))),
            .failure_detail => try self.concreteScalar(store, expected),
            .int, .float, .rune, .string, .bool, .none => blk: {
                const ty = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                const matches = switch (expr.*) {
                    .int => isInteger(ty),
                    .float => ty.* == .float or ty.* == .inferred_float,
                    .rune => isPrimitive(ty, .rune),
                    .string => isPrimitive(ty, .string) or isPrimitive(ty, .c_str),
                    .bool => isPrimitive(ty, .bool),
                    .none => ty.* == .optional,
                    else => unreachable,
                };
                if (!matches) return error.IncorrectResultType;
                const skeleton = try self.types.unknownFact(store, @fromBackingInt(@intCast(@backingInt(expected))));
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), skeleton.children);
            },
            .enum_case => |case| blk: {
                const ty = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (ty.* != .nominal or ty.nominal.kind != .@"enum" or case.decl_id == null or case.decl_id.? != ty.nominal.decl_id) return error.IncorrectCaseOwner;
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{});
            },
            .@"try" => |attempt| blk: {
                if (self.exit == null or self.return_type == null) return error.UnsupportedExpression;
                const value = try self.eval(store, attempt.expr);
                const value_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(value.type_term))));
                if (value_type.* != .result or attempt.result_ok_type_id == null or attempt.result_err_type_id == null or
                    attempt.result_ok_type_id.? != value_type.result.ok or attempt.result_err_type_id.? != value_type.result.err) return error.IncorrectResultCaseType;
                // A `try` forks the statement: the error edge returns from the
                // enclosing function, the success edge continues with the payload.
                const failed = self.knownResultCase(attempt.expr, value);
                if (failed != false) {
                    const edge = self.exit.?;
                    const propagated = try self.propagatedError(store, value, value_type, attempt.widen_ordinal);
                    edge.propagated = if (edge.propagated) |previous| try store.joinFacts(previous, propagated) else propagated;
                    edge.recorded = true;
                    if (failed == true) edge.definite = true;
                }
                if (failed == true) break :blk try self.unreachableCarrier(store, expected);
                break :blk value.child(.result_ok) orelse return error.MissingCaptureFact;
            },
            .local => blk: {
                const source = try self.readBindingFact(expr);
                break :blk if (source.type_term == expected) source else try self.coerceLocalRead(store, source, expected);
            },
            .ref_alias_local => blk: {
                // A borrowed alias names a checked place. Either the binding already
                // holds the reference, or the alias borrows the value the binding owns,
                // in which case the capability points at that value's layer.
                const source = try self.readBindingFact(expr);
                if (source.type_term == expected) break :blk source;
                const ty = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (ty.* == .ref_ and source.type_term == try self.types.term(ty.ref_.target)) {
                    break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .ref_target, .fact = source }});
                }
                // The place is itself reached through a checked view: aliasing it
                // names the same referent, and a mutable view may be re-qualified
                // const. A const view can never be re-qualified mutable.
                break :blk try self.coerceLocalRead(store, source, expected);
            },
            .handoff_local => try self.readBindingFact(expr),
            .ref_owned_local => blk: {
                const source = try self.readBindingFact(expr);
                const source_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(source.type_term))));
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (source_type.* != .owned or result_type.* != .ref_ or source_type.owned != result_type.ref_.target) return error.IncorrectResultType;
                const target = source.child(.owned_target) orelse return error.MissingCaptureFact;
                if (target.type_term != try self.types.term(source_type.owned)) return error.IncorrectResultType;
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .ref_target, .fact = target }});
            },
            .ref_local => blk: {
                const source = try self.readBindingFact(expr);
                const ty = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (ty.* != .ref_) return error.IncorrectResultType;
                if (source.type_term != try self.types.term(ty.ref_.target)) return error.IncorrectResultType;
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .ref_target, .fact = source }});
            },
            .ref_field_local, .ref_field_owned_local => |field| blk: {
                const root = try self.readBindingFact(expr);
                const root_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(root.type_term))));
                const object = if (expr.* == .ref_field_owned_local) owned: {
                    if (root_type.* != .owned) return error.IncorrectResultType;
                    const target = root.child(.owned_target) orelse return error.MissingCaptureFact;
                    if (target.type_term != try self.types.term(root_type.owned)) return error.IncorrectResultType;
                    break :owned target;
                } else if (root_type.* == .ref_) reference: {
                    // The place root is a checked alias or view: the field is
                    // projected from the referenced layer, not the carrier.
                    const target = root.child(.ref_target) orelse return error.MissingCaptureFact;
                    if (target.type_term != try self.types.term(root_type.ref_.target)) return error.IncorrectResultType;
                    break :reference target;
                } else root;
                // A borrowed formal arrives as an unresolved nominal skeleton, so
                // recover the declared field layer before projecting the place.
                const projected = try self.types.projectNamedField(try self.enrichNominal(store, object), field.struct_decl_id, field.field, self.structs);
                const ty = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (ty.* != .ref_ or projected.type_term != try self.types.term(ty.ref_.target)) return error.IncorrectResultType;
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .ref_target, .fact = projected }});
            },
            .ref_index_local => |access| blk: {
                const root = try self.readBindingFact(expr);
                _ = try self.eval(store, access.index);
                const item = try self.types.projectSequenceItem(root);
                const ty = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (ty.* == .optional) {
                    // Sparse storage names a slot that may be empty, so the place is
                    // read as a maybe-present capability of the slot's value layer.
                    if (try self.placeCapability(store, expected, item)) |fact| break :blk fact;
                }
                if (ty.* != .ref_ or item.type_term != try self.types.term(ty.ref_.target)) return error.IncorrectResultType;
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .ref_target, .fact = item }});
            },
            .ref_path_local, .ref_index_path_local => blk: {
                const root = try self.readBindingFact(expr);
                const steps = if (expr.* == .ref_path_local) expr.ref_path_local.steps else expr.ref_index_path_local.steps;
                var projected = try self.projectAliasSteps(store, root, steps);
                if (expr.* == .ref_index_path_local) {
                    _ = try self.eval(store, expr.ref_index_path_local.index);
                    projected = try self.types.projectSequenceItem(projected);
                }
                const ty = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                // Sparse storage names a slot that may be empty, so the place is read
                // as a maybe-present capability of the slot's value layer.
                if (try self.placeCapability(store, expected, projected)) |fact| break :blk fact;
                if (ty.* != .ref_ or projected.type_term != try self.types.term(ty.ref_.target)) return error.IncorrectResultType;
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .ref_target, .fact = projected }});
            },
            .ref_union_field_local => |field| blk: {
                const root = try self.readBindingFact(expr);
                const ty = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (ty.* != .ref_) return error.IncorrectResultType;
                const projected = try self.types.projectNamedCasePayload(root, field.union_decl_id, field.field, ty.ref_.target, self.unions);
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .ref_target, .fact = projected }});
            },
            .ref_field_expr => |field| blk: {
                const source = try self.eval(store, field.object);
                const source_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(source.type_term))));
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (source_type.* != .ref_ or result_type.* != .ref_) return error.IncorrectResultType;
                const target = source.child(.ref_target) orelse return error.MissingCaptureFact;
                if (target.type_term != try self.types.term(source_type.ref_.target)) return error.IncorrectResultType;
                const projected = try self.types.projectNamedField(target, field.struct_decl_id, field.field, self.structs);
                if (projected.type_term != try self.types.term(result_type.ref_.target)) return error.IncorrectResultType;
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .ref_target, .fact = projected }});
            },
            .field, .borrowed_field => |access| blk: {
                const source = try self.eval(store, access.object);
                const object = try self.placeLayer(source);
                break :blk try self.types.projectField(try self.enrichNominal(store, object), access, self.structs);
            },
            .tuple_field => |access| blk: {
                // Scalar tuple projections carry no borrowed origin. Their
                // operand is still visited by the ordinary read/effect walk.
                _ = access;
                break :blk try self.types.unknownFact(store, @fromBackingInt(@intCast(@backingInt(expected))));
            },
            .union_field, .borrowed_union_field => |access| blk: {
                const object = try self.enrichNominal(store, try self.eval(store, access.object));
                break :blk try self.types.projectNamedCasePayload(object, access.union_decl_id, access.field, @fromBackingInt(@intCast(@backingInt(expected))), self.unions);
            },
            .struct_literal => |literal| try self.constructStruct(store, expected, literal),
            .new_owned => |literal| blk: {
                const wrapper = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (wrapper.* != .owned) return error.IncorrectResultType;
                const target = try self.constructStruct(store, try self.types.term(wrapper.owned), literal);
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .owned_target, .fact = target }});
            },
            .array_literal, .dense_array_literal => |literal| try self.constructSequence(store, expected, literal),
            .tuple_literal => |literal| blk: {
                for (literal.items) |item| _ = try self.eval(store, item);
                break :blk try self.types.unknownFact(store, @fromBackingInt(@intCast(@backingInt(expected))));
            },
            .array_default => |array| try self.constructEmptySequence(store, expected, array.item_type_id),
            .new_array => |array| blk: {
                _ = try self.eval(store, array.len);
                break :blk try self.constructEmptySequence(store, expected, array.item_type_id);
            },
            .new_sparse => |array| blk: {
                _ = try self.eval(store, array.capacity);
                break :blk try self.constructEmptySequence(store, expected, array.item_type_id);
            },
            .sparse_literal => |literal| blk: {
                if (literal.items.len != literal.len) return error.IncorrectResultType;
                break :blk try self.constructSparseSequence(store, expected, literal.item_type_id, literal.items, &.{});
            },
            .sparse_keyed_literal => |literal| try self.constructSparseSequence(store, expected, literal.item_type_id, &.{}, literal.entries),
            .index, .borrowed_index => |access| blk: {
                const sequence = try self.eval(store, access.object);
                _ = try self.eval(store, access.index);
                const layer = try self.placeLayer(sequence);
                const layer_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(layer.type_term))));
                if (layer_type.* == .sparse_array) {
                    // A sparse lookup materializes an optional result: the slot
                    // may be absent, so the payload origin is the container's
                    // recorded item layer and the carrier keeps the container's.
                    const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                    if (result_type.* != .optional or result_type.optional != layer_type.sparse_array) return error.IncorrectResultType;
                    const item = layer.child(.sequence_item) orelse try self.types.unknownFact(store, layer_type.sparse_array);
                    if (item.type_term != try self.types.term(layer_type.sparse_array)) return error.IncorrectResultType;
                    break :blk try store.internFact(expected, try store.join(layer.receiver, item.receiver), &.{.{ .key = .optional_item, .fact = item }});
                }
                const item = try self.types.projectSequenceItem(layer);
                if (item.type_term != expected) return error.IncorrectResultType;
                break :blk item;
            },
            .slice_range => |range| blk: {
                const sequence = try self.eval(store, range.object);
                if (range.start) |start| _ = try self.eval(store, start);
                if (range.end) |end| _ = try self.eval(store, end);
                const item = try self.types.projectSequenceItem(sequence);
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (result_type.* != .slice or item.type_term != try self.types.term(result_type.slice.item)) return error.IncorrectResultType;
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .sequence_item, .fact = item }});
            },
            .is_test => |test_expr| blk: {
                _ = try self.eval(store, test_expr.subject);
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (result_type.* != .primitive or result_type.primitive != .bool) return error.IncorrectResultType;
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{});
            },
            .unary => |unary| blk: {
                const operand = try self.eval(store, unary.expr);
                const operand_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(operand.type_term))));
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                switch (unary.op) {
                    .not => if (!isPrimitive(result_type, .bool) or !isPrimitive(operand_type, .bool)) return error.IncorrectResultType,
                    .bit_not => if (operand.type_term != expected or operand_type.* != .integer) return error.IncorrectResultType,
                    .negate => if (operand.type_term != expected or (operand_type.* != .integer and operand_type.* != .float)) return error.IncorrectResultType,
                    .copy_list => {
                        if (operand.type_term != expected or result_type.* != .dense_array) return error.IncorrectResultType;
                        break :blk operand;
                    },
                }
                break :blk try self.concreteScalar(store, expected);
            },
            .binary => |binary| blk: {
                // Short-circuit operators evaluate the right operand only on one
                // edge. Both operand origins are checked here, so a move inside
                // either side is still recorded; the edge-specific join of the
                // two binding states stays a B2 obligation.
                const left = try self.eval(store, binary.left);
                const right = try self.eval(store, binary.right);
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                switch (binary.op) {
                    .eq, .ne, .lt, .le, .gt, .ge, .in => if (!isPrimitive(result_type, .bool)) return error.IncorrectResultType,
                    .@"and", .@"or" => {
                        if (!isPrimitive(result_type, .bool)) return error.IncorrectResultType;
                        const left_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(left.type_term))));
                        const right_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(right.type_term))));
                        if (!isPrimitive(left_type, .bool) or !isPrimitive(right_type, .bool)) return error.IncorrectResultType;
                    },
                    else => {},
                }
                break :blk try self.concreteScalar(store, expected);
            },
            .test_assert => |condition| blk: {
                const value = try self.eval(store, condition);
                const condition_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(value.type_term))));
                if (condition_type.* != .primitive or condition_type.primitive != .bool) return error.IncorrectResultType;
                break :blk try self.concreteScalar(store, expected);
            },
            .builtin_print => |print| blk: {
                try self.evalPrintParts(store, print.parts);
                break :blk try self.concreteScalar(store, expected);
            },
            .interpolated_string => |parts| blk: {
                try self.evalPrintParts(store, parts);
                break :blk try self.concreteScalar(store, expected);
            },
            .sequence_len, .sparse_len, .string_len, .string_is_empty, .slice_len => |object| blk: {
                const value = try self.eval(store, object);
                const object_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(value.type_term))));
                const valid = switch (expr.*) {
                    .sequence_len => object_type.* == .dense_array,
                    .sparse_len => object_type.* == .sparse_array,
                    .string_len, .string_is_empty => isPrimitive(object_type, .string),
                    .slice_len => object_type.* == .slice,
                    else => unreachable,
                };
                if (!valid) return error.IncorrectResultType;
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (expr.* == .string_is_empty) {
                    if (!isPrimitive(result_type, .bool)) return error.IncorrectResultType;
                } else if (!isInteger(result_type)) return error.IncorrectResultType;
                break :blk try self.concreteScalar(store, expected);
            },
            .slice_ptr => |object| blk: {
                const value = try self.eval(store, object);
                const object_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(value.type_term))));
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (object_type.* != .slice or result_type.* != .raw) return error.IncorrectResultType;
                if (object_type.slice.item != result_type.raw.target or object_type.slice.is_const != result_type.raw.is_const) return error.IncorrectResultType;
                break :blk try self.types.unknownFact(store, @fromBackingInt(@intCast(@backingInt(expected))));
            },
            .string_from => |bytes| blk: {
                const source = try self.eval(store, bytes);
                if (!try self.isByteSlice(source.type_term)) return error.IncorrectResultType;
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (!isPrimitive(result_type, .string)) return error.IncorrectResultType;
                break :blk try self.concreteScalar(store, expected);
            },
            .string_bytes, .sparse_indices => |object| blk: {
                const source = try self.eval(store, object);
                const source_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(source.type_term))));
                if (expr.* == .string_bytes and !isPrimitive(source_type, .string)) return error.IncorrectResultType;
                if (expr.* == .sparse_indices and source_type.* != .sparse_array) return error.IncorrectResultType;
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                const item_type = if (expr.* == .string_bytes) switch (result_type.*) {
                    .slice => |slice| slice.item,
                    else => return error.IncorrectResultType,
                } else switch (result_type.*) {
                    .dense_array => |item| item,
                    else => return error.IncorrectResultType,
                };
                if (expr.* == .string_bytes) {
                    if (!try self.isByteSlice(expected)) return error.IncorrectResultType;
                } else {
                    const index_type = try self.types.types.get(item_type);
                    if (!isInteger(index_type)) return error.IncorrectResultType;
                }
                const item = try self.concreteScalar(store, try self.types.term(item_type));
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .sequence_item, .fact = item }});
            },
            .sparse_contains_index => |access| blk: {
                const object = try self.eval(store, access.object);
                const index = try self.eval(store, access.index);
                const object_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(object.type_term))));
                const index_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(index.type_term))));
                if (object_type.* != .sparse_array or !isInteger(index_type)) return error.IncorrectResultType;
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (!isPrimitive(result_type, .bool)) return error.IncorrectResultType;
                break :blk try self.concreteScalar(store, expected);
            },
            .sequence_push => |push| blk: {
                const object = try self.eval(store, push.object);
                const item_type = try self.containerItemType(object.type_term);
                const value = try self.eval(store, push.value);
                if (value.type_term != try self.types.term(item_type)) return error.IncorrectResultType;
                break :blk try self.concreteCarrier(store, expected);
            },
            .sparse_insert => |insert| blk: {
                const object = try self.eval(store, insert.object);
                const item_type = try self.containerItemType(object.type_term);
                const index = try self.eval(store, insert.index);
                if (!isInteger(try self.types.types.get(@fromBackingInt(@intCast(@backingInt(index.type_term)))))) return error.IncorrectResultType;
                const value = try self.eval(store, insert.value);
                if (value.type_term != try self.types.term(item_type)) return error.IncorrectResultType;
                break :blk try self.concreteCarrier(store, expected);
            },
            .sequence_reserve => |reserve| blk: {
                const object = try self.eval(store, reserve.object);
                const object_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(object.type_term))));
                if (object_type.* != .dense_array) return error.IncorrectResultType;
                const capacity = try self.eval(store, reserve.capacity);
                if (!isInteger(try self.types.types.get(@fromBackingInt(@intCast(@backingInt(capacity.type_term)))))) return error.IncorrectResultType;
                break :blk try self.concreteCarrier(store, expected);
            },
            .sequence_clear, .sparse_clear => |object| blk: {
                const value = try self.eval(store, object);
                const object_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(value.type_term))));
                const valid = switch (expr.*) {
                    .sequence_clear => object_type.* == .array or object_type.* == .dense_array,
                    .sparse_clear => object_type.* == .sparse_array,
                    else => unreachable,
                };
                if (!valid) return error.IncorrectResultType;
                break :blk try self.concreteCarrier(store, expected);
            },
            .sparse_take => |take| blk: {
                const object = try self.eval(store, take.object);
                const object_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(object.type_term))));
                if (object_type.* != .sparse_array) return error.IncorrectResultType;
                const index = try self.eval(store, take.index);
                if (!isInteger(try self.types.types.get(@fromBackingInt(@intCast(@backingInt(index.type_term)))))) return error.IncorrectResultType;
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (result_type.* != .optional or result_type.optional != object_type.sparse_array) return error.IncorrectResultType;
                const item = object.child(.sequence_item) orelse try self.types.unknownFact(store, object_type.sparse_array);
                if (item.type_term != try self.types.term(object_type.sparse_array)) return error.IncorrectResultType;
                break :blk try store.internFact(expected, try store.join(object.receiver, item.receiver), &.{.{ .key = .optional_item, .fact = item }});
            },
            .sequence_pop => |object| blk: {
                const value = try self.eval(store, object);
                const item = try self.types.projectSequenceItem(value);
                if (item.type_term != expected) return error.IncorrectResultType;
                break :blk item;
            },
            .string_starts_with, .string_ends_with, .string_contains, .string_find, .string_rfind => |call| blk: {
                const object = try self.eval(store, call.object);
                const value = try self.eval(store, call.value);
                const object_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(object.type_term))));
                const value_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(value.type_term))));
                if (!isPrimitive(object_type, .string) or !isPrimitive(value_type, .string)) return error.IncorrectResultType;
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (expr.* != .string_find and expr.* != .string_rfind and !isPrimitive(result_type, .bool)) return error.IncorrectResultType;
                break :blk if (expr.* == .string_find or expr.* == .string_rfind)
                    try self.concreteOptionalScalar(store, expected)
                else
                    try self.concreteScalar(store, expected);
            },
            .string_slice => |slice| blk: {
                const object = try self.eval(store, slice.object);
                const start = try self.eval(store, slice.start);
                const end = try self.eval(store, slice.end);
                const object_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(object.type_term))));
                const start_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(start.type_term))));
                const end_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(end.type_term))));
                if (!isPrimitive(object_type, .string) or !isInteger(start_type) or !isInteger(end_type)) return error.IncorrectResultType;
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (!isPrimitive(result_type, .string)) return error.IncorrectResultType;
                break :blk try self.concreteScalar(store, expected);
            },
            .ref_load => |source| blk: {
                const reference = try self.eval(store, source);
                const ty = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(reference.type_term))));
                const target = switch (ty.*) {
                    .ref_ => |ref| ref.target,
                    else => return error.UnsupportedExpression,
                };
                if (expected != try self.types.term(target)) return error.IncorrectResultType;
                break :blk reference.child(.ref_target) orelse return error.MissingCaptureFact;
            },
            .call => |call| blk: {
                const callee_id = call.decl_id orelse return error.MissingCallTarget;
                // A call already on the substitution stack cannot be expanded
                // again; it is summarized by its declared return contract.
                var recursive = false;
                for (self.active_calls) |active| {
                    if (active == callee_id) recursive = true;
                }
                var callee: ?*const sir.Function = null;
                for (self.functions) |*candidate| {
                    if (candidate.decl_id != callee_id) continue;
                    if (callee != null) return error.IncorrectCallSignature;
                    callee = candidate;
                }
                const resolved = callee orelse return error.MissingCallTarget;
                if (call.args.len != resolved.params.len) return error.IncorrectCallSignature;
                const actuals = try store.allocator.alloc(*const Fact, call.args.len);
                defer store.allocator.free(actuals);
                const argument_values = try store.allocator.dupe(?*const Fact, self.binding_values);
                defer store.allocator.free(argument_values);
                var argument_expression = self;
                argument_expression.binding_values = argument_values;
                const argument_flow = StraightLineFlow{
                    .allocator = store.allocator,
                    .expression = self,
                    .binding_types = &.{},
                    .writes = &.{},
                };
                for (call.args, 0..) |arg, index| {
                    // Evaluation order is explicit: once an earlier argument has
                    // returned through a `try` error edge, the remaining arguments
                    // are never evaluated and their handoffs never move.
                    if (self.exit != null and self.exit.?.definite) break;
                    const value = switch (arg) {
                        .value => |value| value,
                    };
                    actuals[index] = try argument_expression.eval(store, value);
                    const formal_type = resolved.params[index].type_id orelse return error.IncorrectCallSignature;
                    const formal_term = try self.types.term(formal_type);
                    if (actuals[index].type_term != formal_term) {
                        const from = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(actuals[index].type_term))));
                        const to = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(formal_term))));
                        // A const-borrow formal accepts two shapes: a mutable view of
                        // the same target, and a value the callee only borrows, for
                        // which lowering materializes the temporary const view.
                        if (to.* != .ref_ or !to.ref_.is_const) return error.IncorrectCallSignature;
                        if (from.* == .ref_) {
                            if (from.ref_.is_const or from.ref_.target != to.ref_.target) return error.IncorrectCallSignature;
                            actuals[index] = try store.internFact(formal_term, actuals[index].receiver, actuals[index].children);
                        } else if (actuals[index].type_term == try self.types.term(to.ref_.target)) {
                            actuals[index] = try store.internFact(formal_term, actuals[index].receiver, &.{.{ .key = .ref_target, .fact = actuals[index] }});
                        } else return error.IncorrectCallSignature;
                    }
                    argument_flow.consumeHandoffs(argument_values, value) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.UnsupportedExpression,
                    };
                }
                if (self.exit != null and self.exit.?.definite) {
                    // An earlier operand of this call already returned through a
                    // `try` error edge, so the callee never runs.
                    break :blk try self.unreachableCarrier(store, expected);
                }
                // The callee ran, so any checked local it received a non-owning
                // view of may have been written through that alias.
                try self.applyCallAliasEffects(store, call.args);
                // Only a use that reaches a protocol witness needs a settled
                // receiver: an ordinary call settles to its own declaration, so
                // it has no `Self` to supply.
                const protocol_authority = call.checked_method_use != null and call.checked_method_use.?.protocol_id != null;
                if (protocol_authority and self.method_uses != null) {
                    // A generic method use is admitted only against a receiver the
                    // body actually reaches: a place whose value layer names no
                    // reachable value can never supply the witness's `Self`.
                    if (!receiverIsSettled(actuals[0])) return error.UnverifiedMethodReceiver;
                    // The use must also carry its own checked identity and signature:
                    // the concrete callee it lowered to and the type it settles are
                    // the ones this flow resolved, so no record can borrow another
                    // use's authority or claim a different result.
                    const use = call.checked_method_use.?;
                    if (use.use_id == 0) return error.MissingMethodUseIdentity;
                    const use_callee = use.callee_declaration_id orelse return error.MissingMethodUseSignature;
                    const use_result = use.result_type_id orelse return error.MissingMethodUseSignature;
                    if (use_callee != callee_id) return error.IncorrectCallSignature;
                    if (resolved.return_type_id != use_result) return error.IncorrectCallSignature;
                    for (use.substitution) |substituted| _ = try self.types.term(substituted);
                    try self.method_uses.?.append(store.allocator, .{
                        .expr = expr,
                        .use_id = use.use_id,
                        .receiver = actuals[0],
                        .callee_declaration_id = use_callee,
                        .result_type_id = use_result,
                        .substitution = use.substitution,
                    });
                }
                if (resolved.is_extern or recursive) {
                    // An extern declaration has no checked body, and a call that
                    // is already on the substitution stack cannot be expanded
                    // again. Both are summarized by the declared return contract:
                    // a concrete carrier whose nominal layout is preserved for
                    // later projections. Body-derived recursive summaries remain B3.
                    const declared_return = resolved.return_type_id orelse return error.MissingCallResult;
                    if (declared_return != declaredTypeId(expected)) return error.IncorrectCallSignature;
                    const carrier = try self.concreteCarrier(store, expected);
                    break :blk try self.enrichNominal(store, carrier);
                }
                const active = try store.allocator.alloc(identity.DeclId, self.active_calls.len + 1);
                defer store.allocator.free(active);
                @memcpy(active[0..self.active_calls.len], self.active_calls);
                active[self.active_calls.len] = callee_id;
                var prepared = PreparedStraightLine.init(store.allocator, self.types, resolved, self.metadata, self.structs, self.unions, actuals) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.UnsupportedExpression,
                };
                defer prepared.deinit();
                prepared.expression.functions = self.functions;
                prepared.expression.active_calls = active;
                const outcome = prepared.run(store) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.UnsupportedExpression,
                };
                defer outcome.deinit(store.allocator);
                const declared_return = resolved.return_type_id;
                const void_return = declared_return != null and void_leaf: {
                    const ty = try self.types.types.get(declared_return.?);
                    break :void_leaf ty.* == .primitive and ty.primitive == .void;
                };
                if (!outcome.did_return and !void_return) return error.MissingCallResult;
                const returned = outcome.returned orelse void_result: {
                    if (!void_return) return error.MissingCallResult;
                    break :void_result try self.concreteCarrier(store, expected);
                };
                if (returned.type_term != expected) return error.IncorrectResultType;
                break :blk returned;
            },
            .cast => |cast| blk: {
                if (cast.fallible or cast.reinterpret) return error.UnsupportedExpression;
                if (cast.union_case_name != null) {
                    const subject = try self.eval(store, cast.subject);
                    break :blk try self.types.projectCasePayload(subject, cast, self.unions);
                }
                // Index syntax converts an integer key to the hook's declared
                // key type before the call. A checked conversion of an integer
                // yields a derived scalar, so it owns no place.
                const target_type = cast.target_type_id orelse return error.MissingMetadata;
                const target_term = try self.types.term(target_type);
                if (!isInteger(try self.types.types.get(target_type)))
                    return error.UnsupportedExpression;
                const subject = try self.eval(store, cast.subject);
                if (!isInteger(try self.types.types.get(@fromBackingInt(@intCast(@backingInt(subject.type_term))))))
                    return error.IncorrectResultType;
                if (expected != target_term) return error.IncorrectResultType;
                break :blk try self.concreteScalar(store, target_term);
            },
            .union_case => |case| blk: {
                if (case.result_case == null) break :blk try self.constructUnion(store, expected, case);
                const result_case = case.result_case.?;
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (result_type.* != .result) return error.IncorrectResultCaseType;
                if (case.result_ok_type_id == null or case.result_err_type_id == null or
                    case.result_ok_type_id.? != result_type.result.ok or case.result_err_type_id.? != result_type.result.err)
                    return error.IncorrectResultCaseType;
                const selected_type = if (result_case == .ok) result_type.result.ok else result_type.result.err;
                const selected_value = if (case.value) |value| try self.eval(store, value) else blk_value: {
                    const ty = try self.types.types.get(selected_type);
                    if (ty.* != .primitive or ty.primitive != .void) return error.MissingPayload;
                    break :blk_value try store.internFact(try self.types.term(selected_type), try store.intern(&.{.concrete}), &.{});
                };
                const selected = try self.admitOptionalPayload(store, selected_value, try self.types.term(selected_type));
                const skeleton = try self.types.unknownFact(store, @fromBackingInt(@intCast(@backingInt(expected))));
                // An inactive case has no reachable payload, but its declared
                // field or case layout must survive so a later join with the
                // active case's constructed payload compares the same children.
                const ok_shape = try self.enrichNominal(store, skeleton.child(.result_ok) orelse return error.MissingPayloadFact);
                const err_shape = try self.enrichNominal(store, skeleton.child(.result_err) orelse return error.MissingPayloadFact);
                const ok = if (result_case == .ok) selected else try store.bottomFact(ok_shape);
                const err = if (result_case == .err) selected else try store.bottomFact(err_shape);
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{
                    .{ .key = .result_ok, .fact = ok },
                    .{ .key = .result_err, .fact = err },
                });
            },
            .global_ref, .ref_global => |reference| blk: {
                const root = self.checkedPlaceRoot(expr) orelse return error.MissingPlaceIdentity;
                const global = switch (root) {
                    .global => |decl| decl,
                    else => return error.IncorrectGlobalIdentity,
                };
                if (reference.decl_id == null) return error.MissingGlobalIdentity;
                if (global != reference.decl_id.?) return error.IncorrectGlobalIdentity;
                // A borrowed global names its checked pointee layer as the
                // declared child position of the reference carrier.
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (result_type.* != .ref_) break :blk try self.concreteCarrier(store, expected);
                const target = try self.concreteCarrier(store, @fromBackingInt(@intCast(@backingInt(result_type.ref_.target))));
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .ref_target, .fact = target }});
            },
            .function_ref => |reference| blk: {
                if (reference.decl_id == null) return error.MissingFunctionIdentity;
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (result_type.* != .callable) return error.IncorrectCallableContract;
                break :blk try self.concreteCarrier(store, expected);
            },
            .closure => |closure| blk: {
                if (closure.env_decl_id == null or closure.function.decl_id == null) return error.MissingCaptureIdentity;
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (result_type.* != .callable) return error.IncorrectCallableContract;
                const skeleton = try self.types.unknownFact(store, @fromBackingInt(@intCast(@backingInt(expected))));
                var children: std.ArrayListUnmanaged(Child) = .empty;
                defer children.deinit(store.allocator);
                try children.appendSlice(store.allocator, skeleton.children);
                for (closure.captures, 0..) |capture, index| {
                    const captured = try self.eval(store, capture);
                    try children.append(store.allocator, .{ .key = .{ .closure_capture = @intCast(index) }, .fact = captured });
                }
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), children.items);
            },
            .closure_capture => |capture| blk: {
                const declared: semantic_types.TypeId = @fromBackingInt(@intCast(@backingInt(expected)));
                if (capture.type_id == null or capture.type_id.? != declared) return error.IncorrectResultType;
                break :blk try self.concreteCarrier(store, expected);
            },
            .raw_owned_local, .leak_owned_local => blk: {
                const source = try self.readBindingFact(expr);
                const source_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(source.type_term))));
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (source_type.* != .owned or result_type.* != .raw or source_type.owned != result_type.raw.target) return error.IncorrectResultType;
                const target = source.child(.owned_target) orelse return error.MissingCaptureFact;
                if (target.type_term != try self.types.term(source_type.owned)) return error.IncorrectResultType;
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .ref_target, .fact = target }});
            },
            .raw_deref, .ref_raw_deref => |deref| blk: {
                const checked = self.checkedRawDeref(expr) orelse return error.MissingDerefIdentity;
                if (checked.is_volatile != deref.is_volatile) return error.IncorrectDerefContract;
                const pointer = try self.eval(store, deref.expr);
                const pointer_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(pointer.type_term))));
                const pointee = switch (pointer_type.*) {
                    .raw => |raw| raw.target,
                    .ref_ => |reference| reference.target,
                    else => return error.IncorrectResultType,
                };
                if (checked.pointee_type_id != pointee) return error.IncorrectDerefContract;
                const projected = pointer.child(.ref_target) orelse return error.MissingCaptureFact;
                if (projected.type_term != try self.types.term(pointee)) return error.IncorrectResultType;
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (expr.* == .ref_raw_deref and (result_type.* != .ref_ or result_type.ref_.target != pointee)) return error.IncorrectResultType;
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .ref_target, .fact = projected }});
            },
            .asm_expr => |assembly| blk: {
                if (assembly.target_type_id == null or assembly.target_type_id.? != declaredTypeId(expected)) return error.IncorrectResultType;
                if (assembly.output != null and assembly.output.?.name.len == 0) return error.IncorrectAssemblyContract;
                const skeleton = try self.types.unknownFact(store, @fromBackingInt(@intCast(@backingInt(expected))));
                var children: std.ArrayListUnmanaged(Child) = .empty;
                defer children.deinit(store.allocator);
                try children.appendSlice(store.allocator, skeleton.children);
                var opaque_result = false;
                if (assembly.inout) |inout| {
                    const value = try self.eval(store, inout.value);
                    if (value.type_term != expected) return error.IncorrectAssemblyContract;
                    if (inout.name.len == 0) return error.IncorrectAssemblyContract;
                    // The template reads and writes this operand: the value the
                    // expression yields comes from the template rather than the
                    // seed, so no origin recorded here is proven.
                    opaque_result = true;
                    // When the operand exposes a place, the template may write
                    // through every view of that place, exactly as a callee that
                    // receives a borrowed argument can.
                    const operand_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(value.type_term))));
                    if (operand_type.* == .ref_ or operand_type.* == .raw) {
                        const slot = self.operandPlaceSlot(inout.value) orelse return error.MissingPlaceIdentity;
                        try self.refreshPlace(store, slot);
                    }
                    try children.append(store.allocator, .{ .key = .asm_inout, .fact = value });
                }
                for (assembly.inputs, 0..) |input, index| {
                    const value = try self.eval(store, input.value);
                    try children.append(store.allocator, .{ .key = .{ .asm_input = @intCast(index) }, .fact = value });
                }
                break :blk try store.internFact(expected, if (opaque_result) &unresolved else try store.intern(&.{.concrete}), children.items);
            },
            .indirect_call => |call| blk: {
                if (call.return_type_id == null or call.return_type_id.? != declaredTypeId(expected)) return error.IncorrectResultType;
                const callee = try self.eval(store, call.callee);
                const callee_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(callee.type_term))));
                if (callee_type.* != .callable) return error.IncorrectCallableContract;
                if (call.args.len != callee_type.callable.params.len) return error.IncorrectCallableContract;
                var children: std.ArrayListUnmanaged(Child) = .empty;
                defer children.deinit(store.allocator);
                // Arguments are read and moved in evaluation order, exactly as a
                // direct call does: an argument reached after a definite `try`
                // error edge is never evaluated and its handoff never leaves the
                // binding that owns it.
                const argument_values = try store.allocator.dupe(?*const Fact, self.binding_values);
                defer store.allocator.free(argument_values);
                var argument_expression = self;
                argument_expression.binding_values = argument_values;
                const argument_flow = StraightLineFlow{
                    .allocator = store.allocator,
                    .expression = self,
                    .binding_types = &.{},
                    .writes = &.{},
                };
                for (call.args, 0..) |argument, index| {
                    if (self.exit != null and self.exit.?.definite) break;
                    const value = switch (argument) {
                        .value => |value| value,
                    };
                    const actual = try argument_expression.eval(store, value);
                    const declared = callee_type.callable.params[index];
                    if (actual.type_term != try self.types.term(declared)) return error.IncorrectCallableContract;
                    argument_flow.consumeHandoffs(argument_values, value) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.UnsupportedExpression,
                    };
                    const summary = callee.child(.{ .call_parameter = @intCast(index) });
                    const joined = if (summary) |previous| try store.joinFacts(previous, actual) else actual;
                    try children.append(store.allocator, .{ .key = .{ .call_parameter = @intCast(index) }, .fact = joined });
                }
                if (self.exit != null and self.exit.?.definite) {
                    // An earlier argument already returned through a `try` error
                    // edge, so the callable never runs and no place it could have
                    // reached through a view is written.
                    break :blk try self.unreachableCarrier(store, expected);
                }
                // The callable ran, so every checked place it received a non-owning
                // view of may have been written through that view.
                try self.applyCallAliasEffects(store, call.args);
                const result = callee.child(.call_result) orelse return error.MissingCallResult;
                if (result.type_term != expected) return error.IncorrectResultType;
                try children.append(store.allocator, .{ .key = .call_result, .fact = result });
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), children.items);
            },
            .thread_spawn_boxed => |spawn| blk: {
                if (spawn.intrinsic_id == null or spawn.decl_id == null or spawn.trampoline.decl_id == null) return error.MissingIntrinsicIdentity;
                if (spawn.return_type_id == null or spawn.return_type_id.? != declaredTypeId(expected)) return error.IncorrectResultType;
                const payload = try self.eval(store, spawn.payload);
                if (spawn.payload_type_id == null or spawn.payload_type_id.? != declaredTypeId(payload.type_term)) return error.IncorrectPayloadFactType;
                const skeleton = try self.types.unknownFact(store, @fromBackingInt(@intCast(@backingInt(expected))));
                var children: std.ArrayListUnmanaged(Child) = .empty;
                defer children.deinit(store.allocator);
                try children.appendSlice(store.allocator, skeleton.children);
                try children.append(store.allocator, .{ .key = .spawn_payload, .fact = payload });
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), children.items);
            },
            .task_group_spawn_boxed => |spawn| blk: {
                if (spawn.intrinsic_id == null or spawn.decl_id == null or spawn.trampoline.decl_id == null) return error.MissingIntrinsicIdentity;
                if (spawn.return_type_id == null or spawn.return_type_id.? != declaredTypeId(expected)) return error.IncorrectResultType;
                if (spawn.result_type_id == null) return error.MissingCallResult;
                const group = try self.eval(store, spawn.group_raw);
                const entry = try self.eval(store, spawn.entry);
                const payload = try self.eval(store, spawn.payload);
                if (spawn.payload_type_id == null or spawn.payload_type_id.? != declaredTypeId(payload.type_term)) return error.IncorrectPayloadFactType;
                const skeleton = try self.types.unknownFact(store, @fromBackingInt(@intCast(@backingInt(expected))));
                var children: std.ArrayListUnmanaged(Child) = .empty;
                defer children.deinit(store.allocator);
                try children.appendSlice(store.allocator, skeleton.children);
                try children.append(store.allocator, .{ .key = .spawn_group, .fact = group });
                try children.append(store.allocator, .{ .key = .spawn_entry, .fact = entry });
                try children.append(store.allocator, .{ .key = .spawn_payload, .fact = payload });
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), children.items);
            },
            .task_result_take => |take| blk: {
                if (take.intrinsic_id == null) return error.MissingIntrinsicIdentity;
                if (take.return_type_id == null or take.return_type_id.? != declaredTypeId(expected)) return error.IncorrectResultType;
                if (take.value_type_id == null) return error.MissingCallResult;
                const result_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
                if (result_type.* != .result or result_type.result.ok != take.value_type_id.?) return error.IncorrectResultType;
                _ = try self.eval(store, take.witness);
                _ = try self.eval(store, take.pointer);
                const skeleton = try self.types.unknownFact(store, @fromBackingInt(@intCast(@backingInt(expected))));
                const ok = try self.enrichNominal(store, try self.concreteCarrier(store, @fromBackingInt(@intCast(@backingInt(take.value_type_id.?)))));
                const err = try store.bottomFact(skeleton.child(.result_err) orelse return error.MissingPayloadFact);
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), &.{
                    .{ .key = .result_ok, .fact = ok },
                    .{ .key = .result_err, .fact = err },
                });
            },
            .sync_share_boxed => |share| blk: {
                if (share.intrinsic_id == null or share.decl_id == null) return error.MissingIntrinsicIdentity;
                if (share.return_type_id == null or share.return_type_id.? != declaredTypeId(expected)) return error.IncorrectResultType;
                const payload = try self.eval(store, share.payload);
                if (share.payload_type_id == null or share.payload_type_id.? != declaredTypeId(payload.type_term)) return error.IncorrectPayloadFactType;
                const skeleton = try self.types.unknownFact(store, @fromBackingInt(@intCast(@backingInt(expected))));
                var children: std.ArrayListUnmanaged(Child) = .empty;
                defer children.deinit(store.allocator);
                try children.appendSlice(store.allocator, skeleton.children);
                try children.append(store.allocator, .{ .key = .spawn_payload, .fact = payload });
                break :blk try store.internFact(expected, try store.intern(&.{.concrete}), children.items);
            },
            .take_index_local => |take| blk: {
                const root = try self.projectAliasSteps(store, try self.readBindingFact(expr), &.{});
                _ = try self.eval(store, take.index);
                const item = try self.types.projectSequenceItem(root);
                if (item.type_term != expected) return error.IncorrectResultType;
                break :blk item;
            },
            .take_index_path_local => |take| blk: {
                var projected = try self.projectAliasSteps(store, try self.readBindingFact(expr), take.steps);
                _ = try self.eval(store, take.index);
                projected = try self.types.projectSequenceItem(projected);
                if (projected.type_term != expected) return error.IncorrectResultType;
                break :blk projected;
            },
            .take_path_local => |take| blk: {
                const root = try self.readBindingFact(expr);
                const projected = try self.projectAliasSteps(store, root, take.steps);
                if (projected.type_term != expected) return error.IncorrectResultType;
                break :blk projected;
            },
        };
        if (fact.type_term != expected) return error.IncorrectResultType;
        return fact;
    }

    /// A checked nominal place carries the field or case layout recorded in SIR.
    /// Skeleton facts (for example a raw pointer's pointee) carry only the type
    /// adapter's unresolved layout, so recover the declared layout before
    /// projecting. Known children keep their own origins.
    fn enrichNominal(self: PureExprAdapter, store: *Store, fact: *const Fact) Error!*const Fact {
        const id: semantic_types.TypeId = @fromBackingInt(@intCast(@backingInt(fact.type_term)));
        const ty = try self.types.types.get(id);
        const layout: ?*const Fact = if (TypeAdapter.structDeclId(ty.*) != null)
            try self.types.nominalFact(store, id, self.structs)
        else if (TypeAdapter.unionDeclId(ty.*) != null)
            try self.types.unionFact(store, id, self.unions)
        else
            null;
        const declared = layout orelse return fact;
        var children: std.ArrayListUnmanaged(Child) = .empty;
        defer children.deinit(store.allocator);
        // Structural children (type arguments, sequence items) stay, and the
        // declared nominal layout fills the field or case layer that the type
        // adapter's skeleton alone cannot describe.
        for (fact.children) |candidate| try children.append(store.allocator, candidate);
        for (declared.children) |candidate|
            if (fact.child(candidate.key) == null) try children.append(store.allocator, .{ .key = candidate.key, .fact = candidate.fact });
        return store.internFact(fact.type_term, fact.receiver, children.items);
    }

    fn readBindingFact(self: PureExprAdapter, expr: *const sir.Expr) Error!*const Fact {
        for (self.resolved_reads) |entry| {
            if (entry.expr != expr) continue;
            if (entry.slot >= self.binding_values.len) return error.InvalidBindingSlot;
            return self.binding_values[entry.slot] orelse error.UninitializedBinding;
        }
        for (self.local_reads) |entry| if (entry.expr == expr) return entry.fact;
        return error.MissingLocalRead;
    }

    fn checkedPlaceRoot(self: PureExprAdapter, expr: *const sir.Expr) ?sir.CheckedPlaceRoot {
        for (self.metadata) |entry| if (entry.expr == expr) return entry.metadata.checked_place_root;
        return null;
    }

    fn checkedPlacePath(self: PureExprAdapter, expr: *const sir.Expr) ?sir.CheckedPlacePath {
        for (self.metadata) |entry| if (entry.expr == expr) return entry.metadata.checkedPlacePath();
        return null;
    }

    /// A place reached through a non-owning view can be written by whoever
    /// holds that view, so no origin recorded anywhere inside it survives a
    /// call. The declared child layout is preserved so later projections still
    /// resolve; only every receiver on the path is refreshed.
    fn invalidateAliased(self: PureExprAdapter, store: *Store, fact: *const Fact) Error!*const Fact {
        var children: std.ArrayListUnmanaged(Child) = .empty;
        defer children.deinit(store.allocator);
        for (fact.children) |child| try children.append(store.allocator, .{
            .key = child.key,
            .fact = try self.invalidateAliased(store, child.fact),
        });
        return store.internFact(fact.type_term, &unresolved, children.items);
    }

    /// The checked binding whose place an operand names, or null when the
    /// operand is a temporary or projection that no checked binding owns.
    fn operandPlaceSlot(self: PureExprAdapter, expr: *const sir.Expr) ?u32 {
        for (self.resolved_reads) |read| {
            if (read.expr != expr) continue;
            if (read.slot >= self.binding_values.len) continue;
            return read.slot;
        }
        return null;
    }

    /// Refresh every checked binding that shares a place with `slot`. A callee
    /// that receives a borrowed view, or an assembly template that reaches a
    /// place, may write through any view of it, so neither the place nor its
    /// views keep a proven origin. The closure is bounded by the number of
    /// recorded edges, so an alias cycle cannot loop.
    fn refreshPlace(self: PureExprAdapter, store: *Store, slot: u32) Error!void {
        var reached: std.ArrayListUnmanaged(u32) = .empty;
        defer reached.deinit(store.allocator);
        try reached.append(store.allocator, slot);
        var step: usize = 0;
        while (step < self.alias_edges.len) {
            var added = false;
            for (self.alias_edges) |edge| {
                var seen_slot = false;
                var seen_target = false;
                for (reached.items) |candidate| {
                    if (candidate == edge.slot) seen_slot = true;
                    if (candidate == edge.target) seen_target = true;
                }
                if (seen_slot == seen_target) continue;
                const other = if (seen_slot) edge.target else edge.slot;
                var already = false;
                for (reached.items) |candidate| {
                    if (candidate == other) already = true;
                }
                if (already) continue;
                try reached.append(store.allocator, other);
                added = true;
            }
            if (!added) break;
            step += 1;
        }
        for (reached.items) |target| {
            const viewed = self.binding_values[target] orelse continue;
            @constCast(self.binding_values)[target] = try self.invalidateAliased(store, viewed);
        }
    }

    /// After a call runs, every checked binding whose place the callee received
    /// as a non-owning view is conservatively refreshed: the callee may have
    /// written through the view. A view naming another view resolves to the
    /// binding that place ultimately reaches.
    fn applyCallAliasEffects(self: PureExprAdapter, store: *Store, args: []const sir.CallArg) Error!void {
        for (args) |arg| {
            const value = switch (arg) {
                .value => |value| value,
            };
            const actual_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(try self.expectedTerm(value)))));
            const exposes_place = actual_type.* == .ref_ or actual_type.* == .raw;
            if (!exposes_place) continue;
            const slot = self.operandPlaceSlot(value) orelse continue;
            try self.refreshPlace(store, slot);
        }
    }

    fn checkedRawDeref(self: PureExprAdapter, expr: *const sir.Expr) ?sir.CheckedRawDeref {
        for (self.metadata) |entry| if (entry.expr == expr) return entry.metadata.checked_raw_deref;
        return null;
    }

    /// A resolved carrier keeps the declared type layout but claims no origin atom
    /// other than its own concrete source.
    fn concreteCarrier(self: PureExprAdapter, store: *Store, expected: TypeTermId) Error!*const Fact {
        const skeleton = try self.types.unknownFact(store, @fromBackingInt(@intCast(@backingInt(expected))));
        return store.internFact(expected, try store.intern(&.{.concrete}), skeleton.children);
    }

    /// A place in sparse storage is read as a maybe-present capability: the slot
    /// either holds the value layer or is empty. Returns null when the expected
    /// shape is not a capability of the projected layer.
    fn placeCapability(self: PureExprAdapter, store: *Store, expected: TypeTermId, layer: *const Fact) Error!?*const Fact {
        const declared = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
        switch (declared.*) {
            .optional => |item| {
                if (layer.type_term != try self.types.term(item)) return null;
                return store.internFact(expected, layer.receiver, &.{.{ .key = .optional_item, .fact = layer }});
            },
            .ref_ => |reference| {
                // A borrowed sparse slot is a view of a maybe-present place: the
                // view's target is the optional payload carrier, and the payload is
                // the value currently recorded in the slot.
                const target = try self.types.types.get(reference.target);
                if (target.* != .optional) return null;
                if (layer.type_term != try self.types.term(target.optional)) return null;
                const carrier = try store.internFact(try self.types.term(reference.target), layer.receiver, &.{.{ .key = .optional_item, .fact = layer }});
                return store.internFact(expected, layer.receiver, &.{.{ .key = .ref_target, .fact = carrier }});
            },
            else => return null,
        }
    }

    fn coerceLocalRead(self: PureExprAdapter, store: *Store, source: *const Fact, expected: TypeTermId) Error!*const Fact {
        const from = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(source.type_term))));
        const to = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
        if (from.* != .ref_) return error.IncorrectResultType;
        const target = source.child(.ref_target) orelse return error.MissingCaptureFact;
        if (target.type_term != try self.types.term(from.ref_.target)) return error.IncorrectResultType;
        if (expected == target.type_term) return target;
        if (to.* != .ref_ or from.ref_.target != to.ref_.target or from.ref_.is_const or !to.ref_.is_const) return error.IncorrectResultType;
        return store.internFact(expected, source.receiver, &.{.{ .key = .ref_target, .fact = target }});
    }

    fn concreteScalar(self: PureExprAdapter, store: *Store, expected: TypeTermId) Error!*const Fact {
        const ty = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
        switch (ty.*) {
            .primitive, .integer, .float, .inferred_integer, .inferred_float => {},
            else => return error.IncorrectResultType,
        }
        return store.internFact(expected, try store.intern(&.{.concrete}), &.{});
    }

    fn concreteOptionalScalar(self: PureExprAdapter, store: *Store, expected: TypeTermId) Error!*const Fact {
        const ty = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
        if (ty.* != .optional) return error.IncorrectResultType;
        const item = try self.concreteScalar(store, try self.types.term(ty.optional));
        return store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .optional_item, .fact = item }});
    }

    /// Element type of a checked container place, including sparse storage.
    fn containerItemType(self: PureExprAdapter, term: TypeTermId) error{ InvalidTypeId, IncorrectResultType }!semantic_types.TypeId {
        const ty = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(term))));
        return switch (ty.*) {
            .array => |array| array.item,
            .dense_array => |item| item,
            .slice => |slice| slice.item,
            .sparse_array => |item| item,
            else => error.IncorrectResultType,
        };
    }

    fn isPrimitive(ty: *const semantic_types.Type, primitive: semantic_types.Primitive) bool {
        return ty.* == .primitive and ty.primitive == primitive;
    }

    /// The layout a place read walks through. A borrowed view names its referent,
    /// and a raw handle carries the pointee layout it names under the same place
    /// key, so projections start at that layer and see an origin an earlier place
    /// write recorded there.
    fn placeLayer(self: PureExprAdapter, source: *const Fact) Error!*const Fact {
        const source_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(source.type_term))));
        // An owned binding names its place directly: the projection reads the
        // layer the constructor recorded inside the ownership wrapper.
        if (source_type.* == .owned) {
            const target = source.child(.owned_target) orelse return error.MissingCaptureFact;
            if (target.type_term != try self.types.term(source_type.owned)) return error.IncorrectResultType;
            return target;
        }
        if (source_type.* == .ref_) {
            const target = source.child(.ref_target) orelse return error.MissingCaptureFact;
            if (target.type_term != try self.types.term(source_type.ref_.target)) return error.IncorrectResultType;
            return target;
        }
        // A raw or leaked handle names the layout it points at directly, so the
        // projection starts at that recorded layer rather than the skeleton.
        const referent = source.child(.ref_target) orelse return source;
        if (referent.type_term == source.type_term) return referent;
        return source;
    }

    fn isInteger(ty: *const semantic_types.Type) bool {
        return ty.* == .integer or ty.* == .inferred_integer;
    }

    fn isByteSlice(self: PureExprAdapter, term: TypeTermId) Error!bool {
        const ty = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(term))));
        if (ty.* != .slice or !ty.slice.is_const) return false;
        const item = try self.types.types.get(ty.slice.item);
        return item.* == .integer and item.integer.bits == 8 and !item.integer.signed;
    }

    fn evalPrintParts(self: PureExprAdapter, store: *Store, parts: []const sir.BuiltinPrintPart) Error!void {
        for (parts) |part| switch (part) {
            .literal => {},
            .value => |value| {
                const fact = try self.eval(store, value.expr);
                const ty = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(fact.type_term))));
                switch (ty.*) {
                    .integer => {},
                    .primitive => |primitive| if (primitive != .string and primitive != .bool) return error.IncorrectResultType,
                    else => return error.IncorrectResultType,
                }
            },
        };
    }

    fn projectAliasSteps(self: PureExprAdapter, store: *Store, source: *const Fact, steps: []const sir.TakePathStep) Error!*const Fact {
        var fact = source;
        const root_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(fact.type_term))));
        if (root_type.* == .owned) {
            fact = fact.child(.owned_target) orelse return error.MissingCaptureFact;
            if (fact.type_term != try self.types.term(root_type.owned)) return error.IncorrectResultType;
        }
        // A place reached through a checked reference is the referent, not the
        // capability, so the projection starts from the reference's target.
        if (root_type.* == .ref_) {
            fact = fact.child(.ref_target) orelse return error.MissingCaptureFact;
            if (fact.type_term != try self.types.term(root_type.ref_.target)) return error.IncorrectResultType;
        }
        for (steps) |step| switch (step) {
            .field => |field| fact = try self.types.projectNamedField(try self.enrichNominal(store, fact), field.struct_decl_id, field.field, self.structs),
            .index => |index| {
                _ = try self.eval(store, index);
                fact = try self.types.projectSequenceItem(fact);
            },
        };
        return fact;
    }

    fn constructStruct(self: PureExprAdapter, store: *Store, expected: TypeTermId, literal: sir.StructLiteral) Error!*const Fact {
        const id: semantic_types.TypeId = @fromBackingInt(@intCast(@backingInt(expected)));
        if (literal.decl_id == null and typeCarriesBinder(self.types.types, id)) {
            // A constructor over a definition-site binder: no layout exists yet,
            // so the constructed value keeps the binder's unresolved skeleton.
            return self.types.unknownFact(store, id);
        }
        const ty = try self.types.types.get(id);
        const owner = TypeAdapter.structDeclId(ty.*) orelse return error.MissingNominalLayout;
        if (literal.decl_id == null or literal.decl_id.? != owner) return error.IncorrectFieldOwner;
        const decl = for (self.structs) |*candidate| {
            if (candidate.decl_id == owner) break candidate;
        } else return error.MissingNominalLayout;
        const assigned = try store.allocator.alloc(?*const Fact, decl.fields.len);
        defer store.allocator.free(assigned);
        @memset(assigned, null);
        for (literal.fields) |field| {
            const index = for (decl.fields, 0..) |declared, field_index| {
                if (std.mem.eql(u8, declared.name, field.name)) break field_index;
            } else return error.MissingField;
            if (assigned[index] != null) return error.DuplicateField;
            const field_type = decl.fields[index].type_id orelse return error.MissingFieldType;
            const value = try self.eval(store, field.value);
            if (value.type_term != try self.types.term(field_type)) return error.IncorrectFieldType;
            assigned[index] = value;
        }
        const structural = try self.types.unknownFact(store, id);
        var children: std.ArrayListUnmanaged(Child) = .empty;
        defer children.deinit(store.allocator);
        try children.appendSlice(store.allocator, structural.children);
        for (assigned, 0..) |maybe_fact, index| try children.append(store.allocator, .{
            .key = .{ .field = @intCast(index) },
            .fact = maybe_fact orelse return error.MissingFieldFact,
        });
        return store.internFact(expected, try store.intern(&.{.concrete}), children.items);
    }

    fn typeCarriesBinder(types: *const semantic_types.TypeInterner, id: semantic_types.TypeId) bool {
        const ty = types.get(id) catch return false;
        switch (ty.*) {
            .generic_parameter => return true,
            .optional => return typeCarriesBinder(types, ty.optional),
            .array => return typeCarriesBinder(types, ty.array.item),
            .dense_array, .sparse_array => |item| return typeCarriesBinder(types, item),
            .slice => return typeCarriesBinder(types, ty.slice.item),
            .result => return typeCarriesBinder(types, ty.result.ok) or typeCarriesBinder(types, ty.result.err),
            .ref_ => return typeCarriesBinder(types, ty.ref_.target),
            .owned => return typeCarriesBinder(types, ty.owned),
            .raw => return typeCarriesBinder(types, ty.raw.target),
            .generic_instance => |instance| {
                for (instance.args) |arg| if (arg == .type and typeCarriesBinder(types, arg.type)) return true;
                return false;
            },
            else => return false,
        }
    }

    fn constructSequence(self: PureExprAdapter, store: *Store, expected: TypeTermId, literal: sir.ArrayLiteral) Error!*const Fact {
        const id: semantic_types.TypeId = @fromBackingInt(@intCast(@backingInt(expected)));
        const ty = try self.types.types.get(id);
        const item_type = switch (ty.*) {
            .array => |array| array.item,
            .dense_array => |item| item,
            else => return error.UnsupportedExpression,
        };
        if (literal.item_type_id == null or literal.item_type_id.? != item_type or literal.items.len != literal.len) return error.IncorrectResultType;
        const item_term = try self.types.term(item_type);
        var item: ?*const Fact = null;
        for (literal.items) |expr| {
            var value = try self.eval(store, expr);
            if (value.type_term != item_term) {
                // At the definition site an element whose type is still a binder
                // stands for whatever concrete type the call site supplies. The
                // sequence keeps its declared item layout while the element's
                // binder origin joins into the item origin.
                if (!typeCarriesBinder(self.types.types, item_type) or !typeCarriesBinder(self.types.types, declaredTypeId(value.type_term))) return error.IncorrectFieldType;
                const skeleton = try self.types.unknownFact(store, item_type);
                value = try store.internFact(item_term, value.receiver, skeleton.children);
            }
            item = if (item) |prior| try store.joinFacts(prior, value) else value;
        }
        const summarized = item orelse try self.types.unknownFact(store, item_type);
        return store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .sequence_item, .fact = summarized }});
    }

    fn constructEmptySequence(self: PureExprAdapter, store: *Store, expected: TypeTermId, checked_item: ?semantic_types.TypeId) Error!*const Fact {
        const ty = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
        const item_type = switch (ty.*) {
            .array => |array| array.item,
            .dense_array, .sparse_array => |item| item,
            else => return error.IncorrectResultType,
        };
        if (checked_item == null or checked_item.? != item_type) return error.IncorrectResultType;
        const item = try self.types.unknownFact(store, item_type);
        return store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .sequence_item, .fact = item }});
    }

    fn constructSparseSequence(self: PureExprAdapter, store: *Store, expected: TypeTermId, checked_item: ?semantic_types.TypeId, items: []const *sir.Expr, entries: []const sir.SparseKeyedLiteralEntry) Error!*const Fact {
        const ty = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(expected))));
        if (ty.* != .sparse_array or checked_item == null or checked_item.? != ty.sparse_array) return error.IncorrectResultType;
        const item_term = try self.types.term(ty.sparse_array);
        var summary: ?*const Fact = null;
        for (items) |item| {
            const value = try self.eval(store, item);
            if (item.* == .none) continue;
            const payload = if (value.type_term == item_term) value else blk: {
                const slot_type = try self.types.types.get(@fromBackingInt(@intCast(@backingInt(value.type_term))));
                if (slot_type.* != .optional or slot_type.optional != ty.sparse_array) return error.IncorrectFieldType;
                break :blk value.child(.optional_item) orelse return error.MissingCaptureFact;
            };
            if (payload.type_term != item_term) return error.IncorrectFieldType;
            summary = if (summary) |previous| try store.joinFacts(previous, payload) else payload;
        }
        for (entries) |entry| {
            _ = try self.eval(store, entry.index);
            const value = try self.eval(store, entry.value);
            if (value.type_term != item_term) return error.IncorrectFieldType;
            summary = if (summary) |previous| try store.joinFacts(previous, value) else value;
        }
        const item = summary orelse try self.types.unknownFact(store, ty.sparse_array);
        return store.internFact(expected, try store.intern(&.{.concrete}), &.{.{ .key = .sequence_item, .fact = item }});
    }

    fn constructUnion(self: PureExprAdapter, store: *Store, expected: TypeTermId, case: sir.UnionCaseExpr) Error!*const Fact {
        const id: semantic_types.TypeId = @fromBackingInt(@intCast(@backingInt(expected)));
        const ty = try self.types.types.get(id);
        if (ty.* == .error_union) {
            const ordinal = case.inline_union_ordinal orelse return error.MissingCase;
            if (case.inline_union_type_id != id or ordinal >= ty.error_union.len) return error.IncorrectCaseOwner;
            const value = case.value orelse return error.MissingPayload;
            const selected = try self.eval(store, value);
            if (selected.type_term != try self.types.term(ty.error_union[ordinal])) return error.IncorrectPayloadFactType;
            const skeleton = try self.types.unknownFact(store, id);
            var children: std.ArrayListUnmanaged(Child) = .empty;
            defer children.deinit(store.allocator);
            for (skeleton.children) |child| {
                try children.append(store.allocator, .{
                    .key = child.key,
                    .fact = if (child.key == .case_payload and child.key.case_payload == ordinal) selected else try store.bottomFact(child.fact),
                });
            }
            return store.internFact(expected, try store.intern(&.{.concrete}), children.items);
        }
        const owner = TypeAdapter.unionDeclId(ty.*) orelse return error.MissingNominalLayout;
        if (case.decl_id == null or case.decl_id.? != owner) return error.IncorrectCaseOwner;
        const decl = for (self.unions) |*candidate| {
            if (candidate.decl_id == owner) break candidate;
        } else return error.MissingNominalLayout;
        const selected_index = for (decl.fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, case.case_name)) break index;
        } else return error.MissingCase;
        const selected_field = decl.fields[selected_index];
        if (selected_field.has_payload != (case.value != null)) return error.MissingPayload;
        const selected = if (case.value) |value| blk: {
            const field_type = selected_field.type_id orelse return error.MissingPayloadType;
            const payload = try self.eval(store, value);
            if (payload.type_term != try self.types.term(field_type)) return error.IncorrectPayloadFactType;
            break :blk payload;
        } else null;
        const structural = try self.types.unknownFact(store, id);
        const layout = try self.types.unionFact(store, id, self.unions);
        var children: std.ArrayListUnmanaged(Child) = .empty;
        defer children.deinit(store.allocator);
        try children.appendSlice(store.allocator, structural.children);
        for (layout.children) |child| {
            try children.append(store.allocator, .{
                .key = child.key,
                .fact = if (selected != null and std.meta.eql(child.key, ChildKey{ .case_payload = @intCast(selected_index) }))
                    selected.?
                else
                    try store.bottomFact(child.fact),
            });
        }
        return store.internFact(expected, try store.intern(&.{.concrete}), children.items);
    }

    fn expectedTerm(self: PureExprAdapter, expr: *const sir.Expr) Error!TypeTermId {
        var result: ?semantic_types.TypeId = null;
        for (self.metadata) |entry| {
            if (entry.expr != expr) continue;
            if (result != null) return error.DuplicateMetadata;
            result = entry.metadata.type_id;
        }
        return self.types.term(result orelse return error.MissingMetadata);
    }

    /// The carrier a `try` hands back to the enclosing function when its error
    /// case is taken. The success payload of that carrier is unreachable.
    fn propagatedError(self: PureExprAdapter, store: *Store, value: *const Fact, value_type: *const semantic_types.Type, widen_ordinal: ?u32) Error!*const Fact {
        if (value_type.* != .result) return error.IncorrectResultType;
        const return_type_id = self.return_type orelse return error.IncorrectReturnType;
        const return_type = try self.types.types.get(return_type_id);
        if (return_type.* != .result) return error.IncorrectReturnType;
        const source_err = value.child(.result_err) orelse return error.MissingCaptureFact;
        const err_fact = if (widen_ordinal) |ordinal| blk: {
            const target_id = return_type.result.err;
            const target = try self.types.types.get(target_id);
            const layout = if (target.* == .error_union)
                try self.types.unknownFact(store, target_id)
            else
                try self.types.unionFact(store, target_id, self.unions);
            const selected = layout.child(.{ .case_payload = ordinal }) orelse return error.MissingCaptureFact;
            if (selected.type_term != source_err.type_term) return error.IncorrectReturnType;
            var children: std.ArrayListUnmanaged(Child) = .empty;
            defer children.deinit(store.allocator);
            for (layout.children) |child| try children.append(store.allocator, .{
                .key = child.key,
                .fact = if (std.meta.eql(child.key, ChildKey{ .case_payload = ordinal })) source_err else try store.bottomFact(child.fact),
            });
            break :blk try store.internFact(try self.types.term(target_id), try store.intern(&.{.concrete}), children.items);
        } else if (source_err.type_term != try self.types.term(return_type.result.err)) blk: {
            const target_id = return_type.result.err;
            const target = try self.types.types.get(target_id);
            const layout = if (target.* == .error_union)
                try self.types.unknownFact(store, target_id)
            else
                try self.types.unionFact(store, target_id, self.unions);
            const source = try self.enrichNominal(store, source_err);
            var children: std.ArrayListUnmanaged(Child) = .empty;
            defer children.deinit(store.allocator);
            for (layout.children) |target_child| {
                var matched: ?*const Fact = null;
                for (source.children) |source_child| {
                    if (source_child.key != .case_payload) continue;
                    if (source_child.fact.type_term != target_child.fact.type_term) continue;
                    if (matched != null) return error.IncorrectReturnType;
                    matched = source_child.fact;
                }
                try children.append(store.allocator, .{
                    .key = target_child.key,
                    .fact = matched orelse try store.bottomFact(target_child.fact),
                });
            }
            break :blk try store.internFact(try self.types.term(target_id), try store.intern(&.{.concrete}), children.items);
        } else source_err;
        if (err_fact.type_term != try self.types.term(return_type.result.err)) return error.IncorrectReturnType;
        const skeleton = try self.types.unknownFact(store, return_type_id);
        const ok_shape = try self.enrichNominal(store, skeleton.child(.result_ok) orelse return error.MissingCaptureFact);
        const ok_fact = try store.bottomFact(ok_shape);
        return store.internFact(try self.types.term(return_type_id), try store.intern(&.{.concrete}), &.{
            .{ .key = .result_ok, .fact = ok_fact },
            .{ .key = .result_err, .fact = err_fact },
        });
    }

    /// A typed carrier for an operand that evaluation never reaches.
    fn unreachableCarrier(self: PureExprAdapter, store: *Store, expected: TypeTermId) Error!*const Fact {
        const skeleton = try self.types.unknownFact(store, @fromBackingInt(@intCast(@backingInt(expected))));
        var children: std.ArrayListUnmanaged(Child) = .empty;
        defer children.deinit(store.allocator);
        for (skeleton.children) |child| try children.append(store.allocator, .{ .key = child.key, .fact = try store.bottomFact(child.fact) });
        return store.internFact(expected, &bottom, children.items);
    }

    /// The result case a checked carrier provably takes. `null` means the case
    /// is not statically known: the fork keeps both edges. A carrier whose
    /// success (or error) payload is bottom can never take that edge, so a
    /// `try` over it is decided.
    fn knownResultCase(self: PureExprAdapter, attempted: *const sir.Expr, value: *const Fact) ?bool {
        _ = self;
        if (attempted.* == .union_case and attempted.union_case.result_case != null) return attempted.union_case.result_case.? == .err;
        const ok = value.child(.result_ok) orelse return null;
        const err = value.child(.result_err) orelse return null;
        const ok_empty = ok.receiver.* == .set and ok.receiver.set.len == 0;
        const err_empty = err.receiver.* == .set and err.receiver.set.len == 0;
        if (ok_empty) return true;
        if (err_empty) return false;
        return null;
    }
};

/// Flow over resolved binding slots. Deferred and effectful edges still need
/// the full typed body graph.
pub const StraightLineFlow = struct {
    allocator: std.mem.Allocator,
    expression: PureExprAdapter,
    binding_types: []const semantic_types.TypeId,
    writes: []const Write,
    scope_exits: []const ScopeExit = &.{},
    switch_scopes: []const SwitchScope = &.{},
    loop_scopes: []const LoopScope = &.{},
    for_scopes: []const ForScope = &.{},
    return_type: ?semantic_types.TypeId = null,

    pub const Write = struct { stmt: *const sir.Stmt, slot: u32 };
    pub const ScopeExit = struct { stmt: *const sir.Stmt, then_start: usize, then_end: usize, else_start: usize, else_end: usize, capture_slot: ?usize = null };
    pub const SwitchCaseScope = struct { start: usize, end: usize, capture_slot: ?usize = null };
    pub const SwitchScope = struct { stmt: *const sir.Stmt, cases: []const SwitchCaseScope, else_start: usize, else_end: usize };
    pub const LoopScope = struct { stmt: *const sir.Stmt, start: usize, end: usize };
    pub const ForScope = struct { stmt: *const sir.Stmt, start: usize, end: usize, item_slot: usize };
    pub const Result = struct {
        values: []?*const Fact,
        returned: ?*const Fact = null,
        did_return: bool = false,
        reachable: bool = true,
        continued: ?[]?*const Fact = null,
        broken: ?[]?*const Fact = null,

        pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
            allocator.free(self.values);
            if (self.continued) |values| allocator.free(values);
            if (self.broken) |values| allocator.free(values);
        }
    };
    pub const Error = PureExprAdapter.Error || error{ InvalidInitialState, MissingWriteTarget, MissingScopeExit, MissingSwitchScope, MissingLoopScope, MissingCaptureFact, MissingCaptureType, InvalidCapturePath, AlreadyInitialized, IncorrectBindingType, IncorrectReturnType, IncorrectConditionType, UnsupportedIfKind, UnsupportedStatement, IncompatibleType, IncompatibleChildren };

    pub fn run(self: StraightLineFlow, store: *Store, statements: []const sir.Stmt, initial: []const ?*const Fact) Error!Result {
        if (initial.len != self.binding_types.len) return error.InvalidInitialState;
        const values = try self.allocator.dupe(?*const Fact, initial);
        errdefer self.allocator.free(values);
        for (values, self.binding_types) |maybe_fact, ty| {
            if (maybe_fact) |fact| if (fact.type_term != try self.expression.types.term(ty)) return error.IncorrectBindingType;
        }
        var result: Result = .{ .values = values };
        try self.runSegment(store, statements, &result);
        return result;
    }

    /// A concrete value admitted into a wider carrier, such as an optional
    /// slot, keeps its own origin as the carrier's declared payload layer.
    fn widenToCarrier(self: StraightLineFlow, store: *Store, value: *const Fact, declared: semantic_types.TypeId) StraightLineFlow.Error!*const Fact {
        return self.widenToCarrierTerm(store, value, try self.expression.types.term(declared));
    }

    /// The same carrier admission for a layer whose type is already a term. A
    /// projected place can declare a carrier (for example `?T`), so a scalar
    /// write to that place is recorded as the carrier's payload, not rejected.
    fn widenToCarrierTerm(self: StraightLineFlow, store: *Store, value: *const Fact, expected: TypeTermId) StraightLineFlow.Error!*const Fact {
        return self.expression.admitOptionalPayload(store, value, expected) catch |err| switch (err) {
            error.IncorrectPayloadFactType => error.IncorrectBindingType,
            else => return err,
        };
    }

    fn runSegment(self: StraightLineFlow, store: *Store, statements: []const sir.Stmt, result: *Result) Error!void {
        var defers: std.ArrayListUnmanaged(*const sir.Expr) = .empty;
        defer defers.deinit(self.allocator);
        for (statements) |*stmt| {
            if (!result.reachable) break;
            // Each statement owns its own exit edge: a `try` inside it returns
            // from the enclosing function, and no later statement runs.
            var exit = PureExprAdapter.ExitEdge{};
            var expression = self.expression;
            expression.binding_values = result.values;
            expression.return_type = self.return_type;
            expression.exit = &exit;
            switch (stmt.*) {
                .local => |local| {
                    const slot = try self.writeSlot(stmt);
                    if (result.values[slot] != null) return error.AlreadyInitialized;
                    if (local.type_id) |declared| if (declared != self.binding_types[slot]) return error.IncorrectBindingType;
                    const value = try self.evalValue(store, result, expression, local.init);
                    if (!result.reachable) break;
                    const widened = try self.widenToCarrier(store, value, self.binding_types[slot]);
                    try self.consumeHandoffs(result.values, local.init);
                    result.values[slot] = widened;
                    // A detach empties the place it consumed, so the owning
                    // binding's recorded layer is rebuilt once the new binding
                    // has received the detached value.
                    try self.applyTakeEffects(store, result.values, local.init);
                    // A mutation inside the initializer settles the container it
                    // reaches, so an element origin a pop or clear left behind is
                    // not claimed twice.
                    try self.applyContainerEffects(store, result.values, local.init);
                },
                .assign => |assign| {
                    const slot = try self.writeSlot(stmt);
                    if (result.values[slot] == null) return error.UninitializedBinding;
                    const value = try self.evalValue(store, result, expression, assign.value);
                    if (!result.reachable) break;
                    const declared_type = try expression.types.types.get(self.binding_types[slot]);
                    if (declared_type.* == .ref_ or declared_type.* == .raw) {
                        // SIR lowers an assignment to a checked view as a plain
                        // assignment whose payload is the referent value. The write
                        // therefore replaces the referent layer of the view's fact.
                        const referent = switch (declared_type.*) {
                            .ref_ => |reference| reference.target,
                            .raw => |pointer| pointer.target,
                            else => unreachable,
                        };
                        if (value.type_term != try expression.types.term(referent)) return error.IncorrectBindingType;
                        try self.consumeHandoffs(result.values, assign.value);
                        const view_fact = result.values[slot].?;
                        var children: std.ArrayListUnmanaged(Child) = .empty;
                        defer children.deinit(store.allocator);
                        for (view_fact.children) |child| try children.append(store.allocator, .{
                            .key = child.key,
                            .fact = if (std.meta.eql(child.key, ChildKey{ .ref_target = {} })) value else child.fact,
                        });
                        if (view_fact.child(.ref_target) == null) try children.append(store.allocator, .{ .key = .{ .ref_target = {} }, .fact = value });
                        result.values[slot] = try store.internFact(view_fact.type_term, view_fact.receiver, children.items);
                        try self.applyTakeEffects(store, result.values, assign.value);
                        try self.applyContainerEffects(store, result.values, assign.value);
                        continue;
                    }
                    const widened = try self.widenToCarrier(store, value, self.binding_types[slot]);
                    try self.consumeHandoffs(result.values, assign.value);
                    result.values[slot] = widened;
                    try self.applyTakeEffects(store, result.values, assign.value);
                    try self.applyContainerEffects(store, result.values, assign.value);
                },
                .field_assign => |assign| {
                    const slot = try self.writeSlot(stmt);
                    // The declared field layer may not be present in a binding's
                    // skeleton fact yet, so recover it before projecting the path.
                    const root = try expression.enrichNominal(store, result.values[slot] orelse return error.UninitializedBinding);
                    if (assign.steps.len == 0) return error.MissingField;
                    const value = try self.evalValue(store, result, expression, assign.value);
                    if (!result.reachable) break;
                    // The place the path reaches has a declared layer, and the
                    // written value must fit it; a scalar entering an optional
                    // place is recorded as that carrier's payload.
                    const layer = try expression.types.projectFieldPath(store, root, assign.steps, expression.structs);
                    const widened = try self.widenToCarrierTerm(store, value, layer.type_term);
                    try self.consumeHandoffs(result.values, assign.value);
                    if (assign.capture != null) {
                        const capture_slot = try self.captureSlot(stmt);
                        if (result.values[capture_slot] != null) return error.AlreadyInitialized;
                        if (layer.type_term != try expression.types.term(self.binding_types[capture_slot])) return error.IncorrectBindingType;
                        result.values[capture_slot] = layer;
                    }
                    result.values[slot] = try expression.types.replaceFieldPath(store, root, assign.steps, widened, expression.structs);
                    try self.applyTakeEffects(store, result.values, assign.value);
                },
                .index_assign => |assign| {
                    const slot = try self.writeSlot(stmt);
                    // A nested indexed place writes through the binding that owns
                    // the place, so the checked path prefix selects the container
                    // layer that the new item origin joins into.
                    const root = result.values[slot] orelse return error.UninitializedBinding;
                    var prefix = try placeFieldPrefix(expression, store, assign.object);
                    defer prefix.deinit(store.allocator);
                    const container = try expression.types.projectFieldPath(store, root, prefix.items, expression.structs);
                    const container_type = try expression.types.types.get(@fromBackingInt(@intCast(@backingInt(container.type_term))));
                    const item_type = switch (container_type.*) {
                        .array => |array| array.item,
                        .dense_array, .sparse_array => |item| item,
                        .slice => |slice| slice.item,
                        else => return error.UnsupportedStatement,
                    };
                    _ = try expression.eval(store, assign.object);
                    _ = try expression.eval(store, assign.index);
                    const value = try expression.eval(store, assign.value);
                    const item_term = try expression.types.term(item_type);
                    if (value.type_term != item_term) return error.IncorrectBindingType;
                    try self.consumeHandoffs(result.values, assign.object);
                    try self.consumeHandoffs(result.values, assign.index);
                    try self.consumeHandoffs(result.values, assign.value);
                    const before = container.child(.sequence_item) orelse try store.internFact(item_term, &unresolved, &.{});
                    if (before.type_term != value.type_term) return error.IncorrectBindingType;
                    const joined = try store.joinFacts(before, value);
                    var children: std.ArrayListUnmanaged(Child) = .empty;
                    defer children.deinit(store.allocator);
                    for (container.children) |child| {
                        if (std.meta.eql(child.key, ChildKey{ .sequence_item = {} })) continue;
                        try children.append(store.allocator, child);
                    }
                    try children.append(store.allocator, .{ .key = .{ .sequence_item = {} }, .fact = joined });
                    const updated = try store.internFact(container.type_term, container.receiver, children.items);
                    result.values[slot] = try expression.types.replaceFieldPath(store, root, prefix.items, updated, expression.structs);
                },
                .expr => |expr| {
                    _ = try self.evalValue(store, result, expression, expr);
                    if (!result.reachable) break;
                    try self.consumeHandoffs(result.values, expr);
                    try self.applyContainerEffects(store, result.values, expr);
                    try self.applyTakeEffects(store, result.values, expr);
                },
                .yield => |maybe_expr| if (maybe_expr) |expr| {
                    _ = try self.evalValue(store, result, expression, expr);
                    try self.consumeHandoffs(result.values, expr);
                },
                .@"if" => try self.runIf(store, stmt, result, expression),
                .@"switch" => try self.runSwitch(store, stmt, result, expression),
                .@"while" => try self.runWhile(store, stmt, result, &exit),
                .@"for" => try self.runFor(store, stmt, result, &exit),
                .@"try" => |attempt| {
                    // A statement-rooted `try` evaluates its operand completely:
                    // the error edge returns from the function while the success
                    // edge continues with the following statements.
                    const value = try self.evalValue(store, result, expression, attempt.expr);
                    try self.consumeHandoffs(result.values, attempt.expr);
                    if (!result.reachable) break;
                    const value_type = try expression.types.types.get(@fromBackingInt(@intCast(@backingInt(value.type_term))));
                    if (value_type.* != .result) return error.IncorrectResultType;
                    const failed = expression.knownResultCase(attempt.expr, value);
                    if (failed != false) {
                        const ordinal = for (expression.metadata) |entry| {
                            if (entry.expr == attempt.expr) break entry.metadata.try_widen_ordinal;
                        } else null;
                        const propagated = try expression.propagatedError(store, value, value_type, ordinal);
                        exit.propagated = if (exit.propagated) |previous| try store.joinFacts(previous, propagated) else propagated;
                        exit.recorded = true;
                        if (failed == true) exit.definite = true;
                        try self.addReturn(store, result, propagated);
                        result.did_return = true;
                    }
                    if (exit.definite) {
                        result.reachable = false;
                        break;
                    }
                },
                .@"continue" => {
                    try self.addContinue(store, result, result.values);
                    result.reachable = false;
                    break;
                },
                .@"break" => {
                    try self.addBreak(store, result, result.values);
                    result.reachable = false;
                    break;
                },
                .unchecked => |body| {
                    try self.runSegment(store, body, result);
                    // Bindings introduced inside the block cannot be seen by the
                    // statements after it, so their checked origins end here.
                    try self.clearScopeSlots(stmt, result);
                },
                .using_alloc => |scope| {
                    _ = try self.evalValue(store, result, expression, scope.allocator_expr);
                    try self.runSegment(store, scope.body, result);
                    try self.clearScopeSlots(stmt, result);
                },
                .@"defer" => |expr| {
                    // Deferred work is recorded, not executed at registration. It is
                    // settled in reverse order when the segment exits, consuming its
                    // handoffs then.
                    try defers.append(self.allocator, expr);
                },
                .drop => |drop| {
                    // The owning slot comes from the checked write map, so the
                    // display name cannot select a different binding. Explicitly
                    // dropping a binding clears its live origin, and every view
                    // that reaches that place goes with it.
                    const slot = try self.writeSlot(stmt);
                    try self.invalidatePlace(result, slot);
                    _ = drop;
                },
                .asm_stmt => |assembly| for (assembly.inputs) |input| {
                    _ = try self.evalValue(store, result, expression, input.value);
                },
                .deref_assign => |assign| {
                    // A write through a raw or borrowed place replaces the origin
                    // recorded for that place instead of discarding it.
                    _ = try self.evalValue(store, result, expression, assign.pointer);
                    if (!result.reachable) break;
                    const value = try self.evalValue(store, result, expression, assign.value);
                    if (!result.reachable) break;
                    try self.consumeHandoffs(result.values, assign.value);
                    try self.applyPlaceWrite(store, result.values, assign.pointer, &.{}, value);
                },
                .deref_field_assign => |assign| {
                    _ = try self.evalValue(store, result, expression, assign.pointer);
                    if (!result.reachable) break;
                    const value = try self.evalValue(store, result, expression, assign.value);
                    if (!result.reachable) break;
                    try self.consumeHandoffs(result.values, assign.value);
                    try self.applyPlaceWrite(store, result.values, assign.pointer, assign.steps, value);
                },
                .@"return" => |maybe_expr| {
                    if (maybe_expr) |expr| {
                        const value = try self.evalValue(store, result, expression, expr);
                        if (!result.reachable) break;
                        const return_type = self.return_type orelse return error.IncorrectReturnType;
                        // The body's result may occupy a carrier the declaration names,
                        // such as `?T` for a settled `T`, exactly as a write to a
                        // projected place does.
                        const settled = self.widenToCarrierTerm(store, value, try expression.types.term(return_type)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => return error.IncorrectReturnType,
                        };
                        try self.consumeHandoffs(result.values, expr);
                        try self.addReturn(store, result, settled);
                    } else if (self.return_type != null) return error.IncorrectReturnType;
                    result.did_return = true;
                    result.reachable = false;
                    break;
                },
            }
        }
        if (result.broken) |values| {
            var edge = Result{ .values = values };
            try self.settleDefers(store, &edge, defers.items);
            if (edge.did_return) {
                result.did_return = true;
                if (edge.returned) |value| try self.addReturn(store, result, value);
            }
            if (!edge.reachable) {
                self.allocator.free(values);
                result.broken = null;
            }
        }
        try self.settleDefers(store, result, defers.items);
    }

    /// Statements after a lexical scope can no longer name the bindings it
    /// declared, so each of their slots is cleared when the segment exits.
    fn clearScopeSlots(self: StraightLineFlow, stmt: *const sir.Stmt, result: *Result) Error!void {
        for (self.scope_exits) |entry| {
            if (entry.stmt != stmt) continue;
            if (entry.then_end > result.values.len or entry.else_end > result.values.len) return error.InvalidBindingSlot;
            @memset(result.values[entry.then_start..entry.then_end], null);
            if (result.continued) |values| {
                if (entry.then_end > values.len or entry.else_end > values.len) return error.InvalidBindingSlot;
                @memset(values[entry.then_start..entry.then_end], null);
                @memset(values[entry.else_start..entry.else_end], null);
            }
            if (result.broken) |values| {
                if (entry.then_end > values.len or entry.else_end > values.len) return error.InvalidBindingSlot;
                @memset(values[entry.then_start..entry.then_end], null);
                @memset(values[entry.else_start..entry.else_end], null);
            }
            return;
        }
        return error.MissingScopeExit;
    }

    /// A dropped place cannot be reached through a view any more. Every binding
    /// whose recorded view reaches the dropped binding, transitively, stops
    /// naming an origin at the same time.
    fn invalidatePlace(self: StraightLineFlow, result: *Result, root: usize) Error!void {
        var reached: std.ArrayListUnmanaged(u32) = .empty;
        defer reached.deinit(self.allocator);
        try reached.append(self.allocator, @intCast(root));
        var index: usize = 0;
        while (index < reached.items.len) {
            const target = reached.items[index];
            index += 1;
            for (self.expression.alias_edges) |edge| {
                if (edge.target != target) continue;
                if (edge.slot >= result.values.len) return error.InvalidBindingSlot;
                if (result.values[edge.slot] == null) continue;
                result.values[edge.slot] = null;
                try reached.append(self.allocator, edge.slot);
            }
        }
        result.values[root] = null;
    }

    fn settleDefers(self: StraightLineFlow, store: *Store, result: *Result, defers: []const *const sir.Expr) Error!void {
        var index = defers.len;
        while (index > 0) {
            index -= 1;
            var expression = self.expression;
            expression.binding_values = result.values;
            expression.return_type = self.return_type;
            var exit = PureExprAdapter.ExitEdge{};
            expression.exit = &exit;
            _ = try self.evalValue(store, result, expression, defers[index]);
            try self.consumeHandoffs(result.values, defers[index]);
            if (!result.reachable) break;
        }
    }

    fn evalValue(self: StraightLineFlow, store: *Store, result: *Result, expression: PureExprAdapter, expr: *const sir.Expr) Error!*const Fact {
        const value = try expression.eval(store, expr);
        // A nested `try` records its error edge on the statement's exit edge.
        if (expression.exit != null and expression.exit.?.recorded) {
            const edge = expression.exit.?;
            if (edge.propagated) |fact| try self.addReturn(store, result, fact);
            result.did_return = true;
            if (edge.definite) result.reachable = false;
        }
        return value;
    }

    fn runIf(self: StraightLineFlow, store: *Store, stmt: *const sir.Stmt, result: *Result, expression: PureExprAdapter) Error!void {
        const if_stmt = stmt.@"if";
        const scope = for (self.scope_exits) |entry| {
            if (entry.stmt == stmt) break entry;
        } else return error.MissingScopeExit;
        const condition = try self.evalValue(store, result, expression, if_stmt.condition);
        if (!result.reachable) return;
        const known: ?bool = switch (if_stmt.kind) {
            .plain => blk: {
                if (if_stmt.capture_name != null) return error.UnsupportedIfKind;
                const condition_type = try expression.types.types.get(@fromBackingInt(@intCast(@backingInt(condition.type_term))));
                if (condition_type.* != .primitive or condition_type.primitive != .bool) return error.IncorrectConditionType;
                break :blk if (if_stmt.condition.* == .bool) if_stmt.condition.bool else null;
            },
            .optional_some => if (if_stmt.condition.* == .none) false else null,
            .optional_none => if (if_stmt.condition.* == .none) true else null,
            .union_case => blk: {
                const condition_type = try expression.types.types.get(@fromBackingInt(@intCast(@backingInt(condition.type_term))));
                if (condition_type.* != .result) break :blk null;
                const result_case = language_contracts.resolveResultCase(if_stmt.case_name.?) orelse return error.UnsupportedIfKind;
                const failed = expression.knownResultCase(if_stmt.condition, condition);
                break :blk if (failed) |is_err| is_err == (result_case == .err) else null;
            },
        };
        try self.consumeHandoffs(result.values, if_stmt.condition);
        var then_result = Result{ .values = try self.allocator.dupe(?*const Fact, result.values), .reachable = known != false };
        defer then_result.deinit(self.allocator);
        var else_result = Result{ .values = try self.allocator.dupe(?*const Fact, result.values), .reachable = known != true };
        defer else_result.deinit(self.allocator);
        if (then_result.reachable) {
            if (scope.capture_slot) |slot| {
                const capture_type = if_stmt.capture_type_id orelse return error.MissingCaptureType;
                const captured = switch (if_stmt.kind) {
                    .optional_some => try expression.types.optionalPayload(condition),
                    .union_case => blk: {
                        const condition_type = try expression.types.types.get(@fromBackingInt(@intCast(@backingInt(condition.type_term))));
                        if (condition_type.* == .result) {
                            const result_case = language_contracts.resolveResultCase(if_stmt.case_name.?) orelse return error.UnsupportedIfKind;
                            const expected_type = switch (result_case) {
                                .ok => condition_type.result.ok,
                                .err => condition_type.result.err,
                            };
                            if (capture_type != expected_type) return error.IncorrectBindingType;
                            break :blk condition.child(switch (result_case) {
                                .ok => .result_ok,
                                .err => .result_err,
                            }) orelse return error.MissingCaptureFact;
                        }
                        break :blk try expression.types.projectCasePayload(condition, .{
                            .subject = if_stmt.condition,
                            .source_union_decl_id = if_stmt.union_decl_id,
                            .target_type_id = capture_type,
                            .union_case_name = if_stmt.case_name,
                            .fallible = false,
                            .reinterpret = false,
                        }, expression.unions);
                    },
                    else => return error.UnsupportedIfKind,
                };
                if (captured.type_term != try expression.types.term(capture_type)) return error.IncorrectBindingType;
                then_result.values[slot] = captured;
            }
            try self.runSegment(store, if_stmt.then_body, &then_result);
        }
        if (else_result.reachable) try self.runSegment(store, if_stmt.else_body, &else_result);
        @memset(then_result.values[scope.then_start..scope.then_end], null);
        @memset(else_result.values[scope.else_start..scope.else_end], null);
        if (then_result.continued) |values| @memset(values[scope.then_start..scope.then_end], null);
        if (then_result.broken) |values| @memset(values[scope.then_start..scope.then_end], null);
        if (else_result.continued) |values| @memset(values[scope.else_start..scope.else_end], null);
        if (else_result.broken) |values| @memset(values[scope.else_start..scope.else_end], null);
        if (then_result.did_return) {
            result.did_return = true;
            if (then_result.returned) |value| try self.addReturn(store, result, value);
        }
        if (else_result.did_return) {
            result.did_return = true;
            if (else_result.returned) |value| try self.addReturn(store, result, value);
        }
        if (then_result.continued) |values| try self.addContinue(store, result, values);
        if (then_result.broken) |values| try self.addBreak(store, result, values);
        if (else_result.continued) |values| try self.addContinue(store, result, values);
        if (else_result.broken) |values| try self.addBreak(store, result, values);
        if (then_result.reachable and else_result.reachable) {
            for (result.values, then_result.values, else_result.values) |*destination, then_fact, else_fact| {
                destination.* = if (then_fact) |left| if (else_fact) |right| try store.joinFacts(left, right) else null else null;
            }
        } else if (then_result.reachable or else_result.reachable) {
            @memcpy(result.values, if (then_result.reachable) then_result.values else else_result.values);
        } else result.reachable = false;
    }

    fn runSwitch(self: StraightLineFlow, store: *Store, stmt: *const sir.Stmt, result: *Result, expression: PureExprAdapter) Error!void {
        const branch = stmt.@"switch";
        const scope = for (self.switch_scopes) |entry| {
            if (entry.stmt == stmt) break entry;
        } else return error.MissingSwitchScope;
        if (scope.cases.len != branch.cases.len) return error.MissingSwitchScope;
        const subject = try self.evalValue(store, result, expression, branch.value);
        if (!result.reachable) return;
        if (branch.subject_type_id == null or subject.type_term != try expression.types.term(branch.subject_type_id.?)) return error.IncorrectConditionType;
        try self.consumeHandoffs(result.values, branch.value);
        const entry_values = try self.allocator.dupe(?*const Fact, result.values);
        defer self.allocator.free(entry_values);
        var has_exit = false;
        for (branch.cases, scope.cases) |case, case_scope| {
            var arm = Result{ .values = try self.allocator.dupe(?*const Fact, entry_values) };
            defer arm.deinit(self.allocator);
            if (case_scope.capture_slot) |slot| {
                const payload_type = case.payload_type_id orelse return error.MissingCaptureType;
                const checked_case = (case.payload_path orelse return error.InvalidCapturePath).active_case;
                const payload = if (case.result_case) |result_case| blk: {
                    const ty = try expression.types.types.get(branch.subject_type_id.?);
                    if (ty.* != .result) return error.IncorrectConditionType;
                    if (checked_case != .result or checked_case.result != result_case) return error.InvalidCapturePath;
                    const key: ChildKey = if (result_case == .ok) .result_ok else .result_err;
                    break :blk subject.child(key) orelse return error.MissingCaptureFact;
                } else blk: {
                    if (checked_case == .inline_error_union) {
                        const inline_case = checked_case.inline_error_union;
                        const subject_type = try expression.types.types.get(branch.subject_type_id.?);
                        if (subject_type.* != .error_union or inline_case.type_id != branch.subject_type_id.? or
                            inline_case.ordinal >= subject_type.error_union.len or subject_type.error_union[inline_case.ordinal] != payload_type)
                            return error.InvalidCapturePath;
                        break :blk subject.child(.{ .case_payload = inline_case.ordinal }) orelse return error.MissingCaptureFact;
                    }
                    if (checked_case != .union_field or branch.subject_decl_id == null or
                        checked_case.union_field.owner_decl_id != branch.subject_decl_id.?) return error.InvalidCapturePath;
                    const decl = for (expression.unions) |*candidate| {
                        if (candidate.decl_id == branch.subject_decl_id.?) break candidate;
                    } else return error.InvalidCapturePath;
                    const ordinal = checked_case.union_field.ordinal;
                    if (ordinal >= decl.fields.len or !std.mem.eql(u8, decl.fields[ordinal].name, case.case_name) or
                        decl.fields[ordinal].type_id != payload_type) return error.InvalidCapturePath;
                    break :blk try expression.types.projectCasePayload(subject, .{
                        .subject = branch.value,
                        .source_union_decl_id = branch.subject_decl_id,
                        .target_type_id = payload_type,
                        .union_case_name = case.case_name,
                        .fallible = false,
                        .reinterpret = false,
                    }, expression.unions);
                };
                if (payload.type_term != try expression.types.term(payload_type)) return error.IncorrectBindingType;
                arm.values[slot] = payload;
            }
            try self.runSegment(store, case.body, &arm);
            try self.mergeSwitchArm(store, result, &arm, case_scope.start, case_scope.end, &has_exit);
        }
        if (branch.has_else) {
            var arm = Result{ .values = try self.allocator.dupe(?*const Fact, entry_values) };
            defer arm.deinit(self.allocator);
            try self.runSegment(store, branch.else_body, &arm);
            try self.mergeSwitchArm(store, result, &arm, scope.else_start, scope.else_end, &has_exit);
        } else if (!self.switchExhaustive(expression, branch)) {
            if (has_exit) {
                for (result.values, entry_values) |*destination, incoming| {
                    destination.* = if (destination.*) |left| if (incoming) |right| try store.joinFacts(left, right) else null else null;
                }
            } else {
                @memcpy(result.values, entry_values);
                has_exit = true;
            }
        }
        result.reachable = has_exit;
    }

    fn mergeSwitchArm(self: StraightLineFlow, store: *Store, result: *Result, arm: *Result, start: usize, end: usize, has_exit: *bool) Error!void {
        @memset(arm.values[start..end], null);
        if (arm.continued) |values| @memset(values[start..end], null);
        if (arm.broken) |values| @memset(values[start..end], null);
        if (arm.did_return) {
            result.did_return = true;
            if (arm.returned) |value| try self.addReturn(store, result, value);
        }
        if (arm.continued) |values| try self.addContinue(store, result, values);
        if (arm.broken) |values| try self.addBreak(store, result, values);
        if (!arm.reachable) return;
        if (!has_exit.*) {
            @memcpy(result.values, arm.values);
            has_exit.* = true;
            return;
        }
        for (result.values, arm.values) |*destination, incoming| {
            destination.* = if (destination.*) |left| if (incoming) |right| try store.joinFacts(left, right) else null else null;
        }
    }

    fn switchExhaustive(self: StraightLineFlow, expression: PureExprAdapter, branch: sir.Switch) bool {
        _ = self;
        const ty = expression.types.types.get(branch.subject_type_id orelse return false) catch return false;
        if (ty.* == .result) {
            var ok = false;
            var err = false;
            for (branch.cases) |case| switch (case.result_case orelse return false) {
                .ok => ok = true,
                .err => err = true,
            };
            return ok and err;
        }
        const owner = TypeAdapter.unionDeclId(ty.*) orelse return false;
        if (branch.subject_decl_id == null or branch.subject_decl_id.? != owner) return false;
        const decl = for (expression.unions) |*candidate| {
            if (candidate.decl_id == owner) break candidate;
        } else return false;
        for (decl.fields) |field| {
            var found = false;
            for (branch.cases) |case| if (std.mem.eql(u8, case.case_name, field.name)) {
                found = true;
                break;
            };
            if (!found) return false;
        }
        return true;
    }

    fn addReturn(self: StraightLineFlow, store: *Store, result: *Result, value: *const Fact) Error!void {
        _ = self;
        result.returned = if (result.returned) |previous| try store.joinFacts(previous, value) else value;
    }

    fn addContinue(self: StraightLineFlow, store: *Store, result: *Result, values: []const ?*const Fact) Error!void {
        if (result.continued) |prior| {
            for (prior, values) |*destination, incoming| {
                destination.* = if (destination.*) |left| if (incoming) |right| try store.joinFacts(left, right) else null else null;
            }
        } else result.continued = try self.allocator.dupe(?*const Fact, values);
    }

    fn addBreak(self: StraightLineFlow, store: *Store, result: *Result, values: []const ?*const Fact) Error!void {
        if (result.broken) |prior| {
            for (prior, values) |*destination, incoming| {
                destination.* = if (destination.*) |left| if (incoming) |right| try store.joinFacts(left, right) else null else null;
            }
        } else result.broken = try self.allocator.dupe(?*const Fact, values);
    }

    fn joinLoopBreaks(self: StraightLineFlow, store: *Store, result: *Result, breaks: *Result) Error!void {
        _ = self;
        const values = breaks.broken orelse return;
        if (result.reachable) {
            for (result.values, values) |*destination, incoming| {
                destination.* = if (destination.*) |left| if (incoming) |right| try store.joinFacts(left, right) else null else null;
            }
        } else @memcpy(result.values, values);
        result.reachable = true;
    }

    fn runWhile(self: StraightLineFlow, store: *Store, stmt: *const sir.Stmt, result: *Result, exit: *PureExprAdapter.ExitEdge) Error!void {
        const loop = stmt.@"while";
        const scope = for (self.loop_scopes) |entry| {
            if (entry.stmt == stmt) break entry;
        } else return error.MissingLoopScope;
        const entry_values = try self.allocator.dupe(?*const Fact, result.values);
        defer self.allocator.free(entry_values);
        const header = try self.allocator.dupe(?*const Fact, result.values);
        defer self.allocator.free(header);
        const exit_values = try self.allocator.dupe(?*const Fact, result.values);
        defer self.allocator.free(exit_values);
        const known: ?bool = if (loop.condition.* == .bool) loop.condition.bool else null;
        var breaks = Result{ .values = &.{} };
        defer breaks.deinit(self.allocator);
        while (true) {
            var expression = self.expression;
            expression.binding_values = header;
            expression.return_type = self.return_type;
            expression.exit = exit;
            const condition = try self.evalValue(store, result, expression, loop.condition);
            if (!result.reachable) return;
            const condition_type = try expression.types.types.get(@fromBackingInt(@intCast(@backingInt(condition.type_term))));
            if (condition_type.* != .primitive or condition_type.primitive != .bool) return error.IncorrectConditionType;
            const tested = try self.allocator.dupe(?*const Fact, header);
            defer self.allocator.free(tested);
            try self.consumeHandoffs(tested, loop.condition);
            @memcpy(exit_values, tested);
            if (known == false) break;
            var body = Result{ .values = try self.allocator.dupe(?*const Fact, tested) };
            defer body.deinit(self.allocator);
            try self.runSegment(store, loop.body, &body);
            if (body.broken) |values| {
                @memset(values[scope.start..scope.end], null);
                try self.addBreak(store, &breaks, values);
            }
            if (body.continued) |values| {
                @memset(values[scope.start..scope.end], null);
                if (body.reachable) {
                    for (body.values, values) |*destination, incoming| {
                        destination.* = if (destination.*) |left| if (incoming) |right| try store.joinFacts(left, right) else null else null;
                    }
                } else {
                    @memcpy(body.values, values);
                    body.reachable = true;
                }
            }
            @memset(body.values[scope.start..scope.end], null);
            if (body.did_return) {
                result.did_return = true;
                if (body.returned) |value| try self.addReturn(store, result, value);
            }
            if (!body.reachable) {
                // Every path through the body leaves the function, so the loop's exit
                // edge is unreachable and the statements after the loop never run.
                if (body.did_return) result.reachable = false;
                break;
            }
            var changed = false;
            for (header, entry_values, body.values) |*destination, before, after| {
                const next = if (before) |left| if (after) |right| try store.joinFacts(left, right) else null else null;
                if (destination.* != next) changed = true;
                destination.* = next;
            }
            if (!changed) break;
        }
        if (known == true) {
            result.reachable = false;
        } else {
            @memcpy(result.values, exit_values);
        }
        try self.joinLoopBreaks(store, result, &breaks);
    }

    fn runFor(self: StraightLineFlow, store: *Store, stmt: *const sir.Stmt, result: *Result, exit: *PureExprAdapter.ExitEdge) Error!void {
        const loop = stmt.@"for";
        const generated_iteration = loop.iterator_init_decl_id != null or loop.iterator_has_next_decl_id != null or loop.iterator_next_decl_id != null or loop.iterable_index_decl_id != null;
        if (generated_iteration and loop.generated_method_uses.len == 0) return error.UnsupportedStatement;
        const scope = for (self.for_scopes) |entry| {
            if (entry.stmt == stmt) break entry;
        } else return error.MissingLoopScope;
        var expression = self.expression;
        expression.binding_values = result.values;
        expression.return_type = self.return_type;
        expression.exit = exit;
        const iterable = try self.evalValue(store, result, expression, loop.iterable);
        if (!result.reachable) return;
        var item_fact: *const Fact = undefined;
        if (generated_iteration) {
            // Each generated hook runs against the iterable the body reaches,
            // so every hook is admitted against that receiver fact and against
            // the concrete declaration and result type its record names.
            if (!receiverIsSettled(iterable)) return error.UnverifiedMethodReceiver;
            for (loop.generated_method_uses) |use| {
                if (use.use_id == 0) return error.MissingMethodUseIdentity;
                var hook_return: ?semantic_types.TypeId = null;
                for (expression.functions) |function| {
                    if (function.decl_id == use.method_declaration_id) {
                        hook_return = function.return_type_id;
                        break;
                    }
                }
                if (hook_return == null or hook_return.? != use.result_type_id) return error.IncorrectCallSignature;
                for (use.substitution) |substituted| _ = try expression.types.term(substituted);
                switch (use.role) {
                    .iterator_init => if (loop.iterator_state_type_id != use.result_type_id) return error.IncorrectCallSignature,
                    .iterator_has_next => {
                        const settled = try expression.types.types.get(use.result_type_id);
                        if (settled.* != .primitive or settled.primitive != .bool) return error.IncorrectCallSignature;
                    },
                    .iterator_next => if (loop.iterator_cursor_type_id != use.result_type_id) return error.IncorrectCallSignature,
                    .iterable_item => {
                        const loop_item_type = loop.item_type_id orelse return error.IncorrectBindingType;
                        const settled = try expression.types.types.get(use.result_type_id);
                        // The item hook may settle a borrowed view of the loop's
                        // item type rather than the item type itself.
                        const matches = use.result_type_id == loop_item_type or
                            (settled.* == .ref_ and settled.ref_.target == loop_item_type);
                        if (!matches) return error.IncorrectCallSignature;
                    },
                }
                if (expression.method_uses != null) {
                    try expression.method_uses.?.append(store.allocator, .{
                        .expr = loop.iterable,
                        .use_id = use.use_id,
                        .receiver = iterable,
                        .callee_declaration_id = use.method_declaration_id,
                        .result_type_id = use.result_type_id,
                        .substitution = use.substitution,
                    });
                }
            }
            // A hook's item layer is not a container child the flow can project,
            // so the binding starts from the item type's whole shape.
            const item_type = loop.item_type_id orelse return error.IncorrectBindingType;
            if (self.binding_types[scope.item_slot] != item_type) return error.IncorrectBindingType;
            item_fact = try expression.types.unknownFact(store, item_type);
        } else {
            const iterable_type = try expression.types.types.get(@fromBackingInt(@intCast(@backingInt(iterable.type_term))));
            const raw_item_type = switch (iterable_type.*) {
                .array => |array| array.item,
                .dense_array => |item| item,
                .slice => |slice| slice.item,
                .sparse_array => |item| item,
                else => return error.UnsupportedStatement,
            };
            const raw_item = iterable.child(.sequence_item) orelse return error.MissingCaptureFact;
            if (raw_item.type_term != try expression.types.term(raw_item_type)) return error.IncorrectBindingType;
            const item_type = loop.item_type_id orelse return error.IncorrectBindingType;
            if (self.binding_types[scope.item_slot] != item_type) return error.IncorrectBindingType;
            item_fact = if (iterable_type.* == .sparse_array) blk: {
                const optional_type = try expression.types.types.get(item_type);
                if (optional_type.* != .optional or optional_type.optional != raw_item_type) return error.IncorrectBindingType;
                break :blk try store.internFact(try expression.types.term(item_type), try store.intern(&.{.concrete}), &.{.{ .key = .optional_item, .fact = raw_item }});
            } else blk: {
                if (item_type != raw_item_type) return error.IncorrectBindingType;
                break :blk raw_item;
            };
        }
        try self.consumeHandoffs(result.values, loop.iterable);
        const entry_values = try self.allocator.dupe(?*const Fact, result.values);
        defer self.allocator.free(entry_values);
        const header = try self.allocator.dupe(?*const Fact, result.values);
        defer self.allocator.free(header);
        var breaks = Result{ .values = &.{} };
        defer breaks.deinit(self.allocator);
        while (true) {
            var body = Result{ .values = try self.allocator.dupe(?*const Fact, header) };
            defer body.deinit(self.allocator);
            body.values[scope.item_slot] = item_fact;
            try self.runSegment(store, loop.body, &body);
            if (body.broken) |values| {
                @memset(values[scope.start..scope.end], null);
                try self.addBreak(store, &breaks, values);
            }
            if (body.continued) |values| {
                @memset(values[scope.start..scope.end], null);
                if (body.reachable) {
                    for (body.values, values) |*destination, incoming| {
                        destination.* = if (destination.*) |left| if (incoming) |right| try store.joinFacts(left, right) else null else null;
                    }
                } else {
                    @memcpy(body.values, values);
                    body.reachable = true;
                }
            }
            @memset(body.values[scope.start..scope.end], null);
            if (body.did_return) {
                result.did_return = true;
                if (body.returned) |value| try self.addReturn(store, result, value);
            }
            if (!body.reachable) {
                // Every path through the body leaves the function, so the loop's exit
                // edge is unreachable and the statements after the loop never run.
                if (body.did_return) result.reachable = false;
                break;
            }
            var changed = false;
            for (header, entry_values, body.values) |*destination, before, after| {
                const next = if (before) |left| if (after) |right| try store.joinFacts(left, right) else null else null;
                if (destination.* != next) changed = true;
                destination.* = next;
            }
            if (!changed) break;
        }
        @memcpy(result.values, header);
        try self.joinLoopBreaks(store, result, &breaks);
    }

    fn writeSlot(self: StraightLineFlow, stmt: *const sir.Stmt) Error!usize {
        for (self.writes) |write| {
            if (write.stmt != stmt) continue;
            if (write.slot >= self.binding_types.len) return error.InvalidBindingSlot;
            return write.slot;
        }
        return error.MissingWriteTarget;
    }

    fn captureSlot(self: StraightLineFlow, stmt: *const sir.Stmt) Error!usize {
        var seen_root = false;
        for (self.writes) |write| {
            if (write.stmt != stmt) continue;
            if (!seen_root) {
                seen_root = true;
                continue;
            }
            if (write.slot >= self.binding_types.len) return error.InvalidBindingSlot;
            return write.slot;
        }
        return error.MissingWriteTarget;
    }

    /// The checked steps a container place walked through before the statement's
    /// own index. A direct local container has no prefix; every other indexed
    /// write must carry the checked field path that selects its container layer.
    fn placeFieldPrefix(expression: PureExprAdapter, store: *Store, object: *const sir.Expr) Error!std.ArrayListUnmanaged(sir.StructFieldPathStep) {
        var prefix: std.ArrayListUnmanaged(sir.StructFieldPathStep) = .empty;
        if (object.* == .local) return prefix;
        const place = expression.checkedPlacePath(object) orelse return error.MissingPlaceIdentity;
        const projections = place.projections orelse &.{};
        for (projections) |projection| {
            switch (projection.step) {
                .field => |field| try prefix.append(store.allocator, .{ .struct_decl_id = field.owner_decl_id, .struct_name = field.name, .field = field.name }),
                else => return error.UnsupportedStatement,
            }
        }
        return prefix;
    }

    /// The declared binding whose place a view expression names. A place the
    /// flow cannot resolve to a binding has no checked origin to update, so the
    /// statement is rejected rather than silently ignored.
    fn placeSlot(self: StraightLineFlow, expr: *const sir.Expr, values: []?*const Fact) Error!u32 {
        for (self.expression.resolved_reads) |read| {
            if (read.expr != expr) continue;
            if (read.slot >= values.len) return error.InvalidBindingSlot;
            return read.slot;
        }
        return error.MissingPlaceIdentity;
    }

    /// A write through a borrowed or raw place records the written origin in the
    /// layer the view names, and widens the origin of every binding that view
    /// reaches: the callee-style alias rule applies to explicit place writes too.
    fn applyPlaceWrite(self: StraightLineFlow, store: *Store, values: []?*const Fact, pointer: *const sir.Expr, steps: []const sir.StructFieldPathStep, written_value: *const Fact) Error!void {
        const slot = try self.placeSlot(pointer, values);
        const root = values[slot] orelse return error.UninitializedBinding;
        const declared = try self.expression.types.types.get(@fromBackingInt(@intCast(@backingInt(root.type_term))));
        const pointee: semantic_types.TypeId = switch (declared.*) {
            .raw => |raw| raw.target,
            .ref_ => |reference| reference.target,
            else => return error.UnsupportedStatement,
        };
        // A freshly leaked or uninitialized place carries no pointee layer yet;
        // its declared skeleton is the layer the write fills.
        const before = root.child(.ref_target) orelse try self.expression.types.unknownFact(store, pointee);
        if (before.type_term != try self.expression.types.term(pointee)) return error.IncorrectFieldType;
        // The place the write reaches has a declared layer, so a scalar written
        // into a carrier place such as `?T` becomes that carrier's payload.
        const layer = if (steps.len == 0) before else try self.expression.types.projectFieldPath(store, before, steps, self.expression.structs);
        const value = try self.widenToCarrierTerm(store, written_value, layer.type_term);
        const written = try self.expression.types.replaceFieldPath(store, before, steps, value, self.expression.structs);
        var children: std.ArrayListUnmanaged(Child) = .empty;
        defer children.deinit(store.allocator);
        for (root.children) |child| try children.append(store.allocator, .{
            .key = child.key,
            .fact = if (std.meta.eql(child.key, ChildKey{ .ref_target = {} })) written else child.fact,
        });
        if (root.child(.ref_target) == null) try children.append(store.allocator, .{ .key = .{ .ref_target = {} }, .fact = written });
        values[slot] = try store.internFact(root.type_term, root.receiver, children.items);
        for (self.expression.alias_edges) |edge| {
            if (edge.slot != slot) continue;
            const viewed = values[edge.target] orelse continue;
            const origin = try store.join(viewed.receiver, written_value.receiver);
            values[edge.target] = try store.internFact(viewed.type_term, origin, viewed.children);
        }
    }

    /// Detaching a place is a write to the place it consumes: the layer the
    /// value came from keeps its declared type but no longer names an origin,
    /// because that origin moved out with the detached value. The update is
    /// made through the checked projection path of the source binding, so the
    /// parent fact is rebuilt rather than merely cleared at the root.
    fn applyTakeEffects(self: StraightLineFlow, store: *Store, values: []?*const Fact, expr: *const sir.Expr) Error!void {
        switch (expr.*) {
            .take_path_local => |take| {
                const slot = try self.placeSlot(expr, values);
                const root = values[slot] orelse return error.UninitializedBinding;
                var path: std.ArrayListUnmanaged(sir.StructFieldPathStep) = .empty;
                defer path.deinit(store.allocator);
                for (take.steps) |step| {
                    switch (step) {
                        .field => |field| try path.append(store.allocator, field),
                        else => return error.UnsupportedStatement,
                    }
                }
                const layer = try self.expression.types.projectFieldPath(store, root, path.items, self.expression.structs);
                const cleared = try self.expression.types.unknownFact(store, @fromBackingInt(@intCast(@backingInt(layer.type_term))));
                values[slot] = try self.expression.types.replaceFieldPath(store, root, path.items, cleared, self.expression.structs);
            },
            .take_index_local => |take| {
                const slot = try self.placeSlot(expr, values);
                const root = values[slot] orelse return error.UninitializedBinding;
                _ = take;
                try self.clearSequenceItemLayer(store, values, slot, root, &.{});
            },
            .take_index_path_local => |take| {
                const slot = try self.placeSlot(expr, values);
                const root = values[slot] orelse return error.UninitializedBinding;
                var path: std.ArrayListUnmanaged(sir.StructFieldPathStep) = .empty;
                defer path.deinit(store.allocator);
                for (take.steps) |step| {
                    switch (step) {
                        .field => |field| try path.append(store.allocator, field),
                        else => return error.UnsupportedStatement,
                    }
                }
                try self.clearSequenceItemLayer(store, values, slot, root, path.items);
            },
            .sparse_take => |take| {
                // Only a receiver that names a binding slot has a live element
                // layer to clear; a projected container keeps its conservative
                // type fact.
                if (take.object.* != .local) return;
                const slot = try self.placeSlot(take.object, values);
                const root = values[slot] orelse return error.UninitializedBinding;
                try self.clearSequenceItemLayer(store, values, slot, root, &.{});
            },
            else => {},
        }
    }

    /// Sparse and dense containers record one element origin layer, so a detach
    /// from any index conservatively leaves that layer without an origin.
    fn clearSequenceItemLayer(self: StraightLineFlow, store: *Store, values: []?*const Fact, slot: u32, root: *const Fact, prefix: []const sir.StructFieldPathStep) Error!void {
        const container = try self.expression.types.projectFieldPath(store, root, prefix, self.expression.structs);
        const container_type = try self.expression.types.types.get(@fromBackingInt(@intCast(@backingInt(container.type_term))));
        const item_type = switch (container_type.*) {
            .array => |array| array.item,
            .dense_array, .sparse_array => |item| item,
            .slice => |slice| slice.item,
            else => return error.UnsupportedStatement,
        };
        const cleared = try self.expression.types.unknownFact(store, item_type);
        var children: std.ArrayListUnmanaged(Child) = .empty;
        defer children.deinit(store.allocator);
        var recorded = false;
        for (container.children) |child| {
            if (std.meta.eql(child.key, ChildKey{ .sequence_item = {} })) recorded = true;
            try children.append(store.allocator, .{
                .key = child.key,
                .fact = if (std.meta.eql(child.key, ChildKey{ .sequence_item = {} })) cleared else child.fact,
            });
        }
        if (!recorded) try children.append(store.allocator, .{ .key = .{ .sequence_item = {} }, .fact = cleared });
        const updated = try store.internFact(container.type_term, container.receiver, children.items);
        values[slot] = try self.expression.types.replaceFieldPath(store, root, prefix, updated, self.expression.structs);
    }

    /// A checked container mutation keeps the place alive and records the item
    /// origin that entered the slot. Clears and pops leave the element type
    /// unchanged, so only insertions join a new origin into the container.
    fn applyContainerEffects(self: StraightLineFlow, store: *Store, values: []?*const Fact, expr: *const sir.Expr) Error!void {
        const object: *const sir.Expr = switch (expr.*) {
            .sequence_push => |push| push.object,
            .sparse_insert => |insert| insert.object,
            .sequence_pop => |target| target,
            .sequence_clear => |target| target,
            .sparse_clear => |target| target,
            .sparse_take => |take| take.object,
            .sequence_reserve => |reserve| reserve.object,
            else => return,
        };
        // Only a receiver that resolves to a direct binding slot has a live
        // origin to join; projected or temporary containers keep their
        // conservative type fact.
        if (object.* != .local) return;
        // The flow's adapter carries the resolved read map but not the live slot
        // values, so bind them before re-evaluating the inserted value.
        var expression = self.expression;
        expression.binding_values = values;
        var container_slot: ?u32 = null;
        for (self.expression.resolved_reads) |read| {
            if (read.expr != object) continue;
            if (read.slot >= values.len) return error.InvalidBindingSlot;
            container_slot = read.slot;
            break;
        }
        const slot = container_slot orelse return;
        const root = values[slot] orelse return error.UninitializedBinding;
        if (expr.* == .sequence_push or expr.* == .sparse_insert) {
            const item = root.child(.sequence_item) orelse return error.MissingCaptureFact;
            const inserted = try expression.eval(store, if (expr.* == .sequence_push) expr.sequence_push.value else expr.sparse_insert.value);
            if (inserted.type_term != item.type_term) return error.IncorrectBindingType;
            const joined = try store.joinFacts(item, inserted);
            var children: std.ArrayListUnmanaged(Child) = .empty;
            defer children.deinit(store.allocator);
            for (root.children) |child| try children.append(store.allocator, .{ .key = child.key, .fact = if (std.meta.eql(child.key, .sequence_item)) joined else child.fact });
            values[slot] = try store.internFact(root.type_term, root.receiver, children.items);
        } else if (expr.* == .sequence_clear or expr.* == .sparse_clear or expr.* == .sequence_pop) {
            // A clear destroys the elements in place and a pop hands one of them
            // to the expression that reads it, so in both cases the element layer
            // of the container no longer names the origins that left it. Reserve
            // changes capacity only, so the element origin survives it.
            try self.clearSequenceItemLayer(store, values, slot, root, &.{});
        }
        // Every view taken from a mutated container may have moved with it, so
        // no origin recorded inside that view survives the mutation.
        for (self.expression.alias_edges) |edge| {
            if (edge.target != slot) continue;
            const view = values[edge.slot] orelse continue;
            values[edge.slot] = try self.expression.invalidateAliased(store, view);
        }
    }

    fn consumeHandoffs(self: StraightLineFlow, values: []?*const Fact, expr: *const sir.Expr) Error!void {
        switch (expr.*) {
            .handoff_local => {
                for (self.expression.resolved_reads) |read| {
                    if (read.expr != expr) continue;
                    if (read.slot >= values.len) return error.InvalidBindingSlot;
                    if (values[read.slot] == null) return error.UninitializedBinding;
                    values[read.slot] = null;
                    return;
                }
                return error.MissingLocalRead;
            },
            .field, .borrowed_field => |field| try self.consumeHandoffs(values, field.object),
            .tuple_field => |field| try self.consumeHandoffs(values, field.object),
            .union_field, .borrowed_union_field => |field| try self.consumeHandoffs(values, field.object),
            .index, .borrowed_index => |access| {
                try self.consumeHandoffs(values, access.object);
                try self.consumeHandoffs(values, access.index);
            },
            .slice_range => |range| {
                try self.consumeHandoffs(values, range.object);
                if (range.start) |start| try self.consumeHandoffs(values, start);
                if (range.end) |end| try self.consumeHandoffs(values, end);
            },
            .struct_literal, .new_owned => |literal| for (literal.fields) |field| try self.consumeHandoffs(values, field.value),
            .array_literal, .dense_array_literal => |literal| for (literal.items) |item| try self.consumeHandoffs(values, item),
            .tuple_literal => |literal| for (literal.items) |item| try self.consumeHandoffs(values, item),
            .new_array => |array| try self.consumeHandoffs(values, array.len),
            .new_sparse => |array| try self.consumeHandoffs(values, array.capacity),
            .sparse_literal => |literal| for (literal.items) |item| try self.consumeHandoffs(values, item),
            .sparse_keyed_literal => |literal| for (literal.entries) |entry| {
                try self.consumeHandoffs(values, entry.index);
                try self.consumeHandoffs(values, entry.value);
            },
            .cast => |cast| try self.consumeHandoffs(values, cast.subject),
            .@"try" => |attempt| try self.consumeHandoffs(values, attempt.expr),
            .call => |call| for (call.args) |arg| switch (arg) {
                .value => |value| try self.consumeHandoffs(values, value),
            },
            .is_test => |test_expr| try self.consumeHandoffs(values, test_expr.subject),
            .unary => |unary| try self.consumeHandoffs(values, unary.expr),
            .binary => |binary| {
                try self.consumeHandoffs(values, binary.left);
                try self.consumeHandoffs(values, binary.right);
            },
            .test_assert => |condition| try self.consumeHandoffs(values, condition),
            .builtin_print => |print| for (print.parts) |part| switch (part) {
                .literal => {},
                .value => |value| try self.consumeHandoffs(values, value.expr),
            },
            .interpolated_string => |parts| for (parts) |part| switch (part) {
                .literal => {},
                .value => |value| try self.consumeHandoffs(values, value.expr),
            },
            .sequence_len, .sparse_len, .string_len, .string_is_empty, .slice_len, .slice_ptr, .string_from, .string_bytes, .sparse_indices => |object| try self.consumeHandoffs(values, object),
            .sparse_contains_index => |access| {
                try self.consumeHandoffs(values, access.object);
                try self.consumeHandoffs(values, access.index);
            },
            .sequence_push => |push| {
                try self.consumeHandoffs(values, push.object);
                try self.consumeHandoffs(values, push.value);
            },
            .sparse_insert => |insert| {
                try self.consumeHandoffs(values, insert.object);
                try self.consumeHandoffs(values, insert.index);
                try self.consumeHandoffs(values, insert.value);
            },
            .sequence_reserve => |reserve| {
                try self.consumeHandoffs(values, reserve.object);
                try self.consumeHandoffs(values, reserve.capacity);
            },
            .sparse_take => |take| {
                try self.consumeHandoffs(values, take.object);
                try self.consumeHandoffs(values, take.index);
            },
            .sequence_clear, .sparse_clear, .sequence_pop => |object| try self.consumeHandoffs(values, object),
            .string_starts_with, .string_ends_with, .string_contains, .string_find, .string_rfind => |call| {
                try self.consumeHandoffs(values, call.object);
                try self.consumeHandoffs(values, call.value);
            },
            .string_slice => |slice| {
                try self.consumeHandoffs(values, slice.object);
                try self.consumeHandoffs(values, slice.start);
                try self.consumeHandoffs(values, slice.end);
            },
            .ref_load => |source| try self.consumeHandoffs(values, source),
            .ref_field_expr => |field| try self.consumeHandoffs(values, field.object),
            .ref_index_local => |access| try self.consumeHandoffs(values, access.index),
            .ref_path_local, .ref_index_path_local => {
                const steps = if (expr.* == .ref_path_local) expr.ref_path_local.steps else expr.ref_index_path_local.steps;
                for (steps) |step| if (step == .index) try self.consumeHandoffs(values, step.index);
                if (expr.* == .ref_index_path_local) try self.consumeHandoffs(values, expr.ref_index_path_local.index);
            },
            .union_case => |case| if (case.value) |value| try self.consumeHandoffs(values, value),
            .raw_owned_local => {
                // `.ptr()` exposes a non-owning view of an owned place: taking the
                // handle does not move the binding, so the origin the place recorded
                // survives. Only the alias edge it creates is kept, so a later write
                // through the handle refreshes it.
                return;
            },
            .leak_owned_local => {
                // A leak detaches the owned place from its binding, so nothing the
                // binding recorded about it can be trusted afterwards.
                for (self.expression.resolved_reads) |read| {
                    if (read.expr != expr) continue;
                    if (read.slot >= values.len) return error.InvalidBindingSlot;
                    if (values[read.slot] == null) return error.UninitializedBinding;
                    values[read.slot] = null;
                    return;
                }
                return error.MissingLocalRead;
            },
            .closure => |closure| for (closure.captures) |capture| try self.consumeHandoffs(values, capture),
            .thread_spawn_boxed => |spawn| try self.consumeHandoffs(values, spawn.payload),
            .task_group_spawn_boxed => |spawn| {
                try self.consumeHandoffs(values, spawn.group_raw);
                try self.consumeHandoffs(values, spawn.entry);
                try self.consumeHandoffs(values, spawn.payload);
            },
            .task_result_take => |take| {
                try self.consumeHandoffs(values, take.witness);
                try self.consumeHandoffs(values, take.pointer);
            },
            .sync_share_boxed => |share| try self.consumeHandoffs(values, share.payload),
            .asm_expr => |assembly| {
                if (assembly.inout) |inout| try self.consumeHandoffs(values, inout.value);
                for (assembly.inputs) |input| try self.consumeHandoffs(values, input.value);
            },
            .indirect_call => |call| {
                try self.consumeHandoffs(values, call.callee);
                for (call.args) |argument| switch (argument) {
                    .value => |value| try self.consumeHandoffs(values, value),
                };
            },
            .raw_deref, .ref_raw_deref => |deref| try self.consumeHandoffs(values, deref.expr),
            .take_index_local => |take| try self.consumeHandoffs(values, take.index),
            .take_index_path_local => |take| {
                for (take.steps) |step| if (step == .index) try self.consumeHandoffs(values, step.index);
                try self.consumeHandoffs(values, take.index);
            },
            .take_path_local => |take| for (take.steps) |step| if (step == .index) try self.consumeHandoffs(values, step.index),
            else => {},
        }
    }
};

/// Prepare the supported flat SIR body directly from its checked declarations.
/// Source names are used only here, to resolve exact read/write node identities.
pub const PreparedStraightLine = struct {
    const NamedBinding = struct { name: []const u8, id: identity.BindingId, slot: u32 };
    allocator: std.mem.Allocator,
    function: *const sir.Function,
    expression: PureExprAdapter,
    binding_types: []semantic_types.TypeId,
    reads: []PureExprAdapter.ResolvedRead,
    writes: []StraightLineFlow.Write,
    scope_exits: []StraightLineFlow.ScopeExit,
    switch_scopes: []StraightLineFlow.SwitchScope,
    loop_scopes: []StraightLineFlow.LoopScope,
    for_scopes: []StraightLineFlow.ForScope,
    aliases: []PureExprAdapter.AliasEdge,
    initial: []?*const Fact,

    pub const Error = StraightLineFlow.Error || error{ MissingParameterType, MissingBindingId, InvalidParameterFacts, DuplicateBinding, UnknownBinding, IncorrectBindingIdentity, MissingLocalType };

    pub fn init(allocator: std.mem.Allocator, types: TypeAdapter, function: *const sir.Function, metadata: []const sir.ExprMetadataEntry, structs: []const sir.StructDecl, unions: []const sir.UnionDecl, parameter_facts: []const *const Fact) Error!PreparedStraightLine {
        if (parameter_facts.len != function.params.len) return error.InvalidParameterFacts;
        var names: std.ArrayListUnmanaged(NamedBinding) = .empty;
        defer names.deinit(allocator);
        var binding_types: std.ArrayListUnmanaged(semantic_types.TypeId) = .empty;
        defer binding_types.deinit(allocator);
        var reads: std.ArrayListUnmanaged(PureExprAdapter.ResolvedRead) = .empty;
        defer reads.deinit(allocator);
        var writes: std.ArrayListUnmanaged(StraightLineFlow.Write) = .empty;
        defer writes.deinit(allocator);
        var scope_exits: std.ArrayListUnmanaged(StraightLineFlow.ScopeExit) = .empty;
        defer scope_exits.deinit(allocator);
        var switch_scopes: std.ArrayListUnmanaged(StraightLineFlow.SwitchScope) = .empty;
        defer switch_scopes.deinit(allocator);
        errdefer for (switch_scopes.items) |scope| allocator.free(scope.cases);
        var loop_scopes: std.ArrayListUnmanaged(StraightLineFlow.LoopScope) = .empty;
        defer loop_scopes.deinit(allocator);
        var for_scopes: std.ArrayListUnmanaged(StraightLineFlow.ForScope) = .empty;
        defer for_scopes.deinit(allocator);
        var aliases: std.ArrayListUnmanaged(PureExprAdapter.AliasEdge) = .empty;
        defer aliases.deinit(allocator);
        var initial: std.ArrayListUnmanaged(?*const Fact) = .empty;
        defer initial.deinit(allocator);

        for (function.params, parameter_facts) |param, fact| {
            const ty = param.type_id orelse return error.MissingParameterType;
            if (fact.type_term != try types.term(ty)) return error.InvalidParameterFacts;
            try addBinding(allocator, &names, param.name, param.binding_id orelse return error.MissingBindingId, @intCast(binding_types.items.len));
            try binding_types.append(allocator, ty);
            try initial.append(allocator, fact);
        }
        try collectStatements(allocator, function.body, metadata, &names, &binding_types, &reads, &writes, &scope_exits, &switch_scopes, &loop_scopes, &for_scopes, &aliases, &initial);

        const owned_types = try allocator.dupe(semantic_types.TypeId, binding_types.items);
        errdefer allocator.free(owned_types);
        const owned_reads = try allocator.dupe(PureExprAdapter.ResolvedRead, reads.items);
        errdefer allocator.free(owned_reads);
        const owned_writes = try allocator.dupe(StraightLineFlow.Write, writes.items);
        errdefer allocator.free(owned_writes);
        const owned_scopes = try allocator.dupe(StraightLineFlow.ScopeExit, scope_exits.items);
        errdefer allocator.free(owned_scopes);
        const owned_switches = try switch_scopes.toOwnedSlice(allocator);
        errdefer {
            for (owned_switches) |scope| allocator.free(scope.cases);
            allocator.free(owned_switches);
        }
        const owned_loops = try allocator.dupe(StraightLineFlow.LoopScope, loop_scopes.items);
        errdefer allocator.free(owned_loops);
        const owned_fors = try allocator.dupe(StraightLineFlow.ForScope, for_scopes.items);
        errdefer allocator.free(owned_fors);
        const owned_aliases = try allocator.dupe(PureExprAdapter.AliasEdge, aliases.items);
        errdefer allocator.free(owned_aliases);
        const owned_initial = try allocator.dupe(?*const Fact, initial.items);
        return .{
            .allocator = allocator,
            .function = function,
            .expression = .{
                .types = types,
                .metadata = metadata,
                .structs = structs,
                .unions = unions,
                .local_reads = &.{},
                .alias_edges = owned_aliases,
            },
            .binding_types = owned_types,
            .reads = owned_reads,
            .writes = owned_writes,
            .scope_exits = owned_scopes,
            .switch_scopes = owned_switches,
            .loop_scopes = owned_loops,
            .for_scopes = owned_fors,
            .aliases = owned_aliases,
            .initial = owned_initial,
        };
    }

    fn collectStatements(allocator: std.mem.Allocator, statements: []const sir.Stmt, metadata: []const sir.ExprMetadataEntry, names: *std.ArrayListUnmanaged(NamedBinding), binding_types: *std.ArrayListUnmanaged(semantic_types.TypeId), reads: *std.ArrayListUnmanaged(PureExprAdapter.ResolvedRead), writes: *std.ArrayListUnmanaged(StraightLineFlow.Write), scope_exits: *std.ArrayListUnmanaged(StraightLineFlow.ScopeExit), switch_scopes: *std.ArrayListUnmanaged(StraightLineFlow.SwitchScope), loop_scopes: *std.ArrayListUnmanaged(StraightLineFlow.LoopScope), for_scopes: *std.ArrayListUnmanaged(StraightLineFlow.ForScope), aliases: *std.ArrayListUnmanaged(PureExprAdapter.AliasEdge), initial: *std.ArrayListUnmanaged(?*const Fact)) Error!void {
        for (statements) |*stmt| {
            switch (stmt.*) {
                .yield => |maybe_expr| if (maybe_expr) |expr| try collectReads(allocator, reads, metadata, names.items, expr),
                .local => |local| {
                    try collectReads(allocator, reads, metadata, names.items, local.init);
                    const ty = local.type_id orelse metadataType(metadata, local.init) orelse return error.MissingLocalType;
                    const slot: u32 = @intCast(binding_types.items.len);
                    try addBinding(allocator, names, local.name, local.binding_id orelse return error.MissingBindingId, slot);
                    try binding_types.append(allocator, ty);
                    try initial.append(allocator, null);
                    try writes.append(allocator, .{ .stmt = stmt, .slot = slot });
                    try collectAliasEdge(allocator, metadata, names.items, local.init, slot, aliases);
                },
                .assign => |assign| {
                    try collectReads(allocator, reads, metadata, names.items, assign.value);
                    const id = assign.binding_id orelse return error.MissingBindingId;
                    const slot = for (names.items) |binding| {
                        if (binding.id != id) continue;
                        if (!std.mem.eql(u8, binding.name, assign.name)) return error.IncorrectBindingIdentity;
                        break binding.slot;
                    } else return error.UnknownBinding;
                    try writes.append(allocator, .{ .stmt = stmt, .slot = slot });
                    // An existing binding can be re-taken from a different place,
                    // so the view it now names must be recorded as well.
                    try collectAliasEdge(allocator, metadata, names.items, assign.value, slot, aliases);
                },
                .field_assign => |assign| {
                    try collectReads(allocator, reads, metadata, names.items, assign.value);
                    const id = assign.root_binding_id orelse return error.MissingBindingId;
                    const slot = for (names.items) |binding| {
                        if (binding.id != id) continue;
                        if (!std.mem.eql(u8, binding.name, assign.root_name)) return error.IncorrectBindingIdentity;
                        break binding.slot;
                    } else return error.UnknownBinding;
                    try writes.append(allocator, .{ .stmt = stmt, .slot = slot });
                    if (assign.capture) |capture| {
                        const capture_slot: u32 = @intCast(binding_types.items.len);
                        try addBinding(allocator, names, capture.name, capture.binding_id, capture_slot);
                        try binding_types.append(allocator, capture.type_id);
                        try initial.append(allocator, null);
                        try writes.append(allocator, .{ .stmt = stmt, .slot = capture_slot });
                    }
                },
                .index_assign => |assign| {
                    const place = for (metadata) |entry| {
                        if (entry.expr == assign.object) break entry.metadata.checkedPlacePath();
                    } else return error.MissingMetadata;
                    const place_path = place orelse return error.MissingPlaceIdentity;
                    if (place_path.root != .binding) return error.IncorrectBindingIdentity;
                    const slot = if (assign.object.* == .local)
                        try bindingSlot(names.items, place_path.root.binding, assign.object.local)
                    else
                        try bindingSlotById(names.items, place_path.root.binding);
                    try collectReads(allocator, reads, metadata, names.items, assign.object);
                    try collectReads(allocator, reads, metadata, names.items, assign.index);
                    try collectReads(allocator, reads, metadata, names.items, assign.value);
                    try writes.append(allocator, .{ .stmt = stmt, .slot = slot });
                },
                .expr => |expr| try collectReads(allocator, reads, metadata, names.items, expr),
                .@"try" => |attempt| try collectReads(allocator, reads, metadata, names.items, attempt.expr),
                .@"defer" => |expr| try collectReads(allocator, reads, metadata, names.items, expr),
                .drop => |drop| {
                    const id = drop.binding_id orelse return error.MissingBindingId;
                    const slot = try bindingSlot(names.items, id, drop.name);
                    try writes.append(allocator, .{ .stmt = stmt, .slot = slot });
                },
                .unchecked => |body| {
                    const outer_names = names.items.len;
                    const start = binding_types.items.len;
                    try collectStatements(allocator, body, metadata, names, binding_types, reads, writes, scope_exits, switch_scopes, loop_scopes, for_scopes, aliases, initial);
                    const end = binding_types.items.len;
                    names.shrinkRetainingCapacity(outer_names);
                    // The scope's exit edge clears every slot the block declared.
                    try scope_exits.append(allocator, .{ .stmt = stmt, .then_start = start, .then_end = end, .else_start = end, .else_end = end });
                },
                .using_alloc => |scope| {
                    try collectReads(allocator, reads, metadata, names.items, scope.allocator_expr);
                    const outer_names = names.items.len;
                    const start = binding_types.items.len;
                    try collectStatements(allocator, scope.body, metadata, names, binding_types, reads, writes, scope_exits, switch_scopes, loop_scopes, for_scopes, aliases, initial);
                    const end = binding_types.items.len;
                    names.shrinkRetainingCapacity(outer_names);
                    try scope_exits.append(allocator, .{ .stmt = stmt, .then_start = start, .then_end = end, .else_start = end, .else_end = end });
                },
                .asm_stmt => |assembly| for (assembly.inputs) |input| try collectReads(allocator, reads, metadata, names.items, input.value),
                .deref_assign => |assign| {
                    try collectReads(allocator, reads, metadata, names.items, assign.pointer);
                    try collectReads(allocator, reads, metadata, names.items, assign.value);
                },
                .deref_field_assign => |assign| {
                    try collectReads(allocator, reads, metadata, names.items, assign.pointer);
                    try collectReads(allocator, reads, metadata, names.items, assign.value);
                },
                .@"if" => |if_stmt| {
                    try collectReads(allocator, reads, metadata, names.items, if_stmt.condition);
                    const outer_names = names.items.len;
                    const then_start = binding_types.items.len;
                    const capture_slot: ?usize = if (if_stmt.capture_name) |name| blk: {
                        if (if_stmt.kind != .optional_some and if_stmt.kind != .union_case) return error.UnsupportedIfKind;
                        const capture_type = if_stmt.capture_type_id orelse return error.MissingCaptureType;
                        const slot = binding_types.items.len;
                        try addBinding(allocator, names, name, if_stmt.capture_binding_id orelse return error.MissingBindingId, @intCast(slot));
                        try binding_types.append(allocator, capture_type);
                        try initial.append(allocator, null);
                        break :blk slot;
                    } else null;
                    try collectStatements(allocator, if_stmt.then_body, metadata, names, binding_types, reads, writes, scope_exits, switch_scopes, loop_scopes, for_scopes, aliases, initial);
                    const then_end = binding_types.items.len;
                    names.shrinkRetainingCapacity(outer_names);
                    const else_start = binding_types.items.len;
                    try collectStatements(allocator, if_stmt.else_body, metadata, names, binding_types, reads, writes, scope_exits, switch_scopes, loop_scopes, for_scopes, aliases, initial);
                    const else_end = binding_types.items.len;
                    names.shrinkRetainingCapacity(outer_names);
                    try scope_exits.append(allocator, .{ .stmt = stmt, .then_start = then_start, .then_end = then_end, .else_start = else_start, .else_end = else_end, .capture_slot = capture_slot });
                },
                .@"switch" => |branch| {
                    try collectReads(allocator, reads, metadata, names.items, branch.value);
                    const outer_names = names.items.len;
                    const cases = try allocator.alloc(StraightLineFlow.SwitchCaseScope, branch.cases.len);
                    errdefer allocator.free(cases);
                    for (branch.cases, cases) |case, *case_scope| {
                        const start = binding_types.items.len;
                        const capture_slot: ?usize = if (case.payload_name) |name| blk: {
                            const ty = case.payload_type_id orelse return error.MissingCaptureType;
                            const slot = binding_types.items.len;
                            try addBinding(allocator, names, name, case.payload_binding_id orelse return error.MissingBindingId, @intCast(slot));
                            try binding_types.append(allocator, ty);
                            try initial.append(allocator, null);
                            break :blk slot;
                        } else null;
                        try collectStatements(allocator, case.body, metadata, names, binding_types, reads, writes, scope_exits, switch_scopes, loop_scopes, for_scopes, aliases, initial);
                        case_scope.* = .{ .start = start, .end = binding_types.items.len, .capture_slot = capture_slot };
                        names.shrinkRetainingCapacity(outer_names);
                    }
                    const else_start = binding_types.items.len;
                    try collectStatements(allocator, branch.else_body, metadata, names, binding_types, reads, writes, scope_exits, switch_scopes, loop_scopes, for_scopes, aliases, initial);
                    const else_end = binding_types.items.len;
                    names.shrinkRetainingCapacity(outer_names);
                    try switch_scopes.append(allocator, .{ .stmt = stmt, .cases = cases, .else_start = else_start, .else_end = else_end });
                },
                .@"while" => |loop| {
                    try collectReads(allocator, reads, metadata, names.items, loop.condition);
                    const outer_names = names.items.len;
                    const start = binding_types.items.len;
                    try collectStatements(allocator, loop.body, metadata, names, binding_types, reads, writes, scope_exits, switch_scopes, loop_scopes, for_scopes, aliases, initial);
                    const end = binding_types.items.len;
                    names.shrinkRetainingCapacity(outer_names);
                    try loop_scopes.append(allocator, .{ .stmt = stmt, .start = start, .end = end });
                },
                .@"for" => |loop| {
                    try collectReads(allocator, reads, metadata, names.items, loop.iterable);
                    const outer_names = names.items.len;
                    const start = binding_types.items.len;
                    const item_type = loop.item_type_id orelse return error.MissingLocalType;
                    try addBinding(allocator, names, loop.name, loop.binding_id orelse return error.MissingBindingId, @intCast(start));
                    try binding_types.append(allocator, item_type);
                    try initial.append(allocator, null);
                    try collectStatements(allocator, loop.body, metadata, names, binding_types, reads, writes, scope_exits, switch_scopes, loop_scopes, for_scopes, aliases, initial);
                    const end = binding_types.items.len;
                    names.shrinkRetainingCapacity(outer_names);
                    try for_scopes.append(allocator, .{ .stmt = stmt, .start = start, .end = end, .item_slot = start });
                },
                .@"continue", .@"break" => break,
                .@"return" => |maybe_expr| {
                    if (maybe_expr) |expr| try collectReads(allocator, reads, metadata, names.items, expr);
                    break;
                },
            }
        }
    }

    pub fn deinit(self: *PreparedStraightLine) void {
        self.allocator.free(self.binding_types);
        self.allocator.free(self.reads);
        self.allocator.free(self.writes);
        self.allocator.free(self.scope_exits);
        for (self.switch_scopes) |scope| self.allocator.free(scope.cases);
        self.allocator.free(self.switch_scopes);
        self.allocator.free(self.loop_scopes);
        self.allocator.free(self.for_scopes);
        self.allocator.free(self.aliases);
        self.allocator.free(self.initial);
        self.* = undefined;
    }

    pub fn run(self: *const PreparedStraightLine, store: *Store) Error!StraightLineFlow.Result {
        var expression = self.expression;
        expression.resolved_reads = self.reads;
        // The enclosing declaration is already on the call stack, so a call that
        // returns to it is a recursive call summarized by its declared contract.
        if (expression.active_calls.len == 0 and self.function.decl_id != null) {
            const stack = [_]identity.DeclId{self.function.decl_id.?};
            expression.active_calls = &stack;
        }
        return (StraightLineFlow{
            .allocator = self.allocator,
            .expression = expression,
            .binding_types = self.binding_types,
            .writes = self.writes,
            .scope_exits = self.scope_exits,
            .switch_scopes = self.switch_scopes,
            .loop_scopes = self.loop_scopes,
            .for_scopes = self.for_scopes,
            .return_type = self.function.return_type_id,
        }).run(store, self.function.body, self.initial);
    }

    fn addBinding(allocator: std.mem.Allocator, names: *std.ArrayListUnmanaged(NamedBinding), name: []const u8, id: identity.BindingId, slot: u32) Error!void {
        if (findBinding(names.items, name) != null) return error.DuplicateBinding;
        for (names.items) |entry| if (entry.id == id) return error.DuplicateBinding;
        try names.append(allocator, .{ .name = name, .id = id, .slot = slot });
    }

    fn findBinding(names: []const NamedBinding, name: []const u8) ?u32 {
        for (names) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.slot;
        return null;
    }

    /// Resolve a place's owning slot from the checked binding identity. The SIR
    /// name only cross-checks the resolved binding, so a stale name can never
    /// select a different local, and a root naming an undeclared binding is
    /// still reported as an unknown binding.
    fn bindingSlot(names: []const NamedBinding, id: identity.BindingId, name: []const u8) Error!u32 {
        for (names) |entry| {
            if (entry.id != id) continue;
            if (!std.mem.eql(u8, entry.name, name)) return error.IncorrectBindingIdentity;
            return entry.slot;
        }
        if (findBinding(names, name) != null) return error.IncorrectBindingIdentity;
        return error.UnknownBinding;
    }

    /// A projected place names no root spelling, so only the checked identity
    /// selects the owning slot.
    fn bindingSlotById(names: []const NamedBinding, id: identity.BindingId) Error!u32 {
        for (names) |entry| if (entry.id == id) return entry.slot;
        return error.UnknownBinding;
    }

    /// A binding introduced from, or later re-taken as, a non-owning view records
    /// every checked place that view can reach. A call or place write that uses
    /// the view can change any of those places, so their origins are refreshed
    /// rather than trusted.
    fn collectAliasEdge(allocator: std.mem.Allocator, metadata: []const sir.ExprMetadataEntry, names: []const NamedBinding, view_expr: *const sir.Expr, slot: u32, edges: *std.ArrayListUnmanaged(PureExprAdapter.AliasEdge)) Error!void {
        const view_form = switch (view_expr.*) {
            .ref_local, .ref_alias_local, .ref_field_local, .ref_field_owned_local, .ref_index_local, .ref_index_path_local, .ref_path_local, .ref_union_field_local, .ref_owned_local, .raw_owned_local, .leak_owned_local => true,
            else => false,
        };
        if (!view_form) return;
        const place = for (metadata) |entry| {
            if (entry.expr == view_expr) break entry.metadata.checkedPlacePath();
        } else return error.MissingMetadata;
        // A place whose root SIR did not resolve is not a binding alias; the
        // expression's own transfer rule still checks its identity.
        const root = (place orelse return).root;
        if (root != .binding) return;
        const target = try bindingSlotById(names, root.binding);
        if (target == slot) return;
        try edges.append(allocator, .{ .slot = slot, .target = target });
    }

    /// A `take` form addresses a projected place inside a checked binding. The
    /// checked root selects the owning slot; the SIR spelling only cross-checks
    /// that identity, so a stale name can never retarget the detach.
    fn collectTakeBindingRead(allocator: std.mem.Allocator, reads: *std.ArrayListUnmanaged(PureExprAdapter.ResolvedRead), metadata: []const sir.ExprMetadataEntry, names: []const NamedBinding, expr: *const sir.Expr, name: []const u8) Error!void {
        const place = for (metadata) |entry| {
            if (entry.expr == expr) break entry.metadata.checkedPlacePath();
        } else return error.MissingMetadata;
        const root = place orelse return error.MissingPlaceIdentity;
        const id = switch (root.root) {
            .binding => |binding_id| binding_id,
            else => return error.IncorrectBindingIdentity,
        };
        const slot = try bindingSlot(names, id, name);
        try reads.append(allocator, .{ .expr = expr, .slot = slot });
    }

    fn collectReads(allocator: std.mem.Allocator, reads: *std.ArrayListUnmanaged(PureExprAdapter.ResolvedRead), metadata: []const sir.ExprMetadataEntry, names: []const NamedBinding, expr: *const sir.Expr) Error!void {
        switch (expr.*) {
            .@"switch" => |switch_expr| try collectReads(allocator, reads, metadata, names, switch_expr.value),
            .local, .handoff_local, .ref_local, .ref_alias_local, .ref_owned_local => |name| {
                const place = for (metadata) |entry| {
                    if (entry.expr == expr) break entry.metadata.checkedPlacePath() orelse return error.MissingBindingId;
                } else return error.MissingMetadata;
                const id = switch (place.root) {
                    .binding => |binding| binding,
                    else => return error.IncorrectBindingIdentity,
                };
                if (place.projections != null and place.projections.?.len != 0) return error.IncorrectBindingIdentity;
                const slot = try bindingSlot(names, id, name);
                try reads.append(allocator, .{ .expr = expr, .slot = slot });
            },
            .raw_owned_local, .leak_owned_local => |name| {
                // The handle is not a place, but it names the binding whose owned
                // place it exposes, and lowering records that checked root.
                const place = for (metadata) |entry| {
                    if (entry.expr == expr) break entry.metadata.checkedPlacePath() orelse return error.MissingBindingId;
                } else return error.MissingMetadata;
                const id = switch (place.root) {
                    .binding => |binding| binding,
                    else => return error.IncorrectBindingIdentity,
                };
                const slot = try bindingSlot(names, id, name);
                try reads.append(allocator, .{ .expr = expr, .slot = slot });
            },
            .ref_field_local, .ref_field_owned_local => |field| {
                const facts = for (metadata) |entry| {
                    if (entry.expr == expr) break entry.metadata;
                } else return error.MissingMetadata;
                const place = facts.checkedPlacePath() orelse return error.MissingBindingId;
                const id = switch (place.root) {
                    .binding => |binding| binding,
                    else => return error.IncorrectBindingIdentity,
                };
                const steps = place.projections orelse return error.IncorrectFieldOwner;
                if (steps.len != 1 or steps[0].step != .field or field.struct_decl_id == null or
                    steps[0].step.field.owner_decl_id != field.struct_decl_id.? or
                    !std.mem.eql(u8, steps[0].step.field.name, field.field) or
                    steps[0].result_type_id != facts.type_id) return error.IncorrectFieldOwner;
                const slot = try bindingSlot(names, id, field.local_name);
                try reads.append(allocator, .{ .expr = expr, .slot = slot });
            },
            .ref_index_local => |access| {
                const facts = for (metadata) |entry| {
                    if (entry.expr == expr) break entry.metadata;
                } else return error.MissingMetadata;
                const place = facts.checkedPlacePath() orelse return error.MissingBindingId;
                const id = switch (place.root) {
                    .binding => |binding| binding,
                    else => return error.IncorrectBindingIdentity,
                };
                const steps = place.projections orelse return error.IncorrectBindingIdentity;
                if (steps.len != 1 or steps[0].step != .index or steps[0].result_type_id != facts.type_id)
                    return error.IncorrectBindingIdentity;
                const checked = steps[0].step.index;
                const matches = if (access.index.* == .int and access.index.int.value >= 0)
                    checked == .fixed and checked.fixed == access.index.int.value
                else
                    checked == .dynamic and checked.dynamic == access.index;
                if (!matches) return error.IncorrectBindingIdentity;
                const slot = try bindingSlot(names, id, access.local_name);
                try reads.append(allocator, .{ .expr = expr, .slot = slot });
                try collectReads(allocator, reads, metadata, names, access.index);
            },
            .ref_path_local, .ref_index_path_local => {
                const name = if (expr.* == .ref_path_local) expr.ref_path_local.local_name else expr.ref_index_path_local.local_name;
                const steps = if (expr.* == .ref_path_local) expr.ref_path_local.steps else expr.ref_index_path_local.steps;
                const facts = for (metadata) |entry| {
                    if (entry.expr == expr) break entry.metadata;
                } else return error.MissingMetadata;
                const place = facts.checkedPlacePath() orelse return error.MissingBindingId;
                const id = switch (place.root) {
                    .binding => |binding| binding,
                    else => return error.IncorrectBindingIdentity,
                };
                const checked = place.projections orelse return error.IncorrectBindingIdentity;
                if (checked.len != steps.len + @intFromBool(expr.* == .ref_index_path_local) or checked.len == 0 or
                    checked[checked.len - 1].result_type_id != facts.type_id) return error.IncorrectBindingIdentity;
                for (steps, 0..) |step, index| {
                    const projection = checked[index].step;
                    switch (step) {
                        .field => |field| {
                            if (projection != .field or field.struct_decl_id == null or
                                projection.field.owner_decl_id != field.struct_decl_id.? or
                                !std.mem.eql(u8, projection.field.name, field.field)) return error.IncorrectFieldOwner;
                        },
                        .index => |item| {
                            if (projection != .index) return error.IncorrectBindingIdentity;
                            const matches = if (item.* == .int and item.int.value >= 0)
                                projection.index == .fixed and projection.index.fixed == item.int.value
                            else
                                projection.index == .dynamic and projection.index.dynamic == item;
                            if (!matches) return error.IncorrectBindingIdentity;
                        },
                    }
                }
                if (expr.* == .ref_index_path_local) {
                    const item = expr.ref_index_path_local.index;
                    const projection = checked[checked.len - 1].step;
                    if (projection != .index) return error.IncorrectBindingIdentity;
                    const matches = if (item.* == .int and item.int.value >= 0)
                        projection.index == .fixed and projection.index.fixed == item.int.value
                    else
                        projection.index == .dynamic and projection.index.dynamic == item;
                    if (!matches) return error.IncorrectBindingIdentity;
                }
                const slot = try bindingSlot(names, id, name);
                try reads.append(allocator, .{ .expr = expr, .slot = slot });
                for (steps) |step| if (step == .index) try collectReads(allocator, reads, metadata, names, step.index);
                if (expr.* == .ref_index_path_local) try collectReads(allocator, reads, metadata, names, expr.ref_index_path_local.index);
            },
            .ref_union_field_local => |field| {
                const place = for (metadata) |entry| {
                    if (entry.expr == expr) break entry.metadata.checkedPlacePath() orelse return error.MissingBindingId;
                } else return error.MissingMetadata;
                const id = switch (place.root) {
                    .binding => |binding| binding,
                    else => return error.IncorrectBindingIdentity,
                };
                if (place.projections != null and place.projections.?.len != 0) return error.IncorrectBindingIdentity;
                const slot = try bindingSlot(names, id, field.local_name);
                try reads.append(allocator, .{ .expr = expr, .slot = slot });
            },
            .field, .borrowed_field => |field| try collectReads(allocator, reads, metadata, names, field.object),
            .tuple_field => |field| try collectReads(allocator, reads, metadata, names, field.object),
            .union_field, .borrowed_union_field => |field| try collectReads(allocator, reads, metadata, names, field.object),
            .struct_literal, .new_owned => |literal| for (literal.fields) |field| try collectReads(allocator, reads, metadata, names, field.value),
            .array_literal, .dense_array_literal => |literal| for (literal.items) |item| try collectReads(allocator, reads, metadata, names, item),
            .tuple_literal => |literal| for (literal.items) |item| try collectReads(allocator, reads, metadata, names, item),
            .array_default => {},
            .new_array => |array| try collectReads(allocator, reads, metadata, names, array.len),
            .new_sparse => |array| try collectReads(allocator, reads, metadata, names, array.capacity),
            .sparse_literal => |literal| for (literal.items) |item| try collectReads(allocator, reads, metadata, names, item),
            .sparse_keyed_literal => |literal| for (literal.entries) |entry| {
                try collectReads(allocator, reads, metadata, names, entry.index);
                try collectReads(allocator, reads, metadata, names, entry.value);
            },
            .index, .borrowed_index => |access| {
                try collectReads(allocator, reads, metadata, names, access.object);
                try collectReads(allocator, reads, metadata, names, access.index);
            },
            .slice_range => |range| {
                try collectReads(allocator, reads, metadata, names, range.object);
                if (range.start) |start| try collectReads(allocator, reads, metadata, names, start);
                if (range.end) |end| try collectReads(allocator, reads, metadata, names, end);
            },
            .@"try" => |attempt| try collectReads(allocator, reads, metadata, names, attempt.expr),
            .cast => |cast| {
                if (cast.fallible or cast.reinterpret) return error.UnsupportedExpression;
                if (cast.union_case_name == null and cast.target_type_id == null) return error.UnsupportedExpression;
                try collectReads(allocator, reads, metadata, names, cast.subject);
            },
            .call => |call| for (call.args) |arg| switch (arg) {
                .value => |value| try collectReads(allocator, reads, metadata, names, value),
            },
            .is_test => |test_expr| try collectReads(allocator, reads, metadata, names, test_expr.subject),
            .unary => |unary| try collectReads(allocator, reads, metadata, names, unary.expr),
            .binary => |binary| {
                try collectReads(allocator, reads, metadata, names, binary.left);
                try collectReads(allocator, reads, metadata, names, binary.right);
            },
            .test_assert => |condition| try collectReads(allocator, reads, metadata, names, condition),
            .builtin_print => |print| for (print.parts) |part| switch (part) {
                .literal => {},
                .value => |value| try collectReads(allocator, reads, metadata, names, value.expr),
            },
            .interpolated_string => |parts| for (parts) |part| switch (part) {
                .literal => {},
                .value => |value| try collectReads(allocator, reads, metadata, names, value.expr),
            },
            .sequence_len, .sparse_len, .string_len, .string_is_empty, .slice_len, .slice_ptr, .string_from, .string_bytes, .sparse_indices => |object| try collectReads(allocator, reads, metadata, names, object),
            .sparse_contains_index => |access| {
                try collectReads(allocator, reads, metadata, names, access.object);
                try collectReads(allocator, reads, metadata, names, access.index);
            },
            .sequence_push => |push| {
                try collectReads(allocator, reads, metadata, names, push.object);
                try collectReads(allocator, reads, metadata, names, push.value);
            },
            .sparse_insert => |insert| {
                try collectReads(allocator, reads, metadata, names, insert.object);
                try collectReads(allocator, reads, metadata, names, insert.index);
                try collectReads(allocator, reads, metadata, names, insert.value);
            },
            .sequence_reserve => |reserve| {
                try collectReads(allocator, reads, metadata, names, reserve.object);
                try collectReads(allocator, reads, metadata, names, reserve.capacity);
            },
            .sparse_take => |take| {
                try collectReads(allocator, reads, metadata, names, take.object);
                try collectReads(allocator, reads, metadata, names, take.index);
            },
            .sequence_clear, .sparse_clear, .sequence_pop => |object| try collectReads(allocator, reads, metadata, names, object),
            .string_starts_with, .string_ends_with, .string_contains, .string_find, .string_rfind => |call| {
                try collectReads(allocator, reads, metadata, names, call.object);
                try collectReads(allocator, reads, metadata, names, call.value);
            },
            .string_slice => |slice| {
                try collectReads(allocator, reads, metadata, names, slice.object);
                try collectReads(allocator, reads, metadata, names, slice.start);
                try collectReads(allocator, reads, metadata, names, slice.end);
            },
            .ref_load => |source| try collectReads(allocator, reads, metadata, names, source),
            .ref_field_expr => |field| try collectReads(allocator, reads, metadata, names, field.object),
            .union_case => |case| {
                if (case.value) |value| try collectReads(allocator, reads, metadata, names, value);
            },
            .closure => |closure| for (closure.captures) |capture| try collectReads(allocator, reads, metadata, names, capture),
            .thread_spawn_boxed => |spawn| try collectReads(allocator, reads, metadata, names, spawn.payload),
            .task_group_spawn_boxed => |spawn| {
                try collectReads(allocator, reads, metadata, names, spawn.group_raw);
                try collectReads(allocator, reads, metadata, names, spawn.entry);
                try collectReads(allocator, reads, metadata, names, spawn.payload);
            },
            .task_result_take => |take| {
                try collectReads(allocator, reads, metadata, names, take.witness);
                try collectReads(allocator, reads, metadata, names, take.pointer);
            },
            .sync_share_boxed => |share| try collectReads(allocator, reads, metadata, names, share.payload),
            .asm_expr => |assembly| {
                if (assembly.inout) |inout| try collectReads(allocator, reads, metadata, names, inout.value);
                for (assembly.inputs) |input| try collectReads(allocator, reads, metadata, names, input.value);
            },
            .indirect_call => |call| {
                try collectReads(allocator, reads, metadata, names, call.callee);
                for (call.args) |argument| switch (argument) {
                    .value => |value| try collectReads(allocator, reads, metadata, names, value),
                };
            },
            .raw_deref, .ref_raw_deref => |deref| try collectReads(allocator, reads, metadata, names, deref.expr),
            .take_index_local => |take| {
                try collectTakeBindingRead(allocator, reads, metadata, names, expr, take.local_name);
                try collectReads(allocator, reads, metadata, names, take.index);
            },
            .take_index_path_local => |take| {
                try collectTakeBindingRead(allocator, reads, metadata, names, expr, take.local_name);
                for (take.steps) |step| if (step == .index) try collectReads(allocator, reads, metadata, names, step.index);
                try collectReads(allocator, reads, metadata, names, take.index);
            },
            .take_path_local => |take| {
                try collectTakeBindingRead(allocator, reads, metadata, names, expr, take.local_name);
                for (take.steps) |step| if (step == .index) try collectReads(allocator, reads, metadata, names, step.index);
            },
            .failure_detail => |detail| if (detail.index) |index| try collectReads(allocator, reads, metadata, names, index),
            .int, .float, .rune, .string, .bool, .none, .enum_case, .global_ref, .ref_global, .function_ref, .closure_capture => {},
        }
    }

    fn metadataType(metadata: []const sir.ExprMetadataEntry, expr: *const sir.Expr) ?semantic_types.TypeId {
        for (metadata) |entry| if (entry.expr == expr) return entry.metadata.type_id;
        return null;
    }
};

/// Checked body consumer. Sema runs this for every lowered declaration so the
/// body's own checked flow, not an independent source walk, decides whether the
/// declaration settles a result of its declared type.
pub const BodyReport = struct {
    /// The declared type of the value the body's checked flow settles as the
    /// result. Sema compares this against the function's declared return type.
    returned_type: ?semantic_types.TypeId,
    did_return: bool,
    reachable: bool,
    /// Number of generic method uses the checked flow evaluated.
    method_uses: usize,
};

pub const AnalyzeError = PreparedStraightLine.Error || StraightLineFlow.Error;

pub fn analyzeBody(
    allocator: std.mem.Allocator,
    types: TypeAdapter,
    functions: []const sir.Function,
    function: *const sir.Function,
    metadata: []const sir.ExprMetadataEntry,
    structs: []const sir.StructDecl,
    unions: []const sir.UnionDecl,
    method_uses: *std.ArrayListUnmanaged(MethodUse),
) AnalyzeError!BodyReport {
    var store = Store.init(allocator);
    defer store.deinit();
    // A declared `void` result is no value at all, so the flow must not demand
    // a settled value of that type; it treats it as "returns nothing".
    var declared = function.*;
    if (declared.return_type_id) |id| {
        const ty = try types.types.get(id);
        if (ty.* == .primitive and ty.primitive == .void) declared.return_type_id = null;
    }
    var initial: std.ArrayListUnmanaged(*const Fact) = .empty;
    defer initial.deinit(allocator);
    for (declared.params) |param| {
        const ty = param.type_id orelse return error.MissingParameterType;
        try initial.append(allocator, try types.unknownFact(&store, ty));
    }
    var prepared = try PreparedStraightLine.init(allocator, types, &declared, metadata, structs, unions, initial.items);
    defer prepared.deinit();
    prepared.expression.functions = functions;
    prepared.expression.method_uses = method_uses;
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    return .{
        .returned_type = if (result.returned) |value| declaredTypeId(value.type_term) else null,
        .did_return = result.did_return,
        .reachable = result.reachable,
        .method_uses = method_uses.items.len,
    };
}
/// Generic inference binds typed facts after ordinary type constraints are
/// solved. Unbound remains distinct from a bound unresolved receiver.
pub const Slot = union(enum) {
    unbound,
    bound: *const Fact,

    pub fn bind(self: Slot, store: *Store, actual: *const Fact) error{ OutOfMemory, IncompatibleType, IncompatibleChildren }!Slot {
        return switch (self) {
            .unbound => .{ .bound = actual },
            .bound => |previous| .{ .bound = try store.joinFacts(previous, actual) },
        };
    }
};

/// Values are canonical within a store. Temporary join buffers use the backing
/// allocator; repeated fixed-point joins do not grow the arena.
pub const Store = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    values: std.ArrayListUnmanaged(*const Origin) = .empty,
    facts: std.ArrayListUnmanaged(*const Fact) = .empty,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Store) void {
        self.values.deinit(self.allocator);
        self.facts.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn intern(self: *Store, atoms: []const Atom) error{OutOfMemory}!*const Origin {
        if (atoms.len == 0) return &bottom;
        var sorted: std.ArrayListUnmanaged(Atom) = .empty;
        defer sorted.deinit(self.allocator);
        try sorted.appendSlice(self.allocator, atoms);
        std.mem.sort(Atom, sorted.items, {}, atomLessThan);
        var unique_count: usize = 0;
        for (sorted.items) |atom| {
            if (unique_count != 0 and std.meta.eql(sorted.items[unique_count - 1], atom)) continue;
            sorted.items[unique_count] = atom;
            unique_count += 1;
        }
        const canonical = sorted.items[0..unique_count];
        for (self.values.items) |value| {
            if (value.set.len != canonical.len) continue;
            for (value.set, canonical) |existing, candidate| {
                if (!std.meta.eql(existing, candidate)) break;
            } else return value;
        }
        const owned = try self.arena.allocator().dupe(Atom, canonical);
        const value = try self.arena.allocator().create(Origin);
        value.* = .{ .set = owned };
        try self.values.append(self.allocator, value);
        return value;
    }

    pub fn join(self: *Store, a: *const Origin, b: *const Origin) error{OutOfMemory}!*const Origin {
        if (a.* == .unresolved or b.* == .unresolved) return &unresolved;
        if (a.set.len == 0) return self.intern(b.set);
        if (b.set.len == 0) return self.intern(a.set);
        var combined: std.ArrayListUnmanaged(Atom) = .empty;
        defer combined.deinit(self.allocator);
        try combined.appendSlice(self.allocator, a.set);
        try combined.appendSlice(self.allocator, b.set);
        return self.intern(combined.items);
    }

    /// A concrete component needs typed field/element resolution. The caller
    /// must supply that result instead of guessing it from the receiver alone.
    pub fn project(self: *Store, source: *const Origin) error{ OutOfMemory, NeedsTypedProjection }!*const Origin {
        if (source.* == .unresolved) return &unresolved;
        for (source.set) |atom| if (atom == .concrete) return error.NeedsTypedProjection;
        var projected: std.ArrayListUnmanaged(Atom) = .empty;
        defer projected.deinit(self.allocator);
        for (source.set) |atom| try projected.append(self.allocator, switch (atom) {
            .parameter => |id| .{ .projection = id },
            .projection => atom,
            .concrete => unreachable,
        });
        return self.intern(projected.items);
    }

    /// Intern a fact after the type adapter has supplied its complete child
    /// layout. Recursion is represented by TypeTermId, not cyclic Fact pointers.
    pub fn internFact(self: *Store, type_term: TypeTermId, receiver: *const Origin, children: []const Child) error{ OutOfMemory, DuplicateChild }!*const Fact {
        var sorted: std.ArrayListUnmanaged(Child) = .empty;
        defer sorted.deinit(self.allocator);
        try sorted.appendSlice(self.allocator, children);
        std.mem.sort(Child, sorted.items, {}, childLessThan);
        if (sorted.items.len > 1) for (sorted.items[1..], 1..) |child, index| {
            if (std.meta.eql(child.key, sorted.items[index - 1].key)) return error.DuplicateChild;
        };
        const canonical_receiver = if (receiver.* == .unresolved) &unresolved else try self.intern(receiver.set);
        for (self.facts.items) |existing| {
            if (existing.type_term != type_term or existing.receiver != canonical_receiver or existing.children.len != sorted.items.len) continue;
            for (existing.children, sorted.items) |left, right| {
                if (!std.meta.eql(left.key, right.key) or left.fact != right.fact) break;
            } else return existing;
        }
        const owned = try self.arena.allocator().dupe(Child, sorted.items);
        const fact = try self.arena.allocator().create(Fact);
        fact.* = .{ .type_term = type_term, .receiver = canonical_receiver, .children = owned };
        try self.facts.append(self.allocator, fact);
        return fact;
    }

    /// Inactive carrier cases have no reachable payload. Preserve their typed
    /// layout so a later join can recover the active case's nested origins.
    pub fn bottomFact(self: *Store, shape: *const Fact) error{ OutOfMemory, DuplicateChild }!*const Fact {
        var children: std.ArrayListUnmanaged(Child) = .empty;
        defer children.deinit(self.allocator);
        for (shape.children) |child| try children.append(self.allocator, .{ .key = child.key, .fact = try self.bottomFact(child.fact) });
        return self.internFact(shape.type_term, &bottom, children.items);
    }

    pub fn joinFacts(self: *Store, a: *const Fact, b: *const Fact) error{ OutOfMemory, IncompatibleType, IncompatibleChildren }!*const Fact {
        if (a.type_term != b.type_term) return error.IncompatibleType;
        if (a.children.len != b.children.len) return error.IncompatibleChildren;
        var merged: std.ArrayListUnmanaged(Child) = .empty;
        defer merged.deinit(self.allocator);
        for (a.children, b.children) |left, right| {
            if (!std.meta.eql(left.key, right.key)) return error.IncompatibleChildren;
            try merged.append(self.allocator, .{ .key = left.key, .fact = try self.joinFacts(left.fact, right.fact) });
        }
        return self.internFact(a.type_term, try self.join(a.receiver, b.receiver), merged.items) catch |err| switch (err) {
            error.DuplicateChild => unreachable,
            else => |failure| return failure,
        };
    }
};

fn childLessThan(_: void, a: Child, b: Child) bool {
    const a_tag = @backingInt(std.meta.activeTag(a.key));
    const b_tag = @backingInt(std.meta.activeTag(b.key));
    if (a_tag != b_tag) return a_tag < b_tag;
    return switch (a.key) {
        .type_argument => |value| value < b.key.type_argument,
        .field => |value| value < b.key.field,
        .case_payload => |value| value < b.key.case_payload,
        .call_parameter => |value| value < b.key.call_parameter,
        else => false,
    };
}

fn atomLessThan(_: void, a: Atom, b: Atom) bool {
    const a_tag = @backingInt(std.meta.activeTag(a));
    const b_tag = @backingInt(std.meta.activeTag(b));
    if (a_tag != b_tag) return a_tag < b_tag;
    if (a == .concrete) return false;
    const a_id = if (a == .parameter) a.parameter else a.projection;
    const b_id = if (b == .parameter) b.parameter else b.projection;
    if (a_id.scope != b_id.scope) return @backingInt(a_id.scope) < @backingInt(b_id.scope);
    return a_id.ordinal < b_id.ordinal;
}

fn referenceBits(value: *const Origin) ?u3 {
    if (value.* == .unresolved) return null;
    var bits: u3 = 0;
    for (value.set) |atom| bits |= switch (atom) {
        .concrete => 0b001,
        .parameter => 0b010,
        .projection => 0b100,
    };
    return bits;
}

test "inactive carrier payload joins preserve nested active origins" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(1)), .ordinal = 0 } }});
    const leaf = try store.internFact(@fromBackingInt(@intCast(1)), origin, &.{});
    const nested = try store.internFact(@fromBackingInt(@intCast(2)), try store.intern(&.{.concrete}), &.{.{ .key = .{ .field = 0 }, .fact = leaf }});
    const inactive = try store.bottomFact(nested);
    const joined = try store.joinFacts(inactive, nested);
    try std.testing.expectEqual(nested, joined);
    try std.testing.expectEqual(&bottom, inactive.receiver);
    try std.testing.expectEqual(&bottom, (inactive.child(.{ .field = 0 }) orelse return error.TestUnexpectedResult).receiver);
}

test "production origin join matches finite reference lattice" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const id = ParamId{ .scope = @fromBackingInt(@intCast(7)), .ordinal = 0 };
    const atoms = [_]Atom{ .concrete, .{ .parameter = id }, .{ .projection = id } };
    var facts: [9]*const Origin = undefined;
    for (0..8) |bits| {
        var selected: [3]Atom = undefined;
        var count: usize = 0;
        for (atoms, 0..) |atom, bit| {
            if (bits & (@as(usize, 1) << @intCast(bit)) == 0) continue;
            selected[count] = atom;
            count += 1;
        }
        facts[bits] = try store.intern(selected[0..count]);
    }
    facts[8] = &unresolved;
    for (facts, 0..) |a, i| {
        try std.testing.expectEqual(a, try store.join(a, a));
        for (facts, 0..) |b, j| {
            const joined = try store.join(a, b);
            try std.testing.expectEqual(joined, try store.join(b, a));
            try std.testing.expect(a.leq(joined));
            try std.testing.expect(b.leq(joined));
            const expected: ?u3 = if (i == 8 or j == 8) null else @as(u3, @intCast(i | j));
            try std.testing.expectEqual(expected, referenceBits(joined));
            for (facts) |c| {
                try std.testing.expectEqual(try store.join(joined, c), try store.join(a, try store.join(b, c)));
                try std.testing.expect((try store.join(a, c)).leq(try store.join(joined, c)));
            }
        }
    }
}

test "inference slots preserve uncertainty and projection needs typed concrete result" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const a_id = ParamId{ .scope = @fromBackingInt(@intCast(1)), .ordinal = 0 };
    const b_id = ParamId{ .scope = @fromBackingInt(@intCast(2)), .ordinal = 0 };
    const a = try store.intern(&.{.{ .parameter = a_id }});
    const b = try store.intern(&.{.{ .parameter = b_id }});
    const slot: OriginSlot = .unbound;
    try std.testing.expectEqual(try store.join(a, b), (try (try slot.bind(&store, a)).bind(&store, b)).bound);
    try std.testing.expectEqual(try store.join(a, b), (try (try slot.bind(&store, b)).bind(&store, a)).bound);
    try std.testing.expectEqual(&unresolved, (try (try slot.bind(&store, &unresolved)).bind(&store, a)).bound);
    try std.testing.expectEqual(&unresolved, (try (try slot.bind(&store, a)).bind(&store, &unresolved)).bound);
    const projected_a = try store.project(a);
    try std.testing.expectEqual(try store.intern(&.{.{ .projection = a_id }}), projected_a);
    try std.testing.expectEqual(projected_a, try store.project(projected_a));
    try std.testing.expectEqual(&unresolved, try store.project(&unresolved));
    try std.testing.expectError(error.NeedsTypedProjection, store.project(try store.intern(&.{ .concrete, .{ .parameter = a_id } })));
}

test "typed nominal receiver does not inherit its generic field authority" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const box_type: TypeTermId = @fromBackingInt(@intCast(1));
    const item_type: TypeTermId = @fromBackingInt(@intCast(2));
    const a_id = ParamId{ .scope = @fromBackingInt(@intCast(1)), .ordinal = 0 };
    const b_id = ParamId{ .scope = @fromBackingInt(@intCast(2)), .ordinal = 0 };
    const concrete = try store.intern(&.{.concrete});
    const a = try store.intern(&.{.{ .parameter = a_id }});
    const b = try store.intern(&.{.{ .parameter = b_id }});
    const a_item = try store.internFact(item_type, a, &.{});
    const b_item = try store.internFact(item_type, b, &.{});
    const a_box = try store.internFact(box_type, concrete, &.{.{ .key = .{ .field = 0 }, .fact = a_item }});
    const b_box = try store.internFact(box_type, concrete, &.{.{ .key = .{ .field = 0 }, .fact = b_item }});
    const joined = try store.joinFacts(a_box, b_box);
    try std.testing.expectEqual(concrete, joined.receiver);
    try std.testing.expectEqual(try store.join(a, b), joined.child(.{ .field = 0 }).?.receiver);
    try std.testing.expectEqual(joined, try store.joinFacts(b_box, a_box));
    try std.testing.expectEqual(joined, (try (try (Slot{ .unbound = {} }).bind(&store, a_box)).bind(&store, b_box)).bound);
    try std.testing.expectEqual(&unresolved, (try (try (Slot{ .unbound = {} }).bind(&store, try store.internFact(item_type, &unresolved, &.{}))).bind(&store, a_item)).bound.receiver);
    try std.testing.expectError(error.IncompatibleType, store.joinFacts(a_box, a_item));
    try std.testing.expectError(error.IncompatibleChildren, store.joinFacts(a_box, try store.internFact(box_type, concrete, &.{})));
    try std.testing.expectError(error.DuplicateChild, store.internFact(box_type, concrete, &.{
        .{ .key = .{ .field = 0 }, .fact = a_item },
        .{ .key = .{ .field = 0 }, .fact = b_item },
    }));
}

test "checked canonical types supply fact terms and structural children" {
    const allocator = std.testing.allocator;
    var types = semantic_types.TypeInterner.init(allocator);
    defer types.deinit();
    var store = Store.init(allocator);
    defer store.deinit();
    const item = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const option = try types.intern(.{ .optional = item });
    const instance = try types.intern(.{ .generic_instance = .{ .kind = .@"struct", .base_decl_id = @fromBackingInt(@intCast(4)), .args = &.{ .{ .type = option }, .{ .const_usize = 8 } } } });
    const callable = try types.intern(.{ .callable = .{ .kind = .function, .calling_convention = .cyna, .params = &.{option}, .return_type = item } });
    const adapter = TypeAdapter{ .types = &types };
    const fact = try adapter.unknownFact(&store, callable);
    try std.testing.expectEqual(try adapter.term(callable), fact.type_term);
    try std.testing.expectEqual(try adapter.term(option), fact.child(.{ .call_parameter = 0 }).?.type_term);
    try std.testing.expectEqual(try adapter.term(item), fact.child(.{ .call_parameter = 0 }).?.child(.optional_item).?.type_term);
    try std.testing.expectEqual(try adapter.term(item), fact.child(.call_result).?.type_term);
    try std.testing.expectEqual(&unresolved, fact.receiver);
    try std.testing.expectEqual(fact, try adapter.unknownFact(&store, callable));
    const instance_fact = try adapter.unknownFact(&store, instance);
    try std.testing.expectEqual(try adapter.term(option), instance_fact.child(.{ .type_argument = 0 }).?.type_term);
    try std.testing.expect(instance_fact.child(.{ .type_argument = 1 }) == null);
    try std.testing.expect(instance_fact.child(.{ .field = 0 }) == null);
    const fields = [_]sir.FieldDecl{.{ .name = "value", .type_id = option }};
    const structs = [_]sir.StructDecl{.{ .decl_id = @fromBackingInt(@intCast(7)), .name = "Box", .layout = .normal, .fields = &fields }};
    const concrete_instance = try types.intern(.{ .generic_instance = .{ .kind = .@"struct", .base_decl_id = @fromBackingInt(@intCast(4)), .decl_id = @fromBackingInt(@intCast(7)), .args = &.{.{ .type = item }} } });
    const nominal_fact = try adapter.nominalFact(&store, concrete_instance, &structs);
    try std.testing.expectEqual(try adapter.term(option), nominal_fact.child(.{ .field = 0 }).?.type_term);
    try std.testing.expect(nominal_fact.child(.{ .type_argument = 0 }) == null);
    var object: sir.Expr = .none;
    const access = sir.FieldAccess{ .object = &object, .struct_decl_id = @fromBackingInt(@intCast(7)), .struct_name = "Box", .field = "value" };
    try std.testing.expectEqual(nominal_fact.child(.{ .field = 0 }).?, try adapter.projectField(nominal_fact, access, &structs));
    const parameter_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(3)), .ordinal = 0 } }});
    const field_fact = try store.internFact(try adapter.term(option), parameter_origin, nominal_fact.child(.{ .field = 0 }).?.children);
    const source_fact = try store.internFact(try adapter.term(concrete_instance), try store.intern(&.{.concrete}), &.{.{ .key = .{ .field = 0 }, .fact = field_fact }});
    try std.testing.expectEqual(parameter_origin, (try adapter.projectField(source_fact, access, &structs)).receiver);
    const wrong_field_fact = try store.internFact(try adapter.term(item), parameter_origin, &.{});
    const wrong_source_fact = try store.internFact(try adapter.term(concrete_instance), &unresolved, &.{.{ .key = .{ .field = 0 }, .fact = wrong_field_fact }});
    try std.testing.expectError(error.IncorrectFieldType, adapter.projectField(wrong_source_fact, access, &structs));
    var wrong_owner = access;
    wrong_owner.struct_decl_id = @fromBackingInt(@intCast(8));
    try std.testing.expectError(error.IncorrectFieldOwner, adapter.projectField(nominal_fact, wrong_owner, &structs));
    var missing_field = access;
    missing_field.field = "absent";
    try std.testing.expectError(error.MissingField, adapter.projectField(nominal_fact, missing_field, &structs));
    try std.testing.expectError(error.MissingNominalLayout, adapter.nominalFact(&store, instance, &structs));
    const incomplete = [_]sir.StructDecl{.{ .decl_id = @fromBackingInt(@intCast(7)), .name = "Box", .layout = .normal, .fields = &.{.{ .name = "value" }} }};
    try std.testing.expectError(error.MissingFieldType, adapter.nominalFact(&store, concrete_instance, &incomplete));
    try std.testing.expectError(error.InvalidTypeId, adapter.term(@fromBackingInt(@intCast(999))));
}

test "checked union case payload keeps its origin and owner identity" {
    const allocator = std.testing.allocator;
    var types = semantic_types.TypeInterner.init(allocator);
    defer types.deinit();
    var store = Store.init(allocator);
    defer store.deinit();
    const item = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const union_type = try types.intern(.{ .nominal = .{ .kind = .@"union", .decl_id = @fromBackingInt(@intCast(12)) } });
    const cases = [_]sir.UnionField{
        .{ .name = "Empty", .has_payload = false },
        .{ .name = "Value", .has_payload = true, .type_id = item },
    };
    const unions = [_]sir.UnionDecl{.{ .decl_id = @fromBackingInt(@intCast(12)), .name = "Choice", .layout = .normal, .fields = &cases }};
    const adapter = TypeAdapter{ .types = &types };
    const skeleton = try adapter.unionFact(&store, union_type, &unions);
    try std.testing.expect(skeleton.child(.{ .case_payload = 0 }) == null);
    try std.testing.expectEqual(try adapter.term(item), skeleton.child(.{ .case_payload = 1 }).?.type_term);
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(3)), .ordinal = 0 } }});
    const payload = try store.internFact(try adapter.term(item), origin, &.{});
    const fact = try store.internFact(try adapter.term(union_type), try store.intern(&.{.concrete}), &.{.{ .key = .{ .case_payload = 1 }, .fact = payload }});
    var subject: sir.Expr = .none;
    const cast = sir.CastExpr{ .subject = &subject, .source_union_decl_id = @fromBackingInt(@intCast(12)), .target_type_id = item, .union_case_name = "Value", .fallible = false, .reinterpret = false };
    try std.testing.expectEqual(origin, (try adapter.projectCasePayload(fact, cast, &unions)).receiver);
    const wrong_payload_fact = try store.internFact(try adapter.term(union_type), origin, &.{});
    const wrong_union_fact = try store.internFact(try adapter.term(union_type), &unresolved, &.{.{ .key = .{ .case_payload = 1 }, .fact = wrong_payload_fact }});
    try std.testing.expectError(error.IncorrectPayloadFactType, adapter.projectCasePayload(wrong_union_fact, cast, &unions));
    var wrong_owner = cast;
    wrong_owner.source_union_decl_id = @fromBackingInt(@intCast(13));
    try std.testing.expectError(error.IncorrectCaseOwner, adapter.projectCasePayload(fact, wrong_owner, &unions));
    var wrong_type = cast;
    wrong_type.target_type_id = union_type;
    try std.testing.expectError(error.IncorrectPayloadType, adapter.projectCasePayload(fact, wrong_type, &unions));
    var empty_case = cast;
    empty_case.union_case_name = "Empty";
    try std.testing.expectError(error.MissingPayload, adapter.projectCasePayload(fact, empty_case, &unions));
}

test "pure typed expression transfer uses expression identity and checked field result" {
    const allocator = std.testing.allocator;
    var types = semantic_types.TypeInterner.init(allocator);
    defer types.deinit();
    var store = Store.init(allocator);
    defer store.deinit();
    const item = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const box = try types.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = @fromBackingInt(@intCast(21)) } });
    const fields = [_]sir.FieldDecl{.{ .name = "value", .type_id = item }};
    const structs = [_]sir.StructDecl{.{ .decl_id = @fromBackingInt(@intCast(21)), .name = "Box", .layout = .normal, .fields = &fields }};
    const adapter = TypeAdapter{ .types = &types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(5)), .ordinal = 0 } }});
    const item_fact = try store.internFact(try adapter.term(item), origin, &.{});
    const box_fact = try store.internFact(try adapter.term(box), try store.intern(&.{.concrete}), &.{.{ .key = .{ .field = 0 }, .fact = item_fact }});
    var first_local: sir.Expr = .{ .local = "box" };
    var shadowed_local: sir.Expr = .{ .local = "box" };
    var field_expr: sir.Expr = .{ .field = .{ .object = &first_local, .struct_decl_id = @fromBackingInt(@intCast(21)), .struct_name = "Box", .field = "value" } };
    const metadata = [_]sir.ExprMetadataEntry{
        .{ .expr = &first_local, .metadata = .{ .type_id = box, .semantics = sir.ValueSemantics.plainValue() } },
        .{ .expr = &shadowed_local, .metadata = .{ .type_id = box, .semantics = sir.ValueSemantics.plainValue() } },
        .{ .expr = &field_expr, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.plainValue() } },
    };
    const reads = [_]PureExprAdapter.LocalRead{.{ .expr = &first_local, .fact = box_fact }};
    const pure = PureExprAdapter{ .types = adapter, .metadata = &metadata, .structs = &structs, .local_reads = &reads };
    try std.testing.expectEqual(origin, (try pure.eval(&store, &field_expr)).receiver);
    try std.testing.expectError(error.MissingLocalRead, pure.eval(&store, &shadowed_local));
    const bool_type = try types.intern(.{ .primitive = .bool });
    var literal: sir.Expr = .{ .bool = true };
    const literal_metadata = [_]sir.ExprMetadataEntry{.{ .expr = &literal, .metadata = .{ .type_id = bool_type, .semantics = sir.ValueSemantics.plainValue() } }};
    const literal_adapter = PureExprAdapter{ .types = adapter, .metadata = &literal_metadata, .structs = &structs, .local_reads = &.{} };
    const literal_fact = try literal_adapter.eval(&store, &literal);
    try std.testing.expectEqual(try store.intern(&.{.concrete}), literal_fact.receiver);
    try std.testing.expectError(error.MissingMetadata, literal_adapter.eval(&store, &shadowed_local));
    var wrong_metadata = metadata;
    wrong_metadata[2].metadata.type_id = box;
    try std.testing.expectError(error.IncorrectResultType, (PureExprAdapter{ .types = adapter, .metadata = &wrong_metadata, .structs = &structs, .local_reads = &reads }).eval(&store, &field_expr));
    var unsupported: sir.Expr = .{ .ref_local = "box" };
    const unsupported_metadata = [_]sir.ExprMetadataEntry{.{ .expr = &unsupported, .metadata = .{ .type_id = box, .semantics = sir.ValueSemantics.plainValue() } }};
    try std.testing.expectError(error.MissingLocalRead, (PureExprAdapter{ .types = adapter, .metadata = &unsupported_metadata, .structs = &structs, .local_reads = &reads }).eval(&store, &unsupported));
}

test "borrowed projections retain checked generic origins" {
    const allocator = std.testing.allocator;
    var types = semantic_types.TypeInterner.init(allocator);
    defer types.deinit();
    var store = Store.init(allocator);
    defer store.deinit();
    const item = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const box_decl: identity.DeclId = @fromBackingInt(@intCast(171));
    const box = try types.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = box_decl } });
    const array = try types.intern(.{ .array = .{ .len = 2, .item = item } });
    const adapter = TypeAdapter{ .types = &types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(17)), .ordinal = 0 } }});
    const item_fact = try store.internFact(try adapter.term(item), origin, &.{});
    const box_fact = try store.internFact(try adapter.term(box), try store.intern(&.{.concrete}), &.{.{ .key = .{ .field = 0 }, .fact = item_fact }});
    const array_fact = try store.internFact(try adapter.term(array), try store.intern(&.{.concrete}), &.{.{ .key = .sequence_item, .fact = item_fact }});
    const fields = [_]sir.FieldDecl{.{ .name = "value", .type_id = item }};
    const structs = [_]sir.StructDecl{.{ .decl_id = box_decl, .name = "Box", .layout = .normal, .fields = &fields }};
    var box_read: sir.Expr = .{ .local = "box" };
    var field_read: sir.Expr = .{ .borrowed_field = .{ .object = &box_read, .struct_decl_id = box_decl, .struct_name = "Box", .field = "value" } };
    var array_read: sir.Expr = .{ .local = "array" };
    var index: sir.Expr = .{ .int = .{ .value = 0, .type_name = null } };
    var element_read: sir.Expr = .{ .borrowed_index = .{ .object = &array_read, .index = &index } };
    const metadata = [_]sir.ExprMetadataEntry{
        .{ .expr = &box_read, .metadata = .{ .type_id = box, .semantics = sir.ValueSemantics.plainValue() } },
        .{ .expr = &field_read, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.borrowedProjection() } },
        .{ .expr = &array_read, .metadata = .{ .type_id = array, .semantics = sir.ValueSemantics.plainValue() } },
        .{ .expr = &index, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.plainValue() } },
        .{ .expr = &element_read, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.borrowedProjection() } },
    };
    const reads = [_]PureExprAdapter.LocalRead{ .{ .expr = &box_read, .fact = box_fact }, .{ .expr = &array_read, .fact = array_fact } };
    const pure = PureExprAdapter{ .types = adapter, .metadata = &metadata, .structs = &structs, .local_reads = &reads };
    try std.testing.expectEqual(origin, (try pure.eval(&store, &field_read)).receiver);
    try std.testing.expectEqual(origin, (try pure.eval(&store, &element_read)).receiver);
}

test "checked reference load projects the target origin" {
    const allocator = std.testing.allocator;
    var types = semantic_types.TypeInterner.init(allocator);
    defer types.deinit();
    var store = Store.init(allocator);
    defer store.deinit();
    const item = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const reference = try types.intern(.{ .ref_ = .{ .target = item, .is_const = true } });
    const adapter = TypeAdapter{ .types = &types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(18)), .ordinal = 0 } }});
    const item_fact = try store.internFact(try adapter.term(item), origin, &.{});
    const reference_fact = try store.internFact(try adapter.term(reference), try store.intern(&.{.concrete}), &.{.{ .key = .ref_target, .fact = item_fact }});
    var source: sir.Expr = .{ .local = "alias" };
    var loaded: sir.Expr = .{ .ref_load = &source };
    const metadata = [_]sir.ExprMetadataEntry{
        .{ .expr = &source, .metadata = .{ .type_id = reference, .semantics = sir.ValueSemantics.plainValue() } },
        .{ .expr = &loaded, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.plainValue() } },
    };
    const reads = [_]PureExprAdapter.LocalRead{.{ .expr = &source, .fact = reference_fact }};
    const pure = PureExprAdapter{ .types = adapter, .metadata = &metadata, .structs = &.{}, .local_reads = &reads };
    try std.testing.expectEqual(origin, (try pure.eval(&store, &loaded)).receiver);
    var wrong_metadata = metadata;
    wrong_metadata[1].metadata.type_id = reference;
    try std.testing.expectError(error.IncorrectResultType, (PureExprAdapter{ .types = adapter, .metadata = &wrong_metadata, .structs = &.{}, .local_reads = &reads }).eval(&store, &loaded));
}

test "checked local reference construction and load preserve source origin" {
    const allocator = std.testing.allocator;
    var types = semantic_types.TypeInterner.init(allocator);
    defer types.deinit();
    var store = Store.init(allocator);
    defer store.deinit();
    const item = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const reference = try types.intern(.{ .ref_ = .{ .target = item, .is_const = true } });
    const adapter = TypeAdapter{ .types = &types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(19)), .ordinal = 0 } }});
    const source_fact = try store.internFact(try adapter.term(item), origin, &.{});
    const source_id: identity.BindingId = @fromBackingInt(@intCast(191));
    const alias_id: identity.BindingId = @fromBackingInt(@intCast(192));
    var borrow: sir.Expr = .{ .ref_local = "source" };
    var alias_read: sir.Expr = .{ .local = "alias" };
    var loaded: sir.Expr = .{ .ref_load = &alias_read };
    const statements = [_]sir.Stmt{
        .{ .local = .{ .name = "alias", .type_id = reference, .binding_id = alias_id, .init = &borrow } },
        .{ .@"return" = &loaded },
    };
    const params = [_]sir.Param{.{ .name = "source", .type_id = item, .binding_id = source_id }};
    const function = sir.Function{ .owner = null, .name = "read_alias", .params = &params, .return_type_id = item, .body = &statements };
    const metadata = [_]sir.ExprMetadataEntry{
        .{ .expr = &borrow, .metadata = .{ .type_id = reference, .semantics = sir.ValueSemantics.plainValue(), .checked_place_root = .{ .binding = source_id }, .non_owning_place_origin = true } },
        .{ .expr = &alias_read, .metadata = .{ .type_id = reference, .semantics = sir.ValueSemantics.plainValue(), .checked_place_root = .{ .binding = alias_id } } },
        .{ .expr = &loaded, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.plainValue() } },
    };
    var prepared = try PreparedStraightLine.init(allocator, adapter, &function, &metadata, &.{}, &.{}, &.{source_fact});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expectEqual(origin, result.returned.?.receiver);
    try std.testing.expectEqual(source_fact, result.values[0].?);
    var forged = metadata;
    forged[0].metadata.checked_place_root = .{ .binding = alias_id };
    try std.testing.expectError(error.IncorrectBindingIdentity, PreparedStraightLine.init(allocator, adapter, &function, &forged, &.{}, &.{}, &.{source_fact}));
}

test "checked struct field references preserve field origin" {
    const allocator = std.testing.allocator;
    var types = semantic_types.TypeInterner.init(allocator);
    defer types.deinit();
    var store = Store.init(allocator);
    defer store.deinit();
    const item = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const box_decl: identity.DeclId = @fromBackingInt(@intCast(201));
    const box = try types.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = box_decl } });
    const owned_box = try types.intern(.{ .owned = box });
    const reference = try types.intern(.{ .ref_ = .{ .target = item, .is_const = true } });
    const adapter = TypeAdapter{ .types = &types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(20)), .ordinal = 0 } }});
    const item_fact = try store.internFact(try adapter.term(item), origin, &.{});
    const box_fact = try store.internFact(try adapter.term(box), try store.intern(&.{.concrete}), &.{.{ .key = .{ .field = 0 }, .fact = item_fact }});
    const owned_fact = try store.internFact(try adapter.term(owned_box), try store.intern(&.{.concrete}), &.{.{ .key = .owned_target, .fact = box_fact }});
    const fields = [_]sir.FieldDecl{.{ .name = "value", .type_id = item }};
    const structs = [_]sir.StructDecl{.{ .decl_id = box_decl, .name = "Box", .layout = .normal, .fields = &fields }};
    var borrowed: sir.Expr = .{ .ref_field_local = .{ .local_name = "box", .struct_decl_id = box_decl, .struct_name = "Box", .field = "value" } };
    var owned_borrowed: sir.Expr = .{ .ref_field_owned_local = .{ .local_name = "owned_box", .struct_decl_id = box_decl, .struct_name = "Box", .field = "value" } };
    const field_projection = [_]sir.CheckedPlaceProjection{.{
        .step = .{ .field = .{ .owner_decl_id = box_decl, .name = "value" } },
        .result_type_id = reference,
    }};
    const metadata = [_]sir.ExprMetadataEntry{
        .{ .expr = &borrowed, .metadata = .{ .type_id = reference, .semantics = sir.ValueSemantics.plainValue(), .checked_place_root = .{ .binding = @fromBackingInt(@intCast(202)) }, .checked_place_projections = &field_projection, .non_owning_place_origin = true } },
        .{ .expr = &owned_borrowed, .metadata = .{ .type_id = reference, .semantics = sir.ValueSemantics.plainValue(), .checked_place_root = .{ .binding = @fromBackingInt(@intCast(203)) }, .checked_place_projections = &field_projection, .non_owning_place_origin = true } },
    };
    const reads = [_]PureExprAdapter.LocalRead{ .{ .expr = &borrowed, .fact = box_fact }, .{ .expr = &owned_borrowed, .fact = owned_fact } };
    const pure = PureExprAdapter{ .types = adapter, .metadata = &metadata, .structs = &structs, .local_reads = &reads };
    try std.testing.expectEqual(origin, (try pure.eval(&store, &borrowed)).child(.ref_target).?.receiver);
    try std.testing.expectEqual(origin, (try pure.eval(&store, &owned_borrowed)).child(.ref_target).?.receiver);
    owned_borrowed.ref_field_owned_local.struct_decl_id = @fromBackingInt(@intCast(204));
    try std.testing.expectError(error.IncorrectFieldOwner, pure.eval(&store, &owned_borrowed));

    const params = [_]sir.Param{.{ .name = "box", .type_id = box, .binding_id = @fromBackingInt(@intCast(202)) }};
    const statements = [_]sir.Stmt{.{ .expr = &borrowed }};
    const function = sir.Function{ .owner = null, .name = "borrow_field", .params = &params, .body = &statements };
    var prepared = try PreparedStraightLine.init(allocator, adapter, &function, metadata[0..1], &structs, &.{}, &.{box_fact});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expectEqual(box_fact, result.values[0].?);
    var forged = metadata;
    forged[0].metadata.checked_place_root = .{ .binding = @fromBackingInt(@intCast(203)) };
    try std.testing.expectError(error.IncorrectBindingIdentity, PreparedStraightLine.init(allocator, adapter, &function, forged[0..1], &structs, &.{}, &.{box_fact}));
}

test "checked indexed local reference preserves element origin" {
    const allocator = std.testing.allocator;
    var types = semantic_types.TypeInterner.init(allocator);
    defer types.deinit();
    var store = Store.init(allocator);
    defer store.deinit();
    const item = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const array = try types.intern(.{ .array = .{ .len = 2, .item = item } });
    const reference = try types.intern(.{ .ref_ = .{ .target = item, .is_const = true } });
    const adapter = TypeAdapter{ .types = &types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(21)), .ordinal = 0 } }});
    const item_fact = try store.internFact(try adapter.term(item), origin, &.{});
    const array_fact = try store.internFact(try adapter.term(array), try store.intern(&.{.concrete}), &.{.{ .key = .sequence_item, .fact = item_fact }});
    const root_id: identity.BindingId = @fromBackingInt(@intCast(211));
    var index: sir.Expr = .{ .int = .{ .value = 0, .type_name = null } };
    var alias: sir.Expr = .{ .ref_index_local = .{ .local_name = "items", .index = &index } };
    const index_projection = [_]sir.CheckedPlaceProjection{.{
        .step = .{ .index = .{ .fixed = 0 } },
        .result_type_id = reference,
    }};
    const statements = [_]sir.Stmt{.{ .expr = &alias }};
    const params = [_]sir.Param{.{ .name = "items", .type_id = array, .binding_id = root_id }};
    const function = sir.Function{ .owner = null, .name = "borrow_item", .params = &params, .body = &statements };
    const metadata = [_]sir.ExprMetadataEntry{
        .{ .expr = &index, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.plainValue() } },
        .{ .expr = &alias, .metadata = .{ .type_id = reference, .semantics = sir.ValueSemantics.plainValue(), .checked_place_root = .{ .binding = root_id }, .checked_place_projections = &index_projection, .non_owning_place_origin = true } },
    };
    var prepared = try PreparedStraightLine.init(allocator, adapter, &function, &metadata, &.{}, &.{}, &.{array_fact});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expectEqual(array_fact, result.values[0].?);
    const reads = [_]PureExprAdapter.LocalRead{.{ .expr = &alias, .fact = array_fact }};
    const pure = PureExprAdapter{ .types = adapter, .metadata = &metadata, .structs = &.{}, .local_reads = &reads };
    try std.testing.expectEqual(origin, (try pure.eval(&store, &alias)).child(.ref_target).?.receiver);
    var forged = metadata;
    forged[1].metadata.checked_place_root = .{ .binding = @fromBackingInt(@intCast(212)) };
    try std.testing.expectError(error.IncorrectBindingIdentity, PreparedStraightLine.init(allocator, adapter, &function, &forged, &.{}, &.{}, &.{array_fact}));
}

test "checked nested reference paths project declared fields and indices" {
    const allocator = std.testing.allocator;
    var types = semantic_types.TypeInterner.init(allocator);
    defer types.deinit();
    var store = Store.init(allocator);
    defer store.deinit();
    const item = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const box_decl: identity.DeclId = @fromBackingInt(@intCast(221));
    const outer_decl: identity.DeclId = @fromBackingInt(@intCast(222));
    const box = try types.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = box_decl } });
    const array = try types.intern(.{ .array = .{ .len = 2, .item = item } });
    const outer = try types.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = outer_decl } });
    const reference = try types.intern(.{ .ref_ = .{ .target = item, .is_const = true } });
    const adapter = TypeAdapter{ .types = &types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(22)), .ordinal = 0 } }});
    const item_fact = try store.internFact(try adapter.term(item), origin, &.{});
    const box_fact = try store.internFact(try adapter.term(box), try store.intern(&.{.concrete}), &.{.{ .key = .{ .field = 0 }, .fact = item_fact }});
    const array_fact = try store.internFact(try adapter.term(array), try store.intern(&.{.concrete}), &.{.{ .key = .sequence_item, .fact = item_fact }});
    const outer_fact = try store.internFact(try adapter.term(outer), try store.intern(&.{.concrete}), &.{ .{ .key = .{ .field = 0 }, .fact = box_fact }, .{ .key = .{ .field = 1 }, .fact = array_fact } });
    const box_fields = [_]sir.FieldDecl{.{ .name = "value", .type_id = item }};
    const outer_fields = [_]sir.FieldDecl{ .{ .name = "inner", .type_id = box }, .{ .name = "items", .type_id = array } };
    const structs = [_]sir.StructDecl{
        .{ .decl_id = box_decl, .name = "Box", .layout = .normal, .fields = &box_fields },
        .{ .decl_id = outer_decl, .name = "Outer", .layout = .normal, .fields = &outer_fields },
    };
    var field_steps = [_]sir.TakePathStep{
        .{ .field = .{ .struct_decl_id = outer_decl, .struct_name = "Outer", .field = "inner" } },
        .{ .field = .{ .struct_decl_id = box_decl, .struct_name = "Box", .field = "value" } },
    };
    var field_alias: sir.Expr = .{ .ref_path_local = .{ .local_name = "outer", .steps = &field_steps } };
    var index: sir.Expr = .{ .int = .{ .value = 0, .type_name = null } };
    const index_steps = [_]sir.TakePathStep{.{ .field = .{ .struct_decl_id = outer_decl, .struct_name = "Outer", .field = "items" } }};
    var index_alias: sir.Expr = .{ .ref_index_path_local = .{ .local_name = "outer", .steps = &index_steps, .index = &index } };
    const metadata = [_]sir.ExprMetadataEntry{
        .{ .expr = &field_alias, .metadata = .{ .type_id = reference, .semantics = sir.ValueSemantics.plainValue() } },
        .{ .expr = &index, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.plainValue() } },
        .{ .expr = &index_alias, .metadata = .{ .type_id = reference, .semantics = sir.ValueSemantics.plainValue() } },
    };
    const reads = [_]PureExprAdapter.LocalRead{ .{ .expr = &field_alias, .fact = outer_fact }, .{ .expr = &index_alias, .fact = outer_fact } };
    const pure = PureExprAdapter{ .types = adapter, .metadata = &metadata, .structs = &structs, .local_reads = &reads };
    try std.testing.expectEqual(origin, (try pure.eval(&store, &field_alias)).child(.ref_target).?.receiver);
    try std.testing.expectEqual(origin, (try pure.eval(&store, &index_alias)).child(.ref_target).?.receiver);
    field_steps[1].field.struct_decl_id = outer_decl;
    try std.testing.expectError(error.IncorrectFieldOwner, pure.eval(&store, &field_alias));
}

test "checked union payload reads and references preserve case origin" {
    const allocator = std.testing.allocator;
    var types = semantic_types.TypeInterner.init(allocator);
    defer types.deinit();
    var store = Store.init(allocator);
    defer store.deinit();
    const item = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const union_decl: identity.DeclId = @fromBackingInt(@intCast(231));
    const choice = try types.intern(.{ .nominal = .{ .kind = .@"union", .decl_id = union_decl } });
    const reference = try types.intern(.{ .ref_ = .{ .target = item, .is_const = true } });
    const adapter = TypeAdapter{ .types = &types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(23)), .ordinal = 0 } }});
    const payload = try store.internFact(try adapter.term(item), origin, &.{});
    const choice_fact = try store.internFact(try adapter.term(choice), try store.intern(&.{.concrete}), &.{.{ .key = .{ .case_payload = 0 }, .fact = payload }});
    const fields = [_]sir.UnionField{.{ .name = "Value", .has_payload = true, .type_id = item }};
    const unions = [_]sir.UnionDecl{.{ .decl_id = union_decl, .name = "Choice", .layout = .normal, .fields = &fields }};
    const root_id: identity.BindingId = @fromBackingInt(@intCast(232));
    var object: sir.Expr = .{ .local = "choice" };
    var value: sir.Expr = .{ .union_field = .{ .object = &object, .union_decl_id = union_decl, .union_name = "Choice", .field = "Value" } };
    var borrowed: sir.Expr = .{ .borrowed_union_field = .{ .object = &object, .union_decl_id = union_decl, .union_name = "Choice", .field = "Value" } };
    var alias: sir.Expr = .{ .ref_union_field_local = .{ .local_name = "choice", .union_decl_id = union_decl, .union_name = "Choice", .field = "Value" } };
    const metadata = [_]sir.ExprMetadataEntry{
        .{ .expr = &object, .metadata = .{ .type_id = choice, .semantics = sir.ValueSemantics.plainValue(), .checked_place_root = .{ .binding = root_id } } },
        .{ .expr = &value, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.plainValue() } },
        .{ .expr = &borrowed, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.borrowedProjection() } },
        .{ .expr = &alias, .metadata = .{ .type_id = reference, .semantics = sir.ValueSemantics.plainValue(), .checked_place_root = .{ .binding = root_id }, .non_owning_place_origin = true } },
    };
    const reads = [_]PureExprAdapter.LocalRead{ .{ .expr = &object, .fact = choice_fact }, .{ .expr = &alias, .fact = choice_fact } };
    const pure = PureExprAdapter{ .types = adapter, .metadata = &metadata, .structs = &.{}, .unions = &unions, .local_reads = &reads };
    try std.testing.expectEqual(origin, (try pure.eval(&store, &value)).receiver);
    try std.testing.expectEqual(origin, (try pure.eval(&store, &borrowed)).receiver);
    try std.testing.expectEqual(origin, (try pure.eval(&store, &alias)).child(.ref_target).?.receiver);
    alias.ref_union_field_local.union_decl_id = @fromBackingInt(@intCast(233));
    try std.testing.expectError(error.IncorrectCaseOwner, pure.eval(&store, &alias));
    alias.ref_union_field_local.union_decl_id = union_decl;

    const statements = [_]sir.Stmt{.{ .expr = &alias }};
    const params = [_]sir.Param{.{ .name = "choice", .type_id = choice, .binding_id = root_id }};
    const function = sir.Function{ .owner = null, .name = "borrow_case", .params = &params, .body = &statements };
    var prepared = try PreparedStraightLine.init(allocator, adapter, &function, &metadata, &.{}, &unions, &.{choice_fact});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expectEqual(choice_fact, result.values[0].?);
    var forged = metadata;
    forged[3].metadata.checked_place_root = .{ .binding = @fromBackingInt(@intCast(234)) };
    try std.testing.expectError(error.IncorrectBindingIdentity, PreparedStraightLine.init(allocator, adapter, &function, &forged, &.{}, &unions, &.{choice_fact}));
}

test "pure typed expression transfer extracts a checked union payload" {
    const allocator = std.testing.allocator;
    var types = semantic_types.TypeInterner.init(allocator);
    defer types.deinit();
    var store = Store.init(allocator);
    defer store.deinit();
    const item = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const union_type = try types.intern(.{ .nominal = .{ .kind = .@"union", .decl_id = @fromBackingInt(@intCast(31)) } });
    const cases = [_]sir.UnionField{.{ .name = "Value", .has_payload = true, .type_id = item }};
    const unions = [_]sir.UnionDecl{.{ .decl_id = @fromBackingInt(@intCast(31)), .name = "Choice", .layout = .normal, .fields = &cases }};
    const adapter = TypeAdapter{ .types = &types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(6)), .ordinal = 0 } }});
    const payload = try store.internFact(try adapter.term(item), origin, &.{});
    const union_fact = try store.internFact(try adapter.term(union_type), try store.intern(&.{.concrete}), &.{.{ .key = .{ .case_payload = 0 }, .fact = payload }});
    var subject: sir.Expr = .{ .local = "choice" };
    var extract: sir.Expr = .{ .cast = .{ .subject = &subject, .source_union_decl_id = @fromBackingInt(@intCast(31)), .target_type_id = item, .union_case_name = "Value", .fallible = false, .reinterpret = false } };
    const metadata = [_]sir.ExprMetadataEntry{
        .{ .expr = &subject, .metadata = .{ .type_id = union_type, .semantics = sir.ValueSemantics.plainValue() } },
        .{ .expr = &extract, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.plainValue() } },
    };
    const reads = [_]PureExprAdapter.LocalRead{.{ .expr = &subject, .fact = union_fact }};
    const pure = PureExprAdapter{ .types = adapter, .metadata = &metadata, .structs = &.{}, .unions = &unions, .local_reads = &reads };
    try std.testing.expectEqual(origin, (try pure.eval(&store, &extract)).receiver);
    extract.cast.fallible = true;
    try std.testing.expectError(error.UnsupportedExpression, pure.eval(&store, &extract));
}

test "straight-line typed flow strongly replaces resolved binding before return" {
    const allocator = std.testing.allocator;
    var types = semantic_types.TypeInterner.init(allocator);
    defer types.deinit();
    var store = Store.init(allocator);
    defer store.deinit();
    const item = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const adapter = TypeAdapter{ .types = &types };
    const old_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(8)), .ordinal = 0 } }});
    const old_fact = try store.internFact(try adapter.term(item), old_origin, &.{});
    var input: sir.Expr = .{ .local = "x" };
    var literal: sir.Expr = .{ .int = .{ .value = 1, .type_name = null } };
    var returned: sir.Expr = .{ .local = "x" };
    const statements = [_]sir.Stmt{
        .{ .local = .{ .name = "x", .type_id = item, .binding_id = @fromBackingInt(@intCast(2)), .init = &input } },
        .{ .assign = .{ .name = "x", .binding_id = @fromBackingInt(@intCast(2)), .value = &literal } },
        .{ .@"return" = &returned },
    };
    const metadata = [_]sir.ExprMetadataEntry{
        .{ .expr = &input, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.plainValue(), .checked_place_root = .{ .binding = @fromBackingInt(@intCast(1)) } } },
        .{ .expr = &literal, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.plainValue() } },
        .{ .expr = &returned, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.plainValue(), .checked_place_root = .{ .binding = @fromBackingInt(@intCast(2)) } } },
    };
    const reads = [_]PureExprAdapter.ResolvedRead{
        .{ .expr = &input, .slot = 0 },
        .{ .expr = &returned, .slot = 1 },
    };
    const writes = [_]StraightLineFlow.Write{
        .{ .stmt = &statements[0], .slot = 1 },
        .{ .stmt = &statements[1], .slot = 1 },
    };
    const flow = StraightLineFlow{
        .allocator = allocator,
        .expression = .{ .types = adapter, .metadata = &metadata, .structs = &.{}, .local_reads = &.{}, .resolved_reads = &reads },
        .binding_types = &.{ item, item },
        .writes = &writes,
        .return_type = item,
    };
    const initial = [_]?*const Fact{ old_fact, null };
    const result = try flow.run(&store, &statements, &initial);
    defer result.deinit(allocator);
    try std.testing.expect(result.did_return);
    try std.testing.expectEqual(try store.intern(&.{.concrete}), result.returned.?.receiver);
    try std.testing.expectEqual(old_origin, result.values[0].?.receiver);
    try std.testing.expectEqual(result.returned, result.values[1]);
    const no_writes = StraightLineFlow{ .allocator = allocator, .expression = flow.expression, .binding_types = flow.binding_types, .writes = &.{}, .return_type = item };
    try std.testing.expectError(error.MissingWriteTarget, no_writes.run(&store, &statements, &initial));

    const params = [_]sir.Param{.{ .name = "input", .type_id = item, .binding_id = @fromBackingInt(@intCast(1)) }};
    input.local = "input";
    const function = sir.Function{ .owner = null, .name = "forward", .params = &params, .return_type_id = item, .body = &statements };
    var prepared = try PreparedStraightLine.init(allocator, adapter, &function, &metadata, &.{}, &.{}, &.{old_fact});
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 2), prepared.binding_types.len);
    try std.testing.expectEqual(@as(u32, 0), prepared.reads[0].slot);
    try std.testing.expectEqual(@as(u32, 1), prepared.reads[1].slot);
    const prepared_result = try prepared.run(&store);
    defer prepared_result.deinit(allocator);
    try std.testing.expectEqual(try store.intern(&.{.concrete}), prepared_result.returned.?.receiver);
}

test "checked handoff transfers origin and invalidates its source binding" {
    const allocator = std.testing.allocator;
    var types = semantic_types.TypeInterner.init(allocator);
    defer types.deinit();
    var store = Store.init(allocator);
    defer store.deinit();
    const item = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const adapter = TypeAdapter{ .types = &types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(14)), .ordinal = 0 } }});
    const source_fact = try store.internFact(try adapter.term(item), origin, &.{});
    const source_id: identity.BindingId = @fromBackingInt(@intCast(141));
    const destination_id: identity.BindingId = @fromBackingInt(@intCast(142));
    var moved: sir.Expr = .{ .handoff_local = "source" };
    const statements = [_]sir.Stmt{.{ .local = .{ .name = "destination", .type_id = item, .binding_id = destination_id, .init = &moved } }};
    const params = [_]sir.Param{.{ .name = "source", .type_id = item, .binding_id = source_id }};
    const function = sir.Function{ .owner = null, .name = "handoff", .params = &params, .body = &statements };
    const metadata = [_]sir.ExprMetadataEntry{.{
        .expr = &moved,
        .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.plainValue(), .checked_place_root = .{ .binding = source_id } },
    }};
    var prepared = try PreparedStraightLine.init(allocator, adapter, &function, &metadata, &.{}, &.{}, &.{source_fact});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.values[0] == null);
    try std.testing.expectEqual(source_fact, result.values[1].?);

    var moved_again: sir.Expr = .{ .handoff_local = "source" };
    const repeated = [_]sir.Stmt{
        statements[0],
        .{ .local = .{ .name = "second", .type_id = item, .binding_id = @fromBackingInt(@intCast(143)), .init = &moved_again } },
    };
    const repeated_metadata = [_]sir.ExprMetadataEntry{
        metadata[0],
        .{ .expr = &moved_again, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.plainValue(), .checked_place_root = .{ .binding = source_id } } },
    };
    const repeated_function = sir.Function{ .owner = null, .name = "handoff_twice", .params = &params, .body = &repeated };
    var repeated_prepared = try PreparedStraightLine.init(allocator, adapter, &repeated_function, &repeated_metadata, &.{}, &.{}, &.{source_fact});
    defer repeated_prepared.deinit();
    try std.testing.expectError(error.UninitializedBinding, repeated_prepared.run(&store));
}

test "nested checked handoff in a struct literal consumes its source once" {
    const allocator = std.testing.allocator;
    var types = semantic_types.TypeInterner.init(allocator);
    defer types.deinit();
    var store = Store.init(allocator);
    defer store.deinit();
    const item = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const box_decl: identity.DeclId = @fromBackingInt(@intCast(151));
    const box = try types.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = box_decl } });
    const adapter = TypeAdapter{ .types = &types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(15)), .ordinal = 0 } }});
    const source_fact = try store.internFact(try adapter.term(item), origin, &.{});
    const source_id: identity.BindingId = @fromBackingInt(@intCast(152));
    var first: sir.Expr = .{ .handoff_local = "source" };
    var literal: sir.Expr = .{ .int = .{ .value = 0, .type_name = null } };
    const fields = [_]sir.StructLiteralField{ .{ .name = "a", .value = &first }, .{ .name = "b", .value = &literal } };
    var constructed: sir.Expr = .{ .struct_literal = .{ .decl_id = box_decl, .type_name = "Box", .fields = &fields } };
    const statements = [_]sir.Stmt{.{ .local = .{ .name = "box", .type_id = box, .binding_id = @fromBackingInt(@intCast(153)), .init = &constructed } }};
    const params = [_]sir.Param{.{ .name = "source", .type_id = item, .binding_id = source_id }};
    const structs = [_]sir.StructDecl{.{ .decl_id = box_decl, .name = "Box", .layout = .normal, .fields = &.{ .{ .name = "a", .type_id = item }, .{ .name = "b", .type_id = item } } }};
    const metadata = [_]sir.ExprMetadataEntry{
        .{ .expr = &first, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.plainValue(), .checked_place_root = .{ .binding = source_id } } },
        .{ .expr = &literal, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.plainValue() } },
        .{ .expr = &constructed, .metadata = .{ .type_id = box, .semantics = sir.ValueSemantics.plainValue() } },
    };
    const function = sir.Function{ .owner = null, .name = "wrap", .params = &params, .body = &statements };
    var prepared = try PreparedStraightLine.init(allocator, adapter, &function, &metadata, &structs, &.{}, &.{source_fact});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.values[0] == null);
    try std.testing.expectEqual(origin, result.values[1].?.child(.{ .field = 0 }).?.receiver);

    var second: sir.Expr = .{ .handoff_local = "source" };
    const duplicate_fields = [_]sir.StructLiteralField{ .{ .name = "a", .value = &first }, .{ .name = "b", .value = &second } };
    var duplicate_constructed: sir.Expr = .{ .struct_literal = .{ .decl_id = box_decl, .type_name = "Box", .fields = &duplicate_fields } };
    const duplicate_statements = [_]sir.Stmt{.{ .local = .{ .name = "box", .type_id = box, .binding_id = @fromBackingInt(@intCast(153)), .init = &duplicate_constructed } }};
    const duplicate_metadata = [_]sir.ExprMetadataEntry{
        metadata[0],
        .{ .expr = &second, .metadata = .{ .type_id = item, .semantics = sir.ValueSemantics.plainValue(), .checked_place_root = .{ .binding = source_id } } },
        .{ .expr = &duplicate_constructed, .metadata = .{ .type_id = box, .semantics = sir.ValueSemantics.plainValue() } },
    };
    const duplicate_function = sir.Function{ .owner = null, .name = "wrap_twice", .params = &params, .body = &duplicate_statements };
    var duplicate_prepared = try PreparedStraightLine.init(allocator, adapter, &duplicate_function, &duplicate_metadata, &structs, &.{}, &.{source_fact});
    defer duplicate_prepared.deinit();
    try std.testing.expectError(error.UninitializedBinding, duplicate_prepared.run(&store));
}

test "checked if condition handoff precedes both branch states" {
    const allocator = std.testing.allocator;
    var types = semantic_types.TypeInterner.init(allocator);
    defer types.deinit();
    var store = Store.init(allocator);
    defer store.deinit();
    const bool_type = try types.intern(.{ .primitive = .bool });
    const adapter = TypeAdapter{ .types = &types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(16)), .ordinal = 0 } }});
    const source_fact = try store.internFact(try adapter.term(bool_type), origin, &.{});
    const source_id: identity.BindingId = @fromBackingInt(@intCast(161));
    var condition: sir.Expr = .{ .handoff_local = "source" };
    const statements = [_]sir.Stmt{.{ .@"if" = .{ .kind = .plain, .condition = &condition, .case_name = null, .capture_name = null, .then_body = &.{}, .else_body = &.{} } }};
    const params = [_]sir.Param{.{ .name = "source", .type_id = bool_type, .binding_id = source_id }};
    const function = sir.Function{ .owner = null, .name = "choose", .params = &params, .body = &statements };
    const metadata = [_]sir.ExprMetadataEntry{.{
        .expr = &condition,
        .metadata = .{ .type_id = bool_type, .semantics = sir.ValueSemantics.plainValue(), .checked_place_root = .{ .binding = source_id } },
    }};
    var prepared = try PreparedStraightLine.init(allocator, adapter, &function, &metadata, &.{}, &.{}, &.{source_fact});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.reachable);
    try std.testing.expect(result.values[0] == null);

    const loop_statements = [_]sir.Stmt{.{ .@"while" = .{ .condition = &condition, .body = &.{} } }};
    const loop_function = sir.Function{ .owner = null, .name = "repeat", .params = &params, .body = &loop_statements };
    var loop_prepared = try PreparedStraightLine.init(allocator, adapter, &loop_function, &metadata, &.{}, &.{}, &.{source_fact});
    defer loop_prepared.deinit();
    try std.testing.expectError(error.UninitializedBinding, loop_prepared.run(&store));
}

test "generic binder IDs distinguish same-spelled parameters across declarations and impls" {
    const allocator = std.testing.allocator;
    var declarations = identity.Registry.init(allocator);
    defer declarations.deinit();
    const source = try declarations.registerSource("generic_scopes.cy");
    const first_module = try declarations.registerModule(source, "first");
    const second_module = try declarations.registerModule(source, "second");
    const first_fn = try declarations.registerDecl(first_module, null, "inspect", .function);
    const second_fn = try declarations.registerDecl(second_module, null, "inspect", .function);
    const owner = try declarations.registerDecl(first_module, null, "Holder", .@"struct");
    const method = try declarations.registerDecl(first_module, "Holder", "inspect", .function);
    const protocol = try declarations.registerDecl(first_module, null, "Readable", .protocol);
    var scopes = ScopeRegistry.init(allocator, &declarations);
    defer scopes.deinit();
    const first = try scopes.register(.{ .declaration = first_fn }, 1);
    const second = try scopes.register(.{ .declaration = second_fn }, 1);
    const nominal = try scopes.register(.{ .declaration = owner }, 1);
    const nested_method = try scopes.register(.{ .declaration = method }, 1);
    const impl_one = try scopes.register(.{ .implementation = .{ .module = first_module, .ordinal = 0 } }, 1);
    const impl_two = try scopes.register(.{ .implementation = .{ .module = first_module, .ordinal = 1 } }, 1);
    try std.testing.expectEqual(first, try scopes.register(.{ .declaration = first_fn }, 1));
    try std.testing.expect(first != second and first != nested_method and nominal != nested_method and impl_one != impl_two);
    const first_param = try scopes.param(first, 0);
    try std.testing.expect(scopes.verifyParam(first_param));
    try std.testing.expect(!std.meta.eql(first_param, try scopes.param(second, 0)));
    try std.testing.expectError(error.ConflictingArity, scopes.register(.{ .declaration = first_fn }, 2));
    try std.testing.expectError(error.InvalidParameter, scopes.param(first, 1));
    try std.testing.expectError(error.InvalidBinder, scopes.register(.{ .declaration = protocol }, 1));
    try std.testing.expectError(error.InvalidBinder, scopes.param(@fromBackingInt(@intCast(99)), 0));
    try std.testing.expect(!scopes.verifyParam(.{ .scope = @fromBackingInt(@intCast(99)), .ordinal = 0 }));
}

test "parsed generic declarations register distinct lexical binder identities" {
    const allocator = std.testing.allocator;
    const source =
        \\type Alias<T> = T;
        \\struct Box<T> { value: T; fn map<U>(self: &const Box<T>, value: U): U { return value; } }
        \\fn identity<T>(value: T): T { return value; }
        \\protocol Marker { fn mark(self: &const Box<i32>): i32; }
        \\impl<T> Box<T>: Marker { fn mark(self: &const Box<T>): i32 { return 1; } }
    ;
    const tokens = try @import("../lexer/lexer.zig").lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try @import("../parser/parser.zig").parse(allocator, "binders.cy", source, tokens);
    defer program.deinit(allocator);
    var declarations = try @import("declarations.zig").registration.build(allocator, "binders.cy", program);
    defer declarations.deinit();
    var scopes = ScopeRegistry.init(allocator, &declarations);
    defer scopes.deinit();
    try scopes.registerProgram(program);
    try std.testing.expectEqual(@as(usize, 5), scopes.scopes.items.len);
    for (scopes.scopes.items, 0..) |scope, index| {
        try std.testing.expectEqual(@as(u32, 1), scope.param_count);
        if (index != 0) try std.testing.expect(!std.meta.eql(scope.key, scopes.scopes.items[index - 1].key));
    }
    try std.testing.expect(scopes.scopes.items[0].key == .declaration);
    try std.testing.expect(scopes.scopes.items[3].key == .declaration);
    try std.testing.expect(scopes.scopes.items[4].key == .implementation);
    const box_param = scopes.sourceParam(program.structs[0].module_name, program.structs[0].type_params[0].name_token.offset).?;
    const method_param = scopes.sourceParam(program.structs[0].methods[0].module_name, program.structs[0].methods[0].type_params[0].name_token.offset).?;
    const function_param = scopes.sourceParam(program.functions[0].module_name, program.functions[0].type_params[0].name_token.offset).?;
    try std.testing.expect(scopes.verifyParam(box_param));
    try std.testing.expect(!std.meta.eql(box_param, method_param));
    try std.testing.expect(!std.meta.eql(box_param, function_param));
    try std.testing.expect(scopes.verifySourceParam(program.structs[0].module_name, program.structs[0].type_params[0].name_token.offset, box_param));
    try std.testing.expect(!scopes.verifySourceParam(program.structs[0].module_name, program.structs[0].type_params[0].name_token.offset, method_param));
}

fn scopeAllocationProbe(allocator: std.mem.Allocator) anyerror!void {
    var declarations = identity.Registry.init(allocator);
    defer declarations.deinit();
    const source = try declarations.registerSource("scope_allocation.cy");
    const module_id = try declarations.registerModule(source, "main");
    const decl = try declarations.registerDecl(module_id, null, "inspect", .function);
    var scopes = ScopeRegistry.init(allocator, &declarations);
    defer scopes.deinit();
    const binder = try scopes.register(.{ .declaration = decl }, 2);
    _ = try scopes.param(binder, 1);
    _ = try scopes.register(.{ .implementation = .{ .module = module_id, .ordinal = 0 } }, 1);
}

test "generic binder registry releases partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, scopeAllocationProbe, .{});
}

fn allocationProbe(allocator: std.mem.Allocator) anyerror!void {
    var store = Store.init(allocator);
    defer store.deinit();
    const a = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(1)), .ordinal = 0 } }});
    const b = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(1)), .ordinal = 1 } }});
    _ = try store.join(a, b);
    _ = try store.project(a);
    const type_term: TypeTermId = @fromBackingInt(@intCast(1));
    const left = try store.internFact(type_term, a, &.{});
    const right = try store.internFact(type_term, b, &.{});
    _ = try store.joinFacts(left, right);
    const outer_type: TypeTermId = @fromBackingInt(@intCast(2));
    const outer_left = try store.internFact(outer_type, a, &.{.{ .key = .{ .field = 0 }, .fact = left }});
    const outer_right = try store.internFact(outer_type, b, &.{.{ .key = .{ .field = 0 }, .fact = right }});
    _ = try store.joinFacts(outer_left, outer_right);
}

test "origin store releases partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}

pub const method_use = struct {
    pub const Error = error{OutOfMemory};
    /// Collect protocol-backed method-use IDs from a checked SIR body.
    /// Output order is not a source-order contract.
    pub fn collect(
        allocator: std.mem.Allocator,
        function: *const sir.Function,
        ids: *std.ArrayListUnmanaged(u32),
    ) Error!void {
        var pending: std.ArrayListUnmanaged([]const sir.Stmt) = .empty;
        defer pending.deinit(allocator);
        var stack: std.ArrayListUnmanaged(*const sir.Expr) = .empty;
        defer stack.deinit(allocator);
        try pending.append(allocator, function.body);
        while (pending.items.len > 0) {
            const statements = pending.items[pending.items.len - 1];
            pending.items.len -= 1;
            for (statements) |statement| switch (statement) {
                .local => |local| try stack.append(allocator, local.init),
                .assign => |assign| try stack.append(allocator, assign.value),
                .field_assign => |assign| try stack.append(allocator, assign.value),
                .index_assign => |assign| {
                    try stack.append(allocator, assign.object);
                    try stack.append(allocator, assign.index);
                    try stack.append(allocator, assign.value);
                },
                .deref_assign => |assign| {
                    try stack.append(allocator, assign.pointer);
                    try stack.append(allocator, assign.value);
                },
                .deref_field_assign => |assign| {
                    try stack.append(allocator, assign.pointer);
                    try stack.append(allocator, assign.value);
                },
                .using_alloc => |block| {
                    try stack.append(allocator, block.allocator_expr);
                    try pending.append(allocator, block.body);
                },
                .unchecked => |body| try pending.append(allocator, body),
                .@"if" => |branch| {
                    try stack.append(allocator, branch.condition);
                    try pending.append(allocator, branch.then_body);
                    try pending.append(allocator, branch.else_body);
                },
                .@"while" => |loop| {
                    try stack.append(allocator, loop.condition);
                    try pending.append(allocator, loop.body);
                },
                .@"for" => |loop| {
                    // Generated `syntax.iter*` hook uses are recorded on the loop
                    // itself, so the checked flow has to settle each one.
                    for (loop.generated_method_uses) |use| try ids.append(allocator, use.use_id);
                    try stack.append(allocator, loop.iterable);
                    try pending.append(allocator, loop.body);
                },
                .@"switch" => |branch| {
                    try stack.append(allocator, branch.value);
                    for (branch.cases) |case| try pending.append(allocator, case.body);
                    try pending.append(allocator, branch.else_body);
                },
                .@"try" => |attempt| try stack.append(allocator, attempt.expr),
                .@"defer", .expr => |expr| try stack.append(allocator, expr),
                .@"return" => |maybe_expr| if (maybe_expr) |expr| try stack.append(allocator, expr),
                .asm_stmt => |assembly| {
                    for (assembly.inputs) |input| try stack.append(allocator, input.value);
                },
                else => {},
            };
        }
        while (stack.items.len > 0) {
            const expr = stack.pop() orelse break;
            // A checked use is admitted by the flow only when it reaches a protocol
            // witness; ordinary call records carry their own callee authority.
            if (expr.* == .call and expr.call.checked_method_use != null and
                expr.call.checked_method_use.?.protocol_id != null)
            {
                try ids.append(allocator, expr.call.checked_method_use.?.use_id);
            }
            switch (expr.*) {
                .call => |call| for (call.args) |arg| try stack.append(allocator, arg.value),
                .indirect_call => |call| {
                    try stack.append(allocator, call.callee);
                    for (call.args) |arg| try stack.append(allocator, arg.value);
                },
                .@"try" => |try_expr| try stack.append(allocator, try_expr.expr),
                .union_case => |case| if (case.value) |value| try stack.append(allocator, value),
                .is_test => |is_test| try stack.append(allocator, is_test.subject),
                .cast => |cast| try stack.append(allocator, cast.subject),
                .closure => |closure| for (closure.captures) |capture| try stack.append(allocator, capture),
                .thread_spawn_boxed => |spawn| try stack.append(allocator, spawn.payload),
                .task_group_spawn_boxed => |spawn| {
                    try stack.append(allocator, spawn.group_raw);
                    try stack.append(allocator, spawn.entry);
                    try stack.append(allocator, spawn.payload);
                },
                .task_result_take => |take| {
                    try stack.append(allocator, take.witness);
                    try stack.append(allocator, take.pointer);
                },
                .sync_share_boxed => |share| try stack.append(allocator, share.payload),
                .ref_load => |value| try stack.append(allocator, value),
                .ref_raw_deref, .raw_deref => |deref| try stack.append(allocator, deref.expr),
                .unary => |unary| try stack.append(allocator, unary.expr),
                .binary => |binary| {
                    try stack.append(allocator, binary.left);
                    try stack.append(allocator, binary.right);
                },
                .test_assert => |value| try stack.append(allocator, value),
                .builtin_print => |print| for (print.parts) |part| {
                    if (part == .value) try stack.append(allocator, part.value.expr);
                },
                .interpolated_string => |parts| for (parts) |part| {
                    if (part == .value) try stack.append(allocator, part.value.expr);
                },
                .sequence_push => |push| {
                    try stack.append(allocator, push.object);
                    try stack.append(allocator, push.value);
                },
                .sparse_insert => |insert| {
                    try stack.append(allocator, insert.object);
                    try stack.append(allocator, insert.index);
                    try stack.append(allocator, insert.value);
                },
                .sparse_contains_index => |contains| {
                    try stack.append(allocator, contains.object);
                    try stack.append(allocator, contains.index);
                },
                .sparse_take => |take| {
                    try stack.append(allocator, take.object);
                    try stack.append(allocator, take.index);
                },
                .sequence_reserve => |reserve| {
                    try stack.append(allocator, reserve.object);
                    try stack.append(allocator, reserve.capacity);
                },
                .string_starts_with, .string_ends_with, .string_contains, .string_find, .string_rfind => |pair| {
                    try stack.append(allocator, pair.object);
                    try stack.append(allocator, pair.value);
                },
                .string_slice => |slice| {
                    try stack.append(allocator, slice.object);
                    try stack.append(allocator, slice.start);
                    try stack.append(allocator, slice.end);
                },
                .slice_range => |range| {
                    try stack.append(allocator, range.object);
                    if (range.start) |start| try stack.append(allocator, start);
                    if (range.end) |end| try stack.append(allocator, end);
                },
                .sequence_len, .sequence_clear, .sparse_len, .sparse_clear, .sparse_indices, .sequence_pop, .string_len, .string_is_empty, .string_bytes, .string_from, .slice_len, .slice_ptr => |value| try stack.append(allocator, value),
                .index, .borrowed_index => |index| {
                    try stack.append(allocator, index.object);
                    try stack.append(allocator, index.index);
                },
                .take_index_local => |take| try stack.append(allocator, take.index),
                .take_index_path_local => |take| {
                    for (take.steps) |step| if (step == .index) try stack.append(allocator, step.index);
                    try stack.append(allocator, take.index);
                },
                .ref_index_local => |reference| try stack.append(allocator, reference.index),
                .ref_field_expr => |field| try stack.append(allocator, field.object),
                .field, .borrowed_field => |field| try stack.append(allocator, field.object),
                .tuple_field => |field| try stack.append(allocator, field.object),
                .union_field, .borrowed_union_field => |field| try stack.append(allocator, field.object),
                .take_path_local, .ref_path_local => |take| for (take.steps) |step| if (step == .index) try stack.append(allocator, step.index),
                .array_literal, .dense_array_literal => |literal| for (literal.items) |item| try stack.append(allocator, item),
                .tuple_literal => |literal| for (literal.items) |item| try stack.append(allocator, item),
                .sparse_literal => |literal| for (literal.items) |item| try stack.append(allocator, item),
                .sparse_keyed_literal => |literal| for (literal.entries) |entry| {
                    try stack.append(allocator, entry.index);
                    try stack.append(allocator, entry.value);
                },
                .new_array => |array| try stack.append(allocator, array.len),
                .new_sparse => |array| try stack.append(allocator, array.capacity),
                .new_owned, .struct_literal => |literal| for (literal.fields) |field| try stack.append(allocator, field.value),
                .asm_expr => |assembly| {
                    if (assembly.inout) |inout| try stack.append(allocator, inout.value);
                    for (assembly.inputs) |input| try stack.append(allocator, input.value);
                },
                else => {},
            }
        }
    }
    /// Compare the checked flow with the method uses recorded while lowering.
    pub const Issue = union(enum) {
        count_mismatch: struct { observed: usize, recorded: usize },
        missing_use_id,
        not_once: struct { use_id: u32, count: usize },
        return_type_mismatch,
    };

    /// Compare the checked flow with the method uses recorded while lowering.
    /// The order of checks preserves the diagnostics emitted by both callers.
    pub fn firstIssue(
        allocator: std.mem.Allocator,
        recorded_ids: []const u32,
        observed_uses: []const MethodUse,
        report: BodyReport,
        declared_return_type: ?sir.TypeId,
    ) error{OutOfMemory}!?Issue {
        if (report.method_uses != recorded_ids.len) {
            return .{ .count_mismatch = .{ .observed = report.method_uses, .recorded = recorded_ids.len } };
        }

        var settled: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        defer settled.deinit(allocator);
        for (observed_uses) |use| {
            if (use.use_id == 0) return .missing_use_id;
            const entry = try settled.getOrPut(allocator, use.use_id);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
        for (recorded_ids) |use_id| {
            const count = settled.get(use_id) orelse 0;
            if (count != 1) return .{ .not_once = .{ .use_id = use_id, .count = count } };
        }
        if (report.returned_type != null and declared_return_type != null and
            report.returned_type.? != declared_return_type.?)
        {
            return .return_type_mismatch;
        }
        return null;
    }
};

pub const definition_body = struct {
    pub const Error = error{OutOfMemory};

    /// Return the first checked-flow gap for a definition-site generic body.
    /// Null means the checked flow accepted every recorded method use.
    pub fn firstGap(
        allocator: std.mem.Allocator,
        canonical_types: *const semantic_types.TypeInterner,
        other_functions: []const sir.Function,
        body: sir.Function,
        metadata: []const sir.ExprMetadataEntry,
        structs: []const sir.StructDecl,
        unions: []const sir.UnionDecl,
        scratch: *[256]u8,
    ) Error!?[]const u8 {
        var pool: std.ArrayListUnmanaged(sir.Function) = .empty;
        defer pool.deinit(allocator);
        try pool.append(allocator, body);
        try pool.appendSlice(allocator, other_functions);

        var present: std.ArrayListUnmanaged(u32) = .empty;
        defer present.deinit(allocator);
        try method_use.collect(allocator, &body, &present);
        if (present.items.len == 0) return null;

        const types = TypeAdapter{ .types = canonical_types };
        var uses: std.ArrayListUnmanaged(MethodUse) = .empty;
        defer uses.deinit(allocator);
        const report = analyzeBody(allocator, types, pool.items, &body, metadata, structs, unions, &uses) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return std.fmt.bufPrint(scratch, "checked flow rejected the body: {s}", .{@errorName(err)}) catch "checked flow rejected the body",
        };
        const issue = try method_use.firstIssue(allocator, present.items, uses.items, report, body.return_type_id);
        return if (issue) |found| switch (found) {
            .count_mismatch => "the checked flow reached a different number of method uses than lowering recorded",
            .missing_use_id => "a method use reached the checked flow without a use id",
            .not_once => "a recorded method use was not settled exactly once by the checked flow",
            .return_type_mismatch => "the checked flow settled a result type that differs from the declared return type",
        } else null;
    }
};

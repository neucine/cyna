const std = @import("std");
const lexer = @import("../lexer/token.zig");
const identity = @import("identity.zig");
const semantic_types = @import("types.zig");
const intrinsics = @import("../intrinsics.zig");
const language_contracts = @import("../language_contracts.zig");
const generated_names = @import("../generated_names.zig");

pub const TypeId = semantic_types.TypeId;

/// Describes how a value relates to storage. This is deliberately orthogonal
/// to ownership: a place can contain a plain, shared, or uniquely owned value.
pub const ValueCategory = enum {
    value,
    place,
    borrowed_projection,
};

/// Compact result classification. `borrowed` marks a dependent access carrier;
/// it is not a fourth assignment/cleanup behavior beside plain, shared, owned.
pub const Ownership = enum {
    plain,
    borrowed,
    shared,
    owned,
};

/// Identifies who is responsible for destroying an initialized value.
pub const CleanupPolicy = enum {
    none,
    scope,
    full_expression,
    explicit,
    transferred,
};

pub const SinkAction = enum {
    none,
    initialize,
    replace,
    @"return",
};

pub const TransferAction = enum {
    copy,
    move,
    take,
};

pub const Consumption = struct {
    sink: SinkAction = .none,
    transfer: TransferAction = .copy,

    pub fn isValid(self: Consumption, semantics: ValueSemantics) bool {
        return switch (self.transfer) {
            .copy => semantics.cleanup != .full_expression and semantics.cleanup != .transferred,
            .move => semantics.cleanup == .full_expression or semantics.cleanup == .transferred,
            .take => semantics.cleanup == .transferred or semantics.ownership == .plain or semantics.ownership == .borrowed,
        };
    }
};

/// Semantic facts that lowering must eventually consume without inspecting
/// the expression variant that produced the value.
pub const ValueSemantics = struct {
    category: ValueCategory,
    ownership: Ownership,
    cleanup: CleanupPolicy,

    pub fn plainValue() ValueSemantics {
        return .{
            .category = .value,
            .ownership = .plain,
            .cleanup = .none,
        };
    }

    pub fn borrowedProjection() ValueSemantics {
        return .{
            .category = .borrowed_projection,
            .ownership = .borrowed,
            .cleanup = .none,
        };
    }

    pub fn isValid(self: ValueSemantics) bool {
        if (self.ownership == .plain or self.ownership == .borrowed) {
            return self.cleanup == .none;
        }
        if (self.cleanup == .transferred) {
            return self.category == .value;
        }
        return true;
    }
};

test "value semantics keep storage category ownership and cleanup orthogonal" {
    try std.testing.expect(ValueSemantics.plainValue().isValid());
    try std.testing.expect(ValueSemantics.borrowedProjection().isValid());
    try std.testing.expect((ValueSemantics{
        .category = .place,
        .ownership = .shared,
        .cleanup = .scope,
    }).isValid());
    try std.testing.expect(!(ValueSemantics{
        .category = .borrowed_projection,
        .ownership = .borrowed,
        .cleanup = .full_expression,
    }).isValid());
    try std.testing.expect(!(ValueSemantics{
        .category = .place,
        .ownership = .owned,
        .cleanup = .transferred,
    }).isValid());
}

test "typed consumption actions agree with cleanup responsibility" {
    const aliased: ValueSemantics = .{
        .category = .place,
        .ownership = .shared,
        .cleanup = .none,
    };
    const temporary: ValueSemantics = .{
        .category = .value,
        .ownership = .owned,
        .cleanup = .full_expression,
    };
    const transferred: ValueSemantics = .{
        .category = .value,
        .ownership = .owned,
        .cleanup = .transferred,
    };

    try std.testing.expect((Consumption{ .sink = .initialize, .transfer = .copy }).isValid(aliased));
    try std.testing.expect((Consumption{ .sink = .@"return", .transfer = .move }).isValid(temporary));
    try std.testing.expect((Consumption{ .sink = .replace, .transfer = .take }).isValid(transferred));
    try std.testing.expect(!(Consumption{ .sink = .initialize, .transfer = .copy }).isValid(temporary));
}
pub const IntrinsicId = intrinsics.Id;
pub const ResultCase = language_contracts.ResultCase;

pub const ExprMetadata = struct {
    type_id: TypeId,
    semantics: ValueSemantics,
    /// Destination union case selected for a statement-rooted `try`.
    try_widen_ordinal: ?u32 = null,
    consumption: Consumption = .{},
    intrinsic_id: ?IntrinsicId = null,
    /// Identity of a value produced by this expression, separate from places.
    temporary_id: ?identity.TemporaryId = null,
    checked_place_root: ?CheckedPlaceRoot = null,
    checked_place_projections: ?[]const CheckedPlaceProjection = null,
    checked_raw_deref: ?CheckedRawDeref = null,
    /// Owned payload supplied through a compiler-generated hosted trampoline.
    checked_generated_payload_binding: ?identity.BindingId = null,
    /// The resolved source place crosses a non-owning alias or view.
    non_owning_place_origin: bool = false,
    /// Emitted during semantic resolution for ownership-bearing expressions.
    checked_effect: ?Record = null,
    checked_sink_effect: ?Record = null,

    pub fn checkedPlacePath(self: ExprMetadata) ?CheckedPlacePath {
        return if (self.checked_place_root) |root| .{
            .root = root,
            .projections = self.checked_place_projections,
            .non_owning = self.non_owning_place_origin,
        } else null;
    }
};

pub const CheckedPlaceRoot = union(enum) {
    binding: identity.BindingId,
    global: identity.DeclId,
};

pub const CheckedPlacePath = struct {
    root: CheckedPlaceRoot,
    /// Borrows the expression metadata's checked projection slice.
    projections: ?[]const CheckedPlaceProjection,
    non_owning: bool,

    pub fn canOwn(self: CheckedPlacePath) bool {
        return !self.non_owning;
    }

    /// Prefixes overlap; a dynamic index may denote any element.
    pub fn mayOverlap(self: CheckedPlacePath, other: CheckedPlacePath) bool {
        if (!std.meta.eql(self.root, other.root)) return false;
        const left = self.projections orelse &.{};
        const right = other.projections orelse &.{};
        for (left[0..@min(left.len, right.len)], right[0..@min(left.len, right.len)]) |a, b| {
            if (!checkedStepsMayOverlap(a.step, b.step)) return false;
        }
        return true;
    }
};

pub const CheckedCaptureOrigin = union(enum) {
    place: CheckedPlacePath,
    temporary: identity.TemporaryId,
};

pub const CheckedPayloadCase = union(enum) {
    optional_some,
    result: ResultCase,
    union_field: struct { owner_decl_id: identity.DeclId, ordinal: u32 },
    inline_error_union: struct { type_id: TypeId, ordinal: u32 },
};

pub const CheckedCapturePath = struct {
    source: ?CheckedCaptureOrigin,
    active_case: CheckedPayloadCase,
};

pub const CheckedIndex = union(enum) { fixed: i64, dynamic: *const Expr };
pub const CheckedRangeBound = union(enum) { fixed: i64, dynamic: *const Expr };
pub const CheckedRange = struct { start: ?CheckedRangeBound, end: ?CheckedRangeBound };

pub const CheckedPlaceProjection = struct {
    step: union(enum) {
        field: struct { owner_decl_id: identity.DeclId, name: []const u8 },
        union_payload: struct { owner_decl_id: identity.DeclId, name: []const u8 },
        index: CheckedIndex,
        range: CheckedRange,
    },
    result_type_id: TypeId,
};

fn fixedRangeBound(bound: ?CheckedRangeBound, open_value: ?i64) ?i64 {
    return if (bound) |value| switch (value) {
        .fixed => |number| number,
        .dynamic => null,
    } else open_value;
}

fn rangeMayContainIndex(range: CheckedRange, index: CheckedIndex) bool {
    if (index != .fixed) return true;
    if (fixedRangeBound(range.start, 0)) |start| if (index.fixed < start) return false;
    if (fixedRangeBound(range.end, null)) |end| if (index.fixed >= end) return false;
    return true;
}

fn rangesMayOverlap(left: CheckedRange, right: CheckedRange) bool {
    if (fixedRangeBound(left.end, null)) |end| {
        if (fixedRangeBound(right.start, 0)) |start| if (end <= start) return false;
    }
    if (fixedRangeBound(right.end, null)) |end| {
        if (fixedRangeBound(left.start, 0)) |start| if (end <= start) return false;
    }
    return true;
}

fn checkedStepsMayOverlap(left: @FieldType(CheckedPlaceProjection, "step"), right: @FieldType(CheckedPlaceProjection, "step")) bool {
    return switch (left) {
        .field => |field| right == .field and field.owner_decl_id == right.field.owner_decl_id and std.mem.eql(u8, field.name, right.field.name),
        .union_payload => |field| right == .union_payload and field.owner_decl_id == right.union_payload.owner_decl_id and std.mem.eql(u8, field.name, right.union_payload.name),
        .index => |index| switch (right) {
            .index => |other| index != .fixed or other != .fixed or index.fixed == other.fixed,
            .range => |range| rangeMayContainIndex(range, index),
            else => false,
        },
        .range => |range| switch (right) {
            .index => |index| rangeMayContainIndex(range, index),
            .range => |other| rangesMayOverlap(range, other),
            else => false,
        },
    };
}

pub const CheckedRawDeref = struct {
    pointer_source: CheckedPlaceRoot,
    pointee_type_id: TypeId,
    is_volatile: bool,
};

const ScopedBinding = struct { name: []const u8, id: identity.BindingId };

pub const Subject = union(enum) {
    place: CheckedPlacePath,
    /// Storage reached through a writable reference binding. The reference
    /// binding is only an address; the pointee owns the replaced value.
    alias_pointee: CheckedPlacePath,
    /// Storage read through a checked reference value. The reference may be
    /// returned by a call and therefore have no rooted place path.
    reference_target: struct { reference: *const Expr, target_type_id: TypeId },
    reference_projection: struct { reference: *const Expr, projection: CheckedPlaceProjection },
    raw_pointee: struct {
        pointer: *const Expr,
        pointee_type_id: TypeId,
        projections: ?[]const CheckedPlaceProjection = null,
    },
    container_slot: struct {
        object: *const Expr,
        place: ?CheckedPlacePath = null,
        item_type_id: TypeId,
        position: union(enum) { append, last, all, indexed: CheckedIndex },
    },
    temporary: identity.TemporaryId,
    temporary_projection: struct { root: identity.TemporaryId, projection: CheckedPlaceProjection },
    temporary_payload: struct {
        root: identity.TemporaryId,
        owner_decl_id: ?identity.DeclId,
        case_name: []const u8,
        result_case: ?ResultCase,
        payload_type_id: TypeId,
    },
    return_slot: identity.DeclId,
    generated_payload: identity.BindingId,
    call_slot: struct { function_decl_id: identity.DeclId, index: u32 },
    indirect_call_slot: struct { call: *const Expr, index: u32 },
    indirect_return_slot: *const Expr,
    closure_slot: struct { environment_decl_id: identity.DeclId, field_index: u32 },

    pub fn canOwn(self: Subject) bool {
        return switch (self) {
            .place => |place| place.canOwn(),
            .alias_pointee => true,
            .reference_target => false,
            .reference_projection => false,
            .raw_pointee => true,
            .container_slot => true,
            .temporary, .temporary_projection, .temporary_payload, .return_slot, .generated_payload, .call_slot, .indirect_call_slot, .indirect_return_slot, .closure_slot => true,
        };
    }

    pub fn isWholeValue(self: Subject) bool {
        return switch (self) {
            .place, .alias_pointee => |place| place.projections == null,
            .raw_pointee => |place| place.projections == null,
            .reference_target => false,
            .reference_projection => false,
            .container_slot => false,
            .temporary_projection => false,
            .temporary_payload => false,
            .temporary, .return_slot, .generated_payload, .call_slot, .indirect_call_slot, .indirect_return_slot, .closure_slot => true,
        };
    }
};

/// The effect is reached only on the named outcome of one checked call or
/// carrier. Argument handoff uses `always`; a fallible constructor's create
/// effect uses `success` so an error cannot invent an obligation.
pub const Edge = union(enum) {
    always,
    success: u32,
    failure: u32,
    active_case: CheckedPayloadCase,
};

pub const CallArgument = struct {
    use_id: u32,
    callee_declaration_id: identity.DeclId,
    index: u32,
    source: Subject,
    destination: ?Subject = null,
    mode: enum { borrow, move },
};

pub const Effect = union(enum) {
    create: struct { obligation_id: u32, destination: Subject },
    /// Produces a fresh owned value without asserting a must-settle obligation.
    materialize: Subject,
    move: struct { source: Subject, destination: Subject },
    /// Duplicates a shared value while keeping the source available.
    copy: struct { source: Subject, destination: Subject },
    take: struct { source: Subject, destination: Subject },
    borrow: Subject,
    read: Subject,
    settle: struct { source: Subject, terminal_declaration_id: identity.DeclId },
    replace: Subject,
    drop: Subject,
    /// Detaches local cleanup responsibility for an explicit raw escape.
    leak: Subject,
    clear: Subject,
    @"return": struct { source: Subject, destination: Subject },
    call_argument: CallArgument,
};

pub const Record = struct {
    edge: Edge = .always,
    effect: Effect,

    pub fn validate(self: Record) error{InvalidEffectContract}!void {
        switch (self.edge) {
            .always, .active_case => {},
            .success, .failure => |use_id| if (use_id == 0) return error.InvalidEffectContract,
        }
        switch (self.effect) {
            .create => |create| {
                if (create.obligation_id == 0 or !create.destination.canOwn()) return error.InvalidEffectContract;
            },
            .materialize => |destination| if (!destination.canOwn() or !destination.isWholeValue()) return error.InvalidEffectContract,
            .move => |move| {
                if (!move.source.canOwn() or !move.source.isWholeValue() or !move.destination.canOwn() or
                    sameEffectSubject(move.source, move.destination)) return error.InvalidEffectContract;
            },
            .copy => |copy| {
                if (!copy.source.canOwn() or !copy.source.isWholeValue() or !copy.destination.canOwn() or
                    sameEffectSubject(copy.source, copy.destination)) return error.InvalidEffectContract;
            },
            .take => |take| {
                if (!take.source.canOwn() or !take.destination.canOwn() or sameEffectSubject(take.source, take.destination)) return error.InvalidEffectContract;
            },
            .borrow, .read => {},
            .settle => |settle| if (!settle.source.canOwn()) return error.InvalidEffectContract,
            .replace, .drop => |destination| if (!destination.canOwn()) return error.InvalidEffectContract,
            .leak => |source| if (!source.canOwn() or !source.isWholeValue()) return error.InvalidEffectContract,
            .clear => |target| if (target != .container_slot or target.container_slot.position != .all) return error.InvalidEffectContract,
            .@"return" => |transfer| {
                if (!transfer.source.canOwn() or !transfer.source.isWholeValue() or !transfer.destination.canOwn() or
                    sameEffectSubject(transfer.source, transfer.destination)) return error.InvalidEffectContract;
            },
            .call_argument => |argument| {
                if (self.edge != .always or argument.use_id == 0) return error.InvalidEffectContract;
                if (argument.mode == .move and
                    (!argument.source.canOwn() or !argument.source.isWholeValue() or argument.destination == null or
                        !argument.destination.?.canOwn() or sameEffectSubject(argument.source, argument.destination.?)))
                {
                    return error.InvalidEffectContract;
                }
                if (argument.mode == .borrow and argument.destination != null) return error.InvalidEffectContract;
            },
        }
    }
};

pub const EffectSite = struct {
    expr: *const Expr,
    action: union(enum) {
        neutral,
        effect: Record,
    },
};

pub const EffectFlowEvent = union(enum) {
    global: *const Global,
    statement: *const Stmt,
    evaluate: *const Expr,
    effect: Record,
    control: struct {
        statement: *const Stmt,
        phase: enum {
            scope_enter,
            scope_exit,
            then_enter,
            else_enter,
            branch_join,
            loop_header,
            loop_body,
            loop_back,
            loop_exit,
            switch_case,
            switch_else,
            switch_join,
            try_error,
            defer_register,
            defer_body,
            defer_end,
            defer_invoke,
            continue_exit,
            break_exit,
            return_exit,
        },
        case_index: u32 = 0,
    },
    short_circuit_rhs: *const Expr,
    short_circuit_join: *const Expr,
    try_error: *const Expr,
    try_success: *const Expr,
};

pub const CallEvaluationSite = union(enum) {
    callee_value: *const Expr,
    argument_value: *const Expr,
    effect: Record,
};

pub const MutationEvaluationSite = union(enum) {
    target_value: *const Expr,
    index_value: *const Expr,
    assigned_value: *const Expr,
    effect: Record,
};

fn mutationSitesMatch(actual: []const ?MutationEvaluationSite, active_len: u8, expected: []const MutationEvaluationSite) bool {
    if (active_len != expected.len or actual.len < expected.len) return false;
    for (actual[0..expected.len], expected) |maybe_site, wanted| {
        const site = maybe_site orelse return false;
        if (!std.meta.eql(site, wanted)) return false;
    }
    for (actual[expected.len..]) |site| if (site != null) return false;
    return true;
}

fn sameEffectSubject(left: Subject, right: Subject) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .temporary => |id| id == right.temporary,
        .temporary_projection => |projection| std.meta.eql(projection, right.temporary_projection),
        .temporary_payload => |payload| payload.root == right.temporary_payload.root and
            payload.owner_decl_id == right.temporary_payload.owner_decl_id and
            std.mem.eql(u8, payload.case_name, right.temporary_payload.case_name) and
            payload.result_case == right.temporary_payload.result_case and
            payload.payload_type_id == right.temporary_payload.payload_type_id,
        .return_slot => |id| id == right.return_slot,
        .generated_payload => |id| id == right.generated_payload,
        .call_slot => |slot| std.meta.eql(slot, right.call_slot),
        .indirect_call_slot => |slot| slot.call == right.indirect_call_slot.call and slot.index == right.indirect_call_slot.index,
        .indirect_return_slot => |call| call == right.indirect_return_slot,
        .reference_target => |target| target.reference == right.reference_target.reference and
            target.target_type_id == right.reference_target.target_type_id,
        .reference_projection => |projection| projection.reference == right.reference_projection.reference and
            std.meta.eql(projection.projection, right.reference_projection.projection),
        .closure_slot => |slot| std.meta.eql(slot, right.closure_slot),
        .raw_pointee => |pointee| blk: {
            const other = right.raw_pointee;
            if (pointee.pointer != other.pointer or pointee.pointee_type_id != other.pointee_type_id) break :blk false;
            const steps = pointee.projections orelse &.{};
            const other_steps = other.projections orelse &.{};
            if (steps.len != other_steps.len) break :blk false;
            for (steps, other_steps) |step, other_step| if (!std.meta.eql(step, other_step)) break :blk false;
            break :blk true;
        },
        .container_slot => |slot| blk: {
            const other = right.container_slot;
            if (slot.object != other.object or slot.item_type_id != other.item_type_id or
                !std.meta.eql(slot.position, other.position) or
                (slot.place == null) != (other.place == null)) break :blk false;
            if (slot.place) |place| {
                if (!sameCheckedPlacePath(place, other.place.?)) break :blk false;
            }
            break :blk true;
        },
        .place, .alias_pointee => |place| blk: {
            const other = switch (right) {
                .place => |value| value,
                .alias_pointee => |value| value,
                else => unreachable,
            };
            if (!std.meta.eql(place.root, other.root) or place.non_owning != other.non_owning) break :blk false;
            const steps = place.projections orelse &.{};
            const other_steps = other.projections orelse &.{};
            if (steps.len != other_steps.len) break :blk false;
            for (steps, other_steps) |step, other_step| {
                if (!std.meta.eql(step, other_step)) break :blk false;
            }
            break :blk true;
        },
    };
}

pub fn sameCheckedPlacePath(left: CheckedPlacePath, right: CheckedPlacePath) bool {
    if (!std.meta.eql(left.root, right.root) or left.non_owning != right.non_owning) return false;
    const steps = left.projections orelse &.{};
    const other_steps = right.projections orelse &.{};
    if (steps.len != other_steps.len) return false;
    for (steps, other_steps) |step, other_step| {
        if (!std.meta.eql(step, other_step)) return false;
    }
    return true;
}

pub const ExprMetadataEntry = struct {
    expr: *const Expr,
    metadata: ExprMetadata,
};

pub const IdentityFailureContext = struct {
    function: ?*const Function = null,
    metadata_index: ?usize = null,
    expression_kind: ?[]const u8 = null,
};

/// Does the layout of the declaration named by `decl_id` mention `needle` in
/// one of its field or payload types? A protocol witness stores the type a
/// specialization substituted into a generic parameter in its struct fields,
/// so the substituted type is reachable only through the declaration layout.
fn declarationTreeContains(types: *const semantic_types.TypeInterner, module: *const Module, decl_id: identity.DeclId, needle: semantic_types.TypeId, depth: usize) bool {
    for (module.structs) |struct_decl| {
        if (struct_decl.decl_id != decl_id) continue;
        for (struct_decl.fields) |field| {
            if (field.type_id != null and typeTreeContains(types, module, field.type_id.?, needle, depth + 1)) return true;
        }
        return false;
    }
    for (module.unions) |union_decl| {
        if (union_decl.decl_id != decl_id) continue;
        for (union_decl.fields) |field| {
            if (field.type_id != null and typeTreeContains(types, module, field.type_id.?, needle, depth + 1)) return true;
        }
        return false;
    }
    return false;
}

/// Does the type named by `id` mention `needle`, either directly, as the type
/// argument a specialization substituted into a generic parameter, or through
/// the layout of a declaration that type names?
fn typeTreeContains(types: *const semantic_types.TypeInterner, module: *const Module, id: semantic_types.TypeId, needle: semantic_types.TypeId, depth: usize) bool {
    if (id == needle) return true;
    if (depth >= 12) return false;
    const ty = types.get(id) catch return false;
    switch (ty.*) {
        .generic_instance => |instance| {
            for (instance.args) |arg| {
                if (arg == .type and typeTreeContains(types, module, arg.type, needle, depth + 1)) return true;
            }
            if (instance.decl_id != null and declarationTreeContains(types, module, instance.decl_id.?, needle, depth + 1)) return true;
        },
        .nominal => |nominal| {
            if (nominal.underlying != null and typeTreeContains(types, module, nominal.underlying.?, needle, depth + 1)) return true;
            if (declarationTreeContains(types, module, nominal.decl_id, needle, depth + 1)) return true;
        },
        .callable => |callable| {
            for (callable.params) |param| {
                if (typeTreeContains(types, module, param, needle, depth + 1)) return true;
            }
            return typeTreeContains(types, module, callable.return_type, needle, depth + 1);
        },
        .raw => |raw| return typeTreeContains(types, module, raw.target, needle, depth + 1),
        .ref_ => |ref| return typeTreeContains(types, module, ref.target, needle, depth + 1),
        .optional, .dense_array, .sparse_array, .owned => |inner| return typeTreeContains(types, module, inner, needle, depth + 1),
        .array => |array| return typeTreeContains(types, module, array.item, needle, depth + 1),
        .slice => |slice| return typeTreeContains(types, module, slice.item, needle, depth + 1),
        .result => |result| return typeTreeContains(types, module, result.ok, needle, depth + 1) or typeTreeContains(types, module, result.err, needle, depth + 1),
        else => {},
    }
    return false;
}

pub const GenericRequirement = struct {
    projected: bool = false,
    declaration_id: ?identity.DeclId,
    module_name: []const u8,
    owner: ?[]const u8,
    declaration: []const u8,
    parameter: []const u8,
    parameter_definition_offset: ?usize = null,
    parameter_id: ?identity.GenericParamId = null,
    operation: []const u8,
    source_offset: usize,
    /// Stable identity of the source method use this requirement came from.
    /// Every requirement and every lowered use of the same source call shares
    /// one id, so a use can never borrow another call's authority.
    use_id: ?u32 = null,
    declared_protocol: ?struct {
        id: identity.DeclId,
        method_id: ?identity.DeclId = null,
        module_name: []const u8,
        name: []const u8,
    } = null,
};

pub const VerifyValueActionsError = error{
    OutOfMemory,
    DuplicateExpressionMetadata,
    InvalidExpressionMetadata,
    MissingExpressionMetadata,
    InvalidSinkAction,
    InvalidCheckedEffect,
};

pub const VerifyIntrinsicCallsError = error{
    IncorrectIntrinsicIdentity,
    InvalidIntrinsicExpression,
};

pub const VerifyCompilerIdentitiesError = error{
    OutOfMemory,
    InvalidResultCaseIdentity,
    InvalidTestEntryIdentity,
    MissingExpressionMetadata,
    MissingCanonicalTypes,
    InvalidTypeIdentity,
    InvalidCheckedPlaceProjection,
    InvalidCheckedPlaceRoot,
    MissingPlaceIdentity,
    InvalidBindingIdentity,
    InvalidTemporaryIdentity,
    InvalidCaptureIdentity,
};

pub const VerifyGenericRequirementsError = error{
    OutOfMemory,
    MissingGenericDeclarationIdentity,
    MissingGenericParameterIdentity,
    ConflictingGenericParameterCanonicalIdentity,
    ConflictingGenericParameterIdentity,
    ConflictingGenericMethodAuthority,
    MissingGenericMethodUseAuthority,
    MissingMethodUseIdentity,
    IncorrectMethodUseIdentity,
    MissingCallAuthority,
    UnregisteredCallAuthority,
    DuplicateMethodUseIdentity,
    ConflictingMethodUseIdentity,
    IncorrectGenericDeclarationIdentity,
    IncorrectGenericProtocolIdentity,
    IncorrectGenericProtocolMethodIdentity,
    MissingMethodUseSignature,
    IncorrectMethodUseSignature,
    InvalidMethodUseSubstitution,
    MissingCanonicalTypes,
    MissingExpressionMetadata,
    MissingGeneratedMethodUse,
    IncorrectGeneratedMethodUse,
    DuplicateGeneratedMethodUse,
};

pub const VerifyPrintHelperIdentitiesError = error{
    MissingPrintHelperIdentity,
    IncorrectPrintHelperIdentity,
    InvalidPrintHelperSignature,
    MissingCanonicalTypes,
    MissingExpressionMetadata,
    InvalidTypeIdentity,
};

pub const VerifyError =
    VerifyValueActionsError ||
    VerifyIntrinsicCallsError ||
    VerifyCompilerIdentitiesError ||
    VerifyGenericRequirementsError ||
    VerifyPrintHelperIdentitiesError;

pub const Type = enum {
    int,
    float,
    rune,
    string,
    bool,
    void,
    function,
    arrow_callable,
    optional,
    array,
    dense_array,
    sparse_array,
    slice,
    result,
    ref,
    owned,
    raw,
    @"enum",
    @"union",
    @"struct",
};

pub const Module = struct {
    canonical_types: ?semantic_types.TypeInterner = null,
    expr_metadata: []const ExprMetadataEntry = &.{},
    expr_metadata_retained: bool = false,
    effect_sites: []const EffectSite = &.{},
    effect_sites_owned: bool = false,
    global_effect_flow: []const EffectFlowEvent = &.{},
    global_effect_flow_owned: bool = false,
    generic_requirements: []const GenericRequirement = &.{},
    globals: []const Global,
    asm_consts: []const AsmConst = &.{},
    enums: []const EnumDecl,
    unions: []const UnionDecl,
    structs: []const StructDecl,
    functions: []const Function,
    tests: []const InlineTest = &.{},
    generated_strings: []const []const u8 = &.{},

    pub fn deinit(self: Module, allocator: std.mem.Allocator) void {
        var canonical_types = self.canonical_types;
        if (canonical_types) |*types| types.deinit();
        if (self.effect_sites_owned) allocator.free(self.effect_sites);
        if (self.global_effect_flow_owned) allocator.free(self.global_effect_flow);
        for (self.globals) |global| global.deinit(allocator);
        allocator.free(self.globals);
        allocator.free(self.asm_consts);
        for (self.enums) |decl| decl.deinit(allocator);
        allocator.free(self.enums);
        for (self.unions) |decl| decl.deinit(allocator);
        allocator.free(self.unions);
        for (self.structs) |decl| decl.deinit(allocator);
        allocator.free(self.structs);
        for (self.functions) |function| function.deinit(allocator);
        allocator.free(self.functions);
        for (self.tests) |inline_test| inline_test.deinit(allocator);
        allocator.free(self.tests);
        for (self.generated_strings) |value| allocator.free(value);
        allocator.free(self.generated_strings);
        for (self.expr_metadata) |entry| if (entry.metadata.checked_place_projections) |projections| allocator.free(projections);
        allocator.free(self.expr_metadata);
        // Every requirement in an emitted module owns the spelling strings it
        // copied from the declaration registry.
        for (self.generic_requirements) |requirement| {
            allocator.free(requirement.module_name);
            if (requirement.owner) |owner| allocator.free(owner);
            allocator.free(requirement.declaration);
            allocator.free(requirement.parameter);
            if (requirement.declared_protocol) |protocol| {
                allocator.free(protocol.module_name);
                allocator.free(protocol.name);
            }
        }
        allocator.free(self.generic_requirements);
    }

    pub fn dump(self: Module, writer: anytype) anyerror!void {
        const module = self;
        for (self.generic_requirements) |requirement| {
            try writer.writeAll("requires ");
            if (requirement.module_name.len != 0) try writer.print("{s}::", .{requirement.module_name});
            if (requirement.owner) |owner| try writer.print("{s}.", .{owner});
            try writer.print("{s}<{s}>: {s} @+{d}", .{
                requirement.declaration,
                requirement.parameter,
                requirement.operation,
                requirement.source_offset,
            });
            if (requirement.projected) try writer.writeAll(" [projection]");
            if (requirement.declared_protocol) |protocol| {
                try writer.writeAll(" [declared ");
                if (protocol.module_name.len != 0) try writer.print("{s}::", .{protocol.module_name});
                try writer.print("{s}]", .{protocol.name});
            }
            try writer.writeByte('\n');
        }
        for (self.globals) |global| {
            if (global.is_extern) try writer.writeAll("extern ");
            try writer.print("{s} ", .{if (global.is_mutable) "var" else "const"});
            if (global.owner) |owner| {
                try writer.print("{s}.{s}: ", .{ owner, global.name });
            } else {
                try writer.print("{s}: ", .{global.name});
            }
            try dumpType(writer, module, global.type_id);
            if (global.abi_name) |abi_name| {
                try writer.print(" = \"{s}\"", .{abi_name});
            }
            if (global.is_symbol_addr) {
                try writer.writeAll(" /*symbol_addr*/");
            } else if (global.init) |init| {
                try writer.writeAll(" = ");
                try dumpExpr(writer, module, init);
            }
            try writer.writeAll("\n");
        }

        for (self.asm_consts) |asm_const| {
            try writer.print("export asm const {s} = {d}\n", .{ asm_const.name, asm_const.value });
        }

        for (self.enums) |decl| {
            try writer.print("enum {s}", .{decl.name});
            if (decl.repr_name) |repr_name| {
                try writer.print(": {s}", .{repr_name});
            }
            try writer.writeAll(" {\n");
            for (decl.cases) |case| {
                try writer.print("  {s} = {d}\n", .{ case.name, case.value });
            }
            try writer.writeAll("}\n");
        }

        for (self.unions) |decl| {
            try writer.print("union {s} {{\n", .{decl.name});
            for (decl.fields) |field| {
                try writer.print("  {s}: ", .{field.name});
                try dumpType(writer, module, field.type_id);
                try writer.writeAll("\n");
            }
            try writer.writeAll("}\n");
        }

        for (self.structs) |decl| {
            try writer.print("struct {s} {{\n", .{decl.name});
            for (decl.fields) |field| {
                try writer.print("  {s}: ", .{field.name});
                try dumpType(writer, module, field.type_id);
                try writer.writeAll("\n");
            }
            try writer.writeAll("}\n");
        }

        for (self.functions) |function| {
            if (function.is_extern) {
                try writer.writeAll("extern ");
                try writer.writeAll(switch (function.calling_convention) {
                    .cyna => "cyna ",
                    .c => "c ",
                });
            }
            if (function.owner) |owner| {
                try writer.print("fn {s}.{s}(", .{ owner, function.name });
            } else {
                try writer.print("fn {s}(", .{function.name});
            }
            for (function.params, 0..) |param, i| {
                if (i != 0) try writer.writeAll(", ");
                try writer.print("{s}: ", .{param.name});
                try dumpType(writer, module, param.type_id);
            }
            try writer.writeAll(")");
            if (!isVoidType(module, function.return_type_id)) {
                try writer.writeAll(": ");
                try dumpType(writer, module, function.return_type_id);
            }
            if (function.abi_name) |abi_name| {
                try writer.print(" = \"{s}\"", .{abi_name});
            }
            try writer.writeAll(" {\n");
            for (function.body) |stmt| {
                try dumpStmt(writer, module, 1, stmt);
            }
            try writer.writeAll("}\n");
        }

        for (self.tests) |inline_test| {
            const module_name = if (inline_test.module_name.len == 0) "<root>" else inline_test.module_name;
            try writer.print("test \"{s}\" [{s}] => {s}\n", .{ inline_test.name, module_name, inline_test.function_name });
        }
    }

    pub fn metadataForExpr(self: Module, expr: *const Expr) ?ExprMetadata {
        for (self.expr_metadata) |entry| {
            if (entry.expr == expr) return entry.metadata;
        }
        return null;
    }

    pub fn dumpValueSemantics(self: Module, writer: anytype) anyerror!void {
        for (self.expr_metadata, 0..) |entry, index| {
            try writer.print("expr {d}: ", .{index});
            try dumpType(writer, self, entry.metadata.type_id);
            try writer.print(" [{s}, {s}, {s}; {s}, {s}]\n", .{
                @tagName(entry.metadata.semantics.category),
                @tagName(entry.metadata.semantics.ownership),
                @tagName(entry.metadata.semantics.cleanup),
                @tagName(entry.metadata.consumption.sink),
                @tagName(entry.metadata.consumption.transfer),
            });
        }
    }

    pub fn dumpIntrinsicCalls(self: Module, writer: anytype) anyerror!void {
        for (self.expr_metadata, 0..) |entry, index| {
            if (!self.expr_metadata_retained and !self.exprIsLive(entry.expr)) continue;
            const intrinsic_id = (switch (entry.expr.*) {
                .call => |call| call.intrinsic_id,
                .thread_spawn_boxed => |spawn| spawn.intrinsic_id,
                .task_group_spawn_boxed => |spawn| spawn.intrinsic_id,
                .task_result_take => |take| take.intrinsic_id,
                .sync_share_boxed => |share| share.intrinsic_id,
                else => null,
            }) orelse entry.metadata.intrinsic_id orelse continue;
            try writer.print("expr {d}: intrinsic {s}\n", .{ index, @tagName(intrinsic_id) });
        }
    }

    pub fn verifyIntrinsicCalls(self: Module) VerifyIntrinsicCallsError!void {
        for (self.expr_metadata) |entry| {
            if (!self.expr_metadata_retained and !self.exprIsLive(entry.expr)) continue;
            switch (entry.expr.*) {
                .call => |call| {
                    const expected = self.intrinsicForDeclId(call.decl_id);
                    if (expected) |expected_id| {
                        if (call.intrinsic_id != expected_id) return error.IncorrectIntrinsicIdentity;
                    } else if (call.intrinsic_id) |intrinsic_id| {
                        const category = intrinsics.definition(intrinsic_id).category;
                        if (category != .standard_library and
                            category != .embedded_contract and
                            category != .language_syntax)
                        {
                            return error.IncorrectIntrinsicIdentity;
                        }
                    }
                },
                .thread_spawn_boxed => |spawn| {
                    if (spawn.intrinsic_id != .std_thread_spawn) return error.InvalidIntrinsicExpression;
                },
                .task_group_spawn_boxed => |spawn| {
                    if (spawn.intrinsic_id != .std_task_group_spawn_impl and
                        spawn.intrinsic_id != .std_task_group_spawn_context_impl and
                        spawn.intrinsic_id != .std_task_context_spawn_impl) return error.InvalidIntrinsicExpression;
                },
                .task_result_take => |take| {
                    if (take.intrinsic_id != .std_task_result_take_impl) return error.InvalidIntrinsicExpression;
                },
                .sync_share_boxed => |share| {
                    const intrinsic_id = share.intrinsic_id orelse return error.InvalidIntrinsicExpression;
                    if (intrinsic_id != .std_sync_share and intrinsic_id != .std_own_arc) {
                        return error.InvalidIntrinsicExpression;
                    }
                },
                else => {
                    if (!intrinsicMatchesBuiltinExpr(entry.expr, entry.metadata.intrinsic_id))
                        return error.IncorrectIntrinsicIdentity;
                },
            }
        }
        for (self.functions) |function| try verifyStmtIntrinsicContracts(function.body);
    }

    pub fn verify(self: Module) VerifyError!void {
        try self.verifyValueActions();
        try self.verifyIntrinsicCalls();
        try self.verifyCompilerIdentities();
        try self.verifyGenericRequirementsWithMetadata(self.expr_metadata_retained);
        try self.verifyPrintHelperIdentities();
    }

    /// Each recorded method expression has one selected declared authority,
    /// even when multiple generic origins contribute requirements at that use.
    pub fn verifyGenericRequirements(self: Module) VerifyGenericRequirementsError!void {
        return self.verifyGenericRequirementsWithMetadata(self.expr_metadata_retained);
    }

    fn verifyGenericRequirementsWithMetadata(self: Module, metadata_retained: bool) VerifyGenericRequirementsError!void {
        return self.verifyGenericRequirementsWithAllocator(std.heap.page_allocator, metadata_retained);
    }

    fn verifyGenericRequirementsWithAllocator(self: Module, allocator: std.mem.Allocator, metadata_retained: bool) VerifyGenericRequirementsError!void {
        var source_uses: std.AutoHashMapUnmanaged(u32, *const Expr) = .empty;
        defer source_uses.deinit(allocator);
        for (self.generic_requirements, 0..) |requirement, index| {
            if (requirement.declaration_id == null) return error.MissingGenericDeclarationIdentity;
            if (requirement.declared_protocol != null and requirement.use_id == null) return error.MissingMethodUseIdentity;
            if (requirement.parameter_definition_offset == null or requirement.parameter_id == null) return error.MissingGenericParameterIdentity;
            for (self.generic_requirements[0..index]) |prior| {
                if (prior.declaration_id == requirement.declaration_id and
                    std.mem.eql(u8, prior.parameter, requirement.parameter) and
                    prior.parameter_definition_offset != requirement.parameter_definition_offset)
                {
                    return error.ConflictingGenericParameterIdentity;
                }
                if (prior.declaration_id == requirement.declaration_id and
                    std.mem.eql(u8, prior.parameter, requirement.parameter) and
                    !std.meta.eql(prior.parameter_id, requirement.parameter_id))
                {
                    return error.ConflictingGenericParameterCanonicalIdentity;
                }
                if (prior.declaration_id != requirement.declaration_id or
                    !std.mem.eql(u8, prior.module_name, requirement.module_name) or
                    prior.source_offset != requirement.source_offset or
                    !std.mem.eql(u8, prior.operation, requirement.operation)) continue;
                const protocol = requirement.declared_protocol orelse {
                    if (prior.declared_protocol != null) return error.ConflictingGenericMethodAuthority;
                    continue;
                };
                const prior_protocol = prior.declared_protocol orelse return error.ConflictingGenericMethodAuthority;
                if (prior_protocol.id != protocol.id or
                    prior_protocol.method_id != protocol.method_id or
                    !std.mem.eql(u8, prior_protocol.module_name, protocol.module_name) or
                    !std.mem.eql(u8, prior_protocol.name, protocol.name))
                {
                    return error.ConflictingGenericMethodAuthority;
                }
                if (prior.use_id != requirement.use_id) return error.ConflictingMethodUseIdentity;
            }
        }
        for (self.expr_metadata) |entry| {
            if ((!metadata_retained and !self.exprIsLive(entry.expr)) or entry.expr.* != .call) continue;
            // Every live lowered call carries the checked identity of the use
            // it settles to, so lowering never has to re-resolve a callee.
            const use = entry.expr.call.checked_method_use orelse return error.MissingCallAuthority;
            if (use.use_id == 0) return error.MissingMethodUseIdentity;
            // Every recorded use carries the signature it lowered to: the type
            // the use settles must be the type the expression is recorded with,
            // and the concrete callee the record names must be the callee the
            // call actually reaches.
            const result_type = use.result_type_id orelse return error.MissingMethodUseSignature;
            // The record names the callee's own settled return type. An
            // expression may settle that reference with a different const
            // qualification (for example a borrowed receiver handed to a
            // `&const` method), which is the same authority, not a forgery.
            if (entry.metadata.type_id != result_type and
                !typesDifferOnlyByRefConst(self, entry.metadata.type_id, result_type))
            {
                return error.IncorrectMethodUseSignature;
            }
            if (entry.expr.call.decl_id != use.callee_declaration_id) return error.MissingMethodUseSignature;
            var callee: ?*const Function = null;
            for (self.functions) |*function| {
                if (function.decl_id == use.callee_declaration_id) {
                    callee = function;
                    break;
                }
            }
            // A record that names a declaration the module never registered is a
            // stale authority, not a verified use.
            const target = callee orelse return error.UnregisteredCallAuthority;
            if (target.return_type_id != result_type) return error.IncorrectMethodUseSignature;
            if (use.substitution.len != 0) {
                const canonical = self.canonical_types orelse return error.MissingCanonicalTypes;
                const types = &canonical;
                for (use.substitution) |substituted| {
                    var used = false;
                    for (target.params) |param| {
                        if (param.type_id) |type_id| {
                            if (typeTreeContains(types, &self, type_id, substituted, 0)) {
                                used = true;
                                break;
                            }
                        }
                    }
                    if (!used and target.return_type_id != null) {
                        used = typeTreeContains(types, &self, target.return_type_id.?, substituted, 0);
                    }
                    if (!used) return error.InvalidMethodUseSubstitution;
                }
            }
            if (use.protocol_id != null) {
                var found = false;
                for (self.generic_requirements) |requirement| {
                    const authority = requirement.declared_protocol orelse continue;
                    if (requirement.declaration_id == use.source_declaration_id and
                        requirement.source_offset == use.source_offset and
                        authority.id == use.protocol_id.? and
                        authority.method_id == use.method_id.?)
                    {
                        if (requirement.use_id != use.use_id) return error.IncorrectMethodUseIdentity;
                        found = true;
                        break;
                    }
                }
                if (!found) return error.MissingGenericMethodUseAuthority;
            }
            const prior = try source_uses.getOrPut(allocator, use.use_id);
            if (prior.found_existing) {
                const prior_use = prior.value_ptr.*.call.checked_method_use.?;
                // Specializations of one source use may share its identity.
                // The first occurrence fixes that identity's source and authority.
                if (prior_use.source_declaration_id != use.source_declaration_id or
                    prior_use.source_offset != use.source_offset or
                    prior_use.protocol_id != use.protocol_id or
                    prior_use.method_id != use.method_id)
                {
                    return error.DuplicateMethodUseIdentity;
                }
            } else {
                prior.value_ptr.* = entry.expr;
            }
        }
        for (self.functions) |function| try self.verifyGeneratedIterationUses(function.body);
    }

    /// A `for` loop over a type with `syntax.iter*` methods desugars into hook
    /// calls that never appear in the source. Every hook the loop reaches is
    /// still a method use, so it must carry its own checked record: the stable
    /// use id, the concrete declaration it resolves to, the type that hook
    /// settles, and the receiver type it is evaluated against. A hook with no
    /// record is a shape gap, not a verified use.
    fn verifyGeneratedIterationUses(self: Module, statements: []const Stmt) VerifyGenericRequirementsError!void {
        for (statements) |statement| switch (statement) {
            .using_alloc => |block| try self.verifyGeneratedIterationUses(block.body),
            .unchecked => |body| try self.verifyGeneratedIterationUses(body),
            .@"if" => |branch| {
                try self.verifyGeneratedIterationUses(branch.then_body);
                try self.verifyGeneratedIterationUses(branch.else_body);
            },
            .@"while" => |loop| try self.verifyGeneratedIterationUses(loop.body),
            .@"switch" => |branch| {
                for (branch.cases) |case| try self.verifyGeneratedIterationUses(case.body);
                try self.verifyGeneratedIterationUses(branch.else_body);
            },
            .@"for" => |loop| {
                try self.verifyGeneratedIterationUses(loop.body);
                try verifyGeneratedIterationLoop(&self, loop);
            },
            else => {},
        };
    }

    /// The builtin print surface reaches four prelude helpers. Each print part
    /// carries the declaration identity of the helper it reaches, so lowering
    /// emits the call from that record rather than searching the module for a
    /// name. The names here validate the transported identity; they are not
    /// used to select a different declaration.
    fn verifyPrintHelperIdentities(self: Module) VerifyPrintHelperIdentitiesError!void {
        const types = if (self.canonical_types) |*value| value else return error.MissingCanonicalTypes;
        for (self.expr_metadata) |entry| {
            if ((!self.expr_metadata_retained and !self.exprIsLive(entry.expr)) or entry.expr.* != .builtin_print) continue;
            const print = entry.expr.builtin_print;
            for (print.parts) |part| switch (part) {
                // A builtin print is built from printed values; a bare literal
                // part would have no checked helper, so it is a shape gap.
                .literal => return error.InvalidPrintHelperSignature,
                .value => |value| {
                    var value_type: ?TypeId = null;
                    for (self.expr_metadata) |candidate| {
                        if (candidate.expr == value.expr) {
                            value_type = candidate.metadata.type_id;
                            break;
                        }
                    }
                    const type_id = value_type orelse return error.MissingExpressionMetadata;
                    const kind = types.get(type_id) catch return error.InvalidTypeIdentity;
                    switch (kind.*) {
                        .primitive => |primitive| switch (primitive) {
                            .string => try checkPrintHelper(self, types, value.helper_declaration_id, "print_string", 1),
                            .bool => try checkPrintHelper(self, types, value.helper_declaration_id, "print_bool", 1),
                            else => return error.InvalidPrintHelperSignature,
                        },
                        .integer, .inferred_integer => try checkPrintHelper(self, types, value.helper_declaration_id, "print_int", 2),
                        else => return error.InvalidPrintHelperSignature,
                    }
                },
            };
            if (print.append_newline) try checkPrintHelper(self, types, print.newline_helper_declaration_id, "print_newline", 0);
        }
    }

    fn checkPrintHelper(
        self: Module,
        types: *const semantic_types.TypeInterner,
        decl_id: ?identity.DeclId,
        expected_name: []const u8,
        arg_count: usize,
    ) VerifyPrintHelperIdentitiesError!void {
        const id = decl_id orelse return error.MissingPrintHelperIdentity;
        var helper: ?*const Function = null;
        for (self.functions) |*function| {
            if (function.decl_id == id) {
                helper = function;
                break;
            }
        }
        const callee = helper orelse return error.MissingPrintHelperIdentity;
        // The declared name is the identity; the abi name is the emitted symbol
        // and is mangled for prelude externs, so it must not gate identity.
        if (!std.mem.eql(u8, callee.name, expected_name)) return error.IncorrectPrintHelperIdentity;
        if (callee.params.len != arg_count) return error.InvalidPrintHelperSignature;
        const return_type = callee.return_type_id orelse return error.InvalidPrintHelperSignature;
        const kind = types.get(return_type) catch return error.InvalidTypeIdentity;
        if (kind.* != .primitive or kind.primitive != .void) return error.InvalidPrintHelperSignature;
    }

    /// Resolve recorded authority identities against the compilation registry
    /// before sema releases it. Names here validate the transported IDs; they
    /// are not used to select a different declaration or protocol.
    pub fn verifyGenericRequirementIdentities(self: Module, registry: *const identity.Registry) VerifyGenericRequirementsError!void {
        return self.verifyGenericRequirementIdentitiesWithMetadata(registry, self.expr_metadata_retained);
    }

    pub fn verifyRetainedGenericRequirementIdentities(self: Module, registry: *const identity.Registry) VerifyGenericRequirementsError!void {
        return self.verifyGenericRequirementIdentitiesWithMetadata(registry, true);
    }

    fn verifyGenericRequirementIdentitiesWithMetadata(self: Module, registry: *const identity.Registry, metadata_retained: bool) VerifyGenericRequirementsError!void {
        try self.verifyGenericRequirementsWithMetadata(metadata_retained);
        for (self.generic_requirements) |requirement| {
            const decl = registry.decl(requirement.declaration_id.?) orelse return error.IncorrectGenericDeclarationIdentity;
            const decl_module = registry.module(decl.module) orelse return error.IncorrectGenericDeclarationIdentity;
            if (decl.kind != .function or
                !std.mem.eql(u8, decl_module.name, requirement.module_name) or
                !std.mem.eql(u8, decl.name, requirement.declaration) or
                !optionalTextEqual(decl.owner, requirement.owner)) return error.IncorrectGenericDeclarationIdentity;
            if (requirement.declared_protocol) |authority| {
                const protocol = registry.decl(authority.id) orelse return error.IncorrectGenericProtocolIdentity;
                const protocol_module = registry.module(protocol.module) orelse return error.IncorrectGenericProtocolIdentity;
                if (protocol.kind != .protocol or protocol.owner != null or
                    !std.mem.eql(u8, protocol_module.name, authority.module_name) or
                    !std.mem.eql(u8, protocol.name, authority.name)) return error.IncorrectGenericProtocolIdentity;
                const method = registry.decl(authority.method_id orelse return error.IncorrectGenericProtocolMethodIdentity) orelse return error.IncorrectGenericProtocolMethodIdentity;
                const method_module = registry.module(method.module) orelse return error.IncorrectGenericProtocolMethodIdentity;
                if (method.kind != .protocol_method or
                    !std.mem.eql(u8, method_module.name, authority.module_name) or
                    !optionalTextEqual(method.owner, authority.name) or
                    !std.mem.eql(u8, method.name, requirement.operation)) return error.IncorrectGenericProtocolMethodIdentity;
            }
        }
    }

    fn typesDifferOnlyByRefConst(self: Module, left: semantic_types.TypeId, right: semantic_types.TypeId) bool {
        const types = self.canonical_types orelse return false;
        const left_node = types.get(left) catch return false;
        const right_node = types.get(right) catch return false;
        if (left_node.* != .ref_ or right_node.* != .ref_) return false;
        return left_node.ref_.target == right_node.ref_.target;
    }

    fn optionalTextEqual(left: ?[]const u8, right: ?[]const u8) bool {
        if (left) |value| return if (right) |other| std.mem.eql(u8, value, other) else false;
        return right == null;
    }

    /// Guards the non-declaration identities that sema resolves for mechanical
    /// downstream consumption. Display names must not be used to reconstruct
    /// these identities after this boundary.
    pub fn verifyCompilerIdentities(self: Module) VerifyCompilerIdentitiesError!void {
        return self.verifyCompilerIdentitiesWithContext(null);
    }

    pub fn verifyCompilerIdentitiesWithContext(self: Module, failure: ?*IdentityFailureContext) VerifyCompilerIdentitiesError!void {
        if (failure) |context| context.* = .{};
        const types = if (self.canonical_types) |*value| value else return error.MissingCanonicalTypes;
        var binding_ids: std.AutoHashMapUnmanaged(identity.BindingId, void) = .empty;
        defer binding_ids.deinit(std.heap.page_allocator);

        for (self.globals) |global| {
            if (global.init) |init| try self.verifyScopedExpr(&.{}, init);
        }
        for (self.functions) |*function| {
            if (failure) |context| context.* = .{ .function = function };
            try self.verifyStmtCompilerIdentities(types, function.body);
            var scope: std.ArrayListUnmanaged(ScopedBinding) = .empty;
            defer scope.deinit(std.heap.page_allocator);
            for (function.params) |param| if (param.binding_id) |id| {
                try checkUniqueBindingId(&binding_ids, id);
                try scope.append(std.heap.page_allocator, .{ .name = param.name, .id = id });
            };
            try checkStatementBindingIds(&binding_ids, function.body);
            try self.verifyScopedStatements(&scope, function.body);
        }

        var has_temporary_ids = false;
        for (self.expr_metadata) |entry| {
            if (entry.metadata.temporary_id != null) {
                has_temporary_ids = true;
                break;
            }
        }
        for (self.expr_metadata, 0..) |entry, index| {
            if (failure) |context| {
                context.* = .{ .metadata_index = index, .expression_kind = @tagName(entry.expr.*) };
                for (self.functions) |*function| {
                    if (stmtSliceContainsExpr(function.body, entry.expr)) {
                        context.function = function;
                        break;
                    }
                }
            }
            if (entry.metadata.temporary_id) |temporary_id| {
                const raw_id = @backingInt(temporary_id);
                if (entry.metadata.semantics.category != .value or raw_id >= (@as(u64, 1) << 62)) {
                    return error.InvalidTemporaryIdentity;
                }
                for (self.expr_metadata[0..index]) |previous| {
                    if (previous.metadata.temporary_id == temporary_id) return error.InvalidTemporaryIdentity;
                }
            } else if (has_temporary_ids and entry.metadata.semantics.category == .value and
                (self.expr_metadata_retained or self.exprIsLive(entry.expr)))
            {
                return error.InvalidTemporaryIdentity;
            }
            if (!self.expr_metadata_retained and !self.exprIsLive(entry.expr)) continue;
            if (entry.metadata.checked_place_root) |root| {
                if (!self.checkedRootExists(root, &binding_ids)) return error.InvalidCheckedPlaceRoot;
            } else if (entry.metadata.semantics.category == .place and
                (entry.metadata.semantics.ownership == .owned or entry.metadata.semantics.ownership == .shared) and
                entry.expr.* != .raw_deref and entry.expr.* != .ref_raw_deref)
            {
                return error.MissingPlaceIdentity;
            }
            if ((entry.expr.* == .raw_deref or entry.expr.* == .ref_raw_deref) and entry.metadata.checked_place_root != null) {
                return error.InvalidCheckedPlaceProjection;
            }
            if (entry.expr.* == .slice_range and entry.metadata.checked_place_root != null and
                (entry.metadata.checked_place_projections == null or !entry.metadata.non_owning_place_origin))
            {
                return error.InvalidCheckedPlaceProjection;
            }
            if ((entry.expr.* == .ref_path_local or entry.expr.* == .ref_index_path_local) and
                entry.metadata.checked_place_root == null) return error.MissingPlaceIdentity;
            const needs_projection = switch (entry.expr.*) {
                .field, .borrowed_field, .tuple_field, .union_field, .borrowed_union_field, .index, .borrowed_index, .ref_field_expr, .ref_field_local, .ref_field_owned_local, .ref_index_local, .ref_path_local, .ref_index_path_local, .ref_union_field_local => true,
                else => false,
            };
            if (needs_projection and entry.metadata.checked_place_root != null and
                entry.metadata.checked_place_projections == null)
            {
                return error.InvalidCheckedPlaceProjection;
            }
            if (entry.metadata.checked_raw_deref) |checked| {
                if (!self.checkedRootExists(checked.pointer_source, &binding_ids)) return error.InvalidCheckedPlaceRoot;
                const deref = switch (entry.expr.*) {
                    .raw_deref => |value| value,
                    .ref_raw_deref => |value| value,
                    else => return error.InvalidCheckedPlaceProjection,
                };
                const result_type = types.get(entry.metadata.type_id) catch return error.InvalidTypeIdentity;
                const pointee_type_id = if (entry.expr.* == .ref_raw_deref) blk: {
                    if (result_type.* != .ref_) return error.InvalidCheckedPlaceProjection;
                    break :blk result_type.ref_.target;
                } else entry.metadata.type_id;
                if (entry.metadata.checked_place_root != null or
                    checked.pointee_type_id != pointee_type_id or
                    checked.is_volatile != deref.is_volatile) return error.InvalidCheckedPlaceProjection;
                const pointer_metadata = self.metadataForExpr(deref.expr) orelse return error.MissingExpressionMetadata;
                const pointer_type = types.get(pointer_metadata.type_id) catch return error.InvalidTypeIdentity;
                if (pointer_type.* != .raw or pointer_type.raw.target != checked.pointee_type_id or
                    pointer_metadata.checked_place_root == null or
                    !std.meta.eql(pointer_metadata.checked_place_root.?, checked.pointer_source))
                {
                    return error.InvalidCheckedPlaceProjection;
                }
            }
            if (entry.metadata.checked_place_projections) |projections| {
                if (entry.metadata.checked_place_root == null or projections.len == 0 or
                    projections[projections.len - 1].result_type_id != entry.metadata.type_id)
                {
                    return error.InvalidCheckedPlaceProjection;
                }
                for (projections) |projection| {
                    _ = types.get(projection.result_type_id) catch return error.InvalidCheckedPlaceProjection;
                }
                if (!self.verifyCheckedPlaceProjectionExpr(entry.expr, entry.metadata.checked_place_root.?, projections)) {
                    return error.InvalidCheckedPlaceProjection;
                }
            }
            if (entry.expr.* != .union_case) continue;
            const node = types.get(entry.metadata.type_id) catch return error.InvalidTypeIdentity;
            const is_result = node.* == .result;
            if (is_result != (entry.expr.union_case.result_case != null)) {
                return error.InvalidResultCaseIdentity;
            }
        }

        for (self.tests) |inline_test| {
            var found = false;
            for (self.functions) |function| {
                if (!std.mem.eql(u8, function.module_name, inline_test.module_name) or
                    !std.mem.eql(u8, function.name, inline_test.function_name))
                {
                    continue;
                }
                if (!function.is_test_entry) return error.InvalidTestEntryIdentity;
                found = true;
                break;
            }
            if (!found) return error.InvalidTestEntryIdentity;
        }
    }

    fn verifyCheckedPlaceProjectionExpr(self: Module, expr: *const Expr, root: CheckedPlaceRoot, steps: []const CheckedPlaceProjection) bool {
        switch (expr.*) {
            .ref_field_local, .ref_field_owned_local => |field| {
                if (root != .binding or steps.len != 1 or steps[0].step != .field) return false;
                const owner_id = field.struct_decl_id orelse return false;
                const checked = steps[0];
                const metadata = self.metadataForExpr(expr) orelse return false;
                const types = if (self.canonical_types) |*value| value else return false;
                const result = types.get(metadata.type_id) catch return false;
                if (result.* != .ref_ or checked.result_type_id != metadata.type_id or
                    checked.step.field.owner_decl_id != owner_id or
                    !std.mem.eql(u8, checked.step.field.name, field.field)) return false;
                var root_type = self.bindingType(root.binding) orelse return false;
                const root_node = types.get(root_type) catch return false;
                if (root_node.* == .ref_) root_type = root_node.ref_.target;
                return checkedTakeOwnerMatches(types, root_type, owner_id);
            },
            .ref_union_field_local => |field| {
                if (root != .binding or steps.len != 1 or steps[0].step != .union_payload) return false;
                const owner_id = field.union_decl_id orelse return false;
                const metadata = self.metadataForExpr(expr) orelse return false;
                const types = if (self.canonical_types) |*value| value else return false;
                const result = types.get(metadata.type_id) catch return false;
                const payload = self.unionPayloadType(owner_id, field.field) orelse return false;
                if (result.* != .ref_ or result.ref_.target != payload or
                    steps[0].result_type_id != metadata.type_id or
                    steps[0].step.union_payload.owner_decl_id != owner_id or
                    !std.mem.eql(u8, steps[0].step.union_payload.name, field.field)) return false;
                var root_type = self.bindingType(root.binding) orelse return false;
                for (0..8) |_| {
                    const node = types.get(root_type) catch return false;
                    root_type = switch (node.*) {
                        .ref_ => |reference| reference.target,
                        .owned => |target| target,
                        .nominal => |nominal| if (nominal.kind == .type_alias and nominal.underlying != null)
                            nominal.underlying.?
                        else
                            return nominal.kind == .@"union" and nominal.decl_id == owner_id,
                        .generic_instance => |instance| return instance.kind == .@"union" and
                            (instance.decl_id orelse instance.base_decl_id) == owner_id,
                        else => return false,
                    };
                }
                return false;
            },
            .ref_index_local => |reference| {
                if (root != .binding or steps.len != 1 or steps[0].step != .index) return false;
                const metadata = self.metadataForExpr(expr) orelse return false;
                const types = if (self.canonical_types) |*value| value else return false;
                const result = types.get(metadata.type_id) catch return false;
                if (result.* != .ref_ or steps[0].result_type_id != metadata.type_id) return false;
                const checked = steps[0].step.index;
                const index_matches = if (reference.index.* == .int and reference.index.int.value >= 0)
                    checked == .fixed and checked.fixed == reference.index.int.value
                else
                    checked == .dynamic and checked.dynamic == reference.index and self.metadataForExpr(reference.index) != null;
                if (!index_matches) return false;
                var root_type = self.bindingType(root.binding) orelse return false;
                for (0..8) |_| {
                    const node = types.get(root_type) catch return false;
                    root_type = switch (node.*) {
                        .ref_ => |value| value.target,
                        .owned => |target| target,
                        .nominal => |nominal| if (nominal.kind == .type_alias and nominal.underlying != null) nominal.underlying.? else break,
                        else => break,
                    };
                }
                const container = types.get(root_type) catch return false;
                const item = switch (container.*) {
                    .array => |array| array.item,
                    .dense_array, .sparse_array => |value| value,
                    .slice => |slice| slice.item,
                    else => return false,
                };
                return result.ref_.target == item;
            },
            .ref_path_local, .ref_index_path_local => return self.verifyCheckedReferencePathExpr(expr, root, steps),
            .sparse_take => |take| {
                const object = self.metadataForExpr(take.object) orelse return false;
                const object_place = object.checkedPlacePath() orelse return false;
                const prefix = object_place.projections orelse &.{};
                if (!std.meta.eql(root, object_place.root) or steps.len != prefix.len + 1 or
                    steps[prefix.len].step != .index) return false;
                for (steps[0..prefix.len], prefix) |actual, expected| {
                    if (!std.meta.eql(actual, expected)) return false;
                }
                const index = steps[prefix.len].step.index;
                const index_matches = if (take.index.* == .int and take.index.int.value >= 0)
                    index == .fixed and index.fixed == take.index.int.value
                else
                    index == .dynamic and index.dynamic == take.index and self.metadataForExpr(take.index) != null;
                const metadata = self.metadataForExpr(expr) orelse return false;
                return index_matches and steps[prefix.len].result_type_id == metadata.type_id;
            },
            .take_index_local, .take_index_path_local, .take_path_local => return self.verifyCheckedTakeProjectionExpr(expr, root, steps),
            .local => return root == .binding,
            .handoff_local, .ref_local, .ref_alias_local, .ref_owned_local => return steps.len == 0 and root == .binding,
            .global_ref, .ref_global => |global_ref| return steps.len == 0 and root == .global and global_ref.decl_id == root.global,
            .ref_field_expr => |field| {
                if (steps.len == 0 or steps[steps.len - 1].step != .field) return false;
                const checked = steps[steps.len - 1];
                const owner_id = field.struct_decl_id orelse return false;
                const metadata = self.metadataForExpr(expr) orelse return false;
                return checked.step.field.owner_decl_id == owner_id and
                    std.mem.eql(u8, checked.step.field.name, field.field) and
                    checked.result_type_id == metadata.type_id and
                    self.verifyCheckedPlaceProjectionExpr(field.object, root, steps[0 .. steps.len - 1]);
            },
            .field, .borrowed_field => |field| {
                if (steps.len == 0 or steps[steps.len - 1].step != .field) return false;
                const checked = steps[steps.len - 1];
                const owner_id = field.struct_decl_id orelse return false;
                const metadata = self.metadataForExpr(expr) orelse return false;
                return checked.step.field.owner_decl_id == owner_id and
                    std.mem.eql(u8, checked.step.field.name, field.field) and
                    checked.result_type_id == metadata.type_id and
                    self.verifyCheckedPlaceProjectionExpr(field.object, root, steps[0 .. steps.len - 1]);
            },
            .tuple_field => |field| {
                if (steps.len == 0 or steps[steps.len - 1].step != .index) return false;
                const checked = steps[steps.len - 1];
                const metadata = self.metadataForExpr(expr) orelse return false;
                const position = std.math.cast(i64, field.index) orelse return false;
                return checked.step.index == .fixed and
                    checked.step.index.fixed == position and
                    checked.result_type_id == metadata.type_id and
                    self.verifyCheckedPlaceProjectionExpr(field.object, root, steps[0 .. steps.len - 1]);
            },
            .union_field, .borrowed_union_field => |field| {
                if (steps.len == 0 or steps[steps.len - 1].step != .union_payload) return false;
                const checked = steps[steps.len - 1];
                const owner_id = field.union_decl_id orelse return false;
                const metadata = self.metadataForExpr(expr) orelse return false;
                const payload = self.unionPayloadType(owner_id, field.field) orelse return false;
                return checked.step.union_payload.owner_decl_id == owner_id and
                    std.mem.eql(u8, checked.step.union_payload.name, field.field) and
                    checked.result_type_id == metadata.type_id and payload == metadata.type_id and
                    self.verifyCheckedPlaceProjectionExpr(field.object, root, steps[0 .. steps.len - 1]);
            },
            .index, .borrowed_index => |index| {
                if (steps.len == 0 or steps[steps.len - 1].step != .index) return false;
                const checked = steps[steps.len - 1];
                const index_matches = if (index.index.* == .int and index.index.int.value >= 0)
                    checked.step.index == .fixed and checked.step.index.fixed == index.index.int.value
                else
                    checked.step.index == .dynamic and checked.step.index.dynamic == index.index and
                        self.metadataForExpr(index.index) != null;
                const metadata = self.metadataForExpr(expr) orelse return false;
                return index_matches and checked.result_type_id == metadata.type_id and
                    self.verifyCheckedPlaceProjectionExpr(index.object, root, steps[0 .. steps.len - 1]);
            },
            .slice_range => |range| {
                if (steps.len == 0 or steps[steps.len - 1].step != .range) return false;
                const checked = steps[steps.len - 1];
                const metadata = self.metadataForExpr(expr) orelse return false;
                return checked.result_type_id == metadata.type_id and
                    self.checkedRangeBoundMatches(checked.step.range.start, range.start) and
                    self.checkedRangeBoundMatches(checked.step.range.end, range.end) and
                    self.verifyCheckedPlaceProjectionExpr(range.object, root, steps[0 .. steps.len - 1]);
            },
            else => return false,
        }
    }

    fn verifyCheckedTakeProjectionExpr(self: Module, expr: *const Expr, root: CheckedPlaceRoot, checked_steps: []const CheckedPlaceProjection) bool {
        if (root != .binding) return false;
        const types = if (self.canonical_types) |*value| value else return false;
        const metadata = self.metadataForExpr(expr) orelse return false;
        const raw_steps: []const TakePathStep = switch (expr.*) {
            .take_path_local => |take| take.steps,
            .take_index_local => &.{},
            .take_index_path_local => |take| take.steps,
            else => return false,
        };
        const final_index: ?*Expr = switch (expr.*) {
            .take_index_local => |take| take.index,
            .take_index_path_local => |take| take.index,
            else => null,
        };
        if (checked_steps.len != raw_steps.len + @intFromBool(final_index != null)) return false;
        var current_type = self.bindingType(root.binding) orelse return false;
        const root_node = types.get(current_type) catch return false;
        if (root_node.* == .ref_) current_type = root_node.ref_.target;
        for (raw_steps, checked_steps[0..raw_steps.len]) |raw, checked| {
            if (!self.verifyCheckedTakeStep(types, raw, checked, &current_type)) return false;
        }
        if (final_index) |index| {
            if (!self.verifyCheckedTakeStep(types, .{ .index = index }, checked_steps[checked_steps.len - 1], &current_type)) return false;
        }
        return current_type == metadata.type_id;
    }

    fn verifyCheckedReferencePathExpr(self: Module, expr: *const Expr, root: CheckedPlaceRoot, checked_steps: []const CheckedPlaceProjection) bool {
        if (root != .binding) return false;
        const types = if (self.canonical_types) |*value| value else return false;
        const metadata = self.metadataForExpr(expr) orelse return false;
        const result = types.get(metadata.type_id) catch return false;
        if (result.* != .ref_) return false;
        const raw_steps: []const TakePathStep = if (expr.* == .ref_path_local)
            expr.ref_path_local.steps
        else
            expr.ref_index_path_local.steps;
        const final_index: ?*Expr = if (expr.* == .ref_index_path_local) expr.ref_index_path_local.index else null;
        if (checked_steps.len == 0 or checked_steps.len != raw_steps.len + @intFromBool(final_index != null)) return false;
        var current_type = self.bindingType(root.binding) orelse return false;
        const root_node = types.get(current_type) catch return false;
        if (root_node.* == .ref_) current_type = root_node.ref_.target;
        for (raw_steps, 0..) |raw, index| {
            var checked = checked_steps[index];
            if (index + 1 == checked_steps.len) {
                checked.result_type_id = result.ref_.target;
                if (raw == .field) {
                    for (self.structs) |declaration| {
                        if (raw.field.struct_decl_id == null or declaration.decl_id != raw.field.struct_decl_id.?) continue;
                        for (declaration.fields) |decl_field| {
                            if (!std.mem.eql(u8, decl_field.name, raw.field.field)) continue;
                            const field_type = decl_field.type_id orelse break;
                            const field_node = types.get(field_type) catch return false;
                            if (field_node.* == .owned and field_node.owned == result.ref_.target)
                                checked.result_type_id = field_type;
                            break;
                        }
                        break;
                    }
                }
            }
            if (!self.verifyCheckedTakeStep(types, raw, checked, &current_type)) return false;
        }
        if (final_index) |index| {
            var checked = checked_steps[checked_steps.len - 1];
            checked.result_type_id = result.ref_.target;
            if (!self.verifyCheckedTakeStep(types, .{ .index = index }, checked, &current_type)) return false;
        }
        const final_node = types.get(current_type) catch return false;
        const target_type = if (final_node.* == .owned) final_node.owned else current_type;
        return target_type == result.ref_.target and checked_steps[checked_steps.len - 1].result_type_id == metadata.type_id;
    }

    fn verifyCheckedTakeStep(self: Module, types: *const semantic_types.TypeInterner, raw: TakePathStep, checked: CheckedPlaceProjection, current_type: *TypeId) bool {
        switch (raw) {
            .field => |field| {
                if (checked.step != .field or field.struct_decl_id == null or
                    checked.step.field.owner_decl_id != field.struct_decl_id.? or
                    !std.mem.eql(u8, checked.step.field.name, field.field)) return false;
                if (!checkedTakeOwnerMatches(types, current_type.*, field.struct_decl_id.?)) return false;
                for (self.structs) |declaration| {
                    if (declaration.decl_id != field.struct_decl_id) continue;
                    for (declaration.fields) |decl_field| {
                        if (!std.mem.eql(u8, decl_field.name, field.field)) continue;
                        current_type.* = decl_field.type_id orelse checked.result_type_id;
                        return checked.result_type_id == current_type.*;
                    }
                }
                return false;
            },
            .index => |index| {
                if (checked.step != .index) return false;
                const index_matches = if (index.* == .int and index.int.value >= 0)
                    checked.step.index == .fixed and checked.step.index.fixed == index.int.value
                else
                    checked.step.index == .dynamic and checked.step.index.dynamic == index and
                        self.metadataForExpr(index) != null;
                if (!index_matches) return false;
                var node = types.get(current_type.*) catch return false;
                if (node.* == .owned) node = types.get(node.owned) catch return false;
                current_type.* = switch (node.*) {
                    .array => |array| array.item,
                    .dense_array => |item| item,
                    .sparse_array => |item| blk: {
                        if (checked.result_type_id == item) break :blk item;
                        const optional = types.get(checked.result_type_id) catch return false;
                        if (optional.* != .optional or optional.optional != item) return false;
                        break :blk checked.result_type_id;
                    },
                    .slice => |slice| slice.item,
                    else => return false,
                };
                return checked.result_type_id == current_type.*;
            },
        }
    }

    fn verifySparseItemTransfer(self: Module, value: *const Expr, parent: identity.TemporaryId, key: CheckedIndex, maybe_record: ?Record) bool {
        const child = self.metadataForExpr(value) orelse return false;
        const moving = child.consumption.transfer == .move and
            (child.semantics.ownership == .owned or child.semantics.ownership == .shared);
        if (!moving) return maybe_record == null;
        const record = maybe_record orelse return false;
        record.validate() catch return false;
        return record.edge == .always and record.effect == .move and
            sameEffectSubject(record.effect.move.source, .{ .temporary = child.temporary_id orelse return false }) and
            sameEffectSubject(record.effect.move.destination, .{ .temporary_projection = .{
                .root = parent,
                .projection = .{ .step = .{ .index = key }, .result_type_id = child.type_id },
            } });
    }

    fn checkedTakeOwnerMatches(types: *const semantic_types.TypeInterner, type_id: TypeId, declaration_id: identity.DeclId) bool {
        var current = type_id;
        for (0..8) |_| {
            const node = types.get(current) catch return false;
            switch (node.*) {
                .owned => |target| current = target,
                .nominal => |nominal| {
                    if (nominal.kind == .type_alias and nominal.underlying != null) {
                        current = nominal.underlying.?;
                    } else return nominal.kind == .@"struct" and nominal.decl_id == declaration_id;
                },
                .generic_instance => |instance| return instance.kind == .@"struct" and
                    (instance.decl_id orelse instance.base_decl_id) == declaration_id,
                else => return false,
            }
        }
        return false;
    }

    fn checkedRangeBoundMatches(self: Module, checked: ?CheckedRangeBound, source: ?*Expr) bool {
        const expr = source orelse return checked == null;
        const bound = checked orelse return false;
        if (expr.* == .int and expr.int.value >= 0) return bound == .fixed and bound.fixed == expr.int.value;
        return bound == .dynamic and bound.dynamic == expr and self.metadataForExpr(expr) != null;
    }

    fn verifyStmtCompilerIdentities(
        self: Module,
        types: *const semantic_types.TypeInterner,
        statements: []const Stmt,
    ) VerifyCompilerIdentitiesError!void {
        for (statements) |stmt| switch (stmt) {
            .using_alloc => |using_alloc| try self.verifyStmtCompilerIdentities(types, using_alloc.body),
            .unchecked => |body| try self.verifyStmtCompilerIdentities(types, body),
            .@"if" => |if_stmt| {
                if ((if_stmt.capture_name == null) != (if_stmt.capture_binding_id == null) or
                    (if_stmt.capture_name != null and if_stmt.capture_type_id == null))
                {
                    return error.InvalidCaptureIdentity;
                }
                if (if_stmt.capture_path) |path| {
                    if (path.source) |origin| {
                        if (if_stmt.capture_name == null or !self.captureOriginMatches(if_stmt.condition, origin)) return error.InvalidCaptureIdentity;
                    } else if (self.captureSubjectHasIdentity(if_stmt.condition)) return error.InvalidCaptureIdentity;
                }
                if (if_stmt.capture_name == null and if_stmt.capture_path != null) return error.InvalidCaptureIdentity;
                switch (if_stmt.kind) {
                    .plain => if (if_stmt.capture_name != null or if_stmt.case_name != null or if_stmt.union_decl_id != null) return error.InvalidCaptureIdentity,
                    .optional_some, .optional_none => if (if_stmt.case_name != null or if_stmt.union_decl_id != null) return error.InvalidCaptureIdentity,
                    .union_case => if (if_stmt.case_name == null) return error.InvalidCaptureIdentity,
                }
                if (if_stmt.capture_name != null) {
                    const checked_case = (if_stmt.capture_path orelse return error.InvalidCaptureIdentity).active_case;
                    switch (if_stmt.kind) {
                        .optional_some => if (checked_case != .optional_some) return error.InvalidCaptureIdentity,
                        .union_case => {
                            if (self.hasUnionDecl(if_stmt.union_decl_id)) {
                                if (checked_case != .union_field) return error.InvalidCaptureIdentity;
                                const field = self.unionFieldAt(checked_case.union_field.owner_decl_id, checked_case.union_field.ordinal) orelse return error.InvalidCaptureIdentity;
                                if (checked_case.union_field.owner_decl_id != if_stmt.union_decl_id.? or
                                    !std.mem.eql(u8, field.name, if_stmt.case_name.?) or
                                    field.type_id != if_stmt.capture_type_id) return error.InvalidCaptureIdentity;
                            } else {
                                const subject = self.metadataForExpr(if_stmt.condition) orelse return error.MissingExpressionMetadata;
                                const subject_type = types.get(subject.type_id) catch return error.InvalidTypeIdentity;
                                if (subject_type.* == .result) {
                                    const result_case = language_contracts.resolveResultCase(if_stmt.case_name.?) orelse return error.InvalidResultCaseIdentity;
                                    if (checked_case != .result or checked_case.result != result_case) return error.InvalidCaptureIdentity;
                                }
                            }
                        },
                        else => return error.InvalidCaptureIdentity,
                    }
                    const subject = self.metadataForExpr(if_stmt.condition) orelse return error.MissingExpressionMetadata;
                    const expected_type: ?TypeId = switch (if_stmt.kind) {
                        .optional_some => blk: {
                            var node = types.get(subject.type_id) catch return error.InvalidTypeIdentity;
                            if (node.* == .ref_) node = types.get(node.ref_.target) catch return error.InvalidTypeIdentity;
                            break :blk if (node.* == .optional) node.optional else null;
                        },
                        .union_case => blk: {
                            if (self.hasUnionDecl(if_stmt.union_decl_id)) {
                                break :blk self.unionPayloadType(if_stmt.union_decl_id, if_stmt.case_name.?);
                            }
                            const typed_subject = self.metadataForExpr(if_stmt.condition) orelse return error.MissingExpressionMetadata;
                            const subject_type = types.get(typed_subject.type_id) catch return error.InvalidTypeIdentity;
                            if (subject_type.* != .result) break :blk null;
                            break :blk switch (language_contracts.resolveResultCase(if_stmt.case_name.?) orelse return error.InvalidResultCaseIdentity) {
                                .ok => subject_type.result.ok,
                                .err => subject_type.result.err,
                            };
                        },
                        else => null,
                    };
                    if (!(if_stmt.kind == .union_case and !self.hasUnionDecl(if_stmt.union_decl_id) and expected_type == null) and
                        (expected_type == null or if_stmt.capture_type_id != expected_type)) return error.InvalidCaptureIdentity;
                }
                try self.verifyStmtCompilerIdentities(types, if_stmt.then_body);
                try self.verifyStmtCompilerIdentities(types, if_stmt.else_body);
            },
            .@"while" => |while_stmt| try self.verifyStmtCompilerIdentities(types, while_stmt.body),
            .@"for" => |for_stmt| try self.verifyStmtCompilerIdentities(types, for_stmt.body),
            .@"switch" => |switch_stmt| {
                const metadata = self.metadataForExpr(switch_stmt.value) orelse return error.MissingExpressionMetadata;
                const node = types.get(metadata.type_id) catch return error.InvalidTypeIdentity;
                const is_result = node.* == .result;
                for (switch_stmt.cases) |case| {
                    if ((case.payload_name == null) != (case.payload_binding_id == null) or
                        (case.payload_name == null) != (case.payload_type_id == null)) return error.InvalidCaptureIdentity;
                    if (case.payload_path) |path| {
                        if (path.source) |origin| {
                            if (case.payload_name == null or !self.captureOriginMatches(switch_stmt.value, origin)) return error.InvalidCaptureIdentity;
                        } else if (self.captureSubjectHasIdentity(switch_stmt.value)) return error.InvalidCaptureIdentity;
                    }
                    if (case.payload_name == null and case.payload_path != null) return error.InvalidCaptureIdentity;
                    if (is_result != (case.result_case != null)) return error.InvalidResultCaseIdentity;
                    if (case.payload_type_id) |payload_type_id| {
                        const checked_case = (case.payload_path orelse return error.InvalidCaptureIdentity).active_case;
                        if (is_result) {
                            if (checked_case != .result or checked_case.result != case.result_case.?) return error.InvalidCaptureIdentity;
                        } else if (self.hasUnionDecl(switch_stmt.subject_decl_id)) {
                            if (checked_case != .union_field) return error.InvalidCaptureIdentity;
                            const field = self.unionFieldAt(checked_case.union_field.owner_decl_id, checked_case.union_field.ordinal) orelse return error.InvalidCaptureIdentity;
                            if (checked_case.union_field.owner_decl_id != switch_stmt.subject_decl_id.? or
                                !std.mem.eql(u8, field.name, case.case_name) or
                                field.type_id != payload_type_id) return error.InvalidCaptureIdentity;
                        } else if (node.* == .error_union) {
                            if (checked_case != .inline_error_union) return error.InvalidCaptureIdentity;
                            const inline_case = checked_case.inline_error_union;
                            if (inline_case.type_id != switch_stmt.subject_type_id.? or inline_case.ordinal >= node.error_union.len or
                                node.error_union[inline_case.ordinal] != payload_type_id or case.union_ordinal != inline_case.ordinal)
                                return error.InvalidCaptureIdentity;
                        }
                        _ = types.get(payload_type_id) catch return error.InvalidTypeIdentity;
                        const expected_type: ?TypeId = if (is_result)
                            (if (case.result_case.? == .ok) node.result.ok else node.result.err)
                        else
                            self.unionPayloadType(switch_stmt.subject_decl_id, case.case_name);
                        if (!(!is_result and !self.hasUnionDecl(switch_stmt.subject_decl_id)) and
                            (expected_type == null or payload_type_id != expected_type.?)) return error.InvalidCaptureIdentity;
                    }
                    try self.verifyStmtCompilerIdentities(types, case.body);
                }
                try self.verifyStmtCompilerIdentities(types, switch_stmt.else_body);
            },
            .yield => {},
            else => {},
        };
    }

    fn unionPayloadType(self: Module, maybe_decl_id: ?identity.DeclId, case_name: []const u8) ?TypeId {
        const decl_id = maybe_decl_id orelse return null;
        for (self.unions) |union_decl| {
            if (union_decl.decl_id != decl_id) continue;
            for (union_decl.fields) |field| {
                if (std.mem.eql(u8, field.name, case_name) and field.has_payload) return field.type_id;
            }
            return null;
        }
        return null;
    }

    fn hasUnionDecl(self: Module, maybe_decl_id: ?identity.DeclId) bool {
        const decl_id = maybe_decl_id orelse return false;
        for (self.unions) |union_decl| if (union_decl.decl_id == decl_id) return true;
        return false;
    }

    fn checkedRootExists(self: Module, root: CheckedPlaceRoot, binding_ids: *const std.AutoHashMapUnmanaged(identity.BindingId, void)) bool {
        return switch (root) {
            .global => |id| blk: {
                for (self.globals) |global| if (global.decl_id == id) break :blk true;
                break :blk false;
            },
            .binding => |id| blk: {
                if (binding_ids.contains(id)) break :blk true;
                for (self.functions) |function| {
                    for (function.params) |param| if (param.binding_id == id) break :blk true;
                    if (stmtSliceDeclaresBinding(function.body, id)) break :blk true;
                }
                break :blk false;
            },
        };
    }

    fn stmtSliceDeclaresBinding(statements: []const Stmt, id: identity.BindingId) bool {
        for (statements) |stmt| {
            switch (stmt) {
                .local => |local| if (local.binding_id == id) return true,
                .field_assign => |assign| if (assign.capture) |capture| {
                    if (capture.binding_id == id) return true;
                },
                .@"if" => |branch| {
                    if (branch.capture_binding_id == id or stmtSliceDeclaresBinding(branch.then_body, id) or stmtSliceDeclaresBinding(branch.else_body, id)) return true;
                },
                .@"switch" => |branch| {
                    for (branch.cases) |case| {
                        if (case.payload_binding_id == id or stmtSliceDeclaresBinding(case.body, id)) return true;
                    }
                    if (stmtSliceDeclaresBinding(branch.else_body, id)) return true;
                },
                .@"for" => |loop| {
                    if (loop.binding_id == id or stmtSliceDeclaresBinding(loop.body, id)) return true;
                },
                .@"while" => |loop| if (stmtSliceDeclaresBinding(loop.body, id)) return true,
                .using_alloc => |using_alloc| if (stmtSliceDeclaresBinding(using_alloc.body, id)) return true,
                .unchecked => |body| if (stmtSliceDeclaresBinding(body, id)) return true,
                else => {},
            }
            switch (stmt) {
                inline else => |payload| if (nestedExprDeclaresBinding(@TypeOf(payload), payload, id)) return true,
            }
        }
        return false;
    }

    fn nestedExprDeclaresBinding(comptime T: type, value: T, id: identity.BindingId) bool {
        if (comptime T == Record) return false;
        if (comptime T == *Expr or T == *const Expr) return nestedExprDeclaresBinding(Expr, value.*, id);
        if (comptime T == Expr) {
            if (value == .@"switch") {
                const branch = value.@"switch";
                for (branch.cases) |case| {
                    if (case.payload_binding_id == id or stmtSliceDeclaresBinding(case.body, id)) return true;
                }
                if (stmtSliceDeclaresBinding(branch.else_body, id)) return true;
            }
            return switch (value) {
                inline else => |payload| nestedExprDeclaresBinding(@TypeOf(payload), payload, id),
            };
        }
        return switch (@typeInfo(T)) {
            .pointer => |pointer| blk: {
                if (comptime pointer.child == u8) break :blk false;
                if (pointer.size == .slice) {
                    for (value) |item| if (nestedExprDeclaresBinding(pointer.child, item, id)) break :blk true;
                } else if (pointer.size == .one) {
                    break :blk nestedExprDeclaresBinding(pointer.child, value.*, id);
                }
                break :blk false;
            },
            .optional => |optional| if (value) |item| nestedExprDeclaresBinding(optional.child, item, id) else false,
            .array => |array| blk: {
                for (value) |item| if (nestedExprDeclaresBinding(array.child, item, id)) break :blk true;
                break :blk false;
            },
            .@"struct" => |record| blk: {
                inline for (record.field_names, record.field_types) |name, field_type| {
                    if (nestedExprDeclaresBinding(field_type, @field(value, name), id)) break :blk true;
                }
                break :blk false;
            },
            .@"union" => switch (value) {
                inline else => |payload| nestedExprDeclaresBinding(@TypeOf(payload), payload, id),
            },
            else => false,
        };
    }

    fn checkUniqueBindingId(seen: *std.AutoHashMapUnmanaged(identity.BindingId, void), id: identity.BindingId) VerifyCompilerIdentitiesError!void {
        if (@backingInt(id) >= (@as(u64, 1) << 62)) return error.InvalidBindingIdentity;
        const result = try seen.getOrPut(std.heap.page_allocator, id);
        if (result.found_existing) return error.InvalidBindingIdentity;
    }

    fn checkStatementBindingIds(seen: *std.AutoHashMapUnmanaged(identity.BindingId, void), statements: []const Stmt) VerifyCompilerIdentitiesError!void {
        for (statements) |stmt| switch (stmt) {
            .local => |local| if (local.binding_id) |id| try checkUniqueBindingId(seen, id),
            .field_assign => |assign| if (assign.capture) |capture| try checkUniqueBindingId(seen, capture.binding_id),
            .@"if" => |branch| {
                if (branch.capture_binding_id) |id| try checkUniqueBindingId(seen, id);
                try checkStatementBindingIds(seen, branch.then_body);
                try checkStatementBindingIds(seen, branch.else_body);
            },
            .@"switch" => |branch| {
                for (branch.cases) |case| {
                    if (case.payload_binding_id) |id| try checkUniqueBindingId(seen, id);
                    try checkStatementBindingIds(seen, case.body);
                }
                try checkStatementBindingIds(seen, branch.else_body);
            },
            .@"for" => |loop| {
                if (loop.binding_id) |id| try checkUniqueBindingId(seen, id);
                try checkStatementBindingIds(seen, loop.body);
            },
            .@"while" => |loop| try checkStatementBindingIds(seen, loop.body),
            .using_alloc => |using_alloc| try checkStatementBindingIds(seen, using_alloc.body),
            .unchecked => |body| try checkStatementBindingIds(seen, body),
            else => {},
        };
    }

    fn verifyScopedStatements(self: Module, scope: *std.ArrayListUnmanaged(ScopedBinding), statements: []const Stmt) VerifyCompilerIdentitiesError!void {
        const base = scope.items.len;
        defer scope.items.len = base;
        for (statements) |stmt| switch (stmt) {
            .local => |local| {
                try self.verifyScopedExpr(scope.items, local.init);
                if (local.binding_mode == .projected) {
                    const place = local.projected_place orelse return error.InvalidBindingIdentity;
                    if (!place.non_owning or place.root != .binding or
                        place.projections == null or place.projections.?.len == 0 or
                        local.binding_id == null or local.binding_id == place.root.binding)
                    {
                        return error.InvalidBindingIdentity;
                    }
                    var root_in_scope = false;
                    for (scope.items) |entry| {
                        if (entry.id == place.root.binding) root_in_scope = true;
                    }
                    if (!root_in_scope) return error.InvalidBindingIdentity;
                    for (place.projections.?) |projection| switch (projection.step) {
                        .field, .union_payload, .index => {},
                        else => return error.InvalidBindingIdentity,
                    };
                } else if (local.projected_place != null) return error.InvalidBindingIdentity;
                if (local.binding_id) |id| try scope.append(std.heap.page_allocator, .{ .name = local.name, .id = id });
            },
            .assign => |assign| {
                var expected_id: ?identity.BindingId = null;
                var index = scope.items.len;
                while (index > 0) {
                    index -= 1;
                    if (!std.mem.eql(u8, scope.items[index].name, assign.name)) continue;
                    expected_id = scope.items[index].id;
                    break;
                }
                if (assign.binding_id != expected_id) return error.InvalidBindingIdentity;
                try self.verifyScopedExpr(scope.items, assign.value);
            },
            .field_assign => |assign| {
                var expected_id: ?identity.BindingId = null;
                var index = scope.items.len;
                while (index > 0) {
                    index -= 1;
                    if (!std.mem.eql(u8, scope.items[index].name, assign.root_name)) continue;
                    expected_id = scope.items[index].id;
                    break;
                }
                if (assign.root_binding_id != expected_id) return error.InvalidBindingIdentity;
                try self.verifyScopedExpr(scope.items, assign.value);
                if (assign.capture) |capture| try scope.append(std.heap.page_allocator, .{ .name = capture.name, .id = capture.binding_id });
            },
            .index_assign => |assign| {
                try self.verifyScopedExpr(scope.items, assign.object);
                try self.verifyScopedExpr(scope.items, assign.index);
                try self.verifyScopedExpr(scope.items, assign.value);
            },
            .drop => |drop| {
                var expected_id: ?identity.BindingId = null;
                var index = scope.items.len;
                while (index > 0) {
                    index -= 1;
                    if (!std.mem.eql(u8, scope.items[index].name, drop.name)) continue;
                    expected_id = scope.items[index].id;
                    break;
                }
                if (drop.binding_id != expected_id) return error.InvalidBindingIdentity;
            },
            .deref_assign => |assign| {
                try self.verifyScopedExpr(scope.items, assign.pointer);
                try self.verifyScopedExpr(scope.items, assign.value);
            },
            .deref_field_assign => |assign| {
                try self.verifyScopedExpr(scope.items, assign.pointer);
                try self.verifyScopedExpr(scope.items, assign.value);
            },
            .using_alloc => |using_alloc| {
                try self.verifyScopedExpr(scope.items, using_alloc.allocator_expr);
                try self.verifyScopedStatements(scope, using_alloc.body);
            },
            .unchecked => |body| try self.verifyScopedStatements(scope, body),
            .asm_stmt => |asm_stmt| for (asm_stmt.inputs) |input| try self.verifyScopedExpr(scope.items, input.value),
            .@"if" => |branch| {
                try self.verifyScopedExpr(scope.items, branch.condition);
                const branch_base = scope.items.len;
                if (branch.kind != .optional_none) if (branch.capture_name) |name| {
                    if (branch.capture_binding_id) |id| try scope.append(std.heap.page_allocator, .{ .name = name, .id = id });
                };
                try self.verifyScopedStatements(scope, branch.then_body);
                scope.items.len = branch_base;
                if (branch.kind == .optional_none) if (branch.capture_name) |name| {
                    if (branch.capture_binding_id) |id| try scope.append(std.heap.page_allocator, .{ .name = name, .id = id });
                };
                try self.verifyScopedStatements(scope, branch.else_body);
                scope.items.len = branch_base;
            },
            .@"while" => |loop| {
                try self.verifyScopedExpr(scope.items, loop.condition);
                try self.verifyScopedStatements(scope, loop.body);
            },
            .@"for" => |loop| {
                try self.verifyScopedExpr(scope.items, loop.iterable);
                const loop_base = scope.items.len;
                if (loop.binding_id) |id| try scope.append(std.heap.page_allocator, .{ .name = loop.name, .id = id });
                try self.verifyScopedStatements(scope, loop.body);
                scope.items.len = loop_base;
            },
            .@"switch" => |branch| {
                try self.verifyScopedExpr(scope.items, branch.value);
                for (branch.cases) |case| {
                    const case_base = scope.items.len;
                    if (case.payload_name) |name| if (case.payload_binding_id) |id| {
                        try scope.append(std.heap.page_allocator, .{ .name = name, .id = id });
                    };
                    try self.verifyScopedStatements(scope, case.body);
                    scope.items.len = case_base;
                }
                try self.verifyScopedStatements(scope, branch.else_body);
            },
            .@"try" => |attempt| try self.verifyScopedExpr(scope.items, attempt.expr),
            .@"defer", .expr => |expr| try self.verifyScopedExpr(scope.items, expr),
            .@"return", .yield => |maybe_expr| if (maybe_expr) |expr| try self.verifyScopedExpr(scope.items, expr),
            .@"continue", .@"break" => {},
        };
    }

    fn verifyScopedExpr(self: Module, scope: []const ScopedBinding, expr: *const Expr) VerifyCompilerIdentitiesError!void {
        if (self.metadataForExpr(expr)) |metadata| {
            if ((expr.* == .global_ref or expr.* == .ref_global) and
                metadata.checked_place_root != null and metadata.checked_place_root.? != .global)
            {
                return error.InvalidCheckedPlaceRoot;
            }
            if (metadata.checked_place_root) |root| switch (root) {
                .binding => |id| if (scopedRootName(expr)) |name| {
                    var index = scope.len;
                    var found = false;
                    while (index > 0) {
                        index -= 1;
                        if (!std.mem.eql(u8, scope[index].name, name)) continue;
                        if (scope[index].id != id) {
                            const projected = self.projectedBindingPlace(scope[index].id) orelse return error.InvalidCheckedPlaceRoot;
                            if (!std.meta.eql(projected.root, root)) return error.InvalidCheckedPlaceRoot;
                            const prefix = projected.projections orelse return error.InvalidCheckedPlaceRoot;
                            const actual = metadata.checked_place_projections orelse return error.InvalidCheckedPlaceRoot;
                            if (actual.len < prefix.len or (expr.* == .local and actual.len != prefix.len)) return error.InvalidCheckedPlaceRoot;
                            for (actual[0..prefix.len], prefix) |step, expected| {
                                if (!std.meta.eql(step, expected)) return error.InvalidCheckedPlaceRoot;
                            }
                        } else if (expr.* == .local and metadata.checked_place_projections != null) {
                            return error.InvalidCheckedPlaceProjection;
                        }
                        found = true;
                        break;
                    }
                    if (!found) return error.InvalidCheckedPlaceRoot;
                },
                .global => |decl_id| {
                    const named = self.globalPlaceIdentity(expr);
                    if (named == null) {
                        if (metadata.checked_place_projections == null) return error.MissingPlaceIdentity;
                    } else if (named.? != decl_id) {
                        return error.InvalidCheckedPlaceRoot;
                    }
                },
            };
        }
        if (expr.* == .@"switch") {
            const branch = expr.@"switch";
            try self.verifyScopedExpr(scope, branch.value);
            var arm_scope: std.ArrayListUnmanaged(ScopedBinding) = .empty;
            defer arm_scope.deinit(std.heap.page_allocator);
            try arm_scope.appendSlice(std.heap.page_allocator, scope);
            for (branch.cases) |case| {
                const base = arm_scope.items.len;
                if (case.payload_name) |name| if (case.payload_binding_id) |id| {
                    try arm_scope.append(std.heap.page_allocator, .{ .name = name, .id = id });
                };
                try self.verifyScopedStatements(&arm_scope, case.body);
                arm_scope.items.len = base;
            }
            try self.verifyScopedStatements(&arm_scope, branch.else_body);
            return;
        }
        try self.verifyNestedExprs(scope, Expr, expr.*);
    }

    fn globalPlaceIdentity(self: Module, expr: *const Expr) ?identity.DeclId {
        switch (expr.*) {
            .global_ref, .ref_global => |global_ref| return global_ref.decl_id,
            .field, .borrowed_field => |field| return self.globalPlaceIdentity(field.object),
            .tuple_field => |field| return self.globalPlaceIdentity(field.object),
            .ref_field_expr => |field| return self.globalPlaceIdentity(field.object),
            .union_field, .borrowed_union_field => |field| return self.globalPlaceIdentity(field.object),
            .index, .borrowed_index => |index| return self.globalPlaceIdentity(index.object),
            .slice_range => |range| return self.globalPlaceIdentity(range.object),
            else => return null,
        }
    }

    fn scopedRootName(expr: *const Expr) ?[]const u8 {
        return switch (expr.*) {
            .local, .handoff_local, .ref_local, .ref_alias_local, .ref_owned_local, .raw_owned_local, .leak_owned_local => |name| name,
            .field, .borrowed_field => |field| scopedRootName(field.object),
            .tuple_field => |field| scopedRootName(field.object),
            .union_field, .borrowed_union_field => |field| scopedRootName(field.object),
            .index, .borrowed_index => |index| scopedRootName(index.object),
            .ref_field_expr => |field| scopedRootName(field.object),
            .ref_field_local, .ref_field_owned_local => |field| field.local_name,
            .ref_union_field_local => |field| field.local_name,
            .ref_index_local => |index| index.local_name,
            .ref_index_path_local, .take_index_path_local => |path| path.local_name,
            .ref_path_local, .take_path_local => |path| path.local_name,
            .take_index_local => |index| index.local_name,
            else => null,
        };
    }

    fn verifyNestedExprs(self: Module, scope: []const ScopedBinding, comptime T: type, value: T) VerifyCompilerIdentitiesError!void {
        // Checked effects describe ownership edges and may refer back to the
        // expression being checked. Scope validation only walks source exprs.
        if (comptime T == Record) return;
        if (comptime T == *Expr or T == *const Expr) {
            try self.verifyScopedExpr(scope, value);
            return;
        }
        if (comptime T == Expr) {
            switch (value) {
                inline else => |payload| try self.verifyNestedExprs(scope, @TypeOf(payload), payload),
            }
            return;
        }
        switch (@typeInfo(T)) {
            .pointer => |pointer| {
                if (comptime pointer.child == u8) return;
                if (pointer.size == .slice) {
                    for (value) |item| try self.verifyNestedExprs(scope, pointer.child, item);
                } else if (pointer.size == .one) {
                    try self.verifyNestedExprs(scope, pointer.child, value.*);
                }
            },
            .optional => |optional| if (value) |item| try self.verifyNestedExprs(scope, optional.child, item),
            .array => |array| for (value) |item| try self.verifyNestedExprs(scope, array.child, item),
            .@"struct" => |record| inline for (record.field_names, record.field_types) |name, field_type| try self.verifyNestedExprs(scope, field_type, @field(value, name)),
            .@"union" => switch (value) {
                inline else => |payload| try self.verifyNestedExprs(scope, @TypeOf(payload), payload),
            },
            else => {},
        }
    }

    fn unionFieldAt(self: Module, decl_id: identity.DeclId, ordinal: u32) ?UnionField {
        for (self.unions) |union_decl| {
            if (union_decl.decl_id != decl_id) continue;
            if (ordinal >= union_decl.fields.len) return null;
            return union_decl.fields[ordinal];
        }
        return null;
    }

    fn captureOriginMatches(self: Module, expr: *const Expr, origin: CheckedCaptureOrigin) bool {
        const metadata = self.metadataForExpr(expr) orelse return false;
        return switch (origin) {
            .place => |place| blk: {
                const checked = metadata.checked_place_root orelse break :blk false;
                if (!std.meta.eql(place.root, checked) or place.non_owning != metadata.non_owning_place_origin) break :blk false;
                const projections = metadata.checked_place_projections;
                if ((place.projections == null) != (projections == null)) break :blk false;
                if (place.projections) |steps| {
                    if (steps.len != projections.?.len or steps.ptr != projections.?.ptr) break :blk false;
                }
                break :blk true;
            },
            .temporary => |temporary_id| metadata.temporary_id == temporary_id,
        };
    }

    fn captureSubjectHasIdentity(self: Module, expr: *const Expr) bool {
        const metadata = self.metadataForExpr(expr) orelse return false;
        return metadata.checked_place_root != null or metadata.temporary_id != null;
    }

    fn intrinsicForDeclId(self: Module, maybe_decl_id: ?identity.DeclId) ?IntrinsicId {
        const decl_id = maybe_decl_id orelse return null;
        for (self.functions) |function| {
            if (function.decl_id != decl_id) continue;
            return intrinsics.resolveDeclaration(function.module_name, function.owner, function.name) orelse function.syntax_intrinsic_id;
        }
        return null;
    }

    pub fn exprIsLive(self: Module, target: *const Expr) bool {
        for (self.globals) |global| {
            if (global.init) |init| {
                if (exprContains(init, target)) return true;
            }
        }
        for (self.functions) |function| {
            if (stmtSliceContainsExpr(function.body, target)) return true;
        }
        return false;
    }

    pub fn liveExprSet(self: Module, allocator: std.mem.Allocator) error{OutOfMemory}!std.AutoHashMapUnmanaged(*const Expr, void) {
        var live: std.AutoHashMapUnmanaged(*const Expr, void) = .empty;
        errdefer live.deinit(allocator);
        for (self.globals) |global| {
            if (global.init) |init| try collectLiveExprs(allocator, &live, *const Expr, init);
        }
        for (self.functions) |function| try collectLiveExprs(allocator, &live, []const Stmt, function.body);
        return live;
    }

    fn collectLiveExprs(
        allocator: std.mem.Allocator,
        live: *std.AutoHashMapUnmanaged(*const Expr, void),
        comptime T: type,
        value: T,
    ) error{OutOfMemory}!void {
        if (comptime T == Record) return;
        if (comptime T == *Expr or T == *const Expr) {
            if (live.contains(value)) return;
            try live.put(allocator, value, {});
            try collectLiveExprs(allocator, live, Expr, value.*);
            return;
        }
        switch (@typeInfo(T)) {
            .pointer => |pointer| {
                if (comptime pointer.child == u8) return;
                if (pointer.size == .slice) {
                    for (value) |item| try collectLiveExprs(allocator, live, pointer.child, item);
                } else if (pointer.size == .one) {
                    try collectLiveExprs(allocator, live, pointer.child, value.*);
                }
            },
            .optional => |optional| if (value) |item| try collectLiveExprs(allocator, live, optional.child, item),
            .array => |array| for (value) |item| try collectLiveExprs(allocator, live, array.child, item),
            .@"struct" => |record| inline for (record.field_names, record.field_types) |name, field_type| try collectLiveExprs(allocator, live, field_type, @field(value, name)),
            .@"union" => switch (value) {
                inline else => |payload| try collectLiveExprs(allocator, live, @TypeOf(payload), payload),
            },
            else => {},
        }
    }

    pub fn verifyValueActions(self: Module) VerifyValueActionsError!void {
        return self.verifyValueActionsWithAllocator(std.heap.page_allocator);
    }

    fn verifyValueActionsWithAllocator(self: Module, allocator: std.mem.Allocator) VerifyValueActionsError!void {
        var expressions: std.AutoHashMapUnmanaged(*const Expr, void) = .empty;
        defer expressions.deinit(allocator);
        for (self.expr_metadata) |entry| {
            if (!entry.metadata.semantics.isValid() or !entry.metadata.consumption.isValid(entry.metadata.semantics)) {
                return error.InvalidExpressionMetadata;
            }
            if (entry.expr.* == .local or entry.expr.* == .global_ref) {
                const place = entry.metadata.checkedPlacePath() orelse return error.InvalidCheckedEffect;
                const record = entry.metadata.checked_effect orelse return error.InvalidCheckedEffect;
                record.validate() catch return error.InvalidCheckedEffect;
                if (record.edge != .always or record.effect != .read or
                    !sameEffectSubject(record.effect.read, .{ .place = place }))
                    return error.InvalidCheckedEffect;
            }
            if (entry.expr.* == .ref_load) {
                const reference = entry.expr.ref_load;
                const reference_metadata = self.metadataForExpr(reference) orelse return error.InvalidCheckedEffect;
                const types = if (self.canonical_types) |*value| value else return error.InvalidCheckedEffect;
                const reference_type = types.get(reference_metadata.type_id) catch return error.InvalidCheckedEffect;
                if (reference_type.* != .ref_ or reference_type.ref_.target != entry.metadata.type_id)
                    return error.InvalidCheckedEffect;
                const record = entry.metadata.checked_effect orelse return error.InvalidCheckedEffect;
                record.validate() catch return error.InvalidCheckedEffect;
                if (record.edge != .always or record.effect != .read or
                    !sameEffectSubject(record.effect.read, .{ .reference_target = .{
                        .reference = reference,
                        .target_type_id = entry.metadata.type_id,
                    } })) return error.InvalidCheckedEffect;
            }
            if (entry.expr.* == .string_bytes) {
                const source = self.metadataForExpr(entry.expr.string_bytes) orelse return error.InvalidCheckedEffect;
                const subject: Subject = if (source.checkedPlacePath()) |place|
                    .{ .place = place }
                else if (source.temporary_id) |temporary|
                    .{ .temporary = temporary }
                else
                    return error.InvalidCheckedEffect;
                const record = entry.metadata.checked_effect orelse return error.InvalidCheckedEffect;
                record.validate() catch return error.InvalidCheckedEffect;
                if (record.edge != .always or record.effect != .borrow or
                    !sameEffectSubject(record.effect.borrow, subject)) return error.InvalidCheckedEffect;
            }
            const neutral_helper = switch (entry.expr.*) {
                .sequence_len, .sparse_len, .sparse_contains_index, .string_len, .string_is_empty, .string_starts_with, .string_ends_with, .string_contains, .string_find, .string_rfind, .slice_len, .slice_ptr => true,
                else => false,
            };
            if (neutral_helper and entry.metadata.checked_effect != null)
                return error.InvalidCheckedEffect;
            const neutral_scalar = switch (entry.expr.*) {
                .int, .float, .rune, .bool, .none, .enum_case, .function_ref, .binary, .test_assert, .builtin_print => true,
                .unary => |unary| unary.op != .copy_list,
                else => false,
            };
            if (neutral_scalar and entry.metadata.checked_effect != null)
                return error.InvalidCheckedEffect;
            const projected_access: ?bool = switch (entry.expr.*) {
                .field, .union_field, .index => false,
                .borrowed_field, .borrowed_union_field, .borrowed_index => true,
                .tuple_field => entry.metadata.semantics.category == .borrowed_projection,
                else => null,
            };
            if (projected_access) |borrowed| {
                if (entry.metadata.checkedPlacePath()) |place| {
                    const record = entry.metadata.checked_effect orelse return error.InvalidCheckedEffect;
                    record.validate() catch return error.InvalidCheckedEffect;
                    if (record.edge != .always) return error.InvalidCheckedEffect;
                    if (borrowed) {
                        if (record.effect != .borrow or !sameEffectSubject(record.effect.borrow, .{ .place = place }))
                            return error.InvalidCheckedEffect;
                    } else if (record.effect != .read or !sameEffectSubject(record.effect.read, .{ .place = place })) {
                        return error.InvalidCheckedEffect;
                    }
                } else if (entry.metadata.checked_effect != null) return error.InvalidCheckedEffect;
            }
            const borrow_access = switch (entry.expr.*) {
                .ref_local, .ref_global, .ref_alias_local, .ref_owned_local, .ref_field_local, .ref_field_owned_local, .ref_index_local, .ref_path_local, .ref_index_path_local, .ref_field_expr, .ref_union_field_local, .slice_range => true,
                else => false,
            };
            if (borrow_access) {
                if (entry.metadata.checkedPlacePath()) |place| {
                    const record = entry.metadata.checked_effect orelse return error.InvalidCheckedEffect;
                    record.validate() catch return error.InvalidCheckedEffect;
                    if (record.edge != .always or record.effect != .borrow or
                        !sameEffectSubject(record.effect.borrow, .{ .place = place }))
                        return error.InvalidCheckedEffect;
                } else if (entry.expr.* == .ref_field_expr and entry.expr.ref_field_expr.object.* != .ref_raw_deref) {
                    const field = entry.expr.ref_field_expr;
                    const owner_id = field.struct_decl_id orelse return error.InvalidCheckedEffect;
                    const child_metadata = self.metadataForExpr(field.object) orelse return error.InvalidCheckedEffect;
                    const types = if (self.canonical_types) |*value| value else return error.InvalidCheckedEffect;
                    const child_type = types.get(child_metadata.type_id) catch return error.InvalidCheckedEffect;
                    const result_type = types.get(entry.metadata.type_id) catch return error.InvalidCheckedEffect;
                    if (child_type.* != .ref_ or result_type.* != .ref_ or
                        !checkedTakeOwnerMatches(types, child_type.ref_.target, owner_id)) return error.InvalidCheckedEffect;
                    var field_valid = false;
                    for (self.structs) |declaration| {
                        if (declaration.decl_id != owner_id) continue;
                        for (declaration.fields) |decl_field| {
                            if (!std.mem.eql(u8, decl_field.name, field.field)) continue;
                            field_valid = decl_field.type_id == null or decl_field.type_id.? == result_type.ref_.target;
                        }
                    }
                    if (!field_valid) return error.InvalidCheckedEffect;
                    const record = entry.metadata.checked_effect orelse return error.InvalidCheckedEffect;
                    record.validate() catch return error.InvalidCheckedEffect;
                    if (record.edge != .always or record.effect != .borrow or
                        !sameEffectSubject(record.effect.borrow, .{ .reference_projection = .{
                            .reference = field.object,
                            .projection = .{ .step = .{ .field = .{
                                .owner_decl_id = owner_id,
                                .name = field.field,
                            } }, .result_type_id = entry.metadata.type_id },
                        } })) return error.InvalidCheckedEffect;
                } else if (entry.metadata.checked_effect != null) return error.InvalidCheckedEffect;
            }
            if (entry.expr.* == .handoff_local) {
                const record = entry.metadata.checked_effect orelse return error.InvalidCheckedEffect;
                const path = entry.metadata.checkedPlacePath() orelse return error.InvalidCheckedEffect;
                const temporary = entry.metadata.temporary_id orelse return error.InvalidCheckedEffect;
                record.validate() catch return error.InvalidCheckedEffect;
                if (record.edge != .always or record.effect != .move or
                    !sameEffectSubject(record.effect.move.source, .{ .place = path }) or
                    record.effect.move.source.place.non_owning != path.non_owning or
                    !sameEffectSubject(record.effect.move.destination, .{ .temporary = temporary }))
                {
                    return error.InvalidCheckedEffect;
                }
            }
            if (entry.expr.* == .raw_owned_local or entry.expr.* == .leak_owned_local) {
                const path = entry.metadata.checkedPlacePath() orelse return error.InvalidCheckedEffect;
                if (path.root != .binding or path.projections != null or path.non_owning) return error.InvalidCheckedEffect;
                const record = entry.metadata.checked_effect orelse return error.InvalidCheckedEffect;
                record.validate() catch return error.InvalidCheckedEffect;
                if (record.edge != .always) return error.InvalidCheckedEffect;
                if (entry.expr.* == .raw_owned_local) {
                    if (record.effect != .borrow or !sameEffectSubject(record.effect.borrow, .{ .place = path }))
                        return error.InvalidCheckedEffect;
                } else if (record.effect != .leak or !sameEffectSubject(record.effect.leak, .{ .place = path })) {
                    return error.InvalidCheckedEffect;
                }
            }
            const owning_aggregate = entry.metadata.semantics.ownership == .owned or entry.metadata.semantics.ownership == .shared;
            const aggregate = switch (entry.expr.*) {
                .struct_literal, .union_case, .array_literal, .tuple_literal, .array_default, .dense_array_literal, .sparse_literal, .sparse_keyed_literal => true,
                else => false,
            };
            const materializes = switch (entry.expr.*) {
                .new_owned, .new_array, .new_sparse, .sparse_indices, .string, .string_from, .string_slice, .interpolated_string => true,
                .unary => |unary| unary.op == .copy_list,
                .struct_literal, .union_case, .array_literal, .tuple_literal, .array_default, .dense_array_literal, .sparse_literal, .sparse_keyed_literal => owning_aggregate,
                else => false,
            };
            if (materializes) {
                const record = entry.metadata.checked_effect orelse return error.InvalidCheckedEffect;
                const temporary = entry.metadata.temporary_id orelse return error.InvalidCheckedEffect;
                record.validate() catch return error.InvalidCheckedEffect;
                const expected_ownership: Ownership = switch (entry.expr.*) {
                    .string, .string_from, .string_slice, .interpolated_string => .shared,
                    else => .owned,
                };
                if ((!aggregate and entry.metadata.semantics.ownership != expected_ownership) or
                    (aggregate and !owning_aggregate) or record.edge != .always or
                    record.effect != .materialize or
                    !sameEffectSubject(record.effect.materialize, .{ .temporary = temporary }))
                {
                    return error.InvalidCheckedEffect;
                }
            } else if (aggregate and entry.metadata.checked_effect != null) {
                return error.InvalidCheckedEffect;
            }
            if (entry.expr.* == .take_path_local or entry.expr.* == .take_index_local or
                entry.expr.* == .take_index_path_local)
            {
                const moving = entry.metadata.semantics.ownership == .owned or entry.metadata.semantics.ownership == .shared;
                if (!moving) {
                    if (entry.metadata.checked_effect != null) return error.InvalidCheckedEffect;
                } else {
                    const record = entry.metadata.checked_effect orelse return error.InvalidCheckedEffect;
                    const path = entry.metadata.checkedPlacePath() orelse return error.InvalidCheckedEffect;
                    const temporary = entry.metadata.temporary_id orelse return error.InvalidCheckedEffect;
                    record.validate() catch return error.InvalidCheckedEffect;
                    const expected_projection_len: usize = switch (entry.expr.*) {
                        .take_path_local => |take| take.steps.len,
                        .take_index_local => 1,
                        .take_index_path_local => |take| take.steps.len + 1,
                        else => unreachable,
                    };
                    if (record.edge != .always or record.effect != .take or
                        (expected_projection_len == 0 and path.projections != null) or
                        (expected_projection_len != 0 and (path.projections == null or path.projections.?.len != expected_projection_len)) or
                        !sameEffectSubject(record.effect.take.source, .{ .place = path }) or
                        !sameEffectSubject(record.effect.take.destination, .{ .temporary = temporary }))
                        return error.InvalidCheckedEffect;
                }
            }
            if (entry.expr.* == .sparse_take) {
                const moving = entry.metadata.semantics.ownership == .owned or entry.metadata.semantics.ownership == .shared;
                if (!moving) {
                    if (entry.metadata.checked_effect != null) return error.InvalidCheckedEffect;
                } else {
                    const record = entry.metadata.checked_effect orelse return error.InvalidCheckedEffect;
                    const path = entry.metadata.checkedPlacePath() orelse return error.InvalidCheckedEffect;
                    const temporary = entry.metadata.temporary_id orelse return error.InvalidCheckedEffect;
                    record.validate() catch return error.InvalidCheckedEffect;
                    if (record.edge != .always or record.effect != .take or
                        !sameEffectSubject(record.effect.take.source, .{ .place = path }) or
                        !sameEffectSubject(record.effect.take.destination, .{ .temporary = temporary }))
                        return error.InvalidCheckedEffect;
                }
            }
            if (entry.expr.* == .new_owned or entry.expr.* == .struct_literal) {
                const literal = switch (entry.expr.*) {
                    .new_owned => |value| value,
                    .struct_literal => |value| value,
                    else => unreachable,
                };
                for (literal.fields) |field| {
                    const child = self.metadataForExpr(field.value) orelse return error.InvalidCheckedEffect;
                    const moving = child.consumption.transfer == .move and
                        (child.semantics.ownership == .owned or child.semantics.ownership == .shared);
                    if (!moving) {
                        if (field.checked_transfer != null) return error.InvalidCheckedEffect;
                        continue;
                    }
                    const record = field.checked_transfer orelse return error.InvalidCheckedEffect;
                    const parent = entry.metadata.temporary_id orelse return error.InvalidCheckedEffect;
                    const declaration = literal.decl_id orelse return error.InvalidCheckedEffect;
                    const source = child.temporary_id orelse return error.InvalidCheckedEffect;
                    record.validate() catch return error.InvalidCheckedEffect;
                    if (record.edge != .always or record.effect != .move or
                        !sameEffectSubject(record.effect.move.source, .{ .temporary = source }) or
                        !sameEffectSubject(record.effect.move.destination, .{ .temporary_projection = .{
                            .root = parent,
                            .projection = .{
                                .step = .{ .field = .{ .owner_decl_id = declaration, .name = field.name } },
                                .result_type_id = child.type_id,
                            },
                        } })) return error.InvalidCheckedEffect;
                }
            }
            if (entry.expr.* == .array_literal or entry.expr.* == .dense_array_literal) {
                const literal = switch (entry.expr.*) {
                    .array_literal => |value| value,
                    .dense_array_literal => |value| value,
                    else => unreachable,
                };
                var any_moving = false;
                for (literal.items) |item| {
                    const child = self.metadataForExpr(item) orelse return error.InvalidCheckedEffect;
                    if (child.consumption.transfer == .move and
                        (child.semantics.ownership == .owned or child.semantics.ownership == .shared)) any_moving = true;
                }
                if (!any_moving) {
                    if (literal.checked_transfers != null) return error.InvalidCheckedEffect;
                } else {
                    const records = literal.checked_transfers orelse return error.InvalidCheckedEffect;
                    if (records.len != literal.items.len) return error.InvalidCheckedEffect;
                    const parent = entry.metadata.temporary_id orelse return error.InvalidCheckedEffect;
                    for (literal.items, records, 0..) |item, maybe_record, slot_index| {
                        const child = self.metadataForExpr(item) orelse return error.InvalidCheckedEffect;
                        const moving = child.consumption.transfer == .move and
                            (child.semantics.ownership == .owned or child.semantics.ownership == .shared);
                        if (!moving) {
                            if (maybe_record != null) return error.InvalidCheckedEffect;
                            continue;
                        }
                        const record = maybe_record orelse return error.InvalidCheckedEffect;
                        record.validate() catch return error.InvalidCheckedEffect;
                        if (record.edge != .always or record.effect != .move or
                            !sameEffectSubject(record.effect.move.source, .{ .temporary = child.temporary_id orelse return error.InvalidCheckedEffect }) or
                            !sameEffectSubject(record.effect.move.destination, .{ .temporary_projection = .{
                                .root = parent,
                                .projection = .{
                                    .step = .{ .index = .{ .fixed = std.math.cast(i64, slot_index) orelse return error.InvalidCheckedEffect } },
                                    .result_type_id = child.type_id,
                                },
                            } })) return error.InvalidCheckedEffect;
                    }
                }
            }
            if (entry.expr.* == .tuple_literal) {
                const literal = entry.expr.tuple_literal;
                var any_moving = false;
                for (literal.items) |item| {
                    const child = self.metadataForExpr(item) orelse return error.InvalidCheckedEffect;
                    if (child.consumption.transfer == .move and
                        (child.semantics.ownership == .owned or child.semantics.ownership == .shared)) any_moving = true;
                }
                if (!any_moving) {
                    if (literal.checked_transfers != null) return error.InvalidCheckedEffect;
                } else {
                    const records = literal.checked_transfers orelse return error.InvalidCheckedEffect;
                    if (records.len != literal.items.len) return error.InvalidCheckedEffect;
                    const parent = entry.metadata.temporary_id orelse return error.InvalidCheckedEffect;
                    for (literal.items, records, 0..) |item, maybe_record, slot_index| {
                        const child = self.metadataForExpr(item) orelse return error.InvalidCheckedEffect;
                        const moving = child.consumption.transfer == .move and
                            (child.semantics.ownership == .owned or child.semantics.ownership == .shared);
                        if (!moving) {
                            if (maybe_record != null) return error.InvalidCheckedEffect;
                            continue;
                        }
                        const record = maybe_record orelse return error.InvalidCheckedEffect;
                        record.validate() catch return error.InvalidCheckedEffect;
                        if (record.edge != .always or record.effect != .move or
                            !sameEffectSubject(record.effect.move.source, .{ .temporary = child.temporary_id orelse return error.InvalidCheckedEffect }) or
                            !sameEffectSubject(record.effect.move.destination, .{ .temporary_projection = .{
                                .root = parent,
                                .projection = .{
                                    .step = .{ .index = .{ .fixed = std.math.cast(i64, slot_index) orelse return error.InvalidCheckedEffect } },
                                    .result_type_id = child.type_id,
                                },
                            } })) return error.InvalidCheckedEffect;
                    }
                }
            }
            if (entry.expr.* == .sparse_literal) {
                const literal = entry.expr.sparse_literal;
                var any_moving = false;
                for (literal.items) |item| {
                    const child = self.metadataForExpr(item) orelse return error.InvalidCheckedEffect;
                    any_moving = any_moving or (child.consumption.transfer == .move and
                        (child.semantics.ownership == .owned or child.semantics.ownership == .shared));
                }
                if (!any_moving) {
                    if (literal.checked_transfers != null) return error.InvalidCheckedEffect;
                } else {
                    const records = literal.checked_transfers orelse return error.InvalidCheckedEffect;
                    if (records.len != literal.items.len) return error.InvalidCheckedEffect;
                    const parent = entry.metadata.temporary_id orelse return error.InvalidCheckedEffect;
                    for (literal.items, records, 0..) |item, record, slot_index| {
                        const key: CheckedIndex = .{ .fixed = std.math.cast(i64, slot_index) orelse return error.InvalidCheckedEffect };
                        if (!self.verifySparseItemTransfer(item, parent, key, record)) return error.InvalidCheckedEffect;
                    }
                }
            }
            if (entry.expr.* == .sparse_keyed_literal) {
                const literal = entry.expr.sparse_keyed_literal;
                var any_moving = false;
                for (literal.entries) |item| {
                    const child = self.metadataForExpr(item.value) orelse return error.InvalidCheckedEffect;
                    any_moving = any_moving or (child.consumption.transfer == .move and
                        (child.semantics.ownership == .owned or child.semantics.ownership == .shared));
                }
                if (!any_moving) {
                    if (literal.checked_transfers != null) return error.InvalidCheckedEffect;
                } else {
                    const records = literal.checked_transfers orelse return error.InvalidCheckedEffect;
                    if (records.len != literal.entries.len) return error.InvalidCheckedEffect;
                    const parent = entry.metadata.temporary_id orelse return error.InvalidCheckedEffect;
                    for (literal.entries, records) |item, record| {
                        const key: CheckedIndex = if (item.index.* == .int and item.index.int.value >= 0)
                            .{ .fixed = item.index.int.value }
                        else
                            .{ .dynamic = item.index };
                        if (!self.verifySparseItemTransfer(item.value, parent, key, record)) return error.InvalidCheckedEffect;
                    }
                }
            }
            if (entry.expr.* == .sequence_push) {
                const push = entry.expr.sequence_push;
                const object = self.metadataForExpr(push.object) orelse return error.InvalidCheckedEffect;
                const child = self.metadataForExpr(push.value) orelse return error.InvalidCheckedEffect;
                const types = if (self.canonical_types) |*interner| interner else return error.InvalidCheckedEffect;
                const object_type = types.get(object.type_id) catch return error.InvalidCheckedEffect;
                if (object_type.* != .dense_array or object_type.dense_array != child.type_id) return error.InvalidCheckedEffect;
                const moving = child.consumption.transfer == .move and
                    (child.semantics.ownership == .owned or child.semantics.ownership == .shared);
                if (!moving) {
                    if (push.checked_transfer != null) return error.InvalidCheckedEffect;
                } else {
                    const record = push.checked_transfer orelse return error.InvalidCheckedEffect;
                    record.validate() catch return error.InvalidCheckedEffect;
                    if (record.edge != .always or record.effect != .move or
                        !sameEffectSubject(record.effect.move.source, .{ .temporary = child.temporary_id orelse return error.InvalidCheckedEffect }) or
                        !sameEffectSubject(record.effect.move.destination, .{ .container_slot = .{
                            .object = push.object,
                            .place = object.checkedPlacePath(),
                            .item_type_id = child.type_id,
                            .position = .append,
                        } })) return error.InvalidCheckedEffect;
                }
            }
            if (entry.expr.* == .sequence_pop) {
                const object_expr = entry.expr.sequence_pop;
                const object = self.metadataForExpr(object_expr) orelse return error.InvalidCheckedEffect;
                const types = if (self.canonical_types) |*interner| interner else return error.InvalidCheckedEffect;
                const object_type = types.get(object.type_id) catch return error.InvalidCheckedEffect;
                if (object_type.* != .dense_array or object_type.dense_array != entry.metadata.type_id) return error.InvalidCheckedEffect;
                const moving = entry.metadata.semantics.ownership == .owned or
                    entry.metadata.semantics.ownership == .shared;
                if (!moving) {
                    if (entry.metadata.checked_effect != null) return error.InvalidCheckedEffect;
                } else {
                    const record = entry.metadata.checked_effect orelse return error.InvalidCheckedEffect;
                    record.validate() catch return error.InvalidCheckedEffect;
                    if (record.edge != .always or record.effect != .take or
                        !sameEffectSubject(record.effect.take.source, .{ .container_slot = .{
                            .object = object_expr,
                            .place = object.checkedPlacePath(),
                            .item_type_id = entry.metadata.type_id,
                            .position = .last,
                        } }) or
                        !sameEffectSubject(record.effect.take.destination, .{ .temporary = entry.metadata.temporary_id orelse return error.InvalidCheckedEffect }))
                        return error.InvalidCheckedEffect;
                }
            }
            if (entry.expr.* == .sequence_clear or entry.expr.* == .sparse_clear) {
                const object_expr = if (entry.expr.* == .sequence_clear)
                    entry.expr.sequence_clear
                else
                    entry.expr.sparse_clear;
                const object = self.metadataForExpr(object_expr) orelse return error.InvalidCheckedEffect;
                const types = if (self.canonical_types) |*interner| interner else return error.InvalidCheckedEffect;
                const object_type = types.get(object.type_id) catch return error.InvalidCheckedEffect;
                const item_type: TypeId = switch (object_type.*) {
                    .dense_array => |item| if (entry.expr.* == .sequence_clear) item else return error.InvalidCheckedEffect,
                    .sparse_array => |item| if (entry.expr.* == .sparse_clear) item else return error.InvalidCheckedEffect,
                    else => return error.InvalidCheckedEffect,
                };
                const record = entry.metadata.checked_effect orelse return error.InvalidCheckedEffect;
                record.validate() catch return error.InvalidCheckedEffect;
                if (record.edge != .always or record.effect != .clear or
                    !sameEffectSubject(record.effect.clear, .{ .container_slot = .{
                        .object = object_expr,
                        .place = object.checkedPlacePath(),
                        .item_type_id = item_type,
                        .position = .all,
                    } })) return error.InvalidCheckedEffect;
            }
            if (entry.expr.* == .sparse_insert) {
                const insert = entry.expr.sparse_insert;
                const object = self.metadataForExpr(insert.object) orelse return error.InvalidCheckedEffect;
                const child = self.metadataForExpr(insert.value) orelse return error.InvalidCheckedEffect;
                if (self.metadataForExpr(insert.index) == null) return error.InvalidCheckedEffect;
                const types = if (self.canonical_types) |*interner| interner else return error.InvalidCheckedEffect;
                const object_type = types.get(object.type_id) catch return error.InvalidCheckedEffect;
                if (object_type.* != .sparse_array or object_type.sparse_array != child.type_id) return error.InvalidCheckedEffect;
                const moving = child.consumption.transfer == .move and
                    (child.semantics.ownership == .owned or child.semantics.ownership == .shared);
                if (!moving) {
                    if (insert.checked_replace != null or insert.checked_transfer != null) return error.InvalidCheckedEffect;
                } else {
                    const destination: Subject = .{ .container_slot = .{
                        .object = insert.object,
                        .place = object.checkedPlacePath(),
                        .item_type_id = child.type_id,
                        .position = .{ .indexed = if (insert.index.* == .int and insert.index.int.value >= 0)
                            .{ .fixed = insert.index.int.value }
                        else
                            .{ .dynamic = insert.index } },
                    } };
                    const replace = insert.checked_replace orelse return error.InvalidCheckedEffect;
                    const transfer = insert.checked_transfer orelse return error.InvalidCheckedEffect;
                    replace.validate() catch return error.InvalidCheckedEffect;
                    transfer.validate() catch return error.InvalidCheckedEffect;
                    if (replace.edge != .always or replace.effect != .replace or
                        !sameEffectSubject(replace.effect.replace, destination) or
                        transfer.edge != .always or transfer.effect != .move or
                        !sameEffectSubject(transfer.effect.move.source, .{ .temporary = child.temporary_id orelse return error.InvalidCheckedEffect }) or
                        !sameEffectSubject(transfer.effect.move.destination, destination)) return error.InvalidCheckedEffect;
                }
            }
            if (entry.expr.* == .@"try") {
                const attempt = entry.expr.@"try";
                const carrier = self.metadataForExpr(attempt.expr) orelse return error.InvalidCheckedEffect;
                const types = if (self.canonical_types) |*interner| interner else return error.InvalidCheckedEffect;
                const carrier_type = types.get(carrier.type_id) catch return error.InvalidCheckedEffect;
                if (carrier_type.* != .result or carrier_type.result.ok != entry.metadata.type_id or
                    attempt.result_ok_type_id != entry.metadata.type_id or
                    attempt.result_err_type_id != carrier_type.result.err) return error.InvalidCheckedEffect;
                const moving = entry.metadata.semantics.ownership == .owned or
                    entry.metadata.semantics.ownership == .shared;
                if (!moving) {
                    if (entry.metadata.checked_effect != null) return error.InvalidCheckedEffect;
                } else {
                    const record = entry.metadata.checked_effect orelse return error.InvalidCheckedEffect;
                    record.validate() catch return error.InvalidCheckedEffect;
                    if (record.edge != .active_case or record.edge.active_case != .result or
                        record.edge.active_case.result != .ok or record.effect != .take or
                        !sameEffectSubject(record.effect.take.source, .{ .temporary_payload = .{
                            .root = carrier.temporary_id orelse return error.InvalidCheckedEffect,
                            .owner_decl_id = null,
                            .case_name = "ok",
                            .result_case = .ok,
                            .payload_type_id = entry.metadata.type_id,
                        } }) or
                        !sameEffectSubject(record.effect.take.destination, .{ .temporary = entry.metadata.temporary_id orelse return error.InvalidCheckedEffect }))
                        return error.InvalidCheckedEffect;
                }
            }
            if (entry.expr.* == .cast) {
                const cast = entry.expr.cast;
                const source = self.metadataForExpr(cast.subject) orelse return error.InvalidCheckedEffect;
                const types = if (self.canonical_types) |*interner| interner else return error.InvalidCheckedEffect;
                const source_type = types.get(source.type_id) catch return error.InvalidCheckedEffect;
                if ((source_type.* == .optional or
                    (source_type.* == .nominal and source_type.nominal.kind == .@"union")) and !cast.reinterpret)
                {
                    const payload_type_id = cast.target_type_id orelse return error.InvalidCheckedEffect;
                    var owner_decl_id: ?identity.DeclId = null;
                    var case_name: []const u8 = "some";
                    const active_case: CheckedPayloadCase = if (source_type.* == .optional) blk: {
                        if (source_type.optional != payload_type_id) return error.InvalidCheckedEffect;
                        break :blk .optional_some;
                    } else blk: {
                        const declaration = cast.source_union_decl_id orelse return error.InvalidCheckedEffect;
                        if (source_type.nominal.decl_id != declaration) return error.InvalidCheckedEffect;
                        case_name = cast.union_case_name orelse return error.InvalidCheckedEffect;
                        var ordinal: ?u32 = null;
                        for (self.unions) |union_decl| {
                            if (union_decl.decl_id != declaration) continue;
                            for (union_decl.fields, 0..) |field, field_index| {
                                if (std.mem.eql(u8, field.name, case_name) and field.type_id == payload_type_id) {
                                    ordinal = @intCast(field_index);
                                    break;
                                }
                            }
                            break;
                        }
                        owner_decl_id = declaration;
                        break :blk .{ .union_field = .{ .owner_decl_id = declaration, .ordinal = ordinal orelse return error.InvalidCheckedEffect } };
                    };
                    const moving = entry.metadata.semantics.ownership == .owned or entry.metadata.semantics.ownership == .shared;
                    if (!moving) {
                        if (entry.metadata.checked_effect != null) return error.InvalidCheckedEffect;
                    } else {
                        const record = entry.metadata.checked_effect orelse return error.InvalidCheckedEffect;
                        record.validate() catch return error.InvalidCheckedEffect;
                        if (source.consumption.transfer != .move) return error.InvalidCheckedEffect;
                        const payload: Subject = .{ .temporary_payload = .{
                            .root = source.temporary_id orelse return error.InvalidCheckedEffect,
                            .owner_decl_id = owner_decl_id,
                            .case_name = case_name,
                            .result_case = null,
                            .payload_type_id = payload_type_id,
                        } };
                        const result_temp = entry.metadata.temporary_id orelse return error.InvalidCheckedEffect;
                        const destination: Subject = if (cast.fallible) .{ .temporary_payload = .{
                            .root = result_temp,
                            .owner_decl_id = null,
                            .case_name = "some",
                            .result_case = null,
                            .payload_type_id = payload_type_id,
                        } } else .{ .temporary = result_temp };
                        if (record.edge != .active_case or !std.meta.eql(record.edge.active_case, active_case) or
                            record.effect != .take or !sameEffectSubject(record.effect.take.source, payload) or
                            !sameEffectSubject(record.effect.take.destination, destination)) return error.InvalidCheckedEffect;
                    }
                } else if (entry.metadata.checked_effect != null) return error.InvalidCheckedEffect;
            }
            if (entry.expr.* == .closure) {
                const closure = entry.expr.closure;
                if (closure.env_decl_id == null and closure.captures.len == 0 and
                    closure.checked_transfers == null) continue;
                const environment = closure.env_decl_id orelse return error.InvalidCheckedEffect;
                var fields: ?[]const FieldDecl = null;
                for (self.structs) |declaration| if (declaration.decl_id == environment) {
                    fields = declaration.fields;
                    break;
                };
                const environment_fields = fields orelse return error.InvalidCheckedEffect;
                if (environment_fields.len != closure.captures.len) return error.InvalidCheckedEffect;
                if (closure.captures.len == 0) {
                    if (closure.checked_transfers != null) return error.InvalidCheckedEffect;
                } else {
                    const records = closure.checked_transfers orelse return error.InvalidCheckedEffect;
                    if (records.len != closure.captures.len) return error.InvalidCheckedEffect;
                    for (closure.captures, records, environment_fields, 0..) |capture, checked, field, capture_index| {
                        const metadata = self.metadataForExpr(capture) orelse return error.InvalidCheckedEffect;
                        if (metadata.semantics.ownership == .plain) {
                            if (checked != null) return error.InvalidCheckedEffect;
                            continue;
                        }
                        if (metadata.semantics.ownership != .borrowed and field.type_id != metadata.type_id) return error.InvalidCheckedEffect;
                        if (metadata.consumption.transfer != .copy) return error.InvalidCheckedEffect;
                        const source: Subject = if (metadata.temporary_id) |id|
                            .{ .temporary = id }
                        else if (metadata.checkedPlacePath()) |path|
                            .{ .place = path }
                        else
                            return error.InvalidCheckedEffect;
                        const record = checked orelse return error.InvalidCheckedEffect;
                        record.validate() catch return error.InvalidCheckedEffect;
                        if (record.edge != .always) return error.InvalidCheckedEffect;
                        if (metadata.semantics.ownership == .shared) {
                            if (record.effect != .copy or
                                !sameEffectSubject(record.effect.copy.source, source) or
                                !sameEffectSubject(record.effect.copy.destination, .{ .closure_slot = .{
                                    .environment_decl_id = environment,
                                    .field_index = @intCast(capture_index),
                                } })) return error.InvalidCheckedEffect;
                        } else if (record.effect != .borrow or !sameEffectSubject(record.effect.borrow, source)) {
                            return error.InvalidCheckedEffect;
                        }
                    }
                }
            }
            if (entry.expr.* == .task_result_take) {
                const take = entry.expr.task_result_take;
                const value_type = take.value_type_id orelse return error.InvalidCheckedEffect;
                if (take.return_type_id != entry.metadata.type_id or
                    self.metadataForExpr(take.witness) == null) return error.InvalidCheckedEffect;
                const pointer = self.metadataForExpr(take.pointer) orelse return error.InvalidCheckedEffect;
                const types = if (self.canonical_types) |*interner| interner else return error.InvalidCheckedEffect;
                const carrier_type = types.get(entry.metadata.type_id) catch return error.InvalidCheckedEffect;
                const pointer_type = types.get(pointer.type_id) catch return error.InvalidCheckedEffect;
                if (carrier_type.* != .result or carrier_type.result.ok != value_type or
                    pointer_type.* != .raw) return error.InvalidCheckedEffect;
                const moving = entry.metadata.semantics.ownership == .owned or
                    entry.metadata.semantics.ownership == .shared;
                if (!moving) {
                    if (take.checked_payload_take != null) return error.InvalidCheckedEffect;
                } else {
                    const record = take.checked_payload_take orelse return error.InvalidCheckedEffect;
                    record.validate() catch return error.InvalidCheckedEffect;
                    if (record.edge != .always or record.effect != .take or
                        !sameEffectSubject(record.effect.take.source, .{ .raw_pointee = .{
                            .pointer = take.pointer,
                            .pointee_type_id = value_type,
                        } }) or
                        !sameEffectSubject(record.effect.take.destination, .{ .temporary_payload = .{
                            .root = entry.metadata.temporary_id orelse return error.InvalidCheckedEffect,
                            .owner_decl_id = null,
                            .case_name = "ok",
                            .result_case = .ok,
                            .payload_type_id = value_type,
                        } })) return error.InvalidCheckedEffect;
                }
            }
            if (entry.expr.* == .thread_spawn_boxed or entry.expr.* == .task_group_spawn_boxed) {
                const payload_expr: *Expr, const payload_type: ?TypeId, const result_type: ?TypeId, const declaration: identity.DeclId, const argument_index: u32, const checked: ?Record = switch (entry.expr.*) {
                    .thread_spawn_boxed => |spawn| .{ spawn.payload, spawn.payload_type_id, spawn.return_type_id, spawn.decl_id orelse return error.InvalidCheckedEffect, 1, spawn.checked_payload_transfer },
                    .task_group_spawn_boxed => |spawn| .{ spawn.payload, spawn.payload_type_id, spawn.return_type_id, spawn.decl_id orelse return error.InvalidCheckedEffect, 3, spawn.checked_payload_transfer },
                    else => unreachable,
                };
                const payload = self.metadataForExpr(payload_expr) orelse return error.InvalidCheckedEffect;
                if (payload_type != payload.type_id or result_type != entry.metadata.type_id) return error.InvalidCheckedEffect;
                const shared_copy = payload.semantics.ownership == .shared and payload.consumption.transfer == .copy;
                const owner_move = (payload.semantics.ownership == .shared or payload.semantics.ownership == .owned) and payload.consumption.transfer == .move;
                if (!shared_copy and !owner_move) {
                    if (checked != null) return error.InvalidCheckedEffect;
                } else {
                    const record = checked orelse return error.InvalidCheckedEffect;
                    record.validate() catch return error.InvalidCheckedEffect;
                    const source: Subject = if (payload.temporary_id) |id|
                        .{ .temporary = id }
                    else if (payload.checkedPlacePath()) |path|
                        .{ .place = path }
                    else
                        return error.InvalidCheckedEffect;
                    const destination: Subject = .{ .call_slot = .{ .function_decl_id = declaration, .index = argument_index } };
                    if (record.edge != .always) return error.InvalidCheckedEffect;
                    if (shared_copy) {
                        if (record.effect != .copy or
                            !sameEffectSubject(record.effect.copy.source, source) or
                            !sameEffectSubject(record.effect.copy.destination, destination)) return error.InvalidCheckedEffect;
                    } else {
                        if (record.effect != .move or
                            !sameEffectSubject(record.effect.move.source, source) or
                            !sameEffectSubject(record.effect.move.destination, destination)) return error.InvalidCheckedEffect;
                    }
                }
            }
            if (entry.expr.* == .sync_share_boxed) {
                const share = entry.expr.sync_share_boxed;
                const declaration = share.decl_id orelse return error.InvalidCheckedEffect;
                const payload = self.metadataForExpr(share.payload) orelse return error.InvalidCheckedEffect;
                if (share.payload_type_id != payload.type_id or share.return_type_id != entry.metadata.type_id)
                    return error.InvalidCheckedEffect;
                const payload_moving = payload.consumption.transfer == .move and
                    (payload.semantics.ownership == .owned or payload.semantics.ownership == .shared);
                if (!payload_moving) {
                    if (share.checked_payload_transfer != null) return error.InvalidCheckedEffect;
                } else {
                    const record = share.checked_payload_transfer orelse return error.InvalidCheckedEffect;
                    record.validate() catch return error.InvalidCheckedEffect;
                    if (record.edge != .always or record.effect != .move or
                        !sameEffectSubject(record.effect.move.source, .{ .temporary = payload.temporary_id orelse return error.InvalidCheckedEffect }) or
                        !sameEffectSubject(record.effect.move.destination, .{ .call_slot = .{
                            .function_decl_id = declaration,
                            .index = 0,
                        } })) return error.InvalidCheckedEffect;
                }
                const result_moving = entry.metadata.consumption.transfer == .move and
                    (entry.metadata.semantics.ownership == .owned or entry.metadata.semantics.ownership == .shared);
                if (!result_moving) {
                    if (share.checked_result_effect != null) return error.InvalidCheckedEffect;
                } else {
                    const record = share.checked_result_effect orelse return error.InvalidCheckedEffect;
                    record.validate() catch return error.InvalidCheckedEffect;
                    if (record.edge != .always or record.effect != .move or
                        !sameEffectSubject(record.effect.move.source, .{ .return_slot = declaration }) or
                        !sameEffectSubject(record.effect.move.destination, .{ .temporary = entry.metadata.temporary_id orelse return error.InvalidCheckedEffect }))
                        return error.InvalidCheckedEffect;
                }
            }
            if (entry.expr.* == .union_case) {
                const case = entry.expr.union_case;
                if (case.value) |value| {
                    const child = self.metadataForExpr(value) orelse return error.InvalidCheckedEffect;
                    const moving = child.consumption.transfer == .move and
                        (child.semantics.ownership == .owned or child.semantics.ownership == .shared);
                    if (moving) {
                        const record = case.checked_transfer orelse return error.InvalidCheckedEffect;
                        const parent = entry.metadata.temporary_id orelse return error.InvalidCheckedEffect;
                        const source = child.temporary_id orelse return error.InvalidCheckedEffect;
                        record.validate() catch return error.InvalidCheckedEffect;
                        if (record.edge != .always or record.effect != .move or
                            !sameEffectSubject(record.effect.move.source, .{ .temporary = source }) or
                            !sameEffectSubject(record.effect.move.destination, .{ .temporary_payload = .{
                                .root = parent,
                                .owner_decl_id = case.decl_id,
                                .case_name = case.case_name,
                                .result_case = case.result_case,
                                .payload_type_id = child.type_id,
                            } })) return error.InvalidCheckedEffect;
                    } else if (case.checked_transfer != null) return error.InvalidCheckedEffect;
                } else if (case.checked_transfer != null) return error.InvalidCheckedEffect;
            }
            if (entry.expr.* == .call) try self.verifyCheckedCallArguments(entry.expr);
            if (entry.expr.* == .indirect_call) {
                try self.verifyGeneratedIndirectPayload(entry.expr);
                try self.verifyOrdinaryIndirectEffects(entry.expr, entry.metadata);
            }
            if (entry.metadata.checked_effect != null) {
                const metadata_effect_site = switch (entry.expr.*) {
                    .local, .global_ref, .ref_load, .string_bytes, .field, .borrowed_field, .tuple_field, .union_field, .borrowed_union_field, .index, .borrowed_index, .ref_local, .ref_global, .ref_alias_local, .ref_owned_local, .ref_field_local, .ref_field_owned_local, .ref_field_expr, .ref_union_field_local, .ref_index_local, .ref_path_local, .ref_index_path_local, .slice_range, .handoff_local, .raw_owned_local, .leak_owned_local, .new_owned, .new_array, .new_sparse, .sparse_indices, .string, .string_from, .string_slice, .interpolated_string, .struct_literal, .union_case, .array_literal, .tuple_literal, .array_default, .dense_array_literal, .sparse_literal, .sparse_keyed_literal, .take_path_local, .take_index_local, .take_index_path_local, .sparse_take, .sequence_pop, .sequence_clear, .sparse_clear, .@"try", .cast => true,
                    .unary => |unary| unary.op == .copy_list,
                    .int, .float, .rune, .bool, .none, .enum_case, .failure_detail, .is_test, .function_ref, .closure, .thread_spawn_boxed, .task_group_spawn_boxed, .task_result_take, .sync_share_boxed, .closure_capture, .ref_raw_deref, .raw_deref, .from_raw, .binary, .call, .indirect_call, .test_assert, .builtin_print, .sequence_push, .sequence_len, .sparse_len, .sparse_insert, .sparse_contains_index, .sequence_reserve, .string_len, .string_is_empty, .string_starts_with, .string_ends_with, .string_contains, .string_find, .string_rfind, .slice_len, .slice_ptr, .asm_expr, .@"switch" => false,
                };
                if (!metadata_effect_site) return error.InvalidCheckedEffect;
            }
            const seen = try expressions.getOrPut(allocator, entry.expr);
            if (seen.found_existing) return error.DuplicateExpressionMetadata;
        }
        for (self.globals) |global| {
            if (global.init) |init| try self.verifyExprSink(init, .initialize);
        }
        for (self.functions) |function| try self.verifyStmtActions(function.body, function.decl_id);
    }

    fn verifyCheckedCallArguments(self: Module, call_expr: *const Expr) VerifyValueActionsError!void {
        const call = call_expr.call;
        const callee_id = call.decl_id orelse {
            if (call.checked_arguments.len != 0 or call.checked_result_effect != null or call.checked_terminal_effect != null or
                call.checked_evaluation_sites.len != 0) return error.InvalidCheckedEffect;
            return;
        };
        var callee: ?Function = null;
        for (self.functions) |function| {
            if (function.decl_id == callee_id) {
                callee = function;
                break;
            }
        }
        const function = callee orelse {
            if (call.checked_arguments.len != 0 or call.checked_result_effect != null or call.checked_terminal_effect != null or
                call.checked_evaluation_sites.len != 0) return error.InvalidCheckedEffect;
            return;
        };
        if (function.params.len != call.args.len) return error.InvalidCheckedEffect;
        var cursor: usize = 0;
        var site_cursor: usize = 0;
        const check_sites = call.checked_method_use != null;
        for (call.args, function.params, 0..) |arg, param, index| {
            const expr = switch (arg) {
                .value => |value| value,
            };
            if (check_sites) {
                if (site_cursor >= call.checked_evaluation_sites.len) return error.InvalidCheckedEffect;
                const site = call.checked_evaluation_sites[site_cursor];
                if (site != .argument_value or site.argument_value != expr) return error.InvalidCheckedEffect;
                site_cursor += 1;
            }
            const metadata = self.metadataForExpr(expr) orelse return error.InvalidCheckedEffect;
            if (metadata.checked_generated_payload_binding != self.expectedGeneratedPayloadBinding(call_expr, expr))
                return error.InvalidCheckedEffect;
            if (metadata.semantics.ownership == .plain) continue;
            if (metadata.temporary_id == null and metadata.checked_generated_payload_binding == null and
                metadata.checkedPlacePath() == null) continue;
            if (cursor >= call.checked_arguments.len) return error.InvalidCheckedEffect;
            const record = call.checked_arguments[cursor];
            cursor += 1;
            if (check_sites) {
                if (site_cursor >= call.checked_evaluation_sites.len) return error.InvalidCheckedEffect;
                const site = call.checked_evaluation_sites[site_cursor];
                if (site != .effect or !std.meta.eql(site.effect, record)) return error.InvalidCheckedEffect;
                site_cursor += 1;
            }
            record.validate() catch return error.InvalidCheckedEffect;
            if (record.effect != .call_argument or record.edge != .always) return error.InvalidCheckedEffect;
            const checked = record.effect.call_argument;
            const use = call.checked_method_use orelse return error.InvalidCheckedEffect;
            const source: Subject = if (metadata.temporary_id) |id|
                .{ .temporary = id }
            else if (metadata.checked_generated_payload_binding) |id|
                .{ .generated_payload = id }
            else if (metadata.checkedPlacePath()) |path|
                .{ .place = path }
            else
                return error.InvalidCheckedEffect;
            const moving = (metadata.consumption.transfer == .move or
                metadata.checked_generated_payload_binding != null) and
                (metadata.semantics.ownership == .owned or metadata.semantics.ownership == .shared);
            if (checked.use_id != use.use_id or checked.callee_declaration_id != callee_id or
                checked.index != index or !sameEffectSubject(checked.source, source) or
                (moving and checked.mode != .move) or (!moving and checked.mode != .borrow))
            {
                return error.InvalidCheckedEffect;
            }
            if (moving) {
                const binding = param.binding_id orelse return error.InvalidCheckedEffect;
                const destination: Subject = .{ .place = .{
                    .root = .{ .binding = binding },
                    .projections = null,
                    .non_owning = false,
                } };
                if (checked.destination == null or !sameEffectSubject(checked.destination.?, destination))
                    return error.InvalidCheckedEffect;
            } else if (checked.destination != null) return error.InvalidCheckedEffect;
        }
        if (cursor != call.checked_arguments.len) return error.InvalidCheckedEffect;
        if (call.checked_terminal_effect != null) return error.InvalidCheckedEffect;
        const result = self.metadataForExpr(call_expr) orelse return error.InvalidCheckedEffect;
        const owner_result = (result.semantics.ownership == .owned or result.semantics.ownership == .shared) and
            result.temporary_id != null and !function.is_extern;
        if (owner_result) {
            const record = call.checked_result_effect orelse return error.InvalidCheckedEffect;
            if (check_sites) {
                if (site_cursor >= call.checked_evaluation_sites.len) return error.InvalidCheckedEffect;
                const site = call.checked_evaluation_sites[site_cursor];
                if (site != .effect or !std.meta.eql(site.effect, record)) return error.InvalidCheckedEffect;
                site_cursor += 1;
            }
            record.validate() catch return error.InvalidCheckedEffect;
            if (record.edge != .always or record.effect != .move or
                !sameEffectSubject(record.effect.move.source, .{ .return_slot = callee_id }) or
                !sameEffectSubject(record.effect.move.destination, .{ .temporary = result.temporary_id.? }))
                return error.InvalidCheckedEffect;
        } else if (call.checked_result_effect != null) return error.InvalidCheckedEffect;
        if (site_cursor != call.checked_evaluation_sites.len) return error.InvalidCheckedEffect;
    }

    fn expectedGeneratedPayloadBinding(self: Module, call_expr: *const Expr, arg: *const Expr) ?identity.BindingId {
        if (arg.* != .raw_deref or arg.raw_deref.expr.* != .cast) return null;
        const cast = arg.raw_deref.expr.cast;
        if (!cast.reinterpret or cast.subject.* != .local or !std.mem.eql(u8, cast.subject.local, "ctx")) return null;
        for (self.functions) |function| {
            if (!std.mem.startsWith(u8, function.name, generated_names.thread_boxed_trampoline_prefix) or
                function.calling_convention != .c or !function.is_isolated or function.params.len != 1 or
                !std.mem.eql(u8, function.params[0].name, "ctx") or
                !stmtSliceContainsExpr(function.body, call_expr)) continue;
            const binding = function.params[0].binding_id orelse return null;
            const context_metadata = self.metadataForExpr(cast.subject) orelse return null;
            const root = context_metadata.checked_place_root orelse return null;
            if (root != .binding or root.binding != binding) return null;
            return binding;
        }
        return null;
    }

    fn verifyGeneratedIndirectPayload(self: Module, expr: *const Expr) VerifyValueActionsError!void {
        const call = expr.indirect_call;
        if (call.checked_evaluation_sites_len > call.checked_evaluation_sites.len) return error.InvalidCheckedEffect;
        const sites = call.checked_evaluation_sites[0..call.checked_evaluation_sites_len];
        const expected = self.expectedGeneratedIndirectPayload(expr);
        if (expected == null) {
            if (call.checked_payload_transfer != null or sites.len != 0) return error.InvalidCheckedEffect;
            return;
        }
        const source = switch (call.args[expected.?.index]) {
            .value => |value| value,
        };
        const metadata = self.metadataForExpr(source) orelse return error.InvalidCheckedEffect;
        if (metadata.checked_generated_payload_binding != expected.?.binding) return error.InvalidCheckedEffect;
        const moving = metadata.semantics.ownership == .owned or metadata.semantics.ownership == .shared;
        if (!moving) {
            if (call.checked_payload_transfer != null) return error.InvalidCheckedEffect;
        } else {
            const record = call.checked_payload_transfer orelse return error.InvalidCheckedEffect;
            record.validate() catch return error.InvalidCheckedEffect;
            if (record.edge != .always or record.effect != .move or
                !sameEffectSubject(record.effect.move.source, .{ .generated_payload = expected.?.binding }) or
                !sameEffectSubject(record.effect.move.destination, .{ .call_slot = .{
                    .function_decl_id = expected.?.declaration,
                    .index = @intCast(expected.?.index),
                } })) return error.InvalidCheckedEffect;
        }
        var cursor: usize = 0;
        if (cursor >= sites.len or sites[cursor] == null or sites[cursor].? != .callee_value or
            sites[cursor].?.callee_value != call.callee)
            return error.InvalidCheckedEffect;
        cursor += 1;
        for (call.args, 0..) |arg, index| {
            if (cursor >= sites.len or sites[cursor] == null or sites[cursor].? != .argument_value or
                sites[cursor].?.argument_value != arg.value)
                return error.InvalidCheckedEffect;
            cursor += 1;
            if (moving and index == expected.?.index) {
                if (cursor >= sites.len or sites[cursor] == null or sites[cursor].? != .effect or
                    !std.meta.eql(sites[cursor].?.effect, call.checked_payload_transfer.?))
                    return error.InvalidCheckedEffect;
                cursor += 1;
            }
        }
        if (cursor != sites.len) return error.InvalidCheckedEffect;
    }

    fn verifyOrdinaryIndirectEffects(self: Module, expr: *const Expr, result_metadata: ExprMetadata) VerifyValueActionsError!void {
        const call = expr.indirect_call;
        if (call.checked_evaluation_sites_len != 0) {
            if (call.checked_arguments != null or call.checked_result_effect != null) return error.InvalidCheckedEffect;
            return;
        }
        const callee_metadata = self.metadataForExpr(call.callee) orelse return error.InvalidCheckedEffect;
        const types = if (self.canonical_types) |*interner| interner else return error.InvalidCheckedEffect;
        const callee_type = types.get(callee_metadata.type_id) catch return error.InvalidCheckedEffect;
        if (callee_type.* != .callable or callee_type.callable.params.len != call.args.len or
            callee_type.callable.return_type != result_metadata.type_id or
            call.return_type_id != result_metadata.type_id) return error.InvalidCheckedEffect;
        const records = call.checked_arguments;
        if (records) |items| if (items.len != call.args.len) return error.InvalidCheckedEffect;
        var any_record = false;
        for (call.args, 0..) |arg, index| {
            const value = switch (arg) {
                .value => |item| item,
            };
            const metadata = self.metadataForExpr(value) orelse return error.InvalidCheckedEffect;
            const maybe_record = if (records) |items| items[index] else null;
            if (metadata.semantics.ownership == .plain) {
                if (maybe_record != null) return error.InvalidCheckedEffect;
                continue;
            }
            any_record = true;
            const source: Subject = if (metadata.temporary_id) |id|
                .{ .temporary = id }
            else if (metadata.checked_generated_payload_binding) |id|
                .{ .generated_payload = id }
            else if (metadata.checkedPlacePath()) |path|
                .{ .place = path }
            else
                return error.InvalidCheckedEffect;
            const moving = metadata.consumption.transfer == .move and
                (metadata.semantics.ownership == .owned or metadata.semantics.ownership == .shared);
            const record = maybe_record orelse return error.InvalidCheckedEffect;
            record.validate() catch return error.InvalidCheckedEffect;
            if (record.edge != .always) return error.InvalidCheckedEffect;
            if (moving) {
                if (record.effect != .move or !sameEffectSubject(record.effect.move.source, source) or
                    !sameEffectSubject(record.effect.move.destination, .{ .indirect_call_slot = .{
                        .call = expr,
                        .index = @intCast(index),
                    } })) return error.InvalidCheckedEffect;
            } else if (record.effect != .borrow or !sameEffectSubject(record.effect.borrow, source)) {
                return error.InvalidCheckedEffect;
            }
        }
        if (!any_record and records != null) return error.InvalidCheckedEffect;
        const moving_result = result_metadata.semantics.ownership == .owned or result_metadata.semantics.ownership == .shared;
        if (!moving_result) {
            if (call.checked_result_effect != null) return error.InvalidCheckedEffect;
        } else {
            const record = call.checked_result_effect orelse return error.InvalidCheckedEffect;
            record.validate() catch return error.InvalidCheckedEffect;
            if (record.edge != .always or record.effect != .move or
                !sameEffectSubject(record.effect.move.source, .{ .indirect_return_slot = expr }) or
                !sameEffectSubject(record.effect.move.destination, .{ .temporary = result_metadata.temporary_id orelse return error.InvalidCheckedEffect }))
                return error.InvalidCheckedEffect;
        }
    }

    const GeneratedIndirectPayload = struct {
        binding: identity.BindingId,
        declaration: identity.DeclId,
        index: usize,
    };

    fn expectedGeneratedIndirectPayload(self: Module, expr: *const Expr) ?GeneratedIndirectPayload {
        const call = expr.indirect_call;
        if (call.args.len != 1 and call.args.len != 2) return null;
        if (call.callee.* != .cast or !call.callee.cast.reinterpret or
            call.callee.cast.subject.* != .local or
            !std.mem.eql(u8, call.callee.cast.subject.local, "entry_ctx")) return null;
        const index = call.args.len - 1;
        const source = switch (call.args[index]) {
            .value => |value| value,
        };
        if (source.* != .raw_deref or source.raw_deref.expr.* != .cast or
            !source.raw_deref.expr.cast.reinterpret or
            source.raw_deref.expr.cast.subject.* != .local or
            !std.mem.eql(u8, source.raw_deref.expr.cast.subject.local, "input_ctx")) return null;
        for (self.functions) |function| {
            if (!std.mem.startsWith(u8, function.name, generated_names.task_group_trampoline_prefix) or
                function.calling_convention != .c or !function.is_isolated or function.params.len != 5 or
                !stmtSliceContainsExpr(function.body, expr)) continue;
            const declaration = function.decl_id orelse return null;
            const binding = function.params[1].binding_id orelse return null;
            const input_metadata = self.metadataForExpr(source.raw_deref.expr.cast.subject) orelse return null;
            const input_root = input_metadata.checked_place_root orelse return null;
            const entry_metadata = self.metadataForExpr(call.callee.cast.subject) orelse return null;
            const entry_root = entry_metadata.checked_place_root orelse return null;
            if (input_root != .binding or input_root.binding != binding or
                entry_root != .binding or entry_root.binding != function.params[0].binding_id) return null;
            return .{ .binding = binding, .declaration = declaration, .index = index };
        }
        return null;
    }

    fn verifyExprSink(self: Module, expr: *const Expr, expected: SinkAction) VerifyValueActionsError!void {
        const metadata = self.metadataForExpr(expr) orelse return error.MissingExpressionMetadata;
        if (metadata.consumption.sink != expected) return error.InvalidSinkAction;
    }

    fn verifyStmtActions(self: Module, statements: []const Stmt, return_decl_id: ?identity.DeclId) VerifyValueActionsError!void {
        for (statements) |stmt| switch (stmt) {
            .local => |local| {
                try self.verifyExprSink(local.init, .initialize);
                const metadata = self.metadataForExpr(local.init) orelse return error.MissingExpressionMetadata;
                if (local.binding_mode == .projected) {
                    const place = local.projected_place orelse return error.InvalidCheckedEffect;
                    const source_place = metadata.checkedPlacePath() orelse return error.InvalidCheckedEffect;
                    if (!std.meta.eql(place.root, source_place.root) or
                        !std.meta.eql(place.projections, source_place.projections) or
                        !place.non_owning or local.type_id != metadata.type_id or
                        metadata.semantics.category != .borrowed_projection or
                        metadata.consumption.transfer != .copy or local.checked_effect != null)
                    {
                        return error.InvalidCheckedEffect;
                    }
                    continue;
                }
                if (metadata.consumption.transfer == .move and
                    (metadata.semantics.ownership == .owned or metadata.semantics.ownership == .shared))
                {
                    const record = local.checked_effect orelse return error.InvalidCheckedEffect;
                    const temporary = metadata.temporary_id orelse return error.InvalidCheckedEffect;
                    const binding = local.binding_id orelse return error.InvalidCheckedEffect;
                    record.validate() catch return error.InvalidCheckedEffect;
                    if (record.edge != .always or record.effect != .move or
                        !sameEffectSubject(record.effect.move.source, .{ .temporary = temporary }) or
                        !sameEffectSubject(record.effect.move.destination, .{ .place = .{
                            .root = .{ .binding = binding },
                            .projections = null,
                            .non_owning = false,
                        } })) return error.InvalidCheckedEffect;
                } else if (local.checked_effect != null) return error.InvalidCheckedEffect;
            },
            .assign => |assign| {
                try self.verifyExprSink(assign.value, .replace);
                if (assign.binding_id != null and assign.global_decl_id != null) return error.InvalidCheckedEffect;
                if (assign.binding_id) |id| {
                    if (self.projectedBindingPlace(id) != null) return error.InvalidCheckedEffect;
                }
                if (assign.checked_non_owning_target and
                    (assign.binding_id == null or !self.bindingIsReference(assign.binding_id.?)))
                {
                    return error.InvalidCheckedEffect;
                }
                if (assign.global_decl_id) |global_id| {
                    var found = false;
                    for (self.globals) |global| {
                        if (global.decl_id == global_id and std.mem.eql(u8, global.name, assign.name)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.InvalidCheckedEffect;
                }
                const metadata = self.metadataForExpr(assign.value) orelse return error.MissingExpressionMetadata;
                const owner_move = metadata.consumption.transfer == .move and
                    (metadata.semantics.ownership == .owned or metadata.semantics.ownership == .shared);
                if (!owner_move or (assign.binding_id == null and assign.global_decl_id == null)) {
                    if (assign.checked_replace != null or assign.checked_transfer != null) return error.InvalidCheckedEffect;
                } else {
                    const root: CheckedPlaceRoot = if (assign.binding_id) |id| .{ .binding = id } else .{ .global = assign.global_decl_id.? };
                    const path: CheckedPlacePath = .{ .root = root, .projections = null, .non_owning = false };
                    const destination: Subject = if (assign.checked_non_owning_target)
                        .{ .alias_pointee = path }
                    else
                        .{ .place = path };
                    const temporary = metadata.temporary_id orelse return error.InvalidCheckedEffect;
                    const replace = assign.checked_replace orelse return error.InvalidCheckedEffect;
                    const transfer = assign.checked_transfer orelse return error.InvalidCheckedEffect;
                    replace.validate() catch return error.InvalidCheckedEffect;
                    transfer.validate() catch return error.InvalidCheckedEffect;
                    if (replace.edge != .always or replace.effect != .replace or
                        !sameEffectSubject(replace.effect.replace, destination) or
                        transfer.edge != .always or transfer.effect != .move or
                        !sameEffectSubject(transfer.effect.move.source, .{ .temporary = temporary }) or
                        !sameEffectSubject(transfer.effect.move.destination, destination)) return error.InvalidCheckedEffect;
                }
            },
            .field_assign => |assign| {
                try self.verifyExprSink(assign.value, .replace);
                if (assign.root_binding_id != null and assign.root_global_decl_id != null) return error.InvalidCheckedEffect;
                if (assign.root_binding_id == null) {
                    const global_id = assign.root_global_decl_id orelse return error.InvalidCheckedEffect;
                    var found = false;
                    for (self.globals) |global| {
                        if (global.decl_id == global_id and std.mem.eql(u8, global.name, assign.root_name)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.InvalidCheckedEffect;
                }
                const projections = assign.checked_projections orelse return error.InvalidCheckedEffect;
                if (projections.len != assign.steps.len or projections.len == 0) return error.InvalidCheckedEffect;
                for (projections, assign.steps) |projection, step| {
                    if (projection.step != .field or step.struct_decl_id == null or
                        projection.step.field.owner_decl_id != step.struct_decl_id.? or
                        !std.mem.eql(u8, projection.step.field.name, step.field)) return error.InvalidCheckedEffect;
                }
                const metadata = self.metadataForExpr(assign.value) orelse return error.MissingExpressionMetadata;
                const field_type_id = projections[projections.len - 1].result_type_id;
                if (field_type_id != metadata.type_id) {
                    const types = if (self.canonical_types) |*interner| interner else return error.InvalidCheckedEffect;
                    const field_type = types.get(field_type_id) catch return error.InvalidCheckedEffect;
                    if (field_type.* != .optional or field_type.optional != metadata.type_id)
                        return error.InvalidCheckedEffect;
                }
                if (assign.capture) |capture| {
                    if (capture.type_id != field_type_id) return error.InvalidCheckedEffect;
                    if (assign.checked_capture) |record| {
                        const source_root: CheckedPlaceRoot = if (assign.root_binding_id) |id| .{ .binding = id } else .{ .global = assign.root_global_decl_id.? };
                        const source_path: CheckedPlacePath = .{ .root = source_root, .projections = projections, .non_owning = false };
                        const source: Subject = if (assign.root_binding_id != null and self.bindingIsReference(assign.root_binding_id.?))
                            .{ .alias_pointee = source_path }
                        else
                            .{ .place = source_path };
                        const destination: Subject = .{ .place = .{ .root = .{ .binding = capture.binding_id }, .projections = null, .non_owning = false } };
                        record.validate() catch return error.InvalidCheckedEffect;
                        if (record.edge != .always or record.effect != .take or
                            !sameEffectSubject(record.effect.take.source, source) or
                            !sameEffectSubject(record.effect.take.destination, destination)) return error.InvalidCheckedEffect;
                    }
                } else if (assign.checked_capture != null) {
                    return error.InvalidCheckedEffect;
                }
                const moving = metadata.consumption.transfer == .move and
                    (metadata.semantics.ownership == .owned or metadata.semantics.ownership == .shared);
                const non_owning = if (assign.root_binding_id) |id| self.bindingIsReference(id) else false;
                if (!moving) {
                    if (assign.checked_replace != null or assign.checked_transfer != null) return error.InvalidCheckedEffect;
                } else {
                    const root: CheckedPlaceRoot = if (assign.root_binding_id) |id| .{ .binding = id } else .{ .global = assign.root_global_decl_id.? };
                    const path: CheckedPlacePath = .{ .root = root, .projections = projections, .non_owning = false };
                    const destination: Subject = if (non_owning) .{ .alias_pointee = path } else .{ .place = path };
                    const temporary = metadata.temporary_id orelse return error.InvalidCheckedEffect;
                    const replace = assign.checked_replace orelse return error.InvalidCheckedEffect;
                    const transfer = assign.checked_transfer orelse return error.InvalidCheckedEffect;
                    replace.validate() catch return error.InvalidCheckedEffect;
                    transfer.validate() catch return error.InvalidCheckedEffect;
                    if (replace.edge != .always or replace.effect != .replace or
                        !sameEffectSubject(replace.effect.replace, destination) or
                        transfer.edge != .always or transfer.effect != .move or
                        !sameEffectSubject(transfer.effect.move.source, .{ .temporary = temporary }) or
                        !sameEffectSubject(transfer.effect.move.destination, destination)) return error.InvalidCheckedEffect;
                }
                var expected_sites: [4]MutationEvaluationSite = undefined;
                var site_count: usize = 0;
                expected_sites[site_count] = .{ .assigned_value = assign.value };
                site_count += 1;
                if (assign.checked_capture) |record| {
                    expected_sites[site_count] = .{ .effect = record };
                    site_count += 1;
                }
                if (moving) {
                    expected_sites[site_count] = .{ .effect = assign.checked_replace.? };
                    site_count += 1;
                    expected_sites[site_count] = .{ .effect = assign.checked_transfer.? };
                    site_count += 1;
                }
                if (!mutationSitesMatch(&assign.checked_evaluation_sites, assign.checked_evaluation_sites_len, expected_sites[0..site_count]))
                    return error.InvalidCheckedEffect;
            },
            .index_assign => |assign| {
                try self.verifyExprSink(assign.value, .replace);
                const object_metadata = self.metadataForExpr(assign.object) orelse return error.MissingExpressionMetadata;
                const value_metadata = self.metadataForExpr(assign.value) orelse return error.MissingExpressionMetadata;
                const moving = value_metadata.consumption.transfer == .move and
                    (value_metadata.semantics.ownership == .owned or value_metadata.semantics.ownership == .shared);
                const object_path = object_metadata.checkedPlacePath();
                const alias_destination = if (object_path) |path| path.non_owning and switch (path.root) {
                    .binding => |id| self.bindingIsReference(id),
                    .global => false,
                } else false;
                if (!moving or object_path == null or (object_path.?.non_owning and !alias_destination)) {
                    if (assign.checked_projections != null or assign.checked_replace != null or
                        assign.checked_transfer != null) return error.InvalidCheckedEffect;
                } else {
                    const path = object_path.?;
                    const prefix = path.projections orelse &.{};
                    const projections = assign.checked_projections orelse return error.InvalidCheckedEffect;
                    if (projections.len != prefix.len + 1) return error.InvalidCheckedEffect;
                    for (projections[0..prefix.len], prefix) |actual, expected| {
                        if (!std.meta.eql(actual, expected)) return error.InvalidCheckedEffect;
                    }
                    const last = projections[prefix.len];
                    const types = if (self.canonical_types) |*interner| interner else return error.InvalidCheckedEffect;
                    var container_type = object_metadata.type_id;
                    const container_node = types.get(container_type) catch return error.InvalidCheckedEffect;
                    if (container_node.* == .ref_) container_type = container_node.ref_.target;
                    if (!self.verifyCheckedTakeStep(types, .{ .index = assign.index }, last, &container_type))
                        return error.InvalidCheckedEffect;
                    if (last.result_type_id != value_metadata.type_id) {
                        const destination_type = types.get(last.result_type_id) catch return error.InvalidCheckedEffect;
                        if (destination_type.* != .optional or destination_type.optional != value_metadata.type_id)
                            return error.InvalidCheckedEffect;
                    }
                    const expected_index: CheckedIndex = if (assign.index.* == .int and assign.index.int.value >= 0)
                        .{ .fixed = assign.index.int.value }
                    else
                        .{ .dynamic = assign.index };
                    if (!std.meta.eql(last.step.index, expected_index)) return error.InvalidCheckedEffect;
                    const destination_path: CheckedPlacePath = .{
                        .root = path.root,
                        .projections = projections,
                        .non_owning = false,
                    };
                    const destination: Subject = if (alias_destination)
                        .{ .alias_pointee = destination_path }
                    else
                        .{ .place = destination_path };
                    const replace = assign.checked_replace orelse return error.InvalidCheckedEffect;
                    const transfer = assign.checked_transfer orelse return error.InvalidCheckedEffect;
                    replace.validate() catch return error.InvalidCheckedEffect;
                    transfer.validate() catch return error.InvalidCheckedEffect;
                    if (replace.edge != .always or replace.effect != .replace or
                        !sameEffectSubject(replace.effect.replace, destination) or
                        transfer.edge != .always or transfer.effect != .move or
                        !sameEffectSubject(transfer.effect.move.source, .{ .temporary = value_metadata.temporary_id orelse return error.InvalidCheckedEffect }) or
                        !sameEffectSubject(transfer.effect.move.destination, destination)) return error.InvalidCheckedEffect;
                }
                var expected_sites: [5]MutationEvaluationSite = undefined;
                expected_sites[0] = .{ .target_value = assign.object };
                expected_sites[1] = .{ .index_value = assign.index };
                expected_sites[2] = .{ .assigned_value = assign.value };
                const site_count: usize = if (moving and object_path != null and (!object_path.?.non_owning or alias_destination)) 5 else 3;
                if (site_count == 5) {
                    expected_sites[3] = .{ .effect = assign.checked_replace.? };
                    expected_sites[4] = .{ .effect = assign.checked_transfer.? };
                }
                if (!mutationSitesMatch(&assign.checked_evaluation_sites, assign.checked_evaluation_sites_len, expected_sites[0..site_count]))
                    return error.InvalidCheckedEffect;
            },
            .deref_assign => |assign| {
                try self.verifyExprSink(assign.value, if (assign.is_init) .initialize else .replace);
                const pointer_metadata = self.metadataForExpr(assign.pointer) orelse return error.MissingExpressionMetadata;
                const value_metadata = self.metadataForExpr(assign.value) orelse return error.MissingExpressionMetadata;
                const types = if (self.canonical_types) |*interner| interner else return error.InvalidCheckedEffect;
                const pointer_type = types.get(pointer_metadata.type_id) catch return error.InvalidCheckedEffect;
                if (pointer_type.* != .raw or pointer_type.raw.is_const or
                    pointer_type.raw.is_volatile != assign.is_volatile or
                    pointer_type.raw.target != value_metadata.type_id) return error.InvalidCheckedEffect;
                const moving = !assign.is_init and value_metadata.consumption.transfer == .move and
                    (value_metadata.semantics.ownership == .owned or value_metadata.semantics.ownership == .shared);
                if (!moving) {
                    if (assign.checked_replace != null or assign.checked_transfer != null) return error.InvalidCheckedEffect;
                } else {
                    const destination: Subject = .{ .raw_pointee = .{
                        .pointer = assign.pointer,
                        .pointee_type_id = pointer_type.raw.target,
                    } };
                    const replace = assign.checked_replace orelse return error.InvalidCheckedEffect;
                    const transfer = assign.checked_transfer orelse return error.InvalidCheckedEffect;
                    replace.validate() catch return error.InvalidCheckedEffect;
                    transfer.validate() catch return error.InvalidCheckedEffect;
                    if (replace.edge != .always or replace.effect != .replace or
                        !sameEffectSubject(replace.effect.replace, destination) or
                        transfer.edge != .always or transfer.effect != .move or
                        !sameEffectSubject(transfer.effect.move.source, .{ .temporary = value_metadata.temporary_id orelse return error.InvalidCheckedEffect }) or
                        !sameEffectSubject(transfer.effect.move.destination, destination)) return error.InvalidCheckedEffect;
                }
            },
            .deref_field_assign => |assign| {
                try self.verifyExprSink(assign.value, .replace);
                const pointer_metadata = self.metadataForExpr(assign.pointer) orelse return error.MissingExpressionMetadata;
                const value_metadata = self.metadataForExpr(assign.value) orelse return error.MissingExpressionMetadata;
                const types = if (self.canonical_types) |*interner| interner else return error.InvalidCheckedEffect;
                const pointer_type = types.get(pointer_metadata.type_id) catch return error.InvalidCheckedEffect;
                if (pointer_type.* != .raw or pointer_type.raw.is_const or
                    pointer_type.raw.is_volatile != assign.is_volatile) return error.InvalidCheckedEffect;
                const projections = assign.checked_projections orelse return error.InvalidCheckedEffect;
                if (projections.len != assign.steps.len or projections.len == 0) return error.InvalidCheckedEffect;
                var current_type = pointer_type.raw.target;
                for (assign.steps, projections) |step, projection| {
                    if (!self.verifyCheckedTakeStep(types, .{ .field = step }, projection, &current_type))
                        return error.InvalidCheckedEffect;
                }
                if (current_type != value_metadata.type_id) return error.InvalidCheckedEffect;
                const moving = value_metadata.consumption.transfer == .move and
                    (value_metadata.semantics.ownership == .owned or value_metadata.semantics.ownership == .shared);
                if (!moving) {
                    if (assign.checked_replace != null or assign.checked_transfer != null) return error.InvalidCheckedEffect;
                } else {
                    const destination: Subject = .{ .raw_pointee = .{
                        .pointer = assign.pointer,
                        .pointee_type_id = pointer_type.raw.target,
                        .projections = projections,
                    } };
                    const replace = assign.checked_replace orelse return error.InvalidCheckedEffect;
                    const transfer = assign.checked_transfer orelse return error.InvalidCheckedEffect;
                    replace.validate() catch return error.InvalidCheckedEffect;
                    transfer.validate() catch return error.InvalidCheckedEffect;
                    if (replace.edge != .always or replace.effect != .replace or
                        !sameEffectSubject(replace.effect.replace, destination) or
                        transfer.edge != .always or transfer.effect != .move or
                        !sameEffectSubject(transfer.effect.move.source, .{ .temporary = value_metadata.temporary_id orelse return error.InvalidCheckedEffect }) or
                        !sameEffectSubject(transfer.effect.move.destination, destination)) return error.InvalidCheckedEffect;
                }
            },
            .drop => |drop| {
                const binding = drop.binding_id orelse return error.InvalidCheckedEffect;
                if (self.projectedBindingPlace(binding) != null) return error.InvalidCheckedEffect;
                const record = drop.checked_effect orelse return error.InvalidCheckedEffect;
                record.validate() catch return error.InvalidCheckedEffect;
                if (record.edge != .always or record.effect != .drop or record.effect.drop != .place or
                    record.effect.drop.place.projections != null or record.effect.drop.place.non_owning or
                    !sameEffectSubject(record.effect.drop, .{ .place = .{
                        .root = .{ .binding = binding },
                        .projections = null,
                        .non_owning = false,
                    } })) return error.InvalidCheckedEffect;
            },
            .@"return" => |maybe_expr| if (maybe_expr) |expr| {
                try self.verifyExprSink(expr, .@"return");
                const metadata = self.metadataForExpr(expr) orelse return error.MissingExpressionMetadata;
                const owner_move = metadata.consumption.transfer == .move and
                    (metadata.semantics.ownership == .owned or metadata.semantics.ownership == .shared);
                if (owner_move) {
                    const record = metadata.checked_sink_effect orelse return error.InvalidCheckedEffect;
                    const temporary = metadata.temporary_id orelse return error.InvalidCheckedEffect;
                    const declaration = return_decl_id orelse return error.InvalidCheckedEffect;
                    record.validate() catch return error.InvalidCheckedEffect;
                    if (record.edge != .always or record.effect != .@"return" or
                        !sameEffectSubject(record.effect.@"return".source, .{ .temporary = temporary }) or
                        !sameEffectSubject(record.effect.@"return".destination, .{ .return_slot = declaration }))
                    {
                        return error.InvalidCheckedEffect;
                    }
                } else if (metadata.checked_sink_effect != null) return error.InvalidCheckedEffect;
            },
            .using_alloc => |using_alloc| try self.verifyStmtActions(using_alloc.body, return_decl_id),
            .unchecked => |body| try self.verifyStmtActions(body, return_decl_id),
            .@"if" => |if_stmt| {
                try self.verifyStmtActions(if_stmt.then_body, return_decl_id);
                try self.verifyStmtActions(if_stmt.else_body, return_decl_id);
            },
            .@"while" => |while_stmt| try self.verifyStmtActions(while_stmt.body, return_decl_id),
            .@"for" => |for_stmt| try self.verifyStmtActions(for_stmt.body, return_decl_id),
            .@"switch" => |switch_stmt| {
                for (switch_stmt.cases) |case| try self.verifyStmtActions(case.body, return_decl_id);
                try self.verifyStmtActions(switch_stmt.else_body, return_decl_id);
            },
            else => {},
        };
    }

    fn bindingIsReference(self: Module, binding_id: identity.BindingId) bool {
        const types = if (self.canonical_types) |*interner| interner else return false;
        const type_id = self.bindingType(binding_id) orelse return false;
        const node = types.get(type_id) catch return false;
        return node.* == .ref_;
    }

    fn bindingType(self: Module, binding_id: identity.BindingId) ?TypeId {
        for (self.functions) |function| {
            for (function.params) |param| {
                if (param.binding_id == binding_id) return param.type_id;
            }
            if (bindingTypeInStatements(function.body, binding_id)) |type_id| return type_id;
        }
        // Expression switches introduce captures and statement-local bindings too.
        // Their bodies are absent from the enclosing statement-only walk.
        for (self.expr_metadata) |entry| {
            if (entry.expr.* != .@"switch") continue;
            for (entry.expr.@"switch".cases) |case| {
                if (case.payload_binding_id == binding_id) return case.payload_type_id;
                if (bindingTypeInStatements(case.body, binding_id)) |type_id| return type_id;
            }
            if (bindingTypeInStatements(entry.expr.@"switch".else_body, binding_id)) |type_id| return type_id;
        }
        return null;
    }

    fn projectedBindingPlace(self: Module, binding_id: identity.BindingId) ?CheckedPlacePath {
        for (self.functions) |function| {
            if (projectedPlaceInStatements(function.body, binding_id)) |place| return place;
        }
        for (self.expr_metadata) |entry| {
            if (entry.expr.* != .@"switch") continue;
            for (entry.expr.@"switch".cases) |case| {
                if (projectedPlaceInStatements(case.body, binding_id)) |place| return place;
            }
            if (projectedPlaceInStatements(entry.expr.@"switch".else_body, binding_id)) |place| return place;
        }
        return null;
    }
};

fn projectedPlaceInStatements(statements: []const Stmt, binding_id: identity.BindingId) ?CheckedPlacePath {
    for (statements) |stmt| switch (stmt) {
        .local => |local| if (local.binding_id == binding_id) return local.projected_place,
        .using_alloc => |scope| if (projectedPlaceInStatements(scope.body, binding_id)) |place| return place,
        .unchecked => |body| if (projectedPlaceInStatements(body, binding_id)) |place| return place,
        .@"if" => |branch| {
            if (projectedPlaceInStatements(branch.then_body, binding_id)) |place| return place;
            if (projectedPlaceInStatements(branch.else_body, binding_id)) |place| return place;
        },
        .@"while" => |loop| if (projectedPlaceInStatements(loop.body, binding_id)) |place| return place,
        .@"for" => |loop| if (projectedPlaceInStatements(loop.body, binding_id)) |place| return place,
        .@"switch" => |branch| {
            for (branch.cases) |case| if (projectedPlaceInStatements(case.body, binding_id)) |place| return place;
            if (projectedPlaceInStatements(branch.else_body, binding_id)) |place| return place;
        },
        else => {},
    };
    return null;
}

fn bindingTypeInStatements(statements: []const Stmt, binding_id: identity.BindingId) ?TypeId {
    for (statements) |stmt| switch (stmt) {
        .local => |local| if (local.binding_id == binding_id) return local.type_id,
        .field_assign => |assign| if (assign.capture) |capture| {
            if (capture.binding_id == binding_id) return capture.type_id;
        },
        .using_alloc => |scope| if (bindingTypeInStatements(scope.body, binding_id)) |id| return id,
        .unchecked => |body| if (bindingTypeInStatements(body, binding_id)) |id| return id,
        .@"if" => |branch| {
            if (branch.capture_binding_id == binding_id) return branch.capture_type_id;
            if (bindingTypeInStatements(branch.then_body, binding_id)) |id| return id;
            if (bindingTypeInStatements(branch.else_body, binding_id)) |id| return id;
        },
        .@"while" => |loop| if (bindingTypeInStatements(loop.body, binding_id)) |id| return id,
        .@"for" => |loop| {
            if (loop.binding_id == binding_id) return loop.item_type_id;
            if (bindingTypeInStatements(loop.body, binding_id)) |id| return id;
        },
        .@"switch" => |branch| {
            for (branch.cases) |case| {
                if (case.payload_binding_id == binding_id) return case.payload_type_id;
                if (bindingTypeInStatements(case.body, binding_id)) |id| return id;
            }
            if (bindingTypeInStatements(branch.else_body, binding_id)) |id| return id;
        },
        else => {},
    };
    return null;
}

pub fn intrinsicForBuiltinExpr(expr: *const Expr) ?IntrinsicId {
    return switch (expr.*) {
        .test_assert => .builtin_assert,
        .builtin_print => |print| if (print.append_newline) .builtin_println else .builtin_print,
        .string_from => .string_from,
        .string_len => .string_len,
        .string_is_empty => .string_is_empty,
        .string_bytes => .string_bytes,
        .string_starts_with => .string_starts_with,
        .string_ends_with => .string_ends_with,
        .string_contains => .string_contains,
        .string_find => .string_find,
        .string_rfind => .string_rfind,
        .string_slice => .string_slice,
        .sequence_len => .sequence_len,
        .sequence_clear => .sequence_clear,
        .sequence_push => .sequence_push,
        .sequence_reserve => .sequence_reserve,
        .sequence_pop => .sequence_pop,
        .sparse_len => .sparse_len,
        .sparse_clear => .sparse_clear,
        .sparse_contains_index => .sparse_contains_index,
        .sparse_indices => .sparse_indices,
        .sparse_insert => .sparse_insert,
        .sparse_take => .sparse_take,
        .slice_len => .slice_len,
        .raw_owned_local => .owned_ptr,
        .leak_owned_local => .owned_leak,
        else => null,
    };
}

pub fn intrinsicMatchesBuiltinExpr(expr: *const Expr, intrinsic_id: ?IntrinsicId) bool {
    if (intrinsicForBuiltinExpr(expr) == intrinsic_id) return true;
    return switch (expr.*) {
        .from_raw => intrinsic_id == .resource_from_raw,
        .unary => |unary| switch (unary.op) {
            .copy_list => intrinsic_id == .sequence_clone,
            else => false,
        },
        else => false,
    };
}

fn verifyStmtIntrinsicContracts(statements: []const Stmt) VerifyIntrinsicCallsError!void {
    for (statements) |stmt| switch (stmt) {
        .@"for" => |for_stmt| {
            const has_protocol_iterator = for_stmt.iterator_init_decl_id != null;
            if (has_protocol_iterator) {
                if (for_stmt.iterator_init_intrinsic_id != .syntax_iter or
                    for_stmt.iterator_has_next_intrinsic_id != .syntax_iter_has_next or
                    for_stmt.iterator_next_intrinsic_id != .syntax_iter_next)
                {
                    return error.InvalidIntrinsicExpression;
                }
                if (for_stmt.iterable_index_decl_id != null and
                    for_stmt.iterable_index_intrinsic_id != .syntax_iter_item)
                {
                    return error.InvalidIntrinsicExpression;
                }
            } else if (for_stmt.iterator_init_intrinsic_id != null or
                for_stmt.iterator_has_next_intrinsic_id != null or
                for_stmt.iterator_next_intrinsic_id != null or
                for_stmt.iterable_index_intrinsic_id != null)
            {
                return error.InvalidIntrinsicExpression;
            }
            try verifyStmtIntrinsicContracts(for_stmt.body);
        },
        .using_alloc => |using_alloc| try verifyStmtIntrinsicContracts(using_alloc.body),
        .unchecked => |body| try verifyStmtIntrinsicContracts(body),
        .@"if" => |if_stmt| {
            try verifyStmtIntrinsicContracts(if_stmt.then_body);
            try verifyStmtIntrinsicContracts(if_stmt.else_body);
        },
        .@"while" => |while_stmt| try verifyStmtIntrinsicContracts(while_stmt.body),
        .@"switch" => |switch_stmt| {
            for (switch_stmt.cases) |case| try verifyStmtIntrinsicContracts(case.body);
            try verifyStmtIntrinsicContracts(switch_stmt.else_body);
        },
        else => {},
    };
}

fn stmtSliceContainsExpr(statements: []const Stmt, target: *const Expr) bool {
    for (statements) |stmt| {
        if (stmtContainsExpr(stmt, target)) return true;
    }
    return false;
}

fn stmtContainsExpr(stmt: Stmt, target: *const Expr) bool {
    return switch (stmt) {
        .local => |local| exprContains(local.init, target),
        .assign => |assign| exprContains(assign.value, target),
        .field_assign => |assign| exprContains(assign.value, target),
        .index_assign => |assign| exprContains(assign.object, target) or exprContains(assign.index, target) or exprContains(assign.value, target),
        .deref_assign => |assign| exprContains(assign.pointer, target) or exprContains(assign.value, target),
        .deref_field_assign => |assign| exprContains(assign.pointer, target) or exprContains(assign.value, target),
        .using_alloc => |using_alloc| exprContains(using_alloc.allocator_expr, target) or stmtSliceContainsExpr(using_alloc.body, target),
        .unchecked => |body| stmtSliceContainsExpr(body, target),
        .asm_stmt => |asm_stmt| blk: {
            for (asm_stmt.inputs) |input| {
                if (exprContains(input.value, target)) break :blk true;
            }
            break :blk false;
        },
        .@"if" => |if_stmt| exprContains(if_stmt.condition, target) or stmtSliceContainsExpr(if_stmt.then_body, target) or stmtSliceContainsExpr(if_stmt.else_body, target),
        .@"while" => |while_stmt| exprContains(while_stmt.condition, target) or stmtSliceContainsExpr(while_stmt.body, target),
        .@"for" => |for_stmt| exprContains(for_stmt.iterable, target) or stmtSliceContainsExpr(for_stmt.body, target),
        .@"switch" => |switch_stmt| blk: {
            if (exprContains(switch_stmt.value, target)) break :blk true;
            for (switch_stmt.cases) |case| {
                if (stmtSliceContainsExpr(case.body, target)) break :blk true;
            }
            break :blk stmtSliceContainsExpr(switch_stmt.else_body, target);
        },
        .yield => |maybe_expr| if (maybe_expr) |expr| exprContains(expr, target) else false,
        .@"try" => |attempt| exprContains(attempt.expr, target),
        .@"defer", .expr => |expr| exprContains(expr, target),
        .@"return" => |maybe_expr| if (maybe_expr) |expr| exprContains(expr, target) else false,
        .@"continue", .@"break", .drop => false,
    };
}

fn exprContains(expr: *const Expr, target: *const Expr) bool {
    if (expr == target) return true;
    return switch (expr.*) {
        .@"switch" => |switch_expr| blk: {
            if (exprContains(switch_expr.value, target)) break :blk true;
            for (switch_expr.cases) |case| if (stmtSliceContainsExpr(case.body, target)) break :blk true;
            break :blk stmtSliceContainsExpr(switch_expr.else_body, target);
        },
        .@"try" => |try_expr| exprContains(try_expr.expr, target),
        .failure_detail => |detail| if (detail.index) |index| exprContains(index, target) else false,
        .union_case => |case| if (case.value) |value| exprContains(value, target) else false,
        .is_test => |is_test| exprContains(is_test.subject, target),
        .cast => |cast| exprContains(cast.subject, target),
        .closure => |closure| exprSliceContains(closure.captures, target),
        .thread_spawn_boxed => |spawn| exprContains(spawn.payload, target),
        .task_group_spawn_boxed => |spawn| exprContains(spawn.group_raw, target) or exprContains(spawn.entry, target) or exprContains(spawn.payload, target),
        .task_result_take => |take| exprContains(take.witness, target) or exprContains(take.pointer, target),
        .sync_share_boxed => |share| exprContains(share.payload, target),
        .ref_field_expr => |field| exprContains(field.object, target),
        .ref_index_local => |index| exprContains(index.index, target),
        .ref_index_path_local, .take_index_path_local => |take_path| takePathContains(take_path, target),
        .ref_path_local, .take_path_local => |take_path| takeStepsContain(take_path.steps, target),
        .ref_load => |value| exprContains(value, target),
        .ref_raw_deref, .raw_deref => |deref| exprContains(deref.expr, target),
        .from_raw => |value| exprContains(value.expr, target),
        .unary => |unary| exprContains(unary.expr, target),
        .binary => |binary| exprContains(binary.left, target) or exprContains(binary.right, target),
        .call => |call| callArgsContain(call.args, target),
        .indirect_call => |call| exprContains(call.callee, target) or callArgsContain(call.args, target),
        .test_assert => |value| exprContains(value, target),
        .builtin_print => |print| printPartsContain(print.parts, target),
        .interpolated_string => |parts| printPartsContain(parts, target),
        .sequence_push => |push| exprContains(push.object, target) or exprContains(push.value, target),
        .sequence_len,
        .sequence_clear,
        .sparse_len,
        .sparse_clear,
        .sparse_indices,
        .sequence_pop,
        .string_len,
        .string_is_empty,
        .string_bytes,
        .string_from,
        .slice_len,
        .slice_ptr,
        => |value| exprContains(value, target),
        .sparse_insert => |insert| exprContains(insert.object, target) or exprContains(insert.index, target) or exprContains(insert.value, target),
        .sparse_contains_index => |contains| exprContains(contains.object, target) or exprContains(contains.index, target),
        .sparse_take => |take| exprContains(take.object, target) or exprContains(take.index, target),
        .sequence_reserve => |reserve| exprContains(reserve.object, target) or exprContains(reserve.capacity, target),
        .string_starts_with,
        .string_ends_with,
        .string_contains,
        .string_find,
        .string_rfind,
        => |contains| exprContains(contains.object, target) or exprContains(contains.value, target),
        .string_slice => |slice| exprContains(slice.object, target) or exprContains(slice.start, target) or exprContains(slice.end, target),
        .slice_range => |slice| exprContains(slice.object, target) or
            (if (slice.start) |start| exprContains(start, target) else false) or
            (if (slice.end) |end| exprContains(end, target) else false),
        .index, .borrowed_index => |index| exprContains(index.object, target) or exprContains(index.index, target),
        .take_index_local => |index| exprContains(index.index, target),
        .array_literal, .dense_array_literal => |literal| exprSliceContains(literal.items, target),
        .tuple_literal => |literal| exprSliceContains(literal.items, target),
        .new_array => |new_array| exprContains(new_array.len, target),
        .new_sparse => |storage| exprContains(storage.capacity, target),
        .sparse_literal => |literal| exprSliceContains(literal.items, target),
        .sparse_keyed_literal => |literal| blk: {
            for (literal.entries) |entry| {
                if (exprContains(entry.index, target) or exprContains(entry.value, target)) break :blk true;
            }
            break :blk false;
        },
        .new_owned, .struct_literal => |literal| blk: {
            for (literal.fields) |field| {
                if (exprContains(field.value, target)) break :blk true;
            }
            break :blk false;
        },
        .asm_expr => |asm_expr| blk: {
            if (asm_expr.inout) |inout| {
                if (exprContains(inout.value, target)) break :blk true;
            }
            for (asm_expr.inputs) |input| {
                if (exprContains(input.value, target)) break :blk true;
            }
            break :blk false;
        },
        .field, .borrowed_field => |field| exprContains(field.object, target),
        .tuple_field => |field| exprContains(field.object, target),
        .union_field, .borrowed_union_field => |field| exprContains(field.object, target),
        .int,
        .float,
        .rune,
        .string,
        .bool,
        .none,
        .enum_case,
        .local,
        .global_ref,
        .function_ref,
        .closure_capture,
        .ref_local,
        .ref_global,
        .ref_alias_local,
        .ref_field_local,
        .ref_field_owned_local,
        .ref_union_field_local,
        .ref_owned_local,
        .raw_owned_local,
        .leak_owned_local,
        .handoff_local,
        .array_default,
        => false,
    };
}

fn exprSliceContains(expressions: []const *Expr, target: *const Expr) bool {
    for (expressions) |expr| {
        if (exprContains(expr, target)) return true;
    }
    return false;
}

fn callArgsContain(args: []const CallArg, target: *const Expr) bool {
    for (args) |arg| switch (arg) {
        .value => |value| if (exprContains(value, target)) return true,
    };
    return false;
}

fn printPartsContain(parts: []const BuiltinPrintPart, target: *const Expr) bool {
    for (parts) |part| switch (part) {
        .literal => {},
        .value => |value| if (exprContains(value.expr, target)) return true,
    };
    return false;
}

fn takeStepsContain(steps: []const TakePathStep, target: *const Expr) bool {
    for (steps) |step| switch (step) {
        .field => {},
        .index => |index| if (exprContains(index, target)) return true,
    };
    return false;
}

fn takePathContains(path: TakeIndexPathLocal, target: *const Expr) bool {
    return takeStepsContain(path.steps, target) or exprContains(path.index, target);
}

pub const InlineTest = struct {
    module_name: []const u8,
    name: []const u8,
    function_name: []const u8,

    pub fn deinit(self: InlineTest, allocator: std.mem.Allocator) void {
        allocator.free(self.function_name);
    }
};

pub const CallingConvention = enum {
    cyna,
    c,
};

pub const Global = struct {
    decl_id: ?identity.DeclId = null,
    module_name: []const u8,
    owner: ?[]const u8 = null,
    name: []const u8,
    is_mutable: bool,
    is_extern: bool = false,
    abi_name: ?[]const u8 = null,
    is_symbol_addr: bool = false,
    type_id: ?TypeId = null,
    init: ?*Expr,

    pub fn deinit(self: Global, allocator: std.mem.Allocator) void {
        if (self.init) |init| init.destroy(allocator);
    }
};

pub const AsmConst = struct {
    name: []const u8,
    value: i64,
};

pub const EnumDecl = struct {
    decl_id: ?identity.DeclId = null,
    module_name: []const u8 = "",
    name: []const u8,
    layout: EnumLayout,
    repr_name: ?[]const u8 = null,
    cases: []const EnumCase,

    pub fn deinit(self: EnumDecl, allocator: std.mem.Allocator) void {
        allocator.free(self.cases);
    }
};

pub const EnumCase = struct {
    name: []const u8,
    value: i64,
};

pub const EnumLayout = enum {
    normal,
    c,
    flags,
};

pub const UnionLayout = enum {
    normal,
    c,
};

pub const UnionKind = enum {
    named_cases,
    type_union,
};

pub const UnionDecl = struct {
    decl_id: ?identity.DeclId = null,
    module_name: []const u8 = "",
    name: []const u8,
    layout: UnionLayout,
    kind: UnionKind = .named_cases,
    fields: []const UnionField,

    pub fn deinit(self: UnionDecl, allocator: std.mem.Allocator) void {
        allocator.free(self.fields);
    }
};

pub const UnionField = struct {
    name: []const u8,
    type_id: ?TypeId = null,
    has_payload: bool,
};

pub const StructLayout = enum {
    normal,
    c,
    @"packed",
};

pub const StructDecl = struct {
    decl_id: ?identity.DeclId = null,
    module_name: []const u8 = "",
    name: []const u8,
    layout: StructLayout,
    is_shared_value: bool = false,
    shared_runtime: SharedRuntime = .none,
    drop_runtime: DropRuntime = .none,
    fields: []const FieldDecl,

    pub fn deinit(self: StructDecl, allocator: std.mem.Allocator) void {
        allocator.free(self.fields);
    }
};

pub const SharedRuntime = enum {
    none,
    arc,
};

pub const DropRuntime = enum {
    none,
    task_discard,
};

pub const FieldDecl = struct {
    name: []const u8,
    type_id: ?TypeId = null,
};

pub const Param = struct {
    name: []const u8,
    type_id: ?TypeId = null,
    binding_id: ?identity.BindingId = null,
};

pub const Function = struct {
    syntax_intrinsic_id: ?IntrinsicId = null,
    decl_id: ?identity.DeclId = null,
    module_name: []const u8 = "",
    owner: ?[]const u8,
    name: []const u8,
    abi_name: ?[]const u8 = null,
    is_extern: bool = false,
    is_export: bool = false,
    is_isolated: bool = false,
    is_test_entry: bool = false,
    calling_convention: CallingConvention = .cyna,
    params: []const Param,
    return_type_id: ?TypeId = null,
    debug_token: lexer.Token = std.mem.zeroes(lexer.Token),
    body: []const Stmt,
    effect_flow: []const EffectFlowEvent = &.{},
    effect_flow_owned: bool = false,

    pub fn deinit(self: Function, allocator: std.mem.Allocator) void {
        if (self.effect_flow_owned) allocator.free(self.effect_flow);
        allocator.free(self.params);
        for (self.body) |stmt| stmt.deinit(allocator);
        allocator.free(self.body);
    }
};

pub const TryStmt = struct {
    expr: *Expr,
    site_line: u32,
};

pub const Stmt = union(enum) {
    local: Local,
    assign: Assign,
    field_assign: FieldAssign,
    index_assign: IndexAssign,
    deref_assign: DerefAssign,
    deref_field_assign: DerefFieldAssign,
    using_alloc: UsingAlloc,
    unchecked: []const Stmt,
    asm_stmt: AsmStmt,
    @"if": If,
    @"while": While,
    @"for": For,
    @"continue": void,
    @"break": void,
    @"switch": Switch,
    yield: ?*Expr,
    @"try": TryStmt,
    @"defer": *Expr,
    drop: DropStmt,
    expr: *Expr,
    @"return": ?*Expr,

    pub fn deinit(self: Stmt, allocator: std.mem.Allocator) void {
        switch (self) {
            .local => |local| local.init.destroy(allocator),
            .assign => |assign| assign.value.destroy(allocator),
            .field_assign => |assign| assign.deinit(allocator),
            .index_assign => |assign| assign.deinit(allocator),
            .deref_assign => |assign| assign.deinit(allocator),
            .deref_field_assign => |assign| assign.deinit(allocator),
            .using_alloc => |using_alloc| using_alloc.deinit(allocator),
            .unchecked => |body| {
                for (body) |stmt| stmt.deinit(allocator);
                allocator.free(body);
            },
            .asm_stmt => |asm_stmt| asm_stmt.deinit(allocator),
            .@"if" => |if_stmt| if_stmt.deinit(allocator),
            .@"while" => |while_stmt| while_stmt.deinit(allocator),
            .@"for" => |for_stmt| for_stmt.deinit(allocator),
            .@"continue", .@"break" => {},
            .@"switch" => |switch_stmt| switch_stmt.deinit(allocator),
            .yield => |maybe_expr| if (maybe_expr) |expr| expr.destroy(allocator),
            .@"try" => |attempt| attempt.expr.destroy(allocator),
            .@"defer" => |expr| expr.destroy(allocator),
            .drop => {},
            .expr => |expr| expr.destroy(allocator),
            .@"return" => |maybe_expr| if (maybe_expr) |expr| expr.destroy(allocator),
        }
    }
};

/// The `drop` statement names a local for display, but its owning binding is
/// the checked identity that downstream analysis must use.
pub const DropStmt = struct {
    name: []const u8,
    binding_id: ?identity.BindingId = null,
    checked_effect: ?Record = null,
};

pub const AsmStmt = struct {
    lines: []const []const u8,
    inputs: []const AsmInput,
    clobbers: []const AsmClobber,
    is_volatile: bool,

    pub fn deinit(self: AsmStmt, allocator: std.mem.Allocator) void {
        for (self.inputs) |input| input.deinit(allocator);
        allocator.free(self.inputs);
        for (self.clobbers) |clobber| clobber.deinit(allocator);
        allocator.free(self.clobbers);
        allocator.free(self.lines);
    }
};

pub const AsmInput = struct {
    name: []const u8,
    constraint: AsmConstraint = .reg,
    value: *Expr,

    pub fn deinit(self: AsmInput, allocator: std.mem.Allocator) void {
        self.value.destroy(allocator);
    }
};

pub const BindingMode = enum { owning, projected };

pub const Local = struct {
    name: []const u8,
    type_id: ?TypeId = null,
    binding_id: ?identity.BindingId = null,
    binding_mode: BindingMode = .owning,
    projected_place: ?CheckedPlacePath = null,
    init: *Expr,
    checked_effect: ?Record = null,
};

pub const Assign = struct {
    name: []const u8,
    binding_id: ?identity.BindingId = null,
    global_decl_id: ?identity.DeclId = null,
    checked_non_owning_target: bool = false,
    value: *Expr,
    checked_replace: ?Record = null,
    checked_transfer: ?Record = null,
};

pub const IndexAssign = struct {
    object: *Expr,
    index: *Expr,
    value: *Expr,
    checked_projections: ?[]const CheckedPlaceProjection = null,
    checked_replace: ?Record = null,
    checked_transfer: ?Record = null,
    checked_evaluation_sites: [5]?MutationEvaluationSite = @splat(null),
    checked_evaluation_sites_len: u8 = 0,

    pub fn deinit(self: IndexAssign, allocator: std.mem.Allocator) void {
        self.object.destroy(allocator);
        self.index.destroy(allocator);
        self.value.destroy(allocator);
        if (self.checked_projections) |projections| allocator.free(projections);
    }
};

pub const FieldAssign = struct {
    root_name: []const u8,
    root_binding_id: ?identity.BindingId = null,
    root_global_decl_id: ?identity.DeclId = null,
    steps: []const StructFieldPathStep,
    checked_projections: ?[]const CheckedPlaceProjection = null,
    value: *Expr,
    capture: ?AssignmentCapture = null,
    checked_capture: ?Record = null,
    checked_replace: ?Record = null,
    checked_transfer: ?Record = null,
    checked_evaluation_sites: [4]?MutationEvaluationSite = @splat(null),
    checked_evaluation_sites_len: u8 = 0,

    pub fn deinit(self: FieldAssign, allocator: std.mem.Allocator) void {
        allocator.free(self.steps);
        if (self.checked_projections) |projections| allocator.free(projections);
        self.value.destroy(allocator);
    }
};

pub const AssignmentCapture = struct {
    name: []const u8,
    binding_id: identity.BindingId,
    type_id: TypeId,
    is_mutable: bool,
};

pub const DerefAssign = struct {
    pointer: *Expr,
    value: *Expr,
    is_volatile: bool = false,
    /// Compiler-generated initialization into previously uninitialized raw
    /// storage. No old value exists to drop.
    is_init: bool = false,
    checked_replace: ?Record = null,
    checked_transfer: ?Record = null,

    pub fn deinit(self: DerefAssign, allocator: std.mem.Allocator) void {
        self.pointer.destroy(allocator);
        self.value.destroy(allocator);
    }
};

pub const DerefFieldAssign = struct {
    pointer: *Expr,
    steps: []const StructFieldPathStep,
    value: *Expr,
    is_volatile: bool = false,
    checked_projections: ?[]const CheckedPlaceProjection = null,
    checked_replace: ?Record = null,
    checked_transfer: ?Record = null,

    pub fn deinit(self: DerefFieldAssign, allocator: std.mem.Allocator) void {
        self.pointer.destroy(allocator);
        allocator.free(self.steps);
        if (self.checked_projections) |projections| allocator.free(projections);
        self.value.destroy(allocator);
    }
};

pub const UsingAlloc = struct {
    is_scoped: bool,
    allocator_expr: *Expr,
    body: []const Stmt,

    pub fn deinit(self: UsingAlloc, allocator: std.mem.Allocator) void {
        self.allocator_expr.destroy(allocator);
        for (self.body) |stmt| stmt.deinit(allocator);
        allocator.free(self.body);
    }
};

pub const If = struct {
    kind: IfKind,
    condition: *Expr,
    union_decl_id: ?identity.DeclId = null,
    case_name: ?[]const u8,
    capture_name: ?[]const u8,
    capture_binding_id: ?identity.BindingId = null,
    capture_type_id: ?TypeId = null,
    capture_path: ?CheckedCapturePath = null,
    then_body: []const Stmt,
    else_body: []const Stmt,

    pub fn deinit(self: If, allocator: std.mem.Allocator) void {
        self.condition.destroy(allocator);
        for (self.then_body) |stmt| stmt.deinit(allocator);
        allocator.free(self.then_body);
        for (self.else_body) |stmt| stmt.deinit(allocator);
        allocator.free(self.else_body);
    }
};

pub const IfKind = enum {
    plain,
    optional_some,
    optional_none,
    union_case,
};

pub const While = struct {
    condition: *Expr,
    body: []const Stmt,

    pub fn deinit(self: While, allocator: std.mem.Allocator) void {
        self.condition.destroy(allocator);
        for (self.body) |stmt| stmt.deinit(allocator);
        allocator.free(self.body);
    }
};

pub const For = struct {
    name: []const u8,
    binding_id: ?identity.BindingId = null,
    item_type_id: ?TypeId = null,
    iterable: *Expr,
    iterator_state_type_id: ?TypeId = null,
    iterator_cursor_type_id: ?TypeId = null,
    iterator_init_decl_id: ?identity.DeclId = null,
    iterator_init_intrinsic_id: ?IntrinsicId = null,
    iterator_has_next_decl_id: ?identity.DeclId = null,
    iterator_has_next_intrinsic_id: ?IntrinsicId = null,
    iterator_next_decl_id: ?identity.DeclId = null,
    iterator_next_intrinsic_id: ?IntrinsicId = null,
    iterable_index_decl_id: ?identity.DeclId = null,
    iterable_index_intrinsic_id: ?IntrinsicId = null,
    /// Checked records for the `syntax.iter*` hooks this loop generates. The
    /// hooks are not written in the source, but each is still a method use, so
    /// it carries its own identity, signature, and specialization.
    generated_method_uses: []GeneratedMethodUse = &.{},
    body: []const Stmt,

    pub fn deinit(self: For, allocator: std.mem.Allocator) void {
        self.iterable.destroy(allocator);
        for (self.body) |stmt| stmt.deinit(allocator);
        allocator.free(self.body);
        for (self.generated_method_uses) |use| if (use.substitution.len != 0) allocator.free(use.substitution);
        if (self.generated_method_uses.len != 0) allocator.free(self.generated_method_uses);
    }
};

pub const Switch = struct {
    value: *Expr,
    // Source `catch` has an ordinary block body; this marks its internal lowering.
    catch_fallback: bool = false,
    failure_binding_id: ?identity.BindingId = null,
    result_type_id: ?TypeId = null,
    subject_type_id: ?TypeId = null,
    subject_decl_id: ?identity.DeclId = null,
    subject_type_name: []const u8,
    cases: []const SwitchCase,
    has_else: bool,
    else_body: []const Stmt,

    pub fn deinit(self: Switch, allocator: std.mem.Allocator) void {
        self.value.destroy(allocator);
        for (self.cases) |case| {
            for (case.body) |stmt| stmt.deinit(allocator);
            allocator.free(case.body);
            if (case.scalar_pattern) |pattern| switch (pattern) {
                .string => |value| allocator.free(value),
                .int => {},
            };
        }
        allocator.free(self.cases);
        for (self.else_body) |stmt| stmt.deinit(allocator);
        allocator.free(self.else_body);
    }
};

pub const SwitchCase = struct {
    case_name: []const u8,
    union_ordinal: ?u32 = null,
    scalar_pattern: ?union(enum) { int: i64, string: []const u8 } = null,
    result_case: ?ResultCase = null,
    payload_name: ?[]const u8,
    payload_binding_id: ?identity.BindingId = null,
    payload_type_id: ?TypeId = null,
    payload_path: ?CheckedCapturePath = null,
    body: []const Stmt,
};

pub const BinaryOp = enum {
    add,
    wrap_add,
    sub,
    wrap_sub,
    mul,
    wrap_mul,
    div,
    mod,
    shl,
    shr,
    bit_and,
    bit_or,
    bit_xor,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    in,
    @"and",
    @"or",
};

pub const UnaryOp = enum {
    not,
    bit_not,
    negate,
    copy_list,
};

pub const Expr = union(enum) {
    int: IntExpr,
    float: FloatExpr,
    rune: u32,
    string: []const u8,
    bool: bool,
    none,
    @"switch": Switch,
    @"try": TryExpr,
    failure_detail: FailureDetail,
    enum_case: EnumCaseExpr,
    union_case: UnionCaseExpr,
    is_test: IsTestExpr,
    cast: CastExpr,
    local: []const u8,
    global_ref: GlobalRef,
    function_ref: FunctionRef,
    closure: Closure,
    thread_spawn_boxed: ThreadSpawnBoxed,
    task_group_spawn_boxed: TaskGroupSpawnBoxed,
    task_result_take: TaskResultTake,
    sync_share_boxed: SyncShareBoxed,
    closure_capture: ClosureCapture,
    ref_local: []const u8,
    ref_global: GlobalRef,
    ref_alias_local: []const u8,
    ref_field_local: RefFieldLocal,
    ref_field_owned_local: RefFieldLocal,
    ref_field_expr: RefFieldExpr,
    ref_union_field_local: RefUnionFieldLocal,
    ref_index_local: RefIndexLocal,
    ref_index_path_local: TakeIndexPathLocal,
    ref_path_local: TakePathLocal,
    ref_load: *Expr,
    ref_owned_local: []const u8,
    raw_owned_local: []const u8,
    leak_owned_local: []const u8,
    handoff_local: []const u8,
    ref_raw_deref: RawDeref,
    raw_deref: RawDeref,
    from_raw: FromRaw,
    unary: Unary,
    binary: Binary,
    call: Call,
    indirect_call: IndirectCall,
    test_assert: *Expr,
    builtin_print: BuiltinPrint,
    interpolated_string: []const BuiltinPrintPart,
    sequence_push: SequencePush,
    sequence_len: *Expr,
    sequence_clear: *Expr,
    sparse_len: *Expr,
    sparse_clear: *Expr,
    sparse_indices: *Expr,
    sparse_insert: SparseInsert,
    sparse_contains_index: SparseContainsIndex,
    sparse_take: SparseTake,
    sequence_reserve: SequenceReserve,
    sequence_pop: *Expr,
    string_len: *Expr,
    string_is_empty: *Expr,
    string_bytes: *Expr,
    string_from: *Expr,
    string_starts_with: StringContains,
    string_ends_with: StringContains,
    string_contains: StringContains,
    string_find: StringContains,
    string_rfind: StringContains,
    string_slice: StringSlice,
    slice_range: SliceRange,
    slice_len: *Expr,
    slice_ptr: *Expr,
    index: Index,
    borrowed_index: Index,
    take_index_local: TakeIndexLocal,
    take_index_path_local: TakeIndexPathLocal,
    take_path_local: TakePathLocal,
    array_literal: ArrayLiteral,
    tuple_literal: TupleLiteral,
    array_default: ArrayDefault,
    new_array: NewArray,
    dense_array_literal: ArrayLiteral,
    sparse_literal: SparseLiteral,
    sparse_keyed_literal: SparseKeyedLiteral,
    new_sparse: SparseArray,
    new_owned: StructLiteral,
    struct_literal: StructLiteral,
    asm_expr: AsmExpr,
    field: FieldAccess,
    tuple_field: TupleFieldAccess,
    borrowed_field: FieldAccess,
    union_field: UnionFieldAccess,
    borrowed_union_field: UnionFieldAccess,

    pub fn destroy(self: *Expr, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
        allocator.destroy(self);
    }

    // Release children while the caller retains ownership of the expression node.
    pub fn deinit(self: *Expr, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .int => {},
            .float => {},
            .rune => {},
            .string => {},
            .bool => {},
            .none => {},
            .@"switch" => |switch_expr| switch_expr.deinit(allocator),
            .@"try" => |try_expr| try_expr.expr.destroy(allocator),
            .failure_detail => |detail| if (detail.index) |index| index.destroy(allocator),
            .enum_case => {},
            .union_case => |case| {
                if (case.value) |value| value.destroy(allocator);
                if (case.throw_message) |message| allocator.free(message);
            },
            .is_test => |is_test| is_test.subject.destroy(allocator),
            .cast => |cast| cast.subject.destroy(allocator),
            .local => {},
            .global_ref => {},
            .function_ref => {},
            .closure => |closure| {
                for (closure.captures) |capture| capture.destroy(allocator);
                allocator.free(closure.captures);
                if (closure.checked_transfers) |records| allocator.free(records);
            },
            .thread_spawn_boxed => |spawn| spawn.payload.destroy(allocator),
            .task_group_spawn_boxed => |spawn| {
                spawn.group_raw.destroy(allocator);
                spawn.entry.destroy(allocator);
                spawn.payload.destroy(allocator);
            },
            .task_result_take => |take| {
                take.witness.destroy(allocator);
                take.pointer.destroy(allocator);
            },
            .sync_share_boxed => |share| share.payload.destroy(allocator),
            .closure_capture => {},
            .ref_local => {},
            .ref_global => {},
            .ref_alias_local => {},
            .ref_field_local => {},
            .ref_field_owned_local => {},
            .ref_field_expr => |field| field.object.destroy(allocator),
            .ref_union_field_local => {},
            .ref_index_local => |index| index.index.destroy(allocator),
            .ref_index_path_local => |take_path| {
                for (take_path.steps) |step| switch (step) {
                    .field => {},
                    .index => |index| index.destroy(allocator),
                };
                allocator.free(take_path.steps);
                take_path.index.destroy(allocator);
            },
            .ref_path_local => |take_path| {
                for (take_path.steps) |step| switch (step) {
                    .field => {},
                    .index => |index| index.destroy(allocator),
                };
                allocator.free(take_path.steps);
            },
            .ref_load => |expr| expr.destroy(allocator),
            .ref_owned_local => {},
            .raw_owned_local => {},
            .leak_owned_local => {},
            .handoff_local => {},
            .ref_raw_deref => |deref| deref.expr.destroy(allocator),
            .raw_deref => |deref| deref.expr.destroy(allocator),
            .from_raw => |value| value.expr.destroy(allocator),
            .unary => |unary| unary.expr.destroy(allocator),
            .binary => |binary| {
                binary.left.destroy(allocator);
                binary.right.destroy(allocator);
            },
            .call => |call| {
                for (call.args) |arg| arg.deinit(allocator);
                allocator.free(call.args);
                if (call.checked_arguments_owned) allocator.free(call.checked_arguments);
                if (call.checked_evaluation_sites_owned) allocator.free(call.checked_evaluation_sites);
                if (call.checked_method_use) |use| {
                    if (use.substitution.len != 0) allocator.free(use.substitution);
                }
            },
            .indirect_call => |call| {
                call.callee.destroy(allocator);
                for (call.args) |arg| arg.deinit(allocator);
                allocator.free(call.args);
                if (call.checked_arguments) |records| allocator.free(records);
            },
            .test_assert => |expr| expr.destroy(allocator),
            .builtin_print => |print| {
                for (print.parts) |part| part.deinit(allocator);
                allocator.free(print.parts);
            },
            .interpolated_string => |parts| {
                for (parts) |part| part.deinit(allocator);
                allocator.free(parts);
            },
            .sequence_push => |push| {
                push.object.destroy(allocator);
                push.value.destroy(allocator);
            },
            .sequence_len => |expr| expr.destroy(allocator),
            .sequence_clear => |expr| expr.destroy(allocator),
            .sparse_len => |expr| expr.destroy(allocator),
            .sparse_clear => |expr| expr.destroy(allocator),
            .sparse_indices => |expr| expr.destroy(allocator),
            .sparse_insert => |insert| {
                insert.object.destroy(allocator);
                insert.index.destroy(allocator);
                insert.value.destroy(allocator);
            },
            .sparse_contains_index => |contains| {
                contains.object.destroy(allocator);
                contains.index.destroy(allocator);
            },
            .sparse_take => |take| {
                take.object.destroy(allocator);
                take.index.destroy(allocator);
            },
            .sequence_reserve => |reserve| {
                reserve.object.destroy(allocator);
                reserve.capacity.destroy(allocator);
            },
            .sequence_pop => |expr| expr.destroy(allocator),
            .string_len => |expr| expr.destroy(allocator),
            .string_is_empty => |expr| expr.destroy(allocator),
            .string_bytes => |expr| expr.destroy(allocator),
            .string_from => |expr| expr.destroy(allocator),
            .string_starts_with => |contains| {
                contains.object.destroy(allocator);
                contains.value.destroy(allocator);
            },
            .string_ends_with => |contains| {
                contains.object.destroy(allocator);
                contains.value.destroy(allocator);
            },
            .string_contains => |contains| {
                contains.object.destroy(allocator);
                contains.value.destroy(allocator);
            },
            .string_find => |contains| {
                contains.object.destroy(allocator);
                contains.value.destroy(allocator);
            },
            .string_rfind => |contains| {
                contains.object.destroy(allocator);
                contains.value.destroy(allocator);
            },
            .string_slice => |slice| {
                slice.object.destroy(allocator);
                slice.start.destroy(allocator);
                slice.end.destroy(allocator);
            },
            .slice_range => |slice| {
                slice.object.destroy(allocator);
                if (slice.start) |start| start.destroy(allocator);
                if (slice.end) |end| end.destroy(allocator);
            },
            .slice_len => |expr| expr.destroy(allocator),
            .slice_ptr => |expr| expr.destroy(allocator),
            .index => |index| {
                index.object.destroy(allocator);
                index.index.destroy(allocator);
            },
            .borrowed_index => |index| {
                index.object.destroy(allocator);
                index.index.destroy(allocator);
            },
            .take_index_local => |index| index.index.destroy(allocator),
            .take_index_path_local => |take_path| {
                for (take_path.steps) |step| switch (step) {
                    .field => {},
                    .index => |index| index.destroy(allocator),
                };
                allocator.free(take_path.steps);
                take_path.index.destroy(allocator);
            },
            .take_path_local => |take_path| {
                for (take_path.steps) |step| switch (step) {
                    .field => {},
                    .index => |index| index.destroy(allocator),
                };
                allocator.free(take_path.steps);
            },
            .array_literal => |literal| {
                for (literal.items) |item| item.destroy(allocator);
                allocator.free(literal.items);
                if (literal.checked_transfers) |records| allocator.free(records);
            },
            .tuple_literal => |literal| {
                for (literal.items) |item| item.destroy(allocator);
                allocator.free(literal.items);
                if (literal.checked_transfers) |records| allocator.free(records);
            },
            .array_default => {},
            .new_array => |new_array| new_array.len.destroy(allocator),
            .new_sparse => |storage| storage.capacity.destroy(allocator),
            .dense_array_literal => |literal| {
                for (literal.items) |item| item.destroy(allocator);
                allocator.free(literal.items);
                if (literal.checked_transfers) |records| allocator.free(records);
            },
            .sparse_literal => |literal| {
                for (literal.items) |item| item.destroy(allocator);
                allocator.free(literal.items);
                if (literal.checked_transfers) |records| allocator.free(records);
            },
            .sparse_keyed_literal => |literal| {
                for (literal.entries) |entry| {
                    entry.index.destroy(allocator);
                    entry.value.destroy(allocator);
                }
                allocator.free(literal.entries);
                if (literal.checked_transfers) |records| allocator.free(records);
            },
            .new_owned => |literal| {
                for (literal.fields) |field| field.value.destroy(allocator);
                allocator.free(literal.fields);
            },
            .struct_literal => |literal| {
                for (literal.fields) |field| field.value.destroy(allocator);
                allocator.free(literal.fields);
            },
            .asm_expr => |asm_expr| asm_expr.deinit(allocator),
            .field => |field| field.object.destroy(allocator),
            .tuple_field => |field| field.object.destroy(allocator),
            .borrowed_field => |field| field.object.destroy(allocator),
            .union_field => |field| field.object.destroy(allocator),
            .borrowed_union_field => |field| field.object.destroy(allocator),
        }
    }
};

pub const GlobalRef = struct {
    decl_id: ?identity.DeclId = null,
    module_name: []const u8,
    owner: ?[]const u8 = null,
    name: []const u8,
};

pub const FunctionRef = struct {
    decl_id: ?identity.DeclId = null,
    module_name: []const u8,
    owner: ?[]const u8,
    name: []const u8,
};

pub const ThreadSpawnBoxed = struct {
    intrinsic_id: ?IntrinsicId = null,
    decl_id: ?identity.DeclId = null,
    module_name: []const u8,
    owner: ?[]const u8,
    callee: []const u8,
    trampoline: FunctionRef,
    payload: *Expr,
    payload_type_id: ?TypeId = null,
    return_type_id: ?TypeId = null,
    checked_payload_transfer: ?Record = null,
};

pub const TaskGroupSpawnBoxed = struct {
    intrinsic_id: ?IntrinsicId = .std_task_group_spawn_impl,
    decl_id: ?identity.DeclId = null,
    module_name: []const u8,
    owner: ?[]const u8,
    callee: []const u8,
    trampoline: FunctionRef,
    group_raw: *Expr,
    entry: *Expr,
    payload: *Expr,
    payload_type_id: ?TypeId = null,
    result_type_id: ?TypeId = null,
    return_type_id: ?TypeId = null,
    checked_payload_transfer: ?Record = null,
};

pub const TaskResultTake = struct {
    intrinsic_id: ?IntrinsicId = .std_task_result_take_impl,
    witness: *Expr,
    pointer: *Expr,
    value_type_id: ?TypeId = null,
    return_type_id: ?TypeId = null,
    checked_payload_take: ?Record = null,
};

pub const SyncShareBoxed = struct {
    intrinsic_id: ?IntrinsicId = null,
    decl_id: ?identity.DeclId = null,
    module_name: []const u8,
    owner: ?[]const u8,
    callee: []const u8,
    payload: *Expr,
    payload_type_id: ?TypeId = null,
    return_type_id: ?TypeId = null,
    checked_payload_transfer: ?Record = null,
    checked_result_effect: ?Record = null,
};

pub const Closure = struct {
    function: FunctionRef,
    env_type_name: []const u8,
    env_decl_id: ?identity.DeclId = null,
    captures: []const *Expr,
    checked_transfers: ?[]?Record = null,
};

pub const ClosureCapture = struct {
    env_name: []const u8,
    env_type_name: []const u8,
    env_decl_id: identity.DeclId,
    field_index: u32,
    type_id: ?TypeId = null,
};

pub const AsmExpr = struct {
    target_type_id: ?TypeId = null,
    lines: []const []const u8,
    output: ?AsmOutput,
    inout: ?AsmInput,
    inputs: []const AsmInput,
    clobbers: []const AsmClobber,
    is_volatile: bool,

    pub fn deinit(self: AsmExpr, allocator: std.mem.Allocator) void {
        if (self.inout) |inout| inout.deinit(allocator);
        for (self.inputs) |input| input.deinit(allocator);
        allocator.free(self.inputs);
        for (self.clobbers) |clobber| clobber.deinit(allocator);
        allocator.free(self.clobbers);
        allocator.free(self.lines);
    }
};

pub const FsWriteFile = struct {
    path: *Expr,
    data: *Expr,
};

pub const AsmOutput = struct {
    name: []const u8,
    constraint: AsmConstraint = .reg,
};

pub const AsmConstraint = enum {
    reg,
    tied_reg,
};

pub const AsmClobber = union(enum) {
    memory,
    flags,
    register: []const u8,

    pub fn deinit(self: AsmClobber, allocator: std.mem.Allocator) void {
        switch (self) {
            .register => |name| allocator.free(name),
            else => {},
        }
    }
};

pub const IntExpr = struct {
    value: i64,
    unsigned_value: ?u64 = null,
    type_name: ?[]const u8,
};

pub const FloatExpr = struct {
    value: f64,
    type_name: ?[]const u8,
};

pub const SequencePush = struct {
    object: *Expr,
    value: *Expr,
    checked_transfer: ?Record = null,
};

pub const SparseInsert = struct {
    object: *Expr,
    index: *Expr,
    value: *Expr,
    checked_replace: ?Record = null,
    checked_transfer: ?Record = null,
};

pub const SparseContainsIndex = struct {
    object: *Expr,
    index: *Expr,
};

pub const SparseTake = struct {
    object: *Expr,
    index: *Expr,
};

pub const BuiltinPrintPart = union(enum) {
    literal: []const u8,
    value: BuiltinPrintValue,

    pub fn deinit(self: BuiltinPrintPart, allocator: std.mem.Allocator) void {
        switch (self) {
            .literal => |text| allocator.free(text),
            .value => |value| value.expr.destroy(allocator),
        }
    }
};

pub const DebugFormat = enum {
    direct,
    decimal,
    binary,
    octal,
    hex_lower,
    hex_upper,
};

pub const BuiltinPrintValue = struct {
    expr: *Expr,
    format: DebugFormat,
    /// Checked declaration identity of the prelude helper this part prints
    /// through. Interpolation holes build a string instead of printing, so
    /// they carry no helper identity.
    helper_declaration_id: ?identity.DeclId = null,
};

pub const BuiltinPrint = struct {
    parts: []const BuiltinPrintPart,
    append_newline: bool,
    /// Checked declaration identity of the prelude helper the trailing newline
    /// reaches. Lowering emits from this id and never resolves a helper name.
    newline_helper_declaration_id: ?identity.DeclId = null,
};

pub const SequenceReserve = struct {
    object: *Expr,
    capacity: *Expr,
};

pub const Index = struct {
    object: *Expr,
    index: *Expr,
};

pub const TakeIndexLocal = struct {
    local_name: []const u8,
    index: *Expr,
};

pub const TryExpr = struct {
    expr: *Expr,
    site_line: u32 = 0,
    result_ok_type_id: ?TypeId = null,
    result_err_type_id: ?TypeId = null,
    widen_ordinal: ?u32 = null,
};

pub const FailureDetailField = enum { available, origin, origin_file, site_count, omitted, message, site, site_file };

pub const FailureDetail = struct {
    binding_id: identity.BindingId,
    field: FailureDetailField,
    index: ?*Expr = null,
};

pub const EnumCaseExpr = struct {
    decl_id: ?identity.DeclId = null,
    type_name: []const u8,
    case_name: []const u8,
    value: i64,
};

pub const UnionCaseExpr = struct {
    decl_id: ?identity.DeclId = null,
    inline_union_type_id: ?TypeId = null,
    inline_union_ordinal: ?u32 = null,
    union_name: []const u8,
    case_name: []const u8,
    result_case: ?ResultCase = null,
    // True only for the compiler's internal `.err` constructed by source `throw`.
    from_throw: bool = false,
    // Exact local supplying a direct `throw local`; later catch lowering can
    // compare it with the catch-code binding, without comparing error codes.
    throw_local_binding_id: ?identity.BindingId = null,
    throw_message: ?[]const u8 = null,
    throw_source_line: u32 = 0,
    value: ?*Expr,
    checked_transfer: ?Record = null,
    result_ok_type_id: ?TypeId = null,
    result_err_type_id: ?TypeId = null,
};

pub const IsTestExpr = struct {
    subject: *Expr,
    kind: IsTestKind,
    case_name: ?[]const u8,
};

pub const CastExpr = struct {
    subject: *Expr,
    source_union_decl_id: ?identity.DeclId = null,
    target_type_id: ?TypeId = null,
    union_case_name: ?[]const u8,
    fallible: bool,
    reinterpret: bool,
};

pub const IsTestKind = enum {
    optional_some,
    optional_none,
    union_case,
};

pub const Binary = struct {
    op: BinaryOp,
    left: *Expr,
    right: *Expr,
};

pub const Unary = struct {
    op: UnaryOp,
    expr: *Expr,
};

pub const RawDeref = struct {
    expr: *Expr,
    is_volatile: bool = false,
};

pub const FromRaw = struct {
    expr: *Expr,
    is_volatile: bool = false,
};

pub const Call = struct {
    intrinsic_id: ?IntrinsicId = null,
    decl_id: ?identity.DeclId = null,
    checked_method_use: ?CheckedMethodUse = null,
    module_name: []const u8,
    owner: ?[]const u8,
    callee: []const u8,
    args: []const CallArg,
    checked_arguments: []const Record = &.{},
    checked_arguments_owned: bool = false,
    checked_result_effect: ?Record = null,
    checked_terminal_effect: ?Record = null,
    checked_evaluation_sites: []const CallEvaluationSite = &.{},
    checked_evaluation_sites_owned: bool = false,
};

pub fn exprDefinitelyDiverges(expr: *const Expr) bool {
    return switch (expr.*) {
        .test_assert => |condition| condition.* == .bool and !condition.bool,
        .call => |call| call.owner == null and
            std.mem.eql(u8, call.module_name, "std.prelude") and
            std.mem.eql(u8, call.callee, "panic"),
        else => false,
    };
}

pub const CheckedMethodUse = struct {
    use_id: u32,
    source_declaration_id: identity.DeclId,
    source_offset: usize,
    /// A use the lowering settles to a declaration rather than a protocol
    /// witness carries no protocol identity; its authority is the concrete
    /// callee the record names.
    protocol_id: ?identity.DeclId = null,
    method_id: ?identity.DeclId = null,
    /// The concrete declaration the use lowers to, the type that use settles,
    /// and the canonical type ids the specialization substituted for the
    /// callee's generic parameters. Together these are the checked signature
    /// of the use, so lowering and the checked body flow agree on one record.
    callee_declaration_id: ?identity.DeclId = null,
    result_type_id: ?TypeId = null,
    substitution: []const TypeId = &.{},
};

/// One of the `syntax.iter*` hook calls a `for` loop generates. A generated
/// use is not written in the source, but it is still a method use, so it
/// carries the same checked identity as a source use: a stable id, the
/// concrete hook declaration it resolves to, the receiver and result types,
/// and the specialization the hook was instantiated with.
pub const GeneratedIterationRole = enum {
    iterator_init,
    iterator_has_next,
    iterator_next,
    iterable_item,
};

pub const GeneratedMethodUse = struct {
    use_id: u32,
    role: GeneratedIterationRole,
    source_declaration_id: identity.DeclId,
    source_offset: usize,
    subject_type_id: TypeId,
    receiver_type_id: TypeId,
    method_declaration_id: identity.DeclId,
    result_type_id: TypeId,
    substitution: []const TypeId = &.{},
};

const GeneratedIterationHook = struct {
    role: GeneratedIterationRole,
    declaration_id: ?identity.DeclId,
    /// The type the loop declares this hook settles, or null when the check
    /// must derive it from the hook's own signature.
    result_type_id: ?TypeId,
};

fn verifyGeneratedIterationLoop(module: *const Module, loop: For) VerifyGenericRequirementsError!void {
    const hooks = [_]GeneratedIterationHook{
        .{ .role = .iterator_init, .declaration_id = loop.iterator_init_decl_id, .result_type_id = loop.iterator_state_type_id },
        .{ .role = .iterator_has_next, .declaration_id = loop.iterator_has_next_decl_id, .result_type_id = null },
        .{ .role = .iterator_next, .declaration_id = loop.iterator_next_decl_id, .result_type_id = loop.iterator_cursor_type_id },
        .{ .role = .iterable_item, .declaration_id = loop.iterable_index_decl_id, .result_type_id = loop.item_type_id },
    };
    var hook_count: usize = 0;
    for (hooks) |hook| {
        if (hook.declaration_id != null) hook_count += 1;
    }
    if (hook_count == 0) return;
    if (module.canonical_types == null) return error.MissingCanonicalTypes;
    const canonical = &module.canonical_types.?;
    if (loop.generated_method_uses.len != hook_count) return error.MissingGeneratedMethodUse;
    const iterable_metadata = module.metadataForExpr(loop.iterable) orelse return error.MissingExpressionMetadata;
    // Every hook role the loop reaches is claimed by exactly one record.
    for (hooks) |hook| {
        if (hook.declaration_id == null) continue;
        var claims: usize = 0;
        for (loop.generated_method_uses) |record| {
            if (record.role == hook.role) claims += 1;
        }
        if (claims > 1) return error.DuplicateGeneratedMethodUse;
    }
    for (hooks) |hook| {
        const declaration_id = hook.declaration_id orelse continue;
        const record = for (loop.generated_method_uses) |candidate| {
            if (candidate.role == hook.role) break candidate;
        } else return error.MissingGeneratedMethodUse;
        if (record.use_id == 0) return error.MissingMethodUseIdentity;
        if (record.method_declaration_id != declaration_id) return error.IncorrectGeneratedMethodUse;
        const result = record.result_type_id;
        const result_type = canonical.get(result) catch return error.IncorrectGeneratedMethodUse;
        if (hook.result_type_id != null) {
            // The item hook may settle a borrowed view of the loop's item type.
            const declared = hook.result_type_id.?;
            if (declared != result and !(result_type.* == .ref_ and result_type.ref_.target == declared)) {
                return error.IncorrectGeneratedMethodUse;
            }
        } else if (result_type.* != .primitive or result_type.primitive != .bool) {
            return error.IncorrectGeneratedMethodUse;
        }
        var hook_index: ?usize = null;
        for (module.functions, 0..) |function, index| {
            if (function.decl_id == declaration_id) {
                hook_index = index;
                break;
            }
        }
        if (hook_index == null) return error.IncorrectGeneratedMethodUse;
        const hook_function = module.functions[hook_index.?];
        if (hook_function.return_type_id != result) return error.IncorrectGeneratedMethodUse;
        if (record.receiver_type_id != record.subject_type_id or record.subject_type_id != iterable_metadata.type_id) {
            return error.IncorrectGeneratedMethodUse;
        }
        for (record.substitution) |substituted| {
            var used = false;
            for (hook_function.params) |param| {
                if (param.type_id) |type_id| {
                    if (typeTreeContains(canonical, module, type_id, substituted, 0)) {
                        used = true;
                        break;
                    }
                }
            }
            if (!used and hook_function.return_type_id != null) {
                used = typeTreeContains(canonical, module, hook_function.return_type_id.?, substituted, 0);
            }
            if (!used) return error.InvalidMethodUseSubstitution;
        }
    }
    for (loop.generated_method_uses, 0..) |record, index| {
        if (record.use_id == 0) return error.MissingMethodUseIdentity;
        for (loop.generated_method_uses[0..index]) |prior| {
            if (prior.use_id == record.use_id) return error.DuplicateGeneratedMethodUse;
        }
    }
}

pub const IndirectCall = struct {
    callee: *Expr,
    args: []const CallArg,
    return_type_id: ?TypeId = null,
    is_arrow_callable: bool = false,
    checked_payload_transfer: ?Record = null,
    checked_arguments: ?[]?Record = null,
    checked_result_effect: ?Record = null,
    checked_evaluation_sites: [4]?CallEvaluationSite = @splat(null),
    checked_evaluation_sites_len: u8 = 0,
};

pub const CallArg = union(enum) {
    value: *Expr,

    pub fn deinit(self: CallArg, allocator: std.mem.Allocator) void {
        switch (self) {
            .value => |expr| expr.destroy(allocator),
        }
    }
};

pub const ArrayLiteral = struct {
    len: usize,
    capacity: ?usize = null,
    item_type_id: ?TypeId = null,
    items: []const *Expr,
    checked_transfers: ?[]?Record = null,
};

pub const TupleLiteral = struct {
    type_id: TypeId,
    items: []const *Expr,
    checked_transfers: ?[]?Record = null,
};

pub const ArrayDefault = struct {
    len: usize,
    item_type_id: ?TypeId = null,
};

pub const NewArray = struct {
    len: *Expr,
    item_type_id: ?TypeId = null,
};

pub const SparseArray = struct {
    capacity: *Expr,
    item_type_id: ?TypeId = null,
};

pub const SparseLiteral = struct {
    capacity: usize,
    len: usize,
    item_type_id: ?TypeId = null,
    items: []const *Expr,
    checked_transfers: ?[]?Record = null,
};

pub const SparseKeyedLiteral = struct {
    capacity: usize,
    item_type_id: ?TypeId = null,
    entries: []const SparseKeyedLiteralEntry,
    checked_transfers: ?[]?Record = null,
};

pub const SparseKeyedLiteralEntry = struct {
    index: *Expr,
    value: *Expr,
};

pub const StringContains = struct {
    object: *Expr,
    value: *Expr,
};

pub const StringSlice = struct {
    object: *Expr,
    start: *Expr,
    end: *Expr,
};

pub const StructLiteral = struct {
    decl_id: ?identity.DeclId = null,
    type_name: []const u8,
    type_module_name: ?[]const u8 = null,
    fields: []const StructLiteralField,
};

pub const StructLiteralField = struct {
    name: []const u8,
    value: *Expr,
    checked_transfer: ?Record = null,
};

pub const FieldAccess = struct {
    object: *Expr,
    struct_decl_id: ?identity.DeclId = null,
    struct_name: []const u8,
    field: []const u8,
};

pub const TupleFieldAccess = struct {
    object: *Expr,
    tuple_type_id: TypeId,
    index: usize,
};

pub const SliceRange = struct {
    object: *Expr,
    start: ?*Expr = null,
    end: ?*Expr = null,
};

pub const UnionFieldAccess = struct {
    object: *Expr,
    union_decl_id: ?identity.DeclId = null,
    union_name: []const u8,
    field: []const u8,
};

pub const RefFieldLocal = struct {
    local_name: []const u8,
    struct_decl_id: ?identity.DeclId = null,
    struct_name: []const u8,
    field: []const u8,
};

pub const RefFieldExpr = struct {
    object: *Expr,
    struct_decl_id: ?identity.DeclId = null,
    struct_name: []const u8,
    field: []const u8,
};

pub const RefUnionFieldLocal = struct {
    local_name: []const u8,
    union_decl_id: ?identity.DeclId = null,
    union_name: []const u8,
    field: []const u8,
};

pub const RefIndexLocal = struct {
    local_name: []const u8,
    index: *Expr,
};

/// Canonical addressable-place projection used by alias, mutation, and detach
/// lowering. `TakePathStep` remains as a compatibility name while the older
/// source-shaped SIR expressions migrate incrementally.
pub const PlaceProjectionStep = union(enum) {
    field: StructFieldPathStep,
    index: *Expr,
};

pub const TakePathStep = PlaceProjectionStep;

pub const LocalPlaceRoot = struct {
    name: []const u8,
    dereference_pointer: bool = true,
};

pub const PlaceRoot = union(enum) {
    local: LocalPlaceRoot,
    global: GlobalRef,
    pointer_expr: *Expr,
};

/// Non-owning view of already-owned SIR nodes. Callers retain ownership of
/// `pointer_expr`, index expressions, and the projection slice.
pub const ResolvedPlacePath = struct {
    root: PlaceRoot,
    projections: []const PlaceProjectionStep = &.{},
};

pub const StructFieldPathStep = struct {
    struct_decl_id: ?identity.DeclId = null,
    struct_name: []const u8,
    field: []const u8,
};

pub const TakeIndexPathLocal = struct {
    local_name: []const u8,
    steps: []const TakePathStep,
    index: *Expr,
};

pub const TakePathLocal = struct {
    local_name: []const u8,
    steps: []const TakePathStep,
};

fn dumpType(writer: anytype, module: Module, type_id: ?TypeId) anyerror!void {
    const id = type_id orelse return writer.writeAll("<missing-type>");
    const types = if (module.canonical_types) |*value| value else return writer.writeAll("<missing-types>");
    try dumpCanonicalType(writer, module, types, id);
}

fn dumpCanonicalType(writer: anytype, module: Module, types: *const semantic_types.TypeInterner, type_id: TypeId) anyerror!void {
    const ty = try types.get(type_id);
    switch (ty.*) {
        .primitive => |primitive| try writer.writeAll(@tagName(primitive)),
        .generic_parameter => |parameter| try writer.writeAll(parameter.name),
        .inferred_integer => try writer.writeAll("int"),
        .inferred_float => try writer.writeAll("float"),
        .integer => |integer| switch (integer.domain) {
            .fixed => try writer.print("{c}{d}", .{ if (integer.signed) @as(u8, 'i') else @as(u8, 'u'), integer.bits }),
            else => try writer.writeAll(@tagName(integer.domain)),
        },
        .float => |float| switch (float.domain) {
            .fixed => try writer.print("f{d}", .{float.bits}),
            else => try writer.writeAll(@tagName(float.domain)),
        },
        .nominal => |nominal| try writer.writeAll(typeDeclName(module, nominal.decl_id) orelse "<unknown-type>"),
        .generic_instance => |instance| try writer.writeAll(if (instance.decl_id) |decl_id|
            typeDeclName(module, decl_id) orelse "<unknown-type>"
        else
            typeDeclName(module, instance.base_decl_id) orelse "<unknown-type>"),
        .optional => try writer.writeAll("optional"),
        .array => try writer.writeAll("array"),
        .tuple => try writer.writeAll("tuple"),
        .dense_array => try writer.writeAll("dense_array"),
        .sparse_array => try writer.writeAll("sparse_array"),
        .slice => try writer.writeAll("slice"),
        .result => try writer.writeAll(language_contracts.result_type_name),
        .error_union => try writer.writeAll("inline_error_union"),
        .ref_ => try writer.writeAll("ref"),
        .owned => try writer.writeAll("owned"),
        .raw => try writer.writeAll("raw"),
        .callable => |callable| try writer.writeAll(if (callable.kind == .arrow) "arrow_callable" else "function"),
    }
}

fn typeDeclName(module: Module, decl_id: identity.DeclId) ?[]const u8 {
    for (module.enums) |decl| if (decl.decl_id == decl_id) return decl.name;
    for (module.unions) |decl| if (decl.decl_id == decl_id) return decl.name;
    for (module.structs) |decl| if (decl.decl_id == decl_id) return decl.name;
    return null;
}

fn isVoidType(module: Module, type_id: ?TypeId) bool {
    const id = type_id orelse return false;
    const types = if (module.canonical_types) |*value| value else return false;
    const ty = types.get(id) catch return false;
    return ty.* == .primitive and (ty.primitive == .void or ty.primitive == .c_void);
}

fn writeIndent(writer: anytype, indent: usize) anyerror!void {
    for (0..indent) |_| {
        try writer.writeAll("  ");
    }
}

fn dumpBlock(writer: anytype, module: Module, indent: usize, body: []const Stmt) anyerror!void {
    for (body) |stmt| {
        try dumpStmt(writer, module, indent, stmt);
    }
}

fn dumpStmt(writer: anytype, module: Module, indent: usize, stmt: Stmt) anyerror!void {
    try writeIndent(writer, indent);
    switch (stmt) {
        .yield => |maybe_expr| {
            try writer.writeAll("yield");
            if (maybe_expr) |expr| {
                try writer.writeAll(" ");
                try dumpExpr(writer, module, expr);
            }
            try writer.writeAll("\n");
        },
        .local => |local| {
            try writer.print("{s} {s}: ", .{ if (local.binding_mode == .projected) @as([]const u8, "projected") else "var", local.name });
            try dumpType(writer, module, local.type_id);
            try writer.writeAll(" = ");
            try dumpExpr(writer, module, local.init);
            try writer.writeAll("\n");
        },
        .assign => |assign| {
            try writer.print("{s} = ", .{assign.name});
            try dumpExpr(writer, module, assign.value);
            try writer.writeAll("\n");
        },
        .field_assign => |assign| {
            try writer.print("{s}", .{assign.root_name});
            for (assign.steps) |step| {
                try writer.print(".{s}", .{step.field});
            }
            try writer.writeAll(" = ");
            try dumpExpr(writer, module, assign.value);
            if (assign.capture) |capture| try writer.print(" @ {s} {s}", .{ if (capture.is_mutable) @as([]const u8, "var") else "const", capture.name });
            try writer.writeAll("\n");
        },
        .index_assign => |assign| {
            try dumpExpr(writer, module, assign.object);
            try writer.writeAll("[");
            try dumpExpr(writer, module, assign.index);
            try writer.writeAll("] = ");
            try dumpExpr(writer, module, assign.value);
            try writer.writeAll("\n");
        },
        .deref_assign => |assign| {
            try writer.writeAll("*");
            try dumpExpr(writer, module, assign.pointer);
            if (assign.is_volatile) try writer.writeAll(" /* volatile */");
            try writer.writeAll(" = ");
            try dumpExpr(writer, module, assign.value);
            try writer.writeAll("\n");
        },
        .deref_field_assign => |assign| {
            try writer.writeAll("*");
            try dumpExpr(writer, module, assign.pointer);
            if (assign.is_volatile) try writer.writeAll(" /* volatile */");
            for (assign.steps) |step| {
                try writer.print(".{s}", .{step.field});
            }
            try writer.writeAll(" = ");
            try dumpExpr(writer, module, assign.value);
            try writer.writeAll("\n");
        },
        .using_alloc => |using_alloc| {
            try writer.writeAll("using ");
            if (using_alloc.is_scoped) try writer.writeAll("scoped ");
            try writer.writeAll("alloc = ");
            try dumpExpr(writer, module, using_alloc.allocator_expr);
            try writer.writeAll(" {\n");
            try dumpBlock(writer, module, indent + 1, using_alloc.body);
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .unchecked => |body| {
            try writer.writeAll("unchecked {\n");
            try dumpBlock(writer, module, indent + 1, body);
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .asm_stmt => |asm_stmt| {
            try writer.writeAll("asm");
            if (asm_stmt.is_volatile) try writer.writeAll(" volatile");
            try writer.writeAll(" {\n");
            for (asm_stmt.lines) |line| {
                try writeIndent(writer, indent + 1);
                try writer.print("\"{s}\";\n", .{line});
            }
            for (asm_stmt.inputs) |input| {
                try writeIndent(writer, indent + 1);
                try writer.print("in {s} {s} = ", .{ @tagName(input.constraint), input.name });
                try dumpExpr(writer, module, input.value);
                try writer.writeAll(";\n");
            }
            for (asm_stmt.clobbers) |clobber| {
                try writeIndent(writer, indent + 1);
                switch (clobber) {
                    .memory => try writer.writeAll("clobber memory;\n"),
                    .flags => try writer.writeAll("clobber flags;\n"),
                    .register => |name| try writer.print("clobber {s};\n", .{name}),
                }
            }
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .@"if" => |if_stmt| {
            try writer.writeAll("if ");
            try dumpExpr(writer, module, if_stmt.condition);
            switch (if_stmt.kind) {
                .plain => {},
                .optional_some => try writer.writeAll(" is some"),
                .optional_none => try writer.writeAll(" is none"),
                .union_case => {},
            }
            if (if_stmt.case_name) |case_name| {
                try writer.print(" {s}", .{case_name});
            }
            if (if_stmt.capture_name) |capture_name| {
                try writer.print(" as {s}", .{capture_name});
            }
            try writer.writeAll(" {\n");
            try dumpBlock(writer, module, indent + 1, if_stmt.then_body);
            try writeIndent(writer, indent);
            if (if_stmt.else_body.len == 0) {
                try writer.writeAll("}\n");
            } else {
                try writer.writeAll("} else {\n");
                try dumpBlock(writer, module, indent + 1, if_stmt.else_body);
                try writeIndent(writer, indent);
                try writer.writeAll("}\n");
            }
        },
        .@"while" => |while_stmt| {
            try writer.writeAll("while ");
            try dumpExpr(writer, module, while_stmt.condition);
            try writer.writeAll(" {\n");
            try dumpBlock(writer, module, indent + 1, while_stmt.body);
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .@"for" => |for_stmt| {
            try writer.print("for {s} in ", .{for_stmt.name});
            try dumpExpr(writer, module, for_stmt.iterable);
            try writer.writeAll(" {\n");
            try dumpBlock(writer, module, indent + 1, for_stmt.body);
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .@"continue" => try writer.writeAll("continue\n"),
        .@"break" => try writer.writeAll("break\n"),
        .@"switch" => |switch_stmt| {
            try writer.writeAll("switch ");
            try dumpExpr(writer, module, switch_stmt.value);
            try writer.writeAll(" {\n");
            for (switch_stmt.cases) |case| {
                try writeIndent(writer, indent + 1);
                try writer.print("{s}", .{case.case_name});
                if (case.payload_name) |payload_name| {
                    try writer.print(" as {s}", .{payload_name});
                }
                try writer.writeAll(" => {\n");
                try dumpBlock(writer, module, indent + 2, case.body);
                try writeIndent(writer, indent + 1);
                try writer.writeAll("}\n");
            }
            if (switch_stmt.has_else) {
                try writeIndent(writer, indent + 1);
                try writer.writeAll("else => {\n");
                try dumpBlock(writer, module, indent + 2, switch_stmt.else_body);
                try writeIndent(writer, indent + 1);
                try writer.writeAll("}\n");
            }
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .@"try" => |attempt| {
            try writer.writeAll("try ");
            try dumpExpr(writer, module, attempt.expr);
            try writer.writeAll("\n");
        },
        .@"defer" => |expr| {
            try writer.writeAll("defer ");
            try dumpExpr(writer, module, expr);
            try writer.writeAll("\n");
        },
        .drop => |drop| try writer.print("drop {s}\n", .{drop.name}),
        .expr => |expr| {
            try dumpExpr(writer, module, expr);
            try writer.writeAll("\n");
        },
        .@"return" => |maybe_expr| {
            try writer.writeAll("return");
            if (maybe_expr) |expr| {
                try writer.writeAll(" ");
                try dumpExpr(writer, module, expr);
            }
            try writer.writeAll("\n");
        },
    }
}

fn dumpExpr(writer: anytype, module: Module, expr: *const Expr) anyerror!void {
    switch (expr.*) {
        .@"switch" => |switch_expr| {
            try writer.writeAll("switch ");
            try dumpExpr(writer, module, switch_expr.value);
        },
        .failure_detail => |detail| try writer.print("failure.{s}", .{@tagName(detail.field)}),
        .int => |value| try writer.print("{d}", .{value.value}),
        .float => |value| try writer.print("{d}", .{value.value}),
        .rune => |value| try writer.print("'{u}'", .{@as(u21, @intCast(value))}),
        .string => |value| try writer.print("\"{s}\"", .{value}),
        .bool => |value| try writer.writeAll(if (value) "true" else "false"),
        .none => try writer.writeAll("none"),
        .@"try" => |try_expr| {
            try writer.writeAll("try ");
            try dumpExpr(writer, module, try_expr.expr);
        },
        .enum_case => |case_expr| try writer.print("{s}.{s}", .{ case_expr.type_name, case_expr.case_name }),
        .union_case => |case_expr| {
            if (case_expr.result_case != null) {
                try writer.print(".{s}", .{case_expr.case_name});
            } else {
                try writer.print("{s}.{s}", .{ case_expr.union_name, case_expr.case_name });
            }
            if (case_expr.value) |value| {
                try writer.writeAll("(");
                try dumpExpr(writer, module, value);
                try writer.writeAll(")");
            }
        },
        .is_test => |is_test| {
            try dumpExpr(writer, module, is_test.subject);
            try writer.writeAll(" is ");
            switch (is_test.kind) {
                .optional_some => try writer.writeAll("some"),
                .optional_none => try writer.writeAll("none"),
                .union_case => try writer.writeAll(is_test.case_name.?),
            }
        },
        .cast => |cast| {
            try dumpExpr(writer, module, cast.subject);
            try writer.writeAll(if (cast.reinterpret) " as! " else if (cast.fallible) " as? " else " as ");
            try dumpType(writer, module, cast.target_type_id);
            if (cast.union_case_name) |case_name| {
                try writer.print(".{s}", .{case_name});
            }
        },
        .local => |name| try writer.writeAll(name),
        .global_ref => |global_ref| if (global_ref.owner) |owner|
            try writer.print("{s}.{s}.{s}", .{ global_ref.module_name, owner, global_ref.name })
        else
            try writer.print("{s}.{s}", .{ global_ref.module_name, global_ref.name }),
        .function_ref => |function_ref| {
            if (function_ref.owner) |owner| {
                try writer.print("{s}.{s}", .{ owner, function_ref.name });
            } else {
                try writer.writeAll(function_ref.name);
            }
        },
        .closure => |closure| {
            try writer.writeAll("closure(");
            if (closure.function.owner) |owner| {
                try writer.print("{s}.{s}", .{ owner, closure.function.name });
            } else {
                try writer.writeAll(closure.function.name);
            }
            try writer.writeAll(", captures=[");
            for (closure.captures, 0..) |capture, i| {
                if (i != 0) try writer.writeAll(", ");
                try dumpExpr(writer, module, capture);
            }
            try writer.writeAll("])");
        },
        .thread_spawn_boxed => |spawn| {
            try writer.print("thread_spawn_boxed {s}(", .{spawn.trampoline.name});
            try dumpExpr(writer, module, spawn.payload);
            try writer.writeByte(')');
        },
        .task_group_spawn_boxed => |spawn| {
            try writer.print("task_group_spawn_boxed {s}(", .{spawn.trampoline.name});
            try dumpExpr(writer, module, spawn.group_raw);
            try writer.writeAll(", ");
            try dumpExpr(writer, module, spawn.entry);
            try writer.writeAll(", ");
            try dumpExpr(writer, module, spawn.payload);
            try writer.writeByte(')');
        },
        .task_result_take => |take| {
            try writer.writeAll("task_result_take(");
            try dumpExpr(writer, module, take.pointer);
            try writer.writeByte(')');
        },
        .sync_share_boxed => |share| {
            try writer.writeAll("sync_share_boxed(");
            try dumpExpr(writer, module, share.payload);
            try writer.writeByte(')');
        },
        .closure_capture => |capture| {
            try writer.print("{s}.{d}", .{ capture.env_name, capture.field_index });
        },
        .ref_local => |name| try writer.print("&{s}", .{name}),
        .ref_global => |global_ref| if (global_ref.owner) |owner|
            try writer.print("&{s}.{s}.{s}", .{ global_ref.module_name, owner, global_ref.name })
        else
            try writer.print("&{s}.{s}", .{ global_ref.module_name, global_ref.name }),
        .ref_alias_local => |name| try writer.print("&alias {s}", .{name}),
        .ref_field_local => |field| try writer.print("&{s}.{s}", .{ field.local_name, field.field }),
        .ref_field_owned_local => |field| try writer.print("&take {s}.{s}", .{ field.local_name, field.field }),
        .ref_field_expr => |field| {
            try writer.writeAll("&(");
            try dumpExpr(writer, module, field.object);
            try writer.print(").{s}", .{field.field});
        },
        .ref_union_field_local => |field| try writer.print("&{s}.{s}", .{ field.local_name, field.field }),
        .ref_index_local => |index| {
            try writer.print("&{s}[", .{index.local_name});
            try dumpExpr(writer, module, index.index);
            try writer.writeAll("]");
        },
        .ref_index_path_local => |take_path| {
            try writer.print("&{s}", .{take_path.local_name});
            try dumpTakePath(writer, module, take_path.steps);
            try writer.writeAll("[");
            try dumpExpr(writer, module, take_path.index);
            try writer.writeAll("]");
        },
        .ref_path_local => |take_path| {
            try writer.print("&{s}", .{take_path.local_name});
            try dumpTakePath(writer, module, take_path.steps);
        },
        .ref_load => |ref_expr| {
            try writer.writeAll("*");
            try dumpExpr(writer, module, ref_expr);
        },
        .ref_owned_local => |name| try writer.print("&take {s}", .{name}),
        .raw_owned_local => |name| try writer.print("raw {s}", .{name}),
        .leak_owned_local => |name| try writer.print("leak {s}", .{name}),
        .handoff_local => |name| try writer.print("handoff {s}", .{name}),
        .ref_raw_deref => |value| {
            try writer.writeAll("&*");
            if (value.is_volatile) try writer.writeAll("volatile ");
            try dumpExpr(writer, module, value.expr);
        },
        .raw_deref => |value| {
            try writer.writeAll("*");
            if (value.is_volatile) try writer.writeAll("volatile ");
            try dumpExpr(writer, module, value.expr);
        },
        .from_raw => |value| {
            try writer.writeAll("from_raw ");
            try dumpExpr(writer, module, value.expr);
        },
        .unary => |unary| {
            try writer.print("{s}(", .{@tagName(unary.op)});
            try dumpExpr(writer, module, unary.expr);
            try writer.writeAll(")");
        },
        .binary => |binary| {
            try writer.writeAll("(");
            try dumpExpr(writer, module, binary.left);
            try writer.print(" {s} ", .{@tagName(binary.op)});
            try dumpExpr(writer, module, binary.right);
            try writer.writeAll(")");
        },
        .call => |call| {
            if (call.owner == null and call.module_name.len != 0) {
                try writer.print("[{s}]", .{call.module_name});
            }
            if (call.owner) |owner| {
                try writer.print("{s}.{s}(", .{ owner, call.callee });
            } else {
                try writer.print("{s}(", .{call.callee});
            }
            for (call.args, 0..) |arg, i| {
                if (i != 0) try writer.writeAll(", ");
                switch (arg) {
                    .value => |value| try dumpExpr(writer, module, value),
                }
            }
            try writer.writeAll(")");
        },
        .test_assert => |value| {
            try writer.writeAll("assert(");
            try dumpExpr(writer, module, value);
            try writer.writeAll(")");
        },
        .builtin_print => |print| {
            try writer.writeAll(if (print.append_newline) "println(" else "print(");
            for (print.parts, 0..) |part, i| {
                if (i != 0) try writer.writeAll(", ");
                switch (part) {
                    .literal => |text| try writer.print("\"{s}\"", .{text}),
                    .value => |value| try dumpExpr(writer, module, value.expr),
                }
            }
            try writer.writeAll(")");
        },
        .interpolated_string => |parts| {
            try writer.writeAll("$\"");
            for (parts) |part| switch (part) {
                .literal => |text| try writer.print("{s}", .{text}),
                .value => |value| {
                    try writer.writeAll("{");
                    try dumpExpr(writer, module, value.expr);
                    switch (value.format) {
                        .direct => {},
                        .decimal => try writer.writeAll(":d"),
                        .binary => try writer.writeAll(":b"),
                        .octal => try writer.writeAll(":o"),
                        .hex_lower => try writer.writeAll(":x"),
                        .hex_upper => try writer.writeAll(":X"),
                    }
                    try writer.writeAll("}");
                },
            };
            try writer.writeAll("\"");
        },
        .sequence_push => |push| {
            try dumpExpr(writer, module, push.object);
            try writer.writeAll(".push(");
            try dumpExpr(writer, module, push.value);
            try writer.writeAll(")");
        },
        .sequence_len => |value| {
            try dumpExpr(writer, module, value);
            try writer.writeAll(".len()");
        },
        .sequence_clear => |value| {
            try dumpExpr(writer, module, value);
            try writer.writeAll(".clear()");
        },
        .sparse_len => |value| {
            try dumpExpr(writer, module, value);
            try writer.writeAll(".len()");
        },
        .sparse_clear => |value| {
            try dumpExpr(writer, module, value);
            try writer.writeAll(".clear()");
        },
        .sparse_indices => |value| {
            try dumpExpr(writer, module, value);
            try writer.writeAll(".indices()");
        },
        .sparse_insert => |insert| {
            try dumpExpr(writer, module, insert.object);
            try writer.writeAll(".insert(");
            try dumpExpr(writer, module, insert.index);
            try writer.writeAll(", ");
            try dumpExpr(writer, module, insert.value);
            try writer.writeAll(")");
        },
        .sparse_contains_index => |contains| {
            try dumpExpr(writer, module, contains.object);
            try writer.writeAll(".contains_index(");
            try dumpExpr(writer, module, contains.index);
            try writer.writeAll(")");
        },
        .sparse_take => |take| {
            try dumpExpr(writer, module, take.object);
            try writer.writeAll(".take(");
            try dumpExpr(writer, module, take.index);
            try writer.writeAll(")");
        },
        .sequence_reserve => |reserve| {
            try dumpExpr(writer, module, reserve.object);
            try writer.writeAll(".reserve(");
            try dumpExpr(writer, module, reserve.capacity);
            try writer.writeAll(")");
        },
        .sequence_pop => |value| {
            try dumpExpr(writer, module, value);
            try writer.writeAll(".pop()");
        },
        .string_len => |value| {
            try dumpExpr(writer, module, value);
            try writer.writeAll(".len()");
        },
        .string_is_empty => |value| {
            try dumpExpr(writer, module, value);
            try writer.writeAll(".is_empty()");
        },
        .string_bytes => |value| {
            try dumpExpr(writer, module, value);
            try writer.writeAll(".bytes()");
        },
        .string_from => |value| {
            try writer.writeAll("string.from(");
            try dumpExpr(writer, module, value);
            try writer.writeByte(')');
        },
        .indirect_call => |call| {
            try dumpExpr(writer, module, call.callee);
            try writer.writeByte('(');
            for (call.args, 0..) |arg, i| {
                if (i != 0) try writer.writeAll(", ");
                switch (arg) {
                    .value => |value| try dumpExpr(writer, module, value),
                }
            }
            try writer.writeByte(')');
        },
        .string_starts_with => |contains| {
            try dumpExpr(writer, module, contains.object);
            try writer.writeAll(".starts_with(");
            try dumpExpr(writer, module, contains.value);
            try writer.writeByte(')');
        },
        .string_ends_with => |contains| {
            try dumpExpr(writer, module, contains.object);
            try writer.writeAll(".ends_with(");
            try dumpExpr(writer, module, contains.value);
            try writer.writeByte(')');
        },
        .string_contains => |contains| {
            try dumpExpr(writer, module, contains.object);
            try writer.writeAll(".contains(");
            try dumpExpr(writer, module, contains.value);
            try writer.writeByte(')');
        },
        .string_find => |contains| {
            try dumpExpr(writer, module, contains.object);
            try writer.writeAll(".find(");
            try dumpExpr(writer, module, contains.value);
            try writer.writeByte(')');
        },
        .string_rfind => |contains| {
            try dumpExpr(writer, module, contains.object);
            try writer.writeAll(".rfind(");
            try dumpExpr(writer, module, contains.value);
            try writer.writeByte(')');
        },
        .string_slice => |slice| {
            try dumpExpr(writer, module, slice.object);
            try writer.writeAll(".slice(");
            try dumpExpr(writer, module, slice.start);
            try writer.writeAll(", ");
            try dumpExpr(writer, module, slice.end);
            try writer.writeByte(')');
        },
        .slice_range => |slice| {
            try dumpExpr(writer, module, slice.object);
            try writer.writeAll("[");
            if (slice.start) |start| try dumpExpr(writer, module, start);
            try writer.writeAll("..");
            if (slice.end) |end| try dumpExpr(writer, module, end);
            try writer.writeAll("]");
        },
        .slice_len => |value| {
            try dumpExpr(writer, module, value);
            try writer.writeAll(".len()");
        },
        .slice_ptr => |value| {
            try dumpExpr(writer, module, value);
            try writer.writeAll(".ptr");
        },
        .index => |index| {
            try dumpExpr(writer, module, index.object);
            try writer.writeAll("[");
            try dumpExpr(writer, module, index.index);
            try writer.writeAll("]");
        },
        .borrowed_index => |index| {
            try writer.writeAll("borrowed ");
            try dumpExpr(writer, module, index.object);
            try writer.writeAll("[");
            try dumpExpr(writer, module, index.index);
            try writer.writeAll("]");
        },
        .take_index_local => |index| {
            try writer.print("take {s}[", .{index.local_name});
            try dumpExpr(writer, module, index.index);
            try writer.writeAll("]");
        },
        .take_index_path_local => |take_path| {
            try writer.print("take {s}", .{take_path.local_name});
            try dumpTakePath(writer, module, take_path.steps);
            try writer.writeAll("[");
            try dumpExpr(writer, module, take_path.index);
            try writer.writeAll("]");
        },
        .take_path_local => |take_path| {
            try writer.print("take {s}", .{take_path.local_name});
            try dumpTakePath(writer, module, take_path.steps);
        },
        .array_literal => |literal| try dumpArrayLiteral(writer, module, literal.items),
        .tuple_literal => |literal| try dumpArrayLiteral(writer, module, literal.items),
        .array_default => |literal| {
            try writer.print("[default; {d}] : ", .{literal.len});
            try dumpType(writer, module, literal.item_type_id);
        },
        .new_array => |new_array| {
            try writer.writeAll("[: ");
            try dumpExpr(writer, module, new_array.len);
            try writer.writeAll("] ");
            try dumpType(writer, module, new_array.item_type_id);
        },
        .new_sparse => |storage| {
            try writer.writeAll("[; ");
            try dumpExpr(writer, module, storage.capacity);
            try writer.writeAll("] ");
            try dumpType(writer, module, storage.item_type_id);
        },
        .dense_array_literal => |literal| {
            if (literal.capacity) |capacity| {
                try writer.print("array(cap={d})", .{capacity});
            } else {
                try writer.writeAll("array");
            }
            try dumpArrayLiteral(writer, module, literal.items);
        },
        .sparse_literal => |literal| {
            try writer.print("sparse(cap={d})", .{literal.capacity});
            try dumpArrayLiteral(writer, module, literal.items);
        },
        .sparse_keyed_literal => |literal| {
            try writer.print("sparse(cap={d}) ", .{literal.capacity});
            try writer.writeAll("{");
            for (literal.entries, 0..) |entry, i| {
                if (i != 0) try writer.writeAll(", ");
                try dumpExpr(writer, module, entry.index);
                try writer.writeAll(": ");
                try dumpExpr(writer, module, entry.value);
            }
            try writer.writeAll("}");
        },
        .new_owned => |literal| {
            try writer.writeAll("new ");
            try dumpStructLiteral(writer, module, literal);
        },
        .struct_literal => |literal| try dumpStructLiteral(writer, module, literal),
        .asm_expr => |asm_expr| {
            try writer.writeAll("asm(");
            try dumpType(writer, module, asm_expr.target_type_id);
            try writer.writeAll(")");
            if (asm_expr.is_volatile) try writer.writeAll(" volatile");
            try writer.writeAll(" { ");
            for (asm_expr.lines) |line| {
                try writer.print("\"{s}\"; ", .{line});
            }
            if (asm_expr.output) |output| {
                try writer.print("out {s} {s}; ", .{ @tagName(output.constraint), output.name });
            }
            if (asm_expr.inout) |inout| {
                try writer.print("inout {s} {s} = ", .{ @tagName(inout.constraint), inout.name });
                try dumpExpr(writer, module, inout.value);
                try writer.writeAll("; ");
            }
            for (asm_expr.inputs) |input| {
                try writer.print("in {s} {s} = ", .{ @tagName(input.constraint), input.name });
                try dumpExpr(writer, module, input.value);
                try writer.writeAll("; ");
            }
            for (asm_expr.clobbers) |clobber| {
                switch (clobber) {
                    .memory => try writer.writeAll("clobber memory; "),
                    .flags => try writer.writeAll("clobber flags; "),
                    .register => |name| try writer.print("clobber {s}; ", .{name}),
                }
            }
            try writer.writeAll("}");
        },
        .field => |field| {
            try dumpExpr(writer, module, field.object);
            try writer.print(".{s}", .{field.field});
        },
        .tuple_field => |field| {
            try dumpExpr(writer, module, field.object);
            try writer.print(".{d}", .{field.index});
        },
        .borrowed_field => |field| {
            try writer.writeAll("borrowed ");
            try dumpExpr(writer, module, field.object);
            try writer.print(".{s}", .{field.field});
        },
        .union_field => |field| {
            try dumpExpr(writer, module, field.object);
            try writer.print(".{s}", .{field.field});
        },
        .borrowed_union_field => |field| {
            try writer.writeAll("borrowed ");
            try dumpExpr(writer, module, field.object);
            try writer.print(".{s}", .{field.field});
        },
    }
}

fn dumpTakePath(writer: anytype, module: Module, steps: []const TakePathStep) anyerror!void {
    for (steps) |step| {
        switch (step) {
            .field => |field| try writer.print(".{s}", .{field.field}),
            .index => |index| {
                try writer.writeAll("[");
                try dumpExpr(writer, module, index);
                try writer.writeAll("]");
            },
        }
    }
}

fn dumpArrayLiteral(writer: anytype, module: Module, items: []const *Expr) anyerror!void {
    try writer.writeAll("[");
    for (items, 0..) |item, i| {
        if (i != 0) try writer.writeAll(", ");
        try dumpExpr(writer, module, item);
    }
    try writer.writeAll("]");
}

fn dumpStructLiteral(writer: anytype, module: Module, literal: StructLiteral) anyerror!void {
    try writer.print("{s} {{ ", .{literal.type_name});
    for (literal.fields, 0..) |field, i| {
        if (i != 0) try writer.writeAll(", ");
        try writer.print("{s} = ", .{field.name});
        try dumpExpr(writer, module, field.value);
    }
    try writer.writeAll(" }");
}

test "generic requirement verifier rejects conflicting authority at one source use" {
    const declaration: identity.DeclId = @fromBackingInt(@intCast(1));
    const readable: identity.DeclId = @fromBackingInt(@intCast(2));
    const other: identity.DeclId = @fromBackingInt(@intCast(3));
    // Both requirements describe constraints on the same source use, so they
    // share that use's identity.
    var requirements = [_]GenericRequirement{
        .{ .declaration_id = declaration, .module_name = "main", .owner = null, .declaration = "inspect", .parameter = "T", .parameter_definition_offset = 2, .parameter_id = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 }, .operation = "read", .source_offset = 10, .use_id = 1, .declared_protocol = .{ .id = readable, .module_name = "main", .name = "Readable" } },
        .{ .declaration_id = declaration, .module_name = "main", .owner = null, .declaration = "inspect", .parameter = "U", .parameter_definition_offset = 3, .parameter_id = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 1 }, .operation = "read", .source_offset = 10, .use_id = 1, .declared_protocol = .{ .id = readable, .module_name = "main", .name = "Readable" } },
    };
    const module: Module = .{ .generic_requirements = &requirements, .globals = &.{}, .enums = &.{}, .unions = &.{}, .structs = &.{}, .functions = &.{} };
    try module.verifyGenericRequirements();
    requirements[1].declared_protocol.?.id = other;
    try std.testing.expectError(error.ConflictingGenericMethodAuthority, module.verifyGenericRequirements());
    requirements[1].declared_protocol.?.id = readable;
    requirements[1].declared_protocol.?.method_id = @fromBackingInt(@intCast(5));
    try std.testing.expectError(error.ConflictingGenericMethodAuthority, module.verifyGenericRequirements());
    requirements[1].declared_protocol.?.method_id = null;
    requirements[1].declared_protocol.?.module_name = "other";
    try std.testing.expectError(error.ConflictingGenericMethodAuthority, module.verifyGenericRequirements());
    requirements[1].declared_protocol.?.module_name = "main";
    requirements[1].declared_protocol = null;
    try std.testing.expectError(error.ConflictingGenericMethodAuthority, module.verifyGenericRequirements());
    requirements[1].declared_protocol = .{ .id = readable, .module_name = "main", .name = "Readable" };
    requirements[1].declaration_id = @fromBackingInt(@intCast(4));
    try module.verifyGenericRequirements();
    requirements[1].declaration_id = declaration;
    requirements[1].source_offset = 20;
    try module.verifyGenericRequirements();
    requirements[1].parameter = "T";
    try std.testing.expectError(error.ConflictingGenericParameterIdentity, module.verifyGenericRequirements());
    requirements[1].parameter_definition_offset = 2;
    try std.testing.expectError(error.ConflictingGenericParameterCanonicalIdentity, module.verifyGenericRequirements());
    requirements[1].parameter_definition_offset = 3;
    requirements[1].parameter = "U";
    requirements[1].parameter_definition_offset = null;
    try std.testing.expectError(error.MissingGenericParameterIdentity, module.verifyGenericRequirements());
    requirements[1].parameter_definition_offset = 3;
    requirements[1].declaration_id = null;
    try std.testing.expectError(error.MissingGenericDeclarationIdentity, module.verifyGenericRequirements());
}

test "generic requirement verifier resolves declaration and protocol identities" {
    var registry = identity.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const source = try registry.registerSource("authority.cy");
    const module_id = try registry.registerModule(source, "main");
    const declaration = try registry.registerDecl(module_id, null, "inspect", .function);
    const other_function = try registry.registerDecl(module_id, null, "other", .function);
    const protocol = try registry.registerDecl(module_id, null, "Readable", .protocol);
    const other_protocol = try registry.registerDecl(module_id, null, "Other", .protocol);
    const method = try registry.registerDecl(module_id, "Readable", "read", .protocol_method);
    const other_method = try registry.registerDecl(module_id, "Other", "read", .protocol_method);
    var requirements = [_]GenericRequirement{.{
        .declaration_id = declaration,
        .module_name = "main",
        .owner = null,
        .declaration = "inspect",
        .parameter = "T",
        .parameter_definition_offset = 2,
        .parameter_id = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 },
        .operation = "read",
        .source_offset = 10,
        .use_id = 1,
        .declared_protocol = .{ .id = protocol, .method_id = method, .module_name = "main", .name = "Readable" },
    }};
    const module: Module = .{ .generic_requirements = &requirements, .globals = &.{}, .enums = &.{}, .unions = &.{}, .structs = &.{}, .functions = &.{} };
    try module.verifyGenericRequirementIdentities(&registry);
    requirements[0].declaration_id = other_function;
    try std.testing.expectError(error.IncorrectGenericDeclarationIdentity, module.verifyGenericRequirementIdentities(&registry));
    requirements[0].declaration_id = @fromBackingInt(@intCast(999));
    try std.testing.expectError(error.IncorrectGenericDeclarationIdentity, module.verifyGenericRequirementIdentities(&registry));
    requirements[0].declaration_id = declaration;
    requirements[0].declared_protocol.?.id = other_protocol;
    try std.testing.expectError(error.IncorrectGenericProtocolIdentity, module.verifyGenericRequirementIdentities(&registry));
    requirements[0].declared_protocol.?.id = @fromBackingInt(@intCast(999));
    try std.testing.expectError(error.IncorrectGenericProtocolIdentity, module.verifyGenericRequirementIdentities(&registry));
    requirements[0].declared_protocol.?.id = protocol;
    requirements[0].declared_protocol.?.method_id = other_method;
    try std.testing.expectError(error.IncorrectGenericProtocolMethodIdentity, module.verifyGenericRequirementIdentities(&registry));
    requirements[0].declared_protocol.?.method_id = @fromBackingInt(@intCast(999));
    try std.testing.expectError(error.IncorrectGenericProtocolMethodIdentity, module.verifyGenericRequirementIdentities(&registry));
    requirements[0].declared_protocol.?.method_id = null;
    try std.testing.expectError(error.IncorrectGenericProtocolMethodIdentity, module.verifyGenericRequirementIdentities(&registry));
}

test "generic requirement verifier checks each lowered method-use authority" {
    const declaration: identity.DeclId = @fromBackingInt(@intCast(1));
    const protocol: identity.DeclId = @fromBackingInt(@intCast(2));
    const method: identity.DeclId = @fromBackingInt(@intCast(3));
    const callee: identity.DeclId = @fromBackingInt(@intCast(4));
    const result_type: semantic_types.TypeId = @fromBackingInt(@intCast(7));
    var requirement = [_]GenericRequirement{.{
        .declaration_id = declaration,
        .module_name = "main",
        .owner = null,
        .declaration = "inspect",
        .parameter = "T",
        .parameter_definition_offset = 5,
        .parameter_id = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 },
        .operation = "read",
        .source_offset = 20,
        .use_id = 1,
        .declared_protocol = .{ .id = protocol, .method_id = method, .module_name = "main", .name = "Readable" },
    }};
    var call = Expr{ .call = .{
        .decl_id = callee,
        .checked_method_use = .{
            .use_id = 1,
            .source_declaration_id = declaration,
            .source_offset = 20,
            .protocol_id = protocol,
            .method_id = method,
            .callee_declaration_id = callee,
            .result_type_id = result_type,
        },
        .module_name = "main",
        .owner = null,
        .callee = "read",
        .args = &.{},
    } };
    const body = [_]Stmt{.{ .expr = &call }};
    const functions = [_]Function{.{ .decl_id = callee, .owner = null, .name = "inspect", .params = &.{}, .return_type_id = result_type, .body = &body }};
    const metadata = [_]ExprMetadataEntry{.{ .expr = &call, .metadata = .{ .type_id = result_type, .semantics = .plainValue() } }};
    const module: Module = .{ .generic_requirements = &requirement, .globals = &.{}, .enums = &.{}, .unions = &.{}, .structs = &.{}, .functions = &functions, .expr_metadata = &metadata };
    try module.verifyGenericRequirements();
    call.call.checked_method_use.?.method_id = @fromBackingInt(@intCast(4));
    try std.testing.expectError(error.MissingGenericMethodUseAuthority, module.verifyGenericRequirements());
    call.call.checked_method_use.?.method_id = method;
    requirement[0].source_offset = 21;
    try std.testing.expectError(error.MissingGenericMethodUseAuthority, module.verifyGenericRequirements());
    requirement[0].source_offset = 20;
    call.call.checked_method_use.?.use_id = 2;
    try std.testing.expectError(error.IncorrectMethodUseIdentity, module.verifyGenericRequirements());
    call.call.checked_method_use.?.use_id = 0;
    try std.testing.expectError(error.MissingMethodUseIdentity, module.verifyGenericRequirements());
    call.call.checked_method_use.?.use_id = 1;
    // The record cannot claim a result type the expression does not settle.
    call.call.checked_method_use.?.result_type_id = @fromBackingInt(@intCast(8));
    try std.testing.expectError(error.IncorrectMethodUseSignature, module.verifyGenericRequirements());
    call.call.checked_method_use.?.result_type_id = result_type;
    // Nor name a callee the call never reaches.
    call.call.checked_method_use.?.callee_declaration_id = @fromBackingInt(@intCast(9));
    try std.testing.expectError(error.MissingMethodUseSignature, module.verifyGenericRequirements());
    call.call.checked_method_use.?.callee_declaration_id = callee;
    // A use with no signature at all is not a checked record.
    call.call.checked_method_use.?.result_type_id = null;
    try std.testing.expectError(error.MissingMethodUseSignature, module.verifyGenericRequirements());
}

test "method-use identity rejects a forged id, a missing id, and two uses sharing one id" {
    const declaration: identity.DeclId = @fromBackingInt(@intCast(1));
    const protocol: identity.DeclId = @fromBackingInt(@intCast(2));
    const method: identity.DeclId = @fromBackingInt(@intCast(3));
    const callee: identity.DeclId = @fromBackingInt(@intCast(4));
    const result_type: semantic_types.TypeId = @fromBackingInt(@intCast(7));
    var requirements = [_]GenericRequirement{
        .{
            .declaration_id = declaration,
            .module_name = "main",
            .owner = null,
            .declaration = "inspect",
            .parameter = "T",
            .parameter_definition_offset = 5,
            .parameter_id = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 },
            .operation = "read",
            .source_offset = 20,
            .use_id = 1,
            .declared_protocol = .{ .id = protocol, .method_id = method, .module_name = "main", .name = "Readable" },
        },
        .{
            .declaration_id = declaration,
            .module_name = "main",
            .owner = null,
            .declaration = "inspect",
            .parameter = "T",
            .parameter_definition_offset = 5,
            .parameter_id = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 },
            .operation = "read",
            .source_offset = 40,
            .use_id = 2,
            .declared_protocol = .{ .id = protocol, .method_id = method, .module_name = "main", .name = "Readable" },
        },
    };
    var first = Expr{ .call = .{
        .decl_id = callee,
        .checked_method_use = .{
            .use_id = 1,
            .source_declaration_id = declaration,
            .source_offset = 20,
            .protocol_id = protocol,
            .method_id = method,
            .callee_declaration_id = callee,
            .result_type_id = result_type,
        },
        .module_name = "main",
        .owner = null,
        .callee = "read",
        .args = &.{},
    } };
    var second = Expr{ .call = .{
        .decl_id = callee,
        .checked_method_use = .{
            .use_id = 2,
            .source_declaration_id = declaration,
            .source_offset = 40,
            .protocol_id = protocol,
            .method_id = method,
            .callee_declaration_id = callee,
            .result_type_id = result_type,
        },
        .module_name = "main",
        .owner = null,
        .callee = "read",
        .args = &.{},
    } };
    // A second specialization of the first source use keeps that use's identity.
    var variant = Expr{ .call = .{
        .decl_id = callee,
        .checked_method_use = .{
            .use_id = 1,
            .source_declaration_id = declaration,
            .source_offset = 20,
            .protocol_id = protocol,
            .method_id = method,
            .callee_declaration_id = callee,
            .result_type_id = result_type,
        },
        .module_name = "main",
        .owner = null,
        .callee = "read",
        .args = &.{},
    } };
    const body = [_]Stmt{ .{ .expr = &first }, .{ .expr = &second }, .{ .expr = &variant } };
    const functions = [_]Function{.{ .decl_id = callee, .owner = null, .name = "inspect", .params = &.{}, .return_type_id = result_type, .body = &body }};
    var metadata = [_]ExprMetadataEntry{
        .{ .expr = &first, .metadata = .{ .type_id = result_type, .semantics = .plainValue() } },
        .{ .expr = &second, .metadata = .{ .type_id = result_type, .semantics = .plainValue() } },
        .{ .expr = &variant, .metadata = .{ .type_id = result_type, .semantics = .plainValue() } },
    };
    const module: Module = .{
        .generic_requirements = &requirements,
        .globals = &.{},
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &functions,
        .expr_metadata = &metadata,
    };
    // Two source uses of the same protocol method keep two distinct identities,
    // and one source use may lower to more than one specialized call.
    try module.verifyGenericRequirements();

    // The second use borrowing the first use's identity is a forgery.
    second.call.checked_method_use.?.use_id = 1;
    requirements[1].use_id = 1;
    try std.testing.expectError(error.DuplicateMethodUseIdentity, module.verifyGenericRequirements());
    second.call.checked_method_use.?.use_id = 2;
    requirements[1].use_id = 2;

    // A use whose recorded requirement claims a different identity is rejected.
    requirements[1].use_id = 3;
    try std.testing.expectError(error.IncorrectMethodUseIdentity, module.verifyGenericRequirements());
    requirements[1].use_id = 2;

    // A requirement that carries authority without a use identity is rejected.
    requirements[1].use_id = null;
    try std.testing.expectError(error.MissingMethodUseIdentity, module.verifyGenericRequirements());
}

/// A checked record for a call the lowering settles to a concrete declaration
/// rather than a protocol witness, used by the ordinary-call matrix below.
fn testOrdinaryUseRecord(
    caller: identity.DeclId,
    use_id: u32,
    source_offset: usize,
    callee: identity.DeclId,
    result: TypeId,
    substitution: []const TypeId,
) CheckedMethodUse {
    return .{
        .use_id = use_id,
        .source_declaration_id = caller,
        .source_offset = source_offset,
        .callee_declaration_id = callee,
        .result_type_id = result,
        .substitution = substitution,
    };
}

test "ordinary call records are checked against the callee they settle to" {
    const caller: identity.DeclId = @fromBackingInt(@intCast(1));
    const helper: identity.DeclId = @fromBackingInt(@intCast(4));
    const other: identity.DeclId = @fromBackingInt(@intCast(7));
    const missing: identity.DeclId = @fromBackingInt(@intCast(9));

    var types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer types.deinit();
    const item: TypeId = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const result_type: TypeId = try types.intern(.{ .primitive = .bool });
    const unrelated: TypeId = try types.intern(.{ .primitive = .rune });

    // A use the lowering settles to a concrete declaration carries no protocol
    // witness; its authority is the callee, the settled type, and the
    // specialization the record names.
    const params = [_]Param{.{ .name = "value", .type_id = item }};
    var first = Expr{ .call = .{
        .decl_id = helper,
        .checked_method_use = testOrdinaryUseRecord(caller, 1, 20, helper, result_type, &.{item}),
        .module_name = "main",
        .owner = null,
        .callee = "helper",
        .args = &.{},
    } };
    var second = Expr{ .call = .{
        .decl_id = helper,
        .checked_method_use = testOrdinaryUseRecord(caller, 2, 40, helper, result_type, &.{item}),
        .module_name = "main",
        .owner = null,
        .callee = "helper",
        .args = &.{},
    } };
    const body = [_]Stmt{ .{ .expr = &first }, .{ .expr = &second } };
    const functions = [_]Function{
        .{ .decl_id = helper, .owner = null, .name = "helper", .params = &params, .return_type_id = result_type, .body = &body },
        .{ .decl_id = other, .owner = null, .name = "other", .params = &.{}, .return_type_id = unrelated, .body = &.{} },
    };
    var metadata = [_]ExprMetadataEntry{
        .{ .expr = &first, .metadata = .{ .type_id = result_type, .semantics = .plainValue() } },
        .{ .expr = &second, .metadata = .{ .type_id = result_type, .semantics = .plainValue() } },
    };
    var module: Module = .{
        .canonical_types = types,
        .globals = &.{},
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &functions,
        .expr_metadata = &metadata,
    };
    try module.verifyGenericRequirements();

    // A live call with no record at all is a shape gap, not a verified use.
    first.call.checked_method_use = null;
    try std.testing.expectError(error.MissingCallAuthority, module.verifyGenericRequirements());
    first.call.checked_method_use = testOrdinaryUseRecord(caller, 1, 20, helper, result_type, &.{item});

    // The use identity cannot be zero.
    first.call.checked_method_use = testOrdinaryUseRecord(caller, 0, 20, helper, result_type, &.{item});
    try std.testing.expectError(error.MissingMethodUseIdentity, module.verifyGenericRequirements());
    first.call.checked_method_use = testOrdinaryUseRecord(caller, 1, 20, helper, result_type, &.{item});

    // The record cannot claim a type the expression does not settle.
    metadata[0].metadata.type_id = unrelated;
    first.call.checked_method_use = testOrdinaryUseRecord(caller, 1, 20, helper, unrelated, &.{item});
    try std.testing.expectError(error.IncorrectMethodUseSignature, module.verifyGenericRequirements());
    metadata[0].metadata.type_id = result_type;
    first.call.checked_method_use = testOrdinaryUseRecord(caller, 1, 20, helper, result_type, &.{item});

    // Nor name a callee the call never reaches.
    first.call.checked_method_use = testOrdinaryUseRecord(caller, 1, 20, other, result_type, &.{item});
    try std.testing.expectError(error.MissingMethodUseSignature, module.verifyGenericRequirements());
    first.call.checked_method_use = testOrdinaryUseRecord(caller, 1, 20, helper, result_type, &.{item});

    // Nor name a declaration the module never registered, whether the call's
    // own identity points at it or the record alone does.
    first.call.decl_id = missing;
    first.call.checked_method_use = testOrdinaryUseRecord(caller, 1, 20, missing, result_type, &.{item});
    try std.testing.expectError(error.UnregisteredCallAuthority, module.verifyGenericRequirements());
    first.call.decl_id = helper;
    first.call.checked_method_use = testOrdinaryUseRecord(caller, 1, 20, missing, result_type, &.{item});
    try std.testing.expectError(error.MissingMethodUseSignature, module.verifyGenericRequirements());
    first.call.checked_method_use = testOrdinaryUseRecord(caller, 1, 20, helper, result_type, &.{item});

    // Nor claim a return type the registered callee does not have.
    metadata[0].metadata.type_id = unrelated;
    first.call.checked_method_use = testOrdinaryUseRecord(caller, 1, 20, helper, unrelated, &.{item});
    try std.testing.expectError(error.IncorrectMethodUseSignature, module.verifyGenericRequirements());
    metadata[0].metadata.type_id = result_type;
    first.call.checked_method_use = testOrdinaryUseRecord(caller, 1, 20, helper, result_type, &.{item});

    // The specialization must be a type the callee signature actually names.
    first.call.checked_method_use = testOrdinaryUseRecord(caller, 1, 20, helper, result_type, &.{unrelated});
    try std.testing.expectError(error.InvalidMethodUseSubstitution, module.verifyGenericRequirements());
    first.call.checked_method_use = testOrdinaryUseRecord(caller, 1, 20, helper, result_type, &.{item});

    // A substitution cannot be asserted without canonical types to check it against.
    const canonical = module.canonical_types;
    module.canonical_types = null;
    try std.testing.expectError(error.MissingCanonicalTypes, module.verifyGenericRequirements());
    module.canonical_types = canonical;

    // Two source uses may not share one use identity, but one source use may
    // lower to several specialized calls that keep that identity.
    second.call.checked_method_use = testOrdinaryUseRecord(caller, 1, 40, helper, result_type, &.{item});
    try std.testing.expectError(error.DuplicateMethodUseIdentity, module.verifyGenericRequirements());
    second.call.checked_method_use = testOrdinaryUseRecord(caller, 1, 20, helper, result_type, &.{item});
    try module.verifyGenericRequirements();
}

test "method-use signature checks the concrete callee and its substitution" {
    const declaration: identity.DeclId = @fromBackingInt(@intCast(1));
    const protocol: identity.DeclId = @fromBackingInt(@intCast(2));
    const method: identity.DeclId = @fromBackingInt(@intCast(3));
    const callee: identity.DeclId = @fromBackingInt(@intCast(4));

    var types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer types.deinit();
    const item: semantic_types.TypeId = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const receiver: semantic_types.TypeId = try types.intern(.{ .generic_instance = .{
        .kind = .@"struct",
        .base_decl_id = @fromBackingInt(@intCast(5)),
        .decl_id = @fromBackingInt(@intCast(6)),
        .args = &.{.{ .type = item }},
    } });
    const result_type: semantic_types.TypeId = try types.intern(.{ .primitive = .bool });
    const unrelated: semantic_types.TypeId = try types.intern(.{ .primitive = .rune });

    var requirement = [_]GenericRequirement{.{
        .declaration_id = declaration,
        .module_name = "main",
        .owner = null,
        .declaration = "inspect",
        .parameter = "T",
        .parameter_definition_offset = 5,
        .parameter_id = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 },
        .operation = "read",
        .source_offset = 20,
        .use_id = 1,
        .declared_protocol = .{ .id = protocol, .method_id = method, .module_name = "main", .name = "Readable" },
    }};
    var call = Expr{ .call = .{
        .decl_id = callee,
        .checked_method_use = .{
            .use_id = 1,
            .source_declaration_id = declaration,
            .source_offset = 20,
            .protocol_id = protocol,
            .method_id = method,
            .callee_declaration_id = callee,
            .result_type_id = result_type,
            .substitution = &.{item},
        },
        .module_name = "main",
        .owner = null,
        .callee = "read",
        .args = &.{},
    } };
    const body = [_]Stmt{.{ .expr = &call }};
    const params = [_]Param{.{ .name = "self", .type_id = receiver }};
    const functions = [_]Function{.{
        .decl_id = callee,
        .owner = null,
        .name = "inspect",
        .params = &params,
        .return_type_id = result_type,
        .body = &body,
    }};
    const metadata = [_]ExprMetadataEntry{.{ .expr = &call, .metadata = .{ .type_id = result_type, .semantics = .plainValue() } }};
    const module: Module = .{
        .canonical_types = types,
        .generic_requirements = &requirement,
        .globals = &.{},
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &functions,
        .expr_metadata = &metadata,
    };
    // The substituted type is a type argument the callee signature names.
    try module.verifyGenericRequirements();

    // A type the specialization never plugs into the callee is a forged substitution.
    call.call.checked_method_use.?.substitution = &.{unrelated};
    try std.testing.expectError(error.InvalidMethodUseSubstitution, module.verifyGenericRequirements());
}

test "generated iterator uses carry the identity of every hook a for loop reaches" {
    const declaration: identity.DeclId = @fromBackingInt(@intCast(1));
    const init_decl: identity.DeclId = @fromBackingInt(@intCast(2));
    const has_next_decl: identity.DeclId = @fromBackingInt(@intCast(3));
    const next_decl: identity.DeclId = @fromBackingInt(@intCast(4));
    const item_decl: identity.DeclId = @fromBackingInt(@intCast(5));

    var types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer types.deinit();
    const item: semantic_types.TypeId = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const receiver: semantic_types.TypeId = try types.intern(.{ .generic_instance = .{
        .kind = .@"struct",
        .base_decl_id = @fromBackingInt(@intCast(6)),
        .decl_id = @fromBackingInt(@intCast(7)),
        .args = &.{.{ .type = item }},
    } });
    const state: semantic_types.TypeId = try types.intern(.{ .generic_instance = .{
        .kind = .@"struct",
        .base_decl_id = @fromBackingInt(@intCast(8)),
        .decl_id = @fromBackingInt(@intCast(9)),
        .args = &.{.{ .type = item }},
    } });
    const cursor: semantic_types.TypeId = try types.intern(.{ .integer = .{ .bits = 64, .signed = false } });
    const bool_type: semantic_types.TypeId = try types.intern(.{ .primitive = .bool });
    const unrelated: semantic_types.TypeId = try types.intern(.{ .primitive = .rune });

    var iterable: Expr = .{ .local = "values" };
    var other_iterable: Expr = .{ .local = "other" };
    var uses = [_]GeneratedMethodUse{
        .{
            .use_id = 1,
            .role = .iterator_init,
            .source_declaration_id = declaration,
            .source_offset = 30,
            .subject_type_id = receiver,
            .receiver_type_id = receiver,
            .method_declaration_id = init_decl,
            .result_type_id = state,
            .substitution = &.{item},
        },
        .{
            .use_id = 2,
            .role = .iterator_has_next,
            .source_declaration_id = declaration,
            .source_offset = 30,
            .subject_type_id = receiver,
            .receiver_type_id = receiver,
            .method_declaration_id = has_next_decl,
            .result_type_id = bool_type,
            .substitution = &.{item},
        },
        .{
            .use_id = 3,
            .role = .iterator_next,
            .source_declaration_id = declaration,
            .source_offset = 30,
            .subject_type_id = receiver,
            .receiver_type_id = receiver,
            .method_declaration_id = next_decl,
            .result_type_id = cursor,
            .substitution = &.{item},
        },
        .{
            .use_id = 4,
            .role = .iterable_item,
            .source_declaration_id = declaration,
            .source_offset = 30,
            .subject_type_id = receiver,
            .receiver_type_id = receiver,
            .method_declaration_id = item_decl,
            .result_type_id = item,
            .substitution = &.{item},
        },
    };
    const loop: For = .{
        .name = "value",
        .item_type_id = item,
        .iterable = &iterable,
        .iterator_state_type_id = state,
        .iterator_cursor_type_id = cursor,
        .iterator_init_decl_id = init_decl,
        .iterator_has_next_decl_id = has_next_decl,
        .iterator_next_decl_id = next_decl,
        .iterable_index_decl_id = item_decl,
        .generated_method_uses = &uses,
        .body = &.{},
    };
    var statements = [_]Stmt{.{ .@"for" = loop }};
    const hook_params = [_]Param{.{ .name = "self", .type_id = receiver }};
    const empty_body = [_]Stmt{};
    const functions = [_]Function{
        .{ .decl_id = declaration, .owner = null, .name = "iterated", .params = &.{}, .return_type_id = cursor, .body = &statements },
        .{ .decl_id = init_decl, .owner = null, .name = "iter", .params = &hook_params, .return_type_id = state, .body = &empty_body },
        .{ .decl_id = has_next_decl, .owner = null, .name = "iter_has_next", .params = &hook_params, .return_type_id = bool_type, .body = &empty_body },
        .{ .decl_id = next_decl, .owner = null, .name = "iter_next", .params = &hook_params, .return_type_id = cursor, .body = &empty_body },
        .{ .decl_id = item_decl, .owner = null, .name = "iter_item", .params = &hook_params, .return_type_id = item, .body = &empty_body },
    };
    const metadata = [_]ExprMetadataEntry{.{ .expr = &iterable, .metadata = .{ .type_id = receiver, .semantics = .plainValue() } }};
    const module: Module = .{
        .canonical_types = types,
        .generic_requirements = &.{},
        .globals = &.{},
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &functions,
        .expr_metadata = &metadata,
    };
    // Every hook the loop reaches has a record naming its declaration, settled
    // type, receiver, and specialization.
    try module.verifyGenericRequirements();

    // A record naming a hook the loop never reaches is a forged use.
    uses[1].method_declaration_id = next_decl;
    try std.testing.expectError(error.IncorrectGeneratedMethodUse, module.verifyGenericRequirements());
    uses[1].method_declaration_id = has_next_decl;

    // A record settling a type the hook's own signature does not return is a
    // forged use.
    uses[1].result_type_id = state;
    try std.testing.expectError(error.IncorrectGeneratedMethodUse, module.verifyGenericRequirements());
    uses[1].result_type_id = bool_type;

    // A hook the loop reaches with no record at all is a shape gap.
    statements[0].@"for".generated_method_uses = uses[0..3];
    try std.testing.expectError(error.MissingGeneratedMethodUse, module.verifyGenericRequirements());
    statements[0].@"for".generated_method_uses = &uses;

    // Two records sharing one use id are not two distinct generated uses.
    uses[3].use_id = 1;
    try std.testing.expectError(error.DuplicateGeneratedMethodUse, module.verifyGenericRequirements());
    uses[3].use_id = 4;

    // A generated use must name the receiver the loop iterates.
    statements[0].@"for".iterable = &other_iterable;
    try std.testing.expectError(error.MissingExpressionMetadata, module.verifyGenericRequirements());
    statements[0].@"for".iterable = &iterable;

    // A specialization term the hook signature never names is forged.
    uses[0].substitution = &.{unrelated};
    try std.testing.expectError(error.InvalidMethodUseSubstitution, module.verifyGenericRequirements());
    uses[0].substitution = &.{item};
    try module.verifyGenericRequirements();
}

test "value-semantics dump exposes type category ownership and cleanup" {
    var types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer types.deinit();
    const bool_type = try types.intern(.{ .primitive = .bool });
    var expr: Expr = .{ .bool = true };
    var entries = [_]ExprMetadataEntry{.{
        .expr = &expr,
        .metadata = .{
            .type_id = bool_type,
            .semantics = .plainValue(),
        },
    }};
    const module: Module = .{
        .canonical_types = types,
        .expr_metadata = &entries,
        .globals = &.{},
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &.{},
    };

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &output);
    try module.dumpValueSemantics(&writer.writer);
    output = writer.toArrayList();
    try std.testing.expectEqualStrings(
        "expr 0: bool [value, plain, none; none, copy]\n",
        output.items,
    );
    try std.testing.expectEqual(entries[0].metadata, module.metadataForExpr(&expr).?);

    const globals = [_]Global{.{
        .module_name = "main",
        .name = "flag",
        .is_mutable = false,
        .type_id = bool_type,
        .init = &expr,
    }};
    var verified_module = module;
    verified_module.globals = &globals;
    try std.testing.expectError(error.InvalidSinkAction, verified_module.verifyValueActions());
    entries[0].metadata.consumption.sink = .initialize;
    try verified_module.verifyValueActions();
}

test "intrinsic-call dump and verifier use resolved identities" {
    var types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer types.deinit();
    const bool_type = try types.intern(.{ .primitive = .bool });
    const primitive_id: identity.DeclId = @fromBackingInt(@intCast(7));
    var call_expr: Expr = .{ .call = .{
        .intrinsic_id = .std_sync_share_boxed,
        .decl_id = primitive_id,
        .module_name = "std.sync",
        .owner = null,
        .callee = "share_boxed",
        .args = &.{},
    } };
    const entries = [_]ExprMetadataEntry{.{
        .expr = &call_expr,
        .metadata = .{
            .type_id = bool_type,
            .semantics = .plainValue(),
        },
    }};
    const main_body = [_]Stmt{.{ .expr = &call_expr }};
    const functions = [_]Function{
        .{
            .decl_id = primitive_id,
            .module_name = "std.sync",
            .owner = null,
            .name = "share_boxed",
            .params = &.{},
            .return_type_id = bool_type,
            .body = &.{},
        },
        .{
            .module_name = "main",
            .owner = null,
            .name = "main",
            .params = &.{},
            .return_type_id = bool_type,
            .body = &main_body,
        },
    };
    const module: Module = .{
        .canonical_types = types,
        .expr_metadata = &entries,
        .globals = &.{},
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &functions,
    };

    try module.verifyIntrinsicCalls();
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &output);
    try module.dumpIntrinsicCalls(&writer.writer);
    output = writer.toArrayList();
    try std.testing.expectEqualStrings(
        "expr 0: intrinsic std_sync_share_boxed\n",
        output.items,
    );

    call_expr.call.intrinsic_id = null;
    try std.testing.expectError(error.IncorrectIntrinsicIdentity, module.verifyIntrinsicCalls());
    call_expr.call.intrinsic_id = .std_own_arc_new_boxed;
    try std.testing.expectError(error.IncorrectIntrinsicIdentity, module.verifyIntrinsicCalls());
}

test "ordinary function named index is not a syntax intrinsic" {
    const index_id: identity.DeclId = @fromBackingInt(@intCast(42));
    var call_expr: Expr = .{ .call = .{
        .decl_id = index_id,
        .module_name = "collections.slot_map",
        .owner = null,
        .callee = "index",
        .args = &.{},
    } };
    const entries = [_]ExprMetadataEntry{.{
        .expr = &call_expr,
        .metadata = .{ .type_id = @fromBackingInt(@intCast(0)), .semantics = .plainValue() },
    }};
    const body = [_]Stmt{.{ .expr = &call_expr }};
    const functions = [_]Function{
        .{ .decl_id = index_id, .module_name = "collections.slot_map", .owner = null, .name = "index", .params = &.{}, .body = &.{} },
        .{ .module_name = "main", .owner = null, .name = "main", .params = &.{}, .body = &body },
    };
    const module: Module = .{
        .expr_metadata = &entries,
        .globals = &.{},
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &functions,
    };
    try module.verifyIntrinsicCalls();
}

test "boxed intrinsic expressions reject the wrong operation identity" {
    var payload: Expr = .{ .bool = true };
    var share_expr: Expr = .{ .sync_share_boxed = .{
        .intrinsic_id = .std_sync_share,
        .module_name = "std.sync",
        .owner = null,
        .callee = "share_boxed",
        .payload = &payload,
    } };
    const entries = [_]ExprMetadataEntry{.{
        .expr = &share_expr,
        .metadata = .{
            .type_id = @fromBackingInt(@intCast(0)),
            .semantics = .plainValue(),
        },
    }};
    const body = [_]Stmt{.{ .expr = &share_expr }};
    const functions = [_]Function{.{
        .module_name = "main",
        .owner = null,
        .name = "main",
        .params = &.{},
        .body = &body,
    }};
    const module: Module = .{
        .expr_metadata = &entries,
        .globals = &.{},
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &functions,
    };

    try module.verifyIntrinsicCalls();
    share_expr.sync_share_boxed.intrinsic_id = .std_thread_spawn;
    try std.testing.expectError(error.InvalidIntrinsicExpression, module.verifyIntrinsicCalls());
}

test "builtin expressions require their typed operation identity" {
    var string_expr: Expr = .{ .string = "abc" };
    var len_expr: Expr = .{ .string_len = &string_expr };
    var entries = [_]ExprMetadataEntry{.{
        .expr = &len_expr,
        .metadata = .{
            .type_id = @fromBackingInt(@intCast(0)),
            .semantics = .plainValue(),
            .intrinsic_id = .string_len,
        },
    }};
    const body = [_]Stmt{.{ .expr = &len_expr }};
    const functions = [_]Function{.{
        .module_name = "main",
        .owner = null,
        .name = "main",
        .params = &.{},
        .body = &body,
    }};
    const module: Module = .{
        .expr_metadata = &entries,
        .globals = &.{},
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &functions,
    };

    try module.verifyIntrinsicCalls();
    entries[0].metadata.intrinsic_id = .sequence_len;
    try std.testing.expectError(error.IncorrectIntrinsicIdentity, module.verifyIntrinsicCalls());
    entries[0].metadata.intrinsic_id = null;
    try std.testing.expectError(error.IncorrectIntrinsicIdentity, module.verifyIntrinsicCalls());
}

test "intrinsic verifier ignores superseded expression metadata" {
    var stale_payload: Expr = .{ .bool = false };
    var stale_expr: Expr = .{ .sync_share_boxed = .{
        .module_name = "std.sync",
        .owner = null,
        .callee = "share_boxed",
        .payload = &stale_payload,
    } };
    var live_expr: Expr = .{ .bool = true };
    const entries = [_]ExprMetadataEntry{
        .{
            .expr = &stale_expr,
            .metadata = .{
                .type_id = @fromBackingInt(@intCast(0)),
                .semantics = .plainValue(),
            },
        },
        .{
            .expr = &live_expr,
            .metadata = .{
                .type_id = @fromBackingInt(@intCast(0)),
                .semantics = .plainValue(),
            },
        },
    };
    const body = [_]Stmt{.{ .expr = &live_expr }};
    const functions = [_]Function{.{
        .module_name = "main",
        .owner = null,
        .name = "main",
        .params = &.{},
        .body = &body,
    }};
    const module: Module = .{
        .expr_metadata = &entries,
        .globals = &.{},
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &functions,
    };

    try module.verifyIntrinsicCalls();
}

test "compiler identity verifier requires typed result cases" {
    var types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer types.deinit();
    const bool_type = try types.intern(.{ .primitive = .bool });
    const result_type = try types.intern(.{ .result = .{ .ok = bool_type, .err = bool_type } });
    var result_expr: Expr = .{ .union_case = .{
        .union_name = language_contracts.result_type_name,
        .case_name = "display-only",
        .result_case = .ok,
        .value = null,
        .result_ok_type_id = bool_type,
        .result_err_type_id = bool_type,
    } };
    const entries = [_]ExprMetadataEntry{.{
        .expr = &result_expr,
        .metadata = .{
            .type_id = result_type,
            .semantics = .plainValue(),
        },
    }};
    const body = [_]Stmt{.{ .expr = &result_expr }};
    const functions = [_]Function{.{
        .module_name = "main",
        .owner = null,
        .name = "main",
        .params = &.{},
        .return_type_id = result_type,
        .body = &body,
    }};
    const module: Module = .{
        .canonical_types = types,
        .expr_metadata = &entries,
        .globals = &.{},
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &functions,
    };

    try module.verifyCompilerIdentities();
    try module.verify();
    result_expr.union_case.result_case = null;
    try std.testing.expectError(error.InvalidResultCaseIdentity, module.verifyCompilerIdentities());
    try std.testing.expectError(error.InvalidResultCaseIdentity, module.verify());
}

test "compiler identity verifier identifies the function and expression metadata" {
    var types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer types.deinit();
    const int_type = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    var value: Expr = .{ .int = .{ .value = 1, .type_name = null } };
    const body = [_]Stmt{.{ .expr = &value }};
    const functions = [_]Function{.{
        .module_name = "sample",
        .owner = null,
        .name = "broken",
        .params = &.{},
        .body = &body,
    }};
    const entries = [_]ExprMetadataEntry{.{
        .expr = &value,
        .metadata = .{ .type_id = int_type, .semantics = .plainValue(), .checked_place_root = .{ .binding = @fromBackingInt(@intCast(999)) } },
    }};
    const module: Module = .{
        .canonical_types = types,
        .expr_metadata = &entries,
        .globals = &.{},
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &functions,
    };
    var failure: IdentityFailureContext = .{};
    try std.testing.expectError(error.InvalidCheckedPlaceRoot, module.verifyCompilerIdentitiesWithContext(&failure));
    try std.testing.expectEqualStrings("broken", failure.function.?.name);
    try std.testing.expectEqual(@as(?usize, 0), failure.metadata_index);
    try std.testing.expectEqualStrings("int", failure.expression_kind.?);
}

test "compiler identity verifier requires explicit test entries" {
    var types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer types.deinit();
    const void_type = try types.intern(.{ .primitive = .void });
    var functions = [_]Function{.{
        .module_name = "tests",
        .owner = null,
        .name = "arbitrary-generated-name",
        .is_test_entry = true,
        .params = &.{},
        .return_type_id = void_type,
        .body = &.{},
    }};
    const tests = [_]InlineTest{.{
        .module_name = "tests",
        .name = "works",
        .function_name = "arbitrary-generated-name",
    }};
    const module: Module = .{
        .canonical_types = types,
        .globals = &.{},
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &functions,
        .tests = &tests,
    };

    try module.verifyCompilerIdentities();
    try module.verify();
    functions[0].is_test_entry = false;
    try std.testing.expectError(error.InvalidTestEntryIdentity, module.verifyCompilerIdentities());
    try std.testing.expectError(error.InvalidTestEntryIdentity, module.verify());
}

fn testVerifierDuplicateIndexes(allocator: std.mem.Allocator) !void {
    const type_id: TypeId = @fromBackingInt(1);
    var values: [40]Expr = undefined;
    var value_metadata: [40]ExprMetadataEntry = undefined;
    for (&values, &value_metadata) |*value, *entry| {
        value.* = .{ .bool = true };
        entry.* = .{ .expr = value, .metadata = .{ .type_id = type_id, .semantics = .plainValue() } };
    }
    var module: Module = .{
        .globals = &.{},
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &.{},
        .expr_metadata = &value_metadata,
    };
    try module.verifyValueActionsWithAllocator(allocator);
    // Equal values in distinct nodes are valid; repeating a node is not.
    value_metadata[39].expr = &values[0];
    if (module.verifyValueActionsWithAllocator(allocator)) |_| {
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.DuplicateExpressionMetadata => {},
        else => return err,
    }

    const callee: identity.DeclId = @fromBackingInt(1);
    const caller: identity.DeclId = @fromBackingInt(2);
    var calls: [40]Expr = undefined;
    var call_metadata: [40]ExprMetadataEntry = undefined;
    for (&calls, &call_metadata, 0..) |*call, *entry, index| {
        call.* = .{ .call = .{
            .decl_id = callee,
            .module_name = "main",
            .owner = null,
            .callee = "read",
            .args = &.{},
            .checked_method_use = .{
                .use_id = @intCast(index / 2 + 1),
                .source_declaration_id = caller,
                .source_offset = index / 2,
                .callee_declaration_id = callee,
                .result_type_id = type_id,
            },
        } };
        entry.* = .{ .expr = call, .metadata = .{ .type_id = type_id, .semantics = .plainValue() } };
    }
    const functions = [_]Function{.{ .decl_id = callee, .owner = null, .name = "read", .params = &.{}, .return_type_id = type_id, .body = &.{} }};
    module.functions = &functions;
    module.expr_metadata = &call_metadata;
    // Each pair models two specializations of one source use.
    try module.verifyGenericRequirementsWithAllocator(allocator, true);
    calls[39].call.checked_method_use.?.source_offset = 999;
    if (module.verifyGenericRequirementsWithAllocator(allocator, true)) |_| {
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.DuplicateMethodUseIdentity => {},
        else => return err,
    }
    // Dead metadata is not inspected in the unretained path, even if malformed.
    calls[39].call.checked_method_use = null;
    try module.verifyGenericRequirementsWithAllocator(allocator, false);
}

test "verifier duplicate indexes preserve identities and release allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testVerifierDuplicateIndexes, .{});
}

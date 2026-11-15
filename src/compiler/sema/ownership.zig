const type_resolution = @import("type_resolution.zig");
const std = @import("std");
const identity = @import("identity.zig");
const ast = @import("../parser/ast.zig");
const semantic_types = @import("types.zig");
const diagnostics = @import("../diagnostics.zig");
const lexer = @import("../lexer/lexer.zig");
const intrinsics = @import("../intrinsics.zig");
const sir = @import("sir.zig");
const generics = @import("generics.zig");
const declarations = @import("declarations.zig");
const protocols = @import("protocols.zig");

/// Access to a storage-bearing place. This is deliberately separate from the
/// value's type and from provenance: provenance answers where storage comes
/// from, while access answers which operations are authorized through the
/// current path.
pub const Access = enum {
    read_only,
    writable,

    pub fn allowsMutation(self: Access) bool {
        return self == .writable;
    }

    /// Projection may preserve or narrow access, but never widen it.
    pub fn constrain(self: Access, requested: Access) Access {
        if (self == .read_only or requested == .read_only) return .read_only;
        return .writable;
    }
};

test "place access projection cannot amplify read-only access" {
    try std.testing.expectEqual(Access.read_only, Access.read_only.constrain(.writable));
    try std.testing.expectEqual(Access.read_only, Access.writable.constrain(.read_only));
    try std.testing.expectEqual(Access.writable, Access.writable.constrain(.writable));
}

pub const MethodSummaryBindings = struct {
    generic_params: ?[]const ast.GenericParam,
    generic_args: ?[]const semantic_types.GenericArgument,
    owns_bindings: bool,

    pub fn deinit(self: MethodSummaryBindings, allocator: std.mem.Allocator) void {
        if (!self.owns_bindings) return;
        allocator.free(self.generic_params.?);
        allocator.free(self.generic_args.?);
    }
};

pub const SummarySink = union(enum) {
    global,
    sink_param: usize,
};

pub const BorrowRootQuery = struct {
    const Self = @This();
    fn findParamIndex(params: []const ast.Param, name: []const u8) ?usize {
        for (params, 0..) |param, i| {
            if (std.mem.eql(u8, param.name, name)) return i;
        }
        return null;
    }

    fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return std.mem.eql(u8, a.?, b.?);
    }

    roots: NormalizedBorrowRoots,

    pub fn initSummary() Self {
        return .{
            .roots = .none(),
        };
    }

    pub fn init() Self {
        return .{ .roots = .none() };
    }

    pub fn markParamFlow(
        self: *Self,
        params: []const ast.Param,
        source_can_borrow: []const bool,
        name: []const u8,
        allow_nonborrow_root: bool,
    ) void {
        const source_index = findParamIndex(params, name) orelse return;
        if (!(allow_nonborrow_root or source_can_borrow[source_index])) return;
        self.roots = NormalizedBorrowRoots.combine(
            self.roots,
            if (source_can_borrow[source_index])
                NormalizedBorrowRoots.paramValue(name)
            else
                NormalizedBorrowRoots.paramOwnerValue(name),
        );
    }

    pub fn markStatic(self: *Self) void {
        self.roots = NormalizedBorrowRoots.combine(self.roots, NormalizedBorrowRoots.staticValue());
    }

    pub fn markGlobal(self: *Self, name: []const u8) void {
        self.roots = NormalizedBorrowRoots.combine(self.roots, NormalizedBorrowRoots.globalValue(name));
    }

    pub fn markParam(self: *Self, name: []const u8) void {
        self.roots = NormalizedBorrowRoots.combine(self.roots, NormalizedBorrowRoots.paramValue(name));
    }

    pub fn markParamOwner(self: *Self, name: []const u8) void {
        self.roots = NormalizedBorrowRoots.combine(self.roots, NormalizedBorrowRoots.paramOwnerValue(name));
    }

    pub fn markLocal(self: *Self, name: []const u8) void {
        self.roots = NormalizedBorrowRoots.combine(self.roots, NormalizedBorrowRoots.localValue(name));
    }

    pub fn markTemporary(self: *Self) void {
        self.roots = NormalizedBorrowRoots.combine(self.roots, NormalizedBorrowRoots.temporaryValue());
    }

    pub fn mergeFrom(self: *Self, other: Self) void {
        self.roots = NormalizedBorrowRoots.combine(self.roots, other.roots);
    }

    pub fn containsParamSource(self: Self, params: []const ast.Param, source_can_borrow: []const bool, source_index: usize) bool {
        const name = params[source_index].name;
        if (source_can_borrow[source_index]) {
            if (!self.roots.contains_param) return false;
            if (!self.roots.precise_param_roots) return true;
            var i: usize = 0;
            while (i < self.roots.param_root_count) : (i += 1) {
                if (optionalEql(self.roots.param_roots[i], name)) return true;
            }
            return false;
        }

        if (!self.roots.contains_param_owner) return false;
        if (!self.roots.precise_param_owner_roots) return true;
        var i: usize = 0;
        while (i < self.roots.param_owner_root_count) : (i += 1) {
            if (optionalEql(self.roots.param_owner_roots[i], name)) return true;
        }
        return false;
    }

    pub fn toProvenance(self: Self) Provenance {
        return Provenance.fromNormalizedBorrowRoots(self.roots);
    }
};

fn rootsOptionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub const ProvenanceRootKind = enum(u8) {
    none,
    static,
    global,
    param,
    param_owner,
    local,
    temporary,
    scoped_alloc,
    composite,
};

pub const NormalizedBorrowRoots = struct {
    // These fixed-width root sets are part of why the abstract domain is finite:
    // once precision would exceed the cap, the representation widens to an
    // imprecise-but-sound summary instead of growing without bound.
    pub const max_precise_local_roots = 4;
    pub const max_precise_param_roots = 8;

    contains_static: bool = false,
    contains_global: bool = false,
    global_name: ?[]const u8 = null,
    contains_param: bool = false,
    precise_param_roots: bool = true,
    param_root_count: u8 = 0,
    param_roots: [max_precise_param_roots]?[]const u8 = .{ null, null, null, null, null, null, null, null },
    contains_param_owner: bool = false,
    precise_param_owner_roots: bool = true,
    param_owner_root_count: u8 = 0,
    param_owner_roots: [max_precise_param_roots]?[]const u8 = .{ null, null, null, null, null, null, null, null },
    contains_local: bool = false,
    contains_temporary: bool = false,
    contains_scoped_alloc: bool = false,
    precise_local_roots: bool = true,
    local_root_count: u8 = 0,
    local_roots: [max_precise_local_roots]?[]const u8 = .{ null, null, null, null },

    pub fn none() NormalizedBorrowRoots {
        return .{};
    }

    pub fn staticValue() NormalizedBorrowRoots {
        return .{ .contains_static = true };
    }

    pub fn globalValue(name: []const u8) NormalizedBorrowRoots {
        return .{
            .contains_global = true,
            .global_name = name,
        };
    }

    pub fn paramValue(name: []const u8) NormalizedBorrowRoots {
        var roots = NormalizedBorrowRoots{ .contains_param = true };
        roots.param_roots[0] = name;
        roots.param_root_count = 1;
        return roots;
    }

    pub fn paramOwnerValue(name: []const u8) NormalizedBorrowRoots {
        var roots = NormalizedBorrowRoots{ .contains_param_owner = true };
        roots.param_owner_roots[0] = name;
        roots.param_owner_root_count = 1;
        return roots;
    }

    pub fn localValue(name: []const u8) NormalizedBorrowRoots {
        var roots = NormalizedBorrowRoots{ .contains_local = true };
        roots.local_roots[0] = name;
        roots.local_root_count = 1;
        return roots;
    }

    pub fn temporaryValue() NormalizedBorrowRoots {
        return .{ .contains_temporary = true };
    }

    pub fn scopedAllocValue() NormalizedBorrowRoots {
        return .{ .contains_scoped_alloc = true };
    }

    pub fn hasAny(self: NormalizedBorrowRoots) bool {
        return self.contains_static or
            self.contains_global or
            self.contains_param or
            self.contains_param_owner or
            self.contains_local or
            self.contains_temporary or
            self.contains_scoped_alloc;
    }

    pub fn singleRootKind(self: NormalizedBorrowRoots) ProvenanceRootKind {
        var count: usize = 0;
        var kind: ProvenanceRootKind = .none;

        if (self.contains_static) {
            count += 1;
            kind = .static;
        }
        if (self.contains_global and self.global_name != null) {
            count += 1;
            kind = .global;
        } else if (self.contains_global) {
            count += 2;
        }
        if (self.contains_param and self.precise_param_roots and self.param_root_count == 1) {
            count += 1;
            kind = .param;
        } else if (self.contains_param) {
            count += 2;
        }
        if (self.contains_param_owner and self.precise_param_owner_roots and self.param_owner_root_count == 1) {
            count += 1;
            kind = .param_owner;
        } else if (self.contains_param_owner) {
            count += 2;
        }
        if (self.contains_local and self.precise_local_roots and self.local_root_count == 1) {
            count += 1;
            kind = .local;
        } else if (self.contains_local) {
            count += 2;
        }
        if (self.contains_temporary) {
            count += 1;
            kind = .temporary;
        }
        if (self.contains_scoped_alloc) {
            count += 1;
            kind = .scoped_alloc;
        }

        return if (count == 1) kind else if (self.hasAny()) .composite else .none;
    }

    pub fn singleRootName(self: NormalizedBorrowRoots) ?[]const u8 {
        return switch (self.singleRootKind()) {
            .global => self.global_name,
            .param => if (self.precise_param_roots and self.param_root_count == 1) self.param_roots[0] else null,
            .param_owner => if (self.precise_param_owner_roots and self.param_owner_root_count == 1) self.param_owner_roots[0] else null,
            .local => if (self.precise_local_roots and self.local_root_count == 1) self.local_roots[0] else null,
            else => null,
        };
    }

    pub fn combine(a: NormalizedBorrowRoots, b: NormalizedBorrowRoots) NormalizedBorrowRoots {
        var combined = NormalizedBorrowRoots{
            .contains_static = a.contains_static or b.contains_static,
            .contains_global = a.contains_global or b.contains_global,
            .global_name = if (a.contains_global and b.contains_global)
                if (rootsOptionalEql(a.global_name, b.global_name)) a.global_name else null
            else if (a.contains_global)
                a.global_name
            else
                b.global_name,
            .contains_param = a.contains_param or b.contains_param,
            .precise_param_roots = a.precise_param_roots and b.precise_param_roots,
            .contains_param_owner = a.contains_param_owner or b.contains_param_owner,
            .precise_param_owner_roots = a.precise_param_owner_roots and b.precise_param_owner_roots,
            .contains_local = a.contains_local or b.contains_local,
            .contains_temporary = a.contains_temporary or b.contains_temporary,
            .contains_scoped_alloc = a.contains_scoped_alloc or b.contains_scoped_alloc,
            .precise_local_roots = a.precise_local_roots and b.precise_local_roots,
        };
        if (combined.contains_param) {
            combined.mergeParamRootsFrom(a);
            combined.mergeParamRootsFrom(b);
        }
        if (combined.contains_param_owner) {
            combined.mergeParamOwnerRootsFrom(a);
            combined.mergeParamOwnerRootsFrom(b);
        }
        if (combined.contains_local) {
            combined.mergeLocalRootsFrom(a);
            combined.mergeLocalRootsFrom(b);
        }
        return combined;
    }

    pub fn mergeParamRootsFrom(self: *NormalizedBorrowRoots, other: NormalizedBorrowRoots) void {
        if (!other.contains_param) return;
        if (!self.precise_param_roots or !other.precise_param_roots) {
            self.precise_param_roots = false;
            self.param_root_count = 0;
            self.param_roots = .{ null, null, null, null, null, null, null, null };
            return;
        }

        var i: usize = 0;
        while (i < other.param_root_count) : (i += 1) {
            const name = other.param_roots[i] orelse continue;
            self.addParamRoot(name);
            if (!self.precise_param_roots) return;
        }
    }

    pub fn addParamRoot(self: *NormalizedBorrowRoots, root_name: []const u8) void {
        var i: usize = 0;
        while (i < self.param_root_count) : (i += 1) {
            if (rootsOptionalEql(self.param_roots[i], root_name)) return;
        }
        if (self.param_root_count >= max_precise_param_roots) {
            self.precise_param_roots = false;
            self.param_root_count = 0;
            self.param_roots = .{ null, null, null, null, null, null, null, null };
            return;
        }
        self.param_roots[self.param_root_count] = root_name;
        self.param_root_count += 1;
    }

    pub fn mergeParamOwnerRootsFrom(self: *NormalizedBorrowRoots, other: NormalizedBorrowRoots) void {
        if (!other.contains_param_owner) return;
        if (!self.precise_param_owner_roots or !other.precise_param_owner_roots) {
            self.precise_param_owner_roots = false;
            self.param_owner_root_count = 0;
            self.param_owner_roots = .{ null, null, null, null, null, null, null, null };
            return;
        }

        var i: usize = 0;
        while (i < other.param_owner_root_count) : (i += 1) {
            const name = other.param_owner_roots[i] orelse continue;
            self.addParamOwnerRoot(name);
            if (!self.precise_param_owner_roots) return;
        }
    }

    pub fn addParamOwnerRoot(self: *NormalizedBorrowRoots, root_name: []const u8) void {
        var i: usize = 0;
        while (i < self.param_owner_root_count) : (i += 1) {
            if (rootsOptionalEql(self.param_owner_roots[i], root_name)) return;
        }
        if (self.param_owner_root_count >= max_precise_param_roots) {
            self.precise_param_owner_roots = false;
            self.param_owner_root_count = 0;
            self.param_owner_roots = .{ null, null, null, null, null, null, null, null };
            return;
        }
        self.param_owner_roots[self.param_owner_root_count] = root_name;
        self.param_owner_root_count += 1;
    }

    pub fn mergeLocalRootsFrom(self: *NormalizedBorrowRoots, other: NormalizedBorrowRoots) void {
        if (!other.contains_local) return;
        if (!self.precise_local_roots or !other.precise_local_roots) {
            self.precise_local_roots = false;
            self.local_root_count = 0;
            self.local_roots = .{ null, null, null, null };
            return;
        }

        var i: usize = 0;
        while (i < other.local_root_count) : (i += 1) {
            const name = other.local_roots[i] orelse continue;
            self.addLocalRoot(name);
            if (!self.precise_local_roots) return;
        }
    }

    pub fn addLocalRoot(self: *NormalizedBorrowRoots, root_name: []const u8) void {
        var i: usize = 0;
        while (i < self.local_root_count) : (i += 1) {
            if (rootsOptionalEql(self.local_roots[i], root_name)) return;
        }
        if (self.local_root_count >= max_precise_local_roots) {
            self.precise_local_roots = false;
            self.local_root_count = 0;
            self.local_roots = .{ null, null, null, null };
            return;
        }
        self.local_roots[self.local_root_count] = root_name;
        self.local_root_count += 1;
    }
};

pub const Provenance = struct {
    roots: NormalizedBorrowRoots = .none(),

    pub fn none() Provenance {
        return .{};
    }

    pub fn staticValue() Provenance {
        return Provenance.fromNormalizedBorrowRoots(NormalizedBorrowRoots.staticValue());
    }

    pub fn globalValue(name: []const u8) Provenance {
        return Provenance.fromNormalizedBorrowRoots(NormalizedBorrowRoots.globalValue(name));
    }

    pub fn paramValue(name: []const u8) Provenance {
        return Provenance.fromNormalizedBorrowRoots(NormalizedBorrowRoots.paramValue(name));
    }

    pub fn paramOwnerValue(name: []const u8) Provenance {
        return Provenance.fromNormalizedBorrowRoots(NormalizedBorrowRoots.paramOwnerValue(name));
    }

    pub fn localValue(name: []const u8) Provenance {
        return Provenance.fromNormalizedBorrowRoots(NormalizedBorrowRoots.localValue(name));
    }

    pub fn temporaryValue() Provenance {
        return Provenance.fromNormalizedBorrowRoots(NormalizedBorrowRoots.temporaryValue());
    }

    pub fn scopedAllocValue() Provenance {
        return Provenance.fromNormalizedBorrowRoots(NormalizedBorrowRoots.scopedAllocValue());
    }

    pub fn toNormalizedBorrowRoots(self: Provenance) NormalizedBorrowRoots {
        return self.roots;
    }

    pub fn fromNormalizedBorrowRoots(roots: NormalizedBorrowRoots) Provenance {
        return .{
            .roots = roots,
        };
    }

    pub fn derived(self: Provenance) Provenance {
        return self;
    }

    pub fn singleRootKind(self: Provenance) ProvenanceRootKind {
        return self.roots.singleRootKind();
    }

    pub fn singleRootName(self: Provenance) ?[]const u8 {
        return self.roots.singleRootName();
    }

    pub fn hasBorrow(self: Provenance) bool {
        return self.roots.hasAny();
    }

    pub fn containsLocalRoots(self: Provenance) bool {
        return self.roots.contains_local;
    }

    pub fn containsParamRoots(self: Provenance) bool {
        return self.roots.contains_param;
    }

    pub fn hasPreciseLocalRoots(self: Provenance) bool {
        return self.roots.precise_local_roots;
    }

    pub fn localRootCount(self: Provenance) u8 {
        return self.roots.local_root_count;
    }

    pub fn localRootAt(self: Provenance, index: usize) ?[]const u8 {
        return self.roots.local_roots[index];
    }

    pub fn combine(a: Provenance, b: Provenance) Provenance {
        if (!a.hasBorrow()) return b;
        if (!b.hasBorrow()) return a;
        return Provenance.fromNormalizedBorrowRoots(NormalizedBorrowRoots.combine(a.toNormalizedBorrowRoots(), b.toNormalizedBorrowRoots()));
    }
};

pub const BorrowSummaryKey = callables.SummaryKey;
pub const BorrowSummaryOwnedKey = callables.OwnedSummaryKey;
pub const BorrowSummaryDependency = callables.SummaryDependency;

pub const BorrowSummaryScc = struct {
    members: []BorrowSummaryOwnedKey,

    pub fn deinit(self: BorrowSummaryScc, allocator: std.mem.Allocator) void {
        for (self.members) |member| member.deinit(allocator);
        allocator.free(self.members);
    }
};

pub const BorrowSummarySccResult = struct {
    components: []BorrowSummaryScc,

    pub fn deinit(self: BorrowSummarySccResult, allocator: std.mem.Allocator) void {
        for (self.components) |component| component.deinit(allocator);
        allocator.free(self.components);
    }
};

pub fn ActiveBorrowSummary(comptime BorrowEscapeRelation: type) type {
    return struct {
        key: BorrowSummaryKey,
        relation: BorrowEscapeRelation,

        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            self.relation.deinit(allocator);
        }
    };
}

pub fn CachedBorrowSummary(comptime BorrowEscapeRelation: type) type {
    return struct {
        key: BorrowSummaryKey,
        owned_generic_args: ?[]semantic_types.GenericArgument,
        relation: BorrowEscapeRelation,

        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            if (self.owned_generic_args) |generic_args| allocator.free(generic_args);
            self.relation.deinit(allocator);
        }
    };
}

pub const BorrowedPlaceMode = enum {
    alias,
    view,
};

pub const BorrowedPlaceDependency = struct {
    roots: NormalizedBorrowRoots,
    projection: PlaceProjectionPath,
    mode: BorrowedPlaceMode,

    pub fn none() BorrowedPlaceDependency {
        return .{
            .roots = .none(),
            .projection = .none(),
            .mode = .view,
        };
    }

    pub fn hasBorrow(self: BorrowedPlaceDependency) bool {
        return self.projection.has_root;
    }
};

pub const PlaceProjectionStep = union(enum) {
    field: []const u8,
    index: ?i64,
    container,
};

pub const PlaceProjectionPath = struct {
    const max_steps = 4;

    has_root: bool = false,
    step_count: usize = 0,
    source_step_count: usize = 0,
    source_expr: ?*ast.Expr = null,
    truncated: bool = false,
    steps: [max_steps]PlaceProjectionStep = undefined,

    pub fn none() PlaceProjectionPath {
        return .{};
    }

    pub fn root() PlaceProjectionPath {
        return .{ .has_root = true };
    }

    pub fn appendField(self: *PlaceProjectionPath, field: []const u8) void {
        if (!self.has_root) return;
        const suffix_index = self.step_count - self.source_step_count;
        if (suffix_index >= max_steps) {
            self.truncated = true;
            return;
        }
        self.steps[suffix_index] = .{ .field = field };
        self.step_count += 1;
    }

    pub fn appendIndex(self: *PlaceProjectionPath, index: ?i64) void {
        if (!self.has_root) return;
        const suffix_index = self.step_count - self.source_step_count;
        if (suffix_index >= max_steps) {
            self.truncated = true;
            return;
        }
        self.steps[suffix_index] = .{ .index = index };
        self.step_count += 1;
    }

    pub fn appendContainer(self: *PlaceProjectionPath) void {
        if (!self.has_root) return;
        const suffix_index = self.step_count - self.source_step_count;
        if (suffix_index >= max_steps) {
            self.truncated = true;
            return;
        }
        self.steps[suffix_index] = .container;
        self.step_count += 1;
    }

    pub fn stepAt(self: PlaceProjectionPath, index: usize) PlaceProjectionStep {
        std.debug.assert(index < self.step_count);
        if (index < self.source_step_count) return sourceProjectionStepAt(self.source_expr.?, index);
        return self.steps[index - self.source_step_count];
    }

    pub fn conservativeRoot() PlaceProjectionPath {
        return .{
            .has_root = true,
            .step_count = 0,
            .truncated = true,
            .steps = undefined,
        };
    }
};

pub fn constIndexValue(expr: *ast.Expr) ?i64 {
    return switch (expr.*) {
        .int => |int| int.value,
        else => null,
    };
}

pub fn placeProjectionPathFromExpr(expr: *ast.Expr) PlaceProjectionPath {
    const count = sourceProjectionStepCount(expr) orelse return .none();
    return .{ .has_root = true, .step_count = count, .source_step_count = count, .source_expr = expr };
}

fn sourceProjectionStepCount(expr: *ast.Expr) ?usize {
    return switch (expr.*) {
        .name => 0,
        .field => |field| if (sourceProjectionStepCount(field.object)) |count| count + 1 else null,
        .index => |index| if (sourceProjectionStepCount(index.object)) |count| count + 1 else null,
        .deref => |deref| sourceProjectionStepCount(deref.expr),
        .address_of => |address_of| sourceProjectionStepCount(address_of.expr),
        else => null,
    };
}

fn sourceProjectionStepAt(expr: *ast.Expr, index: usize) PlaceProjectionStep {
    return switch (expr.*) {
        .field => |field| blk: {
            const parent_count = sourceProjectionStepCount(field.object).?;
            break :blk if (index == parent_count) .{ .field = field.field } else sourceProjectionStepAt(field.object, index);
        },
        .index => |item| blk: {
            const parent_count = sourceProjectionStepCount(item.object).?;
            break :blk if (index == parent_count) .{ .index = constIndexValue(item.index) } else sourceProjectionStepAt(item.object, index);
        },
        .deref => |deref| sourceProjectionStepAt(deref.expr, index),
        .address_of => |address_of| sourceProjectionStepAt(address_of.expr, index),
        else => unreachable,
    };
}

pub fn projectionBaseExpr(expr: *ast.Expr) *ast.Expr {
    return switch (expr.*) {
        .field => |field| projectionBaseExpr(field.object),
        .index => |index| projectionBaseExpr(index.object),
        else => expr,
    };
}

pub fn isBorrowProducingViewMethodCall(call: ast.MethodCall) bool {
    return call.args.len == 0 and
        call.type_args.len == 0 and
        intrinsics.resolveMethod(.string, call.method) == .string_bytes;
}

pub fn isBorrowProducingViewExpr(expr: *ast.Expr) bool {
    return switch (expr.*) {
        .slice_range => true,
        .method_call => |call| isBorrowProducingViewMethodCall(call),
        else => false,
    };
}

pub fn normalizedBorrowRootSourceExpr(expr: *ast.Expr) *ast.Expr {
    return switch (expr.*) {
        .field => |field| normalizedBorrowRootSourceExpr(field.object),
        .index => |index| normalizedBorrowRootSourceExpr(index.object),
        .slice_range => |slice| normalizedBorrowRootSourceExpr(slice.object),
        .method_call => |call| {
            if (isBorrowProducingViewMethodCall(call)) {
                return normalizedBorrowRootSourceExpr(call.object);
            }
            return expr;
        },
        else => expr,
    };
}

pub fn findLiteralField(fields: []const ast.StructLiteralField, name: []const u8) ?ast.StructLiteralField {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field;
    }
    return null;
}

pub const OwnershipClass = enum(u8) {
    plain,
    shared,
    owned,
    borrowed,
};

pub fn exprPathContainsDeref(expr: *ast.Expr) bool {
    var cursor = expr;
    while (true) {
        switch (cursor.*) {
            .field => |field| cursor = field.object,
            .index => |index| cursor = index.object,
            .address_of => |address_of| cursor = address_of.expr,
            .deref => return true,
            else => return false,
        }
    }
}

pub const PlaceRootKind = enum {
    local,
    parameter,
    global,
    raw_pointee,
};

pub const PlaceAddressability = enum {
    root,
    projected_candidate,
    raw_pointee,
};

/// The ownership identity of a source-visible place. Projection-specific
/// legality (for example packed fields and union payloads) remains an explicit
/// validation step, but every consumer gets root access, provenance, and
/// conflict identity from this one resolution.
pub const ResolvedPlace = struct {
    root_kind: PlaceRootKind,
    root_name: []const u8,
    root_binding_id: ?identity.BindingId = null,
    root_global_id: ?identity.DeclId = null,
    root_token: lexer.Token,
    root_type_id: semantic_types.TypeId,
    access: Access,
    roots: NormalizedBorrowRoots,
    projection: PlaceProjectionPath,
    addressability: PlaceAddressability,
};

fn rootsHaveStableStorage(roots: NormalizedBorrowRoots) bool {
    return roots.contains_local or
        roots.contains_param or
        roots.contains_param_owner or
        roots.contains_global;
}

pub fn conservativeBorrowProjection(roots: NormalizedBorrowRoots) PlaceProjectionPath {
    // When we have stable roots but no recoverable precise projected source,
    // widen to a root-level borrowed-place dependency instead of
    // under-approximating the runtime source set.
    return if (rootsHaveStableStorage(roots)) PlaceProjectionPath.conservativeRoot() else .none();
}

fn placeRootName(expr: *ast.Expr) ?ast.Name {
    var cursor = expr;
    while (true) {
        switch (cursor.*) {
            .field => |field| cursor = field.object,
            .index => |index| cursor = index.object,
            .deref => |deref| cursor = deref.expr,
            .address_of => |address_of| cursor = address_of.expr,
            .name => |name| return name,
            else => return null,
        }
    }
}

pub fn TypeAnalysis(comptime host: anytype) type {
    return struct {
        const SemaContext = host.SemaContext;
        const SemaError = host.SemaError;
        const LocalBinding = host.LocalBinding;
        const GlobalBinding = host.GlobalBinding;
        const TypedExpr = host.TypedExpr;
        const lookup = declarations.Lookup(SemaContext);
        const canonical = type_resolution.Canonical(SemaContext);
        const canonicalTypeNode = canonical.typeNode;
        const canonicalUnwrapOwned = canonical.unwrapOwnedType;
        const canonicalRefTarget = canonical.refTargetType;
        const canonicalRefIsConst = canonical.refIsConstant;
        const canonicalSliceIsConst = canonical.sliceIsConstant;
        const canonicalTypeKind = canonical.sirType;
        const canonicalStructLookup = lookup.canonicalStructLookup;
        const canonicalUnionLookup = lookup.canonicalUnionLookup;
        const canonicalTypeVisited = canonical.typeVisited;
        const parseType = host.parseType;
        const trustedConcurrentResource = host.trustedConcurrentResource;
        const findGlobal = declarations.GlobalLookup(SemaContext, GlobalBinding).findGlobal;
        const semanticExprMetadata = host.semanticExprMetadata;
        const recordExprMetadata = host.recordExprMetadata;
        const transferActionForExpr = host.transferActionForExpr;
        const optionalEql = host.optionalEql;
        const BorrowEscapeRelation = host.BorrowEscapeRelation;
        const BorrowEscapeSummaryRelation = host.BorrowEscapeSummaryRelation;
        const BorrowSummaryParamFacts = host.BorrowSummaryParamFacts;
        const ResolvedAstFunction = host.ResolvedAstFunction;
        const BorrowSummarySolveContext = host.BorrowSummarySolveContext;
        const findAstFunction = host.findAstFunction;
        const findStruct = lookup.findStruct;
        const parseTypeWithBindings = host.parseTypeWithBindings;
        const unifyGenericBinding = host.unifyGenericBinding;
        const resolveExplicitGenericArgs = host.resolveExplicitGenericArgs;
        const selectSliceViewMethod = host.selectSliceViewMethod;
        const typeStructField = host.typeStructField;
        const typeUnionPayloadField = host.typeUnionPayloadField;

        /// Canonical ownership classification of a type: whether it carries its
        /// own owned value, and whether it can capture an allocator. The
        /// aggregate field walk is local to this owner because the body owner
        /// already reaches the entry module, and borrowing its helper from here
        /// would close a comptime dependency loop.
        pub fn canonicalTypeIsOwnedValue(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
        ) SemaError!bool {
            return switch (canonicalTypeNode(context, type_id).*) {
                .nominal => |nominal| switch (nominal.kind) {
                    .@"struct", .@"union" => (if (canonicalStructLookup(context, program, type_id)) |decl| decl.is_owned_value else false) or
                        trustedConcurrentResource(context, nominal.decl_id) or
                        try anyCanonicalAggregateFieldTypeSatisfies(context, path, program, type_id, canonicalTypeIsOwnedValue),
                    .type_alias => if (nominal.underlying) |underlying|
                        try canonicalTypeIsOwnedValue(context, path, program, underlying)
                    else
                        false,
                    else => false,
                },
                .generic_instance => |instance| switch (instance.kind) {
                    .@"struct" => (if (canonicalStructLookup(context, program, type_id)) |decl| decl.is_owned_value else false) or
                        trustedConcurrentResource(context, instance.base_decl_id) or
                        try anyCanonicalAggregateFieldTypeSatisfies(context, path, program, type_id, canonicalTypeIsOwnedValue),
                    else => false,
                },
                .dense_array, .sparse_array, .owned => true,
                .optional => |child| try canonicalTypeIsOwnedValue(context, path, program, child),
                .array => |array| try canonicalTypeIsOwnedValue(context, path, program, array.item),
                .tuple => |members| blk: {
                    for (members) |member| {
                        if (try canonicalTypeIsOwnedValue(context, path, program, member)) break :blk true;
                    }
                    break :blk false;
                },
                .result => |result| try canonicalTypeIsOwnedValue(context, path, program, result.ok) or
                    try canonicalTypeIsOwnedValue(context, path, program, result.err),
                else => false,
            };
        }

        pub fn canonicalTypeMayCaptureAllocator(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
        ) SemaError!bool {
            return switch (canonicalTypeNode(context, type_id).*) {
                .primitive => |primitive| primitive == .string,
                .nominal => |nominal| switch (nominal.kind) {
                    .@"struct", .@"union" => try anyCanonicalAggregateFieldTypeSatisfies(context, path, program, type_id, canonicalTypeMayCaptureAllocator),
                    .type_alias => if (nominal.underlying) |underlying|
                        try canonicalTypeMayCaptureAllocator(context, path, program, underlying)
                    else
                        false,
                    else => false,
                },
                .generic_instance => |instance| switch (instance.kind) {
                    .@"struct" => try anyCanonicalAggregateFieldTypeSatisfies(context, path, program, type_id, canonicalTypeMayCaptureAllocator),
                    else => false,
                },
                .dense_array => true,
                .optional, .owned => |child| try canonicalTypeMayCaptureAllocator(context, path, program, child),
                .array => |array| try canonicalTypeMayCaptureAllocator(context, path, program, array.item),
                .tuple => |members| blk: {
                    for (members) |member| {
                        if (try canonicalTypeMayCaptureAllocator(context, path, program, member)) break :blk true;
                    }
                    break :blk false;
                },
                .result => |result| try canonicalTypeMayCaptureAllocator(context, path, program, result.ok) or
                    try canonicalTypeMayCaptureAllocator(context, path, program, result.err),
                else => false,
            };
        }

        fn anyCanonicalAggregateFieldTypeSatisfies(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
            comptime predicate: fn (*SemaContext, []const u8, ast.Program, semantic_types.TypeId) SemaError!bool,
        ) SemaError!bool {
            if (canonicalStructLookup(context, program, type_id)) |decl| {
                switch (decl.fields) {
                    .ast_fields => |fields| for (fields) |field| {
                        const field_type = try parseType(context, path, program, decl.module_name, field.type_name);
                        if (try predicate(context, path, program, field_type)) return true;
                    },
                    .inst_fields => |fields| for (fields) |field| {
                        if (try predicate(context, path, program, field.type_id)) return true;
                    },
                }
                return false;
            }
            if (canonicalUnionLookup(context, program, type_id)) |decl| {
                for (decl.fields) |field| {
                    const type_name = field.type_name orelse continue;
                    const field_type = try parseType(context, path, program, decl.module_name, type_name);
                    if (try predicate(context, path, program, field_type)) return true;
                }
                for (decl.variants) |variant| {
                    const variant_type = try parseType(context, path, program, decl.module_name, variant);
                    if (try predicate(context, path, program, variant_type)) return true;
                }
            }
            return false;
        }

        fn resolveBorrowSummaryRelation(ctx: BorrowSummarySolveContext) SemaError!BorrowEscapeSummaryRelation {
            return try BorrowSummarySolver.init(ctx).resolve();
        }

        pub fn normalizedStructReceiverType(context: *SemaContext, type_id: semantic_types.TypeId) ?semantic_types.TypeId {
            const without_ref = if (canonicalTypeKind(context, type_id) == .ref) canonicalRefTarget(context, type_id) else type_id;
            const base = canonicalUnwrapOwned(context, without_ref);
            if (canonicalTypeKind(context, base) != .@"struct") return null;
            return base;
        }

        /// Resolve an inherent method from the canonical receiver type so a
        /// same-named struct from another module cannot supply the body.
        fn findStructMethodForCanonicalType(
            context: *SemaContext,
            program: ast.Program,
            type_id: semantic_types.TypeId,
            name: []const u8,
        ) ?ast.Function {
            const decl = lookup.canonicalBaseStructDecl(context, program, type_id) orelse return null;
            for (decl.methods) |method| {
                if (std.mem.eql(u8, method.name, name)) return method;
            }
            return null;
        }

        pub fn summarizeBorrowEscapeRelation(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            function: ast.Function,
            generic_params: ?[]const ast.GenericParam,
            generic_args: ?[]const semantic_types.GenericArgument,
        ) SemaError!BorrowEscapeSummaryRelation {
            const allocator = context.allocator;
            _ = current_module;
            const ctx = try buildBorrowSummarySolveContext(context, allocator, path, program, function.module_name, globals, function, generic_params, generic_args);
            return try resolveBorrowSummaryRelation(ctx);
        }

        fn resolveMethodSummaryBindings(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            receiver_type: semantic_types.TypeId,
            method: ast.Function,
            explicit_type_args: []const ast.TypeName,
            args: []const ast.CallArg,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
        ) SemaError!?MethodSummaryBindings {
            if (method.type_params.len == 0) {
                if (lookup.findInstantiatedStructForCanonicalType(context, receiver_type)) |instantiated| {
                    return .{
                        .generic_params = instantiatedParams: {
                            const base_decl = lookup.findStructInModule(program, instantiated.module_name, instantiated.base_name) orelse break :instantiatedParams null;
                            break :instantiatedParams base_decl.type_params;
                        },
                        .generic_args = instantiated.type_args,
                        .owns_bindings = false,
                    };
                }
                return .{ .generic_params = null, .generic_args = null, .owns_bindings = false };
            }

            const method_args = if (explicit_type_args.len != 0)
                try resolveExplicitGenericArgs(context, path, program, current_module, method, explicit_type_args)
            else
                (try inferGenericArgsFromSummaryMethodCall(context, path, program, current_module, method, args, params, param_types)) orelse return null;
            errdefer context.allocator.free(method_args);

            if (lookup.findInstantiatedStructForCanonicalType(context, receiver_type)) |instantiated| {
                const base_decl = lookup.findStructInModule(program, instantiated.module_name, instantiated.base_name) orelse return null;
                const combined_params = try generics.combineGenericParams(SemaContext, context, path, base_decl.type_params, method.type_params);
                errdefer context.allocator.free(combined_params);
                const combined_args = try generics.combineGenericArgs(SemaContext, context, instantiated.type_args, method_args);
                errdefer context.allocator.free(combined_args);
                context.allocator.free(method_args);
                return .{
                    .generic_params = combined_params,
                    .generic_args = combined_args,
                    .owns_bindings = true,
                };
            }

            return .{
                .generic_params = method.type_params,
                .generic_args = method_args,
                .owns_bindings = true,
            };
        }

        fn inferGenericArgsFromSummaryMethodCall(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            method: ast.Function,
            args: []const ast.CallArg,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
        ) SemaError!?[]semantic_types.GenericArgument {
            const allocator = context.allocator;
            const inferred = try allocator.alloc(?semantic_types.GenericArgument, method.type_params.len);
            errdefer allocator.free(inferred);
            @memset(inferred, null);

            for (method.params[1..], args) |pattern_param, arg| {
                const actual = try exprSummaryType(context, path, program, current_module, arg.value, params, param_types) orelse return null;
                try unifyGenericBinding(context, path, program, method.module_name, pattern_param.type_name, actual, method.type_params, inferred);
            }

            var resolved = try allocator.alloc(semantic_types.GenericArgument, method.type_params.len);
            errdefer allocator.free(resolved);
            for (method.type_params, inferred, 0..) |param, maybe_ty, i| {
                const ty = maybe_ty orelse {
                    try context.diagnostic_context.emitToken(path, param.name_token, "generic method `{s}` requires explicit type arguments or inferrable arguments", .{method.name});
                    return SemaError.SemanticFailed;
                };
                resolved[i] = ty;
            }
            allocator.free(inferred);
            return resolved;
        }

        fn summarySliceViewCall(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            slice: ast.SliceRange,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
        ) SemaError!?ast.MethodCall {
            const object_type = (try exprSummaryType(context, path, program, current_module, slice.object, params, param_types)) orelse return null;
            if (type_resolution.typeSliceViewItemType(canonical.interContext(context), object_type) != null) return null;
            const writable = canonicalTypeKind(context, object_type) == .ref and !canonicalRefIsConst(context, object_type);
            const method = (try selectSliceViewMethod(context, path, program, current_module, object_type, writable, slice.token)) orelse return null;
            return .{ .object = slice.object, .method = method.name, .method_token = slice.token, .type_args = &.{}, .args = &.{} };
        }

        fn inferGenericArgsFromSummaryCall(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            function: ast.Function,
            explicit_type_args: []const ast.TypeName,
            args: []const ast.CallArg,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
        ) SemaError!?[]semantic_types.GenericArgument {
            if (explicit_type_args.len != 0) return try resolveExplicitGenericArgs(context, path, program, current_module, function, explicit_type_args);

            const allocator = context.allocator;
            const inferred = try allocator.alloc(?semantic_types.GenericArgument, function.type_params.len);
            defer allocator.free(inferred);
            @memset(inferred, null);

            for (function.params, args) |pattern_param, arg| {
                const actual = try exprSummaryType(context, path, program, current_module, arg.value, params, param_types) orelse return null;
                try unifyGenericBinding(context, path, program, function.module_name, pattern_param.type_name, actual, function.type_params, inferred);
            }

            var resolved = try allocator.alloc(semantic_types.GenericArgument, function.type_params.len);
            errdefer allocator.free(resolved);
            for (function.type_params, inferred, 0..) |param, maybe_ty, i| {
                const ty = maybe_ty orelse {
                    try context.diagnostic_context.emitToken(path, param.name_token, "generic function `{s}` requires explicit type arguments or inferrable arguments", .{function.name});
                    return SemaError.SemanticFailed;
                };
                resolved[i] = ty;
            }
            return resolved;
        }

        fn exprSummaryType(context: *SemaContext, path: []const u8, program: ast.Program, current_module: []const u8, expr: *ast.Expr, params: []const ast.Param, param_types: []const semantic_types.TypeId) SemaError!?semantic_types.TypeId {
            return switch (expr.*) {
                .unary => |unary| try exprSummaryType(context, path, program, current_module, unary.expr, params, param_types),
                .name => |name| blk: {
                    const index = findParamIndex(params, name.text) orelse break :blk null;
                    break :blk param_types[index];
                },
                .field => |field| blk: {
                    const object_ty = (try exprSummaryType(context, path, program, current_module, field.object, params, param_types)) orelse break :blk null;
                    const unwrapped_ref = if (canonicalTypeKind(context, object_ty) == .ref) canonicalRefTarget(context, object_ty) else object_ty;
                    const base_type_id = canonicalUnwrapOwned(context, unwrapped_ref);
                    const base_ty = base_type_id;
                    switch (canonicalTypeKind(context, base_type_id)) {
                        .@"struct" => {
                            const resolved = typeStructField(context, path, program, current_module, base_ty, field.field, field.field_token) catch break :blk null;
                            break :blk resolved.field_type_id;
                        },
                        .@"union" => {
                            const resolved = typeUnionPayloadField(context, path, program, current_module, base_ty, field.field, field.field_token) catch break :blk null;
                            break :blk resolved.field_type_id;
                        },
                        else => break :blk null,
                    }
                },
                .slice_range => |slice| blk: {
                    const object_ty = (try exprSummaryType(context, path, program, current_module, slice.object, params, param_types)) orelse break :blk null;
                    if (try summarySliceViewCall(context, path, program, current_module, slice, params, param_types)) |call| {
                        const decl = lookup.canonicalBaseStructDecl(context, program, object_ty) orelse break :blk null;
                        const method = protocols.findMethodInStruct(decl, call.method) orelse break :blk null;
                        const receiver_type = normalizedStructReceiverType(context, object_ty) orelse break :blk null;
                        const bindings = try resolveMethodSummaryBindings(context, path, program, current_module, receiver_type, method, &.{}, &.{}, params, param_types) orelse break :blk null;
                        defer bindings.deinit(context.allocator);
                        break :blk try parseTypeWithBindings(context, path, program, method.module_name, method.return_type.?, null, bindings.generic_params orelse &.{}, bindings.generic_args orelse &.{});
                    }
                    const item_type_id = type_resolution.typeSliceViewItemType(canonical.interContext(context), object_ty) orelse break :blk null;
                    break :blk try canonical.sliceType(context, item_type_id, false);
                },
                .index => |index| blk: {
                    const object_ty = (try exprSummaryType(context, path, program, current_module, index.object, params, param_types)) orelse break :blk null;
                    const item_ty = if (canonicalTypeKind(context, object_ty) == .slice)
                        canonicalTypeNode(context, object_ty).slice.item
                    else if (try type_resolution.typeIndexAccessRole(canonical.interContext(context), object_ty)) |role|
                        role.value_type_id
                    else
                        break :blk null;
                    break :blk item_ty;
                },
                .cast => |cast| try exprSummaryType(context, path, program, current_module, cast.subject, params, param_types),
                .method_call => |call| blk: {
                    const object_ty = (try exprSummaryType(context, path, program, current_module, call.object, params, param_types)) orelse break :blk null;
                    if (call.args.len == 0 and call.type_args.len == 0) {
                        if (type_resolution.intrinsicReceiverForType(canonical.interContext(context), object_ty)) |receiver| {
                            if (intrinsics.resolveMethod(receiver, call.method)) |intrinsic_id| {
                                switch (intrinsic_id) {
                                    .string_len, .sequence_len, .sparse_len, .slice_len => break :blk try canonical.integerType(context, "usize"),
                                    .string_is_empty => break :blk try canonical.primitiveType(context, .bool),
                                    .string_bytes => break :blk try canonical.sliceType(context, try canonical.integerType(context, "u8"), true),
                                    else => {},
                                }
                            }
                        }
                    }
                    break :blk null;
                },
                else => null,
            };
        }
        pub fn borrowOriginToken(local: LocalBinding) ?lexer.Token {
            if (local.projection_origin) |origin| return ast.firstExprToken(origin);
            return local.declaration_token;
        }

        pub fn emitUnavailableLocal(
            context: *SemaContext,
            path: []const u8,
            token: lexer.Token,
            local: LocalBinding,
            already: bool,
        ) SemaError!void {
            const related = local.unavailable_at orelse local.declaration_token;
            const related_message = if (local.unavailable_at != null) "value became unavailable here" else "value declared here";
            if (already) {
                try emitOwnershipDiagnostic(
                    context,
                    path,
                    token,
                    .ownership_cleanup,
                    related,
                    related_message,
                    "ownership was transferred or the value was explicitly dropped",
                    "use the value before transfer, or copy it when copying is supported",
                    "local `{s}` was already handed off or dropped",
                    .{local.name},
                );
            } else {
                try emitOwnershipDiagnostic(
                    context,
                    path,
                    token,
                    .ownership_use_after_transfer,
                    related,
                    related_message,
                    "ownership was transferred or the value was explicitly dropped",
                    "use the value before transfer, or copy it when copying is supported",
                    "local `{s}` was handed off or dropped",
                    .{local.name},
                );
            }
        }

        pub fn emitScopedAllocEscape(
            context: *SemaContext,
            path: []const u8,
            token: lexer.Token,
            origin: ?lexer.Token,
            action: []const u8,
        ) SemaError!void {
            try emitOwnershipDiagnostic(
                context,
                path,
                token,
                .ownership_scoped_escape,
                origin,
                "scoped value originates here",
                "the value depends on storage released when this allocator block exits",
                "copy out plain data or keep the value inside the scoped allocator block",
                "scoped allocator values cannot escape the block via {s}",
                .{action},
            );
        }

        pub fn emitCallBorrowEscape(
            context: *SemaContext,
            path: []const u8,
            locals: []const LocalBinding,
            token: lexer.Token,
            provenance: Provenance,
        ) SemaError!void {
            try emitOwnershipDiagnostic(
                context,
                path,
                token,
                .ownership_borrow_escape,
                provenanceRootToken(locals, provenance),
                "borrowed argument is rooted here",
                "the callee summary says this argument can reach longer-lived state",
                "pass owned data or use a callee that does not retain this argument",
                "borrowed values cannot escape via function call side effects",
                .{},
            );
        }

        pub fn rejectScopedAllocCallEscape(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            locals: []const LocalBinding,
            expr: *ast.Expr,
            expected: semantic_types.TypeId,
            action: []const u8,
        ) SemaError!void {
            if (context.function_state.scoped_alloc_depth == 0) return;
            if (canonicalTypeKind(context, expected) == .ref or canonicalTypeKind(context, expected) == .raw) return;
            if (!try exprCarriesScopedAllocAs(context, path, program, locals, expr, expected)) return;
            try emitScopedAllocEscape(context, path, ast.firstExprToken(expr), null, action);
            return SemaError.SemanticFailed;
        }

        pub fn rejectScopedAllocMutationEscape(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            target_expr: *ast.Expr,
            value_expr: *ast.Expr,
            value_type: semantic_types.TypeId,
            action: []const u8,
        ) SemaError!void {
            if (context.function_state.scoped_alloc_depth == 0) return;
            if (!try exprCarriesScopedAllocAs(context, path, program, locals, value_expr, value_type)) return;
            if (!targetIsOuterState(context, program, current_module, globals, locals, target_expr)) return;
            try emitScopedAllocEscape(context, path, ast.firstExprToken(value_expr), null, action);
            return SemaError.SemanticFailed;
        }

        fn targetIsOuterState(
            context: *SemaContext,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
        ) bool {
            const region_depth = scopedAllocRegionDepth(context);
            return switch (expr.*) {
                .name => |name| blk: {
                    if (findLocal(locals, name.text)) |local| {
                        break :blk local.scope_depth < region_depth;
                    }
                    break :blk findGlobal(context, program, globals, current_module, name.text) != null;
                },
                .field => |field| targetIsOuterState(context, program, current_module, globals, locals, field.object),
                .index => |index| targetIsOuterState(context, program, current_module, globals, locals, index.object),
                .asm_expr => false,
                else => false,
            };
        }

        fn scopedAllocRegionDepth(
            context: *SemaContext,
        ) usize {
            return context.function_state.scoped_alloc_region_depth orelse context.function_state.block_depth;
        }

        pub fn exprCarriesScopedAlloc(locals: []const LocalBinding, expr: *ast.Expr) bool {
            return switch (expr.*) {
                .@"switch" => true,
                .string, .interpolated_string => true,
                .rune => false,
                .name => |name| blk: {
                    const local = findLocal(locals, name.text) orelse break :blk false;
                    break :blk local.is_scoped_alloc_value;
                },
                .unary => |unary| exprCarriesScopedAlloc(locals, unary.expr),
                .binary => |binary| exprCarriesScopedAlloc(locals, binary.left) or exprCarriesScopedAlloc(locals, binary.right),
                .cast => |cast| exprCarriesScopedAlloc(locals, cast.subject),
                .@"try" => |try_expr| exprCarriesScopedAlloc(locals, try_expr.expr),
                .is_test => |is_test| exprCarriesScopedAlloc(locals, is_test.subject),
                .deref => |deref| exprCarriesScopedAlloc(locals, deref.expr),
                .field => |field| exprCarriesScopedAlloc(locals, field.object),
                .index => |index| exprCarriesScopedAlloc(locals, index.object) or exprCarriesScopedAlloc(locals, index.index),
                .slice_range => |slice| exprCarriesScopedAlloc(locals, slice.object) or (if (slice.start) |start| exprCarriesScopedAlloc(locals, start) else false) or (if (slice.end) |end| exprCarriesScopedAlloc(locals, end) else false),
                .union_case => |case| if (case.value) |value| exprCarriesScopedAlloc(locals, value) else false,
                .array_literal => |literal| blk: {
                    for (literal.items) |item| {
                        if (exprCarriesScopedAlloc(locals, item)) break :blk true;
                    }
                    break :blk false;
                },
                .sequence_repeat => |repeat| blk: {
                    if (exprCarriesScopedAlloc(locals, repeat.count)) break :blk true;
                    for (repeat.items) |item| {
                        if (exprCarriesScopedAlloc(locals, item)) break :blk true;
                    }
                    break :blk false;
                },
                .typed_sequence_literal => |literal| blk: {
                    for (literal.items) |item| {
                        if (exprCarriesScopedAlloc(locals, item)) break :blk true;
                    }
                    break :blk false;
                },
                .fixed_array_construct => |construct| blk: {
                    for (construct.items) |item| {
                        if (exprCarriesScopedAlloc(locals, item)) break :blk true;
                    }
                    break :blk false;
                },
                .new_array, .new_sparse => true,
                .new_owned => |literal| blk: {
                    for (literal.fields) |field| {
                        if (exprCarriesScopedAlloc(locals, field.value)) break :blk true;
                    }
                    break :blk false;
                },
                .struct_literal => |literal| blk: {
                    for (literal.fields) |field| {
                        if (exprCarriesScopedAlloc(locals, field.value)) break :blk true;
                    }
                    break :blk false;
                },
                .keyed_literal => |literal| blk: {
                    for (literal.entries) |entry| {
                        if (exprCarriesScopedAlloc(locals, entry.key) or exprCarriesScopedAlloc(locals, entry.value)) break :blk true;
                    }
                    break :blk false;
                },
                .asm_expr => |asm_expr| blk: {
                    if (asm_expr.inout) |inout| {
                        if (exprCarriesScopedAlloc(locals, inout.value)) break :blk true;
                    }
                    for (asm_expr.inputs) |input| {
                        if (exprCarriesScopedAlloc(locals, input.value)) break :blk true;
                    }
                    break :blk false;
                },
                .call => |call| blk: {
                    for (call.args) |arg| {
                        if (exprCarriesScopedAlloc(locals, arg.value)) break :blk true;
                    }
                    break :blk false;
                },
                .method_call => |call| blk: {
                    if (exprCarriesScopedAlloc(locals, call.object)) break :blk true;
                    for (call.args) |arg| {
                        if (exprCarriesScopedAlloc(locals, arg.value)) break :blk true;
                    }
                    break :blk false;
                },
                .int, .float, .@"comptime", .bool, .none, .address_of, .function_expr, .enum_case => false,
            };
        }

        pub fn exprCarriesScopedAllocAs(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            locals: []const LocalBinding,
            expr: *ast.Expr,
            ty: semantic_types.TypeId,
        ) SemaError!bool {
            if (!try canonicalTypeMayCaptureAllocator(context, path, program, ty)) return false;
            if (try scopedAllocProjectionOrigin(locals, expr)) |origin| {
                return exprCarriesScopedAllocAs(context, path, program, locals, origin, ty);
            }
            return exprCarriesScopedAlloc(locals, expr);
        }

        fn resolvedScopedAllocProjectionBase(locals: []const LocalBinding, expr: *ast.Expr) SemaError!*ast.Expr {
            return if (try scopedAllocProjectionOrigin(locals, expr)) |origin|
                origin
            else
                expr;
        }

        fn scopedAllocProjectionOrigin(locals: []const LocalBinding, expr: *ast.Expr) SemaError!?*ast.Expr {
            return switch (expr.*) {
                .name => |name| blk: {
                    const local = findLocal(locals, name.text) orelse break :blk null;
                    if (local.is_mutable) break :blk null;
                    break :blk local.scoped_alloc_origin;
                },
                .field => |field| blk: {
                    const base = try resolvedScopedAllocProjectionBase(locals, field.object);
                    break :blk switch (base.*) {
                        .struct_literal => |literal| if (findLiteralField(literal.fields, field.field)) |literal_field| literal_field.value else null,
                        .new_owned => |literal| if (findLiteralField(literal.fields, field.field)) |literal_field| literal_field.value else null,
                        else => null,
                    };
                },
                .index => |index| blk: {
                    const base = try resolvedScopedAllocProjectionBase(locals, index.object);
                    const item_index = switch (index.index.*) {
                        .int => |literal| blk_index: {
                            if (literal.value < 0) break :blk null;
                            break :blk_index @as(usize, @intCast(literal.value));
                        },
                        else => break :blk null,
                    };
                    break :blk switch (base.*) {
                        .array_literal => |literal| if (item_index < literal.items.len) literal.items[item_index] else null,
                        .typed_sequence_literal => |literal| if (item_index < literal.items.len) literal.items[item_index] else null,
                        .fixed_array_construct => |literal| if (item_index < literal.items.len) literal.items[item_index] else null,
                        else => null,
                    };
                },
                else => null,
            };
        }

        pub fn lowerImplicitHandoff(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            locals: []const LocalBinding,
            expr: *ast.Expr,
            expected_type_id: semantic_types.TypeId,
            out: *sir.Expr,
        ) SemaError!void {
            if (expr.* != .name) return;
            if (!try canonicalTypeIsOwnedValue(context, path, program, expected_type_id)) return;
            const name = expr.name;
            const local = findPlaceLocal(locals, name.text) orelse {
                try context.diagnostic_context.emitToken(path, name.token, "unknown local `{s}`", .{name.text});
                return SemaError.SemanticFailed;
            };
            if (local.is_unavailable) {
                try emitUnavailableLocal(context, path, name.token, local, false);
                return SemaError.SemanticFailed;
            }
            if (local.is_for_binding) {
                try context.diagnostic_context.emitToken(path, name.token, "cannot hand off for-loop binding `{s}`; clone it explicitly when supported", .{name.text});
                return SemaError.SemanticFailed;
            }
            if (local.kind(context) == .ref) {
                try context.diagnostic_context.emitToken(path, name.token, "cannot hand off an alias because it does not own the referenced value; hand off or clone the owner instead", .{});
                return SemaError.SemanticFailed;
            }
            out.* = .{ .handoff_local = name.text };
            const metadata = semanticExprMetadata(context, out) orelse return error.SemanticFailed;
            try recordExprMetadata(context, out, .{
                .type_id = metadata.type_id,
                .semantics = .{
                    .category = .value,
                    .ownership = metadata.semantics.ownership,
                    .cleanup = .transferred,
                },
                .consumption = .{
                    .sink = metadata.consumption.sink,
                    .transfer = .move,
                },
                .intrinsic_id = metadata.intrinsic_id,
                // The handoff replaces a resolved local read in place, so it keeps the
                // checked identity of the binding whose ownership it transfers.
                .checked_place_root = metadata.checked_place_root,
                .checked_place_projections = metadata.checked_place_projections,
                .non_owning_place_origin = metadata.non_owning_place_origin,
            });
        }

        pub fn rejectProjectedResourceTransferForTypedValue(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            token: lexer.Token,
            value: TypedExpr,
            expected_type_id: semantic_types.TypeId,
            action: []const u8,
        ) SemaError!void {
            // Current conservative sink gate for projected resource transfer.
            // Live callers cover binding, assignment, return, and resource-typed
            // call-argument sinks; keeping those paths unified here avoids drifting
            // back toward older AST-shape-specific rejection behavior.
            if (!try canonicalTypeIsOwnedValue(context, path, program, expected_type_id)) return;
            if (value.value_semantics.category != .borrowed_projection) return;
            try emitOwnershipDiagnostic(
                context,
                path,
                token,
                .ownership_invalidation,
                null,
                "",
                "a projected value borrows storage owned by its containing place",
                "use `[..]` for a view borrow, `.clone()` when supported, or `take` where the place is detachable",
                "cannot hand off a projected owned value via {s}; use `[..]` for a slice/view borrow, `.clone()` when supported, or `take` where the projected place is detachable",
                .{action},
            );
            return SemaError.SemanticFailed;
        }

        pub fn markLocalHandedOff(context: *SemaContext, path: []const u8, locals: []LocalBinding, name: ast.Name) SemaError!void {
            const index = findLocalIndex(locals, name.text) orelse {
                try context.diagnostic_context.emitToken(path, name.token, "unknown local `{s}`", .{name.text});
                return SemaError.SemanticFailed;
            };
            if (locals[index].is_unavailable) {
                try emitUnavailableLocal(context, path, name.token, locals[index], true);
                return SemaError.SemanticFailed;
            }
            if (locals[index].deferred_handoff_depth != null) {
                try context.diagnostic_context.emitToken(path, name.token, "local `{s}` is reserved for a deferred handoff", .{name.text});
                return SemaError.SemanticFailed;
            }
            if (locals[index].is_for_binding) {
                try context.diagnostic_context.emitToken(path, name.token, "cannot hand off for-loop binding `{s}`; clone it explicitly when supported", .{name.text});
                return SemaError.SemanticFailed;
            }
            if (locals[index].binding_mode == .projected) {
                try context.diagnostic_context.emitToken(path, name.token, "cannot hand off projected local `{s}`; its owner retains cleanup responsibility", .{name.text});
                return SemaError.SemanticFailed;
            }
            try rejectLiveBorrowInvalidation(context, path, locals, name.text, name.token, "hand off");
            locals[index].is_unavailable = true;
            locals[index].unavailable_at = name.token;
        }

        pub fn markCheckedNamedHandoff(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            locals: []LocalBinding,
            source: *ast.Expr,
            lowered: *const sir.Expr,
            expected_type_id: semantic_types.TypeId,
        ) SemaError!void {
            if (source.* != .name or !try canonicalTypeIsOwnedValue(context, path, program, expected_type_id)) return;

            const metadata = semanticExprMetadata(context, lowered) orelse return error.SemanticFailed;
            const record = metadata.checked_effect orelse return error.SemanticFailed;
            if (lowered.* != .handoff_local or record.effect != .move or
                record.effect.move.source != .place) return error.SemanticFailed;
            const place = record.effect.move.source.place;
            if (place.root != .binding or place.projections != null or place.non_owning)
                return error.SemanticFailed;
            const index = findLocalIndex(locals, source.name.text) orelse return error.SemanticFailed;
            if (locals[index].binding_id != place.root.binding) return error.SemanticFailed;
            try markLocalHandedOff(context, path, locals, source.name);
        }

        pub fn expectMutableReceiver(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
            object_type: semantic_types.TypeId,
            container_name: []const u8,
        ) SemaError!void {
            // A projected carrier can preserve its own shallow access capability even
            // when the aggregate containing that carrier is read-only.
            const object_node = canonicalTypeNode(context, object_type).*;
            if (object_node == .ref_ and !object_node.ref_.is_const) return;
            if (object_node == .slice and !object_node.slice.is_const) return;
            if (resolvePlace(context, program, current_module, globals, locals, expr)) |place| {
                if (place.access.allowsMutation()) return;
                if (expr.* == .name) {
                    if (findLocal(locals, place.root_name)) |binding| {
                        if (binding.kind(context) == .ref) {
                            try context.diagnostic_context.emitToken(path, place.root_token, "cannot mutate through read-only alias `{s}`", .{place.root_name});
                        } else if (binding.kind(context) == .slice) {
                            try context.diagnostic_context.emitToken(path, place.root_token, "cannot mutate through read-only slice `{s}`", .{place.root_name});
                        } else {
                            try context.diagnostic_context.emitToken(path, place.root_token, "cannot mutate const {s} `{s}`", .{ container_name, place.root_name });
                        }
                    } else {
                        try context.diagnostic_context.emitToken(path, place.root_token, "cannot mutate const {s} `{s}`", .{ container_name, place.root_name });
                    }
                } else {
                    try context.diagnostic_context.emitToken(path, ast.firstExprToken(expr), "cannot mutate through read-only {s} receiver", .{container_name});
                }
                return SemaError.SemanticFailed;
            }

            // A non-place value may be borrowed for the duration of a receiver call;
            // it has no source-visible storage identity to mutate afterwards. A shape
            // that claims to be a place but cannot be resolved is instead rejected.
            switch (expr.*) {
                .name, .field, .index, .deref, .address_of => {
                    try context.diagnostic_context.emitToken(path, ast.firstExprToken(expr), "cannot resolve writable {s} receiver place", .{container_name});
                    return SemaError.SemanticFailed;
                },
                else => return,
            }
        }

        pub fn expectMutablePlaceRoot(context: *SemaContext, path: []const u8, program: ast.Program, current_module: []const u8, globals: []const GlobalBinding, locals: []const LocalBinding, expr: *ast.Expr, object_type: semantic_types.TypeId, place_name: []const u8) SemaError!void {
            if (canonicalTypeNode(context, object_type).* == .slice and !canonicalSliceIsConst(context, object_type)) return;
            const place = resolvePlace(context, program, current_module, globals, locals, expr) orelse {
                try context.diagnostic_context.emitToken(path, ast.firstExprToken(expr), "cannot resolve writable {s}", .{place_name});
                return SemaError.SemanticFailed;
            };
            if (place.access.allowsMutation()) return;
            if (findLocal(locals, place.root_name)) |binding| {
                if (binding.kind(context) == .ref) {
                    try context.diagnostic_context.emitToken(path, place.root_token, "cannot mutate read-only alias `{s}`", .{place.root_name});
                } else if (binding.kind(context) == .slice) {
                    try context.diagnostic_context.emitToken(path, place.root_token, "cannot mutate read-only slice `{s}`", .{place.root_name});
                } else {
                    try context.diagnostic_context.emitToken(path, place.root_token, "cannot mutate const {s} `{s}`", .{ place_name, place.root_name });
                }
            } else {
                try context.diagnostic_context.emitToken(path, place.root_token, "cannot mutate const {s} `{s}`", .{ place_name, place.root_name });
            }
            return SemaError.SemanticFailed;
        }

        fn rawPointeeAccess(context: *SemaContext, type_id: semantic_types.TypeId) ?Access {
            const base_type = canonicalUnwrapOwned(context, if (canonicalTypeKind(context, type_id) == .ref)
                canonicalRefTarget(context, type_id)
            else
                type_id);
            const node = canonicalTypeNode(context, base_type).*;
            if (node != .raw) return null;
            return if (node.raw.is_const) .read_only else .writable;
        }

        fn findPlaceLocal(locals: []const LocalBinding, name: []const u8) ?LocalBinding {
            var index = locals.len;
            while (index > 0) {
                index -= 1;
                if (std.mem.eql(u8, locals[index].name, name)) return locals[index];
            }
            return null;
        }

        pub fn resolvePlace(
            context: *const SemaContext,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
        ) ?ResolvedPlace {
            // canonical type queries currently require the mutable context pointer,
            // while place resolution itself does not mutate semantic state.
            const mutable_context: *SemaContext = @constCast(context);
            const root_name = placeRootName(expr) orelse return null;
            const has_deref = exprPathContainsDeref(expr);
            const projection = placeProjectionPathFromExpr(expr);

            if (findPlaceLocal(locals, root_name.text)) |local| {
                if (has_deref) {
                    if (rawPointeeAccess(mutable_context, local.type_id)) |access| {
                        return .{
                            .root_kind = .raw_pointee,
                            .root_name = root_name.text,
                            .root_binding_id = local.binding_id,
                            .root_token = root_name.token,
                            .root_type_id = local.type_id,
                            .access = access,
                            // Raw pointers carry no safe borrow identity. The pointer
                            // binding is not the storage reached by dereferencing it.
                            .roots = .none(),
                            .projection = projection,
                            .addressability = .raw_pointee,
                        };
                    }
                }
                return .{
                    .root_kind = if (local.is_param) .parameter else .local,
                    .root_name = root_name.text,
                    .root_binding_id = local.binding_id,
                    .root_token = root_name.token,
                    .root_type_id = local.type_id,
                    .access = placeRootAccess(mutable_context, local, expr),
                    .roots = if (local.is_param)
                        NormalizedBorrowRoots.paramOwnerValue(root_name.text)
                    else
                        NormalizedBorrowRoots.localValue(root_name.text),
                    .projection = projection,
                    .addressability = if (projection.step_count == 0) .root else .projected_candidate,
                };
            }

            if (findGlobal(context, program, globals, current_module, root_name.text)) |global| {
                if (has_deref) {
                    if (rawPointeeAccess(mutable_context, global.type_id)) |access| {
                        return .{
                            .root_kind = .raw_pointee,
                            .root_name = root_name.text,
                            .root_global_id = global.id,
                            .root_token = root_name.token,
                            .root_type_id = global.type_id,
                            .access = access,
                            .roots = .none(),
                            .projection = projection,
                            .addressability = .raw_pointee,
                        };
                    }
                }
                return .{
                    .root_kind = .global,
                    .root_name = root_name.text,
                    .root_global_id = global.id,
                    .root_token = root_name.token,
                    .root_type_id = global.type_id,
                    .access = if (global.is_mutable) .writable else .read_only,
                    .roots = NormalizedBorrowRoots.globalValue(root_name.text),
                    .projection = projection,
                    .addressability = if (projection.step_count == 0) .root else .projected_candidate,
                };
            }

            return null;
        }

        fn localPlaceAccess(context: *SemaContext, local: LocalBinding) Access {
            if (local.kind(context) == .ref) {
                return if (canonicalRefIsConst(context, local.type_id)) .read_only else .writable;
            }
            if (local.kind(context) == .slice) {
                return if (canonicalSliceIsConst(context, local.type_id)) .read_only else .writable;
            }
            return if (local.is_mutable or local.is_param) .writable else .read_only;
        }

        fn placeRootAccess(context: *SemaContext, local: LocalBinding, expr: *ast.Expr) Access {
            if (exprPathContainsDeref(expr)) {
                const base_type = canonicalUnwrapOwned(context, if (local.kind(context) == .ref)
                    canonicalRefTarget(context, local.type_id)
                else
                    local.type_id);
                if (canonicalTypeNode(context, base_type).* == .raw) {
                    return if (canonicalTypeNode(context, base_type).raw.is_const) .read_only else .writable;
                }
            }
            return localPlaceAccess(context, local);
        }

        pub fn queryPlaceRootBindings(
            context: *const SemaContext,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
        ) NormalizedBorrowRoots {
            const place = resolvePlace(context, program, current_module, globals, locals, expr) orelse
                return .none();
            return place.roots;
        }

        fn findLocalIndex(locals: []const LocalBinding, needle: []const u8) ?usize {
            for (locals, 0..) |local, i| {
                if (std.mem.eql(u8, local.name, needle)) return i;
            }
            return null;
        }

        pub fn querySummaryPlaceRootBindings(
            context: *const SemaContext,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            params: []const ast.Param,
            expr: *ast.Expr,
        ) NormalizedBorrowRoots {
            var query = BorrowRootQuery.init();
            const base = projectionBaseExpr(expr);
            switch (base.*) {
                .name => |name| {
                    if (findParamIndex(params, name.text) != null) {
                        query.markParamOwner(name.text);
                        return query.roots;
                    }
                    if (findGlobal(context, program, globals, current_module, name.text) != null) {
                        query.markGlobal(name.text);
                    }
                },
                else => {},
            }
            return query.roots;
        }

        pub fn queryViewSourceBorrowRoots(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
        ) SemaError!BorrowRootQuery {
            var query = BorrowRootQuery.init();
            const base = normalizedBorrowRootSourceExpr(expr);
            switch (base.*) {
                .string => query.markStatic(),
                .name => |name| {
                    if (findLocal(locals, name.text)) |local| {
                        const class = try ownershipClass(context, path, program, current_module, try local.canonicalTypeId(context));
                        if (local.is_param) {
                            if (class == .borrowed)
                                query.markParam(name.text)
                            else
                                query.markParamOwner(name.text);
                        } else {
                            query.markLocal(name.text);
                        }
                    } else if (findGlobal(context, program, globals, current_module, name.text) != null) {
                        query.markGlobal(name.text);
                    } else {
                        query.markTemporary();
                    }
                },
                else => query.markTemporary(),
            }
            return query;
        }

        pub fn placeRootProvenance(
            context: *const SemaContext,
            _: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
        ) Provenance {
            return Provenance.fromNormalizedBorrowRoots(queryPlaceRootBindings(context, program, current_module, globals, locals, expr));
        }

        fn referentScopeDepthFromProvenance(locals: []const LocalBinding, provenance: Provenance) ?usize {
            const roots = provenance.toNormalizedBorrowRoots();
            if (roots.contains_static or roots.contains_global or roots.contains_param or roots.contains_param_owner) return 0;
            if (!roots.precise_local_roots) return 0;
            if (roots.local_root_count == 0) return null;

            var best: ?usize = null;
            var i: usize = 0;
            while (i < roots.local_root_count) : (i += 1) {
                const root_name = roots.local_roots[i] orelse continue;
                const root = findLocal(locals, root_name) orelse return 0;
                if (best == null or root.scope_depth < best.?) best = root.scope_depth;
            }
            return best;
        }

        fn mutationTargetScopeDepth(
            context: *SemaContext,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
        ) ?usize {
            return switch (expr.*) {
                .name => |name| blk: {
                    if (findLocal(locals, name.text)) |local| {
                        if (local.kind(context) == .ref) break :blk referentScopeDepthFromProvenance(locals, local.provenance) orelse 0;
                        break :blk local.scope_depth;
                    }
                    if (findGlobal(context, program, globals, current_module, name.text) != null) break :blk 0;
                    break :blk null;
                },
                .field => |field| mutationTargetScopeDepth(context, program, current_module, globals, locals, field.object),
                .index => |index| mutationTargetScopeDepth(context, program, current_module, globals, locals, index.object),
                .asm_expr => null,
                else => null,
            };
        }

        pub fn emitOwnershipDiagnostic(
            context: *SemaContext,
            path: []const u8,
            token: lexer.Token,
            code: diagnostics.DiagnosticCode,
            related_token: ?lexer.Token,
            related_message: []const u8,
            note: ?[]const u8,
            help: ?[]const u8,
            comptime fmt: []const u8,
            args: anytype,
        ) SemaError!void {
            var labels: [1]diagnostics.Label = undefined;
            const label_slice: []const diagnostics.Label = if (related_token) |related| blk: {
                labels[0] = .{
                    .span = diagnostics.SourceSpan.fromToken(path, related),
                    .message = related_message,
                };
                break :blk &labels;
            } else &.{};
            const notes: []const []const u8 = if (note) |text| &.{text} else &.{};
            try context.diagnostic_context.emitTokenWith(path, token, .{
                .code = code,
                .labels = label_slice,
                .notes = notes,
                .help = help,
            }, fmt, args);
        }

        pub fn mutationTargetEscapeTarget(
            context: *SemaContext,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
        ) ?EscapeTarget {
            return switch (expr.*) {
                .name => |name| blk: {
                    if (findLocal(locals, name.text)) |local| {
                        if (local.kind(context) == .ref) break :blk .{ .scope = referentScopeDepthFromProvenance(locals, local.provenance) orelse 0 };
                        break :blk .{ .scope = local.scope_depth };
                    }
                    if (findGlobal(context, program, globals, current_module, name.text) != null) break :blk .global;
                    break :blk null;
                },
                .field => |field| mutationTargetEscapeTarget(context, program, current_module, globals, locals, field.object),
                .index => |index| mutationTargetEscapeTarget(context, program, current_module, globals, locals, index.object),
                .asm_expr => null,
                else => null,
            };
        }

        pub fn rejectBorrowedProvenanceReturnEscape(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            locals: []const LocalBinding,
            token: lexer.Token,
            value: TypedExpr,
            return_type: semantic_types.TypeId,
        ) SemaError!void {
            if (!try typeMayCarryBorrowedProvenance(context, path, program, current_module, return_type)) return;
            if (!value.provenance.hasBorrow()) return;
            if (provenanceCanEscapeReturn(context, locals, value.provenance)) return;
            try emitOwnershipDiagnostic(
                context,
                path,
                token,
                .ownership_borrow_escape,
                provenanceRootToken(locals, value.provenance),
                "borrowed value is rooted here",
                "the returned value may retain this borrow",
                "return owned data or borrow from an allowed caller-owned root",
                "borrowed values cannot escape the function via return",
                .{},
            );
            return SemaError.SemanticFailed;
        }

        pub fn rejectBorrowedProvenanceAssignmentEscape(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            locals: []const LocalBinding,
            token: lexer.Token,
            value: TypedExpr,
            target_type: semantic_types.TypeId,
            target_scope_depth: usize,
        ) SemaError!void {
            if (!try typeMayCarryBorrowedProvenance(context, path, program, current_module, target_type)) return;
            if (!value.provenance.hasBorrow()) return;
            if (provenanceOutlivesTarget(locals, value.provenance, .{ .scope = target_scope_depth })) return;
            try emitOwnershipDiagnostic(
                context,
                path,
                token,
                .ownership_borrow_escape,
                provenanceRootToken(locals, value.provenance),
                "borrowed value is rooted here",
                "the assignment target outlives this borrow",
                "store an owned value or shorten the target lifetime",
                "borrowed values cannot escape into longer-lived assignment targets",
                .{},
            );
            return SemaError.SemanticFailed;
        }

        pub fn rejectBorrowedProvenanceMutationEscape(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            target_expr: *ast.Expr,
            value: TypedExpr,
            value_type: semantic_types.TypeId,
            token: lexer.Token,
            action: []const u8,
        ) SemaError!void {
            if (!try typeMayCarryBorrowedProvenance(context, path, program, current_module, value_type)) return;
            if (!value.provenance.hasBorrow()) return;
            const target = mutationTargetEscapeTarget(context, program, current_module, globals, locals, target_expr) orelse return;
            if (provenanceOutlivesTarget(locals, value.provenance, target)) return;
            try emitOwnershipDiagnostic(
                context,
                path,
                token,
                .ownership_borrow_escape,
                provenanceRootToken(locals, value.provenance),
                "borrowed value is rooted here",
                "the mutated state may outlive this borrow",
                "store an owned value or keep the mutation within the borrow lifetime",
                "borrowed values cannot escape into longer-lived state via {s}",
                .{action},
            );
            return SemaError.SemanticFailed;
        }

        fn preciseRootNamesOverlap(comptime max_roots: usize, a: [max_roots]?[]const u8, a_count: u8, b: [max_roots]?[]const u8, b_count: u8) bool {
            var i: usize = 0;
            while (i < a_count) : (i += 1) {
                const a_name = a[i] orelse continue;
                var j: usize = 0;
                while (j < b_count) : (j += 1) {
                    if (optionalEql(a_name, b[j])) return true;
                }
            }
            return false;
        }

        pub fn normalizedBindingRootsOverlap(a: NormalizedBorrowRoots, b: NormalizedBorrowRoots) bool {
            if (a.contains_global and b.contains_global) {
                if (a.global_name == null or b.global_name == null) return true;
                if (optionalEql(a.global_name, b.global_name)) return true;
            }
            if (a.contains_param and b.contains_param) {
                if (!a.precise_param_roots or !b.precise_param_roots) return true;
                if (preciseRootNamesOverlap(
                    NormalizedBorrowRoots.max_precise_param_roots,
                    a.param_roots,
                    a.param_root_count,
                    b.param_roots,
                    b.param_root_count,
                )) return true;
            }
            if (a.contains_param_owner and b.contains_param_owner) {
                if (!a.precise_param_owner_roots or !b.precise_param_owner_roots) return true;
                if (preciseRootNamesOverlap(
                    NormalizedBorrowRoots.max_precise_param_roots,
                    a.param_owner_roots,
                    a.param_owner_root_count,
                    b.param_owner_roots,
                    b.param_owner_root_count,
                )) return true;
            }
            if (a.contains_local and b.contains_local) {
                if (!a.precise_local_roots or !b.precise_local_roots) return true;
                if (preciseRootNamesOverlap(
                    NormalizedBorrowRoots.max_precise_local_roots,
                    a.local_roots,
                    a.local_root_count,
                    b.local_roots,
                    b.local_root_count,
                )) return true;
            }
            return false;
        }

        fn projectionStepsOverlap(a: PlaceProjectionStep, b: PlaceProjectionStep) bool {
            return switch (a) {
                .field => |a_field| switch (b) {
                    .field => |b_field| std.mem.eql(u8, a_field, b_field),
                    else => false,
                },
                .index => |a_index| switch (b) {
                    .index => |b_index| if (a_index != null and b_index != null)
                        a_index.? == b_index.?
                    else
                        true,
                    .container => true,
                    else => false,
                },
                .container => switch (b) {
                    .index => true,
                    .container => true,
                    else => false,
                },
            };
        }

        pub fn pathOverlapsMutation(alias_path: PlaceProjectionPath, mutation_path: PlaceProjectionPath) bool {
            if (!alias_path.has_root or !mutation_path.has_root) return false;
            if (alias_path.step_count == 0) return true;
            // Truncated paths are an intentional widening point: once precise path
            // identity is lost, overlap must stay conservative.
            if (alias_path.truncated or mutation_path.truncated) return true;

            const shared_len: usize = @min(alias_path.step_count, mutation_path.step_count);
            var i: usize = 0;
            while (i < shared_len) : (i += 1) {
                if (!projectionStepsOverlap(alias_path.stepAt(i), mutation_path.stepAt(i))) return false;
            }
            return true;
        }

        pub fn pathInvalidatesView(view_path: PlaceProjectionPath, mutation_path: PlaceProjectionPath) bool {
            if (!view_path.has_root or !mutation_path.has_root) return false;
            // Truncated paths are an intentional widening point for view invalidation
            // as well.
            if (view_path.truncated or mutation_path.truncated) return true;

            const shared_len: usize = @min(view_path.step_count, mutation_path.step_count);
            var i: usize = 0;
            while (i < shared_len) : (i += 1) {
                if (!projectionStepsOverlap(view_path.stepAt(i), mutation_path.stepAt(i))) return false;
            }

            if (mutation_path.step_count <= view_path.step_count) return true;
            if (mutation_path.stepAt(view_path.step_count) == .container) return true;
            return false;
        }

        fn borrowConflictsWithMutation(borrowed_place: BorrowedPlaceDependency, target_roots: NormalizedBorrowRoots, target_projection: PlaceProjectionPath) bool {
            if (!borrowed_place.hasBorrow()) return false;
            if (!normalizedBindingRootsOverlap(borrowed_place.roots, target_roots)) return false;
            return switch (borrowed_place.mode) {
                .alias => pathOverlapsMutation(borrowed_place.projection, target_projection),
                .view => pathInvalidatesView(borrowed_place.projection, target_projection),
            };
        }

        pub fn rejectProjectedBindingWritableAliasConflict(
            context: *SemaContext,
            path: []const u8,
            locals: []const LocalBinding,
            projected: BorrowedPlaceDependency,
            token: lexer.Token,
        ) SemaError!void {
            for (locals) |local| {
                if (local.is_unavailable or local.kind(context) != .ref or canonicalRefIsConst(context, local.type_id)) continue;
                // A projected view derived from a writable parameter retains
                // that parameter as its owner root. Its later mutations are
                // checked against the projected borrow, so the originating
                // parameter is not a competing alias at binding creation.
                if (local.is_param) {
                    var originating_param = false;
                    if (projected.roots.precise_param_roots) {
                        for (projected.roots.param_roots[0..projected.roots.param_root_count]) |name| {
                            if (name != null and std.mem.eql(u8, name.?, local.name)) originating_param = true;
                        }
                    }
                    if (projected.roots.precise_param_owner_roots) {
                        for (projected.roots.param_owner_roots[0..projected.roots.param_owner_root_count]) |name| {
                            if (name != null and std.mem.eql(u8, name.?, local.name)) originating_param = true;
                        }
                    }
                    if (originating_param) continue;
                }
                if (!local.borrowed_place.hasBorrow() or
                    !normalizedBindingRootsOverlap(local.borrowed_place.roots, projected.roots) or
                    !pathOverlapsMutation(local.borrowed_place.projection, projected.projection)) continue;
                try context.diagnostic_context.emitToken(path, token, "cannot bind projected field while writable alias `{s}` may mutate it", .{local.name});
                return SemaError.SemanticFailed;
            }
        }

        pub fn rejectProjectedBindingMutableAliasCreation(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            target_expr: *ast.Expr,
            token: lexer.Token,
        ) SemaError!void {
            const target = queryPlaceMutationTarget(context, program, current_module, globals, locals, target_expr, .none, "alias");
            for (locals) |local| {
                if (local.binding_mode != .projected or local.is_unavailable or
                    !normalizedBindingRootsOverlap(local.borrowed_place.roots, target.roots) or
                    !pathOverlapsMutation(local.borrowed_place.projection, target.projection)) continue;
                try context.diagnostic_context.emitToken(path, token, "cannot create mutable alias while overlapping borrow `{s}` is live", .{local.name});
                return SemaError.SemanticFailed;
            }
        }

        pub fn rejectProjectedBindingWritableCall(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            argument: *ast.Expr,
        ) SemaError!void {
            const target_expr = if (argument.* == .address_of) argument.address_of.expr else argument;
            const target = queryPlaceMutationTarget(context, program, current_module, globals, locals, target_expr, .none, "writable call argument");
            for (locals) |local| {
                if (local.binding_mode != .projected or local.is_unavailable or
                    !normalizedBindingRootsOverlap(local.borrowed_place.roots, target.roots) or
                    !pathOverlapsMutation(local.borrowed_place.projection, target.projection)) continue;
                try context.diagnostic_context.emitToken(path, ast.firstExprToken(argument), "cannot pass writable alias while overlapping borrow `{s}` is live", .{local.name});
                return SemaError.SemanticFailed;
            }
        }

        fn rejectLiveBorrowInvalidationForRoots(
            context: *SemaContext,
            path: []const u8,
            locals: []const LocalBinding,
            target_roots: NormalizedBorrowRoots,
            target_label: []const u8,
            token: lexer.Token,
            action: []const u8,
        ) SemaError!void {
            for (locals) |local| {
                if (!local.borrowed_place.hasBorrow() or local.is_unavailable) continue;
                if (!normalizedBindingRootsOverlap(local.borrowed_place.roots, target_roots)) continue;
                try emitOwnershipDiagnostic(
                    context,
                    path,
                    token,
                    .ownership_invalidation,
                    borrowOriginToken(local),
                    "borrow created or stored here",
                    "the borrow remains live at this operation",
                    "end the borrow before invalidating its source",
                    "cannot {s} local `{s}` while borrow `{s}` is live",
                    .{ action, target_label, local.name },
                );
                return SemaError.SemanticFailed;
            }
        }

        fn rejectLiveBorrowMutationConflict(
            context: *SemaContext,
            path: []const u8,
            locals: []const LocalBinding,
            target_roots: NormalizedBorrowRoots,
            target_projection: PlaceProjectionPath,
            target_label: []const u8,
            token: lexer.Token,
            action: []const u8,
        ) SemaError!void {
            for (locals) |local| {
                if (local.is_unavailable) continue;
                if (!borrowConflictsWithMutation(local.borrowed_place, target_roots, target_projection)) continue;
                try emitOwnershipDiagnostic(
                    context,
                    path,
                    token,
                    .ownership_live_borrow_conflict,
                    borrowOriginToken(local),
                    "overlapping borrow created or stored here",
                    "the borrowed projection overlaps this mutation",
                    "end the borrow before mutating the overlapping place",
                    "cannot {s} local `{s}` while overlapping borrow `{s}` is live",
                    .{ action, target_label, local.name },
                );
                return SemaError.SemanticFailed;
            }
        }

        const PlaceMutationProjectionSuffix = union(enum) {
            none,
            field: []const u8,
            index: ?i64,
            container,
        };

        const PlaceMutationTarget = struct {
            roots: NormalizedBorrowRoots,
            projection: PlaceProjectionPath,
            label: []const u8,
        };

        pub fn queryPlaceMutationTarget(
            context: *const SemaContext,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            target_expr: *ast.Expr,
            suffix: PlaceMutationProjectionSuffix,
            fallback_label: []const u8,
        ) PlaceMutationTarget {
            const resolved = resolvePlace(context, program, current_module, globals, locals, target_expr);
            var projection = if (resolved) |place| place.projection else PlaceProjectionPath.none();
            switch (suffix) {
                .none => {},
                .field => |field| projection.appendField(field),
                .index => |index| projection.appendIndex(index),
                .container => projection.appendContainer(),
            }
            var roots = if (resolved) |place| place.roots else NormalizedBorrowRoots.none();
            if (resolved) |place| {
                if (findLocal(locals, place.root_name)) |local| {
                    var has_indexed_projected_binding = false;
                    for (locals) |candidate| {
                        if (candidate.binding_mode != .projected or candidate.is_unavailable) continue;
                        const checked = candidate.projected_place orelse continue;
                        if (checked.root == .binding and local.binding_id != null and checked.root.binding == local.binding_id.?) {
                            has_indexed_projected_binding = true;
                            break;
                        }
                    }
                    if (has_indexed_projected_binding and !local.is_param and (local.kind(@constCast(context)) == .slice or local.kind(@constCast(context)) == .ref) and
                        local.borrowed_place.hasBorrow() and local.borrowed_place.projection.has_root)
                    {
                        var inherited = local.borrowed_place.projection;
                        var index: usize = 0;
                        while (index < projection.step_count) : (index += 1) {
                            switch (projection.stepAt(index)) {
                                .field => |field| inherited.appendField(field),
                                .index => |item_index| inherited.appendIndex(item_index),
                                .container => inherited.appendContainer(),
                            }
                        }
                        projection = inherited;
                        roots = local.borrowed_place.roots;
                        if (roots.contains_param and roots.precise_param_roots) {
                            for (roots.param_roots[0..roots.param_root_count]) |name| {
                                if (name) |param_name| roots = NormalizedBorrowRoots.combine(roots, NormalizedBorrowRoots.paramOwnerValue(param_name));
                            }
                        } else if (roots.contains_param) {
                            roots.contains_param_owner = true;
                            roots.precise_param_owner_roots = false;
                            roots.param_owner_root_count = 0;
                        }
                        roots.contains_param = false;
                        roots.precise_param_roots = true;
                        roots.param_root_count = 0;
                    }
                }
            }
            return .{
                .roots = roots,
                .projection = projection,
                .label = if (resolved) |place| place.root_name else fallback_label,
            };
        }

        pub fn rejectLiveBorrowPlaceMutationConflict(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            target_expr: *ast.Expr,
            suffix: PlaceMutationProjectionSuffix,
            fallback_label: []const u8,
            token: lexer.Token,
            action: []const u8,
        ) SemaError!void {
            const target = queryPlaceMutationTarget(context, program, current_module, globals, locals, target_expr, suffix, fallback_label);
            return rejectLiveBorrowMutationConflict(
                context,
                path,
                locals,
                target.roots,
                target.projection,
                target.label,
                token,
                action,
            );
        }

        pub fn rejectLiveBorrowContainerMutationConflict(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            target_expr: *ast.Expr,
            target_label: []const u8,
            token: lexer.Token,
            action: []const u8,
        ) SemaError!void {
            return rejectLiveBorrowPlaceMutationConflict(context, path, program, current_module, globals, locals, target_expr, .container, target_label, token, action);
        }

        pub fn rejectLiveBorrowInvalidation(
            context: *SemaContext,
            path: []const u8,
            locals: []const LocalBinding,
            target_name: []const u8,
            token: lexer.Token,
            action: []const u8,
        ) SemaError!void {
            return rejectLiveBorrowInvalidationForRoots(context, path, locals, NormalizedBorrowRoots.localValue(target_name), target_name, token, action);
        }

        fn borrowSummaryGenericArgsEql(context: *SemaContext, a: ?[]const semantic_types.GenericArgument, b: ?[]const semantic_types.GenericArgument) SemaError!bool {
            _ = context;
            return generics.argumentsEqual(a, b);
        }

        const BorrowSummaryNode = struct {
            key: BorrowSummaryOwnedKey,
            ctx: BorrowSummarySolveContext,
            relation: BorrowEscapeRelation,
            dependencies: std.ArrayListUnmanaged(usize),
            dependents: std.ArrayListUnmanaged(usize),
            queued: bool,

            fn deinit(self: *BorrowSummaryNode, allocator: std.mem.Allocator) void {
                self.key.deinit(allocator);
                self.ctx.facts.deinit(allocator);
                self.relation.deinit(allocator);
                self.dependencies.deinit(allocator);
                self.dependents.deinit(allocator);
            }
        };

        pub const BorrowSummaryWorklist = struct {
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            globals: []const GlobalBinding,
            nodes: std.ArrayListUnmanaged(BorrowSummaryNode),
            queue: std.ArrayListUnmanaged(usize),
            current_node_index: ?usize,
            root_node_index: usize,

            fn init(root_ctx: BorrowSummarySolveContext) SemaError!BorrowSummaryWorklist {
                var self = BorrowSummaryWorklist{
                    .context = root_ctx.context,
                    .allocator = root_ctx.allocator,
                    .path = root_ctx.path,
                    .program = root_ctx.program,
                    .globals = root_ctx.globals,
                    .nodes = .empty,
                    .queue = .empty,
                    .current_node_index = null,
                    .root_node_index = 0,
                };
                errdefer self.deinit();
                const root_index = try self.appendNode(root_ctx);
                self.root_node_index = root_index;
                return self;
            }

            fn deinit(self: *BorrowSummaryWorklist) void {
                for (self.nodes.items) |*node| node.deinit(self.allocator);
                self.nodes.deinit(self.allocator);
                self.queue.deinit(self.allocator);
            }

            fn appendNode(self: *BorrowSummaryWorklist, ctx: BorrowSummarySolveContext) SemaError!usize {
                var appended = false;
                errdefer if (!appended) ctx.facts.deinit(self.allocator);
                var key = try ownBorrowSummaryKey(self.allocator, ctx.summary_key);
                errdefer if (!appended) key.deinit(self.allocator);
                var relation = try BorrowEscapeRelation.init(self.allocator, ctx.function.params.len);
                errdefer if (!appended) relation.deinit(self.allocator);
                const node = BorrowSummaryNode{
                    .key = key,
                    .ctx = ctx,
                    .relation = relation,
                    .dependencies = .empty,
                    .dependents = .empty,
                    .queued = false,
                };
                try self.nodes.append(self.allocator, node);
                appended = true;
                const index = self.nodes.items.len - 1;
                try self.enqueue(index);
                return index;
            }

            fn findNodeIndex(self: *BorrowSummaryWorklist, key: BorrowSummaryKey) SemaError!?usize {
                for (self.nodes.items, 0..) |node, i| {
                    if (try borrowSummaryKeyEql(self.context, node.key.view(), key)) return i;
                }
                return null;
            }

            fn enqueue(self: *BorrowSummaryWorklist, node_index: usize) !void {
                if (self.nodes.items[node_index].queued) return;
                self.nodes.items[node_index].queued = true;
                try self.queue.append(self.allocator, node_index);
            }

            fn appendIndexUnique(list: *std.ArrayListUnmanaged(usize), allocator: std.mem.Allocator, index: usize) !void {
                for (list.items) |existing| {
                    if (existing == index) return;
                }
                try list.append(allocator, index);
            }

            fn addDependency(self: *BorrowSummaryWorklist, from_index: usize, to_index: usize) !void {
                if (from_index == to_index) return;
                try BorrowSummaryWorklist.appendIndexUnique(&self.nodes.items[from_index].dependencies, self.allocator, to_index);
                try BorrowSummaryWorklist.appendIndexUnique(&self.nodes.items[to_index].dependents, self.allocator, from_index);
            }

            fn buildContextForKey(self: *BorrowSummaryWorklist, key: BorrowSummaryKey) SemaError!BorrowSummarySolveContext {
                const function = (if (findAstFunction(self.context, self.program, key.module_name, key.owner, key.function_name)) |found| found else findImplFunctionForBorrowSummary(self.program, key) orelse {
                    try self.context.diagnostic_context.emitPath(self.path, "unknown function while building borrow summary");
                    return SemaError.SemanticFailed;
                }).decl;
                var owned_generic_params: ?[]ast.GenericParam = null;
                defer if (owned_generic_params) |params| self.allocator.free(params);
                const generic_params = try self.genericParamsForKey(key, function, &owned_generic_params);
                return try buildBorrowSummarySolveContext(
                    self.context,
                    self.allocator,
                    self.path,
                    self.program,
                    key.module_name,
                    self.globals,
                    function,
                    generic_params,
                    key.generic_args,
                );
            }

            fn ensureNode(self: *BorrowSummaryWorklist, key: BorrowSummaryKey) SemaError!usize {
                if (try self.findNodeIndex(key)) |index| return index;
                const ctx = try self.buildContextForKey(key);
                return try self.appendNode(ctx);
            }

            fn genericParamsForKey(self: *BorrowSummaryWorklist, key: BorrowSummaryKey, function: ast.Function, owned: *?[]ast.GenericParam) SemaError!?[]const ast.GenericParam {
                if (key.generic_args == null) return null;
                if (function.owner) |owner_name| {
                    for (self.program.impls) |impl_decl| {
                        if (!std.mem.eql(u8, impl_decl.module_name, key.module_name) or !std.mem.eql(u8, impl_decl.method_owner, owner_name)) continue;
                        if (key.generic_args.?.len == impl_decl.type_params.len + function.type_params.len) {
                            if (function.type_params.len == 0) return impl_decl.type_params;
                            owned.* = try generics.combineGenericParams(SemaContext, self.context, self.path, impl_decl.type_params, function.type_params);
                            return owned.*.?;
                        }
                    }
                    const decl = findStruct(self.context, self.program, key.module_name, owner_name);
                    if (decl) |struct_decl| {
                        if (key.generic_args.?.len == struct_decl.type_params.len + function.type_params.len) {
                            owned.* = try generics.combineGenericParams(SemaContext, self.context, self.path, struct_decl.type_params, function.type_params);
                            return owned.*.?;
                        }
                    }
                }
                return if (function.type_params.len != 0) function.type_params else null;
            }

            fn currentApproximation(self: *BorrowSummaryWorklist, key: BorrowSummaryKey) SemaError!BorrowEscapeSummaryRelation {
                const node_index = try self.ensureNode(key);
                if (self.current_node_index) |from_index| {
                    try self.addDependency(from_index, node_index);
                    try recordBorrowSummaryDependency(self.context, self.allocator, self.nodes.items[from_index].key.view(), key);
                }
                return try makeBorrowEscapeSummaryResult(
                    self.allocator,
                    self.nodes.items[node_index].ctx.facts,
                    try self.nodes.items[node_index].relation.clone(self.allocator),
                );
            }

            fn analyzeNode(self: *BorrowSummaryWorklist, node_index: usize) SemaError!BorrowEscapeRelation {
                const ctx = self.nodes.items[node_index].ctx;
                var owned_generic_params: ?[]ast.GenericParam = null;
                defer if (owned_generic_params) |params| self.allocator.free(params);
                const key = self.nodes.items[node_index].key.view();
                const generic_params = try self.genericParamsForKey(key, ctx.function, &owned_generic_params);
                const saved_params = self.context.function_state.current_generic_params;
                const saved_args = self.context.function_state.current_generic_args;
                self.context.function_state.current_generic_params = generic_params orelse &.{};
                self.context.function_state.current_generic_args = key.generic_args orelse &.{};
                defer {
                    self.context.function_state.current_generic_params = saved_params;
                    self.context.function_state.current_generic_args = saved_args;
                }
                var next_relation = try BorrowEscapeRelation.init(self.allocator, ctx.function.params.len);
                errdefer next_relation.deinit(self.allocator);
                const saved_current = self.current_node_index;
                self.current_node_index = node_index;
                defer self.current_node_index = saved_current;

                try summarizeDirectBorrowEscapesInBlock(
                    self.context,
                    ctx.path,
                    ctx.program,
                    ctx.current_module,
                    ctx.globals,
                    ctx.function.body,
                    ctx.function.params,
                    ctx.facts.source_type_ids,
                    ctx.facts.source_can_borrow,
                    ctx.facts.sink_is_ref,
                    &next_relation,
                );
                return next_relation;
            }

            fn cacheSolvedRelations(self: *BorrowSummaryWorklist) SemaError!void {
                for (self.nodes.items) |node| {
                    const key = node.key.view();
                    try cacheBorrowSummaryRelation(self.context, self.allocator, key, key.generic_args, node.relation);
                }
            }

            fn solve(self: *BorrowSummaryWorklist) SemaError!BorrowEscapeSummaryRelation {
                while (self.queue.pop()) |node_index| {
                    self.nodes.items[node_index].queued = false;
                    const next_relation = try self.analyzeNode(node_index);
                    if (BorrowEscapeRelation.eql(self.nodes.items[node_index].relation, next_relation)) {
                        next_relation.deinit(self.allocator);
                        continue;
                    }

                    self.nodes.items[node_index].relation.deinit(self.allocator);
                    self.nodes.items[node_index].relation = next_relation;
                    for (self.nodes.items[node_index].dependents.items) |dependent_index| {
                        try self.enqueue(dependent_index);
                    }
                }

                try self.cacheSolvedRelations();
                const root_node = self.nodes.items[self.root_node_index];
                return try makeBorrowEscapeSummaryResult(
                    self.allocator,
                    root_node.ctx.facts,
                    try root_node.relation.clone(self.allocator),
                );
            }
        };

        pub const BorrowSummarySolver = struct {
            ctx: BorrowSummarySolveContext,

            pub fn init(ctx: BorrowSummarySolveContext) BorrowSummarySolver {
                return .{ .ctx = ctx };
            }

            fn tryReuse(self: BorrowSummarySolver) SemaError!?BorrowEscapeSummaryRelation {
                if (self.ctx.context.borrow_summaries.active_worklist != null) return null;
                if (try lookupBorrowSummaryRelation(self.ctx.context, self.ctx.allocator, self.ctx.summary_key)) |relation| {
                    return try makeBorrowEscapeSummaryResult(self.ctx.allocator, self.ctx.facts, relation.relation);
                }
                return null;
            }

            fn solve(self: BorrowSummarySolver) SemaError!BorrowEscapeSummaryRelation {
                if (self.ctx.context.borrow_summaries.active_worklist) |worklist| {
                    defer self.ctx.facts.deinit(self.ctx.allocator);
                    return try worklist.currentApproximation(self.ctx.summary_key);
                }
                var worklist = try BorrowSummaryWorklist.init(self.ctx);
                defer worklist.deinit();
                self.ctx.context.borrow_summaries.active_worklist = &worklist;
                defer self.ctx.context.borrow_summaries.active_worklist = null;
                return try worklist.solve();
            }

            pub fn resolve(self: BorrowSummarySolver) SemaError!BorrowEscapeSummaryRelation {
                const reused_summary = self.tryReuse() catch |err| {
                    self.ctx.facts.deinit(self.ctx.allocator);
                    return err;
                };
                if (reused_summary) |reused| {
                    self.ctx.facts.deinit(self.ctx.allocator);
                    return reused;
                }
                return try self.solve();
            }
        };

        fn mergeNestedCallBorrowEscapes(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            owner: ?[]const u8,
            callee_name: []const u8,
            type_args: []const ast.TypeName,
            args: []const ast.CallArg,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
            source_can_borrow: []const bool,
            sink_is_ref: []const bool,
            relation: *BorrowEscapeRelation,
        ) SemaError!void {
            const callee = (findAstFunction(context, program, current_module, owner, callee_name) orelse return).decl;
            if (callee.params.len != args.len) return;
            const resolved_args = if (callee.type_params.len == 0)
                null
            else if (try inferGenericArgsFromSummaryCall(context, path, program, current_module, callee, type_args, args, params, param_types)) |inferred|
                inferred
            else
                return;
            defer if (resolved_args) |bindings| context.allocator.free(bindings);

            const allocator = context.allocator;
            var nested = try summarizeBorrowEscapeRelation(context, path, program, current_module, globals, callee, if (resolved_args != null) callee.type_params else null, resolved_args);
            defer nested.deinit(allocator);

            for (callee.params, 0..) |_, callee_source_index| {
                const roots = try querySummaryExprBorrowRoots(context, path, program, current_module, args[callee_source_index].value, params, param_types, source_can_borrow);
                if (nested.relation.escapesToGlobalSource(callee.params, nested.source_can_borrow, callee_source_index)) relation.markGlobalFrom(roots);
                for (callee.params, 0..) |_, callee_sink_index| {
                    if (!nested.relation.escapesToSinkSource(callee.params, nested.source_can_borrow, callee_source_index, callee_sink_index)) continue;
                    markSummaryRootsToTargetSinks(context, program, current_module, globals, params, sink_is_ref, args[callee_sink_index].value, roots, relation);
                }
            }
        }

        fn mergeNestedCallBorrowReturns(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            owner: ?[]const u8,
            callee_name: []const u8,
            type_args: []const ast.TypeName,
            args: []const ast.CallArg,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
            source_can_borrow: []const bool,
            relation: *BorrowEscapeRelation,
        ) SemaError!bool {
            const callee = (findAstFunction(context, program, current_module, owner, callee_name) orelse return false).decl;
            if (callee.params.len != args.len) return false;
            const resolved_args = if (callee.type_params.len == 0)
                null
            else if (try inferGenericArgsFromSummaryCall(context, path, program, current_module, callee, type_args, args, params, param_types)) |inferred|
                inferred
            else
                return false;
            defer if (resolved_args) |bindings| context.allocator.free(bindings);

            const allocator = context.allocator;
            var nested = try summarizeBorrowEscapeRelation(context, path, program, current_module, globals, callee, if (resolved_args != null) callee.type_params else null, resolved_args);
            defer nested.deinit(allocator);

            for (callee.params, 0..) |_, callee_source_index| {
                if (!nested.relation.returnsSource(callee.params, nested.source_can_borrow, callee_source_index)) continue;
                const roots = try querySummaryExprBorrowRoots(context, path, program, current_module, args[callee_source_index].value, params, param_types, source_can_borrow);
                relation.markReturnFrom(roots);
            }
            return true;
        }

        fn mergeNestedMethodBorrowEscapes(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            call: ast.MethodCall,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
            source_can_borrow: []const bool,
            sink_is_ref: []const bool,
            relation: *BorrowEscapeRelation,
        ) SemaError!void {
            const object_type = (try exprSummaryType(context, path, program, current_module, call.object, params, param_types)) orelse return;
            const receiver_type_id = normalizedStructReceiverType(context, object_type) orelse return;
            const receiver_type = receiver_type_id;
            const method = findStructMethodForCanonicalType(context, program, receiver_type_id, call.method) orelse return;
            if (method.params.len != call.args.len + 1) return;

            const resolved = try resolveMethodSummaryBindings(context, path, program, current_module, receiver_type, method, call.type_args, call.args, params, param_types) orelse return;
            defer resolved.deinit(context.allocator);

            const allocator = context.allocator;
            var nested = try summarizeBorrowEscapeRelation(context, path, program, current_module, globals, method, resolved.generic_params, resolved.generic_args);
            defer nested.deinit(allocator);

            const total_args = call.args.len + 1;
            var callee_source_index: usize = 0;
            while (callee_source_index < total_args) : (callee_source_index += 1) {
                const roots = if (callee_source_index == 0)
                    try querySummaryExprBorrowRoots(context, path, program, current_module, call.object, params, param_types, source_can_borrow)
                else
                    try querySummaryExprBorrowRoots(context, path, program, current_module, call.args[callee_source_index - 1].value, params, param_types, source_can_borrow);
                if (nested.relation.escapesToGlobalSource(method.params, nested.source_can_borrow, callee_source_index)) relation.markGlobalFrom(roots);
                var callee_sink_index: usize = 0;
                while (callee_sink_index < total_args) : (callee_sink_index += 1) {
                    if (!nested.relation.escapesToSinkSource(method.params, nested.source_can_borrow, callee_source_index, callee_sink_index)) continue;
                    const target_expr = if (callee_sink_index == 0)
                        call.object
                    else
                        call.args[callee_sink_index - 1].value;
                    markSummaryRootsToTargetSinks(context, program, current_module, globals, params, sink_is_ref, target_expr, roots, relation);
                }
            }
        }

        fn mergeNestedMethodBorrowReturns(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            call: ast.MethodCall,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
            source_can_borrow: []const bool,
            relation: *BorrowEscapeRelation,
        ) SemaError!bool {
            const object_type = (try exprSummaryType(context, path, program, current_module, call.object, params, param_types)) orelse return false;
            const receiver_type_id = normalizedStructReceiverType(context, object_type) orelse return false;
            const receiver_type = receiver_type_id;
            const method = if (findStructMethodForCanonicalType(context, program, receiver_type_id, call.method)) |resolved|
                resolved
            else if (try protocols.resolveProtocolMethodForType(SemaContext, context, path, program, receiver_type_id, call.method, call.method_token, null, null)) |resolved|
                resolved.decl
            else
                return false;
            if (method.params.len != call.args.len + 1) return false;

            const resolved = try resolveMethodSummaryBindings(context, path, program, current_module, receiver_type, method, call.type_args, call.args, params, param_types) orelse return false;
            defer resolved.deinit(context.allocator);

            const allocator = context.allocator;
            var nested = try summarizeBorrowEscapeRelation(context, path, program, current_module, globals, method, resolved.generic_params, resolved.generic_args);
            defer nested.deinit(allocator);

            if (nested.relation.returnsSource(method.params, nested.source_can_borrow, 0)) {
                const roots = try querySummaryExprBorrowRoots(context, path, program, current_module, call.object, params, param_types, source_can_borrow);
                relation.markReturnFrom(roots);
            }
            for (call.args, 0..) |arg, arg_index| {
                if (!nested.relation.returnsSource(method.params, nested.source_can_borrow, arg_index + 1)) continue;
                const roots = try querySummaryExprBorrowRoots(context, path, program, current_module, arg.value, params, param_types, source_can_borrow);
                relation.markReturnFrom(roots);
            }
            return true;
        }

        fn summarizeDirectBorrowEscapesInBlock(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            body: []const ast.Stmt,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
            source_can_borrow: []const bool,
            sink_is_ref: []const bool,
            relation: *BorrowEscapeRelation,
        ) SemaError!void {
            for (body) |stmt| switch (stmt) {
                .yield => |yield_stmt| if (yield_stmt.value) |expr| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, expr, params, param_types, source_can_borrow, sink_is_ref, relation),
                .local => |local| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, local.init, params, param_types, source_can_borrow, sink_is_ref, relation),
                .@"try" => |expr| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, expr, params, param_types, source_can_borrow, sink_is_ref, relation),
                .@"defer" => |expr| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, expr, params, param_types, source_can_borrow, sink_is_ref, relation),
                .drop, .asm_stmt, .@"continue", .@"break" => {},
                .expr, .discard => |expr| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, expr, params, param_types, source_can_borrow, sink_is_ref, relation),
                .deref_assign => |assign| {
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, assign.pointer, params, param_types, source_can_borrow, sink_is_ref, relation);
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, assign.value, params, param_types, source_can_borrow, sink_is_ref, relation);
                },
                .deref_field_assign => |assign| {
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, assign.pointer, params, param_types, source_can_borrow, sink_is_ref, relation);
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, assign.value, params, param_types, source_can_borrow, sink_is_ref, relation);
                },
                .unchecked => |inner| try summarizeDirectBorrowEscapesInBlock(context, path, program, current_module, globals, inner, params, param_types, source_can_borrow, sink_is_ref, relation),
                .using_alloc => |using_alloc| try summarizeDirectBorrowEscapesInBlock(context, path, program, current_module, globals, using_alloc.body, params, param_types, source_can_borrow, sink_is_ref, relation),
                .@"if" => |if_stmt| {
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, if_stmt.condition, params, param_types, source_can_borrow, sink_is_ref, relation);
                    try summarizeDirectBorrowEscapesInBlock(context, path, program, current_module, globals, if_stmt.then_body, params, param_types, source_can_borrow, sink_is_ref, relation);
                    try summarizeDirectBorrowEscapesInBlock(context, path, program, current_module, globals, if_stmt.else_body, params, param_types, source_can_borrow, sink_is_ref, relation);
                },
                .@"while" => |while_stmt| {
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, while_stmt.condition, params, param_types, source_can_borrow, sink_is_ref, relation);
                    try summarizeDirectBorrowEscapesInBlock(context, path, program, current_module, globals, while_stmt.body, params, param_types, source_can_borrow, sink_is_ref, relation);
                },
                .@"for" => |for_stmt| {
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, for_stmt.iterable, params, param_types, source_can_borrow, sink_is_ref, relation);
                    try summarizeDirectBorrowEscapesInBlock(context, path, program, current_module, globals, for_stmt.body, params, param_types, source_can_borrow, sink_is_ref, relation);
                },
                .@"switch" => |switch_stmt| {
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, switch_stmt.value, params, param_types, source_can_borrow, sink_is_ref, relation);
                    for (switch_stmt.cases) |case| {
                        try summarizeDirectBorrowEscapesInBlock(context, path, program, current_module, globals, case.body, params, param_types, source_can_borrow, sink_is_ref, relation);
                    }
                    try summarizeDirectBorrowEscapesInBlock(context, path, program, current_module, globals, switch_stmt.else_body, params, param_types, source_can_borrow, sink_is_ref, relation);
                },
                .assign => |assign| {
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, assign.value, params, param_types, source_can_borrow, sink_is_ref, relation);
                    if (findGlobal(context, program, globals, current_module, assign.name) != null) {
                        try markSummaryExprEscapes(context, path, program, current_module, assign.value, params, param_types, source_can_borrow, .global, relation);
                    } else if (findParamIndex(params, assign.name)) |sink_index| {
                        if (sink_is_ref[sink_index]) try markSummaryExprEscapes(context, path, program, current_module, assign.value, params, param_types, source_can_borrow, .{ .sink_param = sink_index }, relation);
                    }
                },
                .field_assign => |assign| {
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, assign.value, params, param_types, source_can_borrow, sink_is_ref, relation);
                    try markSummaryExprEscapesToTargetSinks(context, path, program, current_module, globals, assign.value, params, param_types, source_can_borrow, sink_is_ref, assign.object, relation);
                },
                .index_assign => |assign| {
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, assign.index, params, param_types, source_can_borrow, sink_is_ref, relation);
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, assign.value, params, param_types, source_can_borrow, sink_is_ref, relation);
                    try markSummaryExprEscapesToTargetSinks(context, path, program, current_module, globals, assign.value, params, param_types, source_can_borrow, sink_is_ref, assign.object, relation);
                },
                .@"return" => |ret| if (ret.value) |expr| {
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, expr, params, param_types, source_can_borrow, sink_is_ref, relation);
                    try markSummaryReturnEscapes(context, path, program, current_module, globals, expr, params, param_types, source_can_borrow, relation);
                },
            };
        }

        fn summarizeDirectBorrowEscapesInExpr(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            expr: *ast.Expr,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
            source_can_borrow: []const bool,
            sink_is_ref: []const bool,
            relation: *BorrowEscapeRelation,
        ) SemaError!void {
            switch (expr.*) {
                .@"switch" => |switch_expr| {
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, switch_expr.value, params, param_types, source_can_borrow, sink_is_ref, relation);
                    for (switch_expr.cases) |case| try summarizeDirectBorrowEscapesInBlock(context, path, program, current_module, globals, case.body, params, param_types, source_can_borrow, sink_is_ref, relation);
                    try summarizeDirectBorrowEscapesInBlock(context, path, program, current_module, globals, switch_expr.else_body, params, param_types, source_can_borrow, sink_is_ref, relation);
                },
                .call => |call| {
                    try mergeNestedCallBorrowEscapes(context, path, program, current_module, globals, call.owner, call.callee, call.type_args, call.args, params, param_types, source_can_borrow, sink_is_ref, relation);
                    for (call.args) |arg| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, arg.value, params, param_types, source_can_borrow, sink_is_ref, relation);
                },
                .method_call => |call| {
                    try mergeNestedMethodBorrowEscapes(context, path, program, current_module, globals, call, params, param_types, source_can_borrow, sink_is_ref, relation);
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, call.object, params, param_types, source_can_borrow, sink_is_ref, relation);
                    for (call.args) |arg| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, arg.value, params, param_types, source_can_borrow, sink_is_ref, relation);
                },
                .address_of => |address_of| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, address_of.expr, params, param_types, source_can_borrow, sink_is_ref, relation),
                .@"try" => |try_expr| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, try_expr.expr, params, param_types, source_can_borrow, sink_is_ref, relation),
                .deref => |deref| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, deref.expr, params, param_types, source_can_borrow, sink_is_ref, relation),
                .unary => |unary| {
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, unary.expr, params, param_types, source_can_borrow, sink_is_ref, relation);
                },
                .is_test => |is_test| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, is_test.subject, params, param_types, source_can_borrow, sink_is_ref, relation),
                .cast => |cast| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, cast.subject, params, param_types, source_can_borrow, sink_is_ref, relation),
                .binary => |binary| {
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, binary.left, params, param_types, source_can_borrow, sink_is_ref, relation);
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, binary.right, params, param_types, source_can_borrow, sink_is_ref, relation);
                },
                .union_case => |case| if (case.value) |value| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, value, params, param_types, source_can_borrow, sink_is_ref, relation),
                .slice_range => |slice| {
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, slice.object, params, param_types, source_can_borrow, sink_is_ref, relation);
                    if (slice.start) |start| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, start, params, param_types, source_can_borrow, sink_is_ref, relation);
                    if (slice.end) |end| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, end, params, param_types, source_can_borrow, sink_is_ref, relation);
                },
                .index => |index| {
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, index.object, params, param_types, source_can_borrow, sink_is_ref, relation);
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, index.index, params, param_types, source_can_borrow, sink_is_ref, relation);
                },
                .array_literal => |literal| for (literal.items) |item| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, item, params, param_types, source_can_borrow, sink_is_ref, relation),
                .sequence_repeat => |repeat| {
                    for (repeat.items) |item| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, item, params, param_types, source_can_borrow, sink_is_ref, relation);
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, repeat.count, params, param_types, source_can_borrow, sink_is_ref, relation);
                },
                .typed_sequence_literal => |literal| for (literal.items) |item| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, item, params, param_types, source_can_borrow, sink_is_ref, relation),
                .fixed_array_construct => |construct| for (construct.items) |item| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, item, params, param_types, source_can_borrow, sink_is_ref, relation),
                .new_array => |new_array| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, new_array.len, params, param_types, source_can_borrow, sink_is_ref, relation),
                .new_sparse => |new_sparse| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, new_sparse.capacity, params, param_types, source_can_borrow, sink_is_ref, relation),
                .new_owned, .struct_literal => |literal| for (literal.fields) |field| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, field.value, params, param_types, source_can_borrow, sink_is_ref, relation),
                .keyed_literal => |literal| for (literal.entries) |entry| {
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, entry.key, params, param_types, source_can_borrow, sink_is_ref, relation);
                    try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, entry.value, params, param_types, source_can_borrow, sink_is_ref, relation);
                },
                .field => |field| try summarizeDirectBorrowEscapesInExpr(context, path, program, current_module, globals, field.object, params, param_types, source_can_borrow, sink_is_ref, relation),
                .int, .float, .rune, .@"comptime", .string, .interpolated_string, .bool, .none, .name, .function_expr, .enum_case, .asm_expr => {},
            }
        }
        fn markSummaryReturnEscapes(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            expr: *ast.Expr,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
            source_can_borrow: []const bool,
            relation: *BorrowEscapeRelation,
        ) SemaError!void {
            var allow_direct_param_marking = true;
            switch (expr.*) {
                .@"switch" => |switch_expr| {
                    for (switch_expr.cases) |case| for (case.body) |stmt| if (stmt == .yield) if (stmt.yield.value) |value| {
                        try markSummaryReturnEscapes(context, path, program, current_module, globals, value, params, param_types, source_can_borrow, relation);
                    };
                    for (switch_expr.else_body) |stmt| if (stmt == .yield) if (stmt.yield.value) |value| {
                        try markSummaryReturnEscapes(context, path, program, current_module, globals, value, params, param_types, source_can_borrow, relation);
                    };
                    allow_direct_param_marking = false;
                },
                .call => |call| {
                    if (!try mergeNestedCallBorrowReturns(context, path, program, current_module, globals, call.owner, call.callee, call.type_args, call.args, params, param_types, source_can_borrow, relation)) {
                        for (call.args) |arg| try markSummaryReturnEscapes(context, path, program, current_module, globals, arg.value, params, param_types, source_can_borrow, relation);
                    }
                    allow_direct_param_marking = false;
                },
                .method_call => |call| {
                    if (!try mergeNestedMethodBorrowReturns(context, path, program, current_module, globals, call, params, param_types, source_can_borrow, relation)) {
                        try markSummaryReturnEscapes(context, path, program, current_module, globals, call.object, params, param_types, source_can_borrow, relation);
                        for (call.args) |arg| try markSummaryReturnEscapes(context, path, program, current_module, globals, arg.value, params, param_types, source_can_borrow, relation);
                    }
                    allow_direct_param_marking = false;
                },
                .address_of => |address_of| try markSummaryReturnEscapes(context, path, program, current_module, globals, address_of.expr, params, param_types, source_can_borrow, relation),
                .@"try" => |try_expr| try markSummaryReturnEscapes(context, path, program, current_module, globals, try_expr.expr, params, param_types, source_can_borrow, relation),
                .deref => |deref| try markSummaryReturnEscapes(context, path, program, current_module, globals, deref.expr, params, param_types, source_can_borrow, relation),
                .unary => |unary| {
                    try markSummaryReturnEscapes(context, path, program, current_module, globals, unary.expr, params, param_types, source_can_borrow, relation);
                },
                .is_test => |is_test| try markSummaryReturnEscapes(context, path, program, current_module, globals, is_test.subject, params, param_types, source_can_borrow, relation),
                .cast => |cast| try markSummaryReturnEscapes(context, path, program, current_module, globals, cast.subject, params, param_types, source_can_borrow, relation),
                .binary => |binary| {
                    try markSummaryReturnEscapes(context, path, program, current_module, globals, binary.left, params, param_types, source_can_borrow, relation);
                    try markSummaryReturnEscapes(context, path, program, current_module, globals, binary.right, params, param_types, source_can_borrow, relation);
                },
                .union_case => |case| if (case.value) |value| try markSummaryReturnEscapes(context, path, program, current_module, globals, value, params, param_types, source_can_borrow, relation),
                .slice_range => |slice| {
                    if (try summarySliceViewCall(context, path, program, current_module, slice, params, param_types)) |call| {
                        if (!try mergeNestedMethodBorrowReturns(context, path, program, current_module, globals, call, params, param_types, source_can_borrow, relation)) {
                            try markSummaryReturnEscapes(context, path, program, current_module, globals, slice.object, params, param_types, source_can_borrow, relation);
                        }
                        allow_direct_param_marking = false;
                    } else {
                        try markSummaryReturnEscapes(context, path, program, current_module, globals, slice.object, params, param_types, source_can_borrow, relation);
                    }
                    if (slice.start) |start| try markSummaryReturnEscapes(context, path, program, current_module, globals, start, params, param_types, source_can_borrow, relation);
                    if (slice.end) |end| try markSummaryReturnEscapes(context, path, program, current_module, globals, end, params, param_types, source_can_borrow, relation);
                },
                .index => |index| {
                    try markSummaryReturnEscapes(context, path, program, current_module, globals, index.object, params, param_types, source_can_borrow, relation);
                    try markSummaryReturnEscapes(context, path, program, current_module, globals, index.index, params, param_types, source_can_borrow, relation);
                },
                .array_literal => |literal| for (literal.items) |item| try markSummaryReturnEscapes(context, path, program, current_module, globals, item, params, param_types, source_can_borrow, relation),
                .sequence_repeat => |repeat| {
                    for (repeat.items) |item| try markSummaryReturnEscapes(context, path, program, current_module, globals, item, params, param_types, source_can_borrow, relation);
                    try markSummaryReturnEscapes(context, path, program, current_module, globals, repeat.count, params, param_types, source_can_borrow, relation);
                },
                .typed_sequence_literal => |literal| for (literal.items) |item| try markSummaryReturnEscapes(context, path, program, current_module, globals, item, params, param_types, source_can_borrow, relation),
                .fixed_array_construct => |construct| for (construct.items) |item| try markSummaryReturnEscapes(context, path, program, current_module, globals, item, params, param_types, source_can_borrow, relation),
                .new_array => |new_array| try markSummaryReturnEscapes(context, path, program, current_module, globals, new_array.len, params, param_types, source_can_borrow, relation),
                .new_sparse => |new_sparse| try markSummaryReturnEscapes(context, path, program, current_module, globals, new_sparse.capacity, params, param_types, source_can_borrow, relation),
                .new_owned, .struct_literal => |literal| for (literal.fields) |field| try markSummaryReturnEscapes(context, path, program, current_module, globals, field.value, params, param_types, source_can_borrow, relation),
                .keyed_literal => |literal| for (literal.entries) |entry| {
                    try markSummaryReturnEscapes(context, path, program, current_module, globals, entry.key, params, param_types, source_can_borrow, relation);
                    try markSummaryReturnEscapes(context, path, program, current_module, globals, entry.value, params, param_types, source_can_borrow, relation);
                },
                .field => |field| try markSummaryReturnEscapes(context, path, program, current_module, globals, field.object, params, param_types, source_can_borrow, relation),
                .int, .float, .rune, .@"comptime", .string, .interpolated_string, .bool, .none, .name, .function_expr, .enum_case, .asm_expr => {},
            }

            if (!allow_direct_param_marking) return;
            const roots = try querySummaryExprBorrowRoots(context, path, program, current_module, expr, params, param_types, source_can_borrow);
            relation.markReturnFrom(roots);
        }
        pub fn markSummaryRootsToTargetRootSet(
            params: []const ast.Param,
            sink_is_ref: []const bool,
            target_roots: NormalizedBorrowRoots,
            roots: BorrowRootQuery,
            relation: *BorrowEscapeRelation,
        ) void {
            if (target_roots.contains_global) relation.markGlobalFrom(roots);
            if (!target_roots.contains_param_owner) return;

            if (!target_roots.precise_param_owner_roots) {
                for (sink_is_ref, 0..) |is_ref, param_index| {
                    if (is_ref) relation.markSinkFrom(param_index, roots);
                }
                return;
            }

            var i: usize = 0;
            while (i < target_roots.param_owner_root_count) : (i += 1) {
                const root_name = target_roots.param_owner_roots[i] orelse continue;
                const param_index = findParamIndex(params, root_name) orelse continue;
                if (sink_is_ref[param_index]) relation.markSinkFrom(param_index, roots);
            }
        }

        pub fn markSummaryRootsToTargetSinks(
            context: *const SemaContext,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            params: []const ast.Param,
            sink_is_ref: []const bool,
            target_expr: *ast.Expr,
            roots: BorrowRootQuery,
            relation: *BorrowEscapeRelation,
        ) void {
            const target_roots = querySummaryPlaceRootBindings(context, program, current_module, globals, params, target_expr);
            markSummaryRootsToTargetRootSet(params, sink_is_ref, target_roots, roots, relation);
        }

        fn markSummaryExprEscapesToTargetSinks(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            expr: *ast.Expr,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
            source_can_borrow: []const bool,
            sink_is_ref: []const bool,
            target_expr: *ast.Expr,
            relation: *BorrowEscapeRelation,
        ) SemaError!void {
            const roots = try querySummaryExprBorrowRoots(context, path, program, current_module, expr, params, param_types, source_can_borrow);
            markSummaryRootsToTargetSinks(context, program, current_module, globals, params, sink_is_ref, target_expr, roots, relation);
        }

        fn summaryExprMayCarryBorrowedProvenance(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            expr: *ast.Expr,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
        ) SemaError!bool {
            if (try exprSummaryType(context, path, program, current_module, expr, params, param_types)) |ty| {
                return try typeMayCarryBorrowedProvenance(context, path, program, current_module, ty);
            }
            return switch (expr.*) {
                .int, .float, .rune, .string, .bool, .none, .enum_case, .asm_expr => false,
                else => true,
            };
        }

        pub fn querySummaryExprBorrowRoots(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            expr: *ast.Expr,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
            source_can_borrow: []const bool,
        ) SemaError!BorrowRootQuery {
            var roots = BorrowRootQuery.initSummary();
            if (!try summaryExprMayCarryBorrowedProvenance(context, path, program, current_module, expr, params, param_types)) return roots;
            try accumulateSummaryExprBorrowRoots(path, program, current_module, expr, params, param_types, source_can_borrow, false, &roots);
            return roots;
        }

        pub fn summaryExprBorrowSourceFlags(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            expr: *ast.Expr,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
            source_can_borrow: []const bool,
            out: []bool,
        ) SemaError!void {
            @memset(out, false);
            const roots = try querySummaryExprBorrowRoots(context, path, program, current_module, expr, params, param_types, source_can_borrow);
            for (params, 0..) |_, source_index| {
                out[source_index] = roots.containsParamSource(params, source_can_borrow, source_index);
            }
        }

        pub fn findParamIndex(params: []const ast.Param, name: []const u8) ?usize {
            for (params, 0..) |param, i| {
                if (std.mem.eql(u8, param.name, name)) return i;
            }
            return null;
        }

        fn markSummaryExprEscapes(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            expr: *ast.Expr,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
            source_can_borrow: []const bool,
            sink: SummarySink,
            relation: *BorrowEscapeRelation,
        ) SemaError!void {
            const roots = try querySummaryExprBorrowRoots(context, path, program, current_module, expr, params, param_types, source_can_borrow);
            switch (sink) {
                .global => relation.markGlobalFrom(roots),
                .sink_param => |sink_index| relation.markSinkFrom(sink_index, roots),
            }
        }

        fn accumulateSummaryExprBorrowRoots(
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            expr: *ast.Expr,
            params: []const ast.Param,
            param_types: []const semantic_types.TypeId,
            source_can_borrow: []const bool,
            as_borrow_root: bool,
            roots: *BorrowRootQuery,
        ) SemaError!void {
            switch (expr.*) {
                .@"switch" => |switch_expr| {
                    for (switch_expr.cases) |case| for (case.body) |stmt| if (stmt == .yield) if (stmt.yield.value) |value| {
                        try accumulateSummaryExprBorrowRoots(path, program, current_module, value, params, param_types, source_can_borrow, as_borrow_root, roots);
                    };
                    for (switch_expr.else_body) |stmt| if (stmt == .yield) if (stmt.yield.value) |value| {
                        try accumulateSummaryExprBorrowRoots(path, program, current_module, value, params, param_types, source_can_borrow, as_borrow_root, roots);
                    };
                },
                .name => |name| roots.markParamFlow(params, source_can_borrow, name.text, as_borrow_root),
                .string => if (as_borrow_root) roots.markStatic(),
                .interpolated_string => if (as_borrow_root) roots.markStatic(),
                .address_of => |address_of| try accumulateSummaryExprBorrowRoots(path, program, current_module, address_of.expr, params, param_types, source_can_borrow, true, roots),
                .@"try" => |try_expr| try accumulateSummaryExprBorrowRoots(path, program, current_module, try_expr.expr, params, param_types, source_can_borrow, as_borrow_root, roots),
                .deref => |deref| try accumulateSummaryExprBorrowRoots(path, program, current_module, deref.expr, params, param_types, source_can_borrow, as_borrow_root, roots),
                .unary => |unary| try accumulateSummaryExprBorrowRoots(path, program, current_module, unary.expr, params, param_types, source_can_borrow, as_borrow_root, roots),
                .is_test => |is_test| try accumulateSummaryExprBorrowRoots(path, program, current_module, is_test.subject, params, param_types, source_can_borrow, as_borrow_root, roots),
                .cast => |cast| try accumulateSummaryExprBorrowRoots(path, program, current_module, cast.subject, params, param_types, source_can_borrow, as_borrow_root, roots),
                .binary => |binary| {
                    try accumulateSummaryExprBorrowRoots(path, program, current_module, binary.left, params, param_types, source_can_borrow, false, roots);
                    try accumulateSummaryExprBorrowRoots(path, program, current_module, binary.right, params, param_types, source_can_borrow, false, roots);
                },
                .call => |call| {
                    for (call.args) |arg| {
                        try accumulateSummaryExprBorrowRoots(path, program, current_module, arg.value, params, param_types, source_can_borrow, false, roots);
                    }
                },
                .method_call => |call| {
                    if (isBorrowProducingViewMethodCall(call)) {
                        try accumulateSummaryExprBorrowRoots(path, program, current_module, normalizedBorrowRootSourceExpr(expr), params, param_types, source_can_borrow, true, roots);
                        return;
                    }
                    try accumulateSummaryExprBorrowRoots(path, program, current_module, call.object, params, param_types, source_can_borrow, false, roots);
                    for (call.args) |arg| {
                        try accumulateSummaryExprBorrowRoots(path, program, current_module, arg.value, params, param_types, source_can_borrow, false, roots);
                    }
                },
                .union_case => |case| if (case.value) |value| try accumulateSummaryExprBorrowRoots(path, program, current_module, value, params, param_types, source_can_borrow, false, roots),
                .slice_range, .index, .field => try accumulateSummaryExprBorrowRoots(path, program, current_module, normalizedBorrowRootSourceExpr(expr), params, param_types, source_can_borrow, true, roots),
                .array_literal => |literal| for (literal.items) |item| try accumulateSummaryExprBorrowRoots(path, program, current_module, item, params, param_types, source_can_borrow, false, roots),
                .sequence_repeat => |repeat| {
                    for (repeat.items) |item| try accumulateSummaryExprBorrowRoots(path, program, current_module, item, params, param_types, source_can_borrow, false, roots);
                    try accumulateSummaryExprBorrowRoots(path, program, current_module, repeat.count, params, param_types, source_can_borrow, false, roots);
                },
                .typed_sequence_literal => |literal| for (literal.items) |item| try accumulateSummaryExprBorrowRoots(path, program, current_module, item, params, param_types, source_can_borrow, false, roots),
                .fixed_array_construct => |construct| for (construct.items) |item| try accumulateSummaryExprBorrowRoots(path, program, current_module, item, params, param_types, source_can_borrow, false, roots),
                .new_array => {},
                .new_sparse => |new_sparse| try accumulateSummaryExprBorrowRoots(path, program, current_module, new_sparse.capacity, params, param_types, source_can_borrow, false, roots),
                .new_owned, .struct_literal => |literal| for (literal.fields) |field| try accumulateSummaryExprBorrowRoots(path, program, current_module, field.value, params, param_types, source_can_borrow, false, roots),
                .keyed_literal => |literal| for (literal.entries) |entry| {
                    try accumulateSummaryExprBorrowRoots(path, program, current_module, entry.key, params, param_types, source_can_borrow, false, roots);
                    try accumulateSummaryExprBorrowRoots(path, program, current_module, entry.value, params, param_types, source_can_borrow, false, roots);
                },
                .int, .float, .rune, .@"comptime", .bool, .none, .function_expr, .enum_case, .asm_expr => {},
            }
        }

        pub fn collectBorrowSummaryParamFacts(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            function: ast.Function,
            generic_params: ?[]const ast.GenericParam,
            generic_args: ?[]const semantic_types.GenericArgument,
        ) SemaError!BorrowSummaryParamFacts {
            const param_count = function.params.len;
            var source_type_ids = try allocator.alloc(semantic_types.TypeId, param_count);
            errdefer allocator.free(source_type_ids);
            var source_can_borrow = try allocator.alloc(bool, param_count);
            errdefer allocator.free(source_can_borrow);
            var sink_is_ref = try allocator.alloc(bool, param_count);
            errdefer allocator.free(sink_is_ref);

            var i: usize = 0;
            while (i < param_count) : (i += 1) {
                const param = function.params[i];
                const source_type = if (generic_params) |bindings|
                    try parseTypeWithBindings(context, path, program, current_module, param.type_name, null, bindings, generic_args.?)
                else
                    try parseType(context, path, program, current_module, param.type_name);
                source_type_ids[i] = source_type;
                source_can_borrow[i] = try typeMayCarryBorrowedProvenance(context, path, program, current_module, source_type_ids[i]);
                sink_is_ref[i] = canonicalTypeNode(context, source_type_ids[i]).* == .ref_;
            }

            return .{
                .source_type_ids = source_type_ids,
                .source_can_borrow = source_can_borrow,
                .sink_is_ref = sink_is_ref,
            };
        }

        pub fn buildBorrowSummarySolveContext(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            function: ast.Function,
            generic_params: ?[]const ast.GenericParam,
            generic_args: ?[]const semantic_types.GenericArgument,
        ) SemaError!BorrowSummarySolveContext {
            return .{
                .context = context,
                .allocator = allocator,
                .path = path,
                .program = program,
                .current_module = current_module,
                .globals = globals,
                .function = function,
                .generic_args = generic_args,
                .summary_key = makeBorrowSummaryKey(function, generic_args),
                .facts = try collectBorrowSummaryParamFacts(context, allocator, path, program, current_module, function, generic_params, generic_args),
            };
        }

        pub fn borrowSummaryKeyEql(context: *SemaContext, a: BorrowSummaryKey, b: BorrowSummaryKey) SemaError!bool {
            return std.mem.eql(u8, a.module_name, b.module_name) and
                optionalEql(a.owner, b.owner) and
                std.mem.eql(u8, a.function_name, b.function_name) and
                try borrowSummaryGenericArgsEql(context, a.generic_args, b.generic_args);
        }

        pub fn makeBorrowSummaryKey(function: ast.Function, generic_args: ?[]const semantic_types.GenericArgument) BorrowSummaryKey {
            return .{
                .module_name = function.module_name,
                .owner = function.owner,
                .function_name = function.name,
                .generic_args = generic_args,
            };
        }

        pub fn findImplFunctionForBorrowSummary(program: ast.Program, key: BorrowSummaryKey) ?ResolvedAstFunction {
            const owner = key.owner orelse return null;
            for (program.impls) |impl_decl| {
                if (!std.mem.eql(u8, impl_decl.module_name, key.module_name) or
                    !std.mem.eql(u8, impl_decl.method_owner, owner)) continue;
                for (impl_decl.methods) |method| {
                    if (std.mem.eql(u8, method.name, key.function_name)) {
                        return .{ .id = null, .decl = method, .impl_decl = impl_decl };
                    }
                }
            }
            return null;
        }

        pub fn ownBorrowSummaryKey(allocator: std.mem.Allocator, key: BorrowSummaryKey) !BorrowSummaryOwnedKey {
            return .{
                .module_name = key.module_name,
                .owner = key.owner,
                .function_name = key.function_name,
                .owned_generic_args = if (key.generic_args) |args| try allocator.dupe(semantic_types.GenericArgument, args) else null,
            };
        }

        fn findActiveBorrowSummaryIndex(context: *SemaContext, key: BorrowSummaryKey) SemaError!?usize {
            for (context.borrow_summaries.active.items, 0..) |active, i| {
                if (try borrowSummaryKeyEql(context, active.key, key)) return i;
            }
            return null;
        }

        fn findCachedBorrowSummaryIndex(context: *SemaContext, key: BorrowSummaryKey) SemaError!?usize {
            for (context.borrow_summaries.cached.items, 0..) |cached, i| {
                if (try borrowSummaryKeyEql(context, cached.key, key)) return i;
            }
            return null;
        }

        fn cloneCachedBorrowSummaryRelation(context: *SemaContext, allocator: std.mem.Allocator, key: BorrowSummaryKey) SemaError!?BorrowEscapeRelation {
            const cached_index = (try findCachedBorrowSummaryIndex(context, key)) orelse return null;
            return try context.borrow_summaries.cached.items[cached_index].relation.clone(allocator);
        }

        fn cloneActiveBorrowSummaryRelation(context: *SemaContext, allocator: std.mem.Allocator, key: BorrowSummaryKey) SemaError!?BorrowEscapeRelation {
            const active_index = (try findActiveBorrowSummaryIndex(context, key)) orelse return null;
            return try context.borrow_summaries.active.items[active_index].relation.clone(allocator);
        }

        const BorrowSummaryRelationSource = enum {
            cached,
            active,
        };

        const BorrowSummaryLookupResult = struct {
            relation: BorrowEscapeRelation,
            source: BorrowSummaryRelationSource,
        };

        pub fn lookupBorrowSummaryRelation(context: *SemaContext, allocator: std.mem.Allocator, key: BorrowSummaryKey) !?BorrowSummaryLookupResult {
            if (try cloneCachedBorrowSummaryRelation(context, allocator, key)) |relation| {
                return .{
                    .relation = relation,
                    .source = .cached,
                };
            }
            if (try cloneActiveBorrowSummaryRelation(context, allocator, key)) |relation| {
                return .{
                    .relation = relation,
                    .source = .active,
                };
            }
            return null;
        }

        fn dupeBorrowSummarySourceFlags(allocator: std.mem.Allocator, facts: BorrowSummaryParamFacts) ![]bool {
            return try allocator.dupe(bool, facts.source_can_borrow);
        }

        pub fn recordBorrowSummaryDependency(context: *SemaContext, allocator: std.mem.Allocator, from: BorrowSummaryKey, to: BorrowSummaryKey) !void {
            if (try borrowSummaryKeyEql(context, from, to)) return;
            for (context.borrow_summaries.dependencies.items) |edge| {
                if (try borrowSummaryKeyEql(context, edge.from.view(), from) and try borrowSummaryKeyEql(context, edge.to.view(), to)) return;
            }
            // Each end of an edge owns its own generic-argument copy, so an edge that
            // never reaches the list must release the end already built.
            var from_owned = try ownBorrowSummaryKey(allocator, from);
            errdefer if (from_owned.owned_generic_args) |args| allocator.free(args);
            var to_owned = try ownBorrowSummaryKey(allocator, to);
            errdefer if (to_owned.owned_generic_args) |args| allocator.free(args);
            try context.borrow_summaries.dependencies.append(allocator, .{
                .from = from_owned,
                .to = to_owned,
            });
            from_owned.owned_generic_args = null;
            to_owned.owned_generic_args = null;
        }

        pub fn maybeRecordActiveBorrowSummaryDependency(context: *SemaContext, allocator: std.mem.Allocator, target: BorrowSummaryKey) !void {
            if (context.borrow_summaries.active.items.len == 0) return;
            const from = context.borrow_summaries.active.items[context.borrow_summaries.active.items.len - 1].key;
            try recordBorrowSummaryDependency(context, allocator, from, target);
        }

        fn findBorrowSummaryOwnedKeyIndex(context: *SemaContext, keys: []const BorrowSummaryOwnedKey, key: BorrowSummaryKey) SemaError!?usize {
            for (keys, 0..) |existing, i| {
                if (try borrowSummaryKeyEql(context, existing.view(), key)) return i;
            }
            return null;
        }

        fn appendBorrowSummaryOwnedKeyUnique(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            keys: *std.ArrayListUnmanaged(BorrowSummaryOwnedKey),
            key: BorrowSummaryKey,
        ) !void {
            if (try findBorrowSummaryOwnedKeyIndex(context, keys.items, key) != null) return;
            var owned = try ownBorrowSummaryKey(allocator, key);
            errdefer if (owned.owned_generic_args) |args| allocator.free(args);
            try keys.append(allocator, owned);
            owned.owned_generic_args = null;
        }

        pub fn computeBorrowSummarySccs(context: *SemaContext, allocator: std.mem.Allocator) !BorrowSummarySccResult {
            var nodes: std.ArrayListUnmanaged(BorrowSummaryOwnedKey) = .empty;
            defer {
                for (nodes.items) |node| node.deinit(allocator);
                nodes.deinit(allocator);
            }

            for (context.borrow_summaries.dependencies.items) |edge| {
                try appendBorrowSummaryOwnedKeyUnique(context, allocator, &nodes, edge.from.view());
                try appendBorrowSummaryOwnedKeyUnique(context, allocator, &nodes, edge.to.view());
            }

            const node_count = nodes.items.len;
            const visited = try allocator.alloc(bool, node_count);
            defer allocator.free(visited);
            @memset(visited, false);

            var order: std.ArrayListUnmanaged(usize) = .empty;
            defer order.deinit(allocator);

            const Search = struct {
                fn dfsForward(
                    context_: *SemaContext,
                    allocator_: std.mem.Allocator,
                    nodes_: []const BorrowSummaryOwnedKey,
                    visited_: []bool,
                    order_: *std.ArrayListUnmanaged(usize),
                    start: usize,
                ) !void {
                    if (visited_[start]) return;
                    visited_[start] = true;
                    const from = nodes_[start].view();
                    for (context_.borrow_summaries.dependencies.items) |edge| {
                        if (!try borrowSummaryKeyEql(context_, edge.from.view(), from)) continue;
                        const to_index = (try findBorrowSummaryOwnedKeyIndex(context_, nodes_, edge.to.view())) orelse continue;
                        try dfsForward(context_, allocator_, nodes_, visited_, order_, to_index);
                    }
                    try order_.append(allocator_, start);
                }

                fn dfsReverse(
                    context_: *SemaContext,
                    allocator_: std.mem.Allocator,
                    nodes_: []const BorrowSummaryOwnedKey,
                    visited_: []bool,
                    members_: *std.ArrayListUnmanaged(BorrowSummaryOwnedKey),
                    start: usize,
                ) !void {
                    if (visited_[start]) return;
                    visited_[start] = true;
                    try members_.append(allocator_, try ownBorrowSummaryKey(allocator_, nodes_[start].view()));
                    const target = nodes_[start].view();
                    for (context_.borrow_summaries.dependencies.items) |edge| {
                        if (!try borrowSummaryKeyEql(context_, edge.to.view(), target)) continue;
                        const from_index = (try findBorrowSummaryOwnedKeyIndex(context_, nodes_, edge.from.view())) orelse continue;
                        try dfsReverse(context_, allocator_, nodes_, visited_, members_, from_index);
                    }
                }
            };

            for (nodes.items, 0..) |_, i| {
                try Search.dfsForward(context, allocator, nodes.items, visited, &order, i);
            }

            @memset(visited, false);
            var components: std.ArrayListUnmanaged(BorrowSummaryScc) = .empty;
            errdefer {
                for (components.items) |component| component.deinit(allocator);
                components.deinit(allocator);
            }

            var idx = order.items.len;
            while (idx > 0) {
                idx -= 1;
                const node_index = order.items[idx];
                if (visited[node_index]) continue;
                var members: std.ArrayListUnmanaged(BorrowSummaryOwnedKey) = .empty;
                errdefer {
                    for (members.items) |member| member.deinit(allocator);
                    members.deinit(allocator);
                }
                try Search.dfsReverse(context, allocator, nodes.items, visited, &members, node_index);
                try components.append(allocator, .{
                    .members = try members.toOwnedSlice(allocator),
                });
            }

            return .{
                .components = try components.toOwnedSlice(allocator),
            };
        }

        pub fn borrowSummaryKeyIsInCycle(context: *SemaContext, allocator: std.mem.Allocator, key: BorrowSummaryKey) !bool {
            const sccs = try computeBorrowSummarySccs(context, allocator);
            defer sccs.deinit(allocator);

            for (sccs.components) |component| {
                var contains = false;
                for (component.members) |member| {
                    if (try borrowSummaryKeyEql(context, member.view(), key)) {
                        contains = true;
                        break;
                    }
                }
                if (contains) return component.members.len > 1;
            }
            return false;
        }

        pub fn makeBorrowEscapeSummaryResult(
            allocator: std.mem.Allocator,
            facts: BorrowSummaryParamFacts,
            relation: BorrowEscapeRelation,
        ) !BorrowEscapeSummaryRelation {
            errdefer relation.deinit(allocator);
            return .{
                .relation = relation,
                .source_can_borrow = try dupeBorrowSummarySourceFlags(allocator, facts),
            };
        }

        pub fn cacheBorrowSummaryRelation(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            key: BorrowSummaryKey,
            generic_args: ?[]const semantic_types.GenericArgument,
            relation: BorrowEscapeRelation,
        ) !void {
            if (try findCachedBorrowSummaryIndex(context, key)) |cached_index| {
                const cached_relation = try relation.clone(allocator);
                errdefer cached_relation.deinit(allocator);
                context.borrow_summaries.cached.items[cached_index].relation.deinit(allocator);
                context.borrow_summaries.cached.items[cached_index].relation = cached_relation;
                return;
            }
            const owned_generic_args = if (generic_args) |args| try allocator.dupe(semantic_types.GenericArgument, args) else null;
            errdefer if (owned_generic_args) |args| allocator.free(args);
            const cached_relation = try relation.clone(allocator);
            errdefer cached_relation.deinit(allocator);
            try context.borrow_summaries.cached.append(allocator, .{
                .key = .{
                    .module_name = key.module_name,
                    .owner = key.owner,
                    .function_name = key.function_name,
                    .generic_args = owned_generic_args,
                },
                .owned_generic_args = owned_generic_args,
                .relation = cached_relation,
            });
        }

        fn callEscapeTargetScopeDepth(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
            expected_ref_type: semantic_types.TypeId,
        ) SemaError!usize {
            _ = path;
            _ = expected_ref_type;
            return switch (expr.*) {
                .name => |name| blk: {
                    if (findLocal(locals, name.text)) |local| {
                        if (local.kind(context) == .ref) break :blk localMutationTargetScopeDepth(context, locals, local);
                        break :blk local.scope_depth;
                    }
                    if (findGlobal(context, program, globals, current_module, name.text) != null) break :blk 0;
                    break :blk 0;
                },
                .address_of => |address_of| mutationTargetScopeDepth(context, program, current_module, globals, locals, address_of.expr) orelse 0,
                else => 0,
            };
        }

        pub fn callEscapeTarget(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
            expected_ref_type: semantic_types.TypeId,
        ) SemaError!EscapeTarget {
            return .{ .scope = try callEscapeTargetScopeDepth(context, path, program, current_module, globals, locals, expr, expected_ref_type) };
        }

        pub fn localMutationTargetScopeDepth(context: *SemaContext, locals: []const LocalBinding, binding: LocalBinding) usize {
            if (binding.kind(context) == .ref) return referentScopeDepthFromProvenance(locals, binding.provenance) orelse 0;
            return binding.scope_depth;
        }

        pub fn accumulateLocalRootSetMutationProvenance(locals: []LocalBinding, roots: NormalizedBorrowRoots, value_provenance: Provenance) void {
            if (!roots.contains_local or !roots.precise_local_roots) return;

            var i: usize = 0;
            while (i < roots.local_root_count) : (i += 1) {
                const name = roots.local_roots[i] orelse continue;
                const root_index = findLocalIndex(locals, name) orelse continue;
                locals[root_index].provenance = Provenance.combine(locals[root_index].provenance, value_provenance);
            }
        }

        pub fn accumulateBorrowRootMutationProvenance(locals: []LocalBinding, binding: LocalBinding, value_provenance: Provenance) SemaError!void {
            accumulateLocalRootSetMutationProvenance(locals, binding.borrowed_place.roots, value_provenance);
        }

        pub fn recordMutationProvenance(
            context: *SemaContext,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []LocalBinding,
            target_expr: *ast.Expr,
            value_provenance: Provenance,
        ) SemaError!void {
            const target = queryPlaceMutationTarget(context, program, current_module, globals, locals, target_expr, .none, "");
            accumulateLocalRootSetMutationProvenance(locals, target.roots, value_provenance);

            if (target_expr.* != .name) return;
            const binding = findLocal(locals, target_expr.name.text) orelse return;
            if (binding.kind(context) != .ref) return;
            const target_index = findLocalIndex(locals, target_expr.name.text) orelse return;
            locals[target_index].provenance = Provenance.combine(locals[target_index].provenance, value_provenance);
            try accumulateBorrowRootMutationProvenance(locals, binding, value_provenance);
        }

        pub fn checkedStoredBorrowDependency(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            source_expr: *ast.Expr,
            lowered: *const sir.Expr,
            value_type: semantic_types.TypeId,
            provenance: Provenance,
        ) SemaError!BorrowedPlaceDependency {
            if (!provenance.hasBorrow() or !try typeMayCarryBorrowedProvenance(context, path, program, current_module, value_type))
                return .none();
            const mode: BorrowedPlaceMode = switch (source_expr.*) {
                .address_of => .alias,
                .slice_range => .view,
                else => return borrowedPlaceDependencyForStoredValue(context, path, program, current_module, globals, locals, source_expr, value_type, provenance),
            };
            const metadata = semanticExprMetadata(context, lowered) orelse return error.SemanticFailed;
            const place = metadata.checkedPlacePath() orelse
                return borrowedPlaceDependencyForStoredValue(context, path, program, current_module, globals, locals, source_expr, value_type, provenance);
            if (place.non_owning)
                return borrowedPlaceDependencyForStoredValue(context, path, program, current_module, globals, locals, source_expr, value_type, provenance);
            const record = metadata.checked_effect orelse return error.SemanticFailed;
            if (record.effect != .borrow or record.effect.borrow != .place or
                !sir.sameCheckedPlacePath(record.effect.borrow.place, place)) return error.SemanticFailed;

            const roots: NormalizedBorrowRoots = switch (place.root) {
                .binding => |binding_id| blk: {
                    for (locals) |local| {
                        if (local.binding_id != binding_id) continue;
                        break :blk if (local.is_param)
                            NormalizedBorrowRoots.paramOwnerValue(local.name)
                        else
                            NormalizedBorrowRoots.localValue(local.name);
                    }
                    return error.SemanticFailed;
                },
                .global => |decl_id| blk: {
                    for (globals) |global| {
                        if (global.id == decl_id) break :blk NormalizedBorrowRoots.globalValue(global.name);
                    }
                    return error.SemanticFailed;
                },
            };
            var projection = PlaceProjectionPath.root();
            const steps = place.projections orelse &.{};
            for (steps, 0..) |item, index| {
                switch (item.step) {
                    .field => |field| projection.appendField(field.name),
                    .union_payload => |field| projection.appendField(field.name),
                    .index => |item_index| projection.appendIndex(if (item_index == .fixed) item_index.fixed else null),
                    .range => {
                        if (mode == .view and index + 1 == steps.len) continue;
                        projection.appendContainer();
                    },
                }
            }
            return .{ .roots = roots, .projection = projection, .mode = mode };
        }

        pub fn borrowedPlaceDependencyForStoredValue(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            source_expr: ?*ast.Expr,
            value_type: semantic_types.TypeId,
            provenance: Provenance,
        ) SemaError!BorrowedPlaceDependency {
            if (!provenance.hasBorrow()) return .none();
            if (!try typeMayCarryBorrowedProvenance(context, path, program, current_module, value_type)) return .none();

            if (source_expr) |expr| {
                if (try borrowProjectionOrigin(locals, expr)) |origin| {
                    return borrowedPlaceDependencyForStoredValue(context, path, program, current_module, globals, locals, origin, value_type, provenance);
                }
                switch (expr.*) {
                    .name => |name| {
                        if (findLocal(locals, name.text)) |local| {
                            if (local.borrowed_place.hasBorrow()) return local.borrowed_place;
                        }
                    },
                    .address_of => |address_of| return .{
                        .roots = queryPlaceRootBindings(context, program, current_module, globals, locals, address_of.expr),
                        .projection = placeProjectionPathFromExpr(address_of.expr),
                        .mode = .alias,
                    },
                    .slice_range, .method_call => if (isBorrowProducingViewExpr(expr)) {
                        const roots = (try queryViewSourceBorrowRoots(context, path, program, current_module, globals, locals, expr)).roots;
                        return .{
                            .roots = roots,
                            .projection = directBorrowProjectionPath(expr),
                            .mode = .view,
                        };
                    },
                    .field => |field| return borrowedPlaceDependencyForStoredValue(context, path, program, current_module, globals, locals, field.object, value_type, provenance),
                    .index => |index| return borrowedPlaceDependencyForStoredValue(context, path, program, current_module, globals, locals, index.object, value_type, provenance),
                    .cast => |cast| return borrowedPlaceDependencyForStoredValue(context, path, program, current_module, globals, locals, cast.subject, value_type, provenance),
                    .@"try" => |try_expr| return borrowedPlaceDependencyForStoredValue(context, path, program, current_module, globals, locals, try_expr.expr, value_type, provenance),
                    .is_test => |is_test| return borrowedPlaceDependencyForStoredValue(context, path, program, current_module, globals, locals, is_test.subject, value_type, provenance),
                    .deref => |deref| return borrowedPlaceDependencyForStoredValue(context, path, program, current_module, globals, locals, deref.expr, value_type, provenance),
                    else => {},
                }
            }

            const roots = provenance.toNormalizedBorrowRoots();
            return .{
                .roots = roots,
                .projection = conservativeBorrowProjection(roots),
                .mode = if (canonicalTypeKind(context, value_type) == .ref) .alias else .view,
            };
        }

        pub fn resolvedBorrowProjectionBase(locals: []const LocalBinding, expr: *ast.Expr) SemaError!*ast.Expr {
            return if (try borrowProjectionOrigin(locals, expr)) |origin|
                origin
            else
                expr;
        }

        pub fn borrowProjectionOrigin(locals: []const LocalBinding, expr: *ast.Expr) SemaError!?*ast.Expr {
            return switch (expr.*) {
                .name => |name| blk: {
                    const local = findLocal(locals, name.text) orelse break :blk null;
                    // Mutable carriers now keep a straight-line projection origin; the
                    // origin is widened explicitly at control-flow joins instead of
                    // being discarded on every assignment.
                    break :blk local.projection_origin;
                },
                .field => |field| blk: {
                    const base = try resolvedBorrowProjectionBase(locals, field.object);
                    break :blk switch (base.*) {
                        .struct_literal => |literal| if (findLiteralField(literal.fields, field.field)) |literal_field| literal_field.value else null,
                        .new_owned => |literal| if (findLiteralField(literal.fields, field.field)) |literal_field| literal_field.value else null,
                        else => null,
                    };
                },
                .index => |index| blk: {
                    const base = try resolvedBorrowProjectionBase(locals, index.object);
                    const item_index = switch (index.index.*) {
                        .int => |literal| blk_index: {
                            if (literal.value < 0) break :blk null;
                            break :blk_index @as(usize, @intCast(literal.value));
                        },
                        else => break :blk null,
                    };
                    break :blk switch (base.*) {
                        .array_literal => |literal| if (item_index < literal.items.len) literal.items[item_index] else null,
                        .typed_sequence_literal => |literal| if (item_index < literal.items.len) literal.items[item_index] else null,
                        .fixed_array_construct => |literal| if (item_index < literal.items.len) literal.items[item_index] else null,
                        else => null,
                    };
                },
                .union_case => |case| case.value,
                else => null,
            };
        }

        pub fn directBorrowProjectionPath(expr: *ast.Expr) PlaceProjectionPath {
            return switch (expr.*) {
                .slice_range => |slice| directBorrowProjectionPath(slice.object),
                .method_call => |call| {
                    if (isBorrowProducingViewMethodCall(call)) {
                        return directBorrowProjectionPath(call.object);
                    }
                    return .none();
                },
                else => placeProjectionPathFromExpr(expr),
            };
        }

        pub fn typeMayCarryBorrowedProvenance(context: *SemaContext, path: []const u8, program: ast.Program, current_module: []const u8, type_id: semantic_types.TypeId) SemaError!bool {
            var visited: std.ArrayListUnmanaged(semantic_types.TypeId) = .empty;
            defer visited.deinit(context.allocator);
            return canonicalTypeMayCarryBorrowedProvenance(
                context,
                path,
                program,
                current_module,
                type_id,
                &visited,
            );
        }

        fn canonicalTypeMayCarryBorrowedProvenance(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_id: semantic_types.TypeId,
            visited: *std.ArrayListUnmanaged(semantic_types.TypeId),
        ) SemaError!bool {
            const ty = canonicalTypeNode(context, type_id);
            return switch (ty.*) {
                .primitive => |primitive| primitive == .c_str,
                .inferred_integer, .inferred_float, .integer, .float, .callable, .raw => false,
                .generic_parameter => false,
                .slice, .ref_ => true,
                .optional => |child| canonicalTypeMayCarryBorrowedProvenance(context, path, program, current_module, child, visited),
                .array => |array| canonicalTypeMayCarryBorrowedProvenance(context, path, program, current_module, array.item, visited),
                .tuple => |members| blk: {
                    for (members) |member| {
                        if (try canonicalTypeMayCarryBorrowedProvenance(context, path, program, current_module, member, visited)) break :blk true;
                    }
                    break :blk false;
                },
                .result => |result| try canonicalTypeMayCarryBorrowedProvenance(context, path, program, current_module, result.ok, visited) or
                    try canonicalTypeMayCarryBorrowedProvenance(context, path, program, current_module, result.err, visited),
                .error_union => |members| blk: {
                    for (members) |member| {
                        if (try canonicalTypeMayCarryBorrowedProvenance(context, path, program, current_module, member, visited)) break :blk true;
                    }
                    break :blk false;
                },
                .dense_array, .sparse_array => |child| canonicalTypeMayCarryBorrowedProvenance(context, path, program, current_module, child, visited),
                .owned => false,
                .nominal => |nominal| switch (nominal.kind) {
                    .@"struct", .@"union" => canonicalAggregateMayCarryBorrowedProvenance(context, path, program, current_module, type_id, visited),
                    else => false,
                },
                .generic_instance => |instance| switch (instance.kind) {
                    .@"struct" => canonicalAggregateMayCarryBorrowedProvenance(context, path, program, current_module, type_id, visited),
                    else => false,
                },
            };
        }

        fn canonicalAggregateMayCarryBorrowedProvenance(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            _: []const u8,
            type_id: semantic_types.TypeId,
            visited: *std.ArrayListUnmanaged(semantic_types.TypeId),
        ) SemaError!bool {
            if (canonicalTypeVisited(visited.items, type_id)) return false;
            try visited.append(context.allocator, type_id);
            defer _ = visited.pop();

            if (canonicalStructLookup(context, program, type_id)) |decl| {
                switch (decl.fields) {
                    .ast_fields => |fields| for (fields) |field| {
                        const field_type = try parseType(context, path, program, decl.module_name, field.type_name);
                        if (try canonicalTypeMayCarryBorrowedProvenance(
                            context,
                            path,
                            program,
                            decl.module_name,
                            field_type,
                            visited,
                        )) return true;
                    },
                    .inst_fields => |fields| for (fields) |field| {
                        if (try canonicalTypeMayCarryBorrowedProvenance(
                            context,
                            path,
                            program,
                            decl.module_name,
                            field.type_id,
                            visited,
                        )) return true;
                    },
                }
                return false;
            }
            if (canonicalUnionLookup(context, program, type_id)) |decl| {
                for (decl.fields) |field| {
                    const field_type_name = field.type_name orelse continue;
                    const field_type = try parseType(context, path, program, decl.module_name, field_type_name);
                    if (try canonicalTypeMayCarryBorrowedProvenance(
                        context,
                        path,
                        program,
                        decl.module_name,
                        field_type,
                        visited,
                    )) return true;
                }
            }
            return false;
        }

        pub fn rootedBorrowProvenanceForType(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            ty: semantic_types.TypeId,
            root_kind: ProvenanceRootKind,
            root_name: ?[]const u8,
        ) SemaError!Provenance {
            if (!try typeMayCarryBorrowedProvenance(context, path, program, current_module, ty)) return .none();
            return switch (root_kind) {
                .none => .none(),
                .static => Provenance.staticValue(),
                .global => Provenance.globalValue(root_name.?),
                .param => Provenance.paramValue(root_name.?),
                .param_owner => Provenance.paramOwnerValue(root_name.?),
                .local => Provenance.localValue(root_name.?),
                .temporary => Provenance.temporaryValue(),
                .scoped_alloc => Provenance.scopedAllocValue(),
                .composite => unreachable,
            };
        }

        pub fn ownershipSummary(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_id: semantic_types.TypeId,
        ) SemaError!?[]u8 {
            switch (canonicalTypeNode(context, type_id).*) {
                .dense_array => return try allocator.dupe(u8, "dense storage"),
                .sparse_array => return try allocator.dupe(u8, "sparse storage"),
                .owned => return try allocator.dupe(u8, "owned pointer"),
                .ref_ => return try allocator.dupe(u8, "alias pointer"),
                .slice => |slice| return if (slice.is_const)
                    try allocator.dupe(u8, "read-only view")
                else
                    try allocator.dupe(u8, "borrowed view"),
                .raw => |raw| return if (raw.is_volatile)
                    try allocator.dupe(u8, "volatile raw pointer")
                else
                    try allocator.dupe(u8, "raw pointer"),
                else => {},
            }
            if (try detailedOwnershipSummary(context, allocator, path, program, current_module, type_id)) |detail| return detail;
            return switch (try ownershipClass(context, path, program, current_module, type_id)) {
                .plain => null,
                .shared => try allocator.dupe(u8, "shared / copy-value"),
                .owned => try allocator.dupe(u8, "owns nested storage"),
                .borrowed => try allocator.dupe(u8, "carries borrowed/view data"),
            };
        }

        pub fn provenanceSummary(allocator: std.mem.Allocator, provenance: Provenance) ?[]u8 {
            if (!provenance.hasBorrow()) return null;
            return switch (provenance.singleRootKind()) {
                .global => if (provenance.singleRootName()) |name|
                    std.fmt.allocPrint(allocator, "borrowed from global `{s}`", .{name}) catch null
                else
                    allocator.dupe(u8, "borrowed from global state") catch null,
                .param => if (provenance.singleRootName()) |name|
                    std.fmt.allocPrint(allocator, "borrowed from parameter `{s}`", .{name}) catch null
                else
                    allocator.dupe(u8, "borrowed from a parameter") catch null,
                .param_owner => if (provenance.singleRootName()) |name|
                    std.fmt.allocPrint(allocator, "derived from owner parameter `{s}`", .{name}) catch null
                else
                    allocator.dupe(u8, "derived from an owner parameter") catch null,
                .local => if (provenance.singleRootName()) |name|
                    std.fmt.allocPrint(allocator, "borrowed from local `{s}`", .{name}) catch null
                else
                    allocator.dupe(u8, "borrowed from a local") catch null,
                .temporary => allocator.dupe(u8, "borrowed from a temporary value") catch null,
                .scoped_alloc => allocator.dupe(u8, "depends on scoped allocator storage") catch null,
                .static => allocator.dupe(u8, "borrowed from static data") catch null,
                .composite => allocator.dupe(u8, "borrowed from multiple roots") catch null,
                .none => null,
            };
        }

        pub const OwnershipFeatures = struct {
            has_shared: bool = false,
            has_owned_value: bool = false,
            has_dense_array: bool = false,
            has_sparse_array: bool = false,
            has_owned_pointer: bool = false,
            has_borrowed_reference: bool = false,
            has_borrowed_view: bool = false,

            pub fn anyOwned(self: OwnershipFeatures) bool {
                return self.has_owned_value or self.has_dense_array or self.has_sparse_array or self.has_owned_pointer;
            }

            pub fn anyBorrowed(self: OwnershipFeatures) bool {
                return self.has_borrowed_reference or self.has_borrowed_view;
            }
        };

        fn detailedOwnershipSummary(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_id: semantic_types.TypeId,
        ) SemaError!?[]u8 {
            const features = try ownershipFeatures(context, path, program, current_module, type_id);
            if (!features.anyOwned() and !features.anyBorrowed()) {
                return if (features.has_shared) try allocator.dupe(u8, "shared / copy-value") else null;
            }

            var parts = std.ArrayListUnmanaged([]const u8).empty;
            defer parts.deinit(allocator);

            if (features.has_dense_array) try parts.append(allocator, "dense storage");
            if (features.has_sparse_array) try parts.append(allocator, "sparse storage");
            if (features.has_owned_pointer) try parts.append(allocator, "owned pointers");
            if (features.has_owned_value) try parts.append(allocator, "owned value");
            if (features.has_shared) try parts.append(allocator, "shared claims");
            if (features.has_borrowed_reference) try parts.append(allocator, "alias pointers");
            if (features.has_borrowed_view) try parts.append(allocator, "borrowed views");

            if (parts.items.len == 0) return null;

            var joined = std.ArrayListUnmanaged(u8).empty;
            defer joined.deinit(allocator);
            for (parts.items, 0..) |part, index| {
                if (index != 0) try joined.appendSlice(allocator, ", ");
                try joined.appendSlice(allocator, part);
            }

            if (features.anyOwned() and !features.anyBorrowed()) {
                if (parts.items.len == 1) {
                    return try std.fmt.allocPrint(allocator, "owns nested {s}", .{joined.items});
                }
                return try std.fmt.allocPrint(allocator, "owns nested storage ({s})", .{joined.items});
            }
            if (!features.anyOwned() and features.anyBorrowed()) {
                if (parts.items.len == 1) {
                    return try std.fmt.allocPrint(allocator, "carries {s}", .{joined.items});
                }
                return try std.fmt.allocPrint(allocator, "carries borrowed/view data ({s})", .{joined.items});
            }
            return try std.fmt.allocPrint(allocator, "mixed ownership ({s})", .{joined.items});
        }

        pub fn ownershipFeatures(context: *SemaContext, path: []const u8, program: ast.Program, current_module: []const u8, type_id: semantic_types.TypeId) SemaError!OwnershipFeatures {
            var visited: std.ArrayListUnmanaged(semantic_types.TypeId) = .empty;
            defer visited.deinit(context.allocator);
            return canonicalOwnershipFeatures(
                context,
                path,
                program,
                current_module,
                type_id,
                &visited,
            );
        }

        fn canonicalOwnershipFeatures(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_id: semantic_types.TypeId,
            visited: *std.ArrayListUnmanaged(semantic_types.TypeId),
        ) SemaError!OwnershipFeatures {
            const ty = canonicalTypeNode(context, type_id);
            return switch (ty.*) {
                .primitive => |primitive| if (primitive == .string)
                    .{ .has_shared = true }
                else if (primitive == .c_str)
                    .{ .has_borrowed_view = true }
                else
                    .{},
                .inferred_integer, .inferred_float, .integer, .float, .callable, .raw => .{},
                // A definition-site binder carries no concrete resource until it is
                // substituted; the substituted type is settled when it is instantiated.
                .generic_parameter => .{},
                .nominal => |nominal| switch (nominal.kind) {
                    .@"struct", .@"union" => if (trustedConcurrentResource(context, nominal.decl_id))
                        .{ .has_owned_value = true }
                    else
                        canonicalAggregateOwnershipFeatures(context, path, program, current_module, type_id, visited),
                    else => .{},
                },
                .generic_instance => |instance| switch (instance.kind) {
                    .@"struct" => if (trustedConcurrentResource(context, instance.base_decl_id))
                        .{ .has_owned_value = true }
                    else
                        canonicalAggregateOwnershipFeatures(context, path, program, current_module, type_id, visited),
                    else => .{},
                },
                .slice => .{ .has_borrowed_view = true },
                .ref_ => .{ .has_borrowed_reference = true },
                .dense_array => |item| combineOwnershipFeatures(
                    .{ .has_dense_array = true },
                    try canonicalOwnershipFeatures(context, path, program, current_module, item, visited),
                ),
                .sparse_array => |item| combineOwnershipFeatures(
                    .{ .has_sparse_array = true },
                    try canonicalOwnershipFeatures(context, path, program, current_module, item, visited),
                ),
                .owned => |item| combineOwnershipFeatures(
                    .{ .has_owned_pointer = true },
                    try canonicalOwnershipFeatures(context, path, program, current_module, item, visited),
                ),
                .optional => |child| canonicalOwnershipFeatures(context, path, program, current_module, child, visited),
                .array => |array| canonicalOwnershipFeatures(context, path, program, current_module, array.item, visited),
                .tuple => |members| blk: {
                    var combined: OwnershipFeatures = .{};
                    for (members) |member| {
                        combined = combineOwnershipFeatures(combined, try canonicalOwnershipFeatures(context, path, program, current_module, member, visited));
                    }
                    break :blk combined;
                },
                .result => |result| combineOwnershipFeatures(
                    try canonicalOwnershipFeatures(context, path, program, current_module, result.ok, visited),
                    try canonicalOwnershipFeatures(context, path, program, current_module, result.err, visited),
                ),
                .error_union => |members| blk: {
                    var combined: OwnershipFeatures = .{};
                    for (members) |member| {
                        combined = combineOwnershipFeatures(combined, try canonicalOwnershipFeatures(context, path, program, current_module, member, visited));
                    }
                    break :blk combined;
                },
            };
        }

        fn canonicalAggregateOwnershipFeatures(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            _: []const u8,
            type_id: semantic_types.TypeId,
            visited: *std.ArrayListUnmanaged(semantic_types.TypeId),
        ) SemaError!OwnershipFeatures {
            if (canonicalStructLookup(context, program, type_id)) |decl| {
                if (decl.is_shared_value) return .{ .has_shared = true };
                if (canonicalTypeVisited(visited.items, type_id)) return .{};
                try visited.append(context.allocator, type_id);
                defer _ = visited.pop();

                var result: OwnershipFeatures = .{ .has_owned_value = decl.is_owned_value };
                switch (decl.fields) {
                    .ast_fields => |fields| for (fields) |field| {
                        const field_type = try parseType(context, path, program, decl.module_name, field.type_name);
                        result = combineOwnershipFeatures(result, try canonicalOwnershipFeatures(
                            context,
                            path,
                            program,
                            decl.module_name,
                            field_type,
                            visited,
                        ));
                    },
                    .inst_fields => |fields| for (fields) |field| {
                        result = combineOwnershipFeatures(result, try canonicalOwnershipFeatures(
                            context,
                            path,
                            program,
                            decl.module_name,
                            field.type_id,
                            visited,
                        ));
                    },
                }
                return result;
            }
            if (canonicalUnionLookup(context, program, type_id)) |decl| {
                if (canonicalTypeVisited(visited.items, type_id)) return .{};
                try visited.append(context.allocator, type_id);
                defer _ = visited.pop();

                var result: OwnershipFeatures = .{};
                for (decl.fields) |field| {
                    const field_type_name = field.type_name orelse continue;
                    const field_type = try parseType(context, path, program, decl.module_name, field_type_name);
                    result = combineOwnershipFeatures(result, try canonicalOwnershipFeatures(
                        context,
                        path,
                        program,
                        decl.module_name,
                        field_type,
                        visited,
                    ));
                }
                for (decl.variants) |variant| {
                    const variant_type = try parseType(context, path, program, decl.module_name, variant);
                    result = combineOwnershipFeatures(result, try canonicalOwnershipFeatures(
                        context,
                        path,
                        program,
                        decl.module_name,
                        variant_type,
                        visited,
                    ));
                }
                return result;
            }
            return .{};
        }

        fn combineOwnershipFeatures(a: OwnershipFeatures, b: OwnershipFeatures) OwnershipFeatures {
            return .{
                .has_shared = a.has_shared or b.has_shared,
                .has_owned_value = a.has_owned_value or b.has_owned_value,
                .has_dense_array = a.has_dense_array or b.has_dense_array,
                .has_sparse_array = a.has_sparse_array or b.has_sparse_array,
                .has_owned_pointer = a.has_owned_pointer or b.has_owned_pointer,
                .has_borrowed_reference = a.has_borrowed_reference or b.has_borrowed_reference,
                .has_borrowed_view = a.has_borrowed_view or b.has_borrowed_view,
            };
        }

        pub fn ownershipClass(context: *SemaContext, path: []const u8, program: ast.Program, current_module: []const u8, type_id: semantic_types.TypeId) SemaError!OwnershipClass {
            const facts = try ownershipFeatures(context, path, program, current_module, type_id);
            if (facts.anyOwned()) return .owned;
            if (facts.has_shared) return .shared;
            if (facts.anyBorrowed()) return .borrowed;
            return .plain;
        }

        pub fn typeIsOwnedForProtocol(context: *SemaContext, path: []const u8, program: ast.Program, current_module: []const u8, type_id: semantic_types.TypeId) SemaError!bool {
            return (try ownershipClass(context, path, program, current_module, type_id)) == .owned;
        }

        pub fn finalizeAndRecordExprSemantics(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            typed: *TypedExpr,
        ) SemaError!void {
            if (typed.value_semantics.category != .borrowed_projection) {
                const ownership: sir.Ownership = switch (try ownershipClass(context, path, program, current_module, typed.type_id)) {
                    .plain => .plain,
                    .borrowed => .borrowed,
                    .shared => .shared,
                    .owned => .owned,
                };
                const category: sir.ValueCategory = if (try semanticExprIsPlace(context, typed.expr))
                    .place
                else
                    .value;
                const transfers_ownership = switch (typed.expr.*) {
                    .sparse_take, .take_index_local, .take_index_path_local, .take_path_local => ownership == .shared or ownership == .owned,
                    else => false,
                };
                const cleanup: sir.CleanupPolicy = if (transfers_ownership)
                    .transferred
                else if (ownership == .plain or ownership == .borrowed or category == .place or try semanticExprAliasesExistingStorage(context, typed.expr))
                    .none
                else
                    .full_expression;
                typed.value_semantics = .{
                    .category = category,
                    .ownership = ownership,
                    .cleanup = cleanup,
                };
            }
            if (!typed.value_semantics.isValid()) return error.SemanticFailed;

            const semantics = typed.value_semantics;
            try recordExprMetadata(context, typed.expr, .{
                .type_id = typed.type_id,
                .semantics = semantics,
                .intrinsic_id = typed.intrinsic_id,
                .consumption = .{
                    .transfer = transferActionForExpr(typed.expr, semantics),
                },
            });
        }

        fn semanticExprIsPlace(context: *SemaContext, expr: *const sir.Expr) SemaError!bool {
            return switch (expr.*) {
                .local, .global_ref, .raw_deref => true,
                .field => |field| semanticExprIsPlace(context, field.object),
                .index => |index| blk: {
                    if (!try semanticExprIsPlace(context, index.object)) break :blk false;
                    const object_metadata = semanticExprMetadata(context, index.object) orelse return error.SemanticFailed;
                    break :blk switch (canonicalTypeNode(context, object_metadata.type_id).*) {
                        .array, .slice, .dense_array => true,
                        else => false,
                    };
                },
                else => false,
            };
        }

        fn semanticExprAliasesExistingStorage(context: *SemaContext, expr: *const sir.Expr) SemaError!bool {
            return switch (expr.*) {
                .string,
                .local,
                .field,
                .borrowed_field,
                .union_field,
                .borrowed_union_field,
                .borrowed_index,
                .raw_deref,
                => true,
                .index => |index| blk: {
                    const object_metadata = semanticExprMetadata(context, index.object) orelse return error.SemanticFailed;
                    break :blk switch (canonicalTypeNode(context, object_metadata.type_id).*) {
                        .array, .slice, .dense_array => true,
                        else => false,
                    };
                },
                else => false,
            };
        }
    };
}

pub const EscapeTarget = union(enum) {
    scope: usize,
    function,
    global,
};

pub fn projectionPathEqual(a: anytype, b: @TypeOf(a)) bool {
    if (a.has_root != b.has_root) return false;
    if (!a.has_root) return true;
    if (a.step_count != b.step_count or a.truncated != b.truncated) return false;

    var i: usize = 0;
    while (i < a.step_count) : (i += 1) {
        switch (a.stepAt(i)) {
            .field => |field| switch (b.stepAt(i)) {
                .field => |other| if (!std.mem.eql(u8, field, other)) return false,
                else => return false,
            },
            .index => |index| switch (b.stepAt(i)) {
                .index => |other| if (index != other) return false,
                else => return false,
            },
            .container => if (b.stepAt(i) != .container) return false,
        }
    }
    return true;
}

pub fn normalizedRootsEqual(a: anytype, b: @TypeOf(a)) bool {
    if (a.contains_static != b.contains_static or
        a.contains_global != b.contains_global or
        !optionalStringEqual(a.global_name, b.global_name) or
        a.contains_param != b.contains_param or
        a.precise_param_roots != b.precise_param_roots or
        a.param_root_count != b.param_root_count or
        a.contains_param_owner != b.contains_param_owner or
        a.precise_param_owner_roots != b.precise_param_owner_roots or
        a.param_owner_root_count != b.param_owner_root_count or
        a.contains_local != b.contains_local or
        a.contains_temporary != b.contains_temporary or
        a.contains_scoped_alloc != b.contains_scoped_alloc or
        a.precise_local_roots != b.precise_local_roots or
        a.local_root_count != b.local_root_count)
    {
        return false;
    }

    for (a.param_roots, b.param_roots) |left, right| {
        if (!optionalStringEqual(left, right)) return false;
    }
    for (a.param_owner_roots, b.param_owner_roots) |left, right| {
        if (!optionalStringEqual(left, right)) return false;
    }
    for (a.local_roots, b.local_roots) |left, right| {
        if (!optionalStringEqual(left, right)) return false;
    }
    return true;
}

pub fn provenanceEqual(a: anytype, b: @TypeOf(a)) bool {
    return normalizedRootsEqual(a.roots, b.roots);
}

pub fn borrowedDependencyEqual(a: anytype, b: @TypeOf(a)) bool {
    return normalizedRootsEqual(a.roots, b.roots) and
        projectionPathEqual(a.projection, b.projection) and
        a.mode == b.mode;
}

pub fn mergeBorrowedDependency(
    a: anytype,
    b: @TypeOf(a),
    conservativeProjection: anytype,
) @TypeOf(a) {
    if (!a.hasBorrow()) return b;
    if (!b.hasBorrow()) return a;

    const roots = @TypeOf(a.roots).combine(a.roots, b.roots);
    const mode = if (a.mode == .alias or b.mode == .alias) @TypeOf(a.mode).alias else @TypeOf(a.mode).view;
    return .{
        .roots = roots,
        .projection = if (a.mode == b.mode and projectionPathEqual(a.projection, b.projection))
            a.projection
        else
            conservativeProjection(roots),
        .mode = mode,
    };
}

pub fn localAbstractStateEqual(a: anytype, b: @TypeOf(a)) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!provenanceEqual(left.provenance, right.provenance)) return false;
        if (!borrowedDependencyEqual(left.borrowed_place, right.borrowed_place)) return false;
        if (left.projection_origin != right.projection_origin) return false;
        if (left.is_unavailable != right.is_unavailable) return false;
        if (left.deferred_handoff_depth != right.deferred_handoff_depth) return false;
        if (left.is_scoped_alloc_value != right.is_scoped_alloc_value) return false;
        if (left.scoped_alloc_origin != right.scoped_alloc_origin) return false;
    }
    return true;
}

pub fn provenanceOutlivesTarget(locals: anytype, provenance: anytype, target: EscapeTarget) bool {
    const roots = provenance.toNormalizedBorrowRoots();
    if (!roots.hasAny()) return true;
    if (roots.contains_temporary or roots.contains_scoped_alloc) return false;
    switch (target) {
        .function, .global => if (roots.contains_param_owner) return false,
        .scope => {},
    }
    if (!roots.contains_local) return true;
    if (!roots.precise_local_roots) return false;

    const target_scope_depth = switch (target) {
        .scope => |depth| depth,
        .function, .global => 0,
    };
    var i: usize = 0;
    while (i < roots.local_root_count) : (i += 1) {
        const root_name = roots.local_roots[i] orelse return false;
        const root = findLocal(locals, root_name) orelse return false;
        if (root.scope_depth > target_scope_depth) return false;
    }
    return true;
}

pub fn provenanceOutlivesScope(locals: anytype, provenance: anytype, target_scope_depth: usize) bool {
    return provenanceOutlivesTarget(locals, provenance, .{ .scope = target_scope_depth });
}

pub fn provenanceCanEscapeFunction(locals: anytype, provenance: anytype) bool {
    return provenanceOutlivesTarget(locals, provenance, .function);
}

pub fn provenanceCanEscapeReturn(context: anytype, locals: anytype, provenance: anytype) bool {
    if (provenanceCanEscapeFunction(locals, provenance)) return true;
    const roots = provenance.toNormalizedBorrowRoots();
    if (!roots.contains_param_owner) return false;
    if (roots.contains_temporary or roots.contains_scoped_alloc or roots.contains_local) return false;
    if (!roots.precise_param_owner_roots) return false;

    var i: usize = 0;
    while (i < roots.param_owner_root_count) : (i += 1) {
        const root_name = roots.param_owner_roots[i] orelse return false;
        const root = findLocal(locals, root_name) orelse return false;
        if (!root.is_param) return false;
        if (root.kind(context) != .ref and root.kind(context) != .slice) return false;
    }
    return roots.param_owner_root_count != 0;
}

pub fn provenanceRootToken(locals: anytype, provenance: anytype) ?lexer.Token {
    const roots = provenance.toNormalizedBorrowRoots();
    var i: usize = 0;
    while (i < roots.local_root_count) : (i += 1) {
        const root_name = roots.local_roots[i] orelse continue;
        const root = findLocal(locals, root_name) orelse continue;
        if (root.declaration_token) |token| return token;
    }
    var j: usize = 0;
    while (j < roots.param_root_count) : (j += 1) {
        const root_name = roots.param_roots[j] orelse continue;
        const root = findLocal(locals, root_name) orelse continue;
        if (root.declaration_token) |token| return token;
    }
    return null;
}

pub fn projectedReadValueSemantics(
    result_has_storage_lifetime: bool,
    result_may_carry_borrowed_provenance: bool,
) sir.ValueSemantics {
    return if (result_has_storage_lifetime or result_may_carry_borrowed_provenance)
        .borrowedProjection()
    else
        .plainValue();
}

fn findLocal(locals: anytype, name: []const u8) ?@TypeOf(locals[0]) {
    var i = locals.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, locals[i].name, name)) return locals[i];
    }
    return null;
}

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

pub const callables = struct {
    pub fn EscapeRelation(
        comptime RootQuery: type,
        comptime rootsEqual: anytype,
    ) type {
        return struct {
            const Self = @This();

            return_roots: RootQuery,
            global_roots: RootQuery,
            param_sink_roots: []RootQuery,

            pub fn init(allocator: std.mem.Allocator, params_len: usize) !Self {
                const sinks = try allocator.alloc(RootQuery, params_len);
                for (sinks) |*sink| sink.* = RootQuery.init();
                return .{
                    .return_roots = RootQuery.init(),
                    .global_roots = RootQuery.init(),
                    .param_sink_roots = sinks,
                };
            }

            pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
                allocator.free(self.param_sink_roots);
            }

            pub fn markReturnFrom(self: *Self, roots: RootQuery) void {
                self.return_roots.mergeFrom(roots);
            }

            pub fn markGlobalFrom(self: *Self, roots: RootQuery) void {
                self.global_roots.mergeFrom(roots);
            }

            pub fn markSinkFrom(self: *Self, sink_index: usize, roots: RootQuery) void {
                if (sink_index < self.param_sink_roots.len) self.param_sink_roots[sink_index].mergeFrom(roots);
            }

            pub fn returnsSource(
                self: Self,
                params: []const ast.Param,
                source_can_borrow: []const bool,
                source_index: usize,
            ) bool {
                return self.return_roots.containsParamSource(params, source_can_borrow, source_index);
            }

            pub fn escapesToGlobalSource(
                self: Self,
                params: []const ast.Param,
                source_can_borrow: []const bool,
                source_index: usize,
            ) bool {
                return self.global_roots.containsParamSource(params, source_can_borrow, source_index);
            }

            pub fn escapesToSinkSource(
                self: Self,
                params: []const ast.Param,
                source_can_borrow: []const bool,
                source_index: usize,
                sink_index: usize,
            ) bool {
                if (sink_index >= self.param_sink_roots.len) return false;
                return self.param_sink_roots[sink_index].containsParamSource(params, source_can_borrow, source_index);
            }

            pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
                return .{
                    .return_roots = self.return_roots,
                    .global_roots = self.global_roots,
                    .param_sink_roots = try allocator.dupe(RootQuery, self.param_sink_roots),
                };
            }

            pub fn eql(a: Self, b: Self) bool {
                if (!rootsEqual(a.return_roots.roots, b.return_roots.roots)) return false;
                if (!rootsEqual(a.global_roots.roots, b.global_roots.roots)) return false;
                if (a.param_sink_roots.len != b.param_sink_roots.len) return false;
                for (a.param_sink_roots, b.param_sink_roots) |left, right| {
                    if (!rootsEqual(left.roots, right.roots)) return false;
                }
                return true;
            }
        };
    }

    pub fn EscapeSummaryRelation(comptime Relation: type) type {
        return struct {
            relation: Relation,
            source_can_borrow: []bool,

            pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
                allocator.free(self.source_can_borrow);
                self.relation.deinit(allocator);
            }
        };
    }

    pub const SummaryParamFacts = struct {
        source_type_ids: []semantic_types.TypeId,
        source_can_borrow: []bool,
        sink_is_ref: []bool,

        pub fn deinit(self: SummaryParamFacts, allocator: std.mem.Allocator) void {
            allocator.free(self.source_type_ids);
            allocator.free(self.source_can_borrow);
            allocator.free(self.sink_is_ref);
        }
    };

    pub const SummaryKey = struct {
        module_name: []const u8,
        owner: ?[]const u8,
        function_name: []const u8,
        generic_args: ?[]const semantic_types.GenericArgument,
    };

    pub const OwnedSummaryKey = struct {
        module_name: []const u8,
        owner: ?[]const u8,
        function_name: []const u8,
        owned_generic_args: ?[]semantic_types.GenericArgument,

        pub fn deinit(self: OwnedSummaryKey, allocator: std.mem.Allocator) void {
            if (self.owned_generic_args) |args| allocator.free(args);
        }

        pub fn view(self: OwnedSummaryKey) SummaryKey {
            return .{
                .module_name = self.module_name,
                .owner = self.owner,
                .function_name = self.function_name,
                .generic_args = self.owned_generic_args,
            };
        }
    };

    pub const SummaryDependency = struct {
        from: OwnedSummaryKey,
        to: OwnedSummaryKey,

        pub fn deinit(self: SummaryDependency, allocator: std.mem.Allocator) void {
            self.from.deinit(allocator);
            self.to.deinit(allocator);
        }
    };
};

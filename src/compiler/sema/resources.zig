const std = @import("std");
const sir = @import("sir.zig");
const identity = @import("identity.zig");
const types = @import("types.zig");

pub const obligations = struct {
    /// A value may own a finalization obligation in addition to ordinary storage.
    /// The front end assigns owner and scope IDs after name and type resolution;
    /// this module deliberately knows nothing about threads or spelling.
    pub const ScopeId = u32;
    pub const OwnerId = u32;
    pub const ObligationId = u32;

    pub const State = enum {
        live,
        settled,
        maybe_live,
    };

    pub const Error = error{
        InvalidScope,
        InvalidOwner,
        InvalidObligation,
        OwnerCycle,
        AlreadySettled,
        Unsettled,
        AmbiguousOwner,
        IncompatibleBranches,
        OutOfMemory,
    };

    pub const Scope = struct {
        parent: ?ScopeId,
    };

    pub const Owner = struct {
        scope: ScopeId,
        parent: ?OwnerId,
    };

    pub const Obligation = struct {
        owner: OwnerId,
        state: State = .live,
        // Borrowed from the source declaration, for an eventual diagnostic.
        label: []const u8,
    };

    pub const Dependency = struct {
        obligation: ObligationId,
        backing_owner: OwnerId,
    };

    pub const Model = struct {
        allocator: std.mem.Allocator,
        scopes: std.ArrayListUnmanaged(Scope) = .empty,
        owners: std.ArrayListUnmanaged(Owner) = .empty,
        obligations: std.ArrayListUnmanaged(Obligation) = .empty,
        dependencies: std.ArrayListUnmanaged(Dependency) = .empty,

        pub fn init(allocator: std.mem.Allocator) Error!Model {
            var model = Model{ .allocator = allocator };
            try model.scopes.append(allocator, .{ .parent = null });
            return model;
        }

        pub fn deinit(self: *Model) void {
            self.scopes.deinit(self.allocator);
            self.owners.deinit(self.allocator);
            self.obligations.deinit(self.allocator);
            self.dependencies.deinit(self.allocator);
        }

        pub fn clone(self: *const Model) Error!Model {
            var copy = Model{ .allocator = self.allocator };
            errdefer copy.deinit();
            try copy.scopes.appendSlice(self.allocator, self.scopes.items);
            try copy.owners.appendSlice(self.allocator, self.owners.items);
            try copy.obligations.appendSlice(self.allocator, self.obligations.items);
            try copy.dependencies.appendSlice(self.allocator, self.dependencies.items);
            return copy;
        }

        pub fn newScope(self: *Model, parent: ScopeId) Error!ScopeId {
            if (parent >= self.scopes.items.len) return error.InvalidScope;
            const id: ScopeId = @intCast(self.scopes.items.len);
            try self.scopes.append(self.allocator, .{ .parent = parent });
            return id;
        }

        pub fn newOwner(self: *Model, scope: ScopeId, parent: ?OwnerId) Error!OwnerId {
            if (scope >= self.scopes.items.len) return error.InvalidScope;
            if (parent) |id| {
                if (id >= self.owners.items.len) return error.InvalidOwner;
            }
            const id: OwnerId = @intCast(self.owners.items.len);
            try self.owners.append(self.allocator, .{ .scope = scope, .parent = parent });
            return id;
        }

        pub fn admit(self: *Model, owner: OwnerId, label: []const u8) Error!ObligationId {
            if (owner >= self.owners.items.len) return error.InvalidOwner;
            const id: ObligationId = @intCast(self.obligations.items.len);
            try self.obligations.append(self.allocator, .{ .owner = owner, .label = label });
            return id;
        }

        /// The front end may call this only for a checked terminal operation whose
        /// runtime contract has finished waiting and retired every admitted task.
        /// A cancellation request, timeout, or dropped task handle is not terminal.
        pub fn settle(self: *Model, id: ObligationId) Error!void {
            if (id >= self.obligations.items.len) return error.InvalidObligation;
            const obligation = &self.obligations.items[id];
            if (obligation.state != .live) return error.AlreadySettled;
            obligation.state = .settled;
        }

        pub fn requireBacking(self: *Model, id: ObligationId, backing_owner: OwnerId) Error!void {
            if (id >= self.obligations.items.len) return error.InvalidObligation;
            if (backing_owner >= self.owners.items.len) return error.InvalidOwner;
            try self.dependencies.append(self.allocator, .{ .obligation = id, .backing_owner = backing_owner });
        }

        /// Moving an aggregate changes its owner chain while leaving obligations
        /// and their IDs intact. The caller's ordinary ownership checker makes the
        /// source place unavailable after this operation.
        pub fn reparent(self: *Model, owner: OwnerId, destination: OwnerId) Error!void {
            if (owner >= self.owners.items.len or destination >= self.owners.items.len) return error.InvalidOwner;
            if (self.ownerDescendsFrom(destination, owner)) return error.OwnerCycle;
            self.owners.items[owner].parent = destination;
        }

        /// A direct move of one obligated value into a field or return place.
        pub fn move(self: *Model, id: ObligationId, destination: OwnerId) Error!void {
            if (id >= self.obligations.items.len) return error.InvalidObligation;
            if (destination >= self.owners.items.len) return error.InvalidOwner;
            if (self.obligations.items[id].state != .live) return error.AlreadySettled;
            self.obligations.items[id].owner = destination;
        }

        /// The ID lets diagnostics name the retained group, including when the
        /// attempted close is on a service owner rather than the group itself.
        pub fn outstandingForOwner(self: *const Model, owner: OwnerId) Error!?ObligationId {
            if (owner >= self.owners.items.len) return error.InvalidOwner;
            for (self.obligations.items, 0..) |obligation, index| {
                if (obligation.state != .settled and self.ownerDescendsFrom(obligation.owner, owner)) return @intCast(index);
            }
            for (self.dependencies.items) |dependency| {
                if (self.obligations.items[dependency.obligation].state != .settled and
                    self.ownerDescendsFrom(dependency.backing_owner, owner)) return dependency.obligation;
            }
            return null;
        }

        /// Reject freeing an owner while any nested value still owes settlement.
        pub fn closeOwner(self: *const Model, owner: OwnerId) Error!void {
            if (try self.outstandingForOwner(owner) != null) return error.Unsettled;
        }

        pub fn outstandingForScope(self: *const Model, scope: ScopeId) Error!?ObligationId {
            if (scope >= self.scopes.items.len) return error.InvalidScope;
            for (self.obligations.items, 0..) |obligation, index| {
                if (obligation.state == .settled) continue;
                const outer = self.outerOwner(obligation.owner);
                if (self.scopeDescendsFrom(self.owners.items[outer].scope, scope)) return @intCast(index);
            }
            for (self.dependencies.items) |dependency| {
                if (self.obligations.items[dependency.obligation].state == .settled) continue;
                const outer = self.outerOwner(dependency.backing_owner);
                if (self.scopeDescendsFrom(self.owners.items[outer].scope, scope)) return dependency.obligation;
            }
            return null;
        }

        pub fn leaveScope(self: *const Model, scope: ScopeId) Error!void {
            if (try self.outstandingForScope(scope) != null) return error.Unsettled;
        }

        /// Both branches must retain the same value graph. A possible live state
        /// remains live enough to reject an implicit drop at the join point.
        pub fn merge(left: *const Model, right: *const Model) Error!Model {
            if (left.scopes.items.len != right.scopes.items.len or
                left.owners.items.len != right.owners.items.len or
                left.obligations.items.len != right.obligations.items.len or
                left.dependencies.items.len != right.dependencies.items.len) return error.IncompatibleBranches;
            for (left.scopes.items, right.scopes.items) |scope, other| {
                if (scope.parent != other.parent) return error.IncompatibleBranches;
            }
            var joined = try left.clone();
            errdefer joined.deinit();
            for (joined.owners.items, right.owners.items) |*owner, other| {
                if (owner.scope != other.scope or owner.parent != other.parent) return error.AmbiguousOwner;
            }
            for (joined.obligations.items, right.obligations.items) |*obligation, other| {
                if (!std.mem.eql(u8, obligation.label, other.label)) return error.IncompatibleBranches;
                if (obligation.owner != other.owner) return error.AmbiguousOwner;
                if (obligation.state != other.state) obligation.state = .maybe_live;
            }
            for (joined.dependencies.items, right.dependencies.items) |dependency, other| {
                if (dependency.obligation != other.obligation or dependency.backing_owner != other.backing_owner) return error.IncompatibleBranches;
            }
            return joined;
        }

        fn ownerDescendsFrom(self: *const Model, owner: OwnerId, ancestor: OwnerId) bool {
            var cursor: ?OwnerId = owner;
            while (cursor) |id| {
                if (id == ancestor) return true;
                cursor = self.owners.items[id].parent;
            }
            return false;
        }

        fn outerOwner(self: *const Model, owner: OwnerId) OwnerId {
            var cursor = owner;
            while (self.owners.items[cursor].parent) |parent| cursor = parent;
            return cursor;
        }

        fn scopeDescendsFrom(self: *const Model, scope: ScopeId, ancestor: ScopeId) bool {
            var cursor: ?ScopeId = scope;
            while (cursor) |id| {
                if (id == ancestor) return true;
                cursor = self.scopes.items[id].parent;
            }
            return false;
        }
    };
};

pub const settlement = struct {
    /// A conservative, path-sensitive checker for linear must-settle values.
    /// The declaration IDs are supplied by trusted library resolution, never by
    /// matching a call-site spelling. It deliberately refuses to infer settlement
    /// from task cancellation, handle loss, or an arbitrary user method.
    pub const Contract = struct {
        owner_type: identity.DeclId,
        initializer: ?identity.DeclId = null,
        terminal_primary: identity.DeclId,
        terminal_secondary: identity.DeclId,
    };

    /// IDs establish authority; the checked signature establishes that consuming
    /// this receiver really is a terminal operation. A matching name is not enough.
    pub fn validateContract(interner: *const types.TypeInterner, functions: []const sir.Function, contract: Contract) error{InvalidSettlementContract}!void {
        if (contract.terminal_primary == contract.terminal_secondary) return error.InvalidSettlementContract;
        if (contract.initializer) |initializer_id| {
            if (initializer_id == contract.terminal_primary or initializer_id == contract.terminal_secondary) return error.InvalidSettlementContract;
            var found_initializer = false;
            for (functions) |function| {
                if (function.decl_id != initializer_id) continue;
                if (found_initializer or function.is_extern or function.is_export or function.calling_convention != .cyna or
                    function.params.len != 1) return error.InvalidSettlementContract;
                found_initializer = true;
                const result = interner.get(function.return_type_id orelse return error.InvalidSettlementContract) catch return error.InvalidSettlementContract;
                if (result.* != .result) return error.InvalidSettlementContract;
                const ok = interner.get(result.result.ok) catch return error.InvalidSettlementContract;
                if (ok.* != .nominal or ok.nominal.kind != .@"struct" or ok.nominal.decl_id != contract.owner_type) return error.InvalidSettlementContract;
            }
            if (!found_initializer) return error.InvalidSettlementContract;
        }
        for ([_]identity.DeclId{ contract.terminal_primary, contract.terminal_secondary }) |terminal_id| {
            var found = false;
            for (functions) |function| {
                if (function.decl_id != terminal_id) continue;
                if (found or function.is_extern or function.is_export or function.calling_convention != .cyna or function.params.len != 1) return error.InvalidSettlementContract;
                found = true;
                const receiver = interner.get(function.params[0].type_id orelse return error.InvalidSettlementContract) catch return error.InvalidSettlementContract;
                if (receiver.* != .nominal or receiver.nominal.kind != .@"struct" or receiver.nominal.decl_id != contract.owner_type) return error.InvalidSettlementContract;
                const result = interner.get(function.return_type_id orelse return error.InvalidSettlementContract) catch return error.InvalidSettlementContract;
                if (result.* != .primitive or result.primitive != .void) return error.InvalidSettlementContract;
            }
            if (!found) return error.InvalidSettlementContract;
        }
    }

    pub const Issue = struct {
        function: sir.Function,
        owner: []const u8,
        kind: enum { unsettled, already_settled } = .unsettled,
    };

    const Binding = struct {
        owner_id: usize,
        name: []const u8,
        field_path: []const u8 = "",
        live: bool = true,
    };

    const Root = struct { name: []const u8, id: usize, binding_id: ?identity.BindingId = null, type_id: ?types.TypeId = null, path_prefix: []const u8 = "" };
    const ReceiverPlace = struct { root: Root, path: []const u8 };

    const State = struct {
        allocator: std.mem.Allocator,
        roots: std.ArrayListUnmanaged(Root) = .empty,
        bindings: std.ArrayListUnmanaged(Binding) = .empty,
        deferred: std.ArrayListUnmanaged(*const sir.Expr) = .empty,
        next_owner_id: usize = 0,

        fn deinit(self: *State) void {
            self.roots.deinit(self.allocator);
            self.bindings.deinit(self.allocator);
            self.deferred.deinit(self.allocator);
        }

        fn clone(self: *const State) !State {
            var result = State{ .allocator = self.allocator, .next_owner_id = self.next_owner_id };
            errdefer result.deinit();
            try result.roots.appendSlice(self.allocator, self.roots.items);
            try result.bindings.appendSlice(self.allocator, self.bindings.items);
            try result.deferred.appendSlice(self.allocator, self.deferred.items);
            return result;
        }

        fn identityRootId(binding_id: ?identity.BindingId, synthetic: usize) usize {
            if (binding_id) |id| return @intCast(@backingInt(id));
            return (@as(usize, 1) << (@bitSizeOf(usize) - 1)) | synthetic;
        }

        fn temporaryRootId(temporary_id: identity.TemporaryId) usize {
            return (@as(usize, 1) << (@bitSizeOf(usize) - 2)) | @as(usize, @intCast(@backingInt(temporary_id)));
        }

        fn addRoot(self: *State, name: []const u8, binding_id: ?identity.BindingId) !usize {
            return self.addTypedRoot(name, binding_id, null);
        }

        fn addTypedRoot(self: *State, name: []const u8, binding_id: ?identity.BindingId, type_id: ?types.TypeId) !usize {
            const id = identityRootId(binding_id, self.next_owner_id);
            try self.roots.append(self.allocator, .{ .name = name, .id = id, .binding_id = binding_id, .type_id = type_id });
            self.next_owner_id += 1;
            return id;
        }

        fn addTemporaryRoot(self: *State, name: []const u8, binding_id: ?identity.BindingId, temporary_id: identity.TemporaryId) !usize {
            const id = temporaryRootId(temporary_id);
            try self.roots.append(self.allocator, .{ .name = name, .id = id, .binding_id = binding_id });
            return id;
        }

        fn findRoot(self: *const State, name: []const u8) ?Root {
            var index = self.roots.items.len;
            while (index > 0) {
                index -= 1;
                if (std.mem.eql(u8, self.roots.items[index].name, name)) return self.roots.items[index];
            }
            return null;
        }

        fn findBindingRoot(self: *const State, binding_id: identity.BindingId) ?Root {
            var index = self.roots.items.len;
            while (index > 0) {
                index -= 1;
                if (self.roots.items[index].binding_id == binding_id) return self.roots.items[index];
            }
            return null;
        }

        fn rootId(self: *const State, name: []const u8) ?usize {
            return (self.findRoot(name) orelse return null).id;
        }

        fn withinRoot(root: Root, binding: Binding) bool {
            if (binding.owner_id != root.id) return false;
            if (root.path_prefix.len == 0) return true;
            return std.mem.eql(u8, binding.field_path, root.path_prefix) or
                (std.mem.startsWith(u8, binding.field_path, root.path_prefix) and
                    binding.field_path.len > root.path_prefix.len and
                    (binding.field_path[root.path_prefix.len] == '.' or binding.field_path[root.path_prefix.len] == '['));
        }

        fn consumeRoot(self: *State, name: []const u8) void {
            const source = self.findRoot(name) orelse return;
            for (self.bindings.items) |*binding| if (withinRoot(source, binding.*)) {
                binding.live = false;
            };
        }

        fn consumePlace(self: *State, place: ReceiverPlace) void {
            var source = place.root;
            source.path_prefix = place.path;
            for (self.bindings.items) |*binding| if (withinRoot(source, binding.*)) {
                binding.live = false;
            };
        }

        fn trimTo(self: *State, binding_count: usize, root_count: usize, deferred_count: usize, next_id: usize) void {
            self.bindings.shrinkRetainingCapacity(binding_count);
            self.roots.shrinkRetainingCapacity(root_count);
            self.deferred.shrinkRetainingCapacity(deferred_count);
            self.next_owner_id = next_id;
        }

        fn sameObligations(self: *const State, other: *const State) bool {
            if (self.bindings.items.len != other.bindings.items.len) return false;
            for (self.bindings.items, other.bindings.items) |left, right| {
                if (left.owner_id != right.owner_id or left.live != right.live or !std.mem.eql(u8, left.field_path, right.field_path)) return false;
            }
            return true;
        }

        fn joinLive(self: *State, other: *const State) void {
            for (self.bindings.items, other.bindings.items) |*left, right| left.live = left.live or right.live;
        }

        fn live(self: *const State) ?[]const u8 {
            for (self.bindings.items) |binding| if (binding.live) {
                return binding.name;
            };
            return null;
        }

        fn find(self: *State, source: Root, field_path: []const u8) ?*Binding {
            var index = self.bindings.items.len;
            while (index > 0) {
                index -= 1;
                if (self.bindings.items[index].owner_id == source.id and
                    std.mem.eql(u8, field_path, self.bindings.items[index].field_path)) return &self.bindings.items[index];
            }
            return null;
        }
    };

    const LoopEdges = struct {
        parent: ?*LoopEdges,
        binding_base: usize,
        root_base: usize,
        deferred_base: usize,
        next_owner_id: usize,
        states: std.ArrayListUnmanaged(State) = .empty,
        breaks: std.ArrayListUnmanaged(State) = .empty,

        fn deinit(self: *LoopEdges, allocator: std.mem.Allocator) void {
            for (self.states.items) |*state| state.deinit();
            self.states.deinit(allocator);
            for (self.breaks.items) |*state| state.deinit();
            self.breaks.deinit(allocator);
        }
    };

    const Checker = struct {
        allocator: std.mem.Allocator,
        interner: *const types.TypeInterner,
        structs: []const sir.StructDecl,
        unions: []const sir.UnionDecl,
        metadata: []const sir.ExprMetadataEntry,
        contract: Contract,
        function: sir.Function,
        issue: ?Issue = null,
        current_loop: ?*LoopEdges = null,

        fn isOwner(self: *const Checker, maybe_id: ?types.TypeId) bool {
            const node = self.interner.get(maybe_id orelse return false) catch return false;
            return switch (node.*) {
                .nominal => |nominal| nominal.kind == .@"struct" and nominal.decl_id == self.contract.owner_type,
                else => false,
            };
        }

        fn addBindings(self: *Checker, state: *State, root: Root, maybe_id: ?types.TypeId, path: []const u8) !void {
            var active: std.ArrayListUnmanaged(types.TypeId) = .empty;
            defer active.deinit(self.allocator);
            try self.addBindingsRecursive(state, root, maybe_id, path, &active);
        }

        fn addBindingsRecursive(self: *Checker, state: *State, root: Root, maybe_id: ?types.TypeId, path: []const u8, active: *std.ArrayListUnmanaged(types.TypeId)) !void {
            if (self.isOwner(maybe_id)) {
                try state.bindings.append(self.allocator, .{ .owner_id = root.id, .name = root.name, .field_path = path });
                return;
            }
            const id = maybe_id orelse return;
            for (active.items) |seen| if (seen == id) return;
            try active.append(self.allocator, id);
            defer _ = active.pop();
            const node = self.interner.get(id) catch return;
            switch (node.*) {
                .owned => |child| {
                    // A unique pointer carries the obligations of its pointee.
                    // Field access is transparently lowered to the same receiver
                    // path, so keep the path unchanged here as well.
                    try self.addBindingsRecursive(state, root, child, path, active);
                    return;
                },
                .array => |array| {
                    for (0..array.len) |index| {
                        const child_path = try std.fmt.allocPrint(self.allocator, "{s}[{d}]", .{ path, index });
                        try self.addBindingsRecursive(state, root, array.item, child_path, active);
                    }
                    return;
                },
                .tuple => |members| {
                    for (members, 0..) |member, index| {
                        const child_path = try std.fmt.allocPrint(self.allocator, "{s}[{d}]", .{ path, index });
                        try self.addBindingsRecursive(state, root, member, child_path, active);
                    }
                    return;
                },
                .dense_array, .sparse_array => |item| {
                    // Dynamic containers have no statically enumerable positions.
                    // Preserve their outstanding element obligation as one
                    // aggregate until the whole value is transferred.
                    const child_path = try std.fmt.allocPrint(self.allocator, "{s}[*]", .{path});
                    try self.addBindingsRecursive(state, root, item, child_path, active);
                    return;
                },
                .result => |result| {
                    const child_path = if (path.len == 0) "ok" else try std.fmt.allocPrint(self.allocator, "{s}.ok", .{path});
                    try self.addBindingsRecursive(state, root, result.ok, child_path, active);
                    return;
                },
                .optional => |child| {
                    const child_path = if (path.len == 0) "some" else try std.fmt.allocPrint(self.allocator, "{s}.some", .{path});
                    try self.addBindingsRecursive(state, root, child, child_path, active);
                    return;
                },
                else => {},
            }
            const nominal: struct { kind: types.NominalKind, id: identity.DeclId } = switch (node.*) {
                .nominal => |value| .{ .kind = value.kind, .id = value.decl_id },
                .generic_instance => |instance| .{ .kind = instance.kind, .id = instance.decl_id orelse return },
                else => return,
            };
            if (nominal.kind == .@"union") {
                for (self.unions) |decl| {
                    if (decl.decl_id == null or decl.decl_id.? != nominal.id) continue;
                    for (decl.fields) |field| {
                        if (!field.has_payload) continue;
                        const child_path = if (path.len == 0) field.name else try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ path, field.name });
                        try self.addBindingsRecursive(state, root, field.type_id, child_path, active);
                    }
                    return;
                }
                return;
            }
            if (nominal.kind != .@"struct") return;
            for (self.structs) |decl| {
                if (decl.decl_id == null or decl.decl_id.? != nominal.id) continue;
                for (decl.fields) |field| {
                    const child_path = if (path.len == 0) field.name else try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ path, field.name });
                    try self.addBindingsRecursive(state, root, field.type_id, child_path, active);
                }
                return;
            }
        }

        fn receiverPath(self: *Checker, expr: *const sir.Expr) !?struct { name: []const u8, path: []const u8 } {
            return switch (expr.*) {
                .local => |name| .{ .name = name, .path = "" },
                .handoff_local => |name| .{ .name = name, .path = "" },
                .field => |field| blk: {
                    const parent = try self.receiverPath(field.object) orelse break :blk null;
                    break :blk .{ .name = parent.name, .path = if (parent.path.len == 0) field.field else try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ parent.path, field.field }) };
                },
                .borrowed_field => |field| blk: {
                    const parent = try self.receiverPath(field.object) orelse break :blk null;
                    break :blk .{ .name = parent.name, .path = if (parent.path.len == 0) field.field else try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ parent.path, field.field }) };
                },
                .tuple_field => |field| blk: {
                    const parent = try self.receiverPath(field.object) orelse break :blk null;
                    break :blk .{ .name = parent.name, .path = try std.fmt.allocPrint(self.allocator, "{s}[{d}]", .{ parent.path, field.index }) };
                },
                .index, .borrowed_index => |index| blk: {
                    const parent = try self.receiverPath(index.object) orelse break :blk null;
                    if (index.index.* != .int or index.index.int.value < 0) break :blk null;
                    break :blk .{ .name = parent.name, .path = try std.fmt.allocPrint(self.allocator, "{s}[{d}]", .{ parent.path, index.index.int.value }) };
                },
                .ref_field_owned_local => |field| .{ .name = field.local_name, .path = field.field },
                else => null,
            };
        }

        fn receiverPlace(self: *Checker, state: *const State, expr: *const sir.Expr) !?ReceiverPlace {
            const checked = for (self.metadata) |entry| {
                if (entry.expr == expr) break entry.metadata;
            } else null;
            const checked_place = if (checked) |metadata| metadata.checkedPlacePath() else null;
            // A checked source root identifies the owner of an alias, but does not
            // grant the alias ownership of the projected storage.
            if (checked_place) |place| if (!place.canOwn()) return null;
            const root: ?Root = if (checked_place) |place| switch (place.root) {
                .binding => |binding_id| state.findBindingRoot(binding_id),
                .global => null,
            } else blk: {
                const path = try self.receiverPath(expr) orelse return null;
                break :blk state.findRoot(path.name);
            };
            const resolved_root = root orelse return null;
            const relative_path = if (checked_place) |place| if (place.projections) |steps|
                try self.checkedProjectionPath(steps) orelse return null
            else
                (try self.receiverPath(expr) orelse return null).path else (try self.receiverPath(expr) orelse return null).path;
            return .{ .root = resolved_root, .path = try self.appendPath(resolved_root.path_prefix, relative_path) };
        }

        fn captureReceiverPlace(self: *Checker, state: *const State, expr: *const sir.Expr, origin: ?sir.CheckedCaptureOrigin) !?ReceiverPlace {
            if (origin) |checked| switch (checked) {
                .place => |place| {
                    if (place.non_owning) return null;
                    const root = switch (place.root) {
                        .binding => |binding_id| state.findBindingRoot(binding_id),
                        .global => null,
                    } orelse return null;
                    const relative_path = if (place.projections) |steps|
                        try self.checkedProjectionPath(steps) orelse return null
                    else switch (expr.*) {
                        .local, .handoff_local, .global_ref => "",
                        else => return self.receiverPlace(state, expr),
                    };
                    return .{ .root = root, .path = try self.appendPath(root.path_prefix, relative_path) };
                },
                .temporary => {},
            };
            return self.receiverPlace(state, expr);
        }

        fn checkedProjectionPath(self: *Checker, steps: []const sir.CheckedPlaceProjection) !?[]const u8 {
            var path: []const u8 = "";
            for (steps) |projection| {
                _ = self.interner.get(projection.result_type_id) catch return null;
                path = switch (projection.step) {
                    .field => |field| if (path.len == 0) field.name else try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ path, field.name }),
                    .union_payload => |field| if (path.len == 0) field.name else try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ path, field.name }),
                    .index => |index| switch (index) {
                        .fixed => |value| try std.fmt.allocPrint(self.allocator, "{s}[{d}]", .{ path, value }),
                        .dynamic => return null,
                    },
                    .range => return null,
                };
            }
            return path;
        }

        fn appendPath(self: *Checker, prefix: []const u8, suffix: []const u8) ![]const u8 {
            if (prefix.len == 0) return suffix;
            if (suffix.len == 0) return prefix;
            return if (suffix[0] == '[')
                std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, suffix })
            else
                std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prefix, suffix });
        }

        fn unionDecl(self: *const Checker, maybe_id: ?identity.DeclId) ?sir.UnionDecl {
            const id = maybe_id orelse return null;
            for (self.unions) |decl| if (decl.decl_id != null and decl.decl_id.? == id) return decl;
            return null;
        }

        fn checkedCaseName(self: *const Checker, checked: ?sir.CheckedPayloadCase, fallback: []const u8) []const u8 {
            const case = checked orelse return fallback;
            return switch (case) {
                .optional_some => "some",
                .result => |kind| if (kind == .ok) "ok" else "err",
                .union_field => |field| blk: {
                    const decl = self.unionDecl(field.owner_decl_id) orelse break :blk fallback;
                    if (field.ordinal >= decl.fields.len) break :blk fallback;
                    break :blk decl.fields[field.ordinal].name;
                },
            };
        }

        fn clearUnionAlternatives(state: *State, scope: Root, selected: Root) void {
            for (state.bindings.items) |*binding| {
                if (State.withinRoot(scope, binding.*) and !State.withinRoot(selected, binding.*)) binding.live = false;
            }
        }

        fn exprPropagates(expr: *const sir.Expr) bool {
            return containsTry(sir.Expr, expr.*);
        }

        fn containsTry(comptime T: type, value: T) bool {
            if (comptime T == sir.Expr) {
                if (value == .@"try") return true;
            }
            return switch (@typeInfo(T)) {
                .@"union" => switch (value) {
                    inline else => |payload| containsTry(@TypeOf(payload), payload),
                },
                .@"struct" => |record| blk: {
                    inline for (record.field_names, record.field_types) |name, field_type| {
                        if (containsTry(field_type, @field(value, name))) break :blk true;
                    }
                    break :blk false;
                },
                .optional => |optional| if (value) |payload| containsTry(optional.child, payload) else false,
                .pointer => |pointer| blk: {
                    if (pointer.child == u8) break :blk false;
                    if (pointer.size == .slice) {
                        for (value) |item| if (containsTry(pointer.child, item)) {
                            break :blk true;
                        };
                        break :blk false;
                    }
                    if (pointer.size == .one) break :blk containsTry(pointer.child, value.*);
                    break :blk false;
                },
                .array => |array| blk: {
                    for (value) |item| if (containsTry(array.child, item)) {
                        break :blk true;
                    };
                    break :blk false;
                },
                else => false,
            };
        }

        fn stmtPropagates(stmt: sir.Stmt) bool {
            return switch (stmt) {
                .local => |local| exprPropagates(local.init),
                .assign => |assign| exprPropagates(assign.value),
                .field_assign => |assign| containsTry(sir.FieldAssign, assign),
                .index_assign => |assign| containsTry(sir.IndexAssign, assign),
                .deref_assign => |assign| containsTry(sir.DerefAssign, assign),
                .deref_field_assign => |assign| containsTry(sir.DerefFieldAssign, assign),
                .using_alloc => |using_alloc| exprPropagates(using_alloc.allocator_expr),
                .expr => |expr| exprPropagates(expr),
                .@"try" => |attempt| exprPropagates(attempt.expr),
                .@"defer" => false,
                .@"return" => |value| if (value) |expr| exprPropagates(expr) else false,
                .@"if" => |branch| exprPropagates(branch.condition),
                .@"switch" => |branch| exprPropagates(branch.value),
                .@"while" => |loop| exprPropagates(loop.condition),
                .@"for" => |loop| exprPropagates(loop.iterable),
                else => false,
            };
        }

        fn returnCarriesOwner(self: *Checker, maybe_type: ?types.TypeId) !bool {
            const node = self.interner.get(maybe_type orelse return false) catch return false;
            switch (node.*) {
                .result => |result| return self.returnCarriesOwner(result.ok),
                .optional => |payload| return self.returnCarriesOwner(payload),
                else => {},
            }
            // addBindingsRecursive allocates projected path strings as well as
            // state entries. Keep the entire transient type probe in one arena.
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            var probe_checker = self.*;
            probe_checker.allocator = arena.allocator();
            var probe = State{ .allocator = arena.allocator() };
            defer probe.deinit();
            try probe_checker.addBindings(&probe, .{ .name = "return", .id = 0 }, maybe_type, "");
            return probe.bindings.items.len != 0;
        }

        fn rejectDynamicItem(self: *Checker, expr: *const sir.Expr) !void {
            // A dynamic slot has no stable checked element identity yet. Accepting
            // an owner here would make later element settlement unprovable.
            if (try self.returnCarriesOwner(self.exprType(expr))) self.fail("<dynamic container item>");
        }

        fn rejectLiveDynamicMutation(self: *Checker, state: *State, object: *const sir.Expr) !void {
            if (!(try self.returnCarriesOwner(self.exprType(object)))) return;
            const place = try self.receiverPlace(state, object) orelse {
                self.fail("<dynamic container place>");
                return;
            };
            var scope = place.root;
            scope.path_prefix = place.path;
            for (state.bindings.items) |binding| {
                if (binding.live and State.withinRoot(scope, binding)) {
                    self.fail(place.root.name);
                    return;
                }
            }
        }

        fn exprType(self: *const Checker, expr: *const sir.Expr) ?types.TypeId {
            for (self.metadata) |entry| {
                if (entry.expr == expr) return entry.metadata.type_id;
            }
            return null;
        }

        fn exprTemporaryId(self: *const Checker, expr: *const sir.Expr) ?identity.TemporaryId {
            for (self.metadata) |entry| {
                if (entry.expr == expr) return entry.metadata.temporary_id;
            }
            return null;
        }

        fn captureTemporaryId(self: *const Checker, origin: ?sir.CheckedCaptureOrigin, expr: *const sir.Expr) ?identity.TemporaryId {
            if (origin) |checked| return switch (checked) {
                .place => null,
                .temporary => |temporary_id| temporary_id,
            };
            return self.exprTemporaryId(expr);
        }

        fn transferReturn(self: *Checker, state: *State, expr: *const sir.Expr) !void {
            if (!(try self.returnCarriesOwner(self.function.return_type_id))) return;
            switch (expr.*) {
                .local, .handoff_local => try self.consumeValueSource(state, expr),
                .union_case => |value| {
                    if (value.value) |payload| try self.transferReturn(state, payload);
                },
                else => {},
            }
        }

        fn consumeExprPlace(self: *Checker, state: *State, expr: *const sir.Expr) !void {
            const owner = self.isOwner(self.exprType(expr));
            const place = try self.receiverPlace(state, expr) orelse {
                if (owner) self.fail("<unresolved owner source>");
                return;
            };
            if (owner) {
                const binding = state.find(place.root, place.path) orelse {
                    self.fail(place.root.name);
                    return;
                };
                if (!binding.live) {
                    self.fail(place.root.name);
                    return;
                }
            }
            state.consumePlace(place);
        }

        fn consumeValueSource(self: *Checker, state: *State, expr: *const sir.Expr) !void {
            switch (expr.*) {
                .handoff_local => {
                    const metadata = for (self.metadata) |entry| {
                        if (entry.expr == expr) break entry.metadata;
                    } else null;
                    const record = if (metadata) |checked| checked.checked_effect else null;
                    if (record) |effect| {
                        if (effect.effect == .move) {
                            try self.consumeCheckedSource(state, effect.effect.move.source, expr);
                            return;
                        }
                    }
                    self.fail("<missing handoff effect>");
                },
                .local => try self.consumeExprPlace(state, expr),
                .union_case => |case| {
                    if (case.checked_transfer != null) {
                        if (case.value) |payload| try self.consumeValueSource(state, payload);
                    }
                },
                .struct_literal, .new_owned => |literal| {
                    for (literal.fields) |field| {
                        if (field.checked_transfer != null) try self.consumeValueSource(state, field.value);
                        if (self.issue != null) break;
                    }
                },
                .array_literal, .dense_array_literal => |literal| {
                    if (literal.checked_transfers) |records| for (literal.items, records) |item, record| {
                        if (record != null) try self.consumeValueSource(state, item);
                        if (self.issue != null) break;
                    };
                },
                .tuple_literal => |literal| {
                    if (literal.checked_transfers) |records| for (literal.items, records) |item, record| {
                        if (record != null) try self.consumeValueSource(state, item);
                        if (self.issue != null) break;
                    };
                },
                .sparse_literal => |literal| {
                    if (literal.checked_transfers) |records| for (literal.items, records) |item, record| {
                        if (record != null) try self.consumeValueSource(state, item);
                        if (self.issue != null) break;
                    };
                },
                .sparse_keyed_literal => |literal| {
                    if (literal.checked_transfers) |records| for (literal.entries, records) |item, record| {
                        if (record != null) try self.consumeValueSource(state, item.value);
                        if (self.issue != null) break;
                    };
                },
                else => {},
            }
        }

        fn consumeCheckedSource(self: *Checker, state: *State, source: sir.Subject, value: *const sir.Expr) !void {
            const path = switch (source) {
                .place => |place| place,
                .generated_payload => |binding_id| sir.CheckedPlacePath{
                    .root = .{ .binding = binding_id },
                    .projections = null,
                    .non_owning = false,
                },
                // A local may carry a temporary result ID while its obligation is
                // tracked under its binding root in this checker.
                .temporary => {
                    if (value.* == .local or value.* == .handoff_local)
                        try self.consumeExprPlace(state, value);
                    return;
                },
                else => return,
            };
            const root = switch (path.root) {
                .binding => |binding_id| state.findBindingRoot(binding_id),
                .global => null,
            } orelse return;
            const suffix = if (path.projections) |steps|
                try self.checkedProjectionPath(steps) orelse return
            else
                "";
            const place = ReceiverPlace{ .root = root, .path = try self.appendPath(root.path_prefix, suffix) };
            if (self.isOwner(self.exprType(value))) {
                const binding = state.find(place.root, place.path) orelse {
                    self.fail(place.root.name);
                    return;
                };
                if (!binding.live) {
                    self.fail(place.root.name);
                    return;
                }
            }
            state.consumePlace(place);
        }

        fn structDeclId(self: *const Checker, maybe_type: ?types.TypeId) ?identity.DeclId {
            var type_id = maybe_type orelse return null;
            for (0..4) |_| {
                const node = self.interner.get(type_id) catch return null;
                switch (node.*) {
                    .owned => |child| type_id = child,
                    .ref_ => |ref| type_id = ref.target,
                    .nominal => |nominal| return if (nominal.kind == .@"struct") nominal.decl_id else null,
                    .generic_instance => |instance| return if (instance.kind == .@"struct") instance.decl_id else null,
                    else => return null,
                }
            }
            return null;
        }

        fn fieldAssignPlace(self: *Checker, state: *const State, assign: sir.FieldAssign) !?ReceiverPlace {
            const root = (if (assign.root_binding_id) |id| state.findBindingRoot(id) else state.findRoot(assign.root_name)) orelse return null;
            var path = root.path_prefix;
            if (assign.steps.len == 0) return null;
            var expected_owner = self.structDeclId(root.type_id);
            for (assign.steps) |step| {
                const owner = step.struct_decl_id orelse return null;
                if (expected_owner) |expected| if (owner != expected) return null;
                const decl = for (self.structs) |*candidate| {
                    if (candidate.decl_id == owner) break candidate;
                } else return null;
                const field_type = for (decl.fields) |field| {
                    if (std.mem.eql(u8, field.name, step.field)) break field.type_id;
                } else return null;
                expected_owner = self.structDeclId(field_type);
                path = try self.appendPath(path, step.field);
            }
            return .{ .root = root, .path = path };
        }

        fn transferCallArguments(self: *Checker, state: *State, expr: *const sir.Expr) !void {
            switch (expr.*) {
                .call => |call| {
                    const terminal_call = call.decl_id == self.contract.terminal_primary or call.decl_id == self.contract.terminal_secondary;
                    if (terminal_call) {
                        if (call.args.len == 0) {
                            self.fail("<terminal receiver>");
                            return;
                        }
                        const receiver = switch (call.args[0]) {
                            .value => |value| value,
                        };
                        // Evaluate a projected receiver before applying the terminal
                        // transition. Its child calls may already move or settle the
                        // owner, in which case the terminal must observe that state.
                        try self.transferCallArguments(state, receiver);
                        if (self.issue != null) return;
                        try self.terminal(state, expr);
                        if (self.issue != null) return;
                    }
                    for (call.args, 0..) |arg, index| {
                        // The trusted terminal transition already consumed its receiver.
                        if (terminal_call and index == 0) continue;
                        const value = switch (arg) {
                            .value => |value| value,
                        };
                        const checked_argument = for (call.checked_arguments) |record| {
                            if (record.effect == .call_argument and record.effect.call_argument.index == index)
                                break record.effect.call_argument;
                        } else null;
                        if (call.decl_id == null and try self.returnCarriesOwner(self.exprType(value))) {
                            self.fail("<unresolved call argument>");
                        } else if (checked_argument) |checked| {
                            try self.transferCallArguments(state, value);
                            if (self.issue != null) return;
                            if (checked.mode == .move) try self.consumeCheckedSource(state, checked.source, value);
                        } else if (value.* == .local or value.* == .handoff_local) {
                            try self.consumeValueSource(state, value);
                        } else if (value.* == .field or value.* == .borrowed_field or value.* == .index or value.* == .borrowed_index or value.* == .union_field or value.* == .borrowed_union_field) {
                            // A projected TaskGroup argument needs an explicit checked detach effect.
                            if (try self.returnCarriesOwner(self.exprType(value))) self.fail("<projected call argument>");
                            try self.transferCallArguments(state, value);
                        } else try self.transferCallArguments(state, value);
                        if (self.issue != null) return;
                    }
                },
                .indirect_call => |call| {
                    try self.transferCallArguments(state, call.callee);
                    if (self.issue != null) return;
                    for (call.args, 0..) |arg, index| {
                        const value = switch (arg) {
                            .value => |value| value,
                        };
                        if (try self.returnCarriesOwner(self.exprType(value))) {
                            self.fail("<indirect call argument>");
                            return;
                        }
                        try self.transferCallArguments(state, value);
                        if (self.issue != null) return;
                        if (call.checked_arguments) |records| {
                            if (records[index]) |record| switch (record.effect) {
                                .move => |move| try self.consumeCheckedSource(state, move.source, value),
                                .borrow => {},
                                else => self.fail("<indirect call effect>"),
                            };
                        }
                        if (self.issue != null) return;
                    }
                },
                .struct_literal, .new_owned => |literal| for (literal.fields) |field| {
                    try self.transferCallArguments(state, field.value);
                    if (self.issue != null) return;
                },
                .array_literal => |literal| for (literal.items) |item| {
                    try self.transferCallArguments(state, item);
                    if (self.issue != null) return;
                },
                .tuple_literal => |literal| for (literal.items) |item| {
                    try self.transferCallArguments(state, item);
                    if (self.issue != null) return;
                },
                .dense_array_literal => |literal| for (literal.items) |item| {
                    try self.transferCallArguments(state, item);
                    if (self.issue != null) return;
                    try self.rejectDynamicItem(item);
                    if (self.issue != null) return;
                },
                .union_case => |case| if (case.value) |value| try self.transferCallArguments(state, value),
                .is_test => |test_expr| try self.transferCallArguments(state, test_expr.subject),
                .field, .borrowed_field => |field| try self.transferCallArguments(state, field.object),
                .tuple_field => |field| try self.transferCallArguments(state, field.object),
                .union_field, .borrowed_union_field => |field| try self.transferCallArguments(state, field.object),
                .ref_field_expr => |field| try self.transferCallArguments(state, field.object),
                .index, .borrowed_index => |index| {
                    try self.transferCallArguments(state, index.object);
                    if (self.issue == null) try self.transferCallArguments(state, index.index);
                },
                .ref_index_local => |index| try self.transferCallArguments(state, index.index),
                .take_index_local => |index| try self.transferCallArguments(state, index.index),
                .ref_index_path_local => |path| {
                    for (path.steps) |step| if (step == .index) {
                        try self.transferCallArguments(state, step.index);
                        if (self.issue != null) return;
                    };
                    try self.transferCallArguments(state, path.index);
                },
                .take_index_path_local => |path| {
                    for (path.steps) |step| if (step == .index) {
                        try self.transferCallArguments(state, step.index);
                        if (self.issue != null) return;
                    };
                    try self.transferCallArguments(state, path.index);
                },
                .ref_path_local => |path| for (path.steps) |step| {
                    if (step == .index) try self.transferCallArguments(state, step.index);
                    if (self.issue != null) return;
                },
                .take_path_local => |path| for (path.steps) |step| {
                    if (step == .index) try self.transferCallArguments(state, step.index);
                    if (self.issue != null) return;
                },
                .slice_range => |slice| {
                    try self.transferCallArguments(state, slice.object);
                    if (self.issue != null) return;
                    if (slice.start) |start| try self.transferCallArguments(state, start);
                    if (self.issue != null) return;
                    if (slice.end) |end| try self.transferCallArguments(state, end);
                },
                .cast => |cast| try self.transferCallArguments(state, cast.subject),
                .unary => |unary| try self.transferCallArguments(state, unary.expr),
                .binary => |binary| {
                    try self.transferCallArguments(state, binary.left);
                    if (self.issue == null) try self.transferCallArguments(state, binary.right);
                },
                .@"try" => |value| try self.transferCallArguments(state, value.expr),
                .ref_load, .test_assert, .sequence_len, .sparse_len, .sparse_indices, .string_len, .string_is_empty, .string_bytes, .string_from, .slice_len => |value| try self.transferCallArguments(state, value),
                .sequence_clear, .sparse_clear, .sequence_pop => |object| {
                    try self.transferCallArguments(state, object);
                    if (self.issue == null) try self.rejectLiveDynamicMutation(state, object);
                },
                .ref_raw_deref, .raw_deref => |value| try self.transferCallArguments(state, value.expr),
                .new_array => |value| try self.transferCallArguments(state, value.len),
                .new_sparse => |value| try self.transferCallArguments(state, value.capacity),
                .sequence_push => |value| {
                    try self.transferCallArguments(state, value.object);
                    if (self.issue == null) try self.transferCallArguments(state, value.value);
                    if (self.issue == null) try self.rejectDynamicItem(value.value);
                },
                .sequence_reserve => |value| {
                    try self.transferCallArguments(state, value.object);
                    if (self.issue == null) try self.transferCallArguments(state, value.capacity);
                },
                .sparse_insert => |value| {
                    try self.transferCallArguments(state, value.object);
                    if (self.issue != null) return;
                    try self.transferCallArguments(state, value.index);
                    if (self.issue == null) try self.transferCallArguments(state, value.value);
                    if (self.issue == null) try self.rejectDynamicItem(value.value);
                },
                .sparse_contains_index => |value| {
                    try self.transferCallArguments(state, value.object);
                    if (self.issue == null) try self.transferCallArguments(state, value.index);
                },
                .sparse_take => |value| {
                    try self.transferCallArguments(state, value.object);
                    if (self.issue == null) try self.transferCallArguments(state, value.index);
                    if (self.issue == null) try self.rejectLiveDynamicMutation(state, value.object);
                },
                .string_starts_with, .string_ends_with, .string_contains, .string_find, .string_rfind => |value| {
                    try self.transferCallArguments(state, value.object);
                    if (self.issue == null) try self.transferCallArguments(state, value.value);
                },
                .string_slice => |value| {
                    try self.transferCallArguments(state, value.object);
                    if (self.issue != null) return;
                    try self.transferCallArguments(state, value.start);
                    if (self.issue == null) try self.transferCallArguments(state, value.end);
                },
                .sparse_literal => |literal| for (literal.items) |item| {
                    try self.transferCallArguments(state, item);
                    if (self.issue != null) return;
                    try self.rejectDynamicItem(item);
                    if (self.issue != null) return;
                },
                .sparse_keyed_literal => |literal| for (literal.entries) |entry| {
                    try self.transferCallArguments(state, entry.index);
                    if (self.issue != null) return;
                    try self.transferCallArguments(state, entry.value);
                    if (self.issue != null) return;
                    try self.rejectDynamicItem(entry.value);
                    if (self.issue != null) return;
                },
                .builtin_print => |print| for (print.parts) |part| {
                    if (part == .value) try self.transferCallArguments(state, part.value.expr);
                    if (self.issue != null) return;
                },
                .interpolated_string => |parts| for (parts) |part| {
                    if (part == .value) try self.transferCallArguments(state, part.value.expr);
                    if (self.issue != null) return;
                },
                .asm_expr => |assembly| {
                    if (assembly.inout) |inout| try self.transferCallArguments(state, inout.value);
                    if (self.issue != null) return;
                    for (assembly.inputs) |input| {
                        try self.transferCallArguments(state, input.value);
                        if (self.issue != null) return;
                    }
                },
                .thread_spawn_boxed => |spawn| try self.transferCallArguments(state, spawn.payload),
                .sync_share_boxed => |spawn| try self.transferCallArguments(state, spawn.payload),
                .task_group_spawn_boxed => |spawn| {
                    try self.transferCallArguments(state, spawn.group_raw);
                    if (self.issue != null) return;
                    try self.transferCallArguments(state, spawn.entry);
                    if (self.issue == null) try self.transferCallArguments(state, spawn.payload);
                },
                .task_result_take => |take| {
                    try self.transferCallArguments(state, take.witness);
                    if (self.issue == null) try self.transferCallArguments(state, take.pointer);
                },
                .closure => |closure| for (closure.captures) |capture| {
                    try self.transferCallArguments(state, capture);
                    if (self.issue != null) return;
                },
                else => {},
            }
        }

        fn fail(self: *Checker, name: []const u8) void {
            if (self.issue == null) self.issue = .{ .function = self.function, .owner = name };
        }

        fn terminal(self: *Checker, state: *State, expr: *const sir.Expr) !void {
            const call = switch (expr.*) {
                .call => |call| call,
                else => return,
            };
            const id = call.decl_id orelse return;
            if (id != self.contract.terminal_primary and id != self.contract.terminal_secondary) return;
            if (call.args.len == 0) {
                self.fail("<terminal receiver>");
                return;
            }
            const record = call.checked_terminal_effect orelse {
                self.fail("<terminal effect>");
                return;
            };
            if (record.effect != .settle or record.effect.settle.terminal_declaration_id != id or
                record.effect.settle.source != .place)
            {
                self.fail("<terminal effect>");
                return;
            }
            const checked = record.effect.settle.source.place;
            const root = switch (checked.root) {
                .binding => |binding_id| state.findBindingRoot(binding_id),
                .global => null,
            } orelse {
                self.fail("<terminal receiver>");
                return;
            };
            const suffix = if (checked.projections) |steps|
                try self.checkedProjectionPath(steps) orelse {
                    self.fail("<terminal receiver>");
                    return;
                }
            else
                "";
            const place = ReceiverPlace{ .root = root, .path = try self.appendPath(root.path_prefix, suffix) };
            const binding = state.find(place.root, place.path) orelse {
                self.fail("<terminal receiver>");
                return;
            };
            if (!binding.live) self.issue = .{ .function = self.function, .owner = place.root.name, .kind = .already_settled };
            binding.live = false;
        }

        fn runDeferred(self: *Checker, state: *State, from: usize) !void {
            var index = state.deferred.items.len;
            while (index > from) {
                index -= 1;
                const expr = state.deferred.items[index];
                try self.transferCallArguments(state, expr);
            }
        }

        fn appendLoopEntry(self: *Checker, entries: *std.ArrayListUnmanaged(State), candidate: *const State) !void {
            for (entries.items) |*entry| if (entry.sameObligations(candidate)) return;
            var copy = try candidate.clone();
            errdefer copy.deinit();
            try entries.append(self.allocator, copy);
        }

        fn checkLoopScoped(self: *Checker, state: *const State, base: usize) void {
            for (state.bindings.items[base..]) |binding| {
                if (binding.live) self.fail(binding.name);
            }
        }

        fn recordContinue(self: *Checker, state: *const State) !void {
            const loop = self.current_loop orelse return;
            var edge = try state.clone();
            defer edge.deinit();
            try self.runDeferred(&edge, loop.deferred_base);
            self.checkLoopScoped(&edge, loop.binding_base);
            if (self.issue != null) return;
            edge.trimTo(loop.binding_base, loop.root_base, loop.deferred_base, loop.next_owner_id);
            try self.appendLoopEntry(&loop.states, &edge);
        }

        fn recordBreak(self: *Checker, state: *const State) !void {
            const loop = self.current_loop orelse return;
            var edge = try state.clone();
            defer edge.deinit();
            try self.runDeferred(&edge, loop.deferred_base);
            self.checkLoopScoped(&edge, loop.binding_base);
            if (self.issue != null) return;
            edge.trimTo(loop.binding_base, loop.root_base, loop.deferred_base, loop.next_owner_id);
            try self.appendLoopEntry(&loop.breaks, &edge);
        }

        fn loopBody(self: *Checker, state: *State, body: []const sir.Stmt, can_skip: bool, item: ?struct { name: []const u8, type_id: ?types.TypeId, binding_id: ?identity.BindingId }) error{OutOfMemory}!bool {
            var entries: std.ArrayListUnmanaged(State) = .empty;
            defer {
                for (entries.items) |*entry| entry.deinit();
                entries.deinit(self.allocator);
            }
            try self.appendLoopEntry(&entries, state);
            var has_exit = can_skip;
            var index: usize = 0;
            while (index < entries.items.len and self.issue == null) : (index += 1) {
                const entry = &entries.items[index];
                if (can_skip) state.joinLive(entry);
                var body_state = try entry.clone();
                defer body_state.deinit();
                var edges = LoopEdges{
                    .parent = self.current_loop,
                    .binding_base = entry.bindings.items.len,
                    .root_base = entry.roots.items.len,
                    .deferred_base = entry.deferred.items.len,
                    .next_owner_id = entry.next_owner_id,
                };
                defer edges.deinit(self.allocator);
                if (item) |binding| {
                    const id = try body_state.addTypedRoot(binding.name, binding.binding_id, binding.type_id);
                    try self.addBindings(&body_state, .{ .name = binding.name, .id = id }, binding.type_id, "");
                }
                self.current_loop = &edges;
                const body_falls = self.block(&body_state, body) catch |err| {
                    self.current_loop = edges.parent;
                    return err;
                };
                self.current_loop = edges.parent;
                if (body_falls) {
                    self.checkLoopScoped(&body_state, edges.binding_base);
                    if (self.issue != null) break;
                    body_state.trimTo(edges.binding_base, edges.root_base, edges.deferred_base, edges.next_owner_id);
                    try self.appendLoopEntry(&entries, &body_state);
                }
                for (edges.states.items) |*edge| try self.appendLoopEntry(&entries, edge);
                for (edges.breaks.items) |*edge| {
                    if (has_exit) state.joinLive(edge) else {
                        const copy = try edge.clone();
                        state.deinit();
                        state.* = copy;
                    }
                    has_exit = true;
                }
            }
            return has_exit;
        }

        fn block(self: *Checker, state: *State, stmts: []const sir.Stmt) error{OutOfMemory}!bool {
            const base = state.bindings.items.len;
            const root_base = state.roots.items.len;
            const deferred_base = state.deferred.items.len;
            var falls_through = true;
            for (stmts) |stmt| {
                if (!falls_through or self.issue != null) break;
                if (stmtPropagates(stmt) or stmt == .@"try") {
                    var error_state = try state.clone();
                    defer error_state.deinit();
                    try self.runDeferred(&error_state, 0);
                    if (error_state.live()) |name| {
                        self.fail(name);
                        break;
                    }
                }
                switch (stmt) {
                    .local => |local| {
                        try self.transferCallArguments(state, local.init);
                        const prior_len = state.bindings.items.len;
                        const checked_binding: ?identity.BindingId = if (local.checked_effect) |record| blk: {
                            const destination = record.effect.move.destination.place;
                            break :blk destination.root.binding;
                        } else null;
                        const binding_id = checked_binding orelse local.binding_id;
                        const new_root = Root{ .name = local.name, .id = State.identityRootId(binding_id, state.next_owner_id), .binding_id = binding_id, .type_id = local.type_id };
                        try self.addBindings(state, new_root, local.type_id, "");
                        if (state.bindings.items.len > prior_len) {
                            try self.consumeValueSource(state, local.init);
                        }
                        if (self.issue != null) break;
                        _ = try state.addTypedRoot(local.name, binding_id, local.type_id);
                    },
                    .assign => |assign| {
                        const destination = if (assign.checked_transfer) |record| blk: {
                            const subject = record.effect.move.destination;
                            if (subject == .place and subject.place.root == .binding)
                                break :blk state.findBindingRoot(subject.place.root.binding);
                            break :blk null;
                        } else if (assign.binding_id) |id| state.findBindingRoot(id) else state.findRoot(assign.name);
                        const root = destination orelse continue;
                        var has_obligation_slot = false;
                        for (state.bindings.items) |binding| {
                            if (!State.withinRoot(root, binding)) continue;
                            has_obligation_slot = true;
                            if (binding.live) {
                                self.fail(root.name);
                                break;
                            }
                        }
                        if (self.issue != null) break;
                        try self.transferCallArguments(state, assign.value);
                        try self.consumeValueSource(state, assign.value);
                        if (self.issue != null) break;
                        if (try self.returnCarriesOwner(self.exprType(assign.value))) {
                            if (has_obligation_slot) {
                                for (state.bindings.items) |*binding| if (State.withinRoot(root, binding.*)) {
                                    binding.live = true;
                                };
                            } else try self.addBindings(state, root, self.exprType(assign.value), "");
                        }
                    },
                    .field_assign => |assign| {
                        const place = try self.fieldAssignPlace(state, assign) orelse {
                            if (try self.returnCarriesOwner(self.exprType(assign.value))) self.fail(assign.root_name);
                            if (assign.root_binding_id) |id| if (state.findBindingRoot(id)) |root| {
                                for (state.bindings.items) |binding| if (binding.live and State.withinRoot(root, binding)) {
                                    self.fail(root.name);
                                };
                            };
                            continue;
                        };
                        var target = place.root;
                        target.path_prefix = place.path;
                        if (assign.capture != null) {
                            try self.transferCallArguments(state, assign.value);
                            try self.consumeValueSource(state, assign.value);
                            if (self.issue != null) break;
                        }
                        if (assign.capture) |capture| {
                            const captured_root_id = try state.addTypedRoot(capture.name, capture.binding_id, capture.type_id);
                            const original_len = state.bindings.items.len;
                            for (0..original_len) |index| {
                                const binding = state.bindings.items[index];
                                if (!State.withinRoot(target, binding)) continue;
                                const suffix = binding.field_path[target.path_prefix.len..];
                                state.bindings.items[index].live = false;
                                try state.bindings.append(self.allocator, .{
                                    .owner_id = captured_root_id,
                                    .name = capture.name,
                                    .field_path = if (std.mem.startsWith(u8, suffix, ".")) suffix[1..] else suffix,
                                    .live = binding.live,
                                });
                            }
                        }
                        var has_obligation_slot = false;
                        for (state.bindings.items) |binding| {
                            if (!State.withinRoot(target, binding)) continue;
                            has_obligation_slot = true;
                            if (binding.live) {
                                self.fail(target.name);
                                break;
                            }
                        }
                        if (self.issue != null) break;
                        if (assign.capture == null) {
                            try self.transferCallArguments(state, assign.value);
                            try self.consumeValueSource(state, assign.value);
                            if (self.issue != null) break;
                        }
                        if (try self.returnCarriesOwner(self.exprType(assign.value))) {
                            if (has_obligation_slot) {
                                for (state.bindings.items) |*binding| if (State.withinRoot(target, binding.*)) {
                                    binding.live = true;
                                };
                            } else try self.addBindings(state, target, self.exprType(assign.value), place.path);
                        }
                    },
                    .index_assign => |assign| {
                        const object_place = try self.receiverPlace(state, assign.object);
                        const owner_value = try self.returnCarriesOwner(self.exprType(assign.value));
                        const fixed_index = if (assign.index.* == .int and assign.index.int.value >= 0) assign.index.int.value else null;
                        if (object_place == null or fixed_index == null) {
                            if (owner_value) self.fail("<indexed place>");
                            if (object_place) |place| {
                                var scope = place.root;
                                scope.path_prefix = place.path;
                                for (state.bindings.items) |binding| if (binding.live and State.withinRoot(scope, binding)) {
                                    self.fail(scope.name);
                                };
                            }
                            continue;
                        }
                        const object = object_place.?;
                        const path = try std.fmt.allocPrint(self.allocator, "{s}[{d}]", .{ object.path, fixed_index.? });
                        var target = object.root;
                        target.path_prefix = path;
                        var has_obligation_slot = false;
                        for (state.bindings.items) |binding| {
                            if (!State.withinRoot(target, binding)) continue;
                            has_obligation_slot = true;
                            if (binding.live) self.fail(target.name);
                        }
                        if (self.issue != null) break;
                        if (owner_value and !has_obligation_slot) {
                            self.fail(target.name);
                            break;
                        }
                        try self.transferCallArguments(state, assign.value);
                        try self.consumeValueSource(state, assign.value);
                        if (self.issue != null) break;
                        if (owner_value) for (state.bindings.items) |*binding| if (State.withinRoot(target, binding.*)) {
                            binding.live = true;
                        };
                    },
                    .expr => |expr| {
                        try self.transferCallArguments(state, expr);
                        if (try self.returnCarriesOwner(self.exprType(expr))) self.fail("<temporary>");
                    },
                    .@"defer" => |expr| try state.deferred.append(self.allocator, expr),
                    .drop => |drop| {
                        const root = state.findRoot(drop.name) orelse continue;
                        for (state.bindings.items) |binding| {
                            if (binding.live and State.withinRoot(root, binding)) self.fail(drop.name);
                        }
                    },
                    .@"return" => |value| {
                        if (value) |expr| {
                            try self.transferCallArguments(state, expr);
                            try self.transferReturn(state, expr);
                        }
                        try self.runDeferred(state, 0);
                        if (state.live()) |name| self.fail(name);
                        falls_through = false;
                    },
                    .@"try" => {},
                    .@"continue" => {
                        try self.recordContinue(state);
                        falls_through = false;
                    },
                    .@"break" => {
                        try self.recordBreak(state);
                        falls_through = false;
                    },
                    .@"if" => |branch| {
                        try self.transferCallArguments(state, branch.condition);
                        var then_state = try state.clone();
                        defer then_state.deinit();
                        var else_state = try state.clone();
                        defer else_state.deinit();
                        var capture_attached = false;
                        if (branch.kind == .optional_some or branch.kind == .optional_none or (branch.kind == .union_case and branch.case_name != null)) {
                            if (try self.captureReceiverPlace(state, branch.condition, if (branch.capture_path) |path| path.source else null)) |place| {
                                const source = place.root;
                                const place_path = place.path;
                                const case_name = self.checkedCaseName(if (branch.capture_path) |path| path.active_case else null, if (branch.kind == .union_case) branch.case_name.? else "some");
                                const payload_path = try self.appendPath(place_path, case_name);
                                const payload_root = Root{ .name = branch.capture_name orelse "", .id = source.id, .binding_id = branch.capture_binding_id, .path_prefix = payload_path };
                                const capture_state = if (branch.kind == .optional_none) &else_state else &then_state;
                                const empty_state = if (branch.kind == .optional_none) &then_state else &else_state;
                                if (branch.capture_name != null) {
                                    try capture_state.roots.append(self.allocator, payload_root);
                                    capture_attached = true;
                                }
                                for (empty_state.bindings.items) |*binding| {
                                    if (State.withinRoot(payload_root, binding.*)) binding.live = false;
                                }
                                if (branch.kind == .union_case) {
                                    const union_root = Root{ .name = source.name, .id = source.id, .path_prefix = place_path };
                                    for (then_state.bindings.items) |*binding| {
                                        if (State.withinRoot(union_root, binding.*) and !State.withinRoot(payload_root, binding.*)) binding.live = false;
                                    }
                                }
                            }
                        }
                        if (!capture_attached) if (branch.capture_name) |name| {
                            const capture_state = if (branch.kind == .optional_none) &else_state else &then_state;
                            const root_id = if (self.captureTemporaryId(if (branch.capture_path) |path| path.source else null, branch.condition)) |temporary_id|
                                try capture_state.addTemporaryRoot(name, branch.capture_binding_id, temporary_id)
                            else
                                try capture_state.addTypedRoot(name, branch.capture_binding_id, branch.capture_type_id);
                            try self.addBindings(capture_state, .{ .name = name, .id = root_id }, branch.capture_type_id, "");
                        };
                        const then_falls = try self.block(&then_state, branch.then_body);
                        const else_falls = try self.block(&else_state, branch.else_body);
                        if (then_falls) self.checkLoopScoped(&then_state, state.bindings.items.len);
                        if (else_falls) self.checkLoopScoped(&else_state, state.bindings.items.len);
                        for (state.bindings.items, 0..) |*binding, index| {
                            binding.live = (then_falls and then_state.bindings.items[index].live) or
                                (else_falls and else_state.bindings.items[index].live);
                        }
                        falls_through = then_falls or else_falls;
                    },
                    .@"switch" => |branch| {
                        try self.transferCallArguments(state, branch.value);
                        const union_decl = self.unionDecl(branch.subject_decl_id);
                        const subject_origin: ?sir.CheckedCaptureOrigin = for (branch.cases) |case| {
                            if (case.payload_path) |path| if (path.source) |origin| break origin;
                        } else null;
                        const subject_place = if (union_decl != null) try self.captureReceiverPlace(state, branch.value, subject_origin) else null;
                        const subject_root: ?Root = if (subject_place) |place| .{
                            .name = place.root.name,
                            .id = place.root.id,
                            .path_prefix = place.path,
                        } else null;
                        const baseline = try state.clone();
                        defer {
                            var copy = baseline;
                            copy.deinit();
                        }
                        var merged = try state.clone();
                        defer merged.deinit();
                        for (merged.bindings.items) |*binding| binding.live = false;
                        var any_falls = false;
                        var has_ok = false;
                        var has_err = false;
                        for (branch.cases) |case| {
                            if (case.result_case) |kind| {
                                if (kind == .ok) has_ok = true else has_err = true;
                            }
                            var case_state = try baseline.clone();
                            defer case_state.deinit();
                            if (union_decl != null) {
                                if (subject_root) |scope| {
                                    const case_root = Root{ .name = case.payload_name orelse "", .id = scope.id, .binding_id = case.payload_binding_id, .path_prefix = try self.appendPath(scope.path_prefix, self.checkedCaseName(if (case.payload_path) |path| path.active_case else null, case.case_name)) };
                                    clearUnionAlternatives(&case_state, scope, case_root);
                                    if (case.payload_name != null) try case_state.roots.append(self.allocator, case_root);
                                } else if (case.payload_name) |name| {
                                    const root_id = if (self.captureTemporaryId(if (case.payload_path) |path| path.source else null, branch.value)) |temporary_id|
                                        try case_state.addTemporaryRoot(name, case.payload_binding_id, temporary_id)
                                    else
                                        try case_state.addTypedRoot(name, case.payload_binding_id, case.payload_type_id);
                                    try self.addBindings(&case_state, .{ .name = name, .id = root_id }, case.payload_type_id, "");
                                }
                            } else if (case.payload_name) |name| {
                                const root_id = if (self.captureTemporaryId(if (case.payload_path) |path| path.source else null, branch.value)) |temporary_id|
                                    try case_state.addTemporaryRoot(name, case.payload_binding_id, temporary_id)
                                else
                                    try case_state.addTypedRoot(name, case.payload_binding_id, case.payload_type_id);
                                if (case.result_case == .ok) {
                                    try self.addBindings(&case_state, .{ .name = name, .id = root_id }, case.payload_type_id, "");
                                }
                            }
                            const case_falls = try self.block(&case_state, case.body);
                            if (case_falls) {
                                for (case_state.bindings.items[baseline.bindings.items.len..]) |binding| {
                                    if (binding.live) self.fail(binding.name);
                                }
                            }
                            if (case_falls) {
                                any_falls = true;
                                for (merged.bindings.items, 0..) |*binding, index| {
                                    binding.live = binding.live or case_state.bindings.items[index].live;
                                }
                            }
                        }
                        if (branch.has_else) {
                            var else_state = try baseline.clone();
                            defer else_state.deinit();
                            if (union_decl != null) if (subject_root) |scope| {
                                for (branch.cases) |case| {
                                    const selected = Root{ .name = case.case_name, .id = scope.id, .path_prefix = try self.appendPath(scope.path_prefix, case.case_name) };
                                    for (else_state.bindings.items) |*binding| if (State.withinRoot(selected, binding.*)) {
                                        binding.live = false;
                                    };
                                }
                            };
                            const else_falls = try self.block(&else_state, branch.else_body);
                            if (else_falls) {
                                any_falls = true;
                                for (merged.bindings.items, 0..) |*binding, index| {
                                    binding.live = binding.live or else_state.bindings.items[index].live;
                                }
                            }
                        } else if (union_decl) |decl| {
                            var uncovered = try baseline.clone();
                            defer uncovered.deinit();
                            if (subject_root) |scope| {
                                for (branch.cases) |case| {
                                    const selected = Root{ .name = case.case_name, .id = scope.id, .path_prefix = try self.appendPath(scope.path_prefix, case.case_name) };
                                    for (uncovered.bindings.items) |*binding| if (State.withinRoot(selected, binding.*)) {
                                        binding.live = false;
                                    };
                                }
                            }
                            var exhaustive = true;
                            for (decl.fields) |field| {
                                const covered = for (branch.cases) |case| {
                                    if (std.mem.eql(u8, field.name, case.case_name)) break true;
                                } else false;
                                if (!covered) exhaustive = false;
                            }
                            if (!exhaustive) {
                                any_falls = true;
                                for (merged.bindings.items, uncovered.bindings.items) |*binding, remaining| binding.live = binding.live or remaining.live;
                            }
                        } else if (!(has_ok and has_err)) {
                            any_falls = true;
                            for (merged.bindings.items, 0..) |*binding, index| {
                                binding.live = binding.live or baseline.bindings.items[index].live;
                            }
                        }
                        for (state.bindings.items, merged.bindings.items) |*binding, result| binding.live = result.live;
                        falls_through = any_falls;
                    },
                    .unchecked => |body| {
                        falls_through = try self.block(state, body);
                    },
                    .using_alloc => |using_alloc| {
                        // Allocator scopes do not change ownership or settlement
                        // obligations. Traverse their body exactly like the other
                        // transparent statement blocks.
                        falls_through = try self.block(state, using_alloc.body);
                    },
                    .@"while" => |loop| {
                        if (loop.condition.* == .bool and !loop.condition.bool) continue;
                        falls_through = try self.loopBody(state, loop.body, !(loop.condition.* == .bool and loop.condition.bool), null);
                    },
                    .@"for" => |loop| {
                        _ = try self.loopBody(state, loop.body, true, .{ .name = loop.name, .type_id = loop.item_type_id, .binding_id = loop.binding_id });
                    },
                    else => {},
                }
            }
            if (falls_through) {
                try self.runDeferred(state, deferred_base);
                for (state.bindings.items[base..]) |binding| {
                    if (binding.live) self.fail(binding.name);
                }
            }
            state.deferred.shrinkRetainingCapacity(deferred_base);
            state.bindings.shrinkRetainingCapacity(base);
            state.roots.shrinkRetainingCapacity(root_base);
            return falls_through;
        }
    };

    pub fn check(
        allocator: std.mem.Allocator,
        interner: *const types.TypeInterner,
        structs: []const sir.StructDecl,
        unions: []const sir.UnionDecl,
        functions: []const sir.Function,
        metadata: []const sir.ExprMetadataEntry,
        contract: Contract,
    ) !?Issue {
        try validateContract(interner, functions, contract);
        for (functions) |function| {
            if (function.is_extern or std.mem.eql(u8, function.module_name, "std.thread")) continue;
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const scratch = arena.allocator();
            var checker = Checker{ .allocator = scratch, .interner = interner, .structs = structs, .unions = unions, .metadata = metadata, .contract = contract, .function = function };
            var state = State{ .allocator = scratch };
            defer state.deinit();
            for (function.params) |param| {
                const root_id = try state.addTypedRoot(param.name, param.binding_id, param.type_id);
                try checker.addBindings(&state, .{ .name = param.name, .id = root_id, .binding_id = param.binding_id }, param.type_id, "");
            }
            const falls_through = try checker.block(&state, function.body);
            if (checker.issue) |issue| return issue;
            if (falls_through) if (state.live()) |name| return .{ .function = function, .owner = name };
        }
        return null;
    }

    test "settlement roots identify the nearest lexical binding" {
        var state = State{ .allocator = std.testing.allocator };
        defer state.deinit();
        const outer = try state.addRoot("group", null);
        try state.bindings.append(std.testing.allocator, .{ .owner_id = outer, .name = "group" });
        const outer_root = state.findRoot("group").?;
        try std.testing.expect(state.find(outer_root, "") != null);
        const inner = try state.addRoot("group", null);
        try std.testing.expect(inner != outer);
        const inner_root = state.findRoot("group").?;
        try std.testing.expect(state.find(inner_root, "") == null);
        try std.testing.expect(state.find(outer_root, "") != null);
        state.consumeRoot("group");
        try std.testing.expect(state.bindings.items[0].live);
        state.roots.shrinkRetainingCapacity(1);
        state.consumeRoot("group");
        try std.testing.expect(!state.bindings.items[0].live);
    }

    test "settlement roots preserve checked binding IDs apart from synthetic captures" {
        var state = State{ .allocator = std.testing.allocator };
        defer state.deinit();
        const checked: identity.BindingId = @fromBackingInt(@intCast(7));
        const checked_root = try state.addRoot("group", checked);
        try std.testing.expectEqual(@as(usize, 7), checked_root);
        const synthetic_root = try state.addRoot("group", null);
        try std.testing.expect(checked_root != synthetic_root);
        try std.testing.expectEqual(synthetic_root, state.findRoot("group").?.id);
        const capture_id: identity.BindingId = @fromBackingInt(@intCast(8));
        try state.roots.append(std.testing.allocator, .{ .name = "item", .id = checked_root, .binding_id = capture_id, .path_prefix = "some" });
        const captured = state.findRoot("item").?;
        try std.testing.expectEqual(capture_id, captured.binding_id.?);
        try std.testing.expectEqual(checked_root, captured.id);
    }

    test "settlement receiver uses checked binding identity across shadowing" {
        var interner = types.TypeInterner.init(std.testing.allocator);
        defer interner.deinit();
        const field_type = try interner.intern(.{ .primitive = .void });
        var state = State{ .allocator = std.testing.allocator };
        defer state.deinit();
        const outer_binding: identity.BindingId = @fromBackingInt(@intCast(10));
        const inner_binding: identity.BindingId = @fromBackingInt(@intCast(11));
        const outer = try state.addRoot("group", outer_binding);
        _ = try state.addRoot("group", inner_binding);
        var expr = sir.Expr{ .local = "group" };
        const projections = [_]sir.CheckedPlaceProjection{.{
            .step = .{ .field = .{ .owner_decl_id = @fromBackingInt(@intCast(12)), .name = "slot" } },
            .result_type_id = field_type,
        }};
        var metadata = [_]sir.ExprMetadataEntry{.{
            .expr = &expr,
            .metadata = .{
                .type_id = field_type,
                .semantics = std.mem.zeroes(sir.ValueSemantics),
                .checked_place_root = .{ .binding = outer_binding },
                .checked_place_projections = &projections,
            },
        }};
        var checker = Checker{
            .allocator = std.testing.allocator,
            .interner = &interner,
            .structs = &.{},
            .unions = &.{},
            .metadata = &metadata,
            .contract = .{ .owner_type = @fromBackingInt(@intCast(1)), .terminal_primary = @fromBackingInt(@intCast(2)), .terminal_secondary = @fromBackingInt(@intCast(3)) },
            .function = .{ .owner = null, .name = "test", .params = &.{}, .body = &.{} },
        };
        const place = (try checker.receiverPlace(&state, &expr)).?;
        try std.testing.expectEqual(outer, place.root.id);
        try std.testing.expectEqual(outer_binding, place.root.binding_id.?);
        try std.testing.expectEqualStrings("slot", place.path);
        try state.bindings.append(std.testing.allocator, .{ .owner_id = outer, .name = "group", .field_path = "slot" });
        try state.bindings.append(std.testing.allocator, .{ .owner_id = state.findBindingRoot(inner_binding).?.id, .name = "group", .field_path = "slot" });
        try checker.consumeExprPlace(&state, &expr);
        try std.testing.expect(!state.bindings.items[0].live);
        try std.testing.expect(state.bindings.items[1].live);
        const capture_place = (try checker.captureReceiverPlace(&state, &expr, .{ .place = .{
            .root = .{ .binding = outer_binding },
            .projections = &projections,
            .non_owning = false,
        } })).?;
        try std.testing.expectEqual(outer, capture_place.root.id);
        try std.testing.expectEqualStrings("slot", capture_place.path);
        try std.testing.expect((try checker.captureReceiverPlace(&state, &expr, .{ .place = .{
            .root = .{ .binding = outer_binding },
            .projections = &projections,
            .non_owning = true,
        } })) == null);
        metadata[0].metadata.non_owning_place_origin = true;
        try std.testing.expect((try checker.receiverPlace(&state, &expr)) == null);
    }

    test "settlement assignment rejects live replacement and moves checked source" {
        const allocator = std.testing.allocator;
        var interner = types.TypeInterner.init(allocator);
        defer interner.deinit();
        const owner_decl: identity.DeclId = @fromBackingInt(@intCast(51));
        const owner_type = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = owner_decl } });
        const target_id: identity.BindingId = @fromBackingInt(@intCast(61));
        const source_id: identity.BindingId = @fromBackingInt(@intCast(62));
        var source = sir.Expr{ .local = "group" };
        const statements = [_]sir.Stmt{.{ .assign = .{ .name = "group", .binding_id = target_id, .value = &source } }};
        const metadata = [_]sir.ExprMetadataEntry{.{
            .expr = &source,
            .metadata = .{ .type_id = owner_type, .semantics = std.mem.zeroes(sir.ValueSemantics), .checked_place_root = .{ .binding = source_id } },
        }};
        var state = State{ .allocator = allocator };
        defer state.deinit();
        const target_root = try state.addRoot("group", target_id);
        const source_root = try state.addRoot("group", source_id);
        try state.bindings.append(allocator, .{ .owner_id = target_root, .name = "target" });
        try state.bindings.append(allocator, .{ .owner_id = source_root, .name = "source" });
        var checker = Checker{
            .allocator = allocator,
            .interner = &interner,
            .structs = &.{},
            .unions = &.{},
            .metadata = &metadata,
            .contract = .{ .owner_type = owner_decl, .terminal_primary = @fromBackingInt(@intCast(52)), .terminal_secondary = @fromBackingInt(@intCast(53)) },
            .function = .{ .owner = null, .name = "replace", .params = &.{}, .body = &statements },
        };
        _ = try checker.block(&state, &statements);
        try std.testing.expectEqualStrings("group", checker.issue.?.owner);
        try std.testing.expect(state.bindings.items[0].live);
        try std.testing.expect(state.bindings.items[1].live);

        checker.issue = null;
        state.bindings.items[0].live = false;
        _ = try checker.block(&state, &statements);
        try std.testing.expect(state.bindings.items[0].live);
        try std.testing.expect(!state.bindings.items[1].live);
    }

    test "settlement field assignment uses checked root and field path" {
        const allocator = std.testing.allocator;
        var interner = types.TypeInterner.init(allocator);
        defer interner.deinit();
        const owner_decl: identity.DeclId = @fromBackingInt(@intCast(71));
        const holder_decl: identity.DeclId = @fromBackingInt(@intCast(72));
        const wrong_decl: identity.DeclId = @fromBackingInt(@intCast(75));
        const owner_type = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = owner_decl } });
        const holder_type = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = holder_decl } });
        const target_id: identity.BindingId = @fromBackingInt(@intCast(81));
        const source_id: identity.BindingId = @fromBackingInt(@intCast(82));
        const fields = [_]sir.FieldDecl{.{ .name = "group", .type_id = owner_type }};
        const structs = [_]sir.StructDecl{
            .{ .decl_id = holder_decl, .name = "Holder", .layout = .normal, .fields = &fields },
            .{ .decl_id = wrong_decl, .name = "Wrong", .layout = .normal, .fields = &fields },
        };
        var steps = [_]sir.StructFieldPathStep{.{ .struct_decl_id = holder_decl, .struct_name = "Holder", .field = "group" }};
        var source = sir.Expr{ .local = "group" };
        const statements = [_]sir.Stmt{.{ .field_assign = .{ .root_name = "holder", .root_binding_id = target_id, .steps = &steps, .value = &source } }};
        const metadata = [_]sir.ExprMetadataEntry{.{
            .expr = &source,
            .metadata = .{ .type_id = owner_type, .semantics = std.mem.zeroes(sir.ValueSemantics), .checked_place_root = .{ .binding = source_id } },
        }};
        var state = State{ .allocator = allocator };
        defer state.deinit();
        const target_root = try state.addTypedRoot("holder", target_id, holder_type);
        const source_root = try state.addRoot("group", source_id);
        try state.bindings.append(allocator, .{ .owner_id = target_root, .name = "holder", .field_path = "group" });
        try state.bindings.append(allocator, .{ .owner_id = source_root, .name = "group" });
        var checker = Checker{
            .allocator = allocator,
            .interner = &interner,
            .structs = &structs,
            .unions = &.{},
            .metadata = &metadata,
            .contract = .{ .owner_type = owner_decl, .terminal_primary = @fromBackingInt(@intCast(73)), .terminal_secondary = @fromBackingInt(@intCast(74)) },
            .function = .{ .owner = null, .name = "replace", .params = &.{}, .body = &statements },
        };
        _ = try checker.block(&state, &statements);
        try std.testing.expect(checker.issue != null);
        try std.testing.expect(state.bindings.items[0].live and state.bindings.items[1].live);
        checker.issue = null;
        state.bindings.items[0].live = false;
        _ = try checker.block(&state, &statements);
        try std.testing.expect(state.bindings.items[0].live);
        try std.testing.expect(!state.bindings.items[1].live);

        checker.issue = null;
        state.bindings.items[0].live = false;
        state.bindings.items[1].live = true;
        steps[0].struct_decl_id = @fromBackingInt(@intCast(999));
        _ = try checker.block(&state, &statements);
        try std.testing.expect(checker.issue != null);
        try std.testing.expect(!state.bindings.items[0].live);
        try std.testing.expect(state.bindings.items[1].live);

        checker.issue = null;
        steps[0].struct_decl_id = wrong_decl;
        _ = try checker.block(&state, &statements);
        try std.testing.expect(checker.issue != null);
        try std.testing.expect(!state.bindings.items[0].live);
        try std.testing.expect(state.bindings.items[1].live);
    }

    test "settlement field capture moves the old obligation to its binding" {
        const allocator = std.testing.allocator;
        var interner = types.TypeInterner.init(allocator);
        defer interner.deinit();
        const owner_decl: identity.DeclId = @fromBackingInt(@intCast(171));
        const holder_decl: identity.DeclId = @fromBackingInt(@intCast(172));
        const owner_type = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = owner_decl } });
        const holder_type = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = holder_decl } });
        const target_id: identity.BindingId = @fromBackingInt(@intCast(181));
        const source_id: identity.BindingId = @fromBackingInt(@intCast(182));
        const capture_id: identity.BindingId = @fromBackingInt(@intCast(183));
        const fields = [_]sir.FieldDecl{.{ .name = "group", .type_id = owner_type }};
        const structs = [_]sir.StructDecl{.{ .decl_id = holder_decl, .name = "Holder", .layout = .normal, .fields = &fields }};
        const steps = [_]sir.StructFieldPathStep{.{ .struct_decl_id = holder_decl, .struct_name = "Holder", .field = "group" }};
        var source = sir.Expr{ .local = "source" };
        const statements = [_]sir.Stmt{.{ .field_assign = .{
            .root_name = "holder",
            .root_binding_id = target_id,
            .steps = &steps,
            .value = &source,
            .capture = .{ .name = "old", .binding_id = capture_id, .type_id = owner_type, .is_mutable = false },
        } }};
        const metadata = [_]sir.ExprMetadataEntry{.{
            .expr = &source,
            .metadata = .{ .type_id = owner_type, .semantics = std.mem.zeroes(sir.ValueSemantics), .checked_place_root = .{ .binding = source_id } },
        }};
        var state = State{ .allocator = allocator };
        defer state.deinit();
        const target_root = try state.addTypedRoot("holder", target_id, holder_type);
        const source_root = try state.addRoot("source", source_id);
        try state.bindings.append(allocator, .{ .owner_id = target_root, .name = "holder", .field_path = "group" });
        try state.bindings.append(allocator, .{ .owner_id = source_root, .name = "source" });
        var checker = Checker{
            .allocator = allocator,
            .interner = &interner,
            .structs = &structs,
            .unions = &.{},
            .metadata = &metadata,
            .contract = .{ .owner_type = owner_decl, .terminal_primary = @fromBackingInt(@intCast(173)), .terminal_secondary = @fromBackingInt(@intCast(174)) },
            .function = .{ .owner = null, .name = "replace", .params = &.{}, .body = &statements },
        };
        _ = try checker.block(&state, &statements);
        try std.testing.expect(checker.issue != null);
        try std.testing.expectEqualStrings("old", checker.issue.?.owner);
        try std.testing.expect(state.bindings.items[0].live);
        try std.testing.expect(!state.bindings.items[1].live);
    }

    test "settlement rejects a discontinuous checked field path" {
        const allocator = std.testing.allocator;
        var interner = types.TypeInterner.init(allocator);
        defer interner.deinit();
        const outer_id: identity.DeclId = @fromBackingInt(@intCast(91));
        const inner_id: identity.DeclId = @fromBackingInt(@intCast(92));
        const wrong_id: identity.DeclId = @fromBackingInt(@intCast(93));
        const inner_type = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = inner_id } });
        const outer_fields = [_]sir.FieldDecl{.{ .name = "inner", .type_id = inner_type }};
        const wrong_fields = [_]sir.FieldDecl{.{ .name = "group", .type_id = inner_type }};
        const structs = [_]sir.StructDecl{
            .{ .decl_id = outer_id, .name = "Outer", .layout = .normal, .fields = &outer_fields },
            .{ .decl_id = wrong_id, .name = "Wrong", .layout = .normal, .fields = &wrong_fields },
        };
        const root_id: identity.BindingId = @fromBackingInt(@intCast(94));
        const steps = [_]sir.StructFieldPathStep{
            .{ .struct_decl_id = outer_id, .struct_name = "Outer", .field = "inner" },
            .{ .struct_decl_id = wrong_id, .struct_name = "Wrong", .field = "group" },
        };
        var value = sir.Expr{ .local = "source" };
        var state = State{ .allocator = allocator };
        defer state.deinit();
        _ = try state.addRoot("outer", root_id);
        var checker = Checker{
            .allocator = allocator,
            .interner = &interner,
            .structs = &structs,
            .unions = &.{},
            .metadata = &.{},
            .contract = .{ .owner_type = inner_id, .terminal_primary = @fromBackingInt(@intCast(95)), .terminal_secondary = @fromBackingInt(@intCast(96)) },
            .function = .{ .owner = null, .name = "replace", .params = &.{}, .body = &.{} },
        };
        try std.testing.expect((try checker.fieldAssignPlace(&state, .{ .root_name = "outer", .root_binding_id = root_id, .steps = &steps, .value = &value })) == null);
    }

    test "settlement indexed assignment transfers only a checked fixed slot" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var interner = types.TypeInterner.init(allocator);
        defer interner.deinit();
        const owner_decl: identity.DeclId = @fromBackingInt(@intCast(101));
        const owner_type = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = owner_decl } });
        const array_type = try interner.intern(.{ .array = .{ .len = 2, .item = owner_type } });
        const array_id: identity.BindingId = @fromBackingInt(@intCast(102));
        const source_id: identity.BindingId = @fromBackingInt(@intCast(103));
        var object = sir.Expr{ .local = "items" };
        var index = sir.Expr{ .int = .{ .value = 0, .type_name = null } };
        var source = sir.Expr{ .local = "group" };
        const statements = [_]sir.Stmt{.{ .index_assign = .{ .object = &object, .index = &index, .value = &source } }};
        const metadata = [_]sir.ExprMetadataEntry{
            .{ .expr = &object, .metadata = .{ .type_id = array_type, .semantics = std.mem.zeroes(sir.ValueSemantics), .checked_place_root = .{ .binding = array_id } } },
            .{ .expr = &source, .metadata = .{ .type_id = owner_type, .semantics = std.mem.zeroes(sir.ValueSemantics), .checked_place_root = .{ .binding = source_id } } },
        };
        var state = State{ .allocator = allocator };
        defer state.deinit();
        const array_root = try state.addTypedRoot("items", array_id, array_type);
        const source_root = try state.addTypedRoot("group", source_id, owner_type);
        try state.bindings.append(allocator, .{ .owner_id = array_root, .name = "items", .field_path = "[0]" });
        try state.bindings.append(allocator, .{ .owner_id = array_root, .name = "items", .field_path = "[1]" });
        try state.bindings.append(allocator, .{ .owner_id = source_root, .name = "group" });
        var checker = Checker{
            .allocator = allocator,
            .interner = &interner,
            .structs = &.{},
            .unions = &.{},
            .metadata = &metadata,
            .contract = .{ .owner_type = owner_decl, .terminal_primary = @fromBackingInt(@intCast(104)), .terminal_secondary = @fromBackingInt(@intCast(105)) },
            .function = .{ .owner = null, .name = "replace", .params = &.{}, .body = &statements },
        };
        _ = try checker.block(&state, &statements);
        try std.testing.expect(checker.issue != null);
        try std.testing.expect(state.bindings.items[0].live and state.bindings.items[1].live and state.bindings.items[2].live);
        checker.issue = null;
        state.bindings.items[0].live = false;
        _ = try checker.block(&state, &statements);
        try std.testing.expect(checker.issue == null);
        try std.testing.expect(state.bindings.items[0].live and state.bindings.items[1].live and !state.bindings.items[2].live);

        checker.issue = null;
        state.bindings.items[0].live = false;
        _ = try checker.block(&state, &statements);
        try std.testing.expect(checker.issue != null);
        try std.testing.expect(!state.bindings.items[0].live and state.bindings.items[1].live and !state.bindings.items[2].live);
    }

    test "settlement rejects projected owner call arguments without a detach effect" {
        const allocator = std.testing.allocator;
        var interner = types.TypeInterner.init(allocator);
        defer interner.deinit();
        const owner_decl: identity.DeclId = @fromBackingInt(@intCast(111));
        const owner_type = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = owner_decl } });
        var root = sir.Expr{ .local = "holder" };
        var projected = sir.Expr{ .field = .{ .object = &root, .struct_name = "Holder", .field = "group" } };
        const args = [_]sir.CallArg{.{ .value = &projected }};
        var call = sir.Expr{ .call = .{ .module_name = "", .owner = null, .callee = "accept", .args = &args } };
        const metadata = [_]sir.ExprMetadataEntry{.{
            .expr = &projected,
            .metadata = .{ .type_id = owner_type, .semantics = std.mem.zeroes(sir.ValueSemantics) },
        }};
        var state = State{ .allocator = allocator };
        defer state.deinit();
        var checker = Checker{
            .allocator = allocator,
            .interner = &interner,
            .structs = &.{},
            .unions = &.{},
            .metadata = &metadata,
            .contract = .{ .owner_type = owner_decl, .terminal_primary = @fromBackingInt(@intCast(112)), .terminal_secondary = @fromBackingInt(@intCast(113)) },
            .function = .{ .owner = null, .name = "caller", .params = &.{}, .body = &.{} },
        };
        try checker.transferCallArguments(&state, &call);
        try std.testing.expect(checker.issue != null);
    }

    test "settlement traverses nested aggregate calls in evaluation order" {
        const allocator = std.testing.allocator;
        var interner = types.TypeInterner.init(allocator);
        defer interner.deinit();
        const owner_decl: identity.DeclId = @fromBackingInt(@intCast(301));
        const owner_type = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = owner_decl } });
        const source_id: identity.BindingId = @fromBackingInt(@intCast(302));
        var first_arg = sir.Expr{ .local = "group" };
        var second_arg = sir.Expr{ .local = "group" };
        const first_args = [_]sir.CallArg{.{ .value = &first_arg }};
        const second_args = [_]sir.CallArg{.{ .value = &second_arg }};
        var first_call = sir.Expr{ .call = .{ .decl_id = @fromBackingInt(@intCast(303)), .module_name = "", .owner = null, .callee = "accept", .args = &first_args } };
        var second_call = sir.Expr{ .call = .{ .decl_id = @fromBackingInt(@intCast(303)), .module_name = "", .owner = null, .callee = "accept", .args = &second_args } };
        const fields = [_]sir.StructLiteralField{ .{ .name = "first", .value = &first_call }, .{ .name = "second", .value = &second_call } };
        var aggregate = sir.Expr{ .struct_literal = .{ .type_name = "Pair", .fields = &fields } };
        const metadata = [_]sir.ExprMetadataEntry{
            .{ .expr = &first_arg, .metadata = .{ .type_id = owner_type, .semantics = std.mem.zeroes(sir.ValueSemantics), .checked_place_root = .{ .binding = source_id } } },
            .{ .expr = &second_arg, .metadata = .{ .type_id = owner_type, .semantics = std.mem.zeroes(sir.ValueSemantics), .checked_place_root = .{ .binding = source_id } } },
        };
        var state = State{ .allocator = allocator };
        defer state.deinit();
        const root = try state.addTypedRoot("group", source_id, owner_type);
        try state.bindings.append(allocator, .{ .owner_id = root, .name = "group" });
        var checker = Checker{
            .allocator = allocator,
            .interner = &interner,
            .structs = &.{},
            .unions = &.{},
            .metadata = &metadata,
            .contract = .{ .owner_type = owner_decl, .terminal_primary = @fromBackingInt(@intCast(304)), .terminal_secondary = @fromBackingInt(@intCast(305)) },
            .function = .{ .owner = null, .name = "aggregate", .params = &.{}, .body = &.{} },
        };
        try checker.transferCallArguments(&state, &aggregate);
        try std.testing.expect(checker.issue != null);
        try std.testing.expect(!state.bindings.items[0].live);
        checker.issue = null;
        state.bindings.items[0].live = true;
        first_call.call.args = &.{};
        try checker.transferCallArguments(&state, &aggregate);
        try std.testing.expect(checker.issue == null);
        try std.testing.expect(!state.bindings.items[0].live);
    }

    test "nested trusted terminal call settles its checked receiver once" {
        const allocator = std.testing.allocator;
        var interner = types.TypeInterner.init(allocator);
        defer interner.deinit();
        const owner_decl: identity.DeclId = @fromBackingInt(@intCast(311));
        const owner_type = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = owner_decl } });
        const root_id: identity.BindingId = @fromBackingInt(@intCast(312));
        const terminal_id: identity.DeclId = @fromBackingInt(@intCast(313));
        var receiver = sir.Expr{ .local = "group" };
        const args = [_]sir.CallArg{.{ .value = &receiver }};
        var finish = sir.Expr{ .call = .{ .decl_id = terminal_id, .module_name = "std.thread", .owner = "TaskGroup", .callee = "finish", .args = &args } };
        const fields = [_]sir.StructLiteralField{.{ .name = "done", .value = &finish }};
        var aggregate = sir.Expr{ .struct_literal = .{ .type_name = "Wrapper", .fields = &fields } };
        var metadata = [_]sir.ExprMetadataEntry{.{
            .expr = &receiver,
            .metadata = .{ .type_id = owner_type, .semantics = std.mem.zeroes(sir.ValueSemantics), .checked_place_root = .{ .binding = root_id } },
        }};
        var state = State{ .allocator = allocator };
        defer state.deinit();
        const root = try state.addTypedRoot("group", root_id, owner_type);
        try state.bindings.append(allocator, .{ .owner_id = root, .name = "group" });
        var checker = Checker{
            .allocator = allocator,
            .interner = &interner,
            .structs = &.{},
            .unions = &.{},
            .metadata = &metadata,
            .contract = .{ .owner_type = owner_decl, .terminal_primary = terminal_id, .terminal_secondary = @fromBackingInt(@intCast(314)) },
            .function = .{ .owner = null, .name = "nested_finish", .params = &.{}, .body = &.{} },
        };
        try checker.transferCallArguments(&state, &aggregate);
        try std.testing.expect(checker.issue == null);
        try std.testing.expect(!state.bindings.items[0].live);
        try checker.transferCallArguments(&state, &aggregate);
        try std.testing.expect(checker.issue != null);
        try std.testing.expect(checker.issue.?.kind == .already_settled);
        checker.issue = null;
        state.bindings.items[0].live = true;
        metadata[0].metadata.checked_place_root = .{ .binding = @fromBackingInt(@intCast(315)) };
        try checker.transferCallArguments(&state, &aggregate);
        try std.testing.expect(checker.issue != null);
        try std.testing.expect(state.bindings.items[0].live);
    }

    test "terminal receiver child effects precede settlement" {
        const allocator = std.testing.allocator;
        var interner = types.TypeInterner.init(allocator);
        defer interner.deinit();
        const owner_decl: identity.DeclId = @fromBackingInt(@intCast(321));
        const owner_type = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = owner_decl } });
        const holder_decl: identity.DeclId = @fromBackingInt(@intCast(326));
        const holder_type = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = holder_decl } });
        const root_id: identity.BindingId = @fromBackingInt(@intCast(322));
        const terminal_id: identity.DeclId = @fromBackingInt(@intCast(323));
        var moved = sir.Expr{ .local = "holder" };
        const inner_args = [_]sir.CallArg{.{ .value = &moved }};
        var inner = sir.Expr{ .call = .{ .decl_id = @fromBackingInt(@intCast(324)), .module_name = "", .owner = null, .callee = "consume", .args = &inner_args } };
        var receiver = sir.Expr{ .field = .{ .object = &inner, .struct_name = "Holder", .field = "group" } };
        const outer_args = [_]sir.CallArg{.{ .value = &receiver }};
        var outer = sir.Expr{ .call = .{ .decl_id = terminal_id, .module_name = "std.thread", .owner = "TaskGroup", .callee = "finish", .args = &outer_args } };
        const projections = [_]sir.CheckedPlaceProjection{.{ .step = .{ .field = .{ .owner_decl_id = holder_decl, .name = "group" } }, .result_type_id = owner_type }};
        const metadata = [_]sir.ExprMetadataEntry{
            .{ .expr = &moved, .metadata = .{ .type_id = holder_type, .semantics = std.mem.zeroes(sir.ValueSemantics), .checked_place_root = .{ .binding = root_id } } },
            .{ .expr = &receiver, .metadata = .{ .type_id = owner_type, .semantics = std.mem.zeroes(sir.ValueSemantics), .checked_place_root = .{ .binding = root_id }, .checked_place_projections = &projections } },
        };
        var state = State{ .allocator = allocator };
        defer state.deinit();
        const root = try state.addTypedRoot("holder", root_id, holder_type);
        try state.bindings.append(allocator, .{ .owner_id = root, .name = "holder", .field_path = "group" });
        var checker = Checker{
            .allocator = allocator,
            .interner = &interner,
            .structs = &.{},
            .unions = &.{},
            .metadata = &metadata,
            .contract = .{ .owner_type = owner_decl, .terminal_primary = terminal_id, .terminal_secondary = @fromBackingInt(@intCast(325)) },
            .function = .{ .owner = null, .name = "receiver_order", .params = &.{}, .body = &.{} },
        };
        try checker.transferCallArguments(&state, &outer);
        try std.testing.expect(checker.issue != null);
        try std.testing.expect(checker.issue.?.kind == .already_settled);
        try std.testing.expect(!state.bindings.items[0].live);
    }

    test "print operands preserve nested call transfer order" {
        const allocator = std.testing.allocator;
        var interner = types.TypeInterner.init(allocator);
        defer interner.deinit();
        const owner_decl: identity.DeclId = @fromBackingInt(@intCast(331));
        const owner_type = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = owner_decl } });
        const root_id: identity.BindingId = @fromBackingInt(@intCast(332));
        var first_arg = sir.Expr{ .local = "group" };
        var second_arg = sir.Expr{ .local = "group" };
        const first_args = [_]sir.CallArg{.{ .value = &first_arg }};
        const second_args = [_]sir.CallArg{.{ .value = &second_arg }};
        var first = sir.Expr{ .call = .{ .decl_id = @fromBackingInt(@intCast(333)), .module_name = "", .owner = null, .callee = "consume", .args = &first_args } };
        var second = sir.Expr{ .call = .{ .decl_id = @fromBackingInt(@intCast(333)), .module_name = "", .owner = null, .callee = "consume", .args = &second_args } };
        const parts = [_]sir.BuiltinPrintPart{
            .{ .value = .{ .expr = &first, .format = .direct } },
            .{ .value = .{ .expr = &second, .format = .direct } },
        };
        var print_expr = sir.Expr{ .builtin_print = .{ .parts = &parts, .append_newline = false } };
        const metadata = [_]sir.ExprMetadataEntry{
            .{ .expr = &first_arg, .metadata = .{ .type_id = owner_type, .semantics = std.mem.zeroes(sir.ValueSemantics), .checked_place_root = .{ .binding = root_id } } },
            .{ .expr = &second_arg, .metadata = .{ .type_id = owner_type, .semantics = std.mem.zeroes(sir.ValueSemantics), .checked_place_root = .{ .binding = root_id } } },
        };
        var state = State{ .allocator = allocator };
        defer state.deinit();
        const root = try state.addTypedRoot("group", root_id, owner_type);
        try state.bindings.append(allocator, .{ .owner_id = root, .name = "group" });
        var checker = Checker{
            .allocator = allocator,
            .interner = &interner,
            .structs = &.{},
            .unions = &.{},
            .metadata = &metadata,
            .contract = .{ .owner_type = owner_decl, .terminal_primary = @fromBackingInt(@intCast(334)), .terminal_secondary = @fromBackingInt(@intCast(335)) },
            .function = .{ .owner = null, .name = "print", .params = &.{}, .body = &.{} },
        };
        try checker.transferCallArguments(&state, &print_expr);
        try std.testing.expect(checker.issue != null);
        try std.testing.expect(!state.bindings.items[0].live);
    }

    test "dynamic container items reject owner values before transfer" {
        const allocator = std.testing.allocator;
        var interner = types.TypeInterner.init(allocator);
        defer interner.deinit();
        const owner_decl: identity.DeclId = @fromBackingInt(@intCast(341));
        const owner_type = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = owner_decl } });
        const root_id: identity.BindingId = @fromBackingInt(@intCast(342));
        var object = sir.Expr{ .local = "items" };
        var item = sir.Expr{ .local = "group" };
        var push = sir.Expr{ .sequence_push = .{ .object = &object, .value = &item } };
        const items = [_]*sir.Expr{&item};
        var literal = sir.Expr{ .dense_array_literal = .{ .len = 1, .items = &items } };
        const metadata = [_]sir.ExprMetadataEntry{.{ .expr = &item, .metadata = .{
            .type_id = owner_type,
            .semantics = std.mem.zeroes(sir.ValueSemantics),
            .checked_place_root = .{ .binding = root_id },
        } }};
        var state = State{ .allocator = allocator };
        defer state.deinit();
        const root = try state.addTypedRoot("group", root_id, owner_type);
        try state.bindings.append(allocator, .{ .owner_id = root, .name = "group" });
        var checker = Checker{
            .allocator = allocator,
            .interner = &interner,
            .structs = &.{},
            .unions = &.{},
            .metadata = &metadata,
            .contract = .{ .owner_type = owner_decl, .terminal_primary = @fromBackingInt(@intCast(343)), .terminal_secondary = @fromBackingInt(@intCast(344)) },
            .function = .{ .owner = null, .name = "dynamic_item", .params = &.{}, .body = &.{} },
        };
        try checker.transferCallArguments(&state, &push);
        try std.testing.expect(checker.issue != null);
        try std.testing.expect(state.bindings.items[0].live);
        checker.issue = null;
        try checker.transferCallArguments(&state, &literal);
        try std.testing.expect(checker.issue != null);
        try std.testing.expect(state.bindings.items[0].live);
    }

    test "dynamic removal and clearing preserve live element obligations" {
        const allocator = std.testing.allocator;
        var interner = types.TypeInterner.init(allocator);
        defer interner.deinit();
        const owner_decl: identity.DeclId = @fromBackingInt(@intCast(351));
        const owner_type = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = owner_decl } });
        const array_type = try interner.intern(.{ .dense_array = owner_type });
        const sparse_type = try interner.intern(.{ .sparse_array = owner_type });
        const root_id: identity.BindingId = @fromBackingInt(@intCast(352));
        var object = sir.Expr{ .local = "items" };
        var clear = sir.Expr{ .sequence_clear = &object };
        var pop = sir.Expr{ .sequence_pop = &object };
        var index = sir.Expr{ .int = .{ .value = 0, .type_name = null } };
        var take = sir.Expr{ .sparse_take = .{ .object = &object, .index = &index } };
        var metadata = [_]sir.ExprMetadataEntry{.{ .expr = &object, .metadata = .{
            .type_id = array_type,
            .semantics = std.mem.zeroes(sir.ValueSemantics),
            .checked_place_root = .{ .binding = root_id },
        } }};
        var state = State{ .allocator = allocator };
        defer state.deinit();
        const root = try state.addTypedRoot("items", root_id, array_type);
        try state.bindings.append(allocator, .{ .owner_id = root, .name = "items", .field_path = "[*]" });
        var checker = Checker{
            .allocator = allocator,
            .interner = &interner,
            .structs = &.{},
            .unions = &.{},
            .metadata = &metadata,
            .contract = .{ .owner_type = owner_decl, .terminal_primary = @fromBackingInt(@intCast(353)), .terminal_secondary = @fromBackingInt(@intCast(354)) },
            .function = .{ .owner = null, .name = "dynamic_remove", .params = &.{}, .body = &.{} },
        };
        try checker.transferCallArguments(&state, &clear);
        try std.testing.expect(checker.issue != null);
        try std.testing.expect(state.bindings.items[0].live);
        checker.issue = null;
        try checker.transferCallArguments(&state, &pop);
        try std.testing.expect(checker.issue != null);
        try std.testing.expect(state.bindings.items[0].live);
        checker.issue = null;
        metadata[0].metadata.type_id = sparse_type;
        state.roots.items[0].type_id = sparse_type;
        try checker.transferCallArguments(&state, &take);
        try std.testing.expect(checker.issue != null);
        try std.testing.expect(state.bindings.items[0].live);
        checker.issue = null;
        state.bindings.items[0].live = false;
        try checker.transferCallArguments(&state, &clear);
        try std.testing.expect(checker.issue == null);
    }

    test "trusted settlement contract validates consuming receiver and void result" {
        var interner = types.TypeInterner.init(std.testing.allocator);
        defer interner.deinit();
        const contract: Contract = .{ .owner_type = @fromBackingInt(@intCast(1)), .terminal_primary = @fromBackingInt(@intCast(2)), .terminal_secondary = @fromBackingInt(@intCast(3)) };
        const owner = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = contract.owner_type } });
        const other = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = @fromBackingInt(@intCast(4)) } });
        const void_type = try interner.intern(.{ .primitive = .void });
        const bool_type = try interner.intern(.{ .primitive = .bool });
        var params = [_]sir.Param{.{ .name = "self", .type_id = owner }};
        var functions = [_]sir.Function{
            .{ .decl_id = contract.terminal_primary, .owner = "TaskGroup", .name = "finish", .params = &params, .return_type_id = void_type, .body = &.{} },
            .{ .decl_id = contract.terminal_secondary, .owner = "TaskGroup", .name = "cancel_and_wait", .params = &params, .return_type_id = void_type, .body = &.{} },
        };
        try validateContract(&interner, &functions, contract);
        params[0].type_id = other;
        try std.testing.expectError(error.InvalidSettlementContract, validateContract(&interner, &functions, contract));
        params[0].type_id = owner;
        functions[0].return_type_id = bool_type;
        try std.testing.expectError(error.InvalidSettlementContract, validateContract(&interner, &functions, contract));
        functions[0].return_type_id = void_type;
        functions[0].params = &.{};
        try std.testing.expectError(error.InvalidSettlementContract, validateContract(&interner, &functions, contract));
        functions[0].params = &params;
        functions[0].is_extern = true;
        try std.testing.expectError(error.InvalidSettlementContract, validateContract(&interner, &functions, contract));
        functions[0].is_extern = false;
        try std.testing.expectError(error.InvalidSettlementContract, validateContract(&interner, functions[0..1], contract));
        var duplicate = contract;
        duplicate.terminal_secondary = duplicate.terminal_primary;
        try std.testing.expectError(error.InvalidSettlementContract, validateContract(&interner, &functions, duplicate));
        try validateContract(&interner, &functions, contract);
    }

    test "temporary capture aliases expression obligation apart from binding and synthetic roots" {
        var state = State{ .allocator = std.testing.allocator };
        defer state.deinit();
        const source_binding_id: identity.BindingId = @fromBackingInt(@intCast(7));
        const capture_binding_id: identity.BindingId = @fromBackingInt(@intCast(8));
        const temporary_id: identity.TemporaryId = @fromBackingInt(@intCast(7));
        const temporary_root = try state.addTemporaryRoot("payload", capture_binding_id, temporary_id);
        const binding_root = try state.addRoot("source", source_binding_id);
        const synthetic_root = try state.addRoot("generated", null);
        try std.testing.expect(temporary_root != binding_root);
        try std.testing.expect(temporary_root != synthetic_root);
        try std.testing.expectEqual(temporary_root, state.findBindingRoot(capture_binding_id).?.id);
        try std.testing.expectEqual(temporary_root, State.temporaryRootId(temporary_id));
    }
};

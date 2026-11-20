const std = @import("std");
const sir = @import("../sema/sir.zig");
const descriptor_names = @import("descriptor_names.zig");
const runtime_symbols = @import("../../runtime/symbols.zig");
const lir = @import("lir.zig");
const errors = @import("errors.zig");
const LowerError = errors.Error;

pub const CleanupEntry = struct {
    name: []const u8,
    ptr_value: lir.ValueId,
    ty: lir.TypeId,
    active: bool,
    heap_ptr: ?lir.ValueId = null,
};

pub const State = struct {
    cleanup_entries: std.ArrayListUnmanaged(CleanupEntry) = .empty,
    trace: std.ArrayListUnmanaged(lir.OwnershipTraceLine) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.freeCleanupEntriesFrom(allocator, 0);
        self.cleanup_entries.deinit(allocator);
        for (self.trace.items) |line| allocator.free(line.text);
        self.trace.deinit(allocator);
    }

    pub fn takeTrace(self: *State, allocator: std.mem.Allocator) errors.Error![]lir.OwnershipTraceLine {
        return self.trace.toOwnedSlice(allocator);
    }

    pub fn appendCleanup(self: *State, allocator: std.mem.Allocator, entry: CleanupEntry) errors.Error!usize {
        const index = self.cleanup_entries.items.len;
        try self.cleanup_entries.append(allocator, entry);
        return index;
    }

    pub fn setCleanupActive(self: *State, index: usize, active: bool) void {
        self.cleanup_entries.items[index].active = active;
    }

    pub fn truncateCleanup(self: *State, allocator: std.mem.Allocator, start: usize) void {
        self.freeCleanupEntriesFrom(allocator, start);
        self.cleanup_entries.items.len = start;
    }

    pub fn recordTrace(
        self: *State,
        allocator: std.mem.Allocator,
        comptime fmt: []const u8,
        args: anytype,
    ) errors.Error!void {
        const value = try std.fmt.allocPrint(allocator, fmt, args);
        errdefer allocator.free(value);
        try self.trace.append(allocator, .{ .text = value });
    }

    pub fn freeCleanupEntriesFrom(self: *State, allocator: std.mem.Allocator, start: usize) void {
        var i = self.cleanup_entries.items.len;
        while (i > start) {
            i -= 1;
            allocator.free(self.cleanup_entries.items[i].name);
        }
    }
};

pub fn isArcSharedValueStruct(struct_ty: lir.StructType) bool {
    return struct_ty.is_shared_value and struct_ty.shared_runtime == .arc;
}

// Function-lowering ownership and cleanup interface.
pub fn emitDefersFrom(self: anytype, start: usize, reason: []const u8) LowerError!void {
    if (self.defers.items.len > start) {
        try @TypeOf(self.*).recordOwnershipSiteTrace(self, "run_defers at {s}", .{reason});
    }
    var i = self.defers.items.len;
    while (i > start) {
        i -= 1;
        _ = try self.lowerExpr(self.defers.items[i]);
    }
}

pub fn emitAutoDropsFrom(self: anytype, start: usize, reason: []const u8) LowerError!void {
    var i = self.ownership.cleanup_entries.items.len;
    while (i > start) {
        i -= 1;
        const cleanup = self.ownership.cleanup_entries.items[i];
        if (!cleanup.active) continue;
        try @TypeOf(self.*).recordOwnershipSiteTrace(self, "auto_drop {s} at {s}", .{ cleanup.name, reason });
        const value = try self.emit(.{ .load = cleanup.ptr_value }, cleanup.ty);
        try @TypeOf(self.*).emitDropValue(self, value, cleanup.ty);
        if (cleanup.heap_ptr) |heap_ptr| try self.emitVoid(.{ .heap_free = heap_ptr });
    }
}

pub fn emitFullExpressionAutoDropsFrom(self: anytype, start: usize, reason: []const u8) LowerError!void {
    try @TypeOf(self.*).emitAutoDropsFrom(self, start, reason);
    self.freeCleanupEntriesFrom(start);
    self.ownership.cleanup_entries.items.len = start;
}

pub fn recordOwnershipTrace(self: anytype, comptime fmt: []const u8, args: anytype) LowerError!void {
    try self.ownership.recordTrace(self.mb.allocator, fmt, args);
}

pub fn recordOwnershipSiteTrace(self: anytype, comptime fmt: []const u8, args: anytype) LowerError!void {
    const prefix = try std.fmt.allocPrint(self.mb.allocator, fmt, args);
    defer self.mb.allocator.free(prefix);
    try @TypeOf(self.*).recordOwnershipTrace(self, "{s} ({s})", .{ prefix, self.currentBlock().name });
}

pub fn typeNeedsDrop(self: anytype, ty: lir.TypeId) LowerError!bool {
    return switch (self.mb.types.items[ty]) {
        .string => true,
        .dense_array, .sparse_array => true,
        .array => |array_ty| @TypeOf(self.*).typeNeedsDrop(self, array_ty.elem),
        .optional => |payload_ty| @TypeOf(self.*).typeNeedsDrop(self, payload_ty),
        .result => |result_ty| blk: {
            break :blk (try @TypeOf(self.*).typeNeedsDrop(self, result_ty.ok)) or (try @TypeOf(self.*).typeNeedsDrop(self, result_ty.err));
        },
        .@"struct" => |struct_ty| blk: {
            if (struct_ty.drop_runtime == .task_discard) break :blk true;
            if (isArcSharedValueStruct(struct_ty)) break :blk true;
            for (struct_ty.fields) |field| {
                if (try @TypeOf(self.*).typeNeedsDrop(self, field.ty)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |union_ty| blk: {
            for (union_ty.payloads) |payload| {
                if (payload) |payload_ty| {
                    if (try @TypeOf(self.*).typeNeedsDrop(self, payload_ty)) break :blk true;
                }
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn emitDropValue(self: anytype, value: lir.ValueId, ty: lir.TypeId) LowerError!void {
    switch (self.mb.types.items[ty]) {
        .void, .bool, .int, .float, .pointer, .slice => return,
        .string => {
            const value_ptr = try self.emit(.{ .stack_alloc = ty }, ty);
            try self.emitVoid(.{ .store = .{ .ptr = value_ptr, .value = value } });
            _ = try self.emit(.{ .call = .{
                .name = runtime_symbols.name(.string_release_at),
                .args = try @TypeOf(self.*).dupeArgs(self, &.{value_ptr}),
            } }, self.mb.void_type);
        },
        .@"struct" => |struct_ty| {
            if (struct_ty.drop_runtime == .task_discard) {
                if (struct_ty.fields.len != 1) return error.LowerInvariantViolation;
                const handle = try self.emit(.{ .extract_field = .{
                    .value = value,
                    .field_index = 0,
                } }, struct_ty.fields[0].ty);
                const status_ty = try self.mb.appendType(.{ .int = .{ .bits = 32, .signed = true } });
                _ = try self.emit(.{ .call = .{
                    .name = "cyna_std_thread_task_discard_raw",
                    .args = try @TypeOf(self.*).dupeArgs(self, &.{handle}),
                } }, status_ty);
                return;
            }
            if (isArcSharedValueStruct(struct_ty)) {
                const handle = try self.emit(.{ .extract_field = .{
                    .value = value,
                    .field_index = 0,
                } }, struct_ty.fields[0].ty);
                _ = try self.emit(.{ .call = .{
                    .name = runtime_symbols.name(.arc_release),
                    .args = try @TypeOf(self.*).dupeArgs(self, &.{handle}),
                } }, self.mb.i64_type);
                return;
            }
            for (struct_ty.fields, 0..) |field, i| {
                const field_value = try self.emit(.{ .extract_field = .{
                    .value = value,
                    .field_index = @intCast(i),
                } }, field.ty);
                try @TypeOf(self.*).emitDropValue(self, field_value, field.ty);
            }
        },
        .dense_array, .sparse_array => {
            const elem_desc = switch (self.mb.types.items[ty]) {
                .dense_array => |item_ty| try @TypeOf(self.*).emitTypeDesc(self, item_ty),
                .sparse_array => |item_ty| try @TypeOf(self.*).emitTypeDesc(self, item_ty),
                else => return error.LowerInvariantViolation,
            };
            switch (self.mb.types.items[ty]) {
                .dense_array => _ = try self.emit(.{ .dense_drop = .{
                    .lhs = value,
                    .rhs = elem_desc,
                } }, self.mb.void_type),
                .sparse_array => _ = try self.emit(.{ .sparse_drop = .{
                    .lhs = value,
                    .rhs = elem_desc,
                } }, self.mb.void_type),
                else => return error.LowerInvariantViolation,
            }
        },
        .array => |array_ty| {
            const array_ptr_ty = try self.mb.appendType(.{ .pointer = array_ty.elem });
            const tmp_ptr = try self.emit(.{ .stack_alloc = ty }, ty);
            try self.emitVoid(.{ .store = .{
                .ptr = tmp_ptr,
                .value = value,
            } });
            var index: usize = 0;
            while (index < array_ty.len) : (index += 1) {
                const index_value = try self.emit(.{ .const_int = @intCast(index) }, self.mb.i64_type);
                const item_ptr = try self.emit(.{ .index_ptr = .{
                    .ptr = tmp_ptr,
                    .index = index_value,
                } }, array_ptr_ty);
                const item_value = try self.emit(.{ .load = item_ptr }, array_ty.elem);
                try @TypeOf(self.*).emitDropValue(self, item_value, array_ty.elem);
            }
        },
        .optional => |payload_ty| {
            const tag_value = try self.emit(.{ .extract_tag = value }, self.mb.bool_type);
            const some_blk = try self.beginBlock("drop_some");
            const cont_blk = try self.beginBlock("drop_opt_cont");
            try self.endBlock(.{ .cond_br = .{
                .condition = tag_value,
                .then_block = some_blk,
                .else_block = cont_blk,
            } });
            self.current_block = some_blk;
            const payload_value = try self.emit(.{ .extract_payload = .{ .value = value } }, payload_ty);
            try @TypeOf(self.*).emitDropValue(self, payload_value, payload_ty);
            try self.endBlock(.{ .br = cont_blk });
            self.current_block = cont_blk;
        },
        .result => |result_ty| {
            const tag_value = try self.emit(.{ .extract_tag = value }, self.mb.bool_type);
            const err_blk = try self.beginBlock("drop_result_err");
            const ok_blk = try self.beginBlock("drop_result_ok");
            const cont_blk = try self.beginBlock("drop_result_cont");
            try self.endBlock(.{ .cond_br = .{
                .condition = tag_value,
                .then_block = err_blk,
                .else_block = ok_blk,
            } });
            self.current_block = ok_blk;
            const ok_value = try self.emit(.{ .extract_payload = .{ .value = value } }, result_ty.ok);
            try @TypeOf(self.*).emitDropValue(self, ok_value, result_ty.ok);
            try self.endBlock(.{ .br = cont_blk });
            self.current_block = err_blk;
            const err_value = try self.emit(.{ .extract_result = .{
                .value = value,
                .is_err = true,
            } }, result_ty.err);
            try @TypeOf(self.*).emitDropValue(self, err_value, result_ty.err);
            try self.endBlock(.{ .br = cont_blk });
            self.current_block = cont_blk;
        },
        .@"union" => |union_ty| {
            const tag_value = try self.emit(.{ .extract_tag = value }, self.mb.i64_type);
            const cont_blk = try self.beginBlock("drop_union_cont");
            var compare_blk = self.current_block;
            for (union_ty.payloads, 0..) |payload_ty, i| {
                if (payload_ty == null) continue;
                self.current_block = compare_blk;
                const case_blk = try self.beginBlock("drop_union_case");
                const next_blk = try self.beginBlock("drop_union_next");
                const want_tag = try self.emit(.{ .const_int = @intCast(i) }, self.mb.i64_type);
                const match_value = try self.emit(.{ .int_cmp = .{
                    .op = .eq,
                    .lhs = tag_value,
                    .rhs = want_tag,
                } }, self.mb.bool_type);
                try self.endBlock(.{ .cond_br = .{
                    .condition = match_value,
                    .then_block = case_blk,
                    .else_block = next_blk,
                } });
                self.current_block = case_blk;
                const payload_value = try self.emit(.{ .extract_payload = .{
                    .value = value,
                    .union_tag = @intCast(i),
                } }, payload_ty.?);
                try @TypeOf(self.*).emitDropValue(self, payload_value, payload_ty.?);
                try self.endBlock(.{ .br = cont_blk });
                compare_blk = next_blk;
            }
            self.current_block = compare_blk;
            try self.endBlock(.{ .br = cont_blk });
            self.current_block = cont_blk;
        },
    }
}

pub fn copyValueInto(self: anytype, dst_ptr: lir.ValueId, value: lir.ValueId, ty: lir.TypeId) LowerError!void {
    if (self.mb.types.items[ty] == .string) {
        const src_ptr = try self.emit(.{ .stack_alloc = ty }, ty);
        try self.emitVoid(.{ .store = .{ .ptr = src_ptr, .value = value } });
        _ = try self.emit(.{ .call = .{
            .name = runtime_symbols.name(.string_share_into),
            .args = try @TypeOf(self.*).dupeArgs(self, &.{ dst_ptr, src_ptr }),
        } }, self.mb.void_type);
        return;
    }
    if (self.mb.types.items[ty] == .@"struct" and isArcSharedValueStruct(self.mb.types.items[ty].@"struct")) {
        const struct_ty = self.mb.types.items[ty].@"struct";
        const handle = try self.emit(.{ .extract_field = .{
            .value = value,
            .field_index = 0,
        } }, struct_ty.fields[0].ty);
        const retained = try self.emit(.{ .call = .{
            .name = runtime_symbols.name(.arc_retain),
            .args = try @TypeOf(self.*).dupeArgs(self, &.{handle}),
        } }, struct_ty.fields[0].ty);
        const fields = try self.mb.allocator.alloc(lir.ValueId, 1);
        errdefer self.mb.allocator.free(fields);
        fields[0] = retained;
        const shared = try self.emit(.{ .make_struct = .{ .fields = fields } }, ty);
        try self.emitVoid(.{ .store = .{
            .ptr = dst_ptr,
            .value = shared,
        } });
        return;
    }
    if (!(try @TypeOf(self.*).typeNeedsDrop(self, ty))) {
        try self.emitVoid(.{ .store = .{
            .ptr = dst_ptr,
            .value = value,
        } });
        return;
    }

    const src_ptr = try self.emit(.{ .stack_alloc = ty }, ty);
    try self.emitVoid(.{ .store = .{
        .ptr = src_ptr,
        .value = value,
    } });
    const desc = try @TypeOf(self.*).emitTypeDesc(self, ty);
    const copy_name = try descriptor_names.descriptorCopyName(self.mb.allocator, .{
        .types = self.mb.types.items,
        .globals = &.{},
        .functions = &.{},
        .generated_names = &.{},
    }, ty);
    try self.mb.generated_names.append(self.mb.allocator, copy_name);
    _ = try self.emit(.{ .call = .{
        .name = copy_name,
        .args = try @TypeOf(self.*).dupeArgs(self, &.{ dst_ptr, src_ptr, desc }),
    } }, self.mb.void_type);
}

pub fn lowerStmtListWithCapturedLocal(self: anytype, name: []const u8, ty: lir.TypeId, value: lir.ValueId, body: []const sir.Stmt) LowerError!void {
    const defer_start = self.defers.items.len;
    const cleanup_start = self.ownership.cleanup_entries.items.len;
    const restore_start = self.scope_restores.items.len;
    defer {
        self.restoreLocalsFrom(restore_start);
        self.scope_restores.items.len = restore_start;
        self.freeCleanupEntriesFrom(cleanup_start);
        self.ownership.cleanup_entries.items.len = cleanup_start;
        self.defers.items.len = defer_start;
    }

    const local = try self.defineLocal(name, ty);
    try @TypeOf(self.*).copyValueInto(self, local.ptr_value, value, ty);
    self.markCleanupActive(local);

    for (body) |stmt| {
        if (self.currentBlock().terminator != .none) break;
        try @TypeOf(self.*).lowerStmt(self, stmt);
    }

    if (self.currentBlock().terminator == .none) {
        try @TypeOf(self.*).emitDefersFrom(self, defer_start, "scope_exit");
        try @TypeOf(self.*).emitAutoDropsFrom(self, cleanup_start, "scope_exit");
    }
}

pub fn lowerStmtListWithAliasedLocal(self: anytype, name: []const u8, ty: lir.TypeId, ptr_value: lir.ValueId, body: []const sir.Stmt) LowerError!void {
    const defer_start = self.defers.items.len;
    const cleanup_start = self.ownership.cleanup_entries.items.len;
    const restore_start = self.scope_restores.items.len;
    defer {
        self.restoreLocalsFrom(restore_start);
        self.scope_restores.items.len = restore_start;
        self.freeCleanupEntriesFrom(cleanup_start);
        self.ownership.cleanup_entries.items.len = cleanup_start;
        self.defers.items.len = defer_start;
    }

    const local_id: lir.LocalId = @intCast(self.locals_list.items.len);
    try self.scope_restores.append(self.mb.allocator, .{
        .name = name,
        .previous = self.locals.get(name),
    });
    try self.locals_list.append(self.mb.allocator, .{
        .name = name,
        .ty = ty,
    });
    try self.locals.put(self.mb.allocator, name, .{
        .local_id = local_id,
        .ptr_value = ptr_value,
        .ty = ty,
        .cleanup_index = null,
    });

    for (body) |stmt| {
        if (self.currentBlock().terminator != .none) break;
        try @TypeOf(self.*).lowerStmt(self, stmt);
    }

    if (self.currentBlock().terminator == .none) {
        try @TypeOf(self.*).emitDefersFrom(self, defer_start, "scope_exit");
        try @TypeOf(self.*).emitAutoDropsFrom(self, cleanup_start, "scope_exit");
    }
}

pub fn lowerStmtListWithMovedCapturedLocal(self: anytype, name: []const u8, ty: lir.TypeId, value: lir.ValueId, body: []const sir.Stmt) LowerError!void {
    const defer_start = self.defers.items.len;
    const cleanup_start = self.ownership.cleanup_entries.items.len;
    const restore_start = self.scope_restores.items.len;
    defer {
        self.restoreLocalsFrom(restore_start);
        self.scope_restores.items.len = restore_start;
        self.freeCleanupEntriesFrom(cleanup_start);
        self.ownership.cleanup_entries.items.len = cleanup_start;
        self.defers.items.len = defer_start;
    }

    const local = try self.defineLocal(name, ty);
    try self.emitVoid(.{ .store = .{
        .ptr = local.ptr_value,
        .value = value,
    } });
    self.markCleanupActive(local);

    for (body) |stmt| {
        if (self.currentBlock().terminator != .none) break;
        try @TypeOf(self.*).lowerStmt(self, stmt);
    }

    if (self.currentBlock().terminator == .none) {
        try @TypeOf(self.*).emitDefersFrom(self, defer_start, "scope_exit");
        try @TypeOf(self.*).emitAutoDropsFrom(self, cleanup_start, "scope_exit");
    }
}

pub fn valueSemanticsNeedsMatchSourceDrop(semantics: sir.ValueSemantics) bool {
    return semantics.cleanup == .full_expression;
}

pub fn captureMatchSourceMovesPayload(self: anytype, expr: *sir.Expr) LowerError!bool {
    return (try self.mb.exprMetadata(expr)).consumption.transfer == .take;
}

pub fn captureMatchSourceNeedsDrop(self: anytype, expr: *sir.Expr) LowerError!bool {
    return valueSemanticsNeedsMatchSourceDrop((try self.mb.exprMetadata(expr)).semantics);
}

pub fn lowerStmtListWithCapturedLocalAndDrop(
    self: anytype,
    name: []const u8,
    ty: lir.TypeId,
    value: lir.ValueId,
    drop_value: ?lir.ValueId,
    drop_ty: lir.TypeId,
    body: []const sir.Stmt,
) LowerError!void {
    const defer_start = self.defers.items.len;
    const cleanup_start = self.ownership.cleanup_entries.items.len;
    const restore_start = self.scope_restores.items.len;
    defer {
        self.restoreLocalsFrom(restore_start);
        self.scope_restores.items.len = restore_start;
        self.freeCleanupEntriesFrom(cleanup_start);
        self.ownership.cleanup_entries.items.len = cleanup_start;
        self.defers.items.len = defer_start;
    }

    const local = try self.defineLocal(name, ty);
    try @TypeOf(self.*).copyValueInto(self, local.ptr_value, value, ty);
    self.markCleanupActive(local);
    if (drop_value) |owned_value| {
        try @TypeOf(self.*).emitDropValue(self, owned_value, drop_ty);
    }

    for (body) |stmt| {
        if (self.currentBlock().terminator != .none) break;
        try @TypeOf(self.*).lowerStmt(self, stmt);
    }

    if (self.currentBlock().terminator == .none) {
        try @TypeOf(self.*).emitDefersFrom(self, defer_start, "scope_exit");
        try @TypeOf(self.*).emitAutoDropsFrom(self, cleanup_start, "scope_exit");
    }
}

pub fn typeHasSharedValueSemantics(self: anytype, ty: lir.TypeId) LowerError!bool {
    if (try typeContainsTaskHandle(self.mb.allocator, self.mb.types.items, ty)) return false;
    return switch (self.mb.types.items[ty]) {
        .string => true,
        .dense_array => true,
        .sparse_array => true,
        .optional => |payload_ty| @TypeOf(self.*).typeHasSharedValueSemantics(self, payload_ty),
        .result => |result_ty| blk: {
            break :blk (try @TypeOf(self.*).typeHasSharedValueSemantics(self, result_ty.ok)) or (try @TypeOf(self.*).typeHasSharedValueSemantics(self, result_ty.err));
        },
        .array => |array_ty| @TypeOf(self.*).typeHasSharedValueSemantics(self, array_ty.elem),
        .@"struct" => |struct_ty| blk: {
            if (isArcSharedValueStruct(struct_ty)) break :blk true;
            for (struct_ty.fields) |field| {
                if (try @TypeOf(self.*).typeHasSharedValueSemantics(self, field.ty)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |union_ty| blk: {
            for (union_ty.payloads) |payload| {
                if (payload) |payload_ty| {
                    if (try @TypeOf(self.*).typeHasSharedValueSemantics(self, payload_ty)) break :blk true;
                }
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn typeContainsTaskHandle(allocator: std.mem.Allocator, types: []const lir.TypeDecl, ty: lir.TypeId) LowerError!bool {
    const visited = try allocator.alloc(bool, types.len);
    defer allocator.free(visited);
    @memset(visited, false);
    return typeContainsTaskHandleVisited(types, ty, visited);
}

fn typeContainsTaskHandleVisited(types: []const lir.TypeDecl, ty: lir.TypeId, visited: []bool) bool {
    if (visited[ty]) return false;
    visited[ty] = true;
    return switch (types[ty]) {
        .dense_array, .sparse_array, .optional => |item| typeContainsTaskHandleVisited(types, item, visited),
        .array => |array| typeContainsTaskHandleVisited(types, array.elem, visited),
        .result => |result| typeContainsTaskHandleVisited(types, result.ok, visited) or typeContainsTaskHandleVisited(types, result.err, visited),
        .@"struct" => |structure| blk: {
            if (structure.drop_runtime == .task_discard) break :blk true;
            for (structure.fields) |field| {
                if (typeContainsTaskHandleVisited(types, field.ty, visited)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |union_ty| blk: {
            for (union_ty.payloads) |payload| {
                if (payload) |item| {
                    if (typeContainsTaskHandleVisited(types, item, visited)) break :blk true;
                }
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn valueSemanticsNeedsDropAfterContainerCopy(semantics: sir.ValueSemantics) bool {
    return semantics.cleanup == .full_expression;
}

pub fn valueSemanticsNeedsStringCleanup(semantics: sir.ValueSemantics) bool {
    return semantics.cleanup == .full_expression;
}

pub fn valueSemanticsNeedsStringReceiverOwner(semantics: sir.ValueSemantics) bool {
    return semantics.category != .place;
}

pub fn exprConsumptionCopiesValue(self: anytype, expr: *sir.Expr) LowerError!bool {
    return (try self.mb.exprMetadata(expr)).consumption.transfer == .copy;
}

pub fn prepareCapturedExprValue(self: anytype, expr: ?*sir.Expr, value: lir.ValueId, ty: lir.TypeId) LowerError!lir.ValueId {
    if (!(try @TypeOf(self.*).typeHasSharedValueSemantics(self, ty))) return value;
    const source_expr = expr orelse return value;
    if (!(try @TypeOf(self.*).exprConsumptionCopiesValue(self, source_expr))) return value;
    const tmp_ptr = try self.emit(.{ .stack_alloc = ty }, ty);
    try @TypeOf(self.*).copyValueInto(self, tmp_ptr, value, ty);
    return self.emit(.{ .load = tmp_ptr }, ty);
}

pub fn captureAliasedValue(self: anytype, value: lir.ValueId, ty: lir.TypeId) LowerError!lir.ValueId {
    const tmp_ptr = try self.emit(.{ .stack_alloc = ty }, ty);
    try @TypeOf(self.*).copyValueInto(self, tmp_ptr, value, ty);
    return self.emit(.{ .load = tmp_ptr }, ty);
}

pub fn captureExprValueInto(self: anytype, dst_ptr: lir.ValueId, expr: ?*sir.Expr, value: lir.ValueId, ty: lir.TypeId) LowerError!void {
    const captured = try @TypeOf(self.*).prepareCapturedExprValue(self, expr, value, ty);
    try self.emitVoid(.{ .store = .{
        .ptr = dst_ptr,
        .value = captured,
    } });
}

pub fn storeWithCleanup(self: anytype, dst_ptr: lir.ValueId, expr: ?*sir.Expr, value: lir.ValueId, ty: lir.TypeId, drop_old: bool) LowerError!void {
    const captured = try @TypeOf(self.*).prepareCapturedExprValue(self, expr, value, ty);
    if (drop_old) {
        const old_value = try self.emit(.{ .load = dst_ptr }, ty);
        try @TypeOf(self.*).emitDropValue(self, old_value, ty);
    }
    try self.emitVoid(.{ .store = .{
        .ptr = dst_ptr,
        .value = captured,
    } });
}

pub fn dropEphemeralSharedAfterContainerCopy(self: anytype, expr: ?*sir.Expr, value: lir.ValueId, ty: lir.TypeId) LowerError!void {
    const source_expr = expr orelse return;
    if (!(try @TypeOf(self.*).typeHasSharedValueSemantics(self, ty))) return;
    const semantics = (try self.mb.exprMetadata(source_expr)).semantics;
    const needs_drop = valueSemanticsNeedsDropAfterContainerCopy(semantics);
    if (!needs_drop) return;
    try @TypeOf(self.*).emitDropValue(self, value, ty);
}

pub fn byteSizeOfType(self: anytype, ty: lir.TypeId) LowerError!usize {
    return switch (self.mb.types.items[ty]) {
        .void => 0,
        .bool => 1,
        .int => |int_ty| @max(1, @as(usize, int_ty.bits) / 8),
        .string => 16,
        .pointer => 8,
        .array => |array_ty| array_ty.len * try @TypeOf(self.*).byteSizeOfType(self, array_ty.elem),
        .slice => 16,
        .dense_array => 24,
        .sparse_array => 32,
        .optional => |payload| 1 + try @TypeOf(self.*).byteSizeOfType(self, payload),
        .result => |result_ty| 1 + @max(try @TypeOf(self.*).byteSizeOfType(self, result_ty.ok), try @TypeOf(self.*).byteSizeOfType(self, result_ty.err)),
        .@"struct" => |struct_ty| blk: {
            var total: usize = 0;
            for (struct_ty.fields) |field| total += try @TypeOf(self.*).byteSizeOfType(self, field.ty);
            break :blk total;
        },
        .@"union" => |union_ty| blk: {
            var total: usize = 8;
            for (union_ty.payloads) |payload| {
                if (payload) |payload_ty| total += try @TypeOf(self.*).byteSizeOfType(self, payload_ty);
            }
            break :blk total;
        },
    };
}

pub fn dupeArgs(self: anytype, values: []const lir.ValueId) LowerError![]lir.ValueId {
    return try self.mb.allocator.dupe(lir.ValueId, values);
}

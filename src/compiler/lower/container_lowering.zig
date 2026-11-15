const std = @import("std");
const sir = @import("../sema/sir.zig");
const identity = @import("../sema/identity.zig");
const lir = @import("lir.zig");
const ownership_lowering = @import("ownership_lowering.zig");
const errors = @import("errors.zig");
const LowerError = errors.Error;

pub const BorrowedSequenceUse = enum {
    copy_from_place,
    len_from_place,
    push_from_place,
    clear_from_place,
    reserve_from_place,
    pop_from_place,
    sparse_len_from_place,
    sparse_clear_from_place,
    sparse_indices_from_place,
    sparse_contains_index_from_place,
    sparse_insert_from_place,
    sparse_take_from_place,
};

pub fn lowerReadableSequenceValue(self: anytype, expr: *sir.Expr, borrowed_use: BorrowedSequenceUse) LowerError!struct { value: lir.ValueId, ty: lir.TypeId } {
    if ((try self.mb.exprMetadata(expr)).semantics.category == .borrowed_projection) {
        const place = try @TypeOf(self.*).lowerAddressableBorrowedProjectionPlacePointer(self, expr);
        const ptr_ty = try self.mb.appendType(.{ .pointer = place.ty });
        try @TypeOf(self.*).recordOwnershipTrace(self, "borrowed_projection {s}", .{@tagName(borrowed_use)});
        return .{
            .value = try @TypeOf(self.*).materializeSequenceValueFromValue(self, place.ptr_value, ptr_ty),
            .ty = place.ty,
        };
    }
    const value = try @TypeOf(self.*).materializeSequenceValue(self, expr);
    return .{
        .value = value,
        .ty = try @TypeOf(self.*).lowerExprType(self, expr),
    };
}

pub fn lowerMutableSequencePlace(self: anytype, expr: *sir.Expr, borrowed_use: BorrowedSequenceUse) LowerError!struct { ptr: lir.ValueId, ty: lir.TypeId } {
    const category = (try self.mb.exprMetadata(expr)).semantics.category;
    if (category == .place) {
        const place = try @TypeOf(self.*).lowerAddressablePlacePointer(self, expr);
        return .{ .ptr = place.ptr_value, .ty = place.ty };
    }
    if (category == .borrowed_projection) {
        const place = try @TypeOf(self.*).lowerAddressableBorrowedProjectionPlacePointer(self, expr);
        try @TypeOf(self.*).recordOwnershipTrace(self, "borrowed_projection {s}", .{@tagName(borrowed_use)});
        return .{ .ptr = place.ptr_value, .ty = place.ty };
    }
    const ty = try @TypeOf(self.*).lowerExprType(self, expr);
    const value = try @TypeOf(self.*).materializeSequenceValue(self, expr);
    const ptr = try self.emit(.{ .stack_alloc = ty }, ty);
    try self.emitVoid(.{ .store = .{ .ptr = ptr, .value = value } });
    return .{ .ptr = ptr, .ty = ty };
}

pub fn lowerArrayDefaultExpr(self: anytype, literal: sir.ArrayDefault) LowerError!lir.ValueId {
    const array_ty = try self.mb.lowerArrayTypeFromCanonicalItem(literal.len, literal.item_type_id);
    return @TypeOf(self.*).emitDefaultValue(self, array_ty);
}

pub fn lowerNewArrayExpr(self: anytype, new_array: sir.NewArray) LowerError!lir.ValueId {
    const array_ty = try self.mb.lowerDenseArrayTypeFromCanonicalItem(new_array.item_type_id);
    const item_ty = try self.mb.lowerCanonicalType(new_array.item_type_id);
    const array_value = try @TypeOf(self.*).emitDenseArrayStorageNew(self, array_ty, item_ty);
    const array_ptr = try self.emit(.{ .stack_alloc = array_ty }, array_ty);
    try self.emitVoid(.{ .store = .{ .ptr = array_ptr, .value = array_value } });
    const capacity_value = try self.lowerExpr(new_array.len);
    _ = try @TypeOf(self.*).emitDenseArrayStorageReserve(self, array_ptr, item_ty, capacity_value);
    return self.emit(.{ .load = array_ptr }, array_ty);
}

pub fn lowerDenseArrayLiteralExpr(self: anytype, literal: sir.ArrayLiteral) LowerError!lir.ValueId {
    const array_ty = try self.mb.lowerDenseArrayTypeFromCanonicalItem(literal.item_type_id);
    const item_ty = try self.mb.lowerCanonicalType(literal.item_type_id);
    const array_init = try @TypeOf(self.*).emitDenseArrayStorageNew(self, array_ty, item_ty);
    const array_ptr = try self.emit(.{ .stack_alloc = array_ty }, array_ty);
    try self.emitVoid(.{ .store = .{ .ptr = array_ptr, .value = array_init } });
    const capacity = literal.capacity orelse literal.items.len;
    if (capacity != 0) {
        const capacity_value = try self.emit(.{ .const_int = @intCast(capacity) }, self.mb.i64_type);
        _ = try @TypeOf(self.*).emitDenseArrayStorageReserve(self, array_ptr, item_ty, capacity_value);
    }
    for (literal.items) |item| {
        const value = try @TypeOf(self.*).lowerExprForTarget(self, item, item_ty);
        _ = try @TypeOf(self.*).emitDenseArrayStoragePushValue(self, array_ptr, item_ty, value);
    }
    return self.emit(.{ .load = array_ptr }, array_ty);
}

pub fn lowerNewSparseExpr(self: anytype, storage: sir.SparseArray) LowerError!lir.ValueId {
    const sparse_ty = try self.mb.lowerSparseArrayTypeFromCanonicalItem(storage.item_type_id);
    const item_ty = try self.mb.lowerCanonicalType(storage.item_type_id);
    const capacity_value = try @TypeOf(self.*).lowerExprForTarget(self, storage.capacity, self.mb.i64_type);
    return self.emit(.{ .sparse_new = .{
        .lhs = capacity_value,
        .rhs = try @TypeOf(self.*).emitTypeDesc(self, item_ty),
    } }, sparse_ty);
}

pub fn lowerSparseLiteralExpr(self: anytype, literal: sir.SparseLiteral) LowerError!lir.ValueId {
    const sparse_ty = try self.mb.lowerSparseArrayTypeFromCanonicalItem(literal.item_type_id);
    const item_ty = try self.mb.lowerCanonicalType(literal.item_type_id);
    const optional_item_ty = try self.mb.appendType(.{ .optional = item_ty });
    const capacity_value = try self.emit(.{ .const_int = @intCast(literal.capacity) }, self.mb.i64_type);
    const sparse_init = try self.emit(.{ .sparse_new = .{
        .lhs = capacity_value,
        .rhs = try @TypeOf(self.*).emitTypeDesc(self, item_ty),
    } }, sparse_ty);
    const sparse_ptr = try self.emit(.{ .stack_alloc = sparse_ty }, sparse_ty);
    try self.emitVoid(.{ .store = .{ .ptr = sparse_ptr, .value = sparse_init } });

    for (literal.items, 0..) |item, i| {
        const slot_value = try @TypeOf(self.*).lowerExprForTarget(self, item, optional_item_ty);
        const is_some = try self.emit(.{ .extract_tag = slot_value }, self.mb.bool_type);
        const tmp_ptr = try self.emit(.{ .stack_alloc = item_ty }, item_ty);
        const some_blk = try self.beginBlock("sparse_lit_some");
        const none_blk = try self.beginBlock("sparse_lit_none");
        const cont_blk = try self.beginBlock("sparse_lit_cont");
        try self.endBlock(.{ .cond_br = .{
            .condition = is_some,
            .then_block = some_blk,
            .else_block = none_blk,
        } });

        self.current_block = some_blk;
        const payload = try self.emit(.{ .extract_payload = .{
            .value = slot_value,
            .union_tag = null,
        } }, item_ty);
        try self.emitVoid(.{ .store = .{ .ptr = tmp_ptr, .value = payload } });
        const index_value = try self.emit(.{ .const_int = @intCast(i) }, self.mb.i64_type);
        _ = try self.emit(.{ .sparse_set_move = .{
            .a = sparse_ptr,
            .b = index_value,
            .c = is_some,
            .d = tmp_ptr,
            .e = try @TypeOf(self.*).emitTypeDesc(self, item_ty),
        } }, self.mb.void_type);
        try self.endBlock(.{ .br = cont_blk });

        self.current_block = none_blk;
        try self.endBlock(.{ .br = cont_blk });

        self.current_block = cont_blk;
    }

    return self.emit(.{ .load = sparse_ptr }, sparse_ty);
}

pub fn lowerSparseKeyedLiteralExpr(self: anytype, literal: sir.SparseKeyedLiteral) LowerError!lir.ValueId {
    const sparse_ty = try self.mb.lowerSparseArrayTypeFromCanonicalItem(literal.item_type_id);
    const item_ty = try self.mb.lowerCanonicalType(literal.item_type_id);
    const capacity_value = try self.emit(.{ .const_int = @intCast(literal.capacity) }, self.mb.i64_type);
    const sparse_init = try self.emit(.{ .sparse_new = .{
        .lhs = capacity_value,
        .rhs = try @TypeOf(self.*).emitTypeDesc(self, item_ty),
    } }, sparse_ty);
    const sparse_ptr = try self.emit(.{ .stack_alloc = sparse_ty }, sparse_ty);
    try self.emitVoid(.{ .store = .{ .ptr = sparse_ptr, .value = sparse_init } });

    const is_some = try self.emit(.{ .const_bool = true }, self.mb.bool_type);
    for (literal.entries) |entry| {
        const index_value = try @TypeOf(self.*).lowerExprForTarget(self, entry.index, self.mb.i64_type);
        const value = try @TypeOf(self.*).lowerExprForTarget(self, entry.value, item_ty);
        const tmp_ptr = try self.emit(.{ .stack_alloc = item_ty }, item_ty);
        try self.emitVoid(.{ .store = .{ .ptr = tmp_ptr, .value = value } });
        _ = try self.emit(.{ .sparse_set_move = .{
            .a = sparse_ptr,
            .b = index_value,
            .c = is_some,
            .d = tmp_ptr,
            .e = try @TypeOf(self.*).emitTypeDesc(self, item_ty),
        } }, self.mb.void_type);
    }

    return self.emit(.{ .load = sparse_ptr }, sparse_ty);
}

pub fn lowerValueForTargetType(self: anytype, value: lir.ValueId, target_ty: lir.TypeId) LowerError!lir.ValueId {
    if (target_ty == self.mb.i64_type) return value;
    return try self.emit(.{ .int_to_int = value }, target_ty);
}

pub fn lowerCalleeReturnType(self: anytype, callee: sir.Function) LowerError!lir.TypeId {
    return self.mb.lowerCanonicalType(callee.return_type_id);
}

pub fn lowerSequenceLenExpr(self: anytype, object: *sir.Expr, result_ty: lir.TypeId) LowerError!lir.ValueId {
    const sequence = try @TypeOf(self.*).lowerReadableSequenceValue(self, object, .len_from_place);
    return @TypeOf(self.*).emitSequenceLenValue(self, sequence.value, sequence.ty, result_ty);
}

pub fn lowerSparseLenExpr(self: anytype, object: *sir.Expr, result_ty: lir.TypeId) LowerError!lir.ValueId {
    const sparse = try @TypeOf(self.*).lowerReadableSequenceValue(self, object, .sparse_len_from_place);
    return self.emit(.{ .sparse_len = sparse.value }, result_ty);
}

pub fn lowerSliceLenExpr(self: anytype, object: *sir.Expr, result_ty: lir.TypeId) LowerError!lir.ValueId {
    const slice_value = try self.lowerExpr(object);
    return self.emit(.{ .extract_slice_len = slice_value }, result_ty);
}

pub fn lowerSequencePushExpr(self: anytype, push: sir.SequencePush) LowerError!lir.ValueId {
    const sequence = try @TypeOf(self.*).lowerMutableSequencePlace(self, push.object, .push_from_place);
    const list_ty = sequence.ty;
    const item_ty = try @TypeOf(self.*).sequenceItemType(self, list_ty);
    const item_value = try self.lowerExpr(push.value);
    switch (self.mb.types.items[list_ty]) {
        .dense_array => {},
        else => return error.LowerInvariantViolation,
    }
    return @TypeOf(self.*).emitSequencePushValue(self, sequence.ptr, list_ty, item_ty, item_value, push.value);
}

pub fn lowerSequenceClearExpr(self: anytype, object: *sir.Expr) LowerError!lir.ValueId {
    const sequence = try @TypeOf(self.*).lowerMutableSequencePlace(self, object, .clear_from_place);
    const list_ty = sequence.ty;
    return @TypeOf(self.*).emitSequenceClearValue(self, sequence.ptr, list_ty, try @TypeOf(self.*).sequenceItemType(self, list_ty));
}

pub fn lowerSparseClearExpr(self: anytype, object: *sir.Expr) LowerError!lir.ValueId {
    const sparse = try @TypeOf(self.*).lowerMutableSequencePlace(self, object, .sparse_clear_from_place);
    const item_ty = try @TypeOf(self.*).sequenceItemType(self, sparse.ty);
    return self.emit(.{ .sparse_clear = .{
        .lhs = sparse.ptr,
        .rhs = try @TypeOf(self.*).emitTypeDesc(self, item_ty),
    } }, self.mb.void_type);
}

pub fn lowerSparseIndicesExpr(self: anytype, object: *sir.Expr) LowerError!lir.ValueId {
    const sparse = try @TypeOf(self.*).lowerReadableSequenceValue(self, object, .sparse_indices_from_place);
    const list_ty = try self.mb.appendType(.{ .dense_array = self.mb.i64_type });
    return self.emit(.{ .sparse_indices = .{
        .lhs = sparse.value,
        .rhs = try @TypeOf(self.*).emitTypeDesc(self, self.mb.i64_type),
    } }, list_ty);
}

pub fn lowerSparseContainsIndexExpr(self: anytype, contains: sir.SparseContainsIndex) LowerError!lir.ValueId {
    const sparse = try @TypeOf(self.*).lowerReadableSequenceValue(self, contains.object, .sparse_contains_index_from_place);
    const index_value = try @TypeOf(self.*).lowerExprForTarget(self, contains.index, self.mb.i64_type);
    return self.emit(.{ .sparse_contains_index = .{
        .lhs = sparse.value,
        .rhs = index_value,
    } }, self.mb.bool_type);
}

pub fn lowerSparseInsertExpr(self: anytype, insert: sir.SparseInsert) LowerError!lir.ValueId {
    const sparse = try @TypeOf(self.*).lowerMutableSequencePlace(self, insert.object, .sparse_insert_from_place);
    const item_ty = try @TypeOf(self.*).sequenceItemType(self, sparse.ty);
    const index_value = try @TypeOf(self.*).lowerExprForTarget(self, insert.index, self.mb.i64_type);
    const item_value = try self.lowerExpr(insert.value);
    const tmp_ptr = try self.emit(.{ .stack_alloc = item_ty }, item_ty);
    try self.emitVoid(.{ .store = .{ .ptr = tmp_ptr, .value = item_value } });
    const move_item = try ownership_lowering.typeContainsTaskHandle(self.mb.allocator, self.mb.types.items, item_ty);
    const elem_desc = try @TypeOf(self.*).emitTypeDesc(self, item_ty);
    const operation: lir.InstData = if (move_item) .{ .sparse_insert_move = .{
        .a = sparse.ptr,
        .b = index_value,
        .c = tmp_ptr,
        .d = elem_desc,
    } } else .{ .sparse_insert = .{
        .a = sparse.ptr,
        .b = index_value,
        .c = tmp_ptr,
        .d = elem_desc,
    } };
    const inserted = try self.emit(operation, self.mb.void_type);
    if (!move_item)
        try @TypeOf(self.*).dropEphemeralSharedAfterContainerCopy(self, insert.value, item_value, item_ty);
    return inserted;
}

pub fn lowerSparseTakeExpr(self: anytype, take: sir.SparseTake) LowerError!lir.ValueId {
    const sparse = try @TypeOf(self.*).lowerMutableSequencePlace(self, take.object, .sparse_take_from_place);
    const item_ty = try @TypeOf(self.*).sequenceItemType(self, sparse.ty);
    const result_ty = try self.mb.appendType(.{ .optional = item_ty });
    const index_value = try @TypeOf(self.*).lowerExprForTarget(self, take.index, self.mb.i64_type);
    const tmp_ptr = try self.emit(.{ .stack_alloc = item_ty }, item_ty);
    const found = try self.emit(.{ .sparse_take = .{
        .a = sparse.ptr,
        .b = index_value,
        .c = tmp_ptr,
        .d = try @TypeOf(self.*).emitTypeDesc(self, item_ty),
    } }, self.mb.bool_type);
    const result_ptr = try self.emit(.{ .stack_alloc = result_ty }, result_ty);
    const some_blk = try self.beginBlock("sparse_take_some");
    const none_blk = try self.beginBlock("sparse_take_none");
    const cont_blk = try self.beginBlock("sparse_take_cont");
    try self.endBlock(.{ .cond_br = .{
        .condition = found,
        .then_block = some_blk,
        .else_block = none_blk,
    } });

    self.current_block = some_blk;
    const payload = try self.emit(.{ .load = tmp_ptr }, item_ty);
    const some_value = try self.emit(.{ .make_some = payload }, result_ty);
    try self.emitVoid(.{ .store = .{ .ptr = result_ptr, .value = some_value } });
    try self.endBlock(.{ .br = cont_blk });

    self.current_block = none_blk;
    const none_value = try self.emit(.make_none, result_ty);
    try self.emitVoid(.{ .store = .{ .ptr = result_ptr, .value = none_value } });
    try self.endBlock(.{ .br = cont_blk });

    self.current_block = cont_blk;
    return self.emit(.{ .load = result_ptr }, result_ty);
}

pub fn lowerSequenceReserveExpr(self: anytype, reserve: sir.SequenceReserve) LowerError!lir.ValueId {
    const sequence = try @TypeOf(self.*).lowerMutableSequencePlace(self, reserve.object, .reserve_from_place);
    const list_ty = sequence.ty;
    const item_ty = try @TypeOf(self.*).sequenceItemType(self, list_ty);
    const capacity = try self.lowerExpr(reserve.capacity);
    return switch (self.mb.types.items[list_ty]) {
        .dense_array => @TypeOf(self.*).emitDenseArrayStorageReserve(self, sequence.ptr, item_ty, capacity),
        else => error.LowerInvariantViolation,
    };
}

pub fn lowerSequencePopExpr(self: anytype, object: *sir.Expr) LowerError!lir.ValueId {
    const sequence = try @TypeOf(self.*).lowerMutableSequencePlace(self, object, .pop_from_place);
    const list_ty = sequence.ty;
    const item_ty = try @TypeOf(self.*).sequenceItemType(self, list_ty);
    return @TypeOf(self.*).emitSequencePopValue(self, sequence.ptr, list_ty, item_ty);
}

pub fn lowerListIndexExpr(self: anytype, object: *sir.Expr, index_expr: *sir.Expr) LowerError!lir.ValueId {
    const list_ty = try @TypeOf(self.*).sequenceStorageType(self, try @TypeOf(self.*).lowerExprType(self, object));
    const item_ty = try @TypeOf(self.*).sequenceItemType(self, list_ty);
    const list_value = try @TypeOf(self.*).materializeSequenceValue(self, object);
    const index_value = try @TypeOf(self.*).lowerExprForTarget(self, index_expr, self.mb.i64_type);
    const elem_ptr = try @TypeOf(self.*).emitSequenceAtValue(self, list_value, list_ty, item_ty, index_value);
    return self.emit(.{ .load = elem_ptr }, item_ty);
}

pub fn emitSequencePushValue(
    self: anytype,
    list_ptr: lir.ValueId,
    list_ty: lir.TypeId,
    item_ty: lir.TypeId,
    item_value: lir.ValueId,
    item_expr: ?*sir.Expr,
) LowerError!lir.ValueId {
    const tmp_ptr = try self.emit(.{ .stack_alloc = item_ty }, item_ty);
    try self.emitVoid(.{ .store = .{ .ptr = tmp_ptr, .value = item_value } });
    const elem_desc = try @TypeOf(self.*).emitTypeDesc(self, item_ty);
    const pushed = switch (self.mb.types.items[list_ty]) {
        .dense_array => try self.emit(.{ .dense_push = .{
            .a = list_ptr,
            .b = tmp_ptr,
            .c = elem_desc,
        } }, self.mb.void_type),
        else => return error.LowerInvariantViolation,
    };
    try @TypeOf(self.*).dropEphemeralSharedAfterContainerCopy(self, item_expr, item_value, item_ty);
    return pushed;
}

pub fn emitDenseArrayStorageNew(
    self: anytype,
    storage_ty: lir.TypeId,
    item_ty: lir.TypeId,
) LowerError!lir.ValueId {
    return self.emit(.{ .dense_new = .{
        .value = try @TypeOf(self.*).emitTypeDesc(self, item_ty),
    } }, storage_ty);
}

pub fn emitDenseArrayStorageReserve(
    self: anytype,
    storage_ptr: lir.ValueId,
    item_ty: lir.TypeId,
    capacity_value: lir.ValueId,
) LowerError!lir.ValueId {
    const capacity_ty = try @TypeOf(self.*).lowerExprTypeFromValue(self, capacity_value);
    const reserve_capacity = if (@TypeOf(self.*).typeIdsEqual(self, capacity_ty, self.mb.i64_type))
        capacity_value
    else
        try self.emit(.{ .int_to_int = capacity_value }, self.mb.i64_type);
    return self.emit(.{ .dense_reserve = .{
        .a = storage_ptr,
        .b = reserve_capacity,
        .c = try @TypeOf(self.*).emitTypeDesc(self, item_ty),
    } }, self.mb.void_type);
}

pub fn emitDenseArrayStoragePushValue(
    self: anytype,
    storage_ptr: lir.ValueId,
    item_ty: lir.TypeId,
    item_value: lir.ValueId,
) LowerError!lir.ValueId {
    const tmp_ptr = try self.emit(.{ .stack_alloc = item_ty }, item_ty);
    try self.emitVoid(.{ .store = .{ .ptr = tmp_ptr, .value = item_value } });
    return self.emit(.{ .dense_push_move = .{
        .a = storage_ptr,
        .b = tmp_ptr,
        .c = try @TypeOf(self.*).emitTypeDesc(self, item_ty),
    } }, self.mb.void_type);
}

pub fn emitSequenceAtValue(
    self: anytype,
    storage_value: lir.ValueId,
    storage_ty: lir.TypeId,
    item_ty: lir.TypeId,
    index_value: lir.ValueId,
) LowerError!lir.ValueId {
    const ptr_ty = try self.mb.appendType(.{ .pointer = item_ty });
    const elem_desc = try @TypeOf(self.*).emitTypeDesc(self, item_ty);
    return switch (self.mb.types.items[storage_ty]) {
        .dense_array => self.emit(.{ .dense_at = .{
            .a = storage_value,
            .b = index_value,
            .c = elem_desc,
        } }, ptr_ty),
        else => error.LowerInvariantViolation,
    };
}

pub fn emitSequenceLenValue(self: anytype, sequence_value: lir.ValueId, sequence_ty: lir.TypeId, result_ty: lir.TypeId) LowerError!lir.ValueId {
    return switch (self.mb.types.items[sequence_ty]) {
        .dense_array => self.emit(.{ .dense_len = sequence_value }, result_ty),
        else => error.LowerInvariantViolation,
    };
}

pub fn emitSequenceClearValue(self: anytype, sequence_ptr: lir.ValueId, sequence_ty: lir.TypeId, item_ty: lir.TypeId) LowerError!lir.ValueId {
    return switch (self.mb.types.items[sequence_ty]) {
        .dense_array => self.emit(.{ .dense_clear = .{
            .lhs = sequence_ptr,
            .rhs = try @TypeOf(self.*).emitTypeDesc(self, item_ty),
        } }, self.mb.void_type),
        else => error.LowerInvariantViolation,
    };
}

pub fn emitSequencePopValue(self: anytype, sequence_ptr: lir.ValueId, sequence_ty: lir.TypeId, item_ty: lir.TypeId) LowerError!lir.ValueId {
    const tmp_ptr = try self.emit(.{ .stack_alloc = item_ty }, item_ty);
    switch (self.mb.types.items[sequence_ty]) {
        .dense_array => _ = try self.emit(.{ .dense_pop = .{
            .a = sequence_ptr,
            .b = tmp_ptr,
            .c = try @TypeOf(self.*).emitTypeDesc(self, item_ty),
        } }, self.mb.void_type),
        else => return error.LowerInvariantViolation,
    }
    return self.emit(.{ .load = tmp_ptr }, item_ty);
}

pub fn emitDefaultValue(self: anytype, ty: lir.TypeId) LowerError!lir.ValueId {
    return switch (self.mb.types.items[ty]) {
        .int => self.emit(.{ .const_int = 0 }, ty),
        .float => self.emit(.{ .const_float = 0.0 }, ty),
        .bool => self.emit(.{ .const_bool = false }, ty),
        .string => self.emit(.{ .const_string = try self.mb.allocator.dupe(u8, "") }, ty),
        .optional => self.emit(.make_none, ty),
        .array => |array_ty| blk: {
            const items = try self.mb.allocator.alloc(lir.ValueId, array_ty.len);
            for (items) |*item| {
                item.* = try @TypeOf(self.*).emitDefaultValue(self, array_ty.elem);
            }
            break :blk try self.emit(.{ .make_array = .{ .items = items } }, ty);
        },
        .@"struct" => |struct_ty| blk: {
            const fields = try self.mb.allocator.alloc(lir.ValueId, struct_ty.fields.len);
            for (struct_ty.fields, fields) |field, *out_field| {
                out_field.* = try @TypeOf(self.*).emitDefaultValue(self, field.ty);
            }
            break :blk try self.emit(.{ .make_struct = .{ .fields = fields } }, ty);
        },
        else => error.LowerInvariantViolation,
    };
}

pub fn materializeSequenceValue(self: anytype, expr: *sir.Expr) LowerError!lir.ValueId {
    const value = try self.lowerExpr(expr);
    const value_ty = try @TypeOf(self.*).lowerExprType(self, expr);
    return @TypeOf(self.*).materializeSequenceValueFromValue(self, value, value_ty);
}

pub fn sequenceStorageType(self: anytype, value_ty: lir.TypeId) LowerError!lir.TypeId {
    return switch (self.mb.types.items[value_ty]) {
        .dense_array, .sparse_array => value_ty,
        .pointer => |pointee| switch (self.mb.types.items[pointee]) {
            .dense_array, .sparse_array => pointee,
            else => error.LowerInvariantViolation,
        },
        else => error.LowerInvariantViolation,
    };
}

pub fn materializeSequenceValueFromValue(self: anytype, value: lir.ValueId, value_ty: lir.TypeId) LowerError!lir.ValueId {
    return switch (self.mb.types.items[value_ty]) {
        .dense_array => value,
        .sparse_array => value,
        .pointer => |pointee| switch (self.mb.types.items[pointee]) {
            .dense_array => self.emit(.{ .load = value }, pointee),
            .sparse_array => self.emit(.{ .load = value }, pointee),
            else => error.LowerInvariantViolation,
        },
        else => error.LowerInvariantViolation,
    };
}

pub fn sequenceItemType(self: anytype, list_ty: lir.TypeId) LowerError!lir.TypeId {
    return switch (self.mb.types.items[list_ty]) {
        .dense_array => |item_ty| item_ty,
        .sparse_array => |item_ty| item_ty,
        .pointer => |pointee| switch (self.mb.types.items[pointee]) {
            .dense_array => |item_ty| item_ty,
            .sparse_array => |item_ty| item_ty,
            else => error.LowerInvariantViolation,
        },
        else => error.LowerInvariantViolation,
    };
}

pub fn emitStoredTemp(self: anytype, ty: lir.TypeId, value: lir.ValueId) LowerError!lir.ValueId {
    const ptr = try self.emit(.{ .stack_alloc = ty }, ty);
    try self.emitVoid(.{ .store = .{ .ptr = ptr, .value = value } });
    return ptr;
}

pub fn emitElementSize(self: anytype, ty: lir.TypeId) LowerError!lir.ValueId {
    return self.emit(.{ .const_int = @intCast(try @TypeOf(self.*).byteSizeOfType(self, ty)) }, self.mb.i64_type);
}

pub fn emitTypeDesc(self: anytype, ty: lir.TypeId) LowerError!lir.ValueId {
    return self.emit(.{ .type_desc = ty }, self.mb.void_type);
}

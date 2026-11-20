const std = @import("std");
const sir = @import("../sema/sir.zig");
const identity = @import("../sema/identity.zig");
const lir = @import("lir.zig");
const errors = @import("errors.zig");
const type_policy = @import("type_policy.zig");
const ownership_lowering = @import("ownership_lowering.zig");
const runtime_symbols = @import("../../runtime/symbols.zig");
const LowerError = errors.Error;
const intCastBoundsForInfo = type_policy.intCastBoundsForInfo;
const intTypeAlwaysFits = type_policy.intTypeAlwaysFits;
const floatFiniteBounds = type_policy.floatFiniteBounds;
const valueSemanticsNeedsStringCleanup = ownership_lowering.valueSemanticsNeedsStringCleanup;
const valueSemanticsNeedsStringReceiverOwner = ownership_lowering.valueSemanticsNeedsStringReceiverOwner;

pub fn lower(self: anytype, expr: *sir.Expr) errors.Error!lir.ValueId {
    const metadata = try self.mb.exprMetadata(expr);
    if (!sir.intrinsicMatchesBuiltinExpr(expr, metadata.intrinsic_id)) {
        return error.InvalidIdentity;
    }
    return switch (expr.*) {
        .@"switch" => |switch_expr| try @TypeOf(self.*).lowerSwitchExpr(self, switch_expr),
        .failure_detail => |detail| blk: {
            var i = self.catch_stack.items.len;
            while (i != 0) {
                i -= 1;
                const scope = self.catch_stack.items[i];
                if (scope.failure_binding_id != null and scope.failure_binding_id.? == detail.binding_id) {
                    break :blk self.emit(.{ .trace_detail = .{
                        .carrier = scope.carrier,
                        .index = if (detail.index) |index| try self.lowerExpr(index) else null,
                        .field = switch (detail.field) {
                            .available => .available,
                            .origin => .origin,
                            .origin_file => .origin_file,
                            .site_count => .site_count,
                            .omitted => .omitted,
                            .message => .message,
                            .site => .site,
                            .site_file => .site_file,
                        },
                    } }, try self.mb.lowerCanonicalType(metadata.type_id));
                }
            }
            return error.LowerInvariantViolation;
        },
        .int => |int_expr| self.emit(
            .{ .const_int = int_expr.value },
            if (int_expr.type_name) |type_name|
                try self.mb.lowerExactNamedIntType(type_name)
            else
                self.mb.i64_type,
        ),
        .rune => |value| self.emit(.{ .const_int = value }, try self.mb.lowerType(.rune, null)),
        .float => |float_expr| self.emit(.{ .const_float = float_expr.value }, try self.mb.lowerType(.float, float_expr.type_name)),
        .bool => |value| self.emit(.{ .const_bool = value }, self.mb.bool_type),
        .is_test => |test_expr| try lowerIsTestExpr(self, test_expr),
        .string => |value| self.emit(.{ .const_string = try self.mb.allocator.dupe(u8, value) }, try self.mb.lowerType(.string, null)),
        .interpolated_string => |parts| try @TypeOf(self.*).lowerInterpolatedStringExpr(self, parts),
        .local => |name| blk: {
            if (self.getLocalIfPresent(name)) |local| {
                const value = try self.emit(.{ .load = local.ptr_value }, local.ty);
                if (!local.read_through_alias) break :blk value;
                const pointee_ty = try self.pointerPointee(local.ty) orelse return error.LowerInvariantViolation;
                break :blk try self.emit(.{ .load = value }, pointee_ty);
            }
            const global = self.getGlobalInfo(name) orelse return error.MissingLocal;
            if (global.is_symbol_addr) {
                const pointee_ty = switch (self.mb.types.items[global.ty]) {
                    .pointer => |pointee| pointee,
                    else => return error.LowerInvariantViolation,
                };
                break :blk try self.emitGlobalSymbolAddr(global, pointee_ty);
            }
            const global_ptr = try self.emitGlobalSymbolAddr(global, global.ty);
            break :blk try self.emit(.{ .load = global_ptr }, global.ty);
        },
        .global_ref => |global_ref| blk: {
            const global = try self.mb.globalById(global_ref.decl_id orelse return error.InvalidIdentity);
            if (global.is_symbol_addr) {
                const pointee_ty = switch (self.mb.types.items[global.ty]) {
                    .pointer => |pointee| pointee,
                    else => return error.LowerInvariantViolation,
                };
                break :blk try self.emitGlobalSymbolAddr(global, pointee_ty);
            }
            const global_ptr = try self.emitGlobalSymbolAddr(global, global.ty);
            break :blk try self.emit(.{ .load = global_ptr }, global.ty);
        },
        .function_ref => |function_ref| blk: {
            const symbol_name = try self.mb.functionSymbol(function_ref);
            const ptr_ty = try self.mb.appendType(.{ .pointer = self.mb.void_type });
            break :blk try self.emit(.{ .global_addr = try self.mb.allocator.dupe(u8, symbol_name) }, ptr_ty);
        },
        .closure => |closure| try self.lowerClosure(closure),
        .closure_capture => |capture| try self.lowerClosureCapture(capture),
        .handoff_local => |name| blk: {
            if (metadata.consumption.transfer != .move) return error.InvalidIdentity;
            const local = try self.getLocal(name);
            try @TypeOf(self.*).recordOwnershipTrace(self, "handoff {s}: source cleanup suppressed", .{name});
            self.markCleanupInactive(local);
            break :blk try self.emit(.{ .load = local.ptr_value }, local.ty);
        },
        .take_index_local => |take_index| blk: {
            if (metadata.consumption.transfer != .take) return error.InvalidIdentity;
            break :blk try @TypeOf(self.*).lowerTakeIndexLocal(self, take_index);
        },
        .take_index_path_local => |take_path| blk: {
            if (metadata.consumption.transfer != .take) return error.InvalidIdentity;
            break :blk try @TypeOf(self.*).lowerTakeIndexPathLocal(self, take_path);
        },
        .take_path_local => |take_path| blk: {
            if (metadata.consumption.transfer != .take) return error.InvalidIdentity;
            break :blk try @TypeOf(self.*).lowerTakePathLocal(self, take_path);
        },
        .ref_local => |name| blk: {
            const local = try self.getLocal(name);
            break :blk switch (self.mb.types.items[local.ty]) {
                .pointer => try self.emit(.{ .load = local.ptr_value }, local.ty),
                else => local.ptr_value,
            };
        },
        .ref_global => |global_ref| blk: {
            const global = try self.mb.globalById(global_ref.decl_id orelse return error.InvalidIdentity);
            break :blk try self.emitGlobalSymbolAddr(global, global.ty);
        },
        .ref_alias_local => |name| blk: {
            const local = try self.getLocal(name);
            break :blk switch (self.mb.types.items[local.ty]) {
                .pointer => try self.emit(.{ .load = local.ptr_value }, local.ty),
                else => local.ptr_value,
            };
        },
        .ref_owned_local, .raw_owned_local => |name| (try self.getLocal(name)).ptr_value,
        .leak_owned_local => |name| blk: {
            const local = try self.getLocal(name);
            try @TypeOf(self.*).recordOwnershipTrace(self, "leak {s}: source cleanup suppressed", .{name});
            self.markCleanupInactive(local);
            const value = try self.emit(.{ .load = local.ptr_value }, local.ty);
            const ptr_ty = try self.mb.appendType(.{ .pointer = local.ty });
            break :blk try self.emit(.{ .heap_alloc = value }, ptr_ty);
        },
        .ref_raw_deref => |raw_expr| try self.lowerExpr(raw_expr.expr),
        .raw_deref => |raw_expr| blk: {
            const ptr_value = try self.lowerExpr(raw_expr.expr);
            const ptr_ty = try @TypeOf(self.*).lowerExprType(self, raw_expr.expr);
            const pointee = switch (self.mb.types.items[ptr_ty]) {
                .pointer => |pointee| pointee,
                else => return error.LowerInvariantViolation,
            };
            break :blk try self.emit(if (raw_expr.is_volatile) .{ .volatile_load = ptr_value } else .{ .load = ptr_value }, pointee);
        },
        .from_raw => |value| blk: {
            const ptr_value = try self.lowerExpr(value.expr);
            const ptr_ty = try @TypeOf(self.*).lowerExprType(self, value.expr);
            const pointee = switch (self.mb.types.items[ptr_ty]) {
                .pointer => |pointee| pointee,
                else => return error.LowerInvariantViolation,
            };
            break :blk try self.emit(if (value.is_volatile) .{ .volatile_load = ptr_value } else .{ .load = ptr_value }, pointee);
        },
        .ref_field_local => |field| try @TypeOf(self.*).lowerRefFieldLocal(self, field),
        .ref_field_owned_local => |field| try @TypeOf(self.*).lowerRefFieldOwnedLocal(self, field),
        .ref_field_expr => |field| try @TypeOf(self.*).lowerRefFieldExpr(self, field),
        .ref_union_field_local => |field| try @TypeOf(self.*).lowerRefUnionFieldLocal(self, field),
        .ref_index_local => |index_ref| try @TypeOf(self.*).lowerRefIndexLocal(self, index_ref),
        .ref_index_path_local => |index_ref| try @TypeOf(self.*).lowerRefIndexPathLocal(self, index_ref),
        .ref_path_local => |take_path| try @TypeOf(self.*).lowerRefPathLocal(self, take_path),
        .ref_load => |ref_expr| blk: {
            const ptr = try self.lowerExpr(ref_expr);
            const ptr_ty = try @TypeOf(self.*).lowerExprType(self, ref_expr);
            break :blk try self.emit(.{ .load = ptr }, try self.pointerPointee(ptr_ty) orelse return error.LowerInvariantViolation);
        },
        .unary => |unary| try @TypeOf(self.*).lowerUnary(self, unary),
        .binary => |bin| try @TypeOf(self.*).lowerBinary(self, bin),
        .cast => |cast| try @TypeOf(self.*).lowerCastExpr(self, cast),
        .call => |call| try self.lowerCall(call),
        .thread_spawn_boxed => |spawn| try self.lowerThreadSpawnBoxed(spawn),
        .task_group_spawn_boxed => |spawn| try self.lowerTaskGroupSpawnBoxed(spawn),
        .task_result_take => |take| try self.lowerTaskResultTake(take),
        .sync_share_boxed => |share| try self.lowerSyncShareBoxed(share),
        .indirect_call => |call| try self.lowerIndirectCall(call),
        .test_assert => |condition| try @TypeOf(self.*).lowerTestAssertExpr(self, condition),
        .builtin_print => |print| try @TypeOf(self.*).lowerBuiltinPrintExpr(self, print),
        .sequence_push => |push| try @TypeOf(self.*).lowerSequencePushExpr(self, push),
        .sequence_len => |object| try @TypeOf(self.*).lowerSequenceLenExpr(self, object, try self.mb.lowerCanonicalType(metadata.type_id)),
        .sparse_len => |object| try @TypeOf(self.*).lowerSparseLenExpr(self, object, try self.mb.lowerCanonicalType(metadata.type_id)),
        .slice_len => |object| try @TypeOf(self.*).lowerSliceLenExpr(self, object, try self.mb.lowerCanonicalType(metadata.type_id)),
        .slice_ptr => |object| blk: {
            const slice_value = try self.lowerExpr(object);
            break :blk try self.emit(.{ .extract_slice_ptr = slice_value }, try self.mb.lowerCanonicalType(metadata.type_id));
        },
        .sequence_clear => |object| try @TypeOf(self.*).lowerSequenceClearExpr(self, object),
        .sparse_clear => |object| try @TypeOf(self.*).lowerSparseClearExpr(self, object),
        .sparse_indices => |object| try @TypeOf(self.*).lowerSparseIndicesExpr(self, object),
        .sparse_insert => |insert| try @TypeOf(self.*).lowerSparseInsertExpr(self, insert),
        .sparse_contains_index => |contains| try @TypeOf(self.*).lowerSparseContainsIndexExpr(self, contains),
        .sparse_take => |take| blk: {
            if (metadata.consumption.transfer != .take) return error.InvalidIdentity;
            break :blk try @TypeOf(self.*).lowerSparseTakeExpr(self, take);
        },
        .sequence_reserve => |reserve| try @TypeOf(self.*).lowerSequenceReserveExpr(self, reserve),
        .sequence_pop => |object| try @TypeOf(self.*).lowerSequencePopExpr(self, object),
        .string_len => |object| try @TypeOf(self.*).lowerStringLenExpr(self, object, try self.mb.lowerCanonicalType(metadata.type_id)),
        .string_is_empty => |object| try @TypeOf(self.*).lowerStringIsEmptyExpr(self, object),
        .string_bytes => |object| try @TypeOf(self.*).lowerStringBytesExpr(self, object),
        .string_from => |bytes| try @TypeOf(self.*).lowerStringFromExpr(self, bytes),
        .string_starts_with => |contains| try @TypeOf(self.*).lowerStringContainsExpr(self, contains, runtime_symbols.name(.string_starts_with)),
        .string_ends_with => |contains| try @TypeOf(self.*).lowerStringContainsExpr(self, contains, runtime_symbols.name(.string_ends_with)),
        .string_contains => |contains| try @TypeOf(self.*).lowerStringContainsExpr(self, contains, runtime_symbols.name(.string_contains)),
        .string_find => |contains| try @TypeOf(self.*).lowerStringFindExpr(self, contains, runtime_symbols.name(.string_find)),
        .string_rfind => |contains| try @TypeOf(self.*).lowerStringFindExpr(self, contains, runtime_symbols.name(.string_rfind)),
        .string_slice => |slice| try @TypeOf(self.*).lowerStringSliceExpr(self, slice),
        .@"try" => |try_expr| try @TypeOf(self.*).lowerTryExprFromNode(self, try_expr),
        .new_owned => |literal| try @TypeOf(self.*).lowerStructLiteralExpr(self, literal),
        .array_literal => |literal| try @TypeOf(self.*).lowerArrayLiteralExpr(self, literal),
        .tuple_literal => |literal| try @TypeOf(self.*).lowerTupleLiteralExpr(self, literal),
        .array_default => |literal| try @TypeOf(self.*).lowerArrayDefaultExpr(self, literal),
        .new_array => |new_array| try @TypeOf(self.*).lowerNewArrayExpr(self, new_array),
        .dense_array_literal => |literal| try @TypeOf(self.*).lowerDenseArrayLiteralExpr(self, literal),
        .sparse_literal => |literal| try @TypeOf(self.*).lowerSparseLiteralExpr(self, literal),
        .sparse_keyed_literal => |literal| try @TypeOf(self.*).lowerSparseKeyedLiteralExpr(self, literal),
        .new_sparse => |storage| try @TypeOf(self.*).lowerNewSparseExpr(self, storage),
        .slice_range => |slice| try @TypeOf(self.*).lowerSliceRangeExpr(self, slice),
        .struct_literal => |literal| try @TypeOf(self.*).lowerStructLiteralExpr(self, literal),
        .asm_expr => |asm_expr| try @TypeOf(self.*).lowerAsmExpr(self, asm_expr),
        .index => |index| try @TypeOf(self.*).lowerIndexExpr(self, index),
        .borrowed_index => |index| try @TypeOf(self.*).lowerBorrowedIndexExpr(self, index),
        .field => |field| try @TypeOf(self.*).lowerFieldExpr(self, field),
        .tuple_field => |field| try @TypeOf(self.*).lowerTupleFieldExpr(self, field),
        .borrowed_field => |field| try @TypeOf(self.*).lowerBorrowedFieldExpr(self, field),
        .union_field => |field| try @TypeOf(self.*).lowerUnionFieldExpr(self, field),
        .borrowed_union_field => |field| try @TypeOf(self.*).lowerBorrowedUnionFieldExpr(self, field),
        .union_case => |case| try @TypeOf(self.*).lowerUnionCaseExpr(self, case),
        .enum_case => |case| self.emit(.{ .const_int = case.value }, try self.mb.lowerEnumTypeById(case.decl_id orelse return error.InvalidIdentity)),
        else => error.LowerInvariantViolation,
    };
}

// Expression operation interface.
pub fn lowerBinary(self: anytype, bin: sir.Binary) LowerError!lir.ValueId {
    if ((bin.op == .eq or bin.op == .ne) and (bin.left.* == .none or bin.right.* == .none)) {
        return @TypeOf(self.*).lowerOptionalNoneCompare(self, bin);
    }
    if (bin.op == .@"and" or bin.op == .@"or") {
        return @TypeOf(self.*).lowerShortCircuitBinary(self, bin);
    }

    const cleanup_start = self.ownership.cleanup_entries.items.len;
    const lhs = try self.lowerExpr(bin.left);
    var rhs = try self.lowerExpr(bin.right);
    const lhs_ty = try @TypeOf(self.*).lowerExprType(self, bin.left);
    const rhs_ty = try @TypeOf(self.*).lowerExprType(self, bin.right);
    if (bin.op == .add and self.mb.types.items[lhs_ty] == .pointer) {
        const index = if (rhs_ty == self.mb.i64_type) rhs else try self.emit(.{ .int_to_int = rhs }, self.mb.i64_type);
        return @TypeOf(self.*).finishBinaryResult(self, try self.emit(.{ .index_ptr = .{
            .ptr = lhs,
            .index = index,
        } }, lhs_ty), cleanup_start);
    }
    if (bin.op == .in) {
        return @TypeOf(self.*).finishBinaryResult(self, try @TypeOf(self.*).lowerContainsBinary(self, lhs, rhs, lhs_ty, rhs_ty), cleanup_start);
    }
    if (self.mb.types.items[lhs_ty] == .string and (bin.op == .eq or bin.op == .ne)) {
        const result = try self.emit(.{ .string_cmp = .{
            .op = if (bin.op == .eq) .eq else .ne,
            .lhs = lhs,
            .rhs = rhs,
        } }, self.mb.bool_type);
        try @TypeOf(self.*).dropStringCompareTemporary(self, bin.left, lhs, lhs_ty);
        try @TypeOf(self.*).dropStringCompareTemporary(self, bin.right, rhs, rhs_ty);
        return @TypeOf(self.*).finishBinaryResult(self, result, cleanup_start);
    }
    if (bin.op == .eq or bin.op == .ne) {
        if (try @TypeOf(self.*).lowerSequenceCompare(self, bin, lhs, rhs, lhs_ty, rhs_ty)) |value| return @TypeOf(self.*).finishBinaryResult(self, value, cleanup_start);
    }
    if (self.mb.types.items[lhs_ty] == .float or self.mb.types.items[rhs_ty] == .float) {
        const target_ty = if (self.mb.types.items[lhs_ty] == .float) lhs_ty else rhs_ty;
        const float_lhs = if (self.mb.types.items[lhs_ty] == .float) lhs else try self.emit(.{ .int_to_float = lhs }, target_ty);
        const float_rhs = if (self.mb.types.items[rhs_ty] == .float) rhs else try self.emit(.{ .int_to_float = rhs }, target_ty);
        const result = switch (bin.op) {
            .add => self.emit(.{ .float_binop = .{ .op = .add, .lhs = float_lhs, .rhs = float_rhs } }, target_ty),
            .sub => self.emit(.{ .float_binop = .{ .op = .sub, .lhs = float_lhs, .rhs = float_rhs } }, target_ty),
            .mul => self.emit(.{ .float_binop = .{ .op = .mul, .lhs = float_lhs, .rhs = float_rhs } }, target_ty),
            .div => self.emit(.{ .float_binop = .{ .op = .div, .lhs = float_lhs, .rhs = float_rhs } }, target_ty),
            .mod => error.LowerInvariantViolation,
            .eq => self.emit(.{ .float_cmp = .{ .op = .eq, .lhs = float_lhs, .rhs = float_rhs } }, self.mb.bool_type),
            .ne => self.emit(.{ .float_cmp = .{ .op = .ne, .lhs = float_lhs, .rhs = float_rhs } }, self.mb.bool_type),
            .lt => self.emit(.{ .float_cmp = .{ .op = .lt, .lhs = float_lhs, .rhs = float_rhs } }, self.mb.bool_type),
            .le => self.emit(.{ .float_cmp = .{ .op = .le, .lhs = float_lhs, .rhs = float_rhs } }, self.mb.bool_type),
            .gt => self.emit(.{ .float_cmp = .{ .op = .gt, .lhs = float_lhs, .rhs = float_rhs } }, self.mb.bool_type),
            .ge => self.emit(.{ .float_cmp = .{ .op = .ge, .lhs = float_lhs, .rhs = float_rhs } }, self.mb.bool_type),
            else => error.LowerInvariantViolation,
        };
        return @TypeOf(self.*).finishBinaryResult(self, try result, cleanup_start);
    }
    if (lhs_ty != rhs_ty) {
        switch (self.mb.types.items[lhs_ty]) {
            .int => switch (self.mb.types.items[rhs_ty]) {
                .int => rhs = try self.emit(.{ .int_to_int = rhs }, lhs_ty),
                else => {},
            },
            else => {},
        }
    }
    const result = switch (bin.op) {
        .add => self.emit(.{ .int_binop = .{ .op = .add, .lhs = lhs, .rhs = rhs } }, lhs_ty),
        .wrap_add => self.emit(.{ .int_binop = .{ .op = .wrap_add, .lhs = lhs, .rhs = rhs } }, lhs_ty),
        .sub => self.emit(.{ .int_binop = .{ .op = .sub, .lhs = lhs, .rhs = rhs } }, lhs_ty),
        .wrap_sub => self.emit(.{ .int_binop = .{ .op = .wrap_sub, .lhs = lhs, .rhs = rhs } }, lhs_ty),
        .mul => self.emit(.{ .int_binop = .{ .op = .mul, .lhs = lhs, .rhs = rhs } }, lhs_ty),
        .wrap_mul => self.emit(.{ .int_binop = .{ .op = .wrap_mul, .lhs = lhs, .rhs = rhs } }, lhs_ty),
        .div => self.emit(.{ .int_binop = .{ .op = .div, .lhs = lhs, .rhs = rhs } }, lhs_ty),
        .mod => self.emit(.{ .int_binop = .{ .op = .mod, .lhs = lhs, .rhs = rhs } }, lhs_ty),
        .shl => self.emit(.{ .int_binop = .{ .op = .shl, .lhs = lhs, .rhs = rhs } }, lhs_ty),
        .shr => self.emit(.{ .int_binop = .{ .op = .shr, .lhs = lhs, .rhs = rhs } }, lhs_ty),
        .bit_and => self.emit(.{ .int_binop = .{ .op = .bit_and, .lhs = lhs, .rhs = rhs } }, lhs_ty),
        .bit_or => self.emit(.{ .int_binop = .{ .op = .bit_or, .lhs = lhs, .rhs = rhs } }, lhs_ty),
        .bit_xor => self.emit(.{ .int_binop = .{ .op = .bit_xor, .lhs = lhs, .rhs = rhs } }, lhs_ty),
        .eq => self.emit(.{ .int_cmp = .{ .op = .eq, .lhs = lhs, .rhs = rhs } }, self.mb.bool_type),
        .ne => self.emit(.{ .int_cmp = .{ .op = .ne, .lhs = lhs, .rhs = rhs } }, self.mb.bool_type),
        .lt => self.emit(.{ .int_cmp = .{ .op = .lt, .lhs = lhs, .rhs = rhs } }, self.mb.bool_type),
        .le => self.emit(.{ .int_cmp = .{ .op = .le, .lhs = lhs, .rhs = rhs } }, self.mb.bool_type),
        .gt => self.emit(.{ .int_cmp = .{ .op = .gt, .lhs = lhs, .rhs = rhs } }, self.mb.bool_type),
        .ge => self.emit(.{ .int_cmp = .{ .op = .ge, .lhs = lhs, .rhs = rhs } }, self.mb.bool_type),
        else => error.LowerInvariantViolation,
    };
    return @TypeOf(self.*).finishBinaryResult(self, try result, cleanup_start);
}

pub fn finishBinaryResult(self: anytype, result: lir.ValueId, cleanup_start: usize) LowerError!lir.ValueId {
    try @TypeOf(self.*).emitFullExpressionAutoDropsFrom(self, cleanup_start, "binary");
    return result;
}

pub fn dropStringCompareTemporary(self: anytype, expr: *sir.Expr, value: lir.ValueId, ty: lir.TypeId) LowerError!void {
    if (self.mb.types.items[ty] != .string) return;
    const needs_cleanup = valueSemanticsNeedsStringCleanup((try self.mb.exprMetadata(expr)).semantics);
    if (needs_cleanup) try @TypeOf(self.*).emitDropValue(self, value, ty);
}

pub fn lowerSequenceCompare(
    self: anytype,
    bin: sir.Binary,
    lhs: lir.ValueId,
    rhs: lir.ValueId,
    lhs_ty: lir.TypeId,
    rhs_ty: lir.TypeId,
) LowerError!?lir.ValueId {
    const op: lir.SequenceCmp.Op = if (bin.op == .eq) .eq else .ne;
    return switch (self.mb.types.items[lhs_ty]) {
        .array => |array_ty| blk: {
            const rhs_array = switch (self.mb.types.items[rhs_ty]) {
                .array => |right| right,
                else => break :blk null,
            };
            if (array_ty.len != rhs_array.len or !@TypeOf(self.*).typeIdsEqual(self, array_ty.elem, rhs_array.elem)) break :blk null;
            try @TypeOf(self.*).expectSequenceComparableElement(self, array_ty.elem);
            const elem_ptr_ty = try self.mb.appendType(.{ .pointer = array_ty.elem });
            const lhs_ptr = try @TypeOf(self.*).emitStoredTemp(self, lhs_ty, lhs);
            const rhs_ptr = try @TypeOf(self.*).emitStoredTemp(self, rhs_ty, rhs);
            const zero = try self.emit(.{ .const_int = 0 }, self.mb.i64_type);
            const lhs_elem = try self.emit(.{ .index_ptr = .{ .ptr = lhs_ptr, .index = zero } }, elem_ptr_ty);
            const rhs_elem = try self.emit(.{ .index_ptr = .{ .ptr = rhs_ptr, .index = zero } }, elem_ptr_ty);
            const len = try self.emit(.{ .const_int = @intCast(array_ty.len) }, self.mb.i64_type);
            const elem_desc = try @TypeOf(self.*).emitTypeDesc(self, array_ty.elem);
            break :blk try self.emit(.{ .sequence_cmp = .{
                .op = op,
                .lhs_ptr = lhs_elem,
                .lhs_len = len,
                .rhs_ptr = rhs_elem,
                .rhs_len = len,
                .elem_desc = elem_desc,
            } }, self.mb.bool_type);
        },
        .slice => |item_ty| blk: {
            const rhs_item_ty = switch (self.mb.types.items[rhs_ty]) {
                .slice => |right| right,
                else => break :blk null,
            };
            if (!@TypeOf(self.*).typeIdsEqual(self, item_ty, rhs_item_ty)) break :blk null;
            try @TypeOf(self.*).expectSequenceComparableElement(self, item_ty);
            const ptr_ty = try self.mb.appendType(.{ .pointer = item_ty });
            const lhs_ptr = try self.emit(.{ .extract_slice_ptr = lhs }, ptr_ty);
            const lhs_len = try self.emit(.{ .extract_slice_len = lhs }, self.mb.i64_type);
            const rhs_ptr = try self.emit(.{ .extract_slice_ptr = rhs }, ptr_ty);
            const rhs_len = try self.emit(.{ .extract_slice_len = rhs }, self.mb.i64_type);
            const elem_desc = try @TypeOf(self.*).emitTypeDesc(self, item_ty);
            break :blk try self.emit(.{ .sequence_cmp = .{
                .op = op,
                .lhs_ptr = lhs_ptr,
                .lhs_len = lhs_len,
                .rhs_ptr = rhs_ptr,
                .rhs_len = rhs_len,
                .elem_desc = elem_desc,
            } }, self.mb.bool_type);
        },
        .dense_array => |item_ty| blk: {
            const rhs_item_ty = switch (self.mb.types.items[rhs_ty]) {
                .dense_array => |right| right,
                else => break :blk null,
            };
            if (!@TypeOf(self.*).typeIdsEqual(self, item_ty, rhs_item_ty)) break :blk null;
            try @TypeOf(self.*).expectSequenceComparableElement(self, item_ty);
            const ptr_ty = try self.mb.appendType(.{ .pointer = item_ty });
            const lhs_value = try @TypeOf(self.*).materializeSequenceValueFromValue(self, lhs, lhs_ty);
            const rhs_value = try @TypeOf(self.*).materializeSequenceValueFromValue(self, rhs, rhs_ty);
            const lhs_ptr = try self.emit(.{ .dense_data = lhs_value }, ptr_ty);
            const lhs_len = try @TypeOf(self.*).emitSequenceLenValue(self, lhs_value, lhs_ty, self.mb.i64_type);
            const rhs_ptr = try self.emit(.{ .dense_data = rhs_value }, ptr_ty);
            const rhs_len = try @TypeOf(self.*).emitSequenceLenValue(self, rhs_value, rhs_ty, self.mb.i64_type);
            const elem_desc = try @TypeOf(self.*).emitTypeDesc(self, item_ty);
            break :blk try self.emit(.{ .sequence_cmp = .{
                .op = op,
                .lhs_ptr = lhs_ptr,
                .lhs_len = lhs_len,
                .rhs_ptr = rhs_ptr,
                .rhs_len = rhs_len,
                .elem_desc = elem_desc,
            } }, self.mb.bool_type);
        },
        .sparse_array => |item_ty| blk: {
            const rhs_item_ty = switch (self.mb.types.items[rhs_ty]) {
                .sparse_array => |right| right,
                else => break :blk null,
            };
            if (!@TypeOf(self.*).typeIdsEqual(self, item_ty, rhs_item_ty)) break :blk null;
            try @TypeOf(self.*).expectSequenceComparableElement(self, item_ty);
            const lhs_value = try @TypeOf(self.*).materializeSequenceValueFromValue(self, lhs, lhs_ty);
            const rhs_value = try @TypeOf(self.*).materializeSequenceValueFromValue(self, rhs, rhs_ty);
            const elem_desc = try @TypeOf(self.*).emitTypeDesc(self, item_ty);
            break :blk try self.emit(.{ .sparse_cmp = .{
                .op = if (bin.op == .eq) .eq else .ne,
                .lhs = lhs_value,
                .rhs = rhs_value,
                .elem_desc = elem_desc,
            } }, self.mb.bool_type);
        },
        else => null,
    };
}

pub fn expectSequenceComparableElement(self: anytype, ty: lir.TypeId) LowerError!void {
    return switch (self.mb.types.items[ty]) {
        .int, .float, .bool, .string => {},
        else => error.LowerInvariantViolation,
    };
}

pub fn lowerContainsBinary(
    self: anytype,
    lhs: lir.ValueId,
    rhs: lir.ValueId,
    lhs_ty: lir.TypeId,
    _: lir.TypeId,
) LowerError!lir.ValueId {
    const masked = try self.emit(.{ .int_binop = .{
        .op = .bit_and,
        .lhs = rhs,
        .rhs = lhs,
    } }, lhs_ty);
    return self.emit(.{ .int_cmp = .{
        .op = .eq,
        .lhs = masked,
        .rhs = lhs,
    } }, self.mb.bool_type);
}

pub fn lowerCastExpr(self: anytype, cast: sir.CastExpr) LowerError!lir.ValueId {
    const target_ty = try @TypeOf(self.*).lowerCastTargetType(self, cast);
    const target_node = try self.mb.canonicalTypeNode(cast.target_type_id);
    if (target_node.* == .primitive and target_node.primitive == .c_str) {
        return switch (cast.subject.*) {
            .string => |value| self.emit(.{ .const_c_str = try self.mb.allocator.dupe(u8, value) }, target_ty),
            else => error.LowerInvariantViolation,
        };
    }
    if (cast.reinterpret) {
        const subject_ty = try @TypeOf(self.*).lowerExprType(self, cast.subject);
        return switch (self.mb.types.items[target_ty]) {
            .int => switch (self.mb.types.items[subject_ty]) {
                .int => try @TypeOf(self.*).lowerIntToIntReinterpretCast(self, cast),
                .float => try @TypeOf(self.*).lowerBitcastReinterpretCast(self, cast),
                .@"struct" => try @TypeOf(self.*).lowerPackedStructToIntCast(self, cast),
                .pointer => try @TypeOf(self.*).lowerRawPtrToIntCast(self, cast),
                else => error.LowerInvariantViolation,
            },
            .float => switch (self.mb.types.items[subject_ty]) {
                .int => try @TypeOf(self.*).lowerBitcastReinterpretCast(self, cast),
                else => error.LowerInvariantViolation,
            },
            .pointer => switch (self.mb.types.items[subject_ty]) {
                .int => try @TypeOf(self.*).lowerIntToRawPtrCast(self, cast),
                .pointer => try @TypeOf(self.*).lowerBitcastReinterpretCast(self, cast),
                else => error.LowerInvariantViolation,
            },
            .@"struct" => switch (self.mb.types.items[subject_ty]) {
                .int => try @TypeOf(self.*).lowerIntToPackedStructCast(self, cast),
                else => error.LowerInvariantViolation,
            },
            else => error.LowerInvariantViolation,
        };
    }

    const subject_ty = try @TypeOf(self.*).lowerExprType(self, cast.subject);
    if (self.mb.types.items[subject_ty] == .optional) {
        return @TypeOf(self.*).lowerOptionalPayloadCast(self, cast);
    }
    if (self.mb.types.items[subject_ty] == .@"union") {
        return switch (self.mb.types.items[target_ty]) {
            .int, .float, .string, .bool, .@"struct" => @TypeOf(self.*).lowerUnionPayloadCast(self, cast),
            else => error.LowerInvariantViolation,
        };
    }
    if (switch ((try self.mb.canonicalTypeNode(cast.target_type_id)).*) {
        .nominal => |nominal| nominal.kind == .@"enum",
        else => false,
    }) {
        return switch (self.mb.types.items[subject_ty]) {
            .int => try @TypeOf(self.*).lowerIntToEnumCast(self, cast),
            else => error.LowerInvariantViolation,
        };
    }
    if (target_node.* == .primitive and target_node.primitive == .rune) {
        return @TypeOf(self.*).lowerIntToCharCast(self, cast);
    }
    return switch (self.mb.types.items[target_ty]) {
        .float => switch (self.mb.types.items[subject_ty]) {
            .float => try @TypeOf(self.*).lowerFloatToFloatCast(self, cast),
            .int => try @TypeOf(self.*).lowerIntToFloatCast(self, cast),
            else => error.LowerInvariantViolation,
        },
        .int => switch (self.mb.types.items[subject_ty]) {
            .float => try @TypeOf(self.*).lowerFloatToIntCast(self, cast),
            .int => try @TypeOf(self.*).lowerIntToIntCast(self, cast),
            else => error.LowerInvariantViolation,
        },
        else => error.LowerInvariantViolation,
    };
}

pub fn lowerCastTargetType(self: anytype, cast: sir.CastExpr) LowerError!lir.TypeId {
    return self.mb.lowerCanonicalType(cast.target_type_id);
}

pub fn lowerOptionalPayloadCast(self: anytype, cast: sir.CastExpr) LowerError!lir.ValueId {
    const subject = try self.lowerExpr(cast.subject);
    const subject_ty = try @TypeOf(self.*).lowerExprType(self, cast.subject);
    const target_ty = switch (self.mb.types.items[subject_ty]) {
        .optional => |payload_ty| payload_ty,
        else => return error.LowerInvariantViolation,
    };
    return @TypeOf(self.*).lowerPresenceCheckedCast(self, subject, target_ty, cast.fallible, null);
}

pub fn lowerIntToIntCast(self: anytype, cast: sir.CastExpr) LowerError!lir.ValueId {
    const subject = try self.lowerExpr(cast.subject);
    const target_ty = try @TypeOf(self.*).lowerCastTargetType(self, cast);
    const subject_ty = try @TypeOf(self.*).lowerExprType(self, cast.subject);
    const converted = if (@TypeOf(self.*).typeIdsEqual(self, subject_ty, target_ty))
        subject
    else
        try self.emit(.{ .int_to_int = subject }, target_ty);

    const always_valid = blk: {
        if (@TypeOf(self.*).typeIdsEqual(self, subject_ty, self.mb.i64_type) and @TypeOf(self.*).typeIdsEqual(self, target_ty, self.mb.i64_type)) break :blk false;
        const src_int = switch (self.mb.types.items[subject_ty]) {
            .int => |int_ty| int_ty,
            else => break :blk false,
        };
        const dst_int = switch (self.mb.types.items[target_ty]) {
            .int => |int_ty| int_ty,
            else => break :blk false,
        };
        break :blk intTypeAlwaysFits(src_int, dst_int);
    };
    if (always_valid) {
        if (cast.fallible) {
            const valid = try self.emit(.{ .const_bool = true }, self.mb.bool_type);
            return @TypeOf(self.*).finishCheckedCast(self, valid, converted, true);
        }
        return converted;
    }

    const valid = try @TypeOf(self.*).emitIntFitsType(self, subject, target_ty);
    return @TypeOf(self.*).finishCheckedCast(self, valid, converted, cast.fallible);
}

pub fn lowerIntToCharCast(self: anytype, cast: sir.CastExpr) LowerError!lir.ValueId {
    const subject = try self.lowerExpr(cast.subject);
    const target_ty = try @TypeOf(self.*).lowerCastTargetType(self, cast);
    const subject_ty = try @TypeOf(self.*).lowerExprType(self, cast.subject);
    const converted = if (@TypeOf(self.*).typeIdsEqual(self, subject_ty, target_ty))
        subject
    else
        try self.emit(.{ .int_to_int = subject }, target_ty);
    const check_ty = self.mb.i64_type;
    const check_value = if (@TypeOf(self.*).typeIdsEqual(self, subject_ty, check_ty))
        subject
    else
        try self.emit(.{ .int_to_int = subject }, check_ty);
    const zero = try self.emit(.{ .const_int = 0 }, check_ty);
    const max_scalar = try self.emit(.{ .const_int = 0x10ffff }, check_ty);
    const surrogate_start = try self.emit(.{ .const_int = 0xd800 }, check_ty);
    const surrogate_end = try self.emit(.{ .const_int = 0xdfff }, check_ty);
    const nonnegative = try self.emit(.{ .int_cmp = .{ .op = .ge, .lhs = check_value, .rhs = zero } }, self.mb.bool_type);
    const in_range = try self.emit(.{ .int_cmp = .{ .op = .le, .lhs = check_value, .rhs = max_scalar } }, self.mb.bool_type);
    const below_surrogates = try self.emit(.{ .int_cmp = .{ .op = .lt, .lhs = check_value, .rhs = surrogate_start } }, self.mb.bool_type);
    const above_surrogates = try self.emit(.{ .int_cmp = .{ .op = .gt, .lhs = check_value, .rhs = surrogate_end } }, self.mb.bool_type);
    const outside_surrogates = try @TypeOf(self.*).emitBoolOr(self, below_surrogates, above_surrogates);
    const bounded = try @TypeOf(self.*).emitBoolAnd(self, nonnegative, in_range);
    const valid = try @TypeOf(self.*).emitBoolAnd(self, bounded, outside_surrogates);
    return @TypeOf(self.*).finishCheckedCast(self, valid, converted, cast.fallible);
}

pub fn lowerIntToIntReinterpretCast(self: anytype, cast: sir.CastExpr) LowerError!lir.ValueId {
    const subject = try self.lowerExpr(cast.subject);
    const target_ty = try @TypeOf(self.*).lowerCastTargetType(self, cast);
    const subject_ty = try @TypeOf(self.*).lowerExprType(self, cast.subject);
    if (@TypeOf(self.*).typeIdsEqual(self, subject_ty, target_ty)) return subject;
    return try self.emit(.{ .int_to_int = subject }, target_ty);
}

pub fn lowerBitcastReinterpretCast(self: anytype, cast: sir.CastExpr) LowerError!lir.ValueId {
    const subject = try self.lowerExpr(cast.subject);
    const subject_ty = try @TypeOf(self.*).lowerExprType(self, cast.subject);
    const target_ty = try @TypeOf(self.*).lowerCastTargetType(self, cast);
    if (@TypeOf(self.*).typeIdsEqual(self, subject_ty, target_ty)) return subject;
    return try self.emit(.{ .bitcast = subject }, target_ty);
}

pub fn lowerPackedStructToIntCast(self: anytype, cast: sir.CastExpr) LowerError!lir.ValueId {
    const subject = try self.lowerExpr(cast.subject);
    const target_ty = try @TypeOf(self.*).lowerCastTargetType(self, cast);
    const converted = try self.emit(.{ .packed_to_int = subject }, target_ty);
    if (cast.fallible) {
        const valid = try self.emit(.{ .const_bool = true }, self.mb.bool_type);
        return @TypeOf(self.*).finishCheckedCast(self, valid, converted, true);
    }
    return converted;
}

pub fn lowerRawPtrToIntCast(self: anytype, cast: sir.CastExpr) LowerError!lir.ValueId {
    const subject = try self.lowerExpr(cast.subject);
    const target_ty = try @TypeOf(self.*).lowerCastTargetType(self, cast);
    const converted = try self.emit(.{ .ptr_to_int = subject }, target_ty);
    if (cast.fallible) {
        const valid = try self.emit(.{ .const_bool = true }, self.mb.bool_type);
        return @TypeOf(self.*).finishCheckedCast(self, valid, converted, true);
    }
    return converted;
}

pub fn lowerIntToPackedStructCast(self: anytype, cast: sir.CastExpr) LowerError!lir.ValueId {
    const subject = try self.lowerExpr(cast.subject);
    const target_ty = try @TypeOf(self.*).lowerCastTargetType(self, cast);
    const converted = try self.emit(.{ .int_to_packed = subject }, target_ty);
    if (cast.fallible) {
        const valid = try self.emit(.{ .const_bool = true }, self.mb.bool_type);
        return @TypeOf(self.*).finishCheckedCast(self, valid, converted, true);
    }
    return converted;
}

pub fn lowerIntToRawPtrCast(self: anytype, cast: sir.CastExpr) LowerError!lir.ValueId {
    const subject = try self.lowerExpr(cast.subject);
    const target_ty = try @TypeOf(self.*).lowerCastTargetType(self, cast);
    const converted = try self.emit(.{ .int_to_ptr = subject }, target_ty);
    if (cast.fallible) {
        const valid = try self.emit(.{ .const_bool = true }, self.mb.bool_type);
        return @TypeOf(self.*).finishCheckedCast(self, valid, converted, true);
    }
    return converted;
}

pub fn lowerIntToFloatCast(self: anytype, cast: sir.CastExpr) LowerError!lir.ValueId {
    const subject = try self.lowerExpr(cast.subject);
    const subject_ty = try @TypeOf(self.*).lowerExprType(self, cast.subject);
    const target_ty = try @TypeOf(self.*).lowerCastTargetType(self, cast);
    const converted = try self.emit(.{ .int_to_float = subject }, target_ty);
    const roundtrip = try self.emit(.{ .float_to_int = converted }, subject_ty);
    const valid = try self.emit(.{ .int_cmp = .{
        .op = .eq,
        .lhs = subject,
        .rhs = roundtrip,
    } }, self.mb.bool_type);
    return @TypeOf(self.*).finishCheckedCast(self, valid, converted, cast.fallible);
}

pub fn lowerFloatToFloatCast(self: anytype, cast: sir.CastExpr) LowerError!lir.ValueId {
    const subject = try self.lowerExpr(cast.subject);
    const subject_ty = try @TypeOf(self.*).lowerExprType(self, cast.subject);
    const target_ty = try @TypeOf(self.*).lowerCastTargetType(self, cast);
    const finite = try @TypeOf(self.*).emitFloatFiniteCheck(self, subject, subject_ty);
    if (@TypeOf(self.*).typeIdsEqual(self, subject_ty, target_ty)) {
        return @TypeOf(self.*).finishCheckedCast(self, finite, subject, cast.fallible);
    }

    const converted = try self.emit(.{ .float_to_float = subject }, target_ty);
    const subject_bits = try @TypeOf(self.*).floatBits(self, subject_ty);
    const target_bits = try @TypeOf(self.*).floatBits(self, target_ty);
    if (subject_bits < target_bits) {
        return @TypeOf(self.*).finishCheckedCast(self, finite, converted, cast.fallible);
    }

    const roundtrip = try self.emit(.{ .float_to_float = converted }, subject_ty);
    const exact = try self.emit(.{ .float_cmp = .{
        .op = .eq,
        .lhs = subject,
        .rhs = roundtrip,
    } }, self.mb.bool_type);
    const valid = try @TypeOf(self.*).emitBoolAnd(self, finite, exact);
    return @TypeOf(self.*).finishCheckedCast(self, valid, converted, cast.fallible);
}

pub fn lowerFloatToIntCast(self: anytype, cast: sir.CastExpr) LowerError!lir.ValueId {
    const subject = try self.lowerExpr(cast.subject);
    const subject_ty = try @TypeOf(self.*).lowerExprType(self, cast.subject);
    const target_int_ty = try @TypeOf(self.*).lowerCastTargetType(self, cast);
    const target_int_info = switch (self.mb.types.items[target_int_ty]) {
        .int => |int_ty| int_ty,
        else => return error.LowerInvariantViolation,
    };
    const bounds = intCastBoundsForInfo(target_int_info);
    const min_value = try self.emit(.{ .const_float = bounds.min_float }, subject_ty);
    const upper_value = try self.emit(.{ .const_float = bounds.upper_exclusive_float }, subject_ty);
    const ge_min = try self.emit(.{ .float_cmp = .{
        .op = .ge,
        .lhs = subject,
        .rhs = min_value,
    } }, self.mb.bool_type);
    const lt_upper = try self.emit(.{ .float_cmp = .{
        .op = .lt,
        .lhs = subject,
        .rhs = upper_value,
    } }, self.mb.bool_type);
    const in_range = try @TypeOf(self.*).emitBoolAnd(self, ge_min, lt_upper);

    const result_ty = if (cast.fallible)
        try self.mb.appendType(.{ .optional = target_int_ty })
    else
        target_int_ty;
    const result_ptr = try self.emit(.{ .stack_alloc = result_ty }, result_ty);

    const valid_range_blk = try self.beginBlock("cast_range_ok");
    const invalid_blk = try self.beginBlock("cast_invalid");
    const cont_blk = try self.beginBlock("cast_cont");
    try self.endBlock(.{ .cond_br = .{
        .condition = in_range,
        .then_block = valid_range_blk,
        .else_block = invalid_blk,
    } });

    self.current_block = valid_range_blk;
    const converted = try self.emit(.{ .float_to_int = subject }, target_int_ty);
    if (cast.fallible) {
        const some_value = try self.emit(.{ .make_some = converted }, result_ty);
        try self.emitVoid(.{ .store = .{ .ptr = result_ptr, .value = some_value } });
    } else {
        try self.emitVoid(.{ .store = .{ .ptr = result_ptr, .value = converted } });
    }
    try self.endBlock(.{ .br = cont_blk });

    self.current_block = invalid_blk;
    if (cast.fallible) {
        const none_value = try self.emit(.make_none, result_ty);
        try self.emitVoid(.{ .store = .{ .ptr = result_ptr, .value = none_value } });
        try self.endBlock(.{ .br = cont_blk });
    } else {
        try self.endBlock(.{ .@"unreachable" = {} });
    }

    self.current_block = cont_blk;
    return self.emit(.{ .load = result_ptr }, result_ty);
}

pub fn lowerIntToEnumCast(self: anytype, cast: sir.CastExpr) LowerError!lir.ValueId {
    const subject = try self.lowerExpr(cast.subject);
    const valid = try @TypeOf(self.*).emitEnumCastCheckResolved(
        self,
        subject,
        try self.mb.canonicalNominalDeclId(cast.target_type_id, .@"enum"),
    );
    return @TypeOf(self.*).finishCheckedCast(self, valid, subject, cast.fallible);
}

pub fn lowerUnionPayloadCast(self: anytype, cast: sir.CastExpr) LowerError!lir.ValueId {
    const subject = try self.lowerExpr(cast.subject);
    const target_ty = try @TypeOf(self.*).lowerCastTargetType(self, cast);
    const union_name = try self.unionNameFromValue(subject);
    const tag = try self.unionCaseTagResolved(
        cast.source_union_decl_id,
        union_name,
        cast.union_case_name orelse return error.LowerInvariantViolation,
    );
    return @TypeOf(self.*).lowerPresenceCheckedCast(self, subject, target_ty, cast.fallible, tag);
}

pub fn lowerPresenceCheckedCast(
    self: anytype,
    subject: lir.ValueId,
    payload_ty: lir.TypeId,
    fallible: bool,
    union_tag: ?i64,
) LowerError!lir.ValueId {
    const tag_value = try self.emit(.{ .extract_tag = subject }, if (union_tag == null) self.mb.bool_type else self.mb.i64_type);
    const valid = if (union_tag) |tag| blk: {
        const want_tag = try self.emit(.{ .const_int = tag }, self.mb.i64_type);
        break :blk try self.emit(.{ .int_cmp = .{
            .op = .eq,
            .lhs = tag_value,
            .rhs = want_tag,
        } }, self.mb.bool_type);
    } else tag_value;
    const result_ty = if (fallible)
        try self.mb.appendType(.{ .optional = payload_ty })
    else
        payload_ty;
    const result_ptr = try self.emit(.{ .stack_alloc = result_ty }, result_ty);
    const valid_blk = try self.beginBlock("cast_valid");
    const invalid_blk = try self.beginBlock("cast_invalid");
    const cont_blk = try self.beginBlock("cast_cont");
    try self.endBlock(.{ .cond_br = .{
        .condition = valid,
        .then_block = valid_blk,
        .else_block = invalid_blk,
    } });

    self.current_block = valid_blk;
    const payload = try self.emit(.{ .extract_payload = .{
        .value = subject,
        .union_tag = union_tag,
    } }, payload_ty);
    if (fallible) {
        const some_value = try self.emit(.{ .make_some = payload }, result_ty);
        try self.emitVoid(.{ .store = .{ .ptr = result_ptr, .value = some_value } });
    } else {
        try self.emitVoid(.{ .store = .{ .ptr = result_ptr, .value = payload } });
    }
    try self.endBlock(.{ .br = cont_blk });

    self.current_block = invalid_blk;
    if (fallible) {
        const none_value = try self.emit(.make_none, result_ty);
        try self.emitVoid(.{ .store = .{ .ptr = result_ptr, .value = none_value } });
        try self.endBlock(.{ .br = cont_blk });
    } else {
        try self.endBlock(.{ .@"unreachable" = {} });
    }

    self.current_block = cont_blk;
    return self.emit(.{ .load = result_ptr }, result_ty);
}

pub fn finishCheckedCast(self: anytype, valid: lir.ValueId, converted: lir.ValueId, fallible: bool) LowerError!lir.ValueId {
    const value_ty = try @TypeOf(self.*).lowerExprTypeFromValue(self, converted);
    const result_ty = if (fallible)
        try @TypeOf(self.*).optionalTypeFromValue(self, converted)
    else
        value_ty;
    const result_ptr = try self.emit(.{ .stack_alloc = result_ty }, result_ty);
    const valid_blk = try self.beginBlock("cast_valid");
    const invalid_blk = try self.beginBlock("cast_invalid");
    const cont_blk = try self.beginBlock("cast_cont");
    try self.endBlock(.{ .cond_br = .{
        .condition = valid,
        .then_block = valid_blk,
        .else_block = invalid_blk,
    } });

    self.current_block = valid_blk;
    if (fallible) {
        const some_value = try self.emit(.{ .make_some = converted }, result_ty);
        try self.emitVoid(.{ .store = .{ .ptr = result_ptr, .value = some_value } });
    } else {
        try self.emitVoid(.{ .store = .{ .ptr = result_ptr, .value = converted } });
    }
    try self.endBlock(.{ .br = cont_blk });

    self.current_block = invalid_blk;
    if (fallible) {
        const none_value = try self.emit(.make_none, result_ty);
        try self.emitVoid(.{ .store = .{ .ptr = result_ptr, .value = none_value } });
        try self.endBlock(.{ .br = cont_blk });
    } else {
        try self.endBlock(.{ .@"unreachable" = {} });
    }

    self.current_block = cont_blk;
    return self.emit(.{ .load = result_ptr }, result_ty);
}

pub fn emitFloatFiniteCheck(self: anytype, value: lir.ValueId, ty: lir.TypeId) LowerError!lir.ValueId {
    const bounds = try floatFiniteBounds(try @TypeOf(self.*).floatBits(self, ty));
    const min_value = try self.emit(.{ .const_float = bounds.min_float }, ty);
    const max_value = try self.emit(.{ .const_float = bounds.max_float }, ty);
    const ge_min = try self.emit(.{ .float_cmp = .{
        .op = .ge,
        .lhs = value,
        .rhs = min_value,
    } }, self.mb.bool_type);
    const le_max = try self.emit(.{ .float_cmp = .{
        .op = .le,
        .lhs = value,
        .rhs = max_value,
    } }, self.mb.bool_type);
    return @TypeOf(self.*).emitBoolAnd(self, ge_min, le_max);
}

pub fn emitBoolAnd(self: anytype, lhs: lir.ValueId, rhs: lir.ValueId) LowerError!lir.ValueId {
    return self.emit(.{ .int_binop = .{
        .op = .bit_and,
        .lhs = lhs,
        .rhs = rhs,
    } }, self.mb.bool_type);
}

pub fn emitBoolOr(self: anytype, lhs: lir.ValueId, rhs: lir.ValueId) LowerError!lir.ValueId {
    return self.emit(.{ .int_binop = .{
        .op = .bit_or,
        .lhs = lhs,
        .rhs = rhs,
    } }, self.mb.bool_type);
}

pub fn emitIntFitsType(self: anytype, value: lir.ValueId, target_ty: lir.TypeId) LowerError!lir.ValueId {
    const target_int_info = switch (self.mb.types.items[target_ty]) {
        .int => |int_ty| int_ty,
        else => return error.LowerInvariantViolation,
    };
    const bounds = intCastBoundsForInfo(target_int_info);
    if (bounds.min == std.math.minInt(i64) and bounds.max == std.math.maxInt(i64)) {
        return self.emit(.{ .const_bool = true }, self.mb.bool_type);
    }
    const source_ty = try @TypeOf(self.*).lowerExprTypeFromValue(self, value);
    const source_int = switch (self.mb.types.items[source_ty]) {
        .int => |int_ty| int_ty,
        else => return error.LowerInvariantViolation,
    };
    const check_ty = if (source_int.bits < 64) self.mb.i64_type else source_ty;
    const check_value = if (@TypeOf(self.*).typeIdsEqual(self, source_ty, check_ty))
        value
    else
        try self.emit(.{ .int_to_int = value }, check_ty);
    const max_value = try self.emit(.{ .const_int = bounds.max }, check_ty);
    const ge_min = if (!source_int.signed and bounds.min < 0)
        try self.emit(.{ .const_bool = true }, self.mb.bool_type)
    else blk: {
        const min_value = try self.emit(.{ .const_int = bounds.min }, check_ty);
        break :blk try self.emit(.{ .int_cmp = .{
            .op = .ge,
            .lhs = check_value,
            .rhs = min_value,
        } }, self.mb.bool_type);
    };
    const le_max = try self.emit(.{ .int_cmp = .{
        .op = .le,
        .lhs = check_value,
        .rhs = max_value,
    } }, self.mb.bool_type);
    return @TypeOf(self.*).emitBoolAnd(self, ge_min, le_max);
}

pub fn emitEnumCastCheckResolved(
    self: anytype,
    value: lir.ValueId,
    decl_id: identity.DeclId,
) LowerError!lir.ValueId {
    const decl = try self.mb.enumById(decl_id);
    const value_ty = try @TypeOf(self.*).lowerExprTypeFromValue(self, value);
    return switch (decl.layout) {
        .c => self.emit(.{ .const_bool = true }, self.mb.bool_type),
        .flags => blk: {
            var allowed_bits: i64 = 0;
            for (decl.cases) |enum_case| allowed_bits |= enum_case.value;
            const mask = try self.emit(.{ .const_int = allowed_bits }, value_ty);
            const masked = try self.emit(.{ .int_binop = .{
                .op = .bit_and,
                .lhs = value,
                .rhs = mask,
            } }, value_ty);
            break :blk try self.emit(.{ .int_cmp = .{
                .op = .eq,
                .lhs = masked,
                .rhs = value,
            } }, self.mb.bool_type);
        },
        .normal => blk: {
            var valid: ?lir.ValueId = null;
            for (decl.cases) |enum_case| {
                const case_value = try self.emit(.{ .const_int = enum_case.value }, value_ty);
                const matches = try self.emit(.{ .int_cmp = .{
                    .op = .eq,
                    .lhs = value,
                    .rhs = case_value,
                } }, self.mb.bool_type);
                valid = if (valid) |acc| try @TypeOf(self.*).emitBoolOr(self, acc, matches) else matches;
            }
            break :blk valid orelse try self.emit(.{ .const_bool = false }, self.mb.bool_type);
        },
    };
}

pub fn optionalTypeFromValue(self: anytype, value: lir.ValueId) LowerError!lir.TypeId {
    const value_ty = try @TypeOf(self.*).lowerExprTypeFromValue(self, value);
    return try self.mb.appendType(.{ .optional = value_ty });
}

pub fn typeIdsEqual(self: anytype, a: lir.TypeId, b: lir.TypeId) bool {
    return self.mb.typeIdsEqual(a, b);
}

pub fn floatBits(self: anytype, ty: lir.TypeId) LowerError!u16 {
    return switch (self.mb.types.items[ty]) {
        .float => |float_ty| float_ty.bits,
        else => error.LowerInvariantViolation,
    };
}

pub fn lowerShortCircuitBinary(self: anytype, bin: sir.Binary) LowerError!lir.ValueId {
    const result_ptr = try self.emit(.{ .stack_alloc = self.mb.bool_type }, self.mb.bool_type);
    const lhs = try self.lowerExpr(bin.left);

    const rhs_blk = try self.beginBlock(if (bin.op == .@"and") "and_rhs" else "or_rhs");
    const short_blk = try self.beginBlock(if (bin.op == .@"and") "and_short" else "or_short");
    const cont_blk = try self.beginBlock(if (bin.op == .@"and") "and_cont" else "or_cont");

    try self.endBlock(.{ .cond_br = .{
        .condition = lhs,
        .then_block = if (bin.op == .@"and") rhs_blk else short_blk,
        .else_block = if (bin.op == .@"and") short_blk else rhs_blk,
    } });

    self.current_block = short_blk;
    {
        const short_value = try self.emit(
            .{ .const_bool = bin.op == .@"or" },
            self.mb.bool_type,
        );
        try self.emitVoid(.{ .store = .{
            .ptr = result_ptr,
            .value = short_value,
        } });
        try self.endBlock(.{ .br = cont_blk });
    }

    self.current_block = rhs_blk;
    {
        const rhs = try self.lowerExpr(bin.right);
        try self.emitVoid(.{ .store = .{
            .ptr = result_ptr,
            .value = rhs,
        } });
        try self.endBlock(.{ .br = cont_blk });
    }

    self.current_block = cont_blk;
    return self.emit(.{ .load = result_ptr }, self.mb.bool_type);
}

pub fn lowerOptionalNoneCompare(self: anytype, bin: sir.Binary) LowerError!lir.ValueId {
    const opt_expr = if (bin.left.* == .none) bin.right else bin.left;
    const opt_v = try self.lowerExpr(opt_expr);
    const tag_v = try self.emit(.{ .extract_tag = opt_v }, self.mb.bool_type);
    const none_v = try self.emit(.{ .const_bool = false }, self.mb.bool_type);
    return self.emit(.{ .int_cmp = .{
        .op = if (bin.op == .eq) .eq else .ne,
        .lhs = tag_v,
        .rhs = none_v,
    } }, self.mb.bool_type);
}

pub fn lowerUnionCaseExpr(self: anytype, case: sir.UnionCaseExpr) LowerError!lir.ValueId {
    if (case.result_case) |result_case| {
        const result_ty = try @TypeOf(self.*).lowerResultTypeFromCaseExpr(self, case);
        var capture_source = case.value;
        const payload = if (case.value) |value| blk: {
            const payload_ty = switch (self.mb.types.items[result_ty]) {
                .result => |result| switch (result_case) {
                    .ok => result.ok,
                    .err => result.err,
                },
                else => return error.LowerInvariantViolation,
            };
            if (value.* != .none and self.mb.types.items[payload_ty] == .optional and
                !@TypeOf(self.*).typeIdsEqual(self, try @TypeOf(self.*).lowerExprType(self, value), payload_ty))
            {
                // Optional injection already captures its payload. Copying the
                // completed carrier again would retain shared resources twice.
                capture_source = null;
            }
            break :blk try @TypeOf(self.*).lowerExprForTarget(self, value, payload_ty);
        } else null;
        const trace = try @TypeOf(self.*).traceActionForResultCase(self, result_case, case);
        return @TypeOf(self.*).lowerResultCaseValue(self, result_ty, result_case, payload, capture_source, false, trace);
    }
    if (case.inline_union_type_id) |type_id| {
        const union_ty = try self.mb.lowerCanonicalType(type_id);
        const tag = case.inline_union_ordinal orelse return error.LowerInvariantViolation;
        const union_decl = self.mb.types.items[union_ty].@"union";
        if (tag >= union_decl.payloads.len) return error.LowerInvariantViolation;
        const payload_ty = union_decl.payloads[tag] orelse return error.LowerInvariantViolation;
        const value = case.value orelse return error.LowerInvariantViolation;
        const payload_value = try @TypeOf(self.*).lowerExprForTarget(self, value, payload_ty);
        const captured = try @TypeOf(self.*).prepareCapturedExprValue(self, value, payload_value, payload_ty);
        return self.emit(.{ .make_union = .{ .tag = tag, .payload = captured } }, union_ty);
    }
    const union_ty = try self.mb.lowerUnionTypeById(case.decl_id orelse return LowerError.InvalidIdentity);
    const tag = try self.unionCaseTagResolved(case.decl_id, case.union_name, case.case_name);
    const payload = if (case.value) |value| blk: {
        const payload_ty = try self.unionCasePayloadTypeResolved(case.decl_id, case.union_name, case.case_name);
        const payload_value = try @TypeOf(self.*).lowerExprForTarget(self, value, payload_ty);
        break :blk try @TypeOf(self.*).prepareCapturedExprValue(self, value, payload_value, payload_ty);
    } else null;
    return self.emit(.{ .make_union = .{
        .tag = tag,
        .payload = payload,
    } }, union_ty);
}

pub fn lowerResultTypeFromCaseExpr(self: anytype, case: sir.UnionCaseExpr) LowerError!lir.TypeId {
    return self.mb.appendType(.{ .result = .{
        .ok = try self.mb.lowerCanonicalType(case.result_ok_type_id),
        .err = try self.mb.lowerCanonicalType(case.result_err_type_id),
    } });
}

pub fn lowerStructLiteralExpr(self: anytype, literal: sir.StructLiteral) LowerError!lir.ValueId {
    const struct_ty = try self.mb.lowerStructTypeById(literal.decl_id orelse return LowerError.InvalidIdentity);
    const struct_decl = switch (self.mb.types.items[struct_ty]) {
        .@"struct" => |decl| decl,
        else => return error.LowerInvariantViolation,
    };
    const fields = try self.mb.allocator.alloc(lir.ValueId, literal.fields.len);
    errdefer self.mb.allocator.free(fields);
    for (literal.fields) |field| {
        const field_index = for (struct_decl.fields, 0..) |struct_field, index| {
            if (std.mem.eql(u8, struct_field.name, field.name)) break index;
        } else return error.LowerInvariantViolation;
        const field_ty = struct_decl.fields[field_index].ty;
        const field_value = try @TypeOf(self.*).lowerExprForTarget(self, field.value, field_ty);
        fields[field_index] = try @TypeOf(self.*).prepareCapturedExprValue(self, field.value, field_value, field_ty);
    }
    return self.emit(.{ .make_struct = .{ .fields = fields } }, struct_ty);
}

pub fn lowerTupleLiteralExpr(self: anytype, literal: sir.TupleLiteral) LowerError!lir.ValueId {
    const tuple_ty = try self.mb.lowerCanonicalType(literal.type_id);
    const fields = switch (self.mb.types.items[tuple_ty]) {
        .@"struct" => |decl| decl.fields,
        else => return error.LowerInvariantViolation,
    };
    if (fields.len != literal.items.len) return error.LowerInvariantViolation;
    const values = try self.mb.allocator.alloc(lir.ValueId, literal.items.len);
    errdefer self.mb.allocator.free(values);
    for (literal.items, fields, values) |item, field, *value| {
        const lowered = try @TypeOf(self.*).lowerExprForTarget(self, item, field.ty);
        value.* = try @TypeOf(self.*).prepareCapturedExprValue(self, item, lowered, field.ty);
    }
    return self.emit(.{ .make_struct = .{ .fields = values } }, tuple_ty);
}

pub fn lowerTupleFieldExpr(self: anytype, field: sir.TupleFieldAccess) LowerError!lir.ValueId {
    const tuple_ty = try self.mb.lowerCanonicalType(field.tuple_type_id);
    const fields = switch (self.mb.types.items[tuple_ty]) {
        .@"struct" => |decl| decl.fields,
        else => return error.LowerInvariantViolation,
    };
    if (field.index >= fields.len) return error.LowerInvariantViolation;
    const object = try self.lowerExpr(field.object);
    return self.emit(.{ .extract_field = .{ .value = object, .field_index = @intCast(field.index) } }, fields[field.index].ty);
}

pub fn lowerArrayLiteralExpr(self: anytype, literal: sir.ArrayLiteral) LowerError!lir.ValueId {
    const array_ty = try self.mb.lowerArrayTypeFromCanonicalItem(literal.len, literal.item_type_id);
    const item_ty = switch (self.mb.types.items[array_ty]) {
        .array => |array_info| array_info.elem,
        else => return error.LowerInvariantViolation,
    };
    const items = try self.mb.allocator.alloc(lir.ValueId, literal.items.len);
    errdefer self.mb.allocator.free(items);
    for (literal.items, items) |item, *out_item| {
        const item_value = try self.lowerExpr(item);
        out_item.* = try @TypeOf(self.*).prepareCapturedExprValue(self, item, item_value, item_ty);
    }
    return self.emit(.{ .make_array = .{ .items = items } }, array_ty);
}

fn lowerSliceBound(self: anytype, expr: *sir.Expr) LowerError!lir.ValueId {
    const value = try self.lowerExpr(expr);
    const ty = try @TypeOf(self.*).lowerExprType(self, expr);
    if (@TypeOf(self.*).typeIdsEqual(self, ty, self.mb.i64_type)) return value;
    return self.emit(.{ .int_to_int = value }, self.mb.i64_type);
}

pub fn lowerSliceRangeExpr(self: anytype, slice: sir.SliceRange) LowerError!lir.ValueId {
    const object = slice.object;
    const object_ty = try @TypeOf(self.*).lowerExprType(self, object);
    const item_ty = switch (self.mb.types.items[object_ty]) {
        .array => |array_ty| array_ty.elem,
        .dense_array => |array_item_ty| array_item_ty,
        .slice => |slice_item_ty| slice_item_ty,
        else => return error.LowerInvariantViolation,
    };
    const slice_ty = try self.mb.appendType(.{ .slice = item_ty });
    const ptr_ty = try self.mb.appendType(.{ .pointer = item_ty });
    const zero = try self.emit(.{ .const_int = 0 }, self.mb.i64_type);

    const base_ptr, const full_len = switch (self.mb.types.items[object_ty]) {
        .dense_array => blk: {
            const list_value = try @TypeOf(self.*).materializeSequenceValue(self, object);
            break :blk .{
                try self.emit(.{ .dense_data = list_value }, ptr_ty),
                try @TypeOf(self.*).emitSequenceLenValue(self, list_value, object_ty, self.mb.i64_type),
            };
        },
        .slice => blk: {
            const slice_value = try self.lowerExpr(object);
            break :blk .{
                try self.emit(.{ .extract_slice_ptr = slice_value }, ptr_ty),
                try self.emit(.{ .extract_slice_len = slice_value }, self.mb.i64_type),
            };
        },
        .array => |array_ty| blk: {
            const array_base_ptr = switch (object.*) {
                .local => |name| (try self.getLocal(name)).ptr_value,
                else => inner: {
                    const value = try self.lowerExpr(object);
                    const tmp_ptr = try self.emit(.{ .stack_alloc = object_ty }, object_ty);
                    try self.emitVoid(.{ .store = .{ .ptr = tmp_ptr, .value = value } });
                    break :inner tmp_ptr;
                },
            };
            break :blk .{
                try self.emit(.{ .index_ptr = .{
                    .ptr = array_base_ptr,
                    .index = zero,
                } }, ptr_ty),
                try self.emit(.{ .const_int = @intCast(array_ty.len) }, self.mb.i64_type),
            };
        },
        else => return error.LowerInvariantViolation,
    };

    const start_value = if (slice.start) |start| try lowerSliceBound(self, start) else zero;
    const end_value = if (slice.end) |end| try lowerSliceBound(self, end) else full_len;
    const nonnegative = try self.emit(.{ .int_cmp = .{ .op = .ge, .lhs = start_value, .rhs = zero } }, self.mb.bool_type);
    const ordered = try self.emit(.{ .int_cmp = .{ .op = .le, .lhs = start_value, .rhs = end_value } }, self.mb.bool_type);
    const within = try self.emit(.{ .int_cmp = .{ .op = .le, .lhs = end_value, .rhs = full_len } }, self.mb.bool_type);
    const valid = try @TypeOf(self.*).emitBoolAnd(self, try @TypeOf(self.*).emitBoolAnd(self, nonnegative, ordered), within);
    const valid_block = try self.beginBlock("slice_valid");
    const invalid_block = try self.beginBlock("slice_invalid");
    try self.endBlock(.{ .cond_br = .{ .condition = valid, .then_block = valid_block, .else_block = invalid_block } });
    self.current_block = invalid_block;
    _ = try self.emit(.{ .call = .{ .name = runtime_symbols.name(.assert_fail), .args = try @TypeOf(self.*).dupeArgs(self, &.{}) } }, self.mb.void_type);
    try self.endBlock(.{ .@"unreachable" = {} });
    self.current_block = valid_block;
    const elem_ptr = try self.emit(.{ .index_ptr = .{
        .ptr = base_ptr,
        .index = start_value,
    } }, ptr_ty);
    const len = try self.emit(.{ .int_binop = .{
        .op = .sub,
        .lhs = end_value,
        .rhs = start_value,
    } }, self.mb.i64_type);
    return self.emit(.{ .make_slice = .{ .ptr = elem_ptr, .len = len } }, slice_ty);
}

// Expression typing, scalar, string, and builtin interface.
fn lowerIsTestExpr(self: anytype, test_expr: sir.IsTestExpr) LowerError!lir.ValueId {
    // Sparse borrowed elements expose presence without materializing or moving
    // their optional payload. Match the direct-if path for these places.
    const sparse = if (test_expr.kind != .union_case)
        try @TypeOf(self.*).lowerBorrowedSparseOptionalSubject(self, test_expr.subject)
    else
        null;
    var subject: ?lir.ValueId = null;
    var subject_ty: ?lir.TypeId = null;
    const present = if (sparse) |borrow| borrow.present else blk: {
        var value = try self.lowerExpr(test_expr.subject);
        var ty = try lowerExprType(self, test_expr.subject);
        if (self.mb.types.items[ty] == .pointer) {
            ty = self.mb.types.items[ty].pointer;
            value = try self.emit(.{ .load = value }, ty);
        }
        subject = value;
        subject_ty = ty;
        if (test_expr.kind == .union_case) {
            if (self.mb.types.items[ty] != .@"union") return error.LowerInvariantViolation;
            const metadata = try self.mb.exprMetadata(test_expr.subject);
            const union_name = try self.unionNameFromValue(value);
            const tag = try self.unionCaseTagResolved(
                try self.mb.canonicalNominalDeclId(metadata.type_id, .@"union"),
                union_name,
                test_expr.case_name orelse return error.LowerInvariantViolation,
            );
            const actual = try self.emit(.{ .extract_tag = value }, self.mb.i64_type);
            const expected = try self.emit(.{ .const_int = tag }, self.mb.i64_type);
            break :blk try self.emit(.{ .int_cmp = .{ .op = .eq, .lhs = actual, .rhs = expected } }, self.mb.bool_type);
        }
        if (self.mb.types.items[ty] != .optional) return error.LowerInvariantViolation;
        break :blk try self.emit(.{ .extract_tag = value }, self.mb.bool_type);
    };
    const result = if (test_expr.kind == .optional_none) blk: {
        const absent = try self.emit(.{ .const_bool = false }, self.mb.bool_type);
        break :blk try self.emit(.{ .int_cmp = .{ .op = .eq, .lhs = present, .rhs = absent } }, self.mb.bool_type);
    } else present;
    if (subject) |value| {
        if (try @TypeOf(self.*).captureMatchSourceNeedsDrop(self, test_expr.subject) and
            try @TypeOf(self.*).typeNeedsDrop(self, subject_ty.?))
        {
            try @TypeOf(self.*).emitDropValue(self, value, subject_ty.?);
        }
    }
    return result;
}

pub fn lowerExprType(self: anytype, expr: *sir.Expr) LowerError!lir.TypeId {
    return switch (expr.*) {
        .@"switch" => |switch_expr| self.mb.lowerCanonicalType(switch_expr.result_type_id orelse return error.LowerInvariantViolation),
        .int => if (expr.int.type_name) |type_name| try self.mb.lowerExactNamedIntType(type_name) else self.mb.i64_type,
        .float => try self.mb.lowerType(.float, expr.float.type_name),
        .rune => try self.mb.lowerType(.rune, null),
        .bool, .is_test => self.mb.bool_type,
        .string => try self.mb.lowerType(.string, null),
        .interpolated_string => try self.mb.lowerType(.string, null),
        .function_ref => try self.mb.appendType(.{ .pointer = self.mb.void_type }),
        .closure => try self.mb.lowerArrowCallableType(),
        .closure_capture => |capture| try self.mb.lowerCanonicalType(capture.type_id),
        .local => |name| blk: {
            if (self.getLocalIfPresent(name)) |local| {
                if (!local.read_through_alias) break :blk local.ty;
                break :blk try self.pointerPointee(local.ty) orelse return error.LowerInvariantViolation;
            }
            break :blk self.getGlobalType(name) orelse return LowerError.MissingLocal;
        },
        .global_ref => |global_ref| (try self.mb.globalById(global_ref.decl_id orelse return LowerError.InvalidIdentity)).ty,
        .handoff_local => |name| (try self.getLocal(name)).ty,
        .take_index_local => |take_index| blk: {
            const place = try @TypeOf(self.*).lowerTakeIndexedPlacePointer(self, take_index.local_name, &.{}, take_index.index);
            break :blk place.ty;
        },
        .take_index_path_local => |take_path| blk: {
            const place = try @TypeOf(self.*).lowerTakeIndexedPlacePointer(self, take_path.local_name, take_path.steps, take_path.index);
            break :blk place.ty;
        },
        .take_path_local => |take_path| blk: {
            const place = try @TypeOf(self.*).lowerTakePlacePointer(self, take_path.local_name, take_path.steps);
            break :blk place.ty;
        },
        .ref_local => |name| blk: {
            const local = try self.getLocal(name);
            break :blk switch (self.mb.types.items[local.ty]) {
                .pointer => local.ty,
                else => try self.mb.appendType(.{ .pointer = local.ty }),
            };
        },
        .ref_global => |global_ref| blk: {
            const global = try self.mb.globalById(global_ref.decl_id orelse return LowerError.InvalidIdentity);
            break :blk try self.mb.appendType(.{ .pointer = global.ty });
        },
        .ref_alias_local => |name| blk: {
            const local = try self.getLocal(name);
            break :blk switch (self.mb.types.items[local.ty]) {
                .pointer => local.ty,
                else => try self.mb.appendType(.{ .pointer = local.ty }),
            };
        },
        .ref_owned_local => |name| blk: {
            const local = try self.getLocal(name);
            break :blk try self.mb.appendType(.{ .pointer = local.ty });
        },
        .raw_owned_local => |name| blk: {
            const local = try self.getLocal(name);
            break :blk try self.mb.appendType(.{ .pointer = local.ty });
        },
        .leak_owned_local => |name| blk: {
            const local = try self.getLocal(name);
            break :blk try self.mb.appendType(.{ .pointer = local.ty });
        },
        .ref_raw_deref => |raw_expr| try @TypeOf(self.*).lowerExprType(self, raw_expr.expr),
        .raw_deref => |raw_expr| blk: {
            const ptr_ty = try @TypeOf(self.*).lowerExprType(self, raw_expr.expr);
            break :blk switch (self.mb.types.items[ptr_ty]) {
                .pointer => |pointee| pointee,
                else => return error.LowerInvariantViolation,
            };
        },
        .from_raw => |value| blk: {
            const ptr_ty = try @TypeOf(self.*).lowerExprType(self, value.expr);
            break :blk switch (self.mb.types.items[ptr_ty]) {
                .pointer => |pointee| pointee,
                else => return error.LowerInvariantViolation,
            };
        },
        .ref_field_local => |field| blk: {
            const field_ty = try self.structFieldTypeResolved(field.struct_decl_id, field.struct_name, field.field);
            break :blk try self.mb.appendType(.{ .pointer = field_ty });
        },
        .ref_field_owned_local => |field| blk: {
            const field_ty = try self.structFieldTypeResolved(field.struct_decl_id, field.struct_name, field.field);
            break :blk try self.mb.appendType(.{ .pointer = field_ty });
        },
        .ref_field_expr => |field| blk: {
            const field_ty = try self.structFieldTypeResolved(field.struct_decl_id, field.struct_name, field.field);
            break :blk try self.mb.appendType(.{ .pointer = field_ty });
        },
        .ref_union_field_local => |field| blk: {
            const field_ty = try self.unionCasePayloadTypeResolved(field.union_decl_id, field.union_name, field.field);
            break :blk try self.mb.appendType(.{ .pointer = field_ty });
        },
        .ref_index_local => |index_ref| blk: {
            const local = try self.getLocal(index_ref.local_name);
            const elem_ty = switch (self.mb.types.items[local.ty]) {
                .array => |array_ty| array_ty.elem,
                .slice => |item_ty| item_ty,
                .dense_array => |item_ty| item_ty,
                .sparse_array => |item_ty| try self.mb.appendType(.{ .optional = item_ty }),
                else => return error.LowerInvariantViolation,
            };
            break :blk try self.mb.appendType(.{ .pointer = elem_ty });
        },
        .ref_index_path_local => |take_path| blk: {
            const base = try @TypeOf(self.*).lowerTakePlacePointer(self, take_path.local_name, take_path.steps);
            const elem_ty = switch (self.mb.types.items[base.ty]) {
                .sparse_array => |item_ty| try self.mb.appendType(.{ .optional = item_ty }),
                else => (try @TypeOf(self.*).lowerIndexPlacePointer(self, base, take_path.index)).ty,
            };
            break :blk try self.mb.appendType(.{ .pointer = elem_ty });
        },
        .ref_path_local => |take_path| blk: {
            const place = try @TypeOf(self.*).lowerTakePlacePointer(self, take_path.local_name, take_path.steps);
            break :blk try self.mb.appendType(.{ .pointer = place.ty });
        },
        .ref_load => |ref_expr| blk: {
            const ptr_ty = try @TypeOf(self.*).lowerExprType(self, ref_expr);
            break :blk try self.pointerPointee(ptr_ty) orelse return error.LowerInvariantViolation;
        },
        .unary => |unary| try @TypeOf(self.*).lowerUnaryType(self, unary),
        .binary => |bin| switch (bin.op) {
            .eq, .ne, .lt, .le, .gt, .ge, .in => self.mb.bool_type,
            else => blk: {
                const left_ty = try @TypeOf(self.*).lowerExprType(self, bin.left);
                const right_ty = try @TypeOf(self.*).lowerExprType(self, bin.right);
                if (self.mb.types.items[left_ty] == .float) break :blk left_ty;
                if (self.mb.types.items[right_ty] == .float) break :blk right_ty;
                break :blk left_ty;
            },
        },
        .cast => |cast| blk: {
            if (cast.fallible) {
                break :blk try self.mb.appendType(.{ .optional = try @TypeOf(self.*).lowerCastTargetType(self, cast) });
            }
            const subject_ty = try @TypeOf(self.*).lowerExprType(self, cast.subject);
            if (self.mb.types.items[subject_ty] == .optional) {
                break :blk switch (self.mb.types.items[subject_ty]) {
                    .optional => |payload_ty| payload_ty,
                    else => unreachable,
                };
            }
            break :blk try @TypeOf(self.*).lowerCastTargetType(self, cast);
        },
        .call => |call| try self.lowerCallReturnType(call),
        .thread_spawn_boxed => |spawn| try self.mb.lowerCanonicalType(spawn.return_type_id),
        .task_group_spawn_boxed => |spawn| try self.mb.lowerCanonicalType(spawn.return_type_id),
        .task_result_take => |take| try self.mb.lowerCanonicalType(take.return_type_id),
        .sync_share_boxed => |share| try self.mb.lowerCanonicalType(share.return_type_id),
        .indirect_call => |call| try self.mb.lowerCanonicalType(call.return_type_id),
        .builtin_print => self.mb.void_type,
        .sequence_push, .sequence_clear, .sparse_clear, .sparse_insert, .sequence_reserve => self.mb.void_type,
        .sequence_len, .sparse_len => try self.mb.lowerCanonicalType((try self.mb.exprMetadata(expr)).type_id),
        .sparse_contains_index => self.mb.bool_type,
        .slice_len => try self.mb.lowerCanonicalType((try self.mb.exprMetadata(expr)).type_id),
        .slice_ptr => try self.mb.lowerCanonicalType((try self.mb.exprMetadata(expr)).type_id),
        .sequence_pop => |object| blk: {
            const list_ty = try @TypeOf(self.*).lowerExprType(self, object);
            break :blk switch (self.mb.types.items[list_ty]) {
                .dense_array => |item_ty| item_ty,
                else => return error.LowerInvariantViolation,
            };
        },
        .sparse_take => |take| blk: {
            const sparse_ty = try @TypeOf(self.*).lowerExprType(self, take.object);
            const item_ty = try @TypeOf(self.*).sequenceItemType(self, sparse_ty);
            break :blk try self.mb.appendType(.{ .optional = item_ty });
        },
        .sparse_indices => try self.mb.appendType(.{ .dense_array = self.mb.i64_type }),
        .string_len => try self.mb.lowerCanonicalType((try self.mb.exprMetadata(expr)).type_id),
        .string_is_empty => self.mb.bool_type,
        .string_bytes => try self.mb.lowerSliceType(.int, "u8"),
        .string_from => self.mb.string_type,
        .string_starts_with => self.mb.bool_type,
        .string_ends_with => self.mb.bool_type,
        .string_contains => self.mb.bool_type,
        .string_find => try self.mb.lowerOptionalType(.int, "usize"),
        .string_rfind => try self.mb.lowerOptionalType(.int, "usize"),
        .string_slice => self.mb.string_type,
        .@"try" => |try_expr| blk: {
            const result_ty = try @TypeOf(self.*).lowerExprType(self, try_expr.expr);
            break :blk switch (self.mb.types.items[result_ty]) {
                .result => |result_decl| result_decl.ok,
                else => return error.LowerInvariantViolation,
            };
        },
        .new_owned => |literal| try self.mb.lowerStructTypeById(literal.decl_id orelse return LowerError.InvalidIdentity),
        .array_literal => |literal| try self.mb.lowerArrayTypeFromCanonicalItem(literal.len, literal.item_type_id),
        .tuple_literal => |literal| try self.mb.lowerCanonicalType(literal.type_id),
        .array_default => |literal| try self.mb.lowerArrayTypeFromCanonicalItem(literal.len, literal.item_type_id),
        .new_array => |new_array| try self.mb.lowerDenseArrayTypeFromCanonicalItem(new_array.item_type_id),
        .dense_array_literal => |literal| try self.mb.lowerDenseArrayTypeFromCanonicalItem(literal.item_type_id),
        .sparse_literal => |literal| try self.mb.lowerSparseArrayTypeFromCanonicalItem(literal.item_type_id),
        .sparse_keyed_literal => |literal| try self.mb.lowerSparseArrayTypeFromCanonicalItem(literal.item_type_id),
        .new_sparse => |storage| try self.mb.lowerSparseArrayTypeFromCanonicalItem(storage.item_type_id),
        .slice_range => |slice| try @TypeOf(self.*).lowerSliceTypeFromObject(self, slice.object),
        .struct_literal => |literal| try self.mb.lowerStructTypeById(literal.decl_id orelse return LowerError.InvalidIdentity),
        .asm_expr => |asm_expr| try self.mb.lowerCanonicalType(asm_expr.target_type_id),
        .index => |index| try @TypeOf(self.*).lowerIndexType(self, index),
        .borrowed_index => |index| try @TypeOf(self.*).lowerIndexType(self, index),
        .field => |field| try self.structFieldTypeResolved(field.struct_decl_id, field.struct_name, field.field),
        .tuple_field => |field| blk: {
            const tuple_ty = try self.mb.lowerCanonicalType(field.tuple_type_id);
            break :blk switch (self.mb.types.items[tuple_ty]) {
                .@"struct" => |decl| if (field.index < decl.fields.len) decl.fields[field.index].ty else return error.LowerInvariantViolation,
                else => return error.LowerInvariantViolation,
            };
        },
        .borrowed_field => |field| try self.structFieldTypeResolved(field.struct_decl_id, field.struct_name, field.field),
        .union_field => |field| try self.unionCasePayloadTypeResolved(field.union_decl_id, field.union_name, field.field),
        .borrowed_union_field => |field| try self.unionCasePayloadTypeResolved(field.union_decl_id, field.union_name, field.field),
        .union_case => |case| if (case.result_case != null)
            try @TypeOf(self.*).lowerResultTypeFromCaseExpr(self, case)
        else if (case.inline_union_type_id) |type_id|
            try self.mb.lowerCanonicalType(type_id)
        else
            try self.mb.lowerUnionTypeById(case.decl_id orelse return LowerError.InvalidIdentity),
        .enum_case => |case| try self.mb.lowerEnumTypeById(case.decl_id orelse return LowerError.InvalidIdentity),
        .failure_detail => try self.mb.lowerCanonicalType((try self.mb.exprMetadata(expr)).type_id),
        else => error.LowerInvariantViolation,
    };
}

pub fn lowerAsmExpr(self: anytype, asm_expr: sir.AsmExpr) LowerError!lir.ValueId {
    const input_names = try self.mb.allocator.alloc([]const u8, asm_expr.inputs.len);
    errdefer self.mb.allocator.free(input_names);
    const input_constraints = try self.mb.allocator.alloc(lir.AsmConstraint, asm_expr.inputs.len);
    errdefer self.mb.allocator.free(input_constraints);
    const args = try self.mb.allocator.alloc(lir.ValueId, asm_expr.inputs.len);
    errdefer self.mb.allocator.free(args);
    for (asm_expr.inputs, 0..) |input, i| {
        input_names[i] = input.name;
        input_constraints[i] = lowerAsmConstraint(input.constraint);
        args[i] = try self.lowerExpr(input.value);
    }
    const lines = try self.mb.allocator.alloc([]const u8, asm_expr.lines.len);
    errdefer self.mb.allocator.free(lines);
    @memcpy(lines, asm_expr.lines);
    const clobbers = try self.mb.allocator.alloc(lir.AsmClobber, asm_expr.clobbers.len);
    var clobber_count: usize = 0;
    errdefer {
        for (clobbers[0..clobber_count]) |clobber| clobber.deinit(self.mb.allocator);
        self.mb.allocator.free(clobbers);
    }
    for (asm_expr.clobbers, 0..) |clobber, i| {
        clobbers[i] = switch (clobber) {
            .memory => .memory,
            .flags => .flags,
            .register => |name| .{ .register = try self.mb.allocator.dupe(u8, name) },
        };
        clobber_count = i + 1;
    }
    const lowered_inout = if (asm_expr.inout) |inout| lir.AsmInOut{
        .name = try self.mb.allocator.dupe(u8, inout.name),
        .constraint = lowerAsmConstraint(inout.constraint),
        .seed = try self.lowerExpr(inout.value),
    } else null;
    errdefer if (lowered_inout) |inout| inout.deinit(self.mb.allocator);
    const result_ty = try self.mb.lowerCanonicalType(asm_expr.target_type_id);
    return try self.emit(.{ .inline_asm = .{
        .lines = lines,
        .output = if (asm_expr.output) |output| .{
            .name = try self.mb.allocator.dupe(u8, output.name),
            .constraint = lowerAsmConstraint(output.constraint),
        } else null,
        .inout = lowered_inout,
        .input_names = input_names,
        .input_constraints = input_constraints,
        .args = args,
        .clobbers = clobbers,
        .is_volatile = asm_expr.is_volatile,
    } }, result_ty);
}

pub fn lowerAsmConstraint(constraint: sir.AsmConstraint) lir.AsmConstraint {
    return switch (constraint) {
        .reg => .reg,
        .tied_reg => .tied_reg,
    };
}

pub fn lowerLocalType(self: anytype, local: sir.Local) LowerError!lir.TypeId {
    return self.mb.lowerCanonicalType(local.type_id);
}

pub fn lowerExprForTarget(self: anytype, expr: *sir.Expr, target_ty: lir.TypeId) LowerError!lir.ValueId {
    switch (self.mb.types.items[target_ty]) {
        .optional => |payload_ty| {
            if (expr.* == .none) {
                return self.emit(.make_none, target_ty);
            }

            const expr_ty = try @TypeOf(self.*).lowerExprType(self, expr);
            if (@TypeOf(self.*).typeIdsEqual(self, expr_ty, target_ty)) {
                return self.lowerExpr(expr);
            }
            const payload_v = try @TypeOf(self.*).lowerExprForTarget(self, expr, payload_ty);
            const captured_payload = try @TypeOf(self.*).prepareCapturedExprValue(self, expr, payload_v, payload_ty);
            return self.emit(.{ .make_some = captured_payload }, target_ty);
        },
        else => {},
    }

    const value = try self.lowerExpr(expr);
    const expr_ty = try @TypeOf(self.*).lowerExprType(self, expr);
    if (@TypeOf(self.*).typeIdsEqual(self, expr_ty, target_ty)) return value;
    switch (self.mb.types.items[expr_ty]) {
        .pointer => |pointee_ty| {
            if (@TypeOf(self.*).typeIdsEqual(self, pointee_ty, target_ty)) {
                return self.emit(.{ .load = value }, target_ty);
            }
        },
        else => {},
    }
    return switch (self.mb.types.items[target_ty]) {
        .int => switch (self.mb.types.items[expr_ty]) {
            .int => self.emit(.{ .int_to_int = value }, target_ty),
            else => value,
        },
        else => value,
    };
}

pub fn lowerUnary(self: anytype, unary: sir.Unary) LowerError!lir.ValueId {
    return switch (unary.op) {
        .not => blk: {
            const value = try self.lowerExpr(unary.expr);
            const false_value = try self.emit(.{ .const_bool = false }, self.mb.bool_type);
            break :blk try self.emit(.{ .int_cmp = .{
                .op = .eq,
                .lhs = value,
                .rhs = false_value,
            } }, self.mb.bool_type);
        },
        .bit_not => blk: {
            const value = try self.lowerExpr(unary.expr);
            const value_ty = try @TypeOf(self.*).lowerExprType(self, unary.expr);
            const all_ones = try self.emit(.{ .const_int = -1 }, value_ty);
            break :blk try self.emit(.{ .int_binop = .{ .op = .bit_xor, .lhs = value, .rhs = all_ones } }, value_ty);
        },
        .negate => blk: {
            const value = try self.lowerExpr(unary.expr);
            const value_ty = try @TypeOf(self.*).lowerExprType(self, unary.expr);
            switch (self.mb.types.items[value_ty]) {
                .int => {
                    const zero = try self.emit(.{ .const_int = 0 }, value_ty);
                    break :blk try self.emit(.{ .int_binop = .{ .op = .sub, .lhs = zero, .rhs = value } }, value_ty);
                },
                .float => {
                    const zero = try self.emit(.{ .const_float = 0.0 }, value_ty);
                    break :blk try self.emit(.{ .float_binop = .{ .op = .sub, .lhs = zero, .rhs = value } }, value_ty);
                },
                else => return error.LowerInvariantViolation,
            }
        },
        .copy_list => {
            const borrowed_list = try @TypeOf(self.*).lowerReadableSequenceValue(self, unary.expr, .copy_from_place);
            const list_value = borrowed_list.value;
            const list_ty = borrowed_list.ty;
            const item_ty = try @TypeOf(self.*).sequenceItemType(self, list_ty);
            const elem_desc = try @TypeOf(self.*).emitTypeDesc(self, item_ty);
            return switch (self.mb.types.items[list_ty]) {
                .dense_array => self.emit(.{ .dense_copy = .{
                    .lhs = list_value,
                    .rhs = elem_desc,
                } }, list_ty),
                else => error.LowerInvariantViolation,
            };
        },
    };
}

pub fn lowerUnaryType(self: anytype, unary: sir.Unary) LowerError!lir.TypeId {
    return switch (unary.op) {
        .not => self.mb.bool_type,
        .bit_not => @TypeOf(self.*).lowerExprType(self, unary.expr),
        .negate => @TypeOf(self.*).lowerExprType(self, unary.expr),
        .copy_list => @TypeOf(self.*).lowerExprType(self, unary.expr),
    };
}

pub fn lowerStringLenExpr(self: anytype, object: *sir.Expr, result_ty: lir.TypeId) LowerError!lir.ValueId {
    const string_value = try self.lowerExpr(object);
    const len = try self.emit(.{ .string_len = string_value }, result_ty);
    try @TypeOf(self.*).dropTemporaryStringReceiver(self, object, string_value);
    return len;
}

pub fn lowerStringIsEmptyExpr(self: anytype, object: *sir.Expr) LowerError!lir.ValueId {
    const len_ty = try self.mb.lowerExactNamedIntType("usize");
    const len_value = try @TypeOf(self.*).lowerStringLenExpr(self, object, len_ty);
    const zero = try self.emit(.{ .const_int = 0 }, len_ty);
    return self.emit(.{ .int_cmp = .{
        .op = .eq,
        .lhs = len_value,
        .rhs = zero,
    } }, self.mb.bool_type);
}

pub fn lowerStringBytesExpr(self: anytype, object: *sir.Expr) LowerError!lir.ValueId {
    const string_value = try @TypeOf(self.*).lowerStringBuiltinReceiver(self, object);
    const byte_ty = try self.mb.lowerExactNamedIntType("u8");
    const ptr_ty = try self.mb.appendType(.{ .pointer = byte_ty });
    const ptr_value = try self.emit(.{ .extract_slice_ptr = string_value }, ptr_ty);
    const len_value = try self.emit(.{ .string_len = string_value }, self.mb.i64_type);
    const slice_ty = try self.mb.lowerSliceType(.int, "u8");
    return self.emit(.{ .make_slice = .{
        .ptr = ptr_value,
        .len = len_value,
    } }, slice_ty);
}

pub fn lowerStringFromExpr(self: anytype, bytes: *sir.Expr) LowerError!lir.ValueId {
    const cleanup_start = self.ownership.cleanup_entries.items.len;
    const bytes_value = try self.lowerExpr(bytes);
    const bytes_ty = try self.mb.lowerSliceType(.int, "u8");
    const bytes_ptr = try @TypeOf(self.*).materializeRuntimeArgument(self, bytes_value, bytes_ty);
    const result = try @TypeOf(self.*).emitStringResultAt(self, runtime_symbols.name(.string_from_bytes_into), &.{bytes_ptr});
    try @TypeOf(self.*).emitFullExpressionAutoDropsFrom(self, cleanup_start, "string call");
    return result;
}

pub fn lowerStringContainsExpr(self: anytype, contains: sir.StringContains, abi_name: []const u8) LowerError!lir.ValueId {
    const object = try self.lowerExpr(contains.object);
    const value = try self.lowerExpr(contains.value);
    const object_parts = try @TypeOf(self.*).stringRuntimeParts(self, object);
    const value_parts = try @TypeOf(self.*).stringRuntimeParts(self, value);
    const result = try self.emit(.{ .call = .{
        .name = abi_name,
        .args = try @TypeOf(self.*).dupeArgs(self, &.{ object_parts.ptr, object_parts.len, value_parts.ptr, value_parts.len }),
    } }, self.mb.bool_type);
    try @TypeOf(self.*).dropTemporaryStringReceiver(self, contains.object, object);
    try @TypeOf(self.*).dropTemporaryStringReceiver(self, contains.value, value);
    return result;
}

pub fn lowerStringFindExpr(self: anytype, contains: sir.StringContains, abi_name: []const u8) LowerError!lir.ValueId {
    const object = try self.lowerExpr(contains.object);
    const value = try self.lowerExpr(contains.value);
    const optional_ty = try self.mb.lowerOptionalType(.int, "usize");
    const result_ptr = try self.emit(.{ .stack_alloc = optional_ty }, optional_ty);
    const object_parts = try @TypeOf(self.*).stringRuntimeParts(self, object);
    const value_parts = try @TypeOf(self.*).stringRuntimeParts(self, value);
    const pointer_name = if (std.mem.eql(u8, abi_name, runtime_symbols.name(.string_find)))
        runtime_symbols.name(.string_find_into)
    else
        runtime_symbols.name(.string_rfind_into);
    _ = try @TypeOf(self.*).emitRuntimeCall(self, pointer_name, &.{ result_ptr, object_parts.ptr, object_parts.len, value_parts.ptr, value_parts.len }, self.mb.void_type);
    const result = try self.emit(.{ .load = result_ptr }, optional_ty);
    try @TypeOf(self.*).dropTemporaryStringReceiver(self, contains.object, object);
    try @TypeOf(self.*).dropTemporaryStringReceiver(self, contains.value, value);
    return result;
}

pub fn lowerStringSliceExpr(self: anytype, slice: sir.StringSlice) LowerError!lir.ValueId {
    const object = try self.lowerExpr(slice.object);
    const start = try @TypeOf(self.*).lowerExprForTarget(self, slice.start, self.mb.i64_type);
    const end = try @TypeOf(self.*).lowerExprForTarget(self, slice.end, self.mb.i64_type);
    const object_ptr = try @TypeOf(self.*).materializeRuntimeArgument(self, object, self.mb.string_type);
    const result = try @TypeOf(self.*).emitStringResultAt(self, runtime_symbols.name(.string_slice_into), &.{ object_ptr, start, end });
    try @TypeOf(self.*).dropTemporaryStringReceiver(self, slice.object, object);
    return result;
}

pub fn lowerStringBuiltinReceiver(self: anytype, object: *sir.Expr) LowerError!lir.ValueId {
    const object_category = (try self.mb.exprMetadata(object)).semantics.category;
    if (object_category == .borrowed_projection) {
        const place = try @TypeOf(self.*).lowerAddressableBorrowedProjectionPlacePointer(self, object);
        try @TypeOf(self.*).recordOwnershipTrace(self, "borrowed_projection string_receiver_from_place", .{});
        return self.emit(.{ .load = place.ptr_value }, place.ty);
    }
    const value = try self.lowerExpr(object);
    const ty = try @TypeOf(self.*).lowerExprType(self, object);
    if (!(try @TypeOf(self.*).typeNeedsDrop(self, ty))) return value;
    const semantics = (try self.mb.exprMetadata(object)).semantics;
    const needs_owner = valueSemanticsNeedsStringReceiverOwner(semantics);
    if (!needs_owner) return value;
    const retained = try @TypeOf(self.*).prepareCapturedExprValue(self, object, value, ty);

    const ptr = try self.emit(.{ .stack_alloc = ty }, ty);
    try self.emitVoid(.{ .store = .{ .ptr = ptr, .value = retained } });
    try self.registerCompilerTemporaryCleanup("string_view_owner", ptr, ty);
    return self.emit(.{ .load = ptr }, ty);
}

pub fn dropTemporaryStringReceiver(self: anytype, object: *sir.Expr, value: lir.ValueId) LowerError!void {
    const ty = try @TypeOf(self.*).lowerExprType(self, object);
    if (self.mb.types.items[ty] != .string) return;
    const needs_cleanup = valueSemanticsNeedsStringCleanup((try self.mb.exprMetadata(object)).semantics);
    if (!needs_cleanup) return;
    try @TypeOf(self.*).emitDropValue(self, value, ty);
}

pub fn lowerBuiltinPrintExpr(self: anytype, print: sir.BuiltinPrint) LowerError!lir.ValueId {
    const first = print.parts[0];
    var write_id = switch (first) {
        // A builtin print is built from printed values; a bare literal part
        // would have no checked helper record, so it never reaches lowering.
        .literal => return LowerError.InvalidSir,
        .value => |value| try @TypeOf(self.*).lowerBuiltinPrintValue(self, value),
    };
    for (print.parts[1..]) |part| {
        write_id = switch (part) {
            .literal => return LowerError.InvalidSir,
            .value => |value| try @TypeOf(self.*).lowerBuiltinPrintValue(self, value),
        };
    }

    if (!print.append_newline) return write_id;
    return @TypeOf(self.*).emitPrintHelperCall(self, print.newline_helper_declaration_id, &.{}, self.mb.void_type);
}

pub fn lowerBuiltinPrintValue(self: anytype, value: sir.BuiltinPrintValue) LowerError!lir.ValueId {
    const value_ty = try @TypeOf(self.*).lowerExprType(self, value.expr);
    return switch (self.mb.types.items[value_ty]) {
        .string => blk: {
            const lowered = try self.lowerExpr(value.expr);
            break :blk try @TypeOf(self.*).emitPrintHelperCall(self, value.helper_declaration_id, &.{lowered}, self.mb.void_type);
        },
        .bool => blk: {
            const lowered = try self.lowerExpr(value.expr);
            break :blk try @TypeOf(self.*).emitPrintHelperCall(self, value.helper_declaration_id, &.{lowered}, self.mb.void_type);
        },
        .int => |int_ty| blk: {
            const lowered = try self.lowerExpr(value.expr);
            const widened = if (int_ty.bits == 64)
                lowered
            else
                try self.emit(.{ .int_to_int = lowered }, self.mb.i64_type);
            const signed_flag = try self.emit(.{ .const_bool = int_ty.signed }, self.mb.bool_type);
            break :blk try @TypeOf(self.*).emitPrintHelperCall(self, value.helper_declaration_id, &.{ widened, signed_flag }, self.mb.void_type);
        },
        else => return error.LowerInvariantViolation,
    };
}

pub fn lowerInterpolatedStringExpr(self: anytype, parts: []const sir.BuiltinPrintPart) LowerError!lir.ValueId {
    var acc = try @TypeOf(self.*).emitStringResultAt(self, runtime_symbols.name(.fmt_empty_into), &.{});
    for (parts) |part| {
        acc = switch (part) {
            .literal => |text| blk: {
                if (text.len == 0) break :blk acc;
                const value = try self.emit(.{ .const_string = try self.mb.allocator.dupe(u8, text) }, self.mb.string_type);
                break :blk try @TypeOf(self.*).appendRuntimeString(self, acc, value);
            },
            .value => |value| try @TypeOf(self.*).lowerInterpolatedStringValue(self, acc, value),
        };
    }
    return acc;
}

pub fn lowerInterpolatedStringValue(self: anytype, acc: lir.ValueId, value: sir.BuiltinPrintValue) LowerError!lir.ValueId {
    const value_ty = try @TypeOf(self.*).lowerExprType(self, value.expr);
    return switch (self.mb.types.items[value_ty]) {
        .string => blk: {
            const lowered = try self.lowerExpr(value.expr);
            break :blk try @TypeOf(self.*).appendRuntimeString(self, acc, lowered);
        },
        .bool => blk: {
            const lowered = try self.lowerExpr(value.expr);
            break :blk try @TypeOf(self.*).lowerInterpolatedBoolAppend(self, acc, lowered);
        },
        .int => |int_ty| blk: {
            const lowered = try self.lowerExpr(value.expr);
            const widened = if (int_ty.bits == 64)
                lowered
            else
                try self.emit(.{ .int_to_int = lowered }, self.mb.i64_type);
            const c_i32_ty = try self.mb.lowerExactNamedIntType("i32");
            const signed_flag = try self.emit(.{ .const_int = if (int_ty.signed) 1 else 0 }, c_i32_ty);
            const kind = try self.emit(.{ .const_int = switch (value.format) {
                .direct, .decimal => 0,
                .binary => 1,
                .octal => 2,
                .hex_lower => 3,
                .hex_upper => 4,
            } }, c_i32_ty);
            const acc_ptr = try @TypeOf(self.*).materializeRuntimeArgument(self, acc, self.mb.string_type);
            break :blk try @TypeOf(self.*).emitStringResultAt(self, runtime_symbols.name(.fmt_append_int_into), &.{ acc_ptr, widened, signed_flag, kind });
        },
        else => return error.LowerInvariantViolation,
    };
}

pub fn lowerInterpolatedBoolAppend(self: anytype, acc: lir.ValueId, condition: lir.ValueId) LowerError!lir.ValueId {
    const result_ptr = try self.emit(.{ .stack_alloc = self.mb.string_type }, try self.mb.appendType(.{ .pointer = self.mb.string_type }));
    const true_blk = try self.beginBlock("interp_bool_true");
    const false_blk = try self.beginBlock("interp_bool_false");
    const cont_blk = try self.beginBlock("interp_bool_cont");
    try self.endBlock(.{ .cond_br = .{
        .condition = condition,
        .then_block = true_blk,
        .else_block = false_blk,
    } });

    self.current_block = true_blk;
    const true_text = try self.emit(.{ .const_string = try self.mb.allocator.dupe(u8, "true") }, self.mb.string_type);
    const true_value = try @TypeOf(self.*).appendRuntimeString(self, acc, true_text);
    _ = try self.emit(.{ .store = .{ .ptr = result_ptr, .value = true_value } }, self.mb.void_type);
    try self.endBlock(.{ .br = cont_blk });

    self.current_block = false_blk;
    const false_text = try self.emit(.{ .const_string = try self.mb.allocator.dupe(u8, "false") }, self.mb.string_type);
    const false_value = try @TypeOf(self.*).appendRuntimeString(self, acc, false_text);
    _ = try self.emit(.{ .store = .{ .ptr = result_ptr, .value = false_value } }, self.mb.void_type);
    try self.endBlock(.{ .br = cont_blk });

    self.current_block = cont_blk;
    return self.emit(.{ .load = result_ptr }, self.mb.string_type);
}

/// Emit a builtin print call from the checked declaration identity sema
/// recorded for the prelude helper the part reaches.
pub fn emitPrintHelperCall(
    self: anytype,
    helper_declaration_id: ?identity.DeclId,
    args: []const lir.ValueId,
    return_ty: lir.TypeId,
) LowerError!lir.ValueId {
    const callee = try self.mb.functionById(helper_declaration_id orelse return LowerError.InvalidIdentity);
    return self.emit(.{ .call = .{
        .name = callee.abi_name orelse callee.name,
        .args = try @TypeOf(self.*).dupeArgs(self, args),
    } }, return_ty);
}

pub fn emitRuntimeCall(
    self: anytype,
    name: []const u8,
    args: []const lir.ValueId,
    return_ty: lir.TypeId,
) LowerError!lir.ValueId {
    return self.emit(.{ .call = .{
        .name = name,
        .args = try @TypeOf(self.*).dupeArgs(self, args),
    } }, return_ty);
}

pub fn materializeRuntimeArgument(self: anytype, value: lir.ValueId, ty: lir.TypeId) LowerError!lir.ValueId {
    const ptr = try self.emit(.{ .stack_alloc = ty }, ty);
    try self.emitVoid(.{ .store = .{ .ptr = ptr, .value = value } });
    return ptr;
}

pub fn emitStringResultAt(self: anytype, name: []const u8, args: []const lir.ValueId) LowerError!lir.ValueId {
    const result_ptr = try self.emit(.{ .stack_alloc = self.mb.string_type }, self.mb.string_type);
    const forwarded = try self.mb.allocator.alloc(lir.ValueId, args.len + 1);
    defer self.mb.allocator.free(forwarded);
    forwarded[0] = result_ptr;
    @memcpy(forwarded[1..], args);
    _ = try @TypeOf(self.*).emitRuntimeCall(self, name, forwarded, self.mb.void_type);
    return self.emit(.{ .load = result_ptr }, self.mb.string_type);
}

pub fn appendRuntimeString(self: anytype, acc: lir.ValueId, value: lir.ValueId) LowerError!lir.ValueId {
    const acc_ptr = try @TypeOf(self.*).materializeRuntimeArgument(self, acc, self.mb.string_type);
    const value_ptr = try @TypeOf(self.*).materializeRuntimeArgument(self, value, self.mb.string_type);
    return @TypeOf(self.*).emitStringResultAt(self, runtime_symbols.name(.fmt_append_string_into), &.{ acc_ptr, value_ptr });
}

pub fn stringRuntimeParts(self: anytype, value: lir.ValueId) LowerError!struct { ptr: lir.ValueId, len: lir.ValueId } {
    const byte_ty = try self.mb.lowerExactNamedIntType("u8");
    const ptr_ty = try self.mb.appendType(.{ .pointer = byte_ty });
    return .{
        .ptr = try self.emit(.{ .extract_slice_ptr = value }, ptr_ty),
        .len = try self.emit(.{ .string_len = value }, self.mb.i64_type),
    };
}

pub fn lowerTestAssertExpr(self: anytype, condition: *sir.Expr) LowerError!lir.ValueId {
    const condition_value = try self.lowerExpr(condition);
    const pass_block = try self.beginBlock("assert_pass");
    const fail_block = try self.beginBlock("assert_fail");
    try self.endBlock(.{ .cond_br = .{
        .condition = condition_value,
        .then_block = pass_block,
        .else_block = fail_block,
    } });

    self.current_block = fail_block;
    _ = try self.emit(.{ .call = .{
        .name = runtime_symbols.name(.assertion_fail),
        .args = try @TypeOf(self.*).dupeArgs(self, &.{}),
    } }, self.mb.void_type);
    try self.endBlock(.{ .@"unreachable" = {} });

    self.current_block = pass_block;
    return condition_value;
}

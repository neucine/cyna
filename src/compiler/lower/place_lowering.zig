const std = @import("std");
const sir = @import("../sema/sir.zig");
const identity = @import("../sema/identity.zig");
const lir = @import("lir.zig");
const errors = @import("errors.zig");
const LowerError = errors.Error;

pub fn lowerFieldExpr(self: anytype, field: sir.FieldAccess) LowerError!lir.ValueId {
    const object_ty = try @TypeOf(self.*).lowerExprType(self, field.object);
    const field_ty = try self.structFieldTypeResolved(field.struct_decl_id, field.struct_name, field.field);
    const field_index = try self.structFieldIndexResolved(field.struct_decl_id, field.struct_name, field.field);
    // Prefer place-first projection for addressable values. This keeps
    // globals, locals, and nested projections on a direct pointer path and
    // avoids platform-sensitive aggregate copies. True temporaries still
    // fall back to by-value extraction below.
    if (!try self.structIsPackedResolved(field.struct_decl_id, field.struct_name) and try @TypeOf(self.*).exprIsPlace(self, field.object)) {
        const base = try @TypeOf(self.*).lowerAddressablePlacePointer(self, field.object);
        const place = try @TypeOf(self.*).lowerFieldPlacePointer(self, base, .{
            .struct_decl_id = field.struct_decl_id,
            .struct_name = field.struct_name,
            .field = field.field,
        });
        return self.emit(.{ .load = place.ptr_value }, place.ty);
    }

    const object = try self.lowerExpr(field.object);
    return switch (self.mb.types.items[object_ty]) {
        .pointer => |pointee| switch (self.mb.types.items[pointee]) {
            .@"struct" => blk: {
                const field_ptr_ty = try self.mb.appendType(.{ .pointer = field_ty });
                const field_ptr = try self.emit(.{ .field_ptr = .{
                    .ptr = object,
                    .field_index = field_index,
                } }, field_ptr_ty);
                break :blk try self.emit(.{ .load = field_ptr }, field_ty);
            },
            else => error.LowerInvariantViolation,
        },
        else => self.emit(.{ .extract_field = .{
            .value = object,
            .field_index = field_index,
        } }, field_ty),
    };
}

pub fn lowerBorrowedFieldExpr(self: anytype, field: sir.FieldAccess) LowerError!lir.ValueId {
    // Transitional path: still materializes a value, but it now walks
    // through an addressable place first. That keeps borrowed-field
    // lowering structurally separate from plain field extraction and gives
    // us the exact seam where a future non-owning projected-read runtime
    // form can replace the final `load`.
    const place = try @TypeOf(self.*).lowerBorrowedFieldPlacePointer(self, field);
    return @TypeOf(self.*).lowerBorrowedProjectionValueFromPlace(self, place);
}

pub fn lowerUnionFieldExpr(self: anytype, field: sir.UnionFieldAccess) LowerError!lir.ValueId {
    const object = try self.lowerExpr(field.object);
    const field_ty = try self.unionCasePayloadTypeResolved(field.union_decl_id, field.union_name, field.field);
    return self.emit(.{ .extract_field = .{
        .value = object,
        .field_index = @intCast((try self.unionCaseTagResolved(field.union_decl_id, field.union_name, field.field)) + 1),
    } }, field_ty);
}

pub fn lowerBorrowedUnionFieldExpr(self: anytype, field: sir.UnionFieldAccess) LowerError!lir.ValueId {
    const place = try @TypeOf(self.*).lowerBorrowedUnionFieldPlacePointer(self, field);
    return @TypeOf(self.*).lowerBorrowedProjectionValueFromPlace(self, place);
}

pub fn lowerIndexExpr(self: anytype, index: sir.Index) LowerError!lir.ValueId {
    const object_ty = try @TypeOf(self.*).lowerExprType(self, index.object);
    if (self.mb.types.items[object_ty] == .dense_array) {
        return @TypeOf(self.*).lowerListIndexExpr(self, index.object, index.index);
    }
    // Same invariant as field projection: resolve a place first whenever
    // the indexed object is addressable, then materialize only the final
    // element value. The stack-copy fallback is reserved for temporaries.
    const index_has_addressable_element = switch (self.mb.types.items[object_ty]) {
        .array, .slice => true,
        else => false,
    };
    if (index_has_addressable_element and try @TypeOf(self.*).exprIsPlace(self, index.object)) {
        const base = try @TypeOf(self.*).lowerAddressablePlacePointer(self, index.object);
        const place = try @TypeOf(self.*).lowerIndexPlacePointer(self, base, index.index);
        return self.emit(.{ .load = place.ptr_value }, place.ty);
    }

    const object_value = try self.lowerExpr(index.object);
    const tmp_ptr = try self.emit(.{ .stack_alloc = object_ty }, object_ty);
    try self.emitVoid(.{ .store = .{
        .ptr = tmp_ptr,
        .value = object_value,
    } });
    return @TypeOf(self.*).lowerIndexFromPointer(self, tmp_ptr, object_ty, index.index);
}

pub fn lowerBorrowedIndexExpr(self: anytype, index: sir.Index) LowerError!lir.ValueId {
    // Transitional path analogous to `lowerBorrowedFieldExpr`: resolve the
    // projected place first, then materialize the current value with a
    // final `load`. The place-first structure is the future insertion
    // point for a true non-owning projected-read representation.
    const place = try @TypeOf(self.*).lowerBorrowedIndexPlacePointer(self, index);
    return @TypeOf(self.*).lowerBorrowedProjectionValueFromPlace(self, place);
}

pub const BorrowedSparseOptionalSubject = struct {
    present: lir.ValueId,
    payload_ptr: lir.ValueId,
    payload_ty: lir.TypeId,
};

pub fn lowerBorrowedSparseOptionalSubject(self: anytype, expr: *sir.Expr) LowerError!?BorrowedSparseOptionalSubject {
    if (expr.* == .borrowed_index) {
        const index = expr.borrowed_index;
        const sparse_ty = try @TypeOf(self.*).lowerExprType(self, index.object);
        const payload_ty = switch (self.mb.types.items[sparse_ty]) {
            .sparse_array => |item_ty| item_ty,
            else => return null,
        };
        const index_value = try @TypeOf(self.*).lowerExprForTarget(self, index.index, self.mb.i64_type);
        const sparse_value = try self.lowerExpr(index.object);
        const present = try self.emit(.{ .sparse_contains_index = .{
            .lhs = sparse_value,
            .rhs = index_value,
        } }, self.mb.bool_type);
        const payload_ptr_ty = try self.mb.appendType(.{ .pointer = payload_ty });
        const payload_ptr = try self.emit(.{ .sparse_payload_ptr = .{
            .lhs = sparse_value,
            .rhs = index_value,
        } }, payload_ptr_ty);
        return .{
            .present = present,
            .payload_ptr = payload_ptr,
            .payload_ty = payload_ty,
        };
    }

    const sparse_place = switch (expr.*) {
        .ref_index_local => |index_ref| blk: {
            const local = try self.getLocal(index_ref.local_name);
            const base_ty = switch (self.mb.types.items[local.ty]) {
                .pointer => |pointee| pointee,
                else => local.ty,
            };
            if (self.mb.types.items[base_ty] != .sparse_array) return null;
            break :blk PlacePointer{
                .ptr_value = switch (self.mb.types.items[local.ty]) {
                    .pointer => try self.emit(.{ .load = local.ptr_value }, local.ty),
                    else => local.ptr_value,
                },
                .ty = base_ty,
            };
        },
        .ref_index_path_local => |index_ref| blk: {
            const base = try @TypeOf(self.*).lowerTakePlacePointer(self, index_ref.local_name, index_ref.steps);
            if (self.mb.types.items[base.ty] != .sparse_array) return null;
            break :blk base;
        },
        else => return null,
    };
    const index_expr = switch (expr.*) {
        .ref_index_local => |index_ref| index_ref.index,
        .ref_index_path_local => |index_ref| index_ref.index,
        else => unreachable,
    };
    const payload_ty = switch (self.mb.types.items[sparse_place.ty]) {
        .sparse_array => |item_ty| item_ty,
        else => unreachable,
    };
    const index_value = try @TypeOf(self.*).lowerExprForTarget(self, index_expr, self.mb.i64_type);
    const sparse_value = try self.emit(.{ .load = sparse_place.ptr_value }, sparse_place.ty);
    const present = try self.emit(.{ .sparse_contains_index = .{
        .lhs = sparse_value,
        .rhs = index_value,
    } }, self.mb.bool_type);
    const payload_ptr_ty = try self.mb.appendType(.{ .pointer = payload_ty });
    const payload_ptr = try self.emit(.{ .sparse_payload_ptr = .{
        .lhs = sparse_value,
        .rhs = index_value,
    } }, payload_ptr_ty);
    return .{
        .present = present,
        .payload_ptr = payload_ptr,
        .payload_ty = payload_ty,
    };
}

pub fn lowerIndexFromPointer(self: anytype, ptr_value: lir.ValueId, container_ty: lir.TypeId, index_expr: *sir.Expr) LowerError!lir.ValueId {
    if (self.mb.types.items[container_ty] == .sparse_array) {
        return @TypeOf(self.*).lowerSparseIndexFromPointer(self, ptr_value, container_ty, index_expr);
    }
    const index_value = try @TypeOf(self.*).lowerExprForTarget(self, index_expr, self.mb.i64_type);
    return @TypeOf(self.*).lowerIndexFromPointerValue(self, ptr_value, container_ty, index_value);
}

pub fn lowerIndexFromPointerValue(self: anytype, ptr_value: lir.ValueId, container_ty: lir.TypeId, index_value: lir.ValueId) LowerError!lir.ValueId {
    const elem_ty = switch (self.mb.types.items[container_ty]) {
        .array => |array_ty| array_ty.elem,
        .slice => |item_ty| item_ty,
        else => return error.LowerInvariantViolation,
    };
    const elem_ptr_ty = try self.mb.appendType(.{ .pointer = elem_ty });
    const elem_ptr = switch (self.mb.types.items[container_ty]) {
        .slice => blk: {
            const slice_value = try self.emit(.{ .load = ptr_value }, container_ty);
            const base_ptr = try self.emit(.{ .extract_slice_ptr = slice_value }, elem_ptr_ty);
            break :blk try self.emit(.{ .index_ptr = .{
                .ptr = base_ptr,
                .index = index_value,
            } }, elem_ptr_ty);
        },
        else => try self.emit(.{ .index_ptr = .{
            .ptr = ptr_value,
            .index = index_value,
        } }, elem_ptr_ty),
    };
    return self.emit(.{ .load = elem_ptr }, elem_ty);
}

pub fn lowerSparseIndexFromPointer(
    self: anytype,
    ptr_value: lir.ValueId,
    container_ty: lir.TypeId,
    index_expr: *sir.Expr,
) LowerError!lir.ValueId {
    const item_ty = switch (self.mb.types.items[container_ty]) {
        .sparse_array => |child| child,
        else => return error.LowerInvariantViolation,
    };
    const result_ty = try self.mb.appendType(.{ .optional = item_ty });
    const index_value = try @TypeOf(self.*).lowerExprForTarget(self, index_expr, self.mb.i64_type);
    const sparse_value = try self.emit(.{ .load = ptr_value }, container_ty);
    const tmp_ptr = try self.emit(.{ .stack_alloc = item_ty }, item_ty);
    const found = try self.emit(.{ .sparse_get = .{
        .a = sparse_value,
        .b = index_value,
        .c = tmp_ptr,
        .d = try @TypeOf(self.*).emitTypeDesc(self, item_ty),
    } }, self.mb.bool_type);
    const result_ptr = try self.emit(.{ .stack_alloc = result_ty }, result_ty);
    const some_blk = try self.beginBlock("sparse_index_some");
    const none_blk = try self.beginBlock("sparse_index_none");
    const cont_blk = try self.beginBlock("sparse_index_cont");
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

pub const PlacePointer = struct {
    ptr_value: lir.ValueId,
    ty: lir.TypeId,
};

/// The single lowering entry point for an addressable SIR place path. Sema has
/// already decided access and legality; lowering only materializes the root
/// pointer and applies the recorded projections.
pub fn lowerResolvedPlacePath(self: anytype, path: sir.ResolvedPlacePath) LowerError!PlacePointer {
    var current: PlacePointer = switch (path.root) {
        .local => |root| blk: {
            const local = try self.getLocal(root.name);
            if (root.dereference_pointer and self.mb.types.items[local.ty] == .pointer) {
                break :blk .{
                    .ptr_value = try self.emit(.{ .load = local.ptr_value }, local.ty),
                    .ty = self.mb.types.items[local.ty].pointer,
                };
            }
            break :blk .{
                .ptr_value = local.ptr_value,
                .ty = local.ty,
            };
        },
        .global => |global_ref| blk: {
            const global = try self.mb.globalById(global_ref.decl_id orelse return LowerError.InvalidIdentity);
            break :blk .{
                .ptr_value = try self.emitGlobalSymbolAddr(global, global.ty),
                .ty = global.ty,
            };
        },
        .pointer_expr => |pointer_expr| blk: {
            const pointer_ty = try @TypeOf(self.*).lowerExprType(self, pointer_expr);
            break :blk .{
                .ptr_value = try self.lowerExpr(pointer_expr),
                .ty = try self.pointerPointee(pointer_ty) orelse return error.LowerInvariantViolation,
            };
        },
    };

    for (path.projections) |projection| {
        current = switch (projection) {
            .field => |field| try @TypeOf(self.*).lowerFieldPlacePointer(self, current, field),
            .index => |index_expr| try @TypeOf(self.*).lowerIndexPlacePointer(self, current, index_expr),
        };
    }
    return current;
}

pub fn lowerBorrowedProjectionValueFromPlace(self: anytype, place: PlacePointer) LowerError!lir.ValueId {
    // Central transitional hook for borrowed projected reads. Today this
    // still materializes the current value with a load; the eventual
    // non-owning runtime representation should replace this one operation.
    try @TypeOf(self.*).recordOwnershipTrace(self, "borrowed_projection place materialize", .{});
    return self.emit(.{ .load = place.ptr_value }, place.ty);
}

pub fn lowerBorrowedFieldPlacePointer(self: anytype, field: sir.FieldAccess) LowerError!PlacePointer {
    const base = if (try @TypeOf(self.*).exprIsAddressableProjectionSource(self, field.object))
        try @TypeOf(self.*).lowerAddressableBorrowedProjectionPlacePointer(self, field.object)
    else blk: {
        const object_ty = try @TypeOf(self.*).lowerExprType(self, field.object);
        const object_value = try self.lowerExpr(field.object);
        const tmp_ptr = try self.emit(.{ .stack_alloc = object_ty }, object_ty);
        try self.emitVoid(.{ .store = .{ .ptr = tmp_ptr, .value = object_value } });
        try @TypeOf(self.*).registerCompilerTemporaryCleanup(self, "borrowed_field_base", tmp_ptr, object_ty);
        break :blk PlacePointer{ .ptr_value = tmp_ptr, .ty = object_ty };
    };
    return @TypeOf(self.*).lowerFieldPlacePointer(self, base, .{
        .struct_decl_id = field.struct_decl_id,
        .struct_name = field.struct_name,
        .field = field.field,
    });
}

pub fn lowerBorrowedIndexPlacePointer(self: anytype, index: sir.Index) LowerError!PlacePointer {
    const base = if (try @TypeOf(self.*).exprIsAddressableProjectionSource(self, index.object))
        try @TypeOf(self.*).lowerAddressableBorrowedProjectionPlacePointer(self, index.object)
    else blk: {
        const object_ty = try @TypeOf(self.*).lowerExprType(self, index.object);
        switch (self.mb.types.items[object_ty]) {
            .array, .slice, .dense_array => {},
            else => return error.LowerInvariantViolation,
        }
        const object_value = try self.lowerExpr(index.object);
        const tmp_ptr = try self.emit(.{ .stack_alloc = object_ty }, object_ty);
        try self.emitVoid(.{ .store = .{ .ptr = tmp_ptr, .value = object_value } });
        break :blk PlacePointer{
            .ptr_value = tmp_ptr,
            .ty = object_ty,
        };
    };
    return @TypeOf(self.*).lowerIndexPlacePointer(self, base, index.index);
}

pub fn lowerBorrowedUnionFieldPlacePointer(self: anytype, field: sir.UnionFieldAccess) LowerError!PlacePointer {
    const base = try @TypeOf(self.*).lowerAddressableBorrowedProjectionPlacePointer(self, field.object);
    const field_ty = try self.unionCasePayloadTypeResolved(field.union_decl_id, field.union_name, field.field);
    const ptr_ty = try self.mb.appendType(.{ .pointer = field_ty });
    const base_ptr_value = switch (self.mb.types.items[base.ty]) {
        .pointer => try self.emit(.{ .load = base.ptr_value }, base.ty),
        else => base.ptr_value,
    };
    return .{
        .ptr_value = try self.emit(.{ .union_payload_ptr = .{
            .ptr = base_ptr_value,
            .union_tag = try self.unionCaseTagResolved(field.union_decl_id, field.union_name, field.field),
        } }, ptr_ty),
        .ty = field_ty,
    };
}

pub fn lowerAddressableBorrowedProjectionPlacePointer(self: anytype, expr: *sir.Expr) LowerError!PlacePointer {
    return switch (expr.*) {
        .field => |field| blk: {
            const base = try @TypeOf(self.*).lowerAddressableBorrowedProjectionPlacePointer(self, field.object);
            break :blk try @TypeOf(self.*).lowerFieldPlacePointer(self, base, .{
                .struct_decl_id = field.struct_decl_id,
                .struct_name = field.struct_name,
                .field = field.field,
            });
        },
        .index => |index| try @TypeOf(self.*).lowerBorrowedIndexPlacePointer(self, index),
        .union_field => |field| blk: {
            const base = try @TypeOf(self.*).lowerAddressableBorrowedProjectionPlacePointer(self, field.object);
            const field_ty = try self.unionCasePayloadTypeResolved(field.union_decl_id, field.union_name, field.field);
            const ptr_ty = try self.mb.appendType(.{ .pointer = field_ty });
            const base_ptr_value = switch (self.mb.types.items[base.ty]) {
                .pointer => try self.emit(.{ .load = base.ptr_value }, base.ty),
                else => base.ptr_value,
            };
            break :blk .{
                .ptr_value = try self.emit(.{ .field_ptr = .{
                    .ptr = base_ptr_value,
                    .field_index = @intCast((try self.unionCaseTagResolved(field.union_decl_id, field.union_name, field.field)) + 1),
                } }, ptr_ty),
                .ty = field_ty,
            };
        },
        .borrowed_field => |field| try @TypeOf(self.*).lowerBorrowedFieldPlacePointer(self, field),
        .borrowed_index => |index| try @TypeOf(self.*).lowerBorrowedIndexPlacePointer(self, index),
        .borrowed_union_field => |field| try @TypeOf(self.*).lowerBorrowedUnionFieldPlacePointer(self, field),
        .ref_load => |ref_expr| blk: {
            const ptr_value = try self.lowerExpr(ref_expr);
            const ptr_ty = try @TypeOf(self.*).lowerExprType(self, ref_expr);
            const pointee_ty = try self.pointerPointee(ptr_ty) orelse return error.LowerInvariantViolation;
            break :blk .{
                .ptr_value = ptr_value,
                .ty = pointee_ty,
            };
        },
        else => try @TypeOf(self.*).lowerAddressablePlacePointer(self, expr),
    };
}

pub fn lowerAddressablePlacePointer(self: anytype, expr: *sir.Expr) LowerError!PlacePointer {
    return switch (expr.*) {
        .local => |name| if (self.getLocalIfPresent(name) != null)
            @TypeOf(self.*).lowerResolvedPlacePath(self, .{
                .root = .{ .local = .{ .name = name, .dereference_pointer = false } },
            })
        else if (self.getGlobalInfo(name)) |global|
            PlacePointer{
                .ptr_value = try self.emitGlobalSymbolAddr(global, global.ty),
                .ty = global.ty,
            }
        else
            LowerError.MissingLocal,
        .global_ref => |global_ref| @TypeOf(self.*).lowerResolvedPlacePath(self, .{
            .root = .{ .global = global_ref },
        }),
        .raw_deref => |raw_expr| @TypeOf(self.*).lowerResolvedPlacePath(self, .{
            .root = .{ .pointer_expr = raw_expr.expr },
        }),
        .field => |field| blk: {
            const base = try @TypeOf(self.*).lowerAddressablePlacePointer(self, field.object);
            break :blk try @TypeOf(self.*).lowerFieldPlacePointer(self, base, .{
                .struct_decl_id = field.struct_decl_id,
                .struct_name = field.struct_name,
                .field = field.field,
            });
        },
        .tuple_field => |field| blk: {
            const base = try @TypeOf(self.*).lowerAddressablePlacePointer(self, field.object);
            const fields = switch (self.mb.types.items[base.ty]) {
                .@"struct" => |decl| decl.fields,
                else => return error.LowerInvariantViolation,
            };
            if (field.index >= fields.len) return error.LowerInvariantViolation;
            const field_ty = fields[field.index].ty;
            const ptr_ty = try self.mb.appendType(.{ .pointer = field_ty });
            break :blk .{
                .ptr_value = try self.emit(.{ .field_ptr = .{
                    .ptr = base.ptr_value,
                    .field_index = @intCast(field.index),
                } }, ptr_ty),
                .ty = field_ty,
            };
        },
        .index => |index| blk: {
            const base = try @TypeOf(self.*).lowerAddressablePlacePointer(self, index.object);
            break :blk try @TypeOf(self.*).lowerIndexPlacePointer(self, base, index.index);
        },
        else => error.LowerInvariantViolation,
    };
}

pub fn exprIsPlace(self: anytype, expr: *sir.Expr) LowerError!bool {
    return (try self.mb.exprMetadata(expr)).semantics.category == .place;
}

pub fn exprIsAddressableProjectionSource(self: anytype, expr: *sir.Expr) LowerError!bool {
    return switch ((try self.mb.exprMetadata(expr)).semantics.category) {
        .place, .borrowed_projection => true,
        .value => false,
    };
}

pub fn lowerTakeIndexLocal(self: anytype, take_index: sir.TakeIndexLocal) LowerError!lir.ValueId {
    const place = try @TypeOf(self.*).lowerTakeIndexedPlacePointer(self, take_index.local_name, &.{}, take_index.index);
    return @TypeOf(self.*).lowerTakeFromPlace(self, take_index.local_name, place);
}

pub fn lowerTakeIndexPathLocal(self: anytype, take_path: sir.TakeIndexPathLocal) LowerError!lir.ValueId {
    const place = try @TypeOf(self.*).lowerTakeIndexedPlacePointer(self, take_path.local_name, take_path.steps, take_path.index);
    return @TypeOf(self.*).lowerTakeFromPlace(self, take_path.local_name, place);
}

pub fn lowerTakePathLocal(self: anytype, take_path: sir.TakePathLocal) LowerError!lir.ValueId {
    const place = try @TypeOf(self.*).lowerTakePlacePointer(self, take_path.local_name, take_path.steps);
    return @TypeOf(self.*).lowerTakeFromPlace(self, take_path.local_name, place);
}

pub fn lowerTakeFromPlace(self: anytype, root_name: []const u8, place: PlacePointer) LowerError!lir.ValueId {
    switch (self.mb.types.items[place.ty]) {
        .optional => {},
        else => return error.LowerInvariantViolation,
    }

    const old_value = try self.emit(.{ .load = place.ptr_value }, place.ty);
    const none_value = try self.emit(.make_none, place.ty);
    try self.emitVoid(.{ .store = .{
        .ptr = place.ptr_value,
        .value = none_value,
    } });
    try @TypeOf(self.*).recordOwnershipTrace(self, "take {s}: source cleared to none", .{root_name});
    return old_value;
}

pub fn lowerTakePlacePointer(
    self: anytype,
    local_name: []const u8,
    steps: []const sir.TakePathStep,
) LowerError!PlacePointer {
    return @TypeOf(self.*).lowerResolvedPlacePath(self, .{
        .root = .{ .local = .{ .name = local_name } },
        .projections = steps,
    });
}

pub fn lowerTakeIndexedPlacePointer(
    self: anytype,
    local_name: []const u8,
    steps: []const sir.TakePathStep,
    index_expr: *sir.Expr,
) LowerError!PlacePointer {
    const base_place = try @TypeOf(self.*).lowerTakePlacePointer(self, local_name, steps);
    return @TypeOf(self.*).lowerIndexPlacePointer(self, base_place, index_expr);
}

pub fn lowerFieldPlacePointer(
    self: anytype,
    base: PlacePointer,
    field: sir.StructFieldPathStep,
) LowerError!PlacePointer {
    const field_ty = try self.structFieldTypeResolved(field.struct_decl_id, field.struct_name, field.field);
    const ptr_ty = try self.mb.appendType(.{ .pointer = field_ty });
    const base_ptr_value = switch (self.mb.types.items[base.ty]) {
        .pointer => try self.emit(.{ .load = base.ptr_value }, base.ty),
        else => base.ptr_value,
    };
    return .{
        .ptr_value = try self.emit(.{ .field_ptr = .{
            .ptr = base_ptr_value,
            .field_index = try self.structFieldIndexResolved(field.struct_decl_id, field.struct_name, field.field),
        } }, ptr_ty),
        .ty = field_ty,
    };
}

pub fn lowerIndexPlacePointer(
    self: anytype,
    base: PlacePointer,
    index_expr: *sir.Expr,
) LowerError!PlacePointer {
    // A borrowed array local stores a pointer; index the pointee storage.
    if (self.mb.types.items[base.ty] == .pointer) {
        const target = self.mb.types.items[base.ty].pointer;
        if (self.mb.types.items[target] == .array) {
            return lowerIndexPlacePointer(self, .{
                .ptr_value = try self.emit(.{ .load = base.ptr_value }, base.ty),
                .ty = target,
            }, index_expr);
        }
    }
    const index_value = try @TypeOf(self.*).lowerExprForTarget(self, index_expr, self.mb.i64_type);
    return switch (self.mb.types.items[base.ty]) {
        .array => |array_ty| blk: {
            const ptr_ty = try self.mb.appendType(.{ .pointer = array_ty.elem });
            break :blk .{
                .ptr_value = try self.emit(.{ .index_ptr = .{
                    .ptr = base.ptr_value,
                    .index = index_value,
                } }, ptr_ty),
                .ty = array_ty.elem,
            };
        },
        .slice => |item_ty| blk: {
            const ptr_ty = try self.mb.appendType(.{ .pointer = item_ty });
            const slice_value = try self.emit(.{ .load = base.ptr_value }, base.ty);
            const base_ptr = try self.emit(.{ .extract_slice_ptr = slice_value }, ptr_ty);
            break :blk .{
                .ptr_value = try self.emit(.{ .index_ptr = .{
                    .ptr = base_ptr,
                    .index = index_value,
                } }, ptr_ty),
                .ty = item_ty,
            };
        },
        .dense_array => |item_ty| blk: {
            const list_value = try @TypeOf(self.*).materializeSequenceValueFromValue(
                self,
                try self.emit(.{ .load = base.ptr_value }, base.ty),
                base.ty,
            );
            break :blk .{
                .ptr_value = try @TypeOf(self.*).emitSequenceAtValue(self, list_value, base.ty, item_ty, index_value),
                .ty = item_ty,
            };
        },
        else => error.LowerInvariantViolation,
    };
}

pub fn lowerRefFieldLocal(self: anytype, field: sir.RefFieldLocal) LowerError!lir.ValueId {
    const projections = [_]sir.PlaceProjectionStep{.{ .field = .{
        .struct_decl_id = field.struct_decl_id,
        .struct_name = field.struct_name,
        .field = field.field,
    } }};
    return (try @TypeOf(self.*).lowerResolvedPlacePath(self, .{
        .root = .{ .local = .{ .name = field.local_name } },
        .projections = &projections,
    })).ptr_value;
}

pub fn lowerRefFieldOwnedLocal(self: anytype, field: sir.RefFieldLocal) LowerError!lir.ValueId {
    return @TypeOf(self.*).lowerRefFieldLocal(self, field);
}

pub fn lowerRefFieldExpr(self: anytype, field: sir.RefFieldExpr) LowerError!lir.ValueId {
    const projections = [_]sir.PlaceProjectionStep{.{ .field = .{
        .struct_decl_id = field.struct_decl_id,
        .struct_name = field.struct_name,
        .field = field.field,
    } }};
    return (try @TypeOf(self.*).lowerResolvedPlacePath(self, .{
        .root = .{ .pointer_expr = field.object },
        .projections = &projections,
    })).ptr_value;
}

pub fn lowerRefUnionFieldLocal(self: anytype, field: sir.RefUnionFieldLocal) LowerError!lir.ValueId {
    const local = try self.getLocal(field.local_name);
    const field_ty = try self.unionCasePayloadTypeResolved(field.union_decl_id, field.union_name, field.field);
    const ptr_ty = try self.mb.appendType(.{ .pointer = field_ty });
    const base_ptr_value = switch (self.mb.types.items[local.ty]) {
        .pointer => try self.emit(.{ .load = local.ptr_value }, local.ty),
        else => local.ptr_value,
    };
    return self.emit(.{ .union_payload_ptr = .{
        .ptr = base_ptr_value,
        .union_tag = try self.unionCaseTagResolved(field.union_decl_id, field.union_name, field.field),
    } }, ptr_ty);
}

pub fn lowerRefIndexLocal(self: anytype, index_ref: sir.RefIndexLocal) LowerError!lir.ValueId {
    const projections = [_]sir.PlaceProjectionStep{.{ .index = index_ref.index }};
    return (try @TypeOf(self.*).lowerResolvedPlacePath(self, .{
        .root = .{ .local = .{ .name = index_ref.local_name } },
        .projections = &projections,
    })).ptr_value;
}

pub fn lowerRefIndexPathLocal(self: anytype, index_ref: sir.TakeIndexPathLocal) LowerError!lir.ValueId {
    const place = try @TypeOf(self.*).lowerTakeIndexedPlacePointer(self, index_ref.local_name, index_ref.steps, index_ref.index);
    return place.ptr_value;
}

pub fn lowerRefPathLocal(self: anytype, take_path: sir.TakePathLocal) LowerError!lir.ValueId {
    const place = try @TypeOf(self.*).lowerTakePlacePointer(self, take_path.local_name, take_path.steps);
    return place.ptr_value;
}

pub fn lowerIndexType(self: anytype, index: sir.Index) LowerError!lir.TypeId {
    const object_ty = try @TypeOf(self.*).lowerExprType(self, index.object);
    return switch (self.mb.types.items[object_ty]) {
        .array => |array_ty| array_ty.elem,
        .slice => |item_ty| item_ty,
        .dense_array => |item_ty| item_ty,
        .sparse_array => |item_ty| try self.mb.appendType(.{ .optional = item_ty }),
        else => error.LowerInvariantViolation,
    };
}

pub fn lowerSliceTypeFromObject(self: anytype, object: *sir.Expr) LowerError!lir.TypeId {
    const object_ty = try @TypeOf(self.*).lowerExprType(self, object);
    return switch (self.mb.types.items[object_ty]) {
        .array => |array_ty| try self.mb.appendType(.{ .slice = array_ty.elem }),
        .dense_array => |item_ty| try self.mb.appendType(.{ .slice = item_ty }),
        .slice => object_ty,
        else => error.LowerInvariantViolation,
    };
}

// Assignment and mutation place interface.
pub fn lowerIndexAssignStmt(self: anytype, assign: sir.IndexAssign) LowerError!void {
    const object_ty = try @TypeOf(self.*).lowerExprType(self, assign.object);
    switch (self.mb.types.items[object_ty]) {
        .dense_array => {
            const item_ty = try @TypeOf(self.*).sequenceItemType(self, object_ty);
            const list_value = try @TypeOf(self.*).materializeSequenceValue(self, assign.object);
            const index_value = try @TypeOf(self.*).lowerExprForTarget(self, assign.index, self.mb.i64_type);
            const elem_ptr = try @TypeOf(self.*).emitSequenceAtValue(self, list_value, object_ty, item_ty, index_value);
            const val_value = try @TypeOf(self.*).lowerExprForTarget(self, assign.value, item_ty);
            try @TypeOf(self.*).storeWithCleanup(self, elem_ptr, assign.value, val_value, item_ty, try @TypeOf(self.*).typeNeedsDrop(self, item_ty));
        },
        .sparse_array => {
            const sparse = try @TypeOf(self.*).lowerMutableSequencePlace(self, assign.object, .sparse_insert_from_place);
            const index_value = try @TypeOf(self.*).lowerExprForTarget(self, assign.index, self.mb.i64_type);
            const item_ty = switch (self.mb.types.items[object_ty]) {
                .sparse_array => |payload_ty| payload_ty,
                else => return error.LowerInvariantViolation,
            };
            const optional_ty = try self.mb.appendType(.{ .optional = item_ty });
            const optional_value = try @TypeOf(self.*).lowerExprForTarget(self, assign.value, optional_ty);
            const is_some = try self.emit(.{ .extract_tag = optional_value }, self.mb.bool_type);
            const tmp_ptr = try self.emit(.{ .stack_alloc = item_ty }, item_ty);

            const some_blk = try self.beginBlock("sparse_assign_some");
            const none_blk = try self.beginBlock("sparse_assign_none");
            const cont_blk = try self.beginBlock("sparse_assign_cont");
            try self.endBlock(.{ .cond_br = .{
                .condition = is_some,
                .then_block = some_blk,
                .else_block = none_blk,
            } });

            self.current_block = some_blk;
            const payload = try self.emit(.{ .extract_payload = .{
                .value = optional_value,
                .union_tag = null,
            } }, item_ty);
            try self.emitVoid(.{ .store = .{ .ptr = tmp_ptr, .value = payload } });
            _ = try self.emit(.{ .sparse_set = .{
                .a = sparse.ptr,
                .b = index_value,
                .c = is_some,
                .d = tmp_ptr,
                .e = try @TypeOf(self.*).emitTypeDesc(self, item_ty),
            } }, self.mb.void_type);
            try self.endBlock(.{ .br = cont_blk });

            self.current_block = none_blk;
            const false_value = try self.emit(.{ .const_bool = false }, self.mb.bool_type);
            _ = try self.emit(.{ .sparse_set = .{
                .a = sparse.ptr,
                .b = index_value,
                .c = false_value,
                .d = tmp_ptr,
                .e = try @TypeOf(self.*).emitTypeDesc(self, item_ty),
            } }, self.mb.void_type);
            try self.endBlock(.{ .br = cont_blk });

            self.current_block = cont_blk;
        },
        .array, .slice => {
            const base_place = try @TypeOf(self.*).lowerAddressablePlacePointer(self, assign.object);
            const elem_place = try @TypeOf(self.*).lowerIndexPlacePointer(self, base_place, assign.index);
            const val_value = try @TypeOf(self.*).lowerExprForTarget(self, assign.value, elem_place.ty);
            try @TypeOf(self.*).storeWithCleanup(self, elem_place.ptr_value, assign.value, val_value, elem_place.ty, try @TypeOf(self.*).typeNeedsDrop(self, elem_place.ty));
        },
        else => return error.LowerInvariantViolation,
    }
}

pub fn lowerDerefAssignStmt(self: anytype, assign: sir.DerefAssign) LowerError!void {
    const ptr_value = try self.lowerExpr(assign.pointer);
    const ptr_ty = try @TypeOf(self.*).lowerExprType(self, assign.pointer);
    const pointee_ty = switch (self.mb.types.items[ptr_ty]) {
        .pointer => |pointee| pointee,
        else => return error.LowerInvariantViolation,
    };
    const value = try @TypeOf(self.*).lowerExprForTarget(self, assign.value, pointee_ty);
    if (assign.is_init) {
        try @TypeOf(self.*).captureExprValueInto(self, ptr_value, assign.value, value, pointee_ty);
        return;
    }
    if (assign.is_volatile) {
        if (try @TypeOf(self.*).typeNeedsDrop(self, pointee_ty)) return LowerError.InvalidSir;
        try self.emitVoid(.{ .volatile_store = .{
            .ptr = ptr_value,
            .value = value,
        } });
        return;
    }
    try @TypeOf(self.*).storeWithCleanup(self, ptr_value, assign.value, value, pointee_ty, try @TypeOf(self.*).typeNeedsDrop(self, pointee_ty));
}

pub fn lowerDerefFieldAssignStmt(self: anytype, assign: sir.DerefFieldAssign) LowerError!void {
    const ptr_value = try self.lowerExpr(assign.pointer);
    const ptr_ty = try @TypeOf(self.*).lowerExprType(self, assign.pointer);
    const struct_ty = switch (self.mb.types.items[ptr_ty]) {
        .pointer => |pointee| pointee,
        else => return error.LowerInvariantViolation,
    };
    if (assign.steps.len == 0) return error.LowerInvariantViolation;
    const root_decl_id = assign.steps[0].struct_decl_id orelse return LowerError.InvalidIdentity;
    if (!@TypeOf(self.*).typeIdsEqual(self, struct_ty, try self.mb.lowerStructTypeById(root_decl_id))) return LowerError.InvalidIdentity;
    const final_step = assign.steps[assign.steps.len - 1];
    const field_ty = try self.structFieldTypeResolved(final_step.struct_decl_id, final_step.struct_name, final_step.field);
    const value = try @TypeOf(self.*).lowerExprForTarget(self, assign.value, field_ty);
    const old_value = try self.emit(if (assign.is_volatile)
        .{ .volatile_load = ptr_value }
    else
        .{ .load = ptr_value }, struct_ty);
    const replacement = try @TypeOf(self.*).prepareCapturedExprValue(self, assign.value, value, field_ty);
    const rebuilt = try @TypeOf(self.*).rebuildStructValueWithFieldPath(self, old_value, struct_ty, assign.steps, 0, replacement);
    if (try @TypeOf(self.*).typeNeedsDrop(self, field_ty)) {
        const old_field = try @TypeOf(self.*).extractStructFieldPathValue(self, old_value, struct_ty, assign.steps, 0);
        try @TypeOf(self.*).emitDropValue(self, old_field, field_ty);
    }
    try self.emitVoid(if (assign.is_volatile)
        .{ .volatile_store = .{
            .ptr = ptr_value,
            .value = rebuilt,
        } }
    else
        .{ .store = .{
            .ptr = ptr_value,
            .value = rebuilt,
        } });
}

pub fn lowerFieldAssignStmt(self: anytype, assign: sir.FieldAssign) LowerError!void {
    if (assign.steps.len == 0) return error.LowerInvariantViolation;

    const root = blk: {
        if (self.getGlobalInfo(assign.root_name)) |global| {
            break :blk PlacePointer{
                .ptr_value = try self.emitGlobalSymbolAddr(global, global.ty),
                .ty = global.ty,
            };
        }
        const local = try self.getLocal(assign.root_name);
        break :blk PlacePointer{
            .ptr_value = if (self.mb.types.items[local.ty] == .pointer)
                try self.emit(.{ .load = local.ptr_value }, local.ty)
            else
                local.ptr_value,
            .ty = switch (self.mb.types.items[local.ty]) {
                .pointer => |pointee| pointee,
                else => local.ty,
            },
        };
    };

    const root_decl_id = assign.steps[0].struct_decl_id orelse return LowerError.InvalidIdentity;
    if (!@TypeOf(self.*).typeIdsEqual(self, root.ty, try self.mb.lowerStructTypeById(root_decl_id))) return LowerError.InvalidIdentity;

    const final_step = assign.steps[assign.steps.len - 1];
    const field_ty = try self.structFieldTypeResolved(final_step.struct_decl_id, final_step.struct_name, final_step.field);
    const value = try @TypeOf(self.*).lowerExprForTarget(self, assign.value, field_ty);
    const old_value = try self.emit(.{ .load = root.ptr_value }, root.ty);
    const replacement = try @TypeOf(self.*).prepareCapturedExprValue(self, assign.value, value, field_ty);
    const rebuilt = try @TypeOf(self.*).rebuildStructValueWithFieldPath(self, old_value, root.ty, assign.steps, 0, replacement);
    if (assign.capture) |capture| {
        const old_field = try @TypeOf(self.*).extractStructFieldPathValue(self, old_value, root.ty, assign.steps, 0);
        try self.emitVoid(.{ .store = .{ .ptr = root.ptr_value, .value = rebuilt } });
        const slot = try self.defineLocal(capture.name, field_ty);
        try self.emitVoid(.{ .store = .{ .ptr = slot.ptr_value, .value = old_field } });
        self.markCleanupActive(slot);
    } else if (try @TypeOf(self.*).typeNeedsDrop(self, field_ty)) {
        const old_field = try @TypeOf(self.*).extractStructFieldPathValue(self, old_value, root.ty, assign.steps, 0);
        try @TypeOf(self.*).emitDropValue(self, old_field, field_ty);
        try self.emitVoid(.{ .store = .{
            .ptr = root.ptr_value,
            .value = rebuilt,
        } });
    } else {
        try self.emitVoid(.{ .store = .{
            .ptr = root.ptr_value,
            .value = rebuilt,
        } });
    }
}

pub fn rebuildStructValueWithFieldPath(
    self: anytype,
    base_value: lir.ValueId,
    struct_ty: lir.TypeId,
    steps: []const sir.StructFieldPathStep,
    depth: usize,
    replacement: lir.ValueId,
) LowerError!lir.ValueId {
    const struct_decl = switch (self.mb.types.items[struct_ty]) {
        .@"struct" => |decl| decl,
        else => return error.LowerInvariantViolation,
    };
    const step = steps[depth];
    if (!@TypeOf(self.*).typeIdsEqual(self, struct_ty, try self.mb.lowerStructTypeById(step.struct_decl_id orelse return LowerError.InvalidIdentity))) return LowerError.InvalidIdentity;
    const field_index = try self.structFieldIndexResolved(step.struct_decl_id, step.struct_name, step.field);
    const fields = try self.mb.allocator.alloc(lir.ValueId, struct_decl.fields.len);
    errdefer self.mb.allocator.free(fields);

    for (struct_decl.fields, fields, 0..) |field_decl, *out_field, i| {
        if (i == field_index) {
            if (depth + 1 == steps.len) {
                out_field.* = replacement;
            } else {
                const old_nested = try self.emit(.{ .extract_field = .{
                    .value = base_value,
                    .field_index = @intCast(i),
                } }, field_decl.ty);
                out_field.* = try @TypeOf(self.*).rebuildStructValueWithFieldPath(self, old_nested, field_decl.ty, steps, depth + 1, replacement);
            }
        } else {
            out_field.* = try self.emit(.{ .extract_field = .{
                .value = base_value,
                .field_index = @intCast(i),
            } }, field_decl.ty);
        }
    }

    return self.emit(.{ .make_struct = .{ .fields = fields } }, struct_ty);
}

pub fn extractStructFieldPathValue(
    self: anytype,
    base_value: lir.ValueId,
    struct_ty: lir.TypeId,
    steps: []const sir.StructFieldPathStep,
    depth: usize,
) LowerError!lir.ValueId {
    const struct_decl = switch (self.mb.types.items[struct_ty]) {
        .@"struct" => |decl| decl,
        else => return error.LowerInvariantViolation,
    };
    const step = steps[depth];
    if (!@TypeOf(self.*).typeIdsEqual(self, struct_ty, try self.mb.lowerStructTypeById(step.struct_decl_id orelse return LowerError.InvalidIdentity))) return LowerError.InvalidIdentity;
    const field_index = try self.structFieldIndexResolved(step.struct_decl_id, step.struct_name, step.field);
    const field_ty = struct_decl.fields[field_index].ty;
    const field_value = try self.emit(.{ .extract_field = .{
        .value = base_value,
        .field_index = @intCast(field_index),
    } }, field_ty);
    if (depth + 1 == steps.len) return field_value;
    return @TypeOf(self.*).extractStructFieldPathValue(self, field_value, field_ty, steps, depth + 1);
}

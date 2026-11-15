const std = @import("std");
const common = @import("common.zig");
const lir = @import("../../lower/lir.zig");

pub const Error = common.Error;

pub fn llvmValueType(
    allocator: std.mem.Allocator,
    module: lir.Module,
    info: []const common.ValueInfo,
    value_id: lir.ValueId,
) Error![]u8 {
    const value = info[value_id];
    return switch (value.kind) {
        .pointer => try allocator.dupe(u8, "ptr"),
        .global_desc => try allocator.dupe(u8, "ptr"),
        else => llvmScalarType(allocator, module, value.ty orelse return error.BackendInvariantViolation),
    };
}

pub fn llvmPointeeType(
    allocator: std.mem.Allocator,
    module: lir.Module,
    info: []const common.ValueInfo,
    value_id: lir.ValueId,
) Error![]u8 {
    const value = info[value_id];
    return llvmScalarType(allocator, module, value.pointee orelse return error.BackendInvariantViolation);
}

pub fn llvmScalarType(allocator: std.mem.Allocator, module: lir.Module, ty: lir.TypeId) Error![]u8 {
    return switch (module.types[ty]) {
        .void => allocator.dupe(u8, "void"),
        .bool => allocator.dupe(u8, "i1"),
        .int => |int_ty| std.fmt.allocPrint(allocator, "i{}", .{int_ty.bits}),
        .float => |float_ty| allocator.dupe(u8, if (float_ty.bits == 32) "float" else "double"),
        .string => allocator.dupe(u8, "{ ptr, i64 }"),
        .pointer => allocator.dupe(u8, "ptr"),
        .array => |array_ty| blk: {
            const elem_ty = try llvmScalarType(allocator, module, array_ty.elem);
            defer allocator.free(elem_ty);
            break :blk try std.fmt.allocPrint(allocator, "[{} x {s}]", .{ array_ty.len, elem_ty });
        },
        .slice => allocator.dupe(u8, "{ ptr, i64 }"),
        .dense_array => allocator.dupe(u8, "{ ptr, i64, i64 }"),
        .sparse_array => allocator.dupe(u8, "{ ptr, ptr, i64, i64 }"),
        .optional => try llvmOptionalType(allocator, module, ty),
        .result => try llvmResultType(allocator, module, ty),
        .@"struct" => try llvmStructType(allocator, module, ty),
        .@"union" => try llvmUnionType(allocator, module, ty),
    };
}

pub fn llvmOptionalType(allocator: std.mem.Allocator, module: lir.Module, ty: lir.TypeId) Error![]u8 {
    const payload_ty = try llvmOptionalPayloadType(allocator, module, ty);
    defer allocator.free(payload_ty);
    return std.fmt.allocPrint(allocator, "{{ i8, {s} }}", .{payload_ty});
}

pub fn llvmOptionalPayloadType(allocator: std.mem.Allocator, module: lir.Module, ty: lir.TypeId) Error![]u8 {
    return switch (module.types[ty]) {
        .optional => |payload_ty| llvmScalarType(allocator, module, payload_ty),
        else => error.BackendInvariantViolation,
    };
}

pub fn llvmResultType(allocator: std.mem.Allocator, module: lir.Module, ty: lir.TypeId) Error![]u8 {
    const ok_ty = try llvmResultOkType(allocator, module, ty);
    defer allocator.free(ok_ty);
    const err_ty = try llvmResultErrType(allocator, module, ty);
    defer allocator.free(err_ty);
    return std.fmt.allocPrint(allocator, "{{ i8, {s}, {s}, {{ ptr, i32, i32 }} }}", .{ ok_ty, err_ty });
}

pub fn llvmResultPayloadType(allocator: std.mem.Allocator, module: lir.Module, ty: lir.TypeId) Error![]u8 {
    return llvmResultOkType(allocator, module, ty);
}

pub fn llvmResultOkType(allocator: std.mem.Allocator, module: lir.Module, ty: lir.TypeId) Error![]u8 {
    return switch (module.types[ty]) {
        .result => |result_ty| if (module.types[result_ty.ok] == .void)
            allocator.dupe(u8, "i8")
        else
            llvmScalarType(allocator, module, result_ty.ok),
        else => error.BackendInvariantViolation,
    };
}

pub fn llvmResultErrType(allocator: std.mem.Allocator, module: lir.Module, ty: lir.TypeId) Error![]u8 {
    return switch (module.types[ty]) {
        .result => |result_ty| llvmScalarType(allocator, module, result_ty.err),
        else => error.BackendInvariantViolation,
    };
}

pub fn llvmUnionType(allocator: std.mem.Allocator, module: lir.Module, ty: lir.TypeId) Error![]u8 {
    return switch (module.types[ty]) {
        .@"union" => |union_ty| {
            if (union_ty.payloads.len == 0) {
                return allocator.dupe(u8, "{ i64 }");
            }

            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(allocator);
            var out_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
            const writer = &out_writer.writer;
            try writer.writeAll("{ i64");
            for (union_ty.payloads) |payload_ty| {
                try writer.writeAll(", ");
                if (payload_ty) |slot_ty| {
                    const payload = try llvmScalarType(allocator, module, slot_ty);
                    defer allocator.free(payload);
                    try writer.writeAll(payload);
                } else {
                    try writer.writeAll("i8");
                }
            }
            try writer.writeAll(" }");
            out = out_writer.toArrayList();
            return out.toOwnedSlice(allocator);
        },
        else => error.BackendInvariantViolation,
    };
}

pub fn llvmStructType(allocator: std.mem.Allocator, module: lir.Module, ty: lir.TypeId) Error![]u8 {
    return switch (module.types[ty]) {
        .@"struct" => |struct_ty| {
            if (struct_ty.is_packed) {
                return std.fmt.allocPrint(allocator, "i{}", .{@max(@as(u32, 1), struct_ty.packed_bits)});
            }
            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(allocator);
            var out_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
            const writer = &out_writer.writer;
            try writer.writeAll("{ ");
            for (struct_ty.fields, 0..) |field, i| {
                if (i != 0) try writer.writeAll(", ");
                const field_ty = try llvmScalarType(allocator, module, field.ty);
                defer allocator.free(field_ty);
                try writer.writeAll(field_ty);
            }
            try writer.writeAll(" }");
            out = out_writer.toArrayList();
            return out.toOwnedSlice(allocator);
        },
        else => error.BackendInvariantViolation,
    };
}

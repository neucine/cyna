const std = @import("std");
const lir = @import("lir.zig");
const symbols = @import("../../runtime/symbols.zig");

pub const Error = error{ OutOfMemory, BackendInvariantViolation };

pub fn descriptorGlobalName(allocator: std.mem.Allocator, module: lir.Module, ty: lir.TypeId) Error![]u8 {
    return switch (module.types[ty]) {
        .bool => allocator.dupe(u8, symbols.desc_bool_symbol),
        .int => |int_ty| if (int_ty.bits == 8 and !int_ty.signed)
            allocator.dupe(u8, symbols.desc_u8_symbol)
        else if (int_ty.bits == 32 and int_ty.signed)
            allocator.dupe(u8, symbols.desc_i32_symbol)
        else if (int_ty.bits == 64 and int_ty.signed)
            allocator.dupe(u8, symbols.desc_i64_symbol)
        else
            allocDescriptorName(allocator, module, ty, symbols.descriptor_global_prefix),
        .string => allocator.dupe(u8, symbols.desc_string_symbol),
        .float => |float_ty| if (float_ty.bits == 32)
            allocator.dupe(u8, symbols.desc_f32_symbol)
        else
            allocator.dupe(u8, symbols.desc_f64_symbol),
        .dense_array => allocDescriptorName(allocator, module, ty, symbols.descriptor_global_prefix),
        .sparse_array => allocDescriptorName(allocator, module, ty, symbols.descriptor_global_prefix),
        .@"struct" => allocDescriptorName(allocator, module, ty, symbols.descriptor_global_prefix),
        .pointer, .array, .slice, .optional, .result, .@"union" => allocDescriptorName(allocator, module, ty, symbols.descriptor_global_prefix),
        else => error.BackendInvariantViolation,
    };
}

pub fn descriptorCopyName(allocator: std.mem.Allocator, module: lir.Module, ty: lir.TypeId) Error![]u8 {
    return allocDescriptorName(allocator, module, ty, symbols.descriptor_copy_prefix);
}

pub fn descriptorDropName(allocator: std.mem.Allocator, module: lir.Module, ty: lir.TypeId) Error![]u8 {
    return allocDescriptorName(allocator, module, ty, symbols.descriptor_drop_prefix);
}

pub fn descriptorNeedsGeneration(module: lir.Module, ty: lir.TypeId) bool {
    return switch (module.types[ty]) {
        .int => |int_ty| !((int_ty.bits == 8 and !int_ty.signed) or
            (int_ty.bits == 32 and int_ty.signed) or
            (int_ty.bits == 64 and int_ty.signed)),
        .float => false,
        .dense_array => true,
        .sparse_array => true,
        .@"struct" => true,
        .pointer, .array, .slice, .optional, .result, .@"union" => true,
        else => false,
    };
}

pub fn descriptorHelperNeedsGeneration(module: lir.Module, ty: lir.TypeId) bool {
    if (descriptorNeedsGeneration(module, ty)) return true;
    return switch (module.types[ty]) {
        .dense_array, .sparse_array => true,
        .bool, .int, .string, .@"struct" => false,
        .float, .pointer, .array, .slice, .optional, .result, .@"union", .void => false,
    };
}

fn allocDescriptorName(
    allocator: std.mem.Allocator,
    module: lir.Module,
    ty: lir.TypeId,
    prefix: []const u8,
) Error![]u8 {
    var key = std.ArrayListUnmanaged(u8).empty;
    defer key.deinit(allocator);
    try appendDescriptorTypeKey(allocator, &key, module, ty);
    const hash = std.hash.Wyhash.hash(0, key.items);
    return std.fmt.allocPrint(allocator, "{s}{x}", .{ prefix, hash });
}

fn appendDescriptorTypeKey(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    module: lir.Module,
    ty: lir.TypeId,
) Error!void {
    switch (module.types[ty]) {
        .void => try out.appendSlice(allocator, "void"),
        .bool => try out.appendSlice(allocator, "bool"),
        .int => |int_ty| {
            const text = try std.fmt.allocPrint(allocator, "i{}_{}", .{ int_ty.bits, @intFromBool(int_ty.signed) });
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .float => |float_ty| {
            const text = try std.fmt.allocPrint(allocator, "f{}", .{float_ty.bits});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .string => try out.appendSlice(allocator, "string"),
        .pointer => |pointee| {
            try out.appendSlice(allocator, "ptr(");
            try appendDescriptorTypeKey(allocator, out, module, pointee);
            try out.append(allocator, ')');
        },
        .array => |array_ty| {
            const text = try std.fmt.allocPrint(allocator, "arr{}(", .{array_ty.len});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
            try appendDescriptorTypeKey(allocator, out, module, array_ty.elem);
            try out.append(allocator, ')');
        },
        .slice => |item_ty| {
            try out.appendSlice(allocator, "slice(");
            try appendDescriptorTypeKey(allocator, out, module, item_ty);
            try out.append(allocator, ')');
        },
        .dense_array => |item_ty| {
            try out.appendSlice(allocator, "rarr(");
            try appendDescriptorTypeKey(allocator, out, module, item_ty);
            try out.append(allocator, ')');
        },
        .sparse_array => |item_ty| {
            try out.appendSlice(allocator, "sparse(");
            try appendDescriptorTypeKey(allocator, out, module, item_ty);
            try out.append(allocator, ')');
        },
        .optional => |payload_ty| {
            try out.appendSlice(allocator, "opt(");
            try appendDescriptorTypeKey(allocator, out, module, payload_ty);
            try out.append(allocator, ')');
        },
        .result => |result_ty| {
            try out.appendSlice(allocator, "res(");
            try appendDescriptorTypeKey(allocator, out, module, result_ty.ok);
            try out.append(allocator, ',');
            try appendDescriptorTypeKey(allocator, out, module, result_ty.err);
            try out.append(allocator, ')');
        },
        .@"struct" => |struct_ty| {
            // Display names are not nominal identities: private records in different
            // modules may have the same name and entirely different ownership/layout.
            const text = if (struct_ty.qualified_name) |name|
                try std.fmt.allocPrint(allocator, "struct.nominal({d}:{s})", .{ name.len, name })
            else
                try std.fmt.allocPrint(allocator, "struct({s})", .{struct_ty.name});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .@"union" => |union_ty| {
            const text = if (union_ty.qualified_name) |name|
                try std.fmt.allocPrint(allocator, "union.nominal({d}:{s})", .{ name.len, name })
            else
                try std.fmt.allocPrint(allocator, "union({s})", .{union_ty.name});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
    }
}

const std = @import("std");
const common = @import("common.zig");
const types = @import("types.zig");
const llvm_support = @import("support.zig");
const lir = @import("../../lower/lir.zig");

pub const Error = common.Error;

pub fn emitGlobals(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    string_literals: []const llvm_support.StringLiteral,
) Error!void {
    for (module.globals) |global| {
        const storage_ty = blk: {
            if (global.is_symbol_addr) {
                const pointee_ty = switch (module.types[global.ty]) {
                    .pointer => |pointee| pointee,
                    else => return error.BackendInvariantViolation,
                };
                break :blk try types.llvmScalarType(allocator, module, pointee_ty);
            }
            break :blk try types.llvmScalarType(allocator, module, global.ty);
        };
        defer allocator.free(storage_ty);
        const symbol_name = global.abi_name orelse global.name;
        if (global.is_extern) {
            try writer.print("@{s} = external global {s}\n", .{ symbol_name, storage_ty });
            continue;
        }
        try writer.print("@{s} = {s} {s} ", .{
            symbol_name,
            if (global.is_mutable) "global" else "constant",
            storage_ty,
        });
        try emitGlobalInit(allocator, writer, module, string_literals, global.ty, global.init orelse return error.BackendInvariantViolation);
        try writer.writeByte('\n');
    }
}

fn emitGlobalInit(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    string_literals: []const llvm_support.StringLiteral,
    ty: lir.TypeId,
    init: lir.GlobalInit,
) Error!void {
    switch (module.types[ty]) {
        .string => switch (init) {
            .string => |value| {
                const name = llvm_support.findStringLiteralName(string_literals, value) orelse return error.BackendInvariantViolation;
                try writer.print("{{ ptr getelementptr inbounds ([{d} x i8], ptr @{s}, i64 0, i64 0), i64 {} }}", .{ value.len + 1, name, value.len });
            },
            else => return error.BackendInvariantViolation,
        },
        .int => switch (init) {
            .int => |value| try writer.print("{}", .{value}),
            .enum_value => |value| try writer.print("{}", .{value}),
            else => return error.BackendInvariantViolation,
        },
        .float => switch (init) {
            .float => |value| {
                const literal = try std.fmt.allocPrint(allocator, "{d}", .{value});
                defer allocator.free(literal);
                try writer.writeAll(literal);
                if (std.mem.indexOfAny(u8, literal, ".eE") == null) try writer.writeAll(".0");
            },
            else => return error.BackendInvariantViolation,
        },
        .bool => switch (init) {
            .bool => |value| try writer.writeAll(if (value) "true" else "false"),
            else => return error.BackendInvariantViolation,
        },
        .pointer => switch (init) {
            .symbol_addr => |name| try common.writeAtName(writer, name),
            else => return error.BackendInvariantViolation,
        },
        .optional => |payload_ty| switch (init) {
            .none => try writer.writeAll("zeroinitializer"),
            .some => |value| {
                const payload_scalar_ty = try types.llvmScalarType(allocator, module, payload_ty);
                defer allocator.free(payload_scalar_ty);
                try writer.print("{{ i8 1, {s} ", .{payload_scalar_ty});
                try emitGlobalInit(allocator, writer, module, string_literals, payload_ty, value.*);
                try writer.writeAll(" }");
            },
            else => return error.BackendInvariantViolation,
        },
        .array => |array_ty| switch (init) {
            .array => |items| {
                try writer.writeByte('[');
                for (items, 0..) |item, i| {
                    if (i != 0) try writer.writeAll(", ");
                    const item_ty = try types.llvmScalarType(allocator, module, array_ty.elem);
                    defer allocator.free(item_ty);
                    try writer.print("{s} ", .{item_ty});
                    try emitGlobalInit(allocator, writer, module, string_literals, array_ty.elem, item);
                }
                try writer.writeByte(']');
            },
            else => return error.BackendInvariantViolation,
        },
        .@"struct" => |struct_ty| switch (init) {
            .@"struct" => |fields| {
                try writer.writeAll("{ ");
                for (fields, struct_ty.fields, 0..) |field, struct_field, i| {
                    if (i != 0) try writer.writeAll(", ");
                    const field_ty = try types.llvmScalarType(allocator, module, struct_field.ty);
                    defer allocator.free(field_ty);
                    try writer.print("{s} ", .{field_ty});
                    try emitGlobalInit(allocator, writer, module, string_literals, struct_field.ty, field);
                }
                try writer.writeAll(" }");
            },
            else => return error.BackendInvariantViolation,
        },
        .@"union" => |union_ty| switch (init) {
            .@"union" => |value| {
                try writer.writeAll("{ ");
                try writer.print("i64 {}", .{value.tag});
                for (union_ty.payloads, 0..) |payload_ty, i| {
                    try writer.writeAll(", ");
                    if (payload_ty) |slot_ty| {
                        const payload_scalar_ty = try types.llvmScalarType(allocator, module, slot_ty);
                        defer allocator.free(payload_scalar_ty);
                        try writer.print("{s} ", .{payload_scalar_ty});
                        if (i == value.tag) {
                            if (value.payload) |payload| {
                                try emitGlobalInit(allocator, writer, module, string_literals, slot_ty, payload.*);
                            } else {
                                try writer.writeAll("zeroinitializer");
                            }
                        } else {
                            try writer.writeAll("zeroinitializer");
                        }
                    } else {
                        try writer.writeAll("i8 ");
                        if (i == value.tag) {
                            try writer.writeAll("0");
                        } else {
                            try writer.writeAll("0");
                        }
                    }
                }
                try writer.writeAll(" }");
            },
            else => return error.BackendInvariantViolation,
        },
        else => return error.BackendInvariantViolation,
    }
}

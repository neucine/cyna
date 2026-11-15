const std = @import("std");
const capability = @import("../../capability.zig");
const internal_error = @import("../../internal_error.zig");
const lir = @import("../../lower/lir.zig");
const backend_support = @import("../support.zig");

pub const Error = error{
    WriteFailed,
} || capability.Error || internal_error.Error || std.mem.Allocator.Error;

pub fn writeAtName(writer: anytype, name: []const u8) !void {
    if (isSimpleLlvmName(name)) {
        try writer.writeByte('@');
        try writer.writeAll(name);
        return;
    }
    try writer.writeAll("@\"");
    for (name) |ch| switch (ch) {
        '\\' => try writer.writeAll("\\5C"),
        '"' => try writer.writeAll("\\22"),
        else => try writer.writeByte(ch),
    };
    try writer.writeByte('"');
}

fn isSimpleLlvmName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if ((ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '_' or
            ch == '$' or
            ch == '.' or
            ch == '-')
        {
            continue;
        }
        return false;
    }
    return true;
}

pub const ValueKind = enum {
    none,
    immediate_int,
    immediate_float,
    immediate_bool,
    param,
    register,
    pointer,
    global_ptr,
    global_desc,
};

pub const ValueInfo = struct {
    kind: ValueKind = .none,
    ty: ?lir.TypeId = null,
    pointee: ?lir.TypeId = null,
    int_value: i64 = 0,
    float_value: f64 = 0.0,
    bool_value: bool = false,
    param_index: u32 = 0,
    global_name: ?[]const u8 = null,
    desc_ty: ?lir.TypeId = null,
    desc_name: ?[]u8 = null,
};

pub fn buildValueInfo(allocator: std.mem.Allocator, module: lir.Module, function: lir.Function) Error![]ValueInfo {
    var max_id: usize = 0;
    var found_any = false;
    for (function.blocks) |block| {
        for (block.instructions) |inst| {
            if (inst.id) |id| {
                found_any = true;
                max_id = @max(max_id, id);
            }
        }
    }

    const len = if (found_any) max_id + 1 else 0;
    const info = try allocator.alloc(ValueInfo, len);
    @memset(info, .{});

    for (function.blocks) |block| {
        for (block.instructions) |inst| {
            const id = inst.id orelse continue;
            const slot = &info[id];
            switch (inst.data) {
                .const_int => |value| slot.* = .{
                    .kind = .immediate_int,
                    .ty = inst.ty,
                    .int_value = value,
                },
                .const_float => |value| slot.* = .{
                    .kind = .immediate_float,
                    .ty = inst.ty,
                    .float_value = value,
                },
                .const_bool => |value| slot.* = .{
                    .kind = .immediate_bool,
                    .ty = inst.ty,
                    .bool_value = value,
                },
                .const_string, .const_c_str => slot.* = .{
                    .kind = .register,
                    .ty = inst.ty,
                },
                .param_ref => |index| slot.* = .{
                    .kind = .param,
                    .ty = inst.ty,
                    .param_index = index,
                },
                .type_desc => |desc_ty| slot.* = .{
                    .kind = .global_desc,
                    .desc_ty = desc_ty,
                    .desc_name = try backend_support.descriptorGlobalName(allocator, module, desc_ty),
                },
                .global_addr => |name| {
                    const pointer_ty = inst.ty orelse return error.BackendInvariantViolation;
                    const pointee = switch (module.types[pointer_ty]) {
                        .pointer => |child| child,
                        else => return error.BackendInvariantViolation,
                    };
                    slot.* = .{
                        .kind = .global_ptr,
                        .ty = pointer_ty,
                        .pointee = pointee,
                        .global_name = try allocator.dupe(u8, name),
                    };
                },
                .stack_alloc => |pointee| slot.* = .{
                    .kind = .pointer,
                    .ty = inst.ty,
                    .pointee = pointee,
                },
                .field_ptr => |field_ptr| {
                    _ = field_ptr;
                    const pointer_ty = inst.ty orelse return error.BackendInvariantViolation;
                    const pointee = switch (module.types[pointer_ty]) {
                        .pointer => |child| child,
                        else => return error.BackendInvariantViolation,
                    };
                    slot.* = .{
                        .kind = .pointer,
                        .ty = pointer_ty,
                        .pointee = pointee,
                    };
                },
                .index_ptr => |index_ptr| {
                    _ = index_ptr;
                    const pointer_ty = inst.ty orelse return error.BackendInvariantViolation;
                    const pointee = switch (module.types[pointer_ty]) {
                        .pointer => |child| child,
                        else => return error.BackendInvariantViolation,
                    };
                    slot.* = .{
                        .kind = .pointer,
                        .ty = pointer_ty,
                        .pointee = pointee,
                    };
                },
                .extract_slice_ptr => |slice_ptr| {
                    _ = slice_ptr;
                    const pointer_ty = inst.ty orelse return error.BackendInvariantViolation;
                    const pointee = switch (module.types[pointer_ty]) {
                        .pointer => |child| child,
                        else => return error.BackendInvariantViolation,
                    };
                    slot.* = .{
                        .kind = .pointer,
                        .ty = pointer_ty,
                        .pointee = pointee,
                    };
                },
                else => {
                    if (inst.ty) |ty| switch (module.types[ty]) {
                        .pointer => |child| {
                            slot.* = .{
                                .kind = .pointer,
                                .ty = ty,
                                .pointee = child,
                            };
                            continue;
                        },
                        else => {},
                    };
                    slot.* = .{
                        .kind = .register,
                        .ty = inst.ty,
                    };
                },
            }
        }
    }

    return info;
}

pub fn deinitValueInfo(allocator: std.mem.Allocator, info: []ValueInfo) void {
    for (info) |value| {
        if (value.desc_name) |name| allocator.free(name);
        if (value.global_name) |name| allocator.free(name);
    }
    allocator.free(info);
}

pub fn writeValueRef(writer: anytype, module: lir.Module, info: []const ValueInfo, value_id: lir.ValueId) !void {
    return switch (info[value_id].kind) {
        .immediate_int => writer.print("{}", .{info[value_id].int_value}),
        .immediate_float => writeFloatLiteral(writer, module.types[info[value_id].ty orelse return error.BackendInvariantViolation], info[value_id].float_value),
        .immediate_bool => writer.writeAll(if (info[value_id].bool_value) "true" else "false"),
        .param => writer.print("%arg{}", .{info[value_id].param_index}),
        .global_ptr => writeAtName(writer, info[value_id].global_name orelse return error.BackendInvariantViolation),
        .global_desc => writeAtName(writer, info[value_id].desc_name orelse return error.BackendInvariantViolation),
        .register, .pointer => writer.print("%v{}", .{value_id}),
        else => error.BackendInvariantViolation,
    };
}

fn writeFloatLiteral(writer: anytype, ty: lir.TypeDecl, value: f64) !void {
    if (ty == .float and ty.float.bits == 32) {
        const narrowed: f32 = @floatCast(value);
        const widened: f64 = narrowed;
        try writer.print("0x{X:0>16}", .{@as(u64, @bitCast(widened))});
        return;
    }
    try writer.print("{e:.17}", .{value});
}

const std = @import("std");
const common = @import("common.zig");
const types = @import("types.zig");
const lir = @import("../../lower/lir.zig");
const target_info = @import("../../target.zig");

pub const Error = common.Error;

pub const SizeAlign = struct {
    size: usize,
    abi_align: usize,
};

pub const CallableBoundaryShape = enum {
    semantic,
    scalar_coercion,
    indirect,
    dense_header_ptr,
    sparse_header_ptr,
};

// This file defines the compiler-owned LLVM-facing callable-boundary protocol:
// how a semantic Cyna type crosses a callable boundary, when the lowering uses
// a privileged compiler-runtime carrier shape, and when trusted internal
// modules must bridge between semantic carriers and that representation.
pub fn returnType(
    allocator: std.mem.Allocator,
    module: lir.Module,
    function: lir.Function,
    ty: lir.TypeId,
) Error![]u8 {
    if (try needsIndirectReturn(module, function, ty)) {
        return allocator.dupe(u8, "void");
    }
    if (usesCallableBoundary(function)) {
        if (try cLayoutAbiCoercionType(allocator, module, ty)) |coerced| return coerced;
        if (try publicCallableBoundaryType(allocator, module, ty)) |public_ty| return public_ty;
    }
    return types.llvmScalarType(allocator, module, ty);
}

pub fn paramType(
    allocator: std.mem.Allocator,
    module: lir.Module,
    function: lir.Function,
    ty: lir.TypeId,
) Error![]u8 {
    if (try indirectParamInfo(module, function, ty) != null) return allocator.dupe(u8, "ptr");
    if (usesCallableBoundary(function)) {
        if (try cLayoutAbiCoercionType(allocator, module, ty)) |coerced| return coerced;
        if (try publicCallableBoundaryType(allocator, module, ty)) |public_ty| return public_ty;
    }
    return types.llvmScalarType(allocator, module, ty);
}

pub fn usesCallableBoundary(function: lir.Function) bool {
    return function.calling_convention == .c;
}

pub fn isEntryResult(module: lir.Module, function: lir.Function) bool {
    return !function.is_extern and std.mem.eql(u8, function.name, "main") and
        module.types[function.return_type] == .result;
}

// Only error-returning Cyna functions propagate a diagnostic record across
// their call boundary. C and entry signatures keep their existing ABI.
pub fn takesTraceContext(module: lir.Module, function: lir.Function) bool {
    return function.calling_convention == .cyna and
        !function.is_test_entry and !std.mem.eql(u8, function.name, "main") and
        module.types[function.return_type] == .result;
}

pub fn needsLocalTraceContext(module: lir.Module, function: lir.Function) bool {
    if (function.is_extern or takesTraceContext(module, function)) return false;
    if (module.types[function.return_type] == .result) return true;
    for (function.blocks) |block| for (block.instructions) |inst| {
        if (inst.ty) |ty| {
            if (module.types[ty] != .result) continue;
            switch (inst.data) {
                .call, .indirect_call => return true,
                else => {},
            }
        }
    };
    return false;
}

test "trace context ABI borrows internally and owns at invocation boundaries" {
    const module: lir.Module = .{
        .types = &.{
            .{ .int = .{ .bits = 32, .signed = true } },
            .{ .result = .{ .ok = 0, .err = 0 } },
        },
        .globals = &.{},
        .functions = &.{},
    };
    const internal: lir.Function = .{
        .name = "helper",
        .params = &.{},
        .return_type = 1,
        .locals = &.{},
        .ownership_trace = &.{},
        .blocks = &.{},
        .entry = 0,
    };
    try std.testing.expect(takesTraceContext(module, internal));
    try std.testing.expect(!needsLocalTraceContext(module, internal));

    var imported = internal;
    imported.is_extern = true;
    try std.testing.expect(takesTraceContext(module, imported));

    var boundary = internal;
    boundary.name = "main";
    try std.testing.expect(!takesTraceContext(module, boundary));
    try std.testing.expect(needsLocalTraceContext(module, boundary));
    boundary.name = "test_entry";
    boundary.is_test_entry = true;
    try std.testing.expect(!takesTraceContext(module, boundary));
    try std.testing.expect(needsLocalTraceContext(module, boundary));
    boundary.is_test_entry = false;
    boundary.calling_convention = .c;
    boundary.is_export = true;
    try std.testing.expect(!takesTraceContext(module, boundary));
    try std.testing.expect(needsLocalTraceContext(module, boundary));
}

// Callable-boundary shapes are the compiler's canonical interop policy surface.
// Some cases, such as dense/sparse header-pointer bridging, are intentionally
// classified here before every emitter bridge is fully wired up.
pub fn callableBoundaryShape(module: lir.Module, function: lir.Function, ty: lir.TypeId) Error!CallableBoundaryShape {
    if (!usesCallableBoundary(function)) return .semantic;
    if (try indirectParamInfo(module, function, ty) != null) return .indirect;
    if (try needsIndirectReturn(module, function, ty)) return .indirect;
    if (try hasCLayoutScalarCoercion(module, ty)) return .scalar_coercion;
    return switch (module.types[ty]) {
        .dense_array => .dense_header_ptr,
        .sparse_array => .sparse_header_ptr,
        else => .semantic,
    };
}

pub fn isNullablePointer(module: lir.Module, ty: lir.TypeId) bool {
    return module.types[ty] == .optional and module.types[module.types[ty].optional] == .pointer;
}

pub fn publicCallableBoundaryType(
    allocator: std.mem.Allocator,
    module: lir.Module,
    ty: lir.TypeId,
) Error!?[]u8 {
    return switch (module.types[ty]) {
        .dense_array, .sparse_array => try allocator.dupe(u8, "ptr"),
        .optional => |payload_ty| blk: {
            if (isNullablePointer(module, ty)) break :blk try allocator.dupe(u8, "ptr");
            const payload_public = try callableBoundaryTypeOrSemantic(allocator, module, payload_ty);
            defer allocator.free(payload_public);
            break :blk try std.fmt.allocPrint(allocator, "{{ i8, {s} }}", .{payload_public});
        },
        .result => |result_ty| blk: {
            const ok_public = if (module.types[result_ty.ok] == .void)
                try allocator.dupe(u8, "i8")
            else
                try callableBoundaryTypeOrSemantic(allocator, module, result_ty.ok);
            defer allocator.free(ok_public);
            const err_public = try callableBoundaryTypeOrSemantic(allocator, module, result_ty.err);
            defer allocator.free(err_public);
            break :blk try std.fmt.allocPrint(allocator, "{{ i8, {s}, {s} }}", .{ ok_public, err_public });
        },
        else => null,
    };
}

pub fn needsExportValueBridge(function: lir.Function) bool {
    return function.calling_convention == .c and function.is_export;
}

pub fn needsExternImportValueBridge(function: lir.Function) bool {
    // A call to a locally defined export still crosses its C ABI boundary.
    return usesCallableBoundary(function);
}

pub fn needsIndirectReturn(module: lir.Module, function: lir.Function, ty: lir.TypeId) Error!bool {
    const c_boundary = usesCallableBoundary(function);
    if (!module.target_abi.is_aarch64 and !((module.target_abi.is_x86_64_sysv or module.target_abi.is_x86_64_windows) and c_boundary)) return false;
    if (module.target_abi.is_aarch64_darwin and usesCallableBoundary(function) and cStructHomogeneousFloatFields(module, ty) != null) return false;

    if (!isAggregateBoundaryType(module, ty) and !(module.target_abi.is_x86_64_windows and c_boundary and module.types[ty] == .string)) return false;

    const sa = if (usesCallableBoundary(function))
        try cLayoutBoundarySizeAlign(module, ty)
    else
        try typeSizeAlign(module, ty);
    if (module.target_abi.is_x86_64_windows and c_boundary) return windowsAggregateIndirect(sa.size);
    return sa.size > 16;
}

pub fn indirectParamInfo(module: lir.Module, function: lir.Function, ty: lir.TypeId) Error!?SizeAlign {
    const c_boundary = usesCallableBoundary(function);
    if (!module.target_abi.is_aarch64 and !((module.target_abi.is_x86_64_sysv or module.target_abi.is_x86_64_windows) and c_boundary)) return null;
    if (module.target_abi.is_aarch64_darwin and usesCallableBoundary(function) and cStructHomogeneousFloatFields(module, ty) != null) return null;

    if (!isAggregateBoundaryType(module, ty) and !(module.target_abi.is_x86_64_windows and c_boundary and module.types[ty] == .string)) return null;

    const sa = if (usesCallableBoundary(function))
        try cLayoutBoundarySizeAlign(module, ty)
    else
        try typeSizeAlign(module, ty);
    if (module.target_abi.is_x86_64_windows and c_boundary) {
        if (!windowsAggregateIndirect(sa.size)) return null;
    } else if (sa.size <= 16) return null;
    return sa;
}

fn windowsAggregateIndirect(size: usize) bool {
    return size != 1 and size != 2 and size != 4 and size != 8;
}

fn isAggregateBoundaryType(module: lir.Module, ty: lir.TypeId) bool {
    return switch (module.types[ty]) {
        .@"struct", .@"union", .array, .slice, .result, .optional => true,
        else => false,
    };
}

pub fn cLayoutAbiCoercionType(
    allocator: std.mem.Allocator,
    module: lir.Module,
    ty: lir.TypeId,
) Error!?[]u8 {
    if (!module.target_abi.is_aarch64_darwin and !module.target_abi.is_x86_64_sysv) return null;
    if (isNullablePointer(module, ty)) return null;
    if (cStructHomogeneousFloatFields(module, ty)) |float_bits| {
        const fields = module.types[ty].@"struct".fields;
        if (module.target_abi.is_x86_64_sysv) {
            if (float_bits == 32) return switch (fields.len) {
                1 => try allocator.dupe(u8, "float"),
                2 => try allocator.dupe(u8, "<2 x float>"),
                3 => try allocator.dupe(u8, "{ <2 x float>, float }"),
                4 => try allocator.dupe(u8, "{ <2 x float>, <2 x float> }"),
                else => null,
            };
            if (fields.len == 1) return try allocator.dupe(u8, "double");
            if (fields.len == 2) return try allocator.dupe(u8, "{ double, double }");
            return null;
        }
        return try std.fmt.allocPrint(allocator, "[{d} x {s}]", .{ fields.len, if (float_bits == 32) @as([]const u8, "float") else "double" });
    }
    if (isAggregateBoundaryType(module, ty)) {
        const sa = try cLayoutBoundarySizeAlign(module, ty);
        if (sa.size == 0 or sa.size > 16) return null;
        if (module.target_abi.is_x86_64_sysv) {
            if (sa.size <= 8) return try allocator.dupe(u8, "i64");
            return try allocator.dupe(u8, if (sa.size <= 12) "{ i64, i32 }" else "{ i64, i64 }");
        }
        if (sa.size <= 8) return try allocator.dupe(u8, "i64");
        return try allocator.dupe(u8, "[2 x i64]");
    }
    switch (module.types[ty]) {
        .@"struct" => |struct_ty| {
            if (!struct_ty.is_c_layout) return null;
            const sa = try typeSizeAlign(module, ty);
            if (sa.size != 8) return null;
            return try allocator.dupe(u8, "i64");
        },
        else => return null,
    }
}

fn cStructHomogeneousFloatFields(module: lir.Module, ty: lir.TypeId) ?u16 {
    const struct_ty = switch (module.types[ty]) {
        .@"struct" => |value| value,
        else => return null,
    };
    if (!struct_ty.is_c_layout or struct_ty.is_packed or struct_ty.fields.len == 0 or struct_ty.fields.len > 4) return null;
    var bits: ?u16 = null;
    for (struct_ty.fields) |field| {
        const field_bits = switch (module.types[field.ty]) {
            .float => |value| value.bits,
            else => return null,
        };
        if (field_bits != 32 and field_bits != 64) return null;
        if (bits != null and bits.? != field_bits) return null;
        bits = field_bits;
    }
    return bits;
}

fn hasCLayoutScalarCoercion(module: lir.Module, ty: lir.TypeId) Error!bool {
    if (isNullablePointer(module, ty)) return false;
    if (!module.target_abi.is_aarch64_darwin and !module.target_abi.is_x86_64_sysv) return false;
    if (cStructHomogeneousFloatFields(module, ty) != null) return true;
    if (isAggregateBoundaryType(module, ty)) {
        const sa = try cLayoutBoundarySizeAlign(module, ty);
        return sa.size != 0 and sa.size <= 16;
    }
    return switch (module.types[ty]) {
        .@"struct" => |struct_ty| blk: {
            if (!struct_ty.is_c_layout) break :blk false;
            const sa = try typeSizeAlign(module, ty);
            break :blk sa.size == 8;
        },
        else => false,
    };
}

pub fn callableBoundaryTypeOrSemantic(
    allocator: std.mem.Allocator,
    module: lir.Module,
    ty: lir.TypeId,
) Error![]u8 {
    if (try publicCallableBoundaryType(allocator, module, ty)) |public_ty| return public_ty;
    if (module.types[ty] == .bool) return allocator.dupe(u8, "i8");
    return types.llvmScalarType(allocator, module, ty);
}

pub fn typeSizeAlign(module: lir.Module, ty: lir.TypeId) Error!SizeAlign {
    return switch (module.types[ty]) {
        .void => .{ .size = 0, .abi_align = 1 },
        .bool => .{ .size = 1, .abi_align = 1 },
        .int => |int_ty| blk: {
            const bytes = @max(@as(usize, 1), @as(usize, @intCast(int_ty.bits / 8)));
            break :blk .{ .size = bytes, .abi_align = bytes };
        },
        .float => |float_ty| blk: {
            const bytes = @max(@as(usize, 1), @as(usize, @intCast(float_ty.bits / 8)));
            break :blk .{ .size = bytes, .abi_align = bytes };
        },
        .string => .{ .size = 16, .abi_align = 8 },
        .pointer => .{ .size = module.target_abi.ptrSize(), .abi_align = module.target_abi.ptrSize() },
        .dense_array => .{ .size = module.target_abi.ptrSize() + 16, .abi_align = module.target_abi.ptrSize() },
        .sparse_array => .{ .size = (module.target_abi.ptrSize() * 2) + 16, .abi_align = module.target_abi.ptrSize() },
        .array => |array_ty| blk: {
            const elem_sa = try typeSizeAlign(module, array_ty.elem);
            break :blk .{
                .size = elem_sa.size * array_ty.len,
                .abi_align = elem_sa.abi_align,
            };
        },
        .slice => .{ .size = module.target_abi.ptrSize() + 8, .abi_align = module.target_abi.ptrSize() },
        .optional => |payload_ty| blk: {
            const payload_sa = try typeSizeAlign(module, payload_ty);
            const payload_offset = alignUp(@as(usize, 1), payload_sa.abi_align);
            const max_align = @max(@as(usize, 1), payload_sa.abi_align);
            break :blk .{
                .size = alignUp(payload_offset + payload_sa.size, max_align),
                .abi_align = max_align,
            };
        },
        .result => |result_ty| blk: {
            const ok_sa = try typeSizeAlign(module, result_ty.ok);
            const err_sa = try typeSizeAlign(module, result_ty.err);
            const ok_offset = alignUp(@as(usize, 1), ok_sa.abi_align);
            const err_offset = alignUp(ok_offset + ok_sa.size, err_sa.abi_align);
            const handle_align = module.target_abi.ptrSize();
            const handle_offset = alignUp(err_offset + err_sa.size, handle_align);
            const handle_size = handle_align + 8;
            const max_align = @max(handle_align, @max(ok_sa.abi_align, err_sa.abi_align));
            break :blk .{
                .size = alignUp(handle_offset + handle_size, max_align),
                .abi_align = max_align,
            };
        },
        .@"struct" => |struct_ty| blk: {
            if (struct_ty.is_packed) {
                const bytes = @max(@as(usize, 1), @divFloor(@as(usize, struct_ty.packed_bits) + 7, 8));
                break :blk .{ .size = bytes, .abi_align = 1 };
            }
            var offset: usize = 0;
            var max_align: usize = 1;
            for (struct_ty.fields) |field| {
                const field_sa = try typeSizeAlign(module, field.ty);
                offset = alignUp(offset, field_sa.abi_align);
                offset += field_sa.size;
                max_align = @max(max_align, field_sa.abi_align);
            }
            break :blk .{ .size = alignUp(offset, max_align), .abi_align = max_align };
        },
        .@"union" => |union_ty| blk: {
            var offset: usize = 8;
            var max_align: usize = 8;
            for (union_ty.payloads) |payload_ty| {
                const field_sa = if (payload_ty) |field_ty|
                    try typeSizeAlign(module, field_ty)
                else
                    SizeAlign{ .size = 1, .abi_align = 1 };
                offset = alignUp(offset, field_sa.abi_align);
                offset += field_sa.size;
                max_align = @max(max_align, field_sa.abi_align);
            }
            break :blk .{ .size = alignUp(offset, max_align), .abi_align = max_align };
        },
    };
}

fn cLayoutBoundarySizeAlign(module: lir.Module, ty: lir.TypeId) Error!SizeAlign {
    return switch (module.types[ty]) {
        .dense_array, .sparse_array => .{ .size = module.target_abi.ptrSize(), .abi_align = module.target_abi.ptrSize() },
        .optional => |payload_ty| blk: {
            if (isNullablePointer(module, ty)) break :blk .{ .size = module.target_abi.ptrSize(), .abi_align = module.target_abi.ptrSize() };
            const payload_sa = try cLayoutBoundarySizeAlign(module, payload_ty);
            const payload_offset = alignUp(@as(usize, 1), payload_sa.abi_align);
            const max_align = @max(@as(usize, 1), payload_sa.abi_align);
            break :blk .{
                .size = alignUp(payload_offset + payload_sa.size, max_align),
                .abi_align = max_align,
            };
        },
        .result => |result_ty| blk: {
            const ok_sa = if (module.types[result_ty.ok] == .void)
                SizeAlign{ .size = 1, .abi_align = 1 }
            else
                try cLayoutBoundarySizeAlign(module, result_ty.ok);
            const err_sa = try cLayoutBoundarySizeAlign(module, result_ty.err);
            const ok_offset = alignUp(@as(usize, 1), ok_sa.abi_align);
            const err_offset = alignUp(ok_offset + ok_sa.size, err_sa.abi_align);
            const max_align = @max(@as(usize, 1), @max(ok_sa.abi_align, err_sa.abi_align));
            break :blk .{
                .size = alignUp(err_offset + err_sa.size, max_align),
                .abi_align = max_align,
            };
        },
        else => typeSizeAlign(module, ty),
    };
}

fn alignUp(value: usize, alignment: usize) usize {
    const mask = alignment - 1;
    return (value + mask) & ~mask;
}

test "callableBoundaryShape keeps dense and sparse storage on explicit header-pointer policy" {
    const module = lir.Module{
        .types = &.{
            .{ .int = .{ .bits = 8, .signed = false } },
            .{ .dense_array = 0 },
            .{ .sparse_array = 0 },
        },
        .globals = &.{},
        .functions = &.{},
    };
    const extern_fn = lir.Function{
        .name = "interop",
        .is_extern = true,
        .calling_convention = .c,
        .params = &.{},
        .return_type = 0,
        .locals = &.{},
        .ownership_trace = &.{},
        .blocks = &.{},
        .entry = 0,
    };
    const local_fn = lir.Function{
        .name = "local",
        .params = &.{},
        .return_type = 0,
        .locals = &.{},
        .ownership_trace = &.{},
        .blocks = &.{},
        .entry = 0,
    };

    try std.testing.expectEqual(CallableBoundaryShape.dense_header_ptr, try callableBoundaryShape(module, extern_fn, 1));
    try std.testing.expectEqual(CallableBoundaryShape.sparse_header_ptr, try callableBoundaryShape(module, extern_fn, 2));
    try std.testing.expectEqual(CallableBoundaryShape.semantic, try callableBoundaryShape(module, local_fn, 1));
}

test "callableBoundaryShape keeps ordinary scalars semantic when no special callable-boundary rule applies" {
    const module = lir.Module{
        .types = &.{
            .bool,
            .{ .int = .{ .bits = 64, .signed = true } },
            .string,
        },
        .globals = &.{},
        .functions = &.{},
    };
    const extern_fn = lir.Function{
        .name = "interop",
        .is_extern = true,
        .calling_convention = .c,
        .params = &.{},
        .return_type = 0,
        .locals = &.{},
        .ownership_trace = &.{},
        .blocks = &.{},
        .entry = 0,
    };

    try std.testing.expectEqual(CallableBoundaryShape.semantic, try callableBoundaryShape(module, extern_fn, 0));
    try std.testing.expectEqual(CallableBoundaryShape.semantic, try callableBoundaryShape(module, extern_fn, 1));
    try std.testing.expectEqual(CallableBoundaryShape.semantic, try callableBoundaryShape(module, extern_fn, 2));
}

test "publicCallableBoundaryType maps dense and sparse storage to header-pointer ABI" {
    const module = lir.Module{
        .types = &.{
            .{ .int = .{ .bits = 8, .signed = false } },
            .{ .dense_array = 0 },
            .{ .sparse_array = 0 },
        },
        .globals = &.{},
        .functions = &.{},
    };

    const dense_ty = (try publicCallableBoundaryType(std.testing.allocator, module, 1)).?;
    defer std.testing.allocator.free(dense_ty);
    try std.testing.expectEqualStrings("ptr", dense_ty);

    const sparse_ty = (try publicCallableBoundaryType(std.testing.allocator, module, 2)).?;
    defer std.testing.allocator.free(sparse_ty);
    try std.testing.expectEqualStrings("ptr", sparse_ty);
}

test "target ABI layout controls pointer-sized boundary storage" {
    const module = lir.Module{
        .types = &.{
            .{ .int = .{ .bits = 8, .signed = false } },
            .{ .pointer = 0 },
            .{ .dense_array = 0 },
            .{ .sparse_array = 0 },
        },
        .globals = &.{},
        .functions = &.{},
        .target_abi = target_info.abiLayout("riscv32-none-elf"),
    };

    try std.testing.expectEqual(SizeAlign{ .size = 4, .abi_align = 4 }, try typeSizeAlign(module, 1));
    try std.testing.expectEqual(SizeAlign{ .size = 20, .abi_align = 4 }, try typeSizeAlign(module, 2));
    try std.testing.expectEqual(SizeAlign{ .size = 24, .abi_align = 4 }, try typeSizeAlign(module, 3));
    try std.testing.expectEqual(SizeAlign{ .size = 4, .abi_align = 4 }, try cLayoutBoundarySizeAlign(module, 2));
}

test "result with tagged enum union has stable host and wasm32 layout" {
    const type_nodes: []const lir.TypeDecl = &.{
        .{ .int = .{ .bits = 32, .signed = true } },
        .{ .int = .{ .bits = 64, .signed = true } },
        .{ .@"union" = .{ .name = "Errors", .payloads = &.{ 1, 1 } } },
        .{ .result = .{ .ok = 0, .err = 2 } },
        .{ .pointer = 0 },
        .{ .result = .{ .ok = 4, .err = 2 } },
    };
    for ([_]?[]const u8{ null, "wasm32-wasi" }) |target| {
        const module = lir.Module{
            .types = type_nodes,
            .globals = &.{},
            .functions = &.{},
            .target_abi = target_info.abiLayout(target),
        };
        try std.testing.expectEqual(SizeAlign{ .size = 24, .abi_align = 8 }, try typeSizeAlign(module, 2));
        try std.testing.expectEqual(SizeAlign{ .size = 48, .abi_align = 8 }, try typeSizeAlign(module, 3));
        try std.testing.expectEqual(SizeAlign{ .size = if (target == null) 56 else 48, .abi_align = 8 }, try typeSizeAlign(module, 5));
        const llvm_ty = try types.llvmResultType(std.testing.allocator, module, 3);
        defer std.testing.allocator.free(llvm_ty);
        try std.testing.expectEqualStrings("{ i8, i32, { i64, i64, i64 }, { ptr, i32, i32 } }", llvm_ty);
    }
}

test "publicCallableBoundaryType recurses through result and optional wrappers" {
    const module = lir.Module{
        .types = &.{
            .{ .int = .{ .bits = 8, .signed = false } },
            .{ .int = .{ .bits = 32, .signed = true } },
            .{ .dense_array = 0 },
            .{ .optional = 2 },
            .{ .result = .{ .ok = 2, .err = 1 } },
        },
        .globals = &.{},
        .functions = &.{},
    };

    const optional_ty = (try publicCallableBoundaryType(std.testing.allocator, module, 3)).?;
    defer std.testing.allocator.free(optional_ty);
    try std.testing.expectEqualStrings("{ i8, ptr }", optional_ty);

    const result_ty = (try publicCallableBoundaryType(std.testing.allocator, module, 4)).?;
    defer std.testing.allocator.free(result_ty);
    try std.testing.expectEqualStrings("{ i8, ptr, i32 }", result_ty);
}

test "publicCallableBoundaryType uses i8 placeholder for void result ok payload" {
    const module = lir.Module{
        .types = &.{
            .void,
            .{ .int = .{ .bits = 32, .signed = true } },
            .{ .result = .{ .ok = 0, .err = 1 } },
        },
        .globals = &.{},
        .functions = &.{},
    };

    const result_ty = (try publicCallableBoundaryType(std.testing.allocator, module, 2)).?;
    defer std.testing.allocator.free(result_ty);
    try std.testing.expectEqualStrings("{ i8, i8, i32 }", result_ty);
}

test "public callable boundary widens nested bool payloads to bytes" {
    const module = lir.Module{
        .types = &.{
            .bool,
            .{ .int = .{ .bits = 32, .signed = true } },
            .{ .optional = 0 },
            .{ .result = .{ .ok = 0, .err = 1 } },
        },
        .globals = &.{},
        .functions = &.{},
    };

    const optional_ty = (try publicCallableBoundaryType(std.testing.allocator, module, 2)).?;
    defer std.testing.allocator.free(optional_ty);
    try std.testing.expectEqualStrings("{ i8, i8 }", optional_ty);

    const result_ty = (try publicCallableBoundaryType(std.testing.allocator, module, 3)).?;
    defer std.testing.allocator.free(result_ty);
    try std.testing.expectEqualStrings("{ i8, i8, i32 }", result_ty);
}

test "returnType and paramType use normalized public callable-boundary dense ABI" {
    const module = lir.Module{
        .types = &.{
            .{ .int = .{ .bits = 8, .signed = false } },
            .{ .int = .{ .bits = 32, .signed = true } },
            .{ .dense_array = 0 },
            .{ .result = .{ .ok = 2, .err = 1 } },
        },
        .globals = &.{},
        .functions = &.{},
    };
    const extern_fn = lir.Function{
        .name = "interop",
        .is_extern = true,
        .calling_convention = .c,
        .params = &.{},
        .return_type = 0,
        .locals = &.{},
        .ownership_trace = &.{},
        .blocks = &.{},
        .entry = 0,
    };
    const local_fn = lir.Function{
        .name = "local",
        .params = &.{},
        .return_type = 0,
        .locals = &.{},
        .ownership_trace = &.{},
        .blocks = &.{},
        .entry = 0,
    };

    const extern_dense_param = try paramType(std.testing.allocator, module, extern_fn, 2);
    defer std.testing.allocator.free(extern_dense_param);
    try std.testing.expectEqualStrings("ptr", extern_dense_param);

    const extern_dense_public = (try publicCallableBoundaryType(std.testing.allocator, module, 3)).?;
    defer std.testing.allocator.free(extern_dense_public);
    try std.testing.expectEqualStrings("{ i8, ptr, i32 }", extern_dense_public);

    const extern_dense_result = try returnType(std.testing.allocator, module, extern_fn, 3);
    defer std.testing.allocator.free(extern_dense_result);
    if (module.target_abi.is_aarch64_darwin or module.target_abi.is_x86_64_sysv) {
        try std.testing.expectEqualStrings("void", extern_dense_result);
    } else {
        try std.testing.expectEqualStrings("{ i8, ptr, i32 }", extern_dense_result);
    }

    const local_dense_param = try paramType(std.testing.allocator, module, local_fn, 2);
    defer std.testing.allocator.free(local_dense_param);
    try std.testing.expectEqualStrings("{ ptr, i64, i64 }", local_dense_param);
}

test "target ABI layout controls indirect C aggregate returns" {
    for ([_][]const u8{ "aarch64-apple-darwin", "x86_64-unknown-linux-gnu" }) |target| {
        const module = lir.Module{
            .types = &.{
                .{ .int = .{ .bits = 64, .signed = true } },
                .{ .@"struct" = .{
                    .name = "Large",
                    .is_c_layout = true,
                    .is_packed = false,
                    .is_shared_value = false,
                    .packed_bits = 0,
                    .fields = &.{
                        .{ .name = "a", .ty = 0 },
                        .{ .name = "b", .ty = 0 },
                        .{ .name = "c", .ty = 0 },
                    },
                } },
            },
            .globals = &.{},
            .functions = &.{},
            .target_abi = target_info.abiLayout(target),
        };
        const extern_fn = lir.Function{
            .name = "interop",
            .is_extern = true,
            .calling_convention = .c,
            .params = &.{},
            .return_type = 1,
            .locals = &.{},
            .ownership_trace = &.{},
            .blocks = &.{},
            .entry = 0,
        };

        try std.testing.expect(try needsIndirectReturn(module, extern_fn, 1));
        const ret_ty = try returnType(std.testing.allocator, module, extern_fn, 1);
        defer std.testing.allocator.free(ret_ty);
        try std.testing.expectEqualStrings("void", ret_ty);
    }
}

test "Windows x64 C calls pass strings indirectly and return results through sret" {
    const module = lir.Module{
        .types = &.{
            .string,
            .{ .int = .{ .bits = 32, .signed = true } },
            .{ .result = .{ .ok = 0, .err = 1 } },
        },
        .globals = &.{},
        .functions = &.{},
        .target_abi = target_info.abiLayout("x86_64-pc-windows-gnu"),
    };
    const function = lir.Function{
        .name = "read_file",
        .is_extern = true,
        .calling_convention = .c,
        .params = &.{},
        .return_type = 2,
        .locals = &.{},
        .ownership_trace = &.{},
        .blocks = &.{},
        .entry = 0,
    };
    try std.testing.expectEqual(@as(usize, 16), (try indirectParamInfo(module, function, 0)).?.size);
    try std.testing.expect(try needsIndirectReturn(module, function, 2));
    const parameter = try paramType(std.testing.allocator, module, function, 0);
    defer std.testing.allocator.free(parameter);
    try std.testing.expectEqualStrings("ptr", parameter);
    const result = try returnType(std.testing.allocator, module, function, 2);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("void", result);
}

test "nullable C pointer boundaries use one pointer without changing semantic layout" {
    for ([_][]const u8{ "aarch64-apple-darwin", "x86_64-none-elf", "riscv32-none-elf" }) |target| {
        const module = lir.Module{
            .types = &.{ .{ .int = .{ .bits = 8, .signed = false } }, .{ .pointer = 0 }, .{ .optional = 1 } },
            .globals = &.{},
            .functions = &.{},
            .target_abi = target_info.abiLayout(target),
        };
        var function = lir.Function{ .name = "nullable", .calling_convention = .c, .is_extern = true, .params = &.{}, .return_type = 2, .locals = &.{}, .ownership_trace = &.{}, .blocks = &.{}, .entry = 0 };
        const allocator = std.testing.allocator;
        const returned = try returnType(allocator, module, function, 2);
        defer allocator.free(returned);
        const param = try paramType(allocator, module, function, 2);
        defer allocator.free(param);
        try std.testing.expectEqual(CallableBoundaryShape.semantic, try callableBoundaryShape(module, function, 2));
        try std.testing.expectEqualStrings("ptr", returned);
        try std.testing.expectEqualStrings("ptr", param);
        try std.testing.expect(!try needsIndirectReturn(module, function, 2));
        try std.testing.expect(try indirectParamInfo(module, function, 2) == null);
        try std.testing.expectEqual(module.target_abi.ptrSize(), (try cLayoutBoundarySizeAlign(module, 2)).size);
        try std.testing.expectEqual(2 * module.target_abi.ptrSize(), (try typeSizeAlign(module, 2)).size);
        function.calling_convention = .cyna;
        const internal = try returnType(allocator, module, function, 2);
        defer allocator.free(internal);
        try std.testing.expectEqualStrings("{ i8, ptr }", internal);
    }
}

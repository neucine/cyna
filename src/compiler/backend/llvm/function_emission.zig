const std = @import("std");
const abi = @import("abi.zig");
const common = @import("common.zig");
const instruction_emission = @import("instruction_emission.zig");
const llvm_support = @import("support.zig");
const types = @import("types.zig");
const lir = @import("../../lower/lir.zig");

pub const Error = common.Error;

pub const DebugInfo = struct {
    subprogram_id: u32 = 0,
    location_id: u32 = 0,
};

pub fn emitFunction(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    function: lir.Function,
    string_literals: []const llvm_support.StringLiteral,
    debug: DebugInfo,
) Error!void {
    const return_ty = if (abi.isEntryResult(module, function))
        try allocator.dupe(u8, "i32")
    else
        try abi.returnType(allocator, module, function, function.return_type);
    defer allocator.free(return_ty);

    if (function.is_extern) {
        try writer.print("declare {s} ", .{return_ty});
        try common.writeAtName(writer, function.abi_name orelse function.name);
        try writer.writeByte('(');
    } else {
        try writer.print("define {s} ", .{return_ty});
        try common.writeAtName(writer, function.abi_name orelse function.name);
        try writer.writeByte('(');
    }

    var first_param = true;
    if (!abi.isEntryResult(module, function) and try abi.needsIndirectReturn(module, function, function.return_type)) {
        const indirect_return_ty = if (abi.usesCallableBoundary(function))
            try abi.callableBoundaryTypeOrSemantic(allocator, module, function.return_type)
        else
            try types.llvmScalarType(allocator, module, function.return_type);
        defer allocator.free(indirect_return_ty);
        try writer.print("ptr sret({s}) %retptr", .{indirect_return_ty});
        first_param = false;
    }

    for (function.params, 0..) |param, i| {
        if (!first_param) try writer.writeAll(", ");
        first_param = false;
        const param_ty = try abi.paramType(allocator, module, function, param.ty);
        defer allocator.free(param_ty);
        if (try abi.indirectParamInfo(module, function, param.ty) != null) {
            if (module.target_abi.is_x86_64_sysv and abi.usesCallableBoundary(function)) {
                const byval_ty = try abi.callableBoundaryTypeOrSemantic(allocator, module, param.ty);
                defer allocator.free(byval_ty);
                try writer.print("ptr byval({s}) %abi_arg{}", .{ byval_ty, i });
            } else {
                try writer.print("{s} %abi_arg{}", .{ param_ty, i });
            }
            continue;
        }
        if (abi.needsExportValueBridge(function)) {
            if (try abi.publicCallableBoundaryType(allocator, module, param.ty)) |public_ty| {
                defer allocator.free(public_ty);
                try writer.print("{s} %abi_arg{}", .{ param_ty, i });
                continue;
            }
            switch (try abi.callableBoundaryShape(module, function, param.ty)) {
                .scalar_coercion => {
                    try writer.print("{s} %abi_arg{}", .{ param_ty, i });
                    continue;
                },
                else => {},
            }
        }
        try writer.print("{s} %arg{}", .{ param_ty, i });
    }
    if (abi.takesTraceContext(module, function)) {
        if (!first_param) try writer.writeAll(", ");
        try writer.writeAll("ptr %trace_context");
    }
    try writer.writeByte(')');

    if (debug.subprogram_id != 0 and !function.is_extern) {
        try writer.print(" !dbg !{}", .{debug.subprogram_id});
    }

    if (function.is_extern) {
        try writer.writeByte('\n');
        return;
    }

    try writer.writeAll(" {\n");
    try instruction_emission.emitOwnershipTraceComments(writer, function);

    const info = try common.buildValueInfo(allocator, module, function);
    defer common.deinitValueInfo(allocator, info);
    var next_temp_id: u32 = @intCast(info.len);

    var body_writer = std.Io.Writer.Allocating.init(allocator);
    defer body_writer.deinit();
    const body = &body_writer.writer;
    for (function.blocks, 0..) |block, block_index| {
        try body.print("{s}:\n", .{block.name});
        if (debug.location_id != 0) {
            try body.print("  call void asm sideeffect \"\", \"\"(), !dbg !{}\n", .{debug.location_id});
        }
        if (block_index == function.entry) {
            try instruction_emission.emitFunctionParamAbiSetup(allocator, body, module, function, &next_temp_id);
            if (abi.needsLocalTraceContext(module, function)) {
                try body.writeAll("  %trace_context = call ptr @cyna_trace_new()\n");
            }
        }
        for (block.instructions) |inst| {
            try instruction_emission.emitInstruction(allocator, body, module, function, info, inst, string_literals, &next_temp_id);
        }
        try instruction_emission.emitCatchTraceExits(allocator, body, module, info, block.catch_exits, &next_temp_id);
        try instruction_emission.emitTerminator(allocator, body, module, function, info, block.terminator, &next_temp_id);
    }

    var lines = std.mem.splitScalar(u8, body_writer.written(), '\n');
    var entry_allocations_emitted = false;
    while (lines.next()) |line| {
        if (line.len == 0 or isFixedStackAllocation(line)) continue;
        try writer.print("{s}\n", .{line});
        if (!entry_allocations_emitted and std.mem.eql(u8, line[0 .. line.len - 1], function.blocks[function.entry].name) and line[line.len - 1] == ':') {
            var allocation_lines = std.mem.splitScalar(u8, body_writer.written(), '\n');
            while (allocation_lines.next()) |allocation| {
                if (isFixedStackAllocation(allocation)) try writer.print("{s}\n", .{allocation});
            }
            entry_allocations_emitted = true;
        }
    }
    try writer.writeAll("}\n");
}

fn isFixedStackAllocation(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "  %v")) return false;
    const marker = " = alloca ";
    const offset = std.mem.indexOf(u8, line, marker) orelse return false;
    return std.mem.indexOfScalar(u8, line[offset + marker.len ..], '%') == null;
}

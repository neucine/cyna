const std = @import("std");
const abi = @import("abi.zig");
const common = @import("common.zig");
const backend_support = @import("../support.zig");
const descriptor_emission = @import("descriptor_emission.zig");
const function_emission = @import("function_emission.zig");
const global_emission = @import("global_emission.zig");
const runtime_symbols = @import("../../../runtime/symbols.zig");
const llvm_support = @import("support.zig");
const lir = @import("../../lower/lir.zig");

pub const Error = common.Error || lir.VerifyError;

pub const EmitOptions = struct {
    emit_all_functions: bool = false,
    partitioned: bool = false,
    coff_comdat: bool = false,
};

const allocation_site_file_global = ".cyna.alloc.file";

const DebugMetadata = struct {
    const FileEntry = struct {
        path: []const u8,
        id: u32,
    };

    const FunctionEntry = struct {
        subprogram_id: u32 = 0,
        location_id: u32 = 0,
        file_id: u32 = 0,
        line: u32 = 0,
        column: u32 = 0,
    };

    files: []FileEntry = &.{},
    functions: []FunctionEntry = &.{},
    compile_unit_id: u32 = 0,
    compile_unit_file_id: u32 = 0,
    subroutine_type_id: u32 = 0,
    enabled: bool = false,

    fn deinit(self: DebugMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.files);
        allocator.free(self.functions);
    }
};

pub fn emitModule(allocator: std.mem.Allocator, module: lir.Module) Error![]u8 {
    return emitModuleWithOptions(allocator, module, .{});
}

pub fn emitModuleWithOptions(allocator: std.mem.Allocator, module: lir.Module, options: EmitOptions) Error![]u8 {
    try module.verify(allocator);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var out_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    const writer = &out_writer.writer;
    try writer.writeAll("; ModuleID = 'cyna'\n");

    const reachability = if (options.emit_all_functions)
        try backend_support.allFunctionsReachable(allocator, module)
    else
        try backend_support.analyzeReachability(allocator, module);
    defer reachability.deinit(allocator);

    const debug_metadata = try collectDebugMetadata(allocator, module, reachability);
    defer debug_metadata.deinit(allocator);

    const string_literals = try llvm_support.collectStringLiterals(allocator, module);
    defer {
        for (string_literals) |lit| allocator.free(lit.name);
        allocator.free(string_literals);
    }
    for (string_literals) |lit| {
        const escaped = try llvm_support.escapeBytes(allocator, lit.value);
        defer allocator.free(escaped);
        try writer.print("@{s} = private unnamed_addr constant [{d} x i8] c\"{s}\\00\"\n", .{
            lit.name,
            lit.value.len + 1,
            escaped,
        });
    }
    if (string_literals.len != 0) try writer.writeByte('\n');

    try emitAllocationSiteGlobals(allocator, writer);
    try writer.writeByte('\n');

    try global_emission.emitGlobals(allocator, writer, module, string_literals);
    if (module.globals.len != 0) try writer.writeByte('\n');

    if (backend_support.moduleUsesStringCmp(module, reachability)) {
        try writer.writeAll("declare i1 @");
        try writer.writeAll(runtime_symbols.string_eq_symbol);
        try writer.writeAll("(ptr, i64, ptr, i64)\n\n");
    }

    for (runtime_symbols.primitive_descriptor_symbols) |symbol_name| {
        try writer.print("@{s} = external global {s}\n", .{ symbol_name, runtime_symbols.type_desc_llvm_type });
    }
    try writer.writeByte('\n');

    const desc_seen = try allocator.alloc(bool, module.types.len);
    defer allocator.free(desc_seen);
    @memset(desc_seen, false);
    var emitted_desc_names: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = emitted_desc_names.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        emitted_desc_names.deinit(allocator);
    }
    for (module.functions, 0..) |function, i| {
        if (!reachability.functionIsReachable(i)) continue;
        try descriptor_emission.emitReferencedDescriptorsForFunction(
            allocator,
            writer,
            module,
            function,
            desc_seen,
            &emitted_desc_names,
            options.partitioned,
            options.coff_comdat,
        );
    }

    try emitRuntimeDeclarations(writer, module, reachability);
    if (backend_support.moduleArtifactDepsWithReachability(allocator, module, reachability).any()) {
        try writer.writeByte('\n');
    }
    var emitted_function = false;
    for (module.functions, 0..) |function, i| {
        if (!reachability.functionIsReachable(i)) continue;
        if (emitted_function) try writer.writeByte('\n');
        try function_emission.emitFunction(
            allocator,
            writer,
            module,
            function,
            string_literals,
            .{
                .subprogram_id = debug_metadata.functions[i].subprogram_id,
                .location_id = debug_metadata.functions[i].location_id,
            },
        );
        emitted_function = true;
    }

    if (debug_metadata.enabled) {
        try writer.writeByte('\n');
        try emitDebugMetadata(allocator, writer, module, debug_metadata);
    }

    out = out_writer.toArrayList();
    return out.toOwnedSlice(allocator);
}

fn collectDebugMetadata(allocator: std.mem.Allocator, module: lir.Module, reachability: backend_support.Reachability) Error!DebugMetadata {
    var out: DebugMetadata = .{};
    out.functions = try allocator.alloc(DebugMetadata.FunctionEntry, module.functions.len);
    @memset(out.functions, .{});
    errdefer allocator.free(out.functions);

    var files = std.ArrayListUnmanaged(DebugMetadata.FileEntry).empty;
    defer if (!out.enabled) files.deinit(allocator);

    var next_id: u32 = 4;
    var first_file_id: u32 = 0;
    for (module.functions, 0..) |function, i| {
        if (!reachability.functionIsReachable(i)) continue;
        const path = function.debug_source_path orelse continue;
        // LLVM requires every inlinable call inside a function with debug info
        // to carry a location. Until the emitter attaches locations to all
        // generated calls, keep function-level debug info only for functions
        // whose instruction stream is known not to emit calls.
        if (functionMayEmitCall(function)) continue;
        const line = if (function.debug_line == 0) @as(u32, 1) else function.debug_line;
        const column = if (function.debug_column == 0) @as(u32, 1) else function.debug_column;

        var file_id: ?u32 = null;
        for (files.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                file_id = entry.id;
                break;
            }
        }
        if (file_id == null) {
            file_id = next_id;
            next_id += 1;
            try files.append(allocator, .{ .path = path, .id = file_id.? });
            if (first_file_id == 0) first_file_id = file_id.?;
        }

        out.functions[i] = .{
            .subprogram_id = next_id,
            .location_id = next_id + 1,
            .file_id = file_id.?,
            .line = line,
            .column = column,
        };
        next_id += 2;
        out.enabled = true;
    }

    if (!out.enabled) {
        out.files = &.{};
        return out;
    }

    out.files = try files.toOwnedSlice(allocator);
    out.compile_unit_id = 0;
    out.compile_unit_file_id = first_file_id;
    out.subroutine_type_id = next_id;
    return out;
}

fn functionMayEmitCall(function: lir.Function) bool {
    for (function.blocks) |block| {
        for (block.instructions) |inst| {
            if (instructionMayEmitCall(inst.data)) return true;
        }
    }
    return false;
}

fn instructionMayEmitCall(data: lir.InstData) bool {
    return switch (data) {
        .const_int,
        .const_float,
        .const_bool,
        .param_ref,
        .type_desc,
        .global_addr,
        .const_string,
        .const_c_str,
        .stack_alloc,
        .field_ptr,
        .index_ptr,
        .union_payload_ptr,
        .load,
        .volatile_load,
        .store,
        .volatile_store,
        .int_binop,
        .int_cmp,
        .int_to_int,
        .int_to_ptr,
        .ptr_to_int,
        .bitcast,
        .packed_to_int,
        .int_to_packed,
        .int_to_float,
        .float_to_int,
        .float_to_float,
        .float_binop,
        .float_cmp,
        .string_len,
        .extract_tag,
        .extract_payload,
        .extract_result,
        .extract_field,
        .extract_slice_ptr,
        .extract_slice_len,
        .make_array,
        .make_slice,
        .make_some,
        .make_none,
        .make_struct,
        .make_union,
        .make_result,
        => false,
        else => true,
    };
}

fn emitDebugMetadata(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    debug: DebugMetadata,
) Error!void {
    try writer.writeAll("!llvm.dbg.cu = !{!0}\n");
    try writer.writeAll("!llvm.module.flags = !{!1, !2}\n");
    try writer.writeAll("!llvm.ident = !{!3}\n");
    try writer.print("!0 = distinct !DICompileUnit(language: DW_LANG_C, file: !{}, producer: \"cyna\", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug)\n", .{debug.compile_unit_file_id});
    try writer.writeAll("!1 = !{i32 7, !\"Dwarf Version\", i32 4}\n");
    try writer.writeAll("!2 = !{i32 2, !\"Debug Info Version\", i32 3}\n");
    try writer.writeAll("!3 = !{!\"cyna\"}\n");

    for (debug.files) |file| {
        const filename = std.fs.path.basename(file.path);
        const directory = std.fs.path.dirname(file.path) orelse ".";
        const escaped_filename = try llvm_support.escapeBytes(allocator, filename);
        defer allocator.free(escaped_filename);
        const escaped_directory = try llvm_support.escapeBytes(allocator, directory);
        defer allocator.free(escaped_directory);
        try writer.print("!{} = !DIFile(filename: \"{s}\", directory: \"{s}\")\n", .{
            file.id,
            escaped_filename,
            escaped_directory,
        });
    }

    try writer.print("!{} = !DISubroutineType(types: !{{}})\n", .{debug.subroutine_type_id});
    for (module.functions, debug.functions) |function, function_debug| {
        if (function_debug.subprogram_id == 0) continue;
        const linkage_name = function.abi_name orelse function.name;
        const escaped_name = try llvm_support.escapeBytes(allocator, function.name);
        defer allocator.free(escaped_name);
        const escaped_linkage = try llvm_support.escapeBytes(allocator, linkage_name);
        defer allocator.free(escaped_linkage);
        try writer.print(
            "!{} = distinct !DISubprogram(name: \"{s}\", linkageName: \"{s}\", scope: !{}, file: !{}, line: {}, type: !{}, scopeLine: {}, spFlags: DISPFlagDefinition, unit: !0)\n",
            .{
                function_debug.subprogram_id,
                escaped_name,
                escaped_linkage,
                function_debug.file_id,
                function_debug.file_id,
                function_debug.line,
                debug.subroutine_type_id,
                function_debug.line,
            },
        );
        try writer.print("!{} = !DILocation(line: {}, column: {}, scope: !{})\n", .{
            function_debug.location_id,
            function_debug.line,
            function_debug.column,
            function_debug.subprogram_id,
        });
    }
}

fn emitRuntimeDeclarations(writer: anytype, module: lir.Module, reachability: backend_support.Reachability) Error!void {
    try writer.writeAll("declare void @llvm.trap()\n");
    var needs_trace_ops = false;
    for (module.functions, 0..) |function, i| {
        if (!reachability.functionIsReachable(i) or function.is_extern) continue;
        if (abi.needsLocalTraceContext(module, function) and module.types[function.return_type] == .result) needs_trace_ops = true;
        for (function.blocks) |block| {
            if (block.catch_exits.len != 0) needs_trace_ops = true;
            for (block.instructions) |inst| {
                if (inst.data == .make_result and inst.data.make_result.trace != .none) needs_trace_ops = true;
                if (inst.data == .trace_detail) needs_trace_ops = true;
            }
        }
    }
    // Result descriptors can retire a boxed task failure even when no local
    // function creates or catches a trace in this module.
    try writer.writeAll("declare void @cyna_trace_release_abi(ptr, ptr)\n");
    for (module.functions, 0..) |function, i| {
        if (!reachability.functionIsReachable(i) or !abi.isEntryResult(module, function)) continue;
        try writer.writeAll("declare void @cyna_trace_print_unhandled_abi(i8, ptr)\n");
        break;
    }
    if (needs_trace_ops) {
        try writer.writeAll("declare void @cyna_trace_create_location_abi(ptr, ptr, i32, ptr, i64, ptr, i64)\n");
        try writer.writeAll("declare void @cyna_trace_append_location_abi(ptr, ptr, i32, ptr, i64)\n");
        try writer.writeAll("declare i1 @cyna_trace_available_abi(ptr, ptr)\n");
        try writer.writeAll("declare i32 @cyna_trace_origin_abi(ptr, ptr)\n");
        try writer.writeAll("declare i64 @cyna_trace_site_count_abi(ptr, ptr)\n");
        try writer.writeAll("declare i64 @cyna_trace_omitted_abi(ptr, ptr)\n");
        try writer.writeAll("declare void @cyna_trace_message_abi(ptr, ptr, ptr)\n");
        try writer.writeAll("declare i1 @cyna_trace_site_abi(ptr, ptr, i64, ptr)\n");
        try writer.writeAll("declare void @cyna_trace_origin_file_abi(ptr, ptr, ptr)\n");
        try writer.writeAll("declare i1 @cyna_trace_site_file_abi(ptr, ptr, i64, ptr)\n");
    }
    for (module.functions, 0..) |function, i| {
        if (!reachability.functionIsReachable(i) or !abi.needsLocalTraceContext(module, function)) continue;
        try writer.writeAll("declare ptr @cyna_trace_new()\n");
        try writer.writeAll("declare void @cyna_trace_release_root(ptr)\n");
        break;
    }
    for (runtime_symbols.container_runtime_decls) |decl| {
        const symbol_name = runtime_symbols.name(decl.id);
        if (!decl.always_emit and !backend_support.moduleUsesContainerRuntimeDecl(module, reachability, symbol_name)) continue;
        try writer.print("declare {s} @{s}{s}\n", .{
            decl.return_type,
            symbol_name,
            decl.signature,
        });
    }
    for (runtime_symbols.string_runtime_decls) |decl| {
        const symbol_name = runtime_symbols.name(decl.id);
        if (!backend_support.moduleUsesCallNamed(module, reachability, symbol_name)) continue;
        try writer.print("declare {s} @{s}{s}\n", .{
            decl.return_type,
            symbol_name,
            decl.signature,
        });
    }
    for (runtime_symbols.infrastructure_runtime_decls) |decl| {
        const symbol_name = runtime_symbols.name(decl.id);
        try writer.print("declare {s} @{s}{s}\n", .{
            decl.return_type,
            symbol_name,
            decl.signature,
        });
    }
}

fn emitCStringGlobal(allocator: std.mem.Allocator, writer: anytype, name: []const u8, value: []const u8) Error!void {
    const escaped = try llvm_support.escapeBytes(allocator, value);
    defer allocator.free(escaped);
    try writer.print("@{s} = private unnamed_addr constant [{d} x i8] c\"{s}\\00\"\n", .{
        name,
        value.len + 1,
        escaped,
    });
}

fn emitAllocationSiteGlobals(allocator: std.mem.Allocator, writer: anytype) Error!void {
    try emitCStringGlobal(allocator, writer, allocation_site_file_global, "compiler/backend/llvm/emitter.zig");
    try emitCStringGlobal(allocator, writer, ".cyna.alloc.dense.copy.data", "compiler.dense.copy.data");
    try emitCStringGlobal(allocator, writer, ".cyna.alloc.sparse.copy.occupied", "compiler.sparse.copy.occupied");
    try emitCStringGlobal(allocator, writer, ".cyna.alloc.sparse.copy.data", "compiler.sparse.copy.data");
    try emitCStringGlobal(allocator, writer, ".cyna.alloc.sparse.indices.data", "compiler.sparse.indices.data");
    try emitCStringGlobal(allocator, writer, ".cyna.alloc.dense.reserve.data", "compiler.dense.reserve.data");
    try emitCStringGlobal(allocator, writer, ".cyna.alloc.sparse.new.occupied", "compiler.sparse.new.occupied");
    try emitCStringGlobal(allocator, writer, ".cyna.alloc.sparse.new.data", "compiler.sparse.new.data");
    try emitCStringGlobal(allocator, writer, ".cyna.alloc.dense.runtime.object", "compiler.dense.runtime.object");
    try emitCStringGlobal(allocator, writer, ".cyna.alloc.sparse.runtime.object", "compiler.sparse.runtime.object");
}

const std = @import("std");
const abi = @import("abi.zig");
const common = @import("common.zig");
const backend_support = @import("../support.zig");
const runtime_symbols = @import("../../../runtime/symbols.zig");
const types = @import("types.zig");
const lir = @import("../../lower/lir.zig");

pub const Error = common.Error;

const dense_carrier_llvm_type = runtime_symbols.dense_carrier_llvm_type;
const sparse_carrier_llvm_type = runtime_symbols.sparse_carrier_llvm_type;
const type_desc_copy_field_index = @backingInt(runtime_symbols.TypeDescField.copy);
const type_desc_drop_field_index = @backingInt(runtime_symbols.TypeDescField.drop);

fn emitTypeDescriptorRecursive(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    ty: lir.TypeId,
    seen: []bool,
    emitted_desc_names: *std.StringHashMapUnmanaged(void),
    partitioned: bool,
    coff_comdat: bool,
) Error!void {
    if (seen[ty]) return;
    seen[ty] = true;

    switch (module.types[ty]) {
        .optional => |payload_ty| try emitTypeDescriptorRecursive(allocator, writer, module, payload_ty, seen, emitted_desc_names, partitioned, coff_comdat),
        .result => |result_ty| {
            try emitTypeDescriptorRecursive(allocator, writer, module, result_ty.ok, seen, emitted_desc_names, partitioned, coff_comdat);
            try emitTypeDescriptorRecursive(allocator, writer, module, result_ty.err, seen, emitted_desc_names, partitioned, coff_comdat);
        },
        .array => |array_ty| try emitTypeDescriptorRecursive(allocator, writer, module, array_ty.elem, seen, emitted_desc_names, partitioned, coff_comdat),
        .dense_array => |item_ty| try emitTypeDescriptorRecursive(allocator, writer, module, item_ty, seen, emitted_desc_names, partitioned, coff_comdat),
        .sparse_array => |item_ty| try emitTypeDescriptorRecursive(allocator, writer, module, item_ty, seen, emitted_desc_names, partitioned, coff_comdat),
        .@"struct" => |struct_ty| {
            for (struct_ty.fields) |field| {
                try emitTypeDescriptorRecursive(allocator, writer, module, field.ty, seen, emitted_desc_names, partitioned, coff_comdat);
            }
        },
        .@"union" => |union_ty| {
            for (union_ty.payloads) |payload_ty| {
                if (payload_ty) |field_ty| {
                    try emitTypeDescriptorRecursive(allocator, writer, module, field_ty, seen, emitted_desc_names, partitioned, coff_comdat);
                }
            }
        },
        .int, .float, .pointer, .slice => {},
        else => {},
    }

    const desc_name = try backend_support.descriptorGlobalName(allocator, module, ty);
    errdefer allocator.free(desc_name);
    const gop = try emitted_desc_names.getOrPut(allocator, desc_name);
    if (gop.found_existing) {
        allocator.free(desc_name);
        return;
    }
    const copy_name = try backend_support.descriptorCopyName(allocator, module, ty);
    defer allocator.free(copy_name);
    const drop_name = try backend_support.descriptorDropName(allocator, module, ty);
    defer allocator.free(drop_name);
    const size_align = try abi.typeSizeAlign(module, ty);

    if (!backend_support.descriptorHelperNeedsGeneration(module, ty)) return;
    try emitDescriptorCopyHelper(allocator, writer, module, ty, copy_name, partitioned, coff_comdat);
    try writer.writeByte('\n');
    try emitDescriptorDropHelper(allocator, writer, module, ty, drop_name, partitioned, coff_comdat);
    try writer.writeByte('\n');
    if (!backend_support.descriptorNeedsGeneration(module, ty)) return;
    try writer.print(
        "@{s} = internal global {s} {{ i64 {}, i64 {}, i32 0, ptr @{s}, ptr @{s}, ptr null, ptr null, ptr null }}\n\n",
        .{ desc_name, runtime_symbols.type_desc_llvm_type, size_align.size, size_align.abi_align, copy_name, drop_name },
    );
}

pub fn emitReferencedDescriptorsForFunction(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    function: lir.Function,
    seen: []bool,
    emitted_desc_names: *std.StringHashMapUnmanaged(void),
    partitioned: bool,
    coff_comdat: bool,
) Error!void {
    const info = try common.buildValueInfo(allocator, module, function);
    defer common.deinitValueInfo(allocator, info);

    for (function.blocks) |block| {
        for (block.instructions) |inst| {
            switch (inst.data) {
                .type_desc => |ty| try emitTypeDescriptorRecursive(allocator, writer, module, ty, seen, emitted_desc_names, partitioned, coff_comdat),
                .dense_copy => |value| {
                    const ty = info[value.lhs].ty orelse return error.BackendInvariantViolation;
                    try emitTypeDescriptorRecursive(allocator, writer, module, ty, seen, emitted_desc_names, partitioned, coff_comdat);
                },
                .dense_drop => |value| {
                    const ty = info[value.lhs].ty orelse return error.BackendInvariantViolation;
                    try emitTypeDescriptorRecursive(allocator, writer, module, ty, seen, emitted_desc_names, partitioned, coff_comdat);
                },
                .sparse_copy => |value| {
                    const ty = info[value.lhs].ty orelse return error.BackendInvariantViolation;
                    try emitTypeDescriptorRecursive(allocator, writer, module, ty, seen, emitted_desc_names, partitioned, coff_comdat);
                },
                .sparse_drop => |value| {
                    const ty = info[value.lhs].ty orelse return error.BackendInvariantViolation;
                    try emitTypeDescriptorRecursive(allocator, writer, module, ty, seen, emitted_desc_names, partitioned, coff_comdat);
                },
                .call => |call| {
                    if (findFunctionByAbiName(module, call.name)) |callee| {
                        if (abi.needsExternImportValueBridge(callee)) {
                            for (call.args, 0..) |_, i| {
                                const param = callee.params[i];
                                if (try abi.indirectParamInfo(module, callee, param.ty)) |_| {
                                    if (try abi.publicCallableBoundaryType(allocator, module, param.ty)) |public_ty| {
                                        allocator.free(public_ty);
                                        continue;
                                    }
                                    if (backend_support.descriptorHelperNeedsGeneration(module, param.ty)) {
                                        try emitTypeDescriptorRecursive(allocator, writer, module, param.ty, seen, emitted_desc_names, partitioned, coff_comdat);
                                    }
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }
}

fn emitDescriptorCopyHelper(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    ty: lir.TypeId,
    copy_name: []const u8,
    partitioned: bool,
    coff_comdat: bool,
) Error!void {
    if (partitioned and coff_comdat) try writer.print("${s} = comdat any\n", .{copy_name});
    try writer.print("define{s} void @{s}(ptr %dst, ptr %src, ptr %desc){s} {{\n", .{ if (partitioned) " linkonce_odr" else "", copy_name, if (partitioned and coff_comdat) " comdat" else "" });
    try writer.writeAll("entry:\n");
    _ = try emitDescriptorHelperBody(allocator, writer, module, ty, true);
    try writer.writeAll("  ret void\n}\n");
}

fn emitDescriptorDropHelper(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    ty: lir.TypeId,
    drop_name: []const u8,
    partitioned: bool,
    coff_comdat: bool,
) Error!void {
    if (partitioned and coff_comdat) try writer.print("${s} = comdat any\n", .{drop_name});
    try writer.print("define{s} void @{s}(ptr %value, ptr %desc){s} {{\n", .{ if (partitioned) " linkonce_odr" else "", drop_name, if (partitioned and coff_comdat) " comdat" else "" });
    try writer.writeAll("entry:\n");
    _ = try emitDescriptorHelperBody(allocator, writer, module, ty, false);
    try writer.writeAll("  ret void\n}\n");
}

fn emitDescriptorHelperBody(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    ty: lir.TypeId,
    is_copy: bool,
) Error!void {
    switch (module.types[ty]) {
        .int, .float, .pointer, .slice => {
            const scalar_ty = try types.llvmScalarType(allocator, module, ty);
            defer allocator.free(scalar_ty);
            if (is_copy) {
                try writer.print("  %value = load {s}, ptr %src\n", .{scalar_ty});
                try writer.print("  store {s} %value, ptr %dst\n", .{scalar_ty});
            }
        },
        .optional => |payload_ty| {
            const payload_desc = try backend_support.descriptorGlobalName(allocator, module, payload_ty);
            defer allocator.free(payload_desc);
            const optional_llvm = try types.llvmOptionalType(allocator, module, ty);
            defer allocator.free(optional_llvm);
            if (is_copy) {
                try writer.print("  %src_val = load {s}, ptr %src\n", .{optional_llvm});
                try writer.print("  %src_tag_raw = extractvalue {s} %src_val, 0\n", .{optional_llvm});
                try writer.writeAll("  %src_tag = icmp ne i8 %src_tag_raw, 0\n");
                try writer.writeAll("  br i1 %src_tag, label %copy_some, label %copy_none\n");
                try writer.writeAll("copy_none:\n");
                try writer.print("  store {s} %src_val, ptr %dst\n", .{optional_llvm});
                try writer.writeAll("  br label %copy_cont\n");
                try writer.writeAll("copy_some:\n");
                try writer.print("  %dst_payload = getelementptr inbounds {s}, ptr %dst, i32 0, i32 1\n", .{optional_llvm});
                try writer.print("  %src_payload = getelementptr inbounds {s}, ptr %src, i32 0, i32 1\n", .{optional_llvm});
                try writer.print("  %copy_slot = getelementptr inbounds {s}, ptr @{s}, i32 0, i32 {d}\n", .{ runtime_symbols.type_desc_llvm_type, payload_desc, type_desc_copy_field_index });
                try writer.writeAll("  %copy_fn = load ptr, ptr %copy_slot\n");
                try writer.print("  call void %copy_fn(ptr %dst_payload, ptr %src_payload, ptr @{s})\n", .{payload_desc});
                try writer.print("  %dst_tag = getelementptr inbounds {s}, ptr %dst, i32 0, i32 0\n", .{optional_llvm});
                try writer.writeAll("  store i8 1, ptr %dst_tag\n");
                try writer.writeAll("  br label %copy_cont\n");
                try writer.writeAll("copy_cont:\n");
            } else {
                try writer.print("  %opt_val = load {s}, ptr %value\n", .{optional_llvm});
                try writer.print("  %opt_tag_raw = extractvalue {s} %opt_val, 0\n", .{optional_llvm});
                try writer.writeAll("  %opt_tag = icmp ne i8 %opt_tag_raw, 0\n");
                try writer.writeAll("  br i1 %opt_tag, label %drop_some, label %drop_cont\n");
                try writer.writeAll("drop_some:\n");
                try writer.print("  %payload_ptr = getelementptr inbounds {s}, ptr %value, i32 0, i32 1\n", .{optional_llvm});
                try writer.print("  %drop_slot = getelementptr inbounds {s}, ptr @{s}, i32 0, i32 {d}\n", .{ runtime_symbols.type_desc_llvm_type, payload_desc, type_desc_drop_field_index });
                try writer.writeAll("  %drop_fn = load ptr, ptr %drop_slot\n");
                try writer.print("  call void %drop_fn(ptr %payload_ptr, ptr @{s})\n", .{payload_desc});
                try writer.writeAll("  br label %drop_cont\n");
                try writer.writeAll("drop_cont:\n");
            }
        },
        .result => |result_ty| {
            // A descriptor copy preserves the typed payload but starts with a
            // code-only handle. Trace records have one compiler-managed alias;
            // copying this field would create an untracked second owner.
            // Ordinary descriptor drop likewise does not retire a trace slot:
            // catch exits and explicit transfer paths own that lifetime.
            const result_llvm = try types.llvmResultType(allocator, module, ty);
            defer allocator.free(result_llvm);
            const ok_llvm = try types.llvmResultOkType(allocator, module, ty);
            defer allocator.free(ok_llvm);
            const err_llvm = try types.llvmResultErrType(allocator, module, ty);
            defer allocator.free(err_llvm);

            const ok_desc = if (module.types[result_ty.ok] == .void)
                null
            else
                try backend_support.descriptorGlobalName(allocator, module, result_ty.ok);
            defer if (ok_desc) |name| allocator.free(name);

            const err_desc = try backend_support.descriptorGlobalName(allocator, module, result_ty.err);
            defer allocator.free(err_desc);

            if (is_copy) {
                try writer.print("  store {s} zeroinitializer, ptr %dst\n", .{result_llvm});
                try writer.print("  %src_val = load {s}, ptr %src\n", .{result_llvm});
                try writer.print("  %src_tag_raw = extractvalue {s} %src_val, 0\n", .{result_llvm});
                try writer.writeAll("  %src_is_ok = icmp eq i8 %src_tag_raw, 0\n");
                try writer.writeAll("  br i1 %src_is_ok, label %copy_ok, label %copy_err\n");
                try writer.writeAll("copy_ok:\n");
                if (ok_desc) |payload_desc| {
                    try writer.print("  %dst_ok = getelementptr inbounds {s}, ptr %dst, i32 0, i32 1\n", .{result_llvm});
                    try writer.print("  %src_ok = getelementptr inbounds {s}, ptr %src, i32 0, i32 1\n", .{result_llvm});
                    try writer.print("  %copy_ok_slot = getelementptr inbounds {s}, ptr @{s}, i32 0, i32 {d}\n", .{ runtime_symbols.type_desc_llvm_type, payload_desc, type_desc_copy_field_index });
                    try writer.writeAll("  %copy_ok_fn = load ptr, ptr %copy_ok_slot\n");
                    try writer.print("  call void %copy_ok_fn(ptr %dst_ok, ptr %src_ok, ptr @{s})\n", .{payload_desc});
                }
                try writer.print("  %dst_tag = getelementptr inbounds {s}, ptr %dst, i32 0, i32 0\n", .{result_llvm});
                try writer.writeAll("  store i8 0, ptr %dst_tag\n");
                try writer.writeAll("  br label %copy_cont\n");
                try writer.writeAll("copy_err:\n");
                try writer.print("  %dst_err = getelementptr inbounds {s}, ptr %dst, i32 0, i32 2\n", .{result_llvm});
                try writer.print("  %src_err = getelementptr inbounds {s}, ptr %src, i32 0, i32 2\n", .{result_llvm});
                try writer.print("  %copy_err_slot = getelementptr inbounds {s}, ptr @{s}, i32 0, i32 {d}\n", .{ runtime_symbols.type_desc_llvm_type, err_desc, type_desc_copy_field_index });
                try writer.writeAll("  %copy_err_fn = load ptr, ptr %copy_err_slot\n");
                try writer.print("  call void %copy_err_fn(ptr %dst_err, ptr %src_err, ptr @{s})\n", .{err_desc});
                try writer.print("  %dst_tag_err = getelementptr inbounds {s}, ptr %dst, i32 0, i32 0\n", .{result_llvm});
                try writer.writeAll("  store i8 1, ptr %dst_tag_err\n");
                try writer.writeAll("  br label %copy_cont\n");
                try writer.writeAll("copy_cont:\n");
            } else {
                try writer.print("  %result_val = load {s}, ptr %value\n", .{result_llvm});
                try writer.print("  %result_tag_raw = extractvalue {s} %result_val, 0\n", .{result_llvm});
                try writer.writeAll("  %result_is_ok = icmp eq i8 %result_tag_raw, 0\n");
                try writer.writeAll("  br i1 %result_is_ok, label %drop_ok, label %drop_err\n");
                try writer.writeAll("drop_ok:\n");
                if (ok_desc) |payload_desc| {
                    try writer.print("  %ok_payload = getelementptr inbounds {s}, ptr %value, i32 0, i32 1\n", .{result_llvm});
                    try writer.print("  %drop_ok_slot = getelementptr inbounds {s}, ptr @{s}, i32 0, i32 {d}\n", .{ runtime_symbols.type_desc_llvm_type, payload_desc, type_desc_drop_field_index });
                    try writer.writeAll("  %drop_ok_fn = load ptr, ptr %drop_ok_slot\n");
                    try writer.print("  call void %drop_ok_fn(ptr %ok_payload, ptr @{s})\n", .{payload_desc});
                }
                try writer.writeAll("  br label %drop_cont\n");
                try writer.writeAll("drop_err:\n");
                try writer.print("  %err_payload = getelementptr inbounds {s}, ptr %value, i32 0, i32 2\n", .{result_llvm});
                try writer.print("  %drop_err_slot = getelementptr inbounds {s}, ptr @{s}, i32 0, i32 {d}\n", .{ runtime_symbols.type_desc_llvm_type, err_desc, type_desc_drop_field_index });
                try writer.writeAll("  %drop_err_fn = load ptr, ptr %drop_err_slot\n");
                try writer.print("  call void %drop_err_fn(ptr %err_payload, ptr @{s})\n", .{err_desc});
                try writer.print("  %result_trace = getelementptr inbounds {s}, ptr %value, i32 0, i32 3\n", .{result_llvm});
                try writer.writeAll("  call void @cyna_trace_release_abi(ptr null, ptr %result_trace)\n");
                try writer.writeAll("  br label %drop_cont\n");
                try writer.writeAll("drop_cont:\n");
            }
        },
        .array => |array_ty| {
            const elem_desc = try backend_support.descriptorGlobalName(allocator, module, array_ty.elem);
            defer allocator.free(elem_desc);
            const array_llvm = try types.llvmScalarType(allocator, module, ty);
            defer allocator.free(array_llvm);
            const label_prefix = if (is_copy) "copy_array" else "drop_array";
            try writer.writeAll("  %array_index = alloca i64\n");
            try writer.writeAll("  store i64 0, ptr %array_index\n");
            try writer.print("  br label %{s}_cond\n", .{label_prefix});
            try writer.print("{s}_cond:\n", .{label_prefix});
            try writer.writeAll("  %array_i = load i64, ptr %array_index\n");
            try writer.print("  %array_keep_going = icmp slt i64 %array_i, {}\n", .{array_ty.len});
            try writer.print("  br i1 %array_keep_going, label %{s}_body, label %{s}_cont\n", .{ label_prefix, label_prefix });
            try writer.print("{s}_body:\n", .{label_prefix});
            if (is_copy) {
                try writer.print("  %dst_elem = getelementptr inbounds {s}, ptr %dst, i32 0, i64 %array_i\n", .{array_llvm});
                try writer.print("  %src_elem = getelementptr inbounds {s}, ptr %src, i32 0, i64 %array_i\n", .{array_llvm});
                try writer.print("  %array_copy_slot = getelementptr inbounds {s}, ptr @{s}, i32 0, i32 {d}\n", .{ runtime_symbols.type_desc_llvm_type, elem_desc, type_desc_copy_field_index });
                try writer.writeAll("  %array_copy_fn = load ptr, ptr %array_copy_slot\n");
                try writer.print("  call void %array_copy_fn(ptr %dst_elem, ptr %src_elem, ptr @{s})\n", .{elem_desc});
            } else {
                try writer.print("  %value_elem = getelementptr inbounds {s}, ptr %value, i32 0, i64 %array_i\n", .{array_llvm});
                try writer.print("  %array_drop_slot = getelementptr inbounds {s}, ptr @{s}, i32 0, i32 {d}\n", .{ runtime_symbols.type_desc_llvm_type, elem_desc, type_desc_drop_field_index });
                try writer.writeAll("  %array_drop_fn = load ptr, ptr %array_drop_slot\n");
                try writer.print("  call void %array_drop_fn(ptr %value_elem, ptr @{s})\n", .{elem_desc});
            }
            try writer.writeAll("  %array_next = add i64 %array_i, 1\n");
            try writer.writeAll("  store i64 %array_next, ptr %array_index\n");
            try writer.print("  br label %{s}_cond\n", .{label_prefix});
            try writer.print("{s}_cont:\n", .{label_prefix});
        },
        .dense_array => |item_ty| {
            const elem_desc = try backend_support.descriptorGlobalName(allocator, module, item_ty);
            defer allocator.free(elem_desc);
            const elem_llvm = try types.llvmScalarType(allocator, module, item_ty);
            defer allocator.free(elem_llvm);
            const elem_size = (try abi.typeSizeAlign(module, item_ty)).size;
            if (is_copy) {
                try writer.print("  %src_val = load {s}, ptr %src\n", .{dense_carrier_llvm_type});
                try writer.print("  %src_data = extractvalue {s} %src_val, 0\n", .{dense_carrier_llvm_type});
                try writer.print("  %src_len = extractvalue {s} %src_val, 1\n", .{dense_carrier_llvm_type});
                try writer.print("  %src_cap = extractvalue {s} %src_val, 2\n", .{dense_carrier_llvm_type});
                try writer.writeAll("  %dense_alloc_bytes = mul i64 %src_cap, ");
                try writer.print("{}\n", .{elem_size});
                try writer.writeAll("  %dense_has_cap = icmp ne i64 %src_cap, 0\n");
                try writer.writeAll("  br i1 %dense_has_cap, label %dense_copy_alloc, label %dense_copy_zero\n");
                try writer.writeAll("dense_copy_zero:\n");
                try writer.writeAll("  br label %dense_copy_start\n");
                try writer.writeAll("dense_copy_alloc:\n");
                try writer.writeAll("  %dense_alloc_raw = call ptr @cyna_runtime_tracked_alloc_site(i64 %dense_alloc_bytes, ptr @.cyna.alloc.file, i64 765, ptr @.cyna.alloc.dense.copy.data)\n");
                try writer.writeAll("  br label %dense_copy_start\n");
                try writer.writeAll("dense_copy_start:\n");
                try writer.writeAll("  %dense_dst_data = phi ptr [ null, %dense_copy_zero ], [ %dense_alloc_raw, %dense_copy_alloc ]\n");
                try writer.writeAll("  %dense_index = alloca i64\n");
                try writer.writeAll("  store i64 0, ptr %dense_index\n");
                try writer.writeAll("  br label %dense_copy_cond\n");
                try writer.writeAll("dense_copy_cond:\n");
                try writer.writeAll("  %dense_i = load i64, ptr %dense_index\n");
                try writer.writeAll("  %dense_keep_going = icmp slt i64 %dense_i, %src_len\n");
                try writer.writeAll("  br i1 %dense_keep_going, label %dense_copy_body, label %dense_copy_done\n");
                try writer.writeAll("dense_copy_body:\n");
                try writer.print("  %dense_dst_elem = getelementptr inbounds {s}, ptr %dense_dst_data, i64 %dense_i\n", .{elem_llvm});
                try writer.print("  %dense_src_elem = getelementptr inbounds {s}, ptr %src_data, i64 %dense_i\n", .{elem_llvm});
                try writer.print("  %dense_copy_slot = getelementptr inbounds {s}, ptr @{s}, i32 0, i32 {d}\n", .{ runtime_symbols.type_desc_llvm_type, elem_desc, type_desc_copy_field_index });
                try writer.writeAll("  %dense_copy_fn = load ptr, ptr %dense_copy_slot\n");
                try writer.print("  call void %dense_copy_fn(ptr %dense_dst_elem, ptr %dense_src_elem, ptr @{s})\n", .{elem_desc});
                try writer.writeAll("  %dense_next = add i64 %dense_i, 1\n");
                try writer.writeAll("  store i64 %dense_next, ptr %dense_index\n");
                try writer.writeAll("  br label %dense_copy_cond\n");
                try writer.writeAll("dense_copy_done:\n");
                try writer.writeAll("  %dense_cv0 = insertvalue { ptr, i64, i64 } undef, ptr %dense_dst_data, 0\n");
                try writer.writeAll("  %dense_cv1 = insertvalue { ptr, i64, i64 } %dense_cv0, i64 %src_len, 1\n");
                try writer.writeAll("  %dense_cv2 = insertvalue { ptr, i64, i64 } %dense_cv1, i64 %src_cap, 2\n");
                try writer.print("  store {s} %dense_cv2, ptr %dst\n", .{dense_carrier_llvm_type});
            } else {
                try writer.print("  %dense_val = load {s}, ptr %value\n", .{dense_carrier_llvm_type});
                try writer.print("  %dense_data = extractvalue {s} %dense_val, 0\n", .{dense_carrier_llvm_type});
                try writer.print("  %dense_len = extractvalue {s} %dense_val, 1\n", .{dense_carrier_llvm_type});
                try writer.writeAll("  %dense_drop_index = alloca i64\n");
                try writer.writeAll("  store i64 0, ptr %dense_drop_index\n");
                try writer.writeAll("  br label %dense_drop_cond\n");
                try writer.writeAll("dense_drop_cond:\n");
                try writer.writeAll("  %dense_drop_i = load i64, ptr %dense_drop_index\n");
                try writer.writeAll("  %dense_drop_keep_going = icmp slt i64 %dense_drop_i, %dense_len\n");
                try writer.writeAll("  br i1 %dense_drop_keep_going, label %dense_drop_body, label %dense_drop_done\n");
                try writer.writeAll("dense_drop_body:\n");
                try writer.print("  %dense_value_elem = getelementptr inbounds {s}, ptr %dense_data, i64 %dense_drop_i\n", .{elem_llvm});
                try writer.print("  %dense_drop_slot = getelementptr inbounds {s}, ptr @{s}, i32 0, i32 {d}\n", .{ runtime_symbols.type_desc_llvm_type, elem_desc, type_desc_drop_field_index });
                try writer.writeAll("  %dense_drop_fn = load ptr, ptr %dense_drop_slot\n");
                try writer.print("  call void %dense_drop_fn(ptr %dense_value_elem, ptr @{s})\n", .{elem_desc});
                try writer.writeAll("  %dense_drop_next = add i64 %dense_drop_i, 1\n");
                try writer.writeAll("  store i64 %dense_drop_next, ptr %dense_drop_index\n");
                try writer.writeAll("  br label %dense_drop_cond\n");
                try writer.writeAll("dense_drop_done:\n");
                try writer.writeAll("  %dense_has_data = icmp ne ptr %dense_data, null\n");
                try writer.writeAll("  br i1 %dense_has_data, label %dense_drop_free, label %dense_drop_cont\n");
                try writer.writeAll("dense_drop_free:\n");
                try writer.writeAll("  call void @cyna_runtime_tracked_free(ptr %dense_data)\n");
                try writer.writeAll("  br label %dense_drop_cont\n");
                try writer.writeAll("dense_drop_cont:\n");
            }
        },
        .sparse_array => |item_ty| {
            const elem_desc = try backend_support.descriptorGlobalName(allocator, module, item_ty);
            defer allocator.free(elem_desc);
            const elem_llvm = try types.llvmScalarType(allocator, module, item_ty);
            defer allocator.free(elem_llvm);
            const elem_size = (try abi.typeSizeAlign(module, item_ty)).size;
            if (is_copy) {
                try writer.print("  %src_val = load {s}, ptr %src\n", .{sparse_carrier_llvm_type});
                try writer.print("  %src_data = extractvalue {s} %src_val, 0\n", .{sparse_carrier_llvm_type});
                try writer.print("  %src_occ = extractvalue {s} %src_val, 1\n", .{sparse_carrier_llvm_type});
                try writer.print("  %src_len = extractvalue {s} %src_val, 2\n", .{sparse_carrier_llvm_type});
                try writer.print("  %src_cap = extractvalue {s} %src_val, 3\n", .{sparse_carrier_llvm_type});
                try writer.writeAll("  %sparse_data_bytes = mul i64 %src_cap, ");
                try writer.print("{}\n", .{elem_size});
                try writer.writeAll("  %sparse_has_cap = icmp ne i64 %src_cap, 0\n");
                try writer.writeAll("  br i1 %sparse_has_cap, label %sparse_copy_alloc, label %sparse_copy_zero\n");
                try writer.writeAll("sparse_copy_zero:\n");
                try writer.writeAll("  br label %sparse_copy_start\n");
                try writer.writeAll("sparse_copy_alloc:\n");
                try writer.writeAll("  %sparse_alloc_occ = call ptr @cyna_runtime_tracked_alloc_site(i64 %src_cap, ptr @.cyna.alloc.file, i64 837, ptr @.cyna.alloc.sparse.copy.occupied)\n");
                try writer.writeAll("  %sparse_alloc_data = call ptr @cyna_runtime_tracked_alloc_site(i64 %sparse_data_bytes, ptr @.cyna.alloc.file, i64 838, ptr @.cyna.alloc.sparse.copy.data)\n");
                try writer.writeAll("  br label %sparse_copy_start\n");
                try writer.writeAll("sparse_copy_start:\n");
                try writer.writeAll("  %sparse_dst_occ = phi ptr [ null, %sparse_copy_zero ], [ %sparse_alloc_occ, %sparse_copy_alloc ]\n");
                try writer.writeAll("  %sparse_dst_data = phi ptr [ null, %sparse_copy_zero ], [ %sparse_alloc_data, %sparse_copy_alloc ]\n");
                try writer.writeAll("  %sparse_index = alloca i64\n");
                try writer.writeAll("  store i64 0, ptr %sparse_index\n");
                try writer.writeAll("  br label %sparse_copy_cond\n");
                try writer.writeAll("sparse_copy_cond:\n");
                try writer.writeAll("  %sparse_i = load i64, ptr %sparse_index\n");
                try writer.writeAll("  %sparse_keep_going = icmp slt i64 %sparse_i, %src_cap\n");
                try writer.writeAll("  br i1 %sparse_keep_going, label %sparse_copy_body, label %sparse_copy_done\n");
                try writer.writeAll("sparse_copy_body:\n");
                try writer.writeAll("  %sparse_src_occ_slot = getelementptr inbounds i8, ptr %src_occ, i64 %sparse_i\n");
                try writer.writeAll("  %sparse_dst_occ_slot = getelementptr inbounds i8, ptr %sparse_dst_occ, i64 %sparse_i\n");
                try writer.writeAll("  %sparse_occ_byte = load i8, ptr %sparse_src_occ_slot\n");
                try writer.writeAll("  store i8 %sparse_occ_byte, ptr %sparse_dst_occ_slot\n");
                try writer.writeAll("  %sparse_present = icmp ne i8 %sparse_occ_byte, 0\n");
                try writer.writeAll("  br i1 %sparse_present, label %sparse_copy_elem, label %sparse_copy_next\n");
                try writer.writeAll("sparse_copy_elem:\n");
                try writer.print("  %sparse_dst_elem = getelementptr inbounds {s}, ptr %sparse_dst_data, i64 %sparse_i\n", .{elem_llvm});
                try writer.print("  %sparse_src_elem = getelementptr inbounds {s}, ptr %src_data, i64 %sparse_i\n", .{elem_llvm});
                try writer.print("  %sparse_copy_slot = getelementptr inbounds {s}, ptr @{s}, i32 0, i32 {d}\n", .{ runtime_symbols.type_desc_llvm_type, elem_desc, type_desc_copy_field_index });
                try writer.writeAll("  %sparse_copy_fn = load ptr, ptr %sparse_copy_slot\n");
                try writer.print("  call void %sparse_copy_fn(ptr %sparse_dst_elem, ptr %sparse_src_elem, ptr @{s})\n", .{elem_desc});
                try writer.writeAll("  br label %sparse_copy_next\n");
                try writer.writeAll("sparse_copy_next:\n");
                try writer.writeAll("  %sparse_next = add i64 %sparse_i, 1\n");
                try writer.writeAll("  store i64 %sparse_next, ptr %sparse_index\n");
                try writer.writeAll("  br label %sparse_copy_cond\n");
                try writer.writeAll("sparse_copy_done:\n");
                try writer.writeAll("  %sparse_cv0 = insertvalue { ptr, ptr, i64, i64 } undef, ptr %sparse_dst_data, 0\n");
                try writer.writeAll("  %sparse_cv1 = insertvalue { ptr, ptr, i64, i64 } %sparse_cv0, ptr %sparse_dst_occ, 1\n");
                try writer.writeAll("  %sparse_cv2 = insertvalue { ptr, ptr, i64, i64 } %sparse_cv1, i64 %src_len, 2\n");
                try writer.writeAll("  %sparse_cv3 = insertvalue { ptr, ptr, i64, i64 } %sparse_cv2, i64 %src_cap, 3\n");
                try writer.print("  store {s} %sparse_cv3, ptr %dst\n", .{sparse_carrier_llvm_type});
            } else {
                try writer.print("  %sparse_val = load {s}, ptr %value\n", .{sparse_carrier_llvm_type});
                try writer.print("  %sparse_data = extractvalue {s} %sparse_val, 0\n", .{sparse_carrier_llvm_type});
                try writer.print("  %sparse_occ = extractvalue {s} %sparse_val, 1\n", .{sparse_carrier_llvm_type});
                try writer.print("  %sparse_cap = extractvalue {s} %sparse_val, 3\n", .{sparse_carrier_llvm_type});
                try writer.writeAll("  %sparse_drop_index = alloca i64\n");
                try writer.writeAll("  store i64 0, ptr %sparse_drop_index\n");
                try writer.writeAll("  br label %sparse_drop_cond\n");
                try writer.writeAll("sparse_drop_cond:\n");
                try writer.writeAll("  %sparse_drop_i = load i64, ptr %sparse_drop_index\n");
                try writer.writeAll("  %sparse_drop_keep_going = icmp slt i64 %sparse_drop_i, %sparse_cap\n");
                try writer.writeAll("  br i1 %sparse_drop_keep_going, label %sparse_drop_check, label %sparse_drop_done\n");
                try writer.writeAll("sparse_drop_check:\n");
                try writer.writeAll("  %sparse_occ_slot = getelementptr inbounds i8, ptr %sparse_occ, i64 %sparse_drop_i\n");
                try writer.writeAll("  %sparse_occ_byte = load i8, ptr %sparse_occ_slot\n");
                try writer.writeAll("  %sparse_drop_present = icmp ne i8 %sparse_occ_byte, 0\n");
                try writer.writeAll("  br i1 %sparse_drop_present, label %sparse_drop_body, label %sparse_drop_next\n");
                try writer.writeAll("sparse_drop_body:\n");
                try writer.print("  %sparse_value_elem = getelementptr inbounds {s}, ptr %sparse_data, i64 %sparse_drop_i\n", .{elem_llvm});
                try writer.print("  %sparse_drop_slot = getelementptr inbounds {s}, ptr @{s}, i32 0, i32 {d}\n", .{ runtime_symbols.type_desc_llvm_type, elem_desc, type_desc_drop_field_index });
                try writer.writeAll("  %sparse_drop_fn = load ptr, ptr %sparse_drop_slot\n");
                try writer.print("  call void %sparse_drop_fn(ptr %sparse_value_elem, ptr @{s})\n", .{elem_desc});
                try writer.writeAll("  br label %sparse_drop_next\n");
                try writer.writeAll("sparse_drop_next:\n");
                try writer.writeAll("  %sparse_drop_next_i = add i64 %sparse_drop_i, 1\n");
                try writer.writeAll("  store i64 %sparse_drop_next_i, ptr %sparse_drop_index\n");
                try writer.writeAll("  br label %sparse_drop_cond\n");
                try writer.writeAll("sparse_drop_done:\n");
                try writer.writeAll("  %sparse_has_occ = icmp ne ptr %sparse_occ, null\n");
                try writer.writeAll("  br i1 %sparse_has_occ, label %sparse_drop_free_occ, label %sparse_drop_after_occ\n");
                try writer.writeAll("sparse_drop_free_occ:\n");
                try writer.writeAll("  call void @cyna_runtime_tracked_free(ptr %sparse_occ)\n");
                try writer.writeAll("  br label %sparse_drop_after_occ\n");
                try writer.writeAll("sparse_drop_after_occ:\n");
                try writer.writeAll("  %sparse_has_data = icmp ne ptr %sparse_data, null\n");
                try writer.writeAll("  br i1 %sparse_has_data, label %sparse_drop_free_data, label %sparse_drop_cont\n");
                try writer.writeAll("sparse_drop_free_data:\n");
                try writer.writeAll("  call void @cyna_runtime_tracked_free(ptr %sparse_data)\n");
                try writer.writeAll("  br label %sparse_drop_cont\n");
                try writer.writeAll("sparse_drop_cont:\n");
            }
        },
        .@"struct" => |struct_ty| {
            const struct_llvm = try types.llvmStructType(allocator, module, ty);
            defer allocator.free(struct_llvm);
            if (struct_ty.is_shared_value and struct_ty.shared_runtime == .arc) {
                if (struct_ty.fields.len != 1) return error.BackendInvariantViolation;
                const handle_llvm = try types.llvmStructType(allocator, module, struct_ty.fields[0].ty);
                defer allocator.free(handle_llvm);
                const source = if (is_copy) "%src" else "%value";
                try writer.print("  %arc_handle_ptr = getelementptr inbounds {s}, ptr {s}, i32 0, i32 0\n", .{ struct_llvm, source });
                try writer.print("  %arc_raw_ptr = getelementptr inbounds {s}, ptr %arc_handle_ptr, i32 0, i32 0\n", .{handle_llvm});
                try writer.writeAll("  %arc_raw = load i64, ptr %arc_raw_ptr\n");
                if (is_copy) {
                    try writer.print("  %arc_retained = call i64 @{s}(i64 %arc_raw)\n", .{runtime_symbols.name(.arc_retain)});
                    try writer.print("  %arc_dst_handle_ptr = getelementptr inbounds {s}, ptr %dst, i32 0, i32 0\n", .{struct_llvm});
                    try writer.print("  %arc_dst_raw_ptr = getelementptr inbounds {s}, ptr %arc_dst_handle_ptr, i32 0, i32 0\n", .{handle_llvm});
                    try writer.writeAll("  store i64 %arc_retained, ptr %arc_dst_raw_ptr\n");
                } else {
                    try writer.print("  %arc_release_status = call i64 @{s}(i64 %arc_raw)\n", .{runtime_symbols.name(.arc_release)});
                }
                return;
            }
            if (struct_ty.drop_runtime == .task_discard and is_copy) {
                // Affine task interest has no retain operation. Reaching a
                // descriptor copy is a compiler/runtime contract violation.
                try writer.writeAll("  call void @cyna_assert_fail()\n");
                return;
            }
            if (struct_ty.drop_runtime == .task_discard and !is_copy) {
                if (struct_ty.fields.len != 1) return error.BackendInvariantViolation;
                const handle_llvm = try types.llvmScalarType(allocator, module, struct_ty.fields[0].ty);
                defer allocator.free(handle_llvm);
                try writer.print("  %task_handle_ptr = getelementptr inbounds {s}, ptr %value, i32 0, i32 0\n", .{struct_llvm});
                try writer.print("  %task_handle = load {s}, ptr %task_handle_ptr\n", .{handle_llvm});
                try writer.print("  %task_discard_status = call i32 @cyna_std_thread_task_discard_raw({s} %task_handle)\n", .{handle_llvm});
                return;
            }
            if (struct_ty.is_packed) {
                if (is_copy) {
                    try writer.print("  %value = load {s}, ptr %src\n", .{struct_llvm});
                    try writer.print("  store {s} %value, ptr %dst\n", .{struct_llvm});
                }
                return;
            }
            for (struct_ty.fields, 0..) |field, i| {
                const field_desc = try backend_support.descriptorGlobalName(allocator, module, field.ty);
                defer allocator.free(field_desc);
                if (is_copy) {
                    try writer.print("  %dst_f{} = getelementptr inbounds {s}, ptr %dst, i32 0, i32 {}\n", .{ i, struct_llvm, i });
                    try writer.print("  %src_f{} = getelementptr inbounds {s}, ptr %src, i32 0, i32 {}\n", .{ i, struct_llvm, i });
                    try writer.print("  %copy_slot_{} = getelementptr inbounds {s}, ptr @{s}, i32 0, i32 {d}\n", .{ i, runtime_symbols.type_desc_llvm_type, field_desc, type_desc_copy_field_index });
                    try writer.print("  %copy_fn_{} = load ptr, ptr %copy_slot_{}\n", .{ i, i });
                    try writer.print("  call void %copy_fn_{}(ptr %dst_f{}, ptr %src_f{}, ptr @{s})\n", .{ i, i, i, field_desc });
                } else {
                    try writer.print("  %value_f{} = getelementptr inbounds {s}, ptr %value, i32 0, i32 {}\n", .{ i, struct_llvm, i });
                    try writer.print("  %drop_slot_{} = getelementptr inbounds {s}, ptr @{s}, i32 0, i32 {d}\n", .{ i, runtime_symbols.type_desc_llvm_type, field_desc, type_desc_drop_field_index });
                    try writer.print("  %drop_fn_{} = load ptr, ptr %drop_slot_{}\n", .{ i, i });
                    try writer.print("  call void %drop_fn_{}(ptr %value_f{}, ptr @{s})\n", .{ i, i, field_desc });
                }
            }
        },
        .@"union" => |union_ty| {
            const union_llvm = try types.llvmUnionType(allocator, module, ty);
            defer allocator.free(union_llvm);
            if (is_copy) {
                try writer.print("  %src_val = load {s}, ptr %src\n", .{union_llvm});
                try writer.print("  %src_tag = extractvalue {s} %src_val, 0\n", .{union_llvm});
                try writer.writeAll("  store i64 %src_tag, ptr %dst\n");
                try writer.writeAll("  switch i64 %src_tag, label %copy_union_cont [\n");
                for (union_ty.payloads, 0..) |_, i| {
                    try writer.print("    i64 {} , label %copy_union_case_{}\n", .{ i, i });
                }
                try writer.writeAll("  ]\n");
                for (union_ty.payloads, 0..) |payload_ty, i| {
                    try writer.print("copy_union_case_{}:\n", .{i});
                    if (payload_ty) |field_ty| {
                        const field_desc = try backend_support.descriptorGlobalName(allocator, module, field_ty);
                        defer allocator.free(field_desc);
                        try writer.print("  %dst_u{} = getelementptr inbounds {s}, ptr %dst, i32 0, i32 {}\n", .{ i, union_llvm, i + 1 });
                        try writer.print("  %src_u{} = getelementptr inbounds {s}, ptr %src, i32 0, i32 {}\n", .{ i, union_llvm, i + 1 });
                        try writer.print("  %copy_union_slot_{} = getelementptr inbounds {s}, ptr @{s}, i32 0, i32 {d}\n", .{ i, runtime_symbols.type_desc_llvm_type, field_desc, type_desc_copy_field_index });
                        try writer.print("  %copy_union_fn_{} = load ptr, ptr %copy_union_slot_{}\n", .{ i, i });
                        try writer.print("  call void %copy_union_fn_{}(ptr %dst_u{}, ptr %src_u{}, ptr @{s})\n", .{ i, i, i, field_desc });
                    } else {
                        try writer.print("  %dst_u{} = getelementptr inbounds {s}, ptr %dst, i32 0, i32 {}\n", .{ i, union_llvm, i + 1 });
                        try writer.writeAll("  store i8 0, ptr %dst_u");
                        try writer.print("{}\n", .{i});
                    }
                    try writer.writeAll("  br label %copy_union_cont\n");
                }
                try writer.writeAll("copy_union_cont:\n");
            } else {
                try writer.print("  %union_val = load {s}, ptr %value\n", .{union_llvm});
                try writer.print("  %union_tag = extractvalue {s} %union_val, 0\n", .{union_llvm});
                try writer.writeAll("  switch i64 %union_tag, label %drop_union_cont [\n");
                for (union_ty.payloads, 0..) |_, i| {
                    try writer.print("    i64 {} , label %drop_union_case_{}\n", .{ i, i });
                }
                try writer.writeAll("  ]\n");
                for (union_ty.payloads, 0..) |payload_ty, i| {
                    try writer.print("drop_union_case_{}:\n", .{i});
                    if (payload_ty) |field_ty| {
                        const field_desc = try backend_support.descriptorGlobalName(allocator, module, field_ty);
                        defer allocator.free(field_desc);
                        try writer.print("  %value_u{} = getelementptr inbounds {s}, ptr %value, i32 0, i32 {}\n", .{ i, union_llvm, i + 1 });
                        try writer.print("  %drop_union_slot_{} = getelementptr inbounds {s}, ptr @{s}, i32 0, i32 {d}\n", .{ i, runtime_symbols.type_desc_llvm_type, field_desc, type_desc_drop_field_index });
                        try writer.print("  %drop_union_fn_{} = load ptr, ptr %drop_union_slot_{}\n", .{ i, i });
                        try writer.print("  call void %drop_union_fn_{}(ptr %value_u{}, ptr @{s})\n", .{ i, i, field_desc });
                    }
                    try writer.writeAll("  br label %drop_union_cont\n");
                }
                try writer.writeAll("drop_union_cont:\n");
            }
        },
        else => return error.BackendInvariantViolation,
    }
}

fn findFunctionByAbiName(module: lir.Module, name: []const u8) ?lir.Function {
    for (module.functions) |function| {
        if (function.abi_name) |abi_name| {
            if (std.mem.eql(u8, abi_name, name)) return function;
        }
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

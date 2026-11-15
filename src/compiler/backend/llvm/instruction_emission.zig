const std = @import("std");
const abi = @import("abi.zig");
const common = @import("common.zig");
const backend_support = @import("../support.zig");
const capability = @import("../../capability.zig");
const runtime_symbols = @import("../../../runtime/symbols.zig");
const llvm_support = @import("support.zig");
const types = @import("types.zig");
const lir = @import("../../lower/lir.zig");

pub const Error = common.Error;

const dense_carrier_llvm_type = runtime_symbols.dense_carrier_llvm_type;
const sparse_carrier_llvm_type = runtime_symbols.sparse_carrier_llvm_type;
const dense_runtime_llvm_type = runtime_symbols.dense_runtime_llvm_type;
const sparse_runtime_llvm_type = runtime_symbols.sparse_runtime_llvm_type;
const type_desc_copy_field_index = @backingInt(runtime_symbols.TypeDescField.copy);
const type_desc_drop_field_index = @backingInt(runtime_symbols.TypeDescField.drop);
const allocation_site_file_global = ".cyna.alloc.file";

fn emitTrackedAllocCall(writer: anytype, dest_id: u32, size_ref: []const u8, line: u32, kind_global: []const u8) Error!void {
    try writer.print("  %v{} = call ptr @cyna_runtime_tracked_alloc_site(i64 {s}, ptr @{s}, i64 {}, ptr @{s})\n", .{
        dest_id, size_ref, allocation_site_file_global, line, kind_global,
    });
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

fn nextTempId(next_temp_id: *u32) u32 {
    const id = next_temp_id.*;
    next_temp_id.* += 1;
    return id;
}

fn emitTypeAlignment(writer: anytype, module: lir.Module, ty: lir.TypeId) Error!void {
    const sa = try abi.typeSizeAlign(module, ty);
    try writer.print(", align {}", .{sa.abi_align});
}

fn emitStructuralCopyViaDescriptor(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    info: []const common.ValueInfo,
    next_temp_id: *u32,
    result_id: u32,
    value: lir.BinaryValue,
) Error!void {
    const ty = info[value.lhs].ty orelse return error.BackendInvariantViolation;
    const llvm_ty = try types.llvmScalarType(allocator, module, ty);
    defer allocator.free(llvm_ty);
    const copy_name = try backend_support.descriptorCopyName(allocator, module, ty);
    defer allocator.free(copy_name);

    const dst_ptr_id = nextTempId(next_temp_id);
    const src_ptr_id = nextTempId(next_temp_id);
    try writer.print("  %v{} = alloca {s}\n", .{ dst_ptr_id, llvm_ty });
    try writer.print("  %v{} = alloca {s}\n", .{ src_ptr_id, llvm_ty });
    try writer.print("  store {s} ", .{llvm_ty});
    try common.writeValueRef(writer, module, info, value.lhs);
    try writer.print(", ptr %v{}", .{src_ptr_id});
    try emitTypeAlignment(writer, module, ty);
    try writer.writeByte('\n');
    try writer.print("  call void @{s}(ptr %v{}, ptr %v{}, ptr ", .{ copy_name, dst_ptr_id, src_ptr_id });
    try common.writeValueRef(writer, module, info, value.rhs);
    try writer.writeAll(")\n");
    try writer.print("  %v{} = load {s}, ptr %v{}", .{ result_id, llvm_ty, dst_ptr_id });
    try emitTypeAlignment(writer, module, ty);
    try writer.writeByte('\n');
}

fn emitStructuralDropViaDescriptor(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    info: []const common.ValueInfo,
    next_temp_id: *u32,
    value: lir.BinaryValue,
) Error!void {
    const ty = info[value.lhs].ty orelse return error.BackendInvariantViolation;
    const llvm_ty = try types.llvmScalarType(allocator, module, ty);
    defer allocator.free(llvm_ty);
    const drop_name = try backend_support.descriptorDropName(allocator, module, ty);
    defer allocator.free(drop_name);

    const value_ptr_id = nextTempId(next_temp_id);
    try writer.print("  %v{} = alloca {s}\n", .{ value_ptr_id, llvm_ty });
    try writer.print("  store {s} ", .{llvm_ty});
    try common.writeValueRef(writer, module, info, value.lhs);
    try writer.print(", ptr %v{}", .{value_ptr_id});
    try emitTypeAlignment(writer, module, ty);
    try writer.writeByte('\n');
    try writer.print("  call void @{s}(ptr %v{}, ptr ", .{ drop_name, value_ptr_id });
    try common.writeValueRef(writer, module, info, value.rhs);
    try writer.writeAll(")\n");
}

fn emitDropStoredValueByDescriptor(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    ty: lir.TypeId,
    ptr_id: u32,
) Error!void {
    const drop_name = try backend_support.descriptorDropName(allocator, module, ty);
    defer allocator.free(drop_name);
    const desc_name = try backend_support.descriptorGlobalName(allocator, module, ty);
    defer allocator.free(desc_name);
    try writer.print("  call void @{s}(ptr %v{}, ptr @{s})\n", .{ drop_name, ptr_id, desc_name });
}

fn emitDenseCarrierFromSparseIndices(writer: anytype, allocator: std.mem.Allocator, module: lir.Module, info: []const common.ValueInfo, next_temp_id: *u32, result_id: u32, carrier_value: lir.ValueId, desc: lir.ValueId) Error!void {
    const data_id = nextTempId(next_temp_id);
    const occ_id = nextTempId(next_temp_id);
    const len_id = nextTempId(next_temp_id);
    const cap_id = nextTempId(next_temp_id);
    const has_len_id = nextTempId(next_temp_id);
    const alloc_label = try std.fmt.allocPrint(allocator, "sparse_indices_alloc_{}", .{result_id});
    defer allocator.free(alloc_label);
    const zero_label = try std.fmt.allocPrint(allocator, "sparse_indices_zero_{}", .{result_id});
    defer allocator.free(zero_label);
    const loop_label = try std.fmt.allocPrint(allocator, "sparse_indices_loop_{}", .{result_id});
    defer allocator.free(loop_label);
    const body_label = try std.fmt.allocPrint(allocator, "sparse_indices_body_{}", .{result_id});
    defer allocator.free(body_label);
    const skip_label = try std.fmt.allocPrint(allocator, "sparse_indices_skip_{}", .{result_id});
    defer allocator.free(skip_label);
    const done_label = try std.fmt.allocPrint(allocator, "sparse_indices_done_{}", .{result_id});
    defer allocator.free(done_label);
    const index_elem_ty = switch (module.types[info[result_id].ty orelse return error.BackendInvariantViolation]) {
        .dense_array => |item_ty| item_ty,
        else => return error.BackendInvariantViolation,
    };
    const index_elem_size = (try abi.typeSizeAlign(module, index_elem_ty)).size;
    const out_data_id = nextTempId(next_temp_id);
    const alloc_bytes_id = nextTempId(next_temp_id);
    const index_ptr_id = nextTempId(next_temp_id);
    const out_ptr_id = nextTempId(next_temp_id);
    const i_id = nextTempId(next_temp_id);
    const keep_id = nextTempId(next_temp_id);
    const occ_slot_id = nextTempId(next_temp_id);
    const occ_byte_id = nextTempId(next_temp_id);
    const present_id = nextTempId(next_temp_id);
    const out_i_id = nextTempId(next_temp_id);
    const dst_elem_id = nextTempId(next_temp_id);
    const out_next_id = nextTempId(next_temp_id);
    const i_next_id = nextTempId(next_temp_id);
    const out_phi_id = nextTempId(next_temp_id);
    const cv0_id = nextTempId(next_temp_id);
    const cv1_id = nextTempId(next_temp_id);

    try writer.print("  %v{} = extractvalue {s} ", .{ data_id, sparse_carrier_llvm_type });
    try common.writeValueRef(writer, module, info, carrier_value);
    try writer.writeAll(", 0\n");
    try writer.print("  %v{} = extractvalue {s} ", .{ occ_id, sparse_carrier_llvm_type });
    try common.writeValueRef(writer, module, info, carrier_value);
    try writer.writeAll(", 1\n");
    try writer.print("  %v{} = extractvalue {s} ", .{ len_id, sparse_carrier_llvm_type });
    try common.writeValueRef(writer, module, info, carrier_value);
    try writer.writeAll(", 2\n");
    try writer.print("  %v{} = extractvalue {s} ", .{ cap_id, sparse_carrier_llvm_type });
    try common.writeValueRef(writer, module, info, carrier_value);
    try writer.writeAll(", 3\n");
    try writer.print("  %v{} = icmp ne i64 %v{}, 0\n", .{ has_len_id, len_id });
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ has_len_id, alloc_label, zero_label });
    try writer.print("{s}:\n", .{zero_label});
    try writer.print("  br label %{s}\n", .{done_label});
    try writer.print("{s}:\n", .{alloc_label});
    try writer.print("  %v{} = mul i64 %v{}, {}\n", .{ alloc_bytes_id, len_id, index_elem_size });
    const sparse_indices_size = try std.fmt.allocPrint(allocator, "%v{}", .{alloc_bytes_id});
    defer allocator.free(sparse_indices_size);
    try emitTrackedAllocCall(writer, out_data_id, sparse_indices_size, 1243, ".cyna.alloc.sparse.indices.data");
    try writer.print("  %v{} = alloca i64\n", .{index_ptr_id});
    try writer.writeAll("  store i64 0, ptr ");
    try writer.print("%v{}\n", .{index_ptr_id});
    try writer.print("  %v{} = alloca i64\n", .{out_ptr_id});
    try writer.writeAll("  store i64 0, ptr ");
    try writer.print("%v{}\n", .{out_ptr_id});
    try writer.print("  br label %{s}\n", .{loop_label});
    try writer.print("{s}:\n", .{loop_label});
    try writer.print("  %v{} = load i64, ptr %v{}\n", .{ i_id, index_ptr_id });
    try writer.print("  %v{} = icmp slt i64 %v{}, %v{}\n", .{ keep_id, i_id, cap_id });
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ keep_id, body_label, done_label });
    try writer.print("{s}:\n", .{body_label});
    try writer.print("  %v{} = getelementptr inbounds i8, ptr %v{}, i64 %v{}\n", .{ occ_slot_id, occ_id, i_id });
    try writer.print("  %v{} = load i8, ptr %v{}\n", .{ occ_byte_id, occ_slot_id });
    try writer.print("  %v{} = icmp ne i8 %v{}, 0\n", .{ present_id, occ_byte_id });
    try writer.print("  br i1 %v{}, label %sparse_indices_copy_{}, label %{s}\n", .{ present_id, result_id, skip_label });
    try writer.print("sparse_indices_copy_{}:\n", .{result_id});
    try writer.print("  %v{} = load i64, ptr %v{}\n", .{ out_i_id, out_ptr_id });
    try writer.print("  %v{} = getelementptr inbounds i64, ptr %v{}, i64 %v{}\n", .{ dst_elem_id, out_data_id, out_i_id });
    try writer.print("  store i64 %v{}, ptr %v{}\n", .{ i_id, dst_elem_id });
    try writer.print("  %v{} = add i64 %v{}, 1\n", .{ out_next_id, out_i_id });
    try writer.print("  store i64 %v{}, ptr %v{}\n", .{ out_next_id, out_ptr_id });
    try writer.print("  br label %{s}\n", .{skip_label});
    try writer.print("{s}:\n", .{skip_label});
    try writer.print("  %v{} = add i64 %v{}, 1\n", .{ i_next_id, i_id });
    try writer.print("  store i64 %v{}, ptr %v{}\n", .{ i_next_id, index_ptr_id });
    try writer.print("  br label %{s}\n", .{loop_label});
    try writer.print("{s}:\n", .{done_label});
    try writer.print("  %v{} = phi ptr [ null, %{s} ], [ %v{}, %{s} ]\n", .{ out_phi_id, zero_label, out_data_id, loop_label });
    try writer.print("  %v{} = insertvalue {s} undef, ptr %v{}, 0\n", .{ cv0_id, dense_carrier_llvm_type, out_phi_id });
    try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 1\n", .{ cv1_id, dense_carrier_llvm_type, cv0_id, len_id });
    try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 2\n", .{ result_id, dense_carrier_llvm_type, cv1_id, len_id });
    _ = desc;
}

fn emitSparseTakeMutation(writer: anytype, allocator: std.mem.Allocator, module: lir.Module, info: []const common.ValueInfo, next_temp_id: *u32, result_id: u32, value: lir.QuaternaryValue) Error!void {
    const elem_ty = try types.llvmPointeeType(allocator, module, info, value.c);
    defer allocator.free(elem_ty);
    const carrier_id = nextTempId(next_temp_id);
    const data_id = nextTempId(next_temp_id);
    const occ_id = nextTempId(next_temp_id);
    const len_id = nextTempId(next_temp_id);
    const cap_id = nextTempId(next_temp_id);
    const neg_id = nextTempId(next_temp_id);
    const hi_id = nextTempId(next_temp_id);
    const oob_id = nextTempId(next_temp_id);
    const occ_slot_id = nextTempId(next_temp_id);
    const occ_byte_id = nextTempId(next_temp_id);
    const present_id = nextTempId(next_temp_id);
    const elem_ptr_id = nextTempId(next_temp_id);
    const elem_val_id = nextTempId(next_temp_id);
    const len_dec_id = nextTempId(next_temp_id);
    const occ_cleared_id = nextTempId(next_temp_id);
    const cv0_id = nextTempId(next_temp_id);
    const fail_label = try std.fmt.allocPrint(allocator, "sparse_take_fail_{}", .{result_id});
    defer allocator.free(fail_label);
    const check_label = try std.fmt.allocPrint(allocator, "sparse_take_check_{}", .{result_id});
    defer allocator.free(check_label);
    const some_label = try std.fmt.allocPrint(allocator, "sparse_take_some_{}", .{result_id});
    defer allocator.free(some_label);
    const none_label = try std.fmt.allocPrint(allocator, "sparse_take_none_{}", .{result_id});
    defer allocator.free(none_label);
    const done_label = try std.fmt.allocPrint(allocator, "sparse_take_done_{}", .{result_id});
    defer allocator.free(done_label);

    try writer.print("  %v{} = load {s}, ptr ", .{ carrier_id, sparse_carrier_llvm_type });
    try common.writeValueRef(writer, module, info, value.a);
    try writer.writeByte('\n');
    try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ data_id, sparse_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 1\n", .{ occ_id, sparse_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 2\n", .{ len_id, sparse_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 3\n", .{ cap_id, sparse_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = icmp slt i64 ", .{neg_id});
    try common.writeValueRef(writer, module, info, value.b);
    try writer.writeAll(", 0\n");
    try writer.print("  %v{} = icmp sge i64 ", .{hi_id});
    try common.writeValueRef(writer, module, info, value.b);
    try writer.print(", %v{}\n", .{cap_id});
    try writer.print("  %v{} = or i1 %v{}, %v{}\n", .{ oob_id, neg_id, hi_id });
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ oob_id, fail_label, check_label });
    try writer.print("{s}:\n", .{fail_label});
    try writer.print("  call void @{s}(i64 ", .{runtime_symbols.bounds_fail_symbol});
    try common.writeValueRef(writer, module, info, value.b);
    try writer.print(", i64 %v{})\n", .{cap_id});
    try writer.writeAll("  unreachable\n");
    try writer.print("{s}:\n", .{check_label});
    try writer.print("  %v{} = getelementptr inbounds i8, ptr %v{}, i64 ", .{ occ_slot_id, occ_id });
    try common.writeValueRef(writer, module, info, value.b);
    try writer.writeByte('\n');
    try writer.print("  %v{} = load i8, ptr %v{}\n", .{ occ_byte_id, occ_slot_id });
    try writer.print("  %v{} = icmp ne i8 %v{}, 0\n", .{ present_id, occ_byte_id });
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ present_id, some_label, none_label });
    try writer.print("{s}:\n", .{some_label});
    try writer.print("  %v{} = getelementptr inbounds {s}, ptr %v{}, i64 ", .{ elem_ptr_id, elem_ty, data_id });
    try common.writeValueRef(writer, module, info, value.b);
    try writer.writeByte('\n');
    try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ elem_val_id, elem_ty, elem_ptr_id });
    try writer.print("  store {s} %v{}, ptr ", .{ elem_ty, elem_val_id });
    try common.writeValueRef(writer, module, info, value.c);
    try writer.writeByte('\n');
    try writer.writeAll("  store i8 0, ptr ");
    try writer.print("%v{}\n", .{occ_slot_id});
    try writer.print("  %v{} = sub i64 %v{}, 1\n", .{ len_dec_id, len_id });
    try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 2\n", .{ occ_cleared_id, sparse_carrier_llvm_type, carrier_id, len_dec_id });
    try writer.print("  %v{} = insertvalue {s} %v{}, ptr %v{}, 1\n", .{ cv0_id, sparse_carrier_llvm_type, occ_cleared_id, occ_id });
    try writer.print("  store {s} %v{}, ptr ", .{ sparse_carrier_llvm_type, cv0_id });
    try common.writeValueRef(writer, module, info, value.a);
    try writer.writeByte('\n');
    try writer.print("  br label %{s}\n", .{done_label});
    try writer.print("{s}:\n", .{none_label});
    try writer.print("  br label %{s}\n", .{done_label});
    try writer.print("{s}:\n", .{done_label});
    try writer.print("  %v{} = phi i1 [ true, %{s} ], [ false, %{s} ]\n", .{ result_id, some_label, none_label });
}

fn emitSparsePayloadPtr(writer: anytype, allocator: std.mem.Allocator, module: lir.Module, info: []const common.ValueInfo, result_id: u32, value: lir.BinaryValue) Error!void {
    const elem_ty = try types.llvmPointeeType(allocator, module, info, result_id);
    defer allocator.free(elem_ty);
    try writer.print("  %v{}_data = extractvalue {s} ", .{ result_id, sparse_carrier_llvm_type });
    try common.writeValueRef(writer, module, info, value.lhs);
    try writer.writeAll(", 0\n");
    try writer.print("  %v{}_cap = extractvalue {s} ", .{ result_id, sparse_carrier_llvm_type });
    try common.writeValueRef(writer, module, info, value.lhs);
    try writer.writeAll(", 3\n");
    try writer.print("  %v{}_neg = icmp slt i64 ", .{result_id});
    try common.writeValueRef(writer, module, info, value.rhs);
    try writer.writeAll(", 0\n");
    try writer.print("  %v{}_hi = icmp sge i64 ", .{result_id});
    try common.writeValueRef(writer, module, info, value.rhs);
    try writer.print(", %v{}_cap\n", .{result_id});
    try writer.print("  %v{}_oob = or i1 %v{}_neg, %v{}_hi\n", .{ result_id, result_id, result_id });
    try writer.print("  br i1 %v{}_oob, label %sparse_payload_ptr_fail_{}, label %sparse_payload_ptr_ok_{}\n", .{ result_id, result_id, result_id });
    try writer.print("sparse_payload_ptr_fail_{}:\n", .{result_id});
    try writer.print("  call void @{s}(i64 ", .{runtime_symbols.bounds_fail_symbol});
    try common.writeValueRef(writer, module, info, value.rhs);
    try writer.print(", i64 %v{}_cap)\n", .{result_id});
    try writer.writeAll("  unreachable\n");
    try writer.print("sparse_payload_ptr_ok_{}:\n", .{result_id});
    try writer.print("  %v{} = getelementptr inbounds {s}, ptr %v{}_data, i64 ", .{ result_id, elem_ty, result_id });
    try common.writeValueRef(writer, module, info, value.rhs);
    try writer.writeByte('\n');
}

fn emitDensePushMutation(writer: anytype, allocator: std.mem.Allocator, module: lir.Module, info: []const common.ValueInfo, next_temp_id: *u32, value: lir.TernaryValue, comptime move: bool) Error!void {
    const elem_ty = try types.llvmPointeeType(allocator, module, info, value.b);
    defer allocator.free(elem_ty);
    const before_id = nextTempId(next_temp_id);
    const before_len_id = nextTempId(next_temp_id);
    const len_overflow_id = nextTempId(next_temp_id);
    const want_id = nextTempId(next_temp_id);
    try writer.print("  %v{} = load {s}, ptr ", .{ before_id, dense_carrier_llvm_type });
    try common.writeValueRef(writer, module, info, value.a);
    try writer.writeByte('\n');
    try writer.print("  %v{} = extractvalue {s} %v{}, 1\n", .{ before_len_id, dense_carrier_llvm_type, before_id });
    try writer.print("  %v{} = icmp eq i64 %v{}, 9223372036854775807\n", .{ len_overflow_id, before_len_id });
    try writer.print("  br i1 %v{}, label %dense_push_len_overflow_{}, label %dense_push_len_ok_{}\n", .{ len_overflow_id, before_id, before_id });
    try writer.print("dense_push_len_overflow_{}:\n", .{before_id});
    try writer.print("  call void @{s}(i64 -1, i64 9223372036854775807)\n", .{runtime_symbols.capacity_fail_symbol});
    try writer.writeAll("  unreachable\n");
    try writer.print("dense_push_len_ok_{}:\n", .{before_id});
    try writer.print("  %v{} = add i64 %v{}, 1\n", .{ want_id, before_len_id });
    try emitDenseReserveMutation(writer, allocator, module, info, next_temp_id, value, want_id);
    const carrier_id = nextTempId(next_temp_id);
    const data_id = nextTempId(next_temp_id);
    const len_id = nextTempId(next_temp_id);
    const cap_id = nextTempId(next_temp_id);
    const oob_id = nextTempId(next_temp_id);
    const slot_id = nextTempId(next_temp_id);
    const copy_slot_id = if (move) 0 else nextTempId(next_temp_id);
    const copy_fn_id = if (move) 0 else nextTempId(next_temp_id);
    const len_inc_id = nextTempId(next_temp_id);
    const cv0_id = nextTempId(next_temp_id);
    const cv1_id = nextTempId(next_temp_id);
    const fail_label = try std.fmt.allocPrint(allocator, "dense_push_fail_{}", .{carrier_id});
    defer allocator.free(fail_label);
    const ok_label = try std.fmt.allocPrint(allocator, "dense_push_ok_{}", .{carrier_id});
    defer allocator.free(ok_label);

    try writer.print("  %v{} = load {s}, ptr ", .{ carrier_id, dense_carrier_llvm_type });
    try common.writeValueRef(writer, module, info, value.a);
    try writer.writeByte('\n');
    try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ data_id, dense_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 1\n", .{ len_id, dense_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 2\n", .{ cap_id, dense_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = icmp sge i64 %v{}, %v{}\n", .{ oob_id, len_id, cap_id });
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ oob_id, fail_label, ok_label });
    try writer.print("{s}:\n", .{fail_label});
    try writer.print("  call void @{s}(i64 %v{}, i64 %v{})\n", .{ runtime_symbols.capacity_fail_symbol, want_id, cap_id });
    try writer.writeAll("  unreachable\n");
    try writer.print("{s}:\n", .{ok_label});
    try writer.print("  %v{} = getelementptr inbounds {s}, ptr %v{}, i64 %v{}\n", .{ slot_id, elem_ty, data_id, len_id });
    if (move) {
        const loaded_id = nextTempId(next_temp_id);
        try writer.print("  %v{} = load {s}, ptr ", .{ loaded_id, elem_ty });
        try common.writeValueRef(writer, module, info, value.b);
        try writer.writeByte('\n');
        try writer.print("  store {s} %v{}, ptr %v{}\n", .{ elem_ty, loaded_id, slot_id });
    } else {
        try writer.print("  %v{} = getelementptr inbounds {s}, ptr ", .{ copy_slot_id, runtime_symbols.type_desc_llvm_type });
        try common.writeValueRef(writer, module, info, value.c);
        try writer.print(", i32 0, i32 {d}\n", .{type_desc_copy_field_index});
        try writer.print("  %v{} = load ptr, ptr %v{}\n", .{ copy_fn_id, copy_slot_id });
        try writer.print("  call void %v{}(ptr %v{}, ptr ", .{ copy_fn_id, slot_id });
        try common.writeValueRef(writer, module, info, value.b);
        try writer.writeAll(", ptr ");
        try common.writeValueRef(writer, module, info, value.c);
        try writer.writeAll(")\n");
    }
    try writer.print("  %v{} = add i64 %v{}, 1\n", .{ len_inc_id, len_id });
    try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 1\n", .{ cv0_id, dense_carrier_llvm_type, carrier_id, len_inc_id });
    try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 2\n", .{ cv1_id, dense_carrier_llvm_type, cv0_id, cap_id });
    try writer.print("  store {s} %v{}, ptr ", .{ dense_carrier_llvm_type, cv1_id });
    try common.writeValueRef(writer, module, info, value.a);
    try writer.writeByte('\n');
}

fn emitDensePopMutation(writer: anytype, allocator: std.mem.Allocator, module: lir.Module, info: []const common.ValueInfo, next_temp_id: *u32, value: lir.TernaryValue) Error!void {
    const elem_ty = try types.llvmPointeeType(allocator, module, info, value.b);
    defer allocator.free(elem_ty);
    const carrier_id = nextTempId(next_temp_id);
    const data_id = nextTempId(next_temp_id);
    const len_id = nextTempId(next_temp_id);
    const cap_id = nextTempId(next_temp_id);
    const is_empty_id = nextTempId(next_temp_id);
    const len_dec_id = nextTempId(next_temp_id);
    const slot_id = nextTempId(next_temp_id);
    const elem_val_id = nextTempId(next_temp_id);
    const cv0_id = nextTempId(next_temp_id);
    const cv1_id = nextTempId(next_temp_id);
    const fail_label = try std.fmt.allocPrint(allocator, "dense_pop_fail_{}", .{carrier_id});
    defer allocator.free(fail_label);
    const ok_label = try std.fmt.allocPrint(allocator, "dense_pop_ok_{}", .{carrier_id});
    defer allocator.free(ok_label);

    try writer.print("  %v{} = load {s}, ptr ", .{ carrier_id, dense_carrier_llvm_type });
    try common.writeValueRef(writer, module, info, value.a);
    try writer.writeByte('\n');
    try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ data_id, dense_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 1\n", .{ len_id, dense_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 2\n", .{ cap_id, dense_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = icmp eq i64 %v{}, 0\n", .{ is_empty_id, len_id });
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ is_empty_id, fail_label, ok_label });
    try writer.print("{s}:\n", .{fail_label});
    try writer.print("  call void @{s}()\n", .{runtime_symbols.assert_fail_symbol});
    try writer.writeAll("  unreachable\n");
    try writer.print("{s}:\n", .{ok_label});
    try writer.print("  %v{} = sub i64 %v{}, 1\n", .{ len_dec_id, len_id });
    try writer.print("  %v{} = getelementptr inbounds {s}, ptr %v{}, i64 %v{}\n", .{ slot_id, elem_ty, data_id, len_dec_id });
    try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ elem_val_id, elem_ty, slot_id });
    try writer.print("  store {s} %v{}, ptr ", .{ elem_ty, elem_val_id });
    try common.writeValueRef(writer, module, info, value.b);
    try writer.writeByte('\n');
    try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 1\n", .{ cv0_id, dense_carrier_llvm_type, carrier_id, len_dec_id });
    try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 2\n", .{ cv1_id, dense_carrier_llvm_type, cv0_id, cap_id });
    try writer.print("  store {s} %v{}, ptr ", .{ dense_carrier_llvm_type, cv1_id });
    try common.writeValueRef(writer, module, info, value.a);
    try writer.writeByte('\n');
}

fn storageSemanticType(module: lir.Module, info: []const common.ValueInfo, storage_value: lir.ValueId) Error!lir.TypeId {
    if (info[storage_value].pointee) |storage_ty| return storage_ty;
    const value_ty = info[storage_value].ty orelse return error.BackendInvariantViolation;
    return switch (module.types[value_ty]) {
        .pointer => |child| child,
        .dense_array, .sparse_array => value_ty,
        else => return error.BackendInvariantViolation,
    };
}

fn storageElementType(allocator: std.mem.Allocator, module: lir.Module, info: []const common.ValueInfo, storage_value: lir.ValueId) Error![]u8 {
    const storage_ty = try storageSemanticType(module, info, storage_value);
    const elem_ty = switch (module.types[storage_ty]) {
        .dense_array => |item_ty| item_ty,
        .sparse_array => |item_ty| item_ty,
        else => return error.BackendInvariantViolation,
    };
    return types.llvmScalarType(allocator, module, elem_ty);
}

fn emitDenseReserveMutation(writer: anytype, allocator: std.mem.Allocator, module: lir.Module, info: []const common.ValueInfo, next_temp_id: *u32, value: lir.TernaryValue, want_override: ?u32) Error!void {
    const elem_ty = try storageElementType(allocator, module, info, value.a);
    defer allocator.free(elem_ty);
    const elem_sem_ty = switch (module.types[try storageSemanticType(module, info, value.a)]) {
        .dense_array => |item_ty| item_ty,
        else => return error.BackendInvariantViolation,
    };
    const elem_size = (try abi.typeSizeAlign(module, elem_sem_ty)).size;
    const carrier_id = nextTempId(next_temp_id);
    const data_id = nextTempId(next_temp_id);
    const len_id = nextTempId(next_temp_id);
    const cap_id = nextTempId(next_temp_id);
    const no_grow_id = nextTempId(next_temp_id);
    const want_ok_id = nextTempId(next_temp_id);
    const fail_label = try std.fmt.allocPrint(allocator, "dense_reserve_fail_{}", .{carrier_id});
    defer allocator.free(fail_label);
    const done_label = try std.fmt.allocPrint(allocator, "dense_reserve_done_{}", .{carrier_id});
    defer allocator.free(done_label);
    const grow_check_label = try std.fmt.allocPrint(allocator, "dense_reserve_grow_check_{}", .{carrier_id});
    defer allocator.free(grow_check_label);
    const loop_label = try std.fmt.allocPrint(allocator, "dense_reserve_nextcap_{}", .{carrier_id});
    defer allocator.free(loop_label);
    const alloc_label = try std.fmt.allocPrint(allocator, "dense_reserve_alloc_{}", .{carrier_id});
    defer allocator.free(alloc_label);
    const copy_cond_label = try std.fmt.allocPrint(allocator, "dense_reserve_copy_cond_{}", .{carrier_id});
    defer allocator.free(copy_cond_label);
    const copy_body_label = try std.fmt.allocPrint(allocator, "dense_reserve_copy_body_{}", .{carrier_id});
    defer allocator.free(copy_body_label);
    const copy_done_label = try std.fmt.allocPrint(allocator, "dense_reserve_copy_done_{}", .{carrier_id});
    defer allocator.free(copy_done_label);
    const next_cap_ptr_id = nextTempId(next_temp_id);
    const next_seed_id = nextTempId(next_temp_id);
    const loop_cap_id = nextTempId(next_temp_id);
    const next_keep_id = nextTempId(next_temp_id);
    const doubled_id = nextTempId(next_temp_id);
    const alloc_cap_id = nextTempId(next_temp_id);
    const alloc_bytes_id = nextTempId(next_temp_id);
    const new_data_id = nextTempId(next_temp_id);
    const index_ptr_id = nextTempId(next_temp_id);
    const index_id = nextTempId(next_temp_id);
    const copy_keep_id = nextTempId(next_temp_id);
    const dst_elem_id = nextTempId(next_temp_id);
    const src_elem_id = nextTempId(next_temp_id);
    const elem_val_id = nextTempId(next_temp_id);
    const index_next_id = nextTempId(next_temp_id);
    const has_old_data_id = nextTempId(next_temp_id);
    const grown0_id = nextTempId(next_temp_id);
    const grown1_id = nextTempId(next_temp_id);

    try writer.print("  %v{} = load {s}, ptr ", .{ carrier_id, dense_carrier_llvm_type });
    try common.writeValueRef(writer, module, info, value.a);
    try writer.writeByte('\n');
    try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ data_id, dense_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 1\n", .{ len_id, dense_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 2\n", .{ cap_id, dense_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = icmp sle i64 ", .{no_grow_id});
    if (want_override) |id| try writer.print("%v{}", .{id}) else try common.writeValueRef(writer, module, info, value.b);
    try writer.print(", %v{}\n", .{cap_id});
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ no_grow_id, done_label, grow_check_label });
    try writer.print("{s}:\n", .{grow_check_label});
    try writer.print("  %v{} = icmp sge i64 ", .{want_ok_id});
    if (want_override) |id| try writer.print("%v{}", .{id}) else try common.writeValueRef(writer, module, info, value.b);
    try writer.writeAll(", 0\n");
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ want_ok_id, loop_label, fail_label });
    try writer.print("{s}:\n", .{fail_label});
    try writer.print("  call void @{s}(i64 ", .{runtime_symbols.capacity_fail_symbol});
    if (want_override) |id| try writer.print("%v{}", .{id}) else try common.writeValueRef(writer, module, info, value.b);
    try writer.print(", i64 %v{})\n", .{cap_id});
    try writer.writeAll("  unreachable\n");
    try writer.print("{s}:\n", .{loop_label});
    try writer.print("  %v{} = alloca i64\n", .{next_cap_ptr_id});
    try writer.print("  %v{} = icmp eq i64 %v{}, 0\n", .{ next_seed_id, cap_id });
    try writer.print("  br i1 %v{}, label %dense_reserve_seed_zero_{}, label %dense_reserve_seed_cap_{}\n", .{ next_seed_id, carrier_id, carrier_id });
    try writer.print("dense_reserve_seed_zero_{}:\n", .{carrier_id});
    try writer.print("  store i64 4, ptr %v{}\n", .{next_cap_ptr_id});
    try writer.print("  br label %dense_reserve_seed_done_{}\n", .{carrier_id});
    try writer.print("dense_reserve_seed_cap_{}:\n", .{carrier_id});
    try writer.print("  store i64 %v{}, ptr %v{}\n", .{ cap_id, next_cap_ptr_id });
    try writer.print("  br label %dense_reserve_seed_done_{}\n", .{carrier_id});
    try writer.print("dense_reserve_seed_done_{}:\n", .{carrier_id});
    try writer.print("  br label %dense_reserve_nextcap_loop_{}\n", .{carrier_id});
    try writer.print("dense_reserve_nextcap_loop_{}:\n", .{carrier_id});
    try writer.print("  %v{} = load i64, ptr %v{}\n", .{ loop_cap_id, next_cap_ptr_id });
    try writer.print("  %v{} = icmp sge i64 %v{}, ", .{ next_keep_id, loop_cap_id });
    if (want_override) |id| try writer.print("%v{}", .{id}) else try common.writeValueRef(writer, module, info, value.b);
    try writer.writeByte('\n');
    try writer.print("  br i1 %v{}, label %{s}, label %dense_reserve_nextcap_grow_{}\n", .{ next_keep_id, alloc_label, carrier_id });
    try writer.print("dense_reserve_nextcap_grow_{}:\n", .{carrier_id});
    try writer.print("  %v{} = mul i64 %v{}, 2\n", .{ doubled_id, loop_cap_id });
    try writer.print("  store i64 %v{}, ptr %v{}\n", .{ doubled_id, next_cap_ptr_id });
    try writer.print("  br label %dense_reserve_nextcap_loop_{}\n", .{carrier_id});
    try writer.print("{s}:\n", .{alloc_label});
    try writer.print("  %v{} = load i64, ptr %v{}\n", .{ alloc_cap_id, next_cap_ptr_id });
    try writer.print("  %v{} = mul i64 %v{}, {}\n", .{ alloc_bytes_id, alloc_cap_id, elem_size });
    const dense_reserve_size = try std.fmt.allocPrint(allocator, "%v{}", .{alloc_bytes_id});
    defer allocator.free(dense_reserve_size);
    try emitTrackedAllocCall(writer, new_data_id, dense_reserve_size, 1561, ".cyna.alloc.dense.reserve.data");
    try writer.print("  %v{} = alloca i64\n", .{index_ptr_id});
    try writer.writeAll("  store i64 0, ptr ");
    try writer.print("%v{}\n", .{index_ptr_id});
    try writer.print("  br label %{s}\n", .{copy_cond_label});
    try writer.print("{s}:\n", .{copy_cond_label});
    try writer.print("  %v{} = load i64, ptr %v{}\n", .{ index_id, index_ptr_id });
    try writer.print("  %v{} = icmp slt i64 %v{}, %v{}\n", .{ copy_keep_id, index_id, len_id });
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ copy_keep_id, copy_body_label, copy_done_label });
    try writer.print("{s}:\n", .{copy_body_label});
    try writer.print("  %v{} = getelementptr inbounds {s}, ptr %v{}, i64 %v{}\n", .{ dst_elem_id, elem_ty, new_data_id, index_id });
    try writer.print("  %v{} = getelementptr inbounds {s}, ptr %v{}, i64 %v{}\n", .{ src_elem_id, elem_ty, data_id, index_id });
    try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ elem_val_id, elem_ty, src_elem_id });
    try writer.print("  store {s} %v{}, ptr %v{}\n", .{ elem_ty, elem_val_id, dst_elem_id });
    try writer.print("  %v{} = add i64 %v{}, 1\n", .{ index_next_id, index_id });
    try writer.print("  store i64 %v{}, ptr %v{}\n", .{ index_next_id, index_ptr_id });
    try writer.print("  br label %{s}\n", .{copy_cond_label});
    try writer.print("{s}:\n", .{copy_done_label});
    try writer.print("  %v{} = icmp ne ptr %v{}, null\n", .{ has_old_data_id, data_id });
    try writer.print("  br i1 %v{}, label %dense_reserve_free_{}, label %dense_reserve_store_{}\n", .{ has_old_data_id, carrier_id, carrier_id });
    try writer.print("dense_reserve_free_{}:\n", .{carrier_id});
    try writer.print("  call void @cyna_runtime_tracked_free(ptr %v{})\n", .{data_id});
    try writer.print("  br label %dense_reserve_store_{}\n", .{carrier_id});
    try writer.print("dense_reserve_store_{}:\n", .{carrier_id});
    try writer.print("  %v{} = insertvalue {s} %v{}, ptr %v{}, 0\n", .{ grown0_id, dense_carrier_llvm_type, carrier_id, new_data_id });
    try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 2\n", .{ grown1_id, dense_carrier_llvm_type, grown0_id, alloc_cap_id });
    try writer.print("  store {s} %v{}, ptr ", .{ dense_carrier_llvm_type, grown1_id });
    try common.writeValueRef(writer, module, info, value.a);
    try writer.writeByte('\n');
    try writer.print("  br label %{s}\n", .{done_label});
    try writer.print("{s}:\n", .{done_label});
}

fn emitDenseClearMutation(writer: anytype, allocator: std.mem.Allocator, module: lir.Module, info: []const common.ValueInfo, next_temp_id: *u32, value: lir.BinaryValue) Error!void {
    const elem_ty = try storageElementType(allocator, module, info, value.lhs);
    defer allocator.free(elem_ty);
    const carrier_id = nextTempId(next_temp_id);
    const data_id = nextTempId(next_temp_id);
    const len_id = nextTempId(next_temp_id);
    const cap_id = nextTempId(next_temp_id);
    const drop_slot_id = nextTempId(next_temp_id);
    const drop_fn_id = nextTempId(next_temp_id);
    const zero_len_id = nextTempId(next_temp_id);
    const cleared_id = nextTempId(next_temp_id);
    const i_ptr_id = nextTempId(next_temp_id);
    const loop_label = try std.fmt.allocPrint(allocator, "dense_clear_loop_{}", .{carrier_id});
    defer allocator.free(loop_label);
    const body_label = try std.fmt.allocPrint(allocator, "dense_clear_body_{}", .{carrier_id});
    defer allocator.free(body_label);
    const done_label = try std.fmt.allocPrint(allocator, "dense_clear_done_{}", .{carrier_id});
    defer allocator.free(done_label);
    const i_id = nextTempId(next_temp_id);
    const cond_id = nextTempId(next_temp_id);
    const elem_ptr_id = nextTempId(next_temp_id);
    const i_next_id = nextTempId(next_temp_id);

    try writer.print("  %v{} = load {s}, ptr ", .{ carrier_id, dense_carrier_llvm_type });
    try common.writeValueRef(writer, module, info, value.lhs);
    try writer.writeByte('\n');
    try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ data_id, dense_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 1\n", .{ len_id, dense_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 2\n", .{ cap_id, dense_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = getelementptr inbounds {s}, ptr ", .{ drop_slot_id, runtime_symbols.type_desc_llvm_type });
    try common.writeValueRef(writer, module, info, value.rhs);
    try writer.print(", i32 0, i32 {d}\n", .{type_desc_drop_field_index});
    try writer.print("  %v{} = load ptr, ptr %v{}\n", .{ drop_fn_id, drop_slot_id });
    try writer.print("  %v{} = alloca i64\n", .{i_ptr_id});
    try writer.writeAll("  store i64 0, ptr ");
    try writer.print("%v{}\n", .{i_ptr_id});
    try writer.print("  br label %{s}\n", .{loop_label});
    try writer.print("{s}:\n", .{loop_label});
    try writer.print("  %v{} = load i64, ptr %v{}\n", .{ i_id, i_ptr_id });
    try writer.print("  %v{} = icmp slt i64 %v{}, %v{}\n", .{ cond_id, i_id, len_id });
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ cond_id, body_label, done_label });
    try writer.print("{s}:\n", .{body_label});
    try writer.print("  %v{} = getelementptr inbounds {s}, ptr %v{}, i64 %v{}\n", .{ elem_ptr_id, elem_ty, data_id, i_id });
    try writer.print("  call void %v{}(ptr %v{}, ptr ", .{ drop_fn_id, elem_ptr_id });
    try common.writeValueRef(writer, module, info, value.rhs);
    try writer.writeAll(")\n");
    try writer.print("  %v{} = add i64 %v{}, 1\n", .{ i_next_id, i_id });
    try writer.print("  store i64 %v{}, ptr %v{}\n", .{ i_next_id, i_ptr_id });
    try writer.print("  br label %{s}\n", .{loop_label});
    try writer.print("{s}:\n", .{done_label});
    try writer.print("  %v{} = add i64 0, 0\n", .{zero_len_id});
    try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 1\n", .{ cleared_id, dense_carrier_llvm_type, carrier_id, zero_len_id });
    try writer.print("  store {s} %v{}, ptr ", .{ dense_carrier_llvm_type, cleared_id });
    try common.writeValueRef(writer, module, info, value.lhs);
    try writer.writeByte('\n');
}

fn emitSparseMovedElement(writer: anytype, module: lir.Module, info: []const common.ValueInfo, next_temp_id: *u32, elem_ty: []const u8, elem_ptr_id: u32, source: lir.ValueId) Error!void {
    const loaded_id = nextTempId(next_temp_id);
    try writer.print("  %v{} = load {s}, ptr ", .{ loaded_id, elem_ty });
    try common.writeValueRef(writer, module, info, source);
    try writer.writeByte('\n');
    try writer.print("  store {s} %v{}, ptr %v{}\n", .{ elem_ty, loaded_id, elem_ptr_id });
}

fn emitSparseSetMutation(writer: anytype, allocator: std.mem.Allocator, module: lir.Module, info: []const common.ValueInfo, next_temp_id: *u32, value: lir.QuinaryValue, comptime move: bool) Error!void {
    const elem_ty = try types.llvmPointeeType(allocator, module, info, value.d);
    defer allocator.free(elem_ty);
    const carrier_id = nextTempId(next_temp_id);
    const data_id = nextTempId(next_temp_id);
    const occ_id = nextTempId(next_temp_id);
    const len_id = nextTempId(next_temp_id);
    const cap_id = nextTempId(next_temp_id);
    const neg_id = nextTempId(next_temp_id);
    const hi_id = nextTempId(next_temp_id);
    const oob_id = nextTempId(next_temp_id);
    const occ_slot_id = nextTempId(next_temp_id);
    const occ_byte_id = nextTempId(next_temp_id);
    const occupied_id = nextTempId(next_temp_id);
    const elem_ptr_id = nextTempId(next_temp_id);
    const drop_slot_occ_id = nextTempId(next_temp_id);
    const drop_fn_occ_id = nextTempId(next_temp_id);
    const copy_slot_occ_id = nextTempId(next_temp_id);
    const copy_fn_occ_id = nextTempId(next_temp_id);
    const copy_slot_empty_id = nextTempId(next_temp_id);
    const copy_fn_empty_id = nextTempId(next_temp_id);
    const drop_slot_none_occ_id = nextTempId(next_temp_id);
    const drop_fn_none_occ_id = nextTempId(next_temp_id);
    const len_dec_id = nextTempId(next_temp_id);
    const len_inc_id = nextTempId(next_temp_id);
    const len_phi_id = nextTempId(next_temp_id);
    const cv0_id = nextTempId(next_temp_id);
    const fail_label = try std.fmt.allocPrint(allocator, "sparse_set_fail_{}", .{carrier_id});
    defer allocator.free(fail_label);
    const check_label = try std.fmt.allocPrint(allocator, "sparse_set_check_{}", .{carrier_id});
    defer allocator.free(check_label);
    const some_label = try std.fmt.allocPrint(allocator, "sparse_set_some_{}", .{carrier_id});
    defer allocator.free(some_label);
    const some_occ_label = try std.fmt.allocPrint(allocator, "sparse_set_some_occ_{}", .{carrier_id});
    defer allocator.free(some_occ_label);
    const some_empty_label = try std.fmt.allocPrint(allocator, "sparse_set_some_empty_{}", .{carrier_id});
    defer allocator.free(some_empty_label);
    const none_label = try std.fmt.allocPrint(allocator, "sparse_set_none_{}", .{carrier_id});
    defer allocator.free(none_label);
    const none_occ_label = try std.fmt.allocPrint(allocator, "sparse_set_none_occ_{}", .{carrier_id});
    defer allocator.free(none_occ_label);
    const none_empty_label = try std.fmt.allocPrint(allocator, "sparse_set_none_empty_{}", .{carrier_id});
    defer allocator.free(none_empty_label);
    const merge_label = try std.fmt.allocPrint(allocator, "sparse_set_merge_{}", .{carrier_id});
    defer allocator.free(merge_label);

    try writer.print("  %v{} = load {s}, ptr ", .{ carrier_id, sparse_carrier_llvm_type });
    try common.writeValueRef(writer, module, info, value.a);
    try writer.writeByte('\n');
    try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ data_id, sparse_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 1\n", .{ occ_id, sparse_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 2\n", .{ len_id, sparse_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 3\n", .{ cap_id, sparse_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = icmp slt i64 ", .{neg_id});
    try common.writeValueRef(writer, module, info, value.b);
    try writer.writeAll(", 0\n");
    try writer.print("  %v{} = icmp sge i64 ", .{hi_id});
    try common.writeValueRef(writer, module, info, value.b);
    try writer.print(", %v{}\n", .{cap_id});
    try writer.print("  %v{} = or i1 %v{}, %v{}\n", .{ oob_id, neg_id, hi_id });
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ oob_id, fail_label, check_label });
    try writer.print("{s}:\n", .{fail_label});
    try writer.print("  call void @{s}(i64 ", .{runtime_symbols.bounds_fail_symbol});
    try common.writeValueRef(writer, module, info, value.b);
    try writer.print(", i64 %v{})\n", .{cap_id});
    try writer.writeAll("  unreachable\n");
    try writer.print("{s}:\n", .{check_label});
    try writer.print("  %v{} = getelementptr inbounds i8, ptr %v{}, i64 ", .{ occ_slot_id, occ_id });
    try common.writeValueRef(writer, module, info, value.b);
    try writer.writeByte('\n');
    try writer.print("  %v{} = load i8, ptr %v{}\n", .{ occ_byte_id, occ_slot_id });
    try writer.print("  %v{} = icmp ne i8 %v{}, 0\n", .{ occupied_id, occ_byte_id });
    try writer.print("  %v{} = getelementptr inbounds {s}, ptr %v{}, i64 ", .{ elem_ptr_id, elem_ty, data_id });
    try common.writeValueRef(writer, module, info, value.b);
    try writer.writeByte('\n');
    try writer.print("  br i1 ", .{});
    try common.writeValueRef(writer, module, info, value.c);
    try writer.print(", label %{s}, label %{s}\n", .{ some_label, none_label });

    try writer.print("{s}:\n", .{some_label});
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ occupied_id, some_occ_label, some_empty_label });
    try writer.print("{s}:\n", .{some_occ_label});
    try writer.print("  %v{} = getelementptr inbounds {s}, ptr ", .{ drop_slot_occ_id, runtime_symbols.type_desc_llvm_type });
    try common.writeValueRef(writer, module, info, value.e);
    try writer.print(", i32 0, i32 {d}\n", .{type_desc_drop_field_index});
    try writer.print("  %v{} = load ptr, ptr %v{}\n", .{ drop_fn_occ_id, drop_slot_occ_id });
    try writer.print("  call void %v{}(ptr %v{}, ptr ", .{ drop_fn_occ_id, elem_ptr_id });
    try common.writeValueRef(writer, module, info, value.e);
    try writer.writeAll(")\n");
    if (move) {
        try emitSparseMovedElement(writer, module, info, next_temp_id, elem_ty, elem_ptr_id, value.d);
    } else {
        try writer.print("  %v{} = getelementptr inbounds {s}, ptr ", .{ copy_slot_occ_id, runtime_symbols.type_desc_llvm_type });
        try common.writeValueRef(writer, module, info, value.e);
        try writer.print(", i32 0, i32 {d}\n", .{type_desc_copy_field_index});
        try writer.print("  %v{} = load ptr, ptr %v{}\n", .{ copy_fn_occ_id, copy_slot_occ_id });
        try writer.print("  call void %v{}(ptr %v{}, ptr ", .{ copy_fn_occ_id, elem_ptr_id });
        try common.writeValueRef(writer, module, info, value.d);
        try writer.writeAll(", ptr ");
        try common.writeValueRef(writer, module, info, value.e);
        try writer.writeAll(")\n");
    }
    try writer.print("  br label %{s}\n", .{merge_label});

    try writer.print("{s}:\n", .{some_empty_label});
    try writer.writeAll("  store i8 1, ptr ");
    try writer.print("%v{}\n", .{occ_slot_id});
    if (move) {
        try emitSparseMovedElement(writer, module, info, next_temp_id, elem_ty, elem_ptr_id, value.d);
    } else {
        try writer.print("  %v{} = getelementptr inbounds {s}, ptr ", .{ copy_slot_empty_id, runtime_symbols.type_desc_llvm_type });
        try common.writeValueRef(writer, module, info, value.e);
        try writer.print(", i32 0, i32 {d}\n", .{type_desc_copy_field_index});
        try writer.print("  %v{} = load ptr, ptr %v{}\n", .{ copy_fn_empty_id, copy_slot_empty_id });
        try writer.print("  call void %v{}(ptr %v{}, ptr ", .{ copy_fn_empty_id, elem_ptr_id });
        try common.writeValueRef(writer, module, info, value.d);
        try writer.writeAll(", ptr ");
        try common.writeValueRef(writer, module, info, value.e);
        try writer.writeAll(")\n");
    }
    try writer.print("  %v{} = add i64 %v{}, 1\n", .{ len_inc_id, len_id });
    try writer.print("  br label %{s}\n", .{merge_label});

    try writer.print("{s}:\n", .{none_label});
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ occupied_id, none_occ_label, none_empty_label });
    try writer.print("{s}:\n", .{none_occ_label});
    try writer.print("  %v{} = getelementptr inbounds {s}, ptr ", .{ drop_slot_none_occ_id, runtime_symbols.type_desc_llvm_type });
    try common.writeValueRef(writer, module, info, value.e);
    try writer.print(", i32 0, i32 {d}\n", .{type_desc_drop_field_index});
    try writer.print("  %v{} = load ptr, ptr %v{}\n", .{ drop_fn_none_occ_id, drop_slot_none_occ_id });
    try writer.print("  call void %v{}(ptr %v{}, ptr ", .{ drop_fn_none_occ_id, elem_ptr_id });
    try common.writeValueRef(writer, module, info, value.e);
    try writer.writeAll(")\n");
    try writer.writeAll("  store i8 0, ptr ");
    try writer.print("%v{}\n", .{occ_slot_id});
    try writer.print("  %v{} = sub i64 %v{}, 1\n", .{ len_dec_id, len_id });
    try writer.print("  br label %{s}\n", .{merge_label});

    try writer.print("{s}:\n", .{none_empty_label});
    try writer.print("  br label %{s}\n", .{merge_label});

    try writer.print("{s}:\n", .{merge_label});
    try writer.print(
        "  %v{} = phi i64 [ %v{}, %{s} ], [ %v{}, %{s} ], [ %v{}, %{s} ], [ %v{}, %{s} ]\n",
        .{ len_phi_id, len_id, some_occ_label, len_inc_id, some_empty_label, len_dec_id, none_occ_label, len_id, none_empty_label },
    );
    try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 2\n", .{ cv0_id, sparse_carrier_llvm_type, carrier_id, len_phi_id });
    try writer.print("  store {s} %v{}, ptr ", .{ sparse_carrier_llvm_type, cv0_id });
    try common.writeValueRef(writer, module, info, value.a);
    try writer.writeByte('\n');
}

fn emitSparseClearMutation(writer: anytype, allocator: std.mem.Allocator, module: lir.Module, info: []const common.ValueInfo, next_temp_id: *u32, value: lir.BinaryValue) Error!void {
    const elem_ty = try storageElementType(allocator, module, info, value.lhs);
    defer allocator.free(elem_ty);
    const carrier_id = nextTempId(next_temp_id);
    const data_id = nextTempId(next_temp_id);
    const occ_id = nextTempId(next_temp_id);
    const cap_id = nextTempId(next_temp_id);
    const drop_slot_id = nextTempId(next_temp_id);
    const drop_fn_id = nextTempId(next_temp_id);
    const i_ptr_id = nextTempId(next_temp_id);
    const loop_label = try std.fmt.allocPrint(allocator, "sparse_clear_loop_{}", .{carrier_id});
    defer allocator.free(loop_label);
    const check_label = try std.fmt.allocPrint(allocator, "sparse_clear_check_{}", .{carrier_id});
    defer allocator.free(check_label);
    const body_label = try std.fmt.allocPrint(allocator, "sparse_clear_body_{}", .{carrier_id});
    defer allocator.free(body_label);
    const skip_label = try std.fmt.allocPrint(allocator, "sparse_clear_skip_{}", .{carrier_id});
    defer allocator.free(skip_label);
    const done_label = try std.fmt.allocPrint(allocator, "sparse_clear_done_{}", .{carrier_id});
    defer allocator.free(done_label);
    const i_id = nextTempId(next_temp_id);
    const cond_id = nextTempId(next_temp_id);
    const occ_slot_id = nextTempId(next_temp_id);
    const occ_byte_id = nextTempId(next_temp_id);
    const occupied_id = nextTempId(next_temp_id);
    const elem_ptr_id = nextTempId(next_temp_id);
    const i_next_id = nextTempId(next_temp_id);
    const cleared_id = nextTempId(next_temp_id);

    try writer.print("  %v{} = load {s}, ptr ", .{ carrier_id, sparse_carrier_llvm_type });
    try common.writeValueRef(writer, module, info, value.lhs);
    try writer.writeByte('\n');
    try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ data_id, sparse_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 1\n", .{ occ_id, sparse_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 3\n", .{ cap_id, sparse_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = getelementptr inbounds {s}, ptr ", .{ drop_slot_id, runtime_symbols.type_desc_llvm_type });
    try common.writeValueRef(writer, module, info, value.rhs);
    try writer.print(", i32 0, i32 {d}\n", .{type_desc_drop_field_index});
    try writer.print("  %v{} = load ptr, ptr %v{}\n", .{ drop_fn_id, drop_slot_id });
    try writer.print("  %v{} = alloca i64\n", .{i_ptr_id});
    try writer.writeAll("  store i64 0, ptr ");
    try writer.print("%v{}\n", .{i_ptr_id});
    try writer.print("  br label %{s}\n", .{loop_label});
    try writer.print("{s}:\n", .{loop_label});
    try writer.print("  %v{} = load i64, ptr %v{}\n", .{ i_id, i_ptr_id });
    try writer.print("  %v{} = icmp slt i64 %v{}, %v{}\n", .{ cond_id, i_id, cap_id });
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ cond_id, check_label, done_label });
    try writer.print("{s}:\n", .{check_label});
    try writer.print("  %v{} = getelementptr inbounds i8, ptr %v{}, i64 %v{}\n", .{ occ_slot_id, occ_id, i_id });
    try writer.print("  %v{} = load i8, ptr %v{}\n", .{ occ_byte_id, occ_slot_id });
    try writer.print("  %v{} = icmp ne i8 %v{}, 0\n", .{ occupied_id, occ_byte_id });
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ occupied_id, body_label, skip_label });
    try writer.print("{s}:\n", .{body_label});
    try writer.print("  %v{} = getelementptr inbounds {s}, ptr %v{}, i64 %v{}\n", .{ elem_ptr_id, elem_ty, data_id, i_id });
    try writer.print("  call void %v{}(ptr %v{}, ptr ", .{ drop_fn_id, elem_ptr_id });
    try common.writeValueRef(writer, module, info, value.rhs);
    try writer.writeAll(")\n");
    try writer.writeAll("  store i8 0, ptr ");
    try writer.print("%v{}\n", .{occ_slot_id});
    try writer.print("  br label %{s}\n", .{skip_label});
    try writer.print("{s}:\n", .{skip_label});
    try writer.print("  %v{} = add i64 %v{}, 1\n", .{ i_next_id, i_id });
    try writer.print("  store i64 %v{}, ptr %v{}\n", .{ i_next_id, i_ptr_id });
    try writer.print("  br label %{s}\n", .{loop_label});
    try writer.print("{s}:\n", .{done_label});
    try writer.print("  %v{} = insertvalue {s} %v{}, i64 0, 2\n", .{ cleared_id, sparse_carrier_llvm_type, carrier_id });
    try writer.print("  store {s} %v{}, ptr ", .{ sparse_carrier_llvm_type, cleared_id });
    try common.writeValueRef(writer, module, info, value.lhs);
    try writer.writeByte('\n');
}

fn emitSparseCarrierFromNewDirect(writer: anytype, allocator: std.mem.Allocator, module: lir.Module, info: []const common.ValueInfo, next_temp_id: *u32, result_id: u32, capacity: lir.ValueId, desc: lir.ValueId) Error!void {
    _ = desc;
    const cap_ok_id = nextTempId(next_temp_id);
    const cap_zero_id = nextTempId(next_temp_id);
    const fail_label = try std.fmt.allocPrint(allocator, "sparse_new_fail_{}", .{result_id});
    defer allocator.free(fail_label);
    const zero_label = try std.fmt.allocPrint(allocator, "sparse_new_zero_{}", .{result_id});
    defer allocator.free(zero_label);
    const alloc_label = try std.fmt.allocPrint(allocator, "sparse_new_alloc_{}", .{result_id});
    defer allocator.free(alloc_label);
    const data_bytes_id = nextTempId(next_temp_id);
    const occ_id = nextTempId(next_temp_id);
    const data_id = nextTempId(next_temp_id);
    const index_ptr_id = nextTempId(next_temp_id);
    const index_id = nextTempId(next_temp_id);
    const keep_id = nextTempId(next_temp_id);
    const occ_slot_id = nextTempId(next_temp_id);
    const next_id = nextTempId(next_temp_id);
    const occ_phi_id = nextTempId(next_temp_id);
    const data_phi_id = nextTempId(next_temp_id);
    const cv0_id = nextTempId(next_temp_id);
    const cv1_id = nextTempId(next_temp_id);
    const cv2_id = nextTempId(next_temp_id);
    const elem_sem_ty = switch (module.types[info[result_id].ty orelse return error.BackendInvariantViolation]) {
        .sparse_array => |item_ty| item_ty,
        else => return error.BackendInvariantViolation,
    };
    const elem_size = (try abi.typeSizeAlign(module, elem_sem_ty)).size;

    try writer.print("  %v{} = icmp sge i64 ", .{cap_ok_id});
    try common.writeValueRef(writer, module, info, capacity);
    try writer.writeAll(", 0\n");
    try writer.print("  br i1 %v{}, label %sparse_new_check_{}, label %{s}\n", .{ cap_ok_id, result_id, fail_label });
    try writer.print("{s}:\n", .{fail_label});
    try writer.print("  call void @{s}(i64 ", .{runtime_symbols.capacity_fail_symbol});
    try common.writeValueRef(writer, module, info, capacity);
    try writer.writeAll(", i64 0)\n");
    try writer.writeAll("  unreachable\n");
    try writer.print("sparse_new_check_{}:\n", .{result_id});
    try writer.print("  %v{} = icmp eq i64 ", .{cap_zero_id});
    try common.writeValueRef(writer, module, info, capacity);
    try writer.writeAll(", 0\n");
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ cap_zero_id, zero_label, alloc_label });
    try writer.print("{s}:\n", .{zero_label});
    try writer.writeAll("  br label %sparse_new_store_");
    try writer.print("{}\n", .{result_id});
    try writer.print("{s}:\n", .{alloc_label});
    try writer.print("  %v{} = mul i64 ", .{data_bytes_id});
    try common.writeValueRef(writer, module, info, capacity);
    try writer.print(", {}\n", .{elem_size});
    try writer.print("  %v{} = call ptr @cyna_runtime_tracked_alloc_site(i64 ", .{occ_id});
    try common.writeValueRef(writer, module, info, capacity);
    try writer.writeAll(", ptr @.cyna.alloc.file, i64 1912, ptr @.cyna.alloc.sparse.new.occupied)\n");
    const sparse_new_data_size = try std.fmt.allocPrint(allocator, "%v{}", .{data_bytes_id});
    defer allocator.free(sparse_new_data_size);
    try emitTrackedAllocCall(writer, data_id, sparse_new_data_size, 1915, ".cyna.alloc.sparse.new.data");
    try writer.print("  %v{} = alloca i64\n", .{index_ptr_id});
    try writer.writeAll("  store i64 0, ptr ");
    try writer.print("%v{}\n", .{index_ptr_id});
    try writer.print("  br label %sparse_new_zero_loop_{}\n", .{result_id});
    try writer.print("sparse_new_zero_loop_{}:\n", .{result_id});
    try writer.print("  %v{} = load i64, ptr %v{}\n", .{ index_id, index_ptr_id });
    try writer.print("  %v{} = icmp slt i64 %v{}, ", .{ keep_id, index_id });
    try common.writeValueRef(writer, module, info, capacity);
    try writer.writeByte('\n');
    try writer.print("  br i1 %v{}, label %sparse_new_zero_body_{}, label %sparse_new_store_{}\n", .{ keep_id, result_id, result_id });
    try writer.print("sparse_new_zero_body_{}:\n", .{result_id});
    try writer.print("  %v{} = getelementptr inbounds i8, ptr %v{}, i64 %v{}\n", .{ occ_slot_id, occ_id, index_id });
    try writer.print("  store i8 0, ptr %v{}\n", .{occ_slot_id});
    try writer.print("  %v{} = add i64 %v{}, 1\n", .{ next_id, index_id });
    try writer.print("  store i64 %v{}, ptr %v{}\n", .{ next_id, index_ptr_id });
    try writer.print("  br label %sparse_new_zero_loop_{}\n", .{result_id});
    try writer.print("sparse_new_store_{}:\n", .{result_id});
    try writer.print("  %v{} = phi ptr [ null, %{s} ], [ %v{}, %sparse_new_zero_loop_{} ]\n", .{ occ_phi_id, zero_label, occ_id, result_id });
    try writer.print("  %v{} = phi ptr [ null, %{s} ], [ %v{}, %sparse_new_zero_loop_{} ]\n", .{ data_phi_id, zero_label, data_id, result_id });
    try writer.print("  %v{} = insertvalue {s} undef, ptr %v{}, 0\n", .{ cv0_id, sparse_carrier_llvm_type, data_phi_id });
    try writer.print("  %v{} = insertvalue {s} %v{}, ptr %v{}, 1\n", .{ cv1_id, sparse_carrier_llvm_type, cv0_id, occ_phi_id });
    try writer.print("  %v{} = insertvalue {s} %v{}, i64 0, 2\n", .{ cv2_id, sparse_carrier_llvm_type, cv1_id });
    try writer.print("  %v{} = insertvalue {s} %v{}, i64 ", .{ result_id, sparse_carrier_llvm_type, cv2_id });
    try common.writeValueRef(writer, module, info, capacity);
    try writer.writeAll(", 3\n");
}

fn emitSparseInsertMutation(writer: anytype, allocator: std.mem.Allocator, module: lir.Module, info: []const common.ValueInfo, next_temp_id: *u32, value: lir.QuaternaryValue, comptime move: bool) Error!void {
    const elem_ty = try types.llvmPointeeType(allocator, module, info, value.c);
    defer allocator.free(elem_ty);
    const carrier_id = nextTempId(next_temp_id);
    const data_id = nextTempId(next_temp_id);
    const occ_id = nextTempId(next_temp_id);
    const len_id = nextTempId(next_temp_id);
    const cap_id = nextTempId(next_temp_id);
    const neg_id = nextTempId(next_temp_id);
    const hi_id = nextTempId(next_temp_id);
    const oob_id = nextTempId(next_temp_id);
    const occ_slot_id = nextTempId(next_temp_id);
    const occ_byte_id = nextTempId(next_temp_id);
    const occupied_id = nextTempId(next_temp_id);
    const elem_ptr_id = nextTempId(next_temp_id);
    const drop_slot_occ_id = nextTempId(next_temp_id);
    const drop_fn_occ_id = nextTempId(next_temp_id);
    const copy_slot_occ_id = nextTempId(next_temp_id);
    const copy_fn_occ_id = nextTempId(next_temp_id);
    const copy_slot_empty_id = nextTempId(next_temp_id);
    const copy_fn_empty_id = nextTempId(next_temp_id);
    const len_inc_id = nextTempId(next_temp_id);
    const len_phi_id = nextTempId(next_temp_id);
    const cv0_id = nextTempId(next_temp_id);
    const fail_label = try std.fmt.allocPrint(allocator, "sparse_insert_fail_{}", .{carrier_id});
    defer allocator.free(fail_label);
    const check_label = try std.fmt.allocPrint(allocator, "sparse_insert_check_{}", .{carrier_id});
    defer allocator.free(check_label);
    const occupied_label = try std.fmt.allocPrint(allocator, "sparse_insert_occ_{}", .{carrier_id});
    defer allocator.free(occupied_label);
    const empty_label = try std.fmt.allocPrint(allocator, "sparse_insert_empty_{}", .{carrier_id});
    defer allocator.free(empty_label);
    const merge_label = try std.fmt.allocPrint(allocator, "sparse_insert_merge_{}", .{carrier_id});
    defer allocator.free(merge_label);

    try writer.print("  %v{} = load {s}, ptr ", .{ carrier_id, sparse_carrier_llvm_type });
    try common.writeValueRef(writer, module, info, value.a);
    try writer.writeByte('\n');
    try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ data_id, sparse_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 1\n", .{ occ_id, sparse_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 2\n", .{ len_id, sparse_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = extractvalue {s} %v{}, 3\n", .{ cap_id, sparse_carrier_llvm_type, carrier_id });
    try writer.print("  %v{} = icmp slt i64 ", .{neg_id});
    try common.writeValueRef(writer, module, info, value.b);
    try writer.writeAll(", 0\n");
    try writer.print("  %v{} = icmp sge i64 ", .{hi_id});
    try common.writeValueRef(writer, module, info, value.b);
    try writer.print(", %v{}\n", .{cap_id});
    try writer.print("  %v{} = or i1 %v{}, %v{}\n", .{ oob_id, neg_id, hi_id });
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ oob_id, fail_label, check_label });
    try writer.print("{s}:\n", .{fail_label});
    try writer.print("  call void @{s}(i64 ", .{runtime_symbols.bounds_fail_symbol});
    try common.writeValueRef(writer, module, info, value.b);
    try writer.print(", i64 %v{})\n", .{cap_id});
    try writer.writeAll("  unreachable\n");
    try writer.print("{s}:\n", .{check_label});
    try writer.print("  %v{} = getelementptr inbounds i8, ptr %v{}, i64 ", .{ occ_slot_id, occ_id });
    try common.writeValueRef(writer, module, info, value.b);
    try writer.writeByte('\n');
    try writer.print("  %v{} = load i8, ptr %v{}\n", .{ occ_byte_id, occ_slot_id });
    try writer.print("  %v{} = icmp ne i8 %v{}, 0\n", .{ occupied_id, occ_byte_id });
    try writer.print("  %v{} = getelementptr inbounds {s}, ptr %v{}, i64 ", .{ elem_ptr_id, elem_ty, data_id });
    try common.writeValueRef(writer, module, info, value.b);
    try writer.writeByte('\n');
    try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ occupied_id, occupied_label, empty_label });

    try writer.print("{s}:\n", .{occupied_label});
    try writer.print("  %v{} = getelementptr inbounds {s}, ptr ", .{ drop_slot_occ_id, runtime_symbols.type_desc_llvm_type });
    try common.writeValueRef(writer, module, info, value.d);
    try writer.print(", i32 0, i32 {d}\n", .{type_desc_drop_field_index});
    try writer.print("  %v{} = load ptr, ptr %v{}\n", .{ drop_fn_occ_id, drop_slot_occ_id });
    try writer.print("  call void %v{}(ptr %v{}, ptr ", .{ drop_fn_occ_id, elem_ptr_id });
    try common.writeValueRef(writer, module, info, value.d);
    try writer.writeAll(")\n");
    if (move) {
        try emitSparseMovedElement(writer, module, info, next_temp_id, elem_ty, elem_ptr_id, value.c);
    } else {
        try writer.print("  %v{} = getelementptr inbounds {s}, ptr ", .{ copy_slot_occ_id, runtime_symbols.type_desc_llvm_type });
        try common.writeValueRef(writer, module, info, value.d);
        try writer.print(", i32 0, i32 {d}\n", .{type_desc_copy_field_index});
        try writer.print("  %v{} = load ptr, ptr %v{}\n", .{ copy_fn_occ_id, copy_slot_occ_id });
        try writer.print("  call void %v{}(ptr %v{}, ptr ", .{ copy_fn_occ_id, elem_ptr_id });
        try common.writeValueRef(writer, module, info, value.c);
        try writer.writeAll(", ptr ");
        try common.writeValueRef(writer, module, info, value.d);
        try writer.writeAll(")\n");
    }
    try writer.print("  br label %{s}\n", .{merge_label});

    try writer.print("{s}:\n", .{empty_label});
    try writer.writeAll("  store i8 1, ptr ");
    try writer.print("%v{}\n", .{occ_slot_id});
    if (move) {
        try emitSparseMovedElement(writer, module, info, next_temp_id, elem_ty, elem_ptr_id, value.c);
    } else {
        try writer.print("  %v{} = getelementptr inbounds {s}, ptr ", .{ copy_slot_empty_id, runtime_symbols.type_desc_llvm_type });
        try common.writeValueRef(writer, module, info, value.d);
        try writer.print(", i32 0, i32 {d}\n", .{type_desc_copy_field_index});
        try writer.print("  %v{} = load ptr, ptr %v{}\n", .{ copy_fn_empty_id, copy_slot_empty_id });
        try writer.print("  call void %v{}(ptr %v{}, ptr ", .{ copy_fn_empty_id, elem_ptr_id });
        try common.writeValueRef(writer, module, info, value.c);
        try writer.writeAll(", ptr ");
        try common.writeValueRef(writer, module, info, value.d);
        try writer.writeAll(")\n");
    }
    try writer.print("  %v{} = add i64 %v{}, 1\n", .{ len_inc_id, len_id });
    try writer.print("  br label %{s}\n", .{merge_label});

    try writer.print("{s}:\n", .{merge_label});
    try writer.print("  %v{} = phi i64 [ %v{}, %{s} ], [ %v{}, %{s} ]\n", .{ len_phi_id, len_id, occupied_label, len_inc_id, empty_label });
    try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 2\n", .{ cv0_id, sparse_carrier_llvm_type, carrier_id, len_phi_id });
    try writer.print("  store {s} %v{}, ptr ", .{ sparse_carrier_llvm_type, cv0_id });
    try common.writeValueRef(writer, module, info, value.a);
    try writer.writeByte('\n');
}

pub fn emitFunctionParamAbiSetup(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    function: lir.Function,
    next_temp_id: *u32,
) Error!void {
    for (function.params, 0..) |param, i| {
        if (abi.needsExportValueBridge(function)) {
            if (try abi.publicCallableBoundaryType(allocator, module, param.ty)) |public_ty| {
                defer allocator.free(public_ty);
                const semantic_ty = try types.llvmScalarType(allocator, module, param.ty);
                defer allocator.free(semantic_ty);
                const bridged_id = nextTempId(next_temp_id);
                const bridged_ptr_id = nextTempId(next_temp_id);
                if (try abi.indirectParamInfo(module, function, param.ty)) |_| {
                    const public_value_id = nextTempId(next_temp_id);
                    try writer.print("  %v{} = load {s}, ptr %abi_arg{}", .{ public_value_id, public_ty, i });
                    try emitTypeAlignment(writer, module, param.ty);
                    try writer.writeByte('\n');
                    _ = try emitExternImportBridgeValue(writer, allocator, module, next_temp_id, param.ty, public_value_id, bridged_id);
                } else switch (module.types[param.ty]) {
                    .dense_array, .sparse_array => {
                        const public_ptr_id = nextTempId(next_temp_id);
                        try writer.print("  %v{} = bitcast ptr %abi_arg{} to ptr\n", .{ public_ptr_id, i });
                        _ = try emitExternImportBridgeValue(writer, allocator, module, next_temp_id, param.ty, public_ptr_id, bridged_id);
                    },
                    else => {
                        const abi_ty = try abi.paramType(allocator, module, function, param.ty);
                        defer allocator.free(abi_ty);
                        const abi_arg_ref = try std.fmt.allocPrint(allocator, "%abi_arg{}", .{i});
                        defer allocator.free(abi_arg_ref);
                        const public_value_id = if (std.mem.eql(u8, abi_ty, public_ty))
                            try emitMemoryCoercion(writer, next_temp_id, public_ty, public_ty, public_ty, abi_arg_ref)
                        else
                            try emitMemoryCoercion(writer, next_temp_id, abi_ty, public_ty, abi_ty, abi_arg_ref);
                        _ = try emitExternImportBridgeValue(writer, allocator, module, next_temp_id, param.ty, public_value_id, bridged_id);
                    },
                }
                try writer.print("  %v{} = alloca {s}\n", .{ bridged_ptr_id, semantic_ty });
                try writer.print("  store {s} %v{}, ptr %v{}", .{ semantic_ty, bridged_id, bridged_ptr_id });
                try emitTypeAlignment(writer, module, param.ty);
                try writer.writeByte('\n');
                try writer.print("  %arg{} = load {s}, ptr %v{}", .{ i, semantic_ty, bridged_ptr_id });
                try emitTypeAlignment(writer, module, param.ty);
                try writer.writeByte('\n');
                continue;
            }
        }
        if (try abi.indirectParamInfo(module, function, param.ty)) |_| {
            const semantic_ty = try types.llvmScalarType(allocator, module, param.ty);
            defer allocator.free(semantic_ty);
            try writer.print("  %arg{} = load {s}, ptr %abi_arg{}", .{ i, semantic_ty, i });
            try emitTypeAlignment(writer, module, param.ty);
            try writer.writeByte('\n');
            continue;
        }
        if (!abi.needsExportValueBridge(function)) continue;
        switch (try abi.callableBoundaryShape(module, function, param.ty)) {
            .semantic => continue,
            .indirect => unreachable,
            .scalar_coercion => {},
            .dense_header_ptr, .sparse_header_ptr => unreachable,
        }
        const abi_ty = (try abi.cLayoutAbiCoercionType(allocator, module, param.ty)).?;
        defer allocator.free(abi_ty);

        const semantic_ty = try types.llvmScalarType(allocator, module, param.ty);
        defer allocator.free(semantic_ty);
        const temp_id = nextTempId(next_temp_id);

        try writer.print("  %v{} = alloca {s}\n", .{ temp_id, semantic_ty });
        try writer.print("  store {s} %abi_arg{}, ptr %v{}", .{ abi_ty, i, temp_id });
        try emitTypeAlignment(writer, module, param.ty);
        try writer.writeByte('\n');
        try writer.print("  %arg{} = load {s}, ptr %v{}", .{ i, semantic_ty, temp_id });
        try emitTypeAlignment(writer, module, param.ty);
        try writer.writeByte('\n');
    }
}

fn emitMemoryCoercion(
    writer: anytype,
    next_temp_id: *u32,
    source_ty: []const u8,
    dest_ty: []const u8,
    storage_ty: []const u8,
    source_ref: []const u8,
) Error!u32 {
    const slot_id = nextTempId(next_temp_id);
    const out_id = nextTempId(next_temp_id);
    try writer.print("  %v{} = alloca {s}\n", .{ slot_id, storage_ty });
    try writer.print("  store {s} {s}, ptr %v{}\n", .{ source_ty, source_ref, slot_id });
    try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ out_id, dest_ty, slot_id });
    return out_id;
}

fn emitExternExportBridgeValue(
    writer: anytype,
    allocator: std.mem.Allocator,
    module: lir.Module,
    next_temp_id: *u32,
    ty: lir.TypeId,
    src_ptr_id: u32,
    dest_id: ?u32,
) Error!u32 {
    return switch (module.types[ty]) {
        .bool => blk: {
            const out_id = dest_id orelse nextTempId(next_temp_id);
            const value_id = nextTempId(next_temp_id);
            try writer.print("  %v{} = load i1, ptr %v{}\n", .{ value_id, src_ptr_id });
            try writer.print("  %v{} = zext i1 %v{} to i8\n", .{ out_id, value_id });
            break :blk out_id;
        },
        .dense_array => |elem_ty| blk: {
            const out_id = dest_id orelse nextTempId(next_temp_id);
            const carrier_id = nextTempId(next_temp_id);
            const data_id = nextTempId(next_temp_id);
            const len_id = nextTempId(next_temp_id);
            const cap_id = nextTempId(next_temp_id);
            const cv0_id = nextTempId(next_temp_id);
            const cv1_id = nextTempId(next_temp_id);
            const cv2_id = nextTempId(next_temp_id);
            const cv3_id = nextTempId(next_temp_id);
            const elem_desc = try backend_support.descriptorGlobalName(allocator, module, elem_ty);
            defer allocator.free(elem_desc);
            try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ carrier_id, dense_carrier_llvm_type, src_ptr_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ data_id, dense_carrier_llvm_type, carrier_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 1\n", .{ len_id, dense_carrier_llvm_type, carrier_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 2\n", .{ cap_id, dense_carrier_llvm_type, carrier_id });
            try emitTrackedAllocCall(writer, out_id, "32", 2164, ".cyna.alloc.dense.runtime.object");
            try writer.print("  %v{} = insertvalue {s} undef, ptr @{s}, 0\n", .{ cv0_id, dense_runtime_llvm_type, elem_desc });
            try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 1\n", .{ cv1_id, dense_runtime_llvm_type, cv0_id, len_id });
            try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 2\n", .{ cv2_id, dense_runtime_llvm_type, cv1_id, cap_id });
            try writer.print("  %v{} = insertvalue {s} %v{}, ptr %v{}, 3\n", .{ cv3_id, dense_runtime_llvm_type, cv2_id, data_id });
            try writer.print("  store {s} %v{}, ptr %v{}\n", .{ dense_runtime_llvm_type, cv3_id, out_id });
            break :blk out_id;
        },
        .sparse_array => |elem_ty| blk: {
            const out_id = dest_id orelse nextTempId(next_temp_id);
            const carrier_id = nextTempId(next_temp_id);
            const data_id = nextTempId(next_temp_id);
            const occ_id = nextTempId(next_temp_id);
            const len_id = nextTempId(next_temp_id);
            const cap_id = nextTempId(next_temp_id);
            const cv0_id = nextTempId(next_temp_id);
            const cv1_id = nextTempId(next_temp_id);
            const cv2_id = nextTempId(next_temp_id);
            const cv3_id = nextTempId(next_temp_id);
            const cv4_id = nextTempId(next_temp_id);
            const elem_desc = try backend_support.descriptorGlobalName(allocator, module, elem_ty);
            defer allocator.free(elem_desc);
            try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ carrier_id, sparse_carrier_llvm_type, src_ptr_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ data_id, sparse_carrier_llvm_type, carrier_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 1\n", .{ occ_id, sparse_carrier_llvm_type, carrier_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 2\n", .{ len_id, sparse_carrier_llvm_type, carrier_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 3\n", .{ cap_id, sparse_carrier_llvm_type, carrier_id });
            try emitTrackedAllocCall(writer, out_id, "40", 2191, ".cyna.alloc.sparse.runtime.object");
            try writer.print("  %v{} = insertvalue {s} undef, ptr @{s}, 0\n", .{ cv0_id, sparse_runtime_llvm_type, elem_desc });
            try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 1\n", .{ cv1_id, sparse_runtime_llvm_type, cv0_id, len_id });
            try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 2\n", .{ cv2_id, sparse_runtime_llvm_type, cv1_id, cap_id });
            try writer.print("  %v{} = insertvalue {s} %v{}, ptr %v{}, 3\n", .{ cv3_id, sparse_runtime_llvm_type, cv2_id, occ_id });
            try writer.print("  %v{} = insertvalue {s} %v{}, ptr %v{}, 4\n", .{ cv4_id, sparse_runtime_llvm_type, cv3_id, data_id });
            try writer.print("  store {s} %v{}, ptr %v{}\n", .{ sparse_runtime_llvm_type, cv4_id, out_id });
            break :blk out_id;
        },
        .optional => |payload_ty| blk: {
            const out_id = dest_id orelse nextTempId(next_temp_id);
            const semantic_ty = try types.llvmScalarType(allocator, module, ty);
            defer allocator.free(semantic_ty);
            if (abi.isNullablePointer(module, ty)) {
                const value_id = nextTempId(next_temp_id);
                const tag_id = nextTempId(next_temp_id);
                const present_id = nextTempId(next_temp_id);
                const pointer_id = nextTempId(next_temp_id);
                try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ value_id, semantic_ty, src_ptr_id });
                try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ tag_id, semantic_ty, value_id });
                try writer.print("  %v{} = icmp ne i8 %v{}, 0\n", .{ present_id, tag_id });
                try writer.print("  %v{} = extractvalue {s} %v{}, 1\n", .{ pointer_id, semantic_ty, value_id });
                try writer.print("  %v{} = select i1 %v{}, ptr %v{}, ptr null\n", .{ out_id, present_id, pointer_id });
                break :blk out_id;
            }
            const public_ty = (try abi.publicCallableBoundaryType(allocator, module, ty)).?;
            defer allocator.free(public_ty);
            const payload_public_ty = try abi.callableBoundaryTypeOrSemantic(allocator, module, payload_ty);
            defer allocator.free(payload_public_ty);
            const semantic_value_id = nextTempId(next_temp_id);
            const tag_id = nextTempId(next_temp_id);
            const is_some_id = nextTempId(next_temp_id);
            const slot_id = nextTempId(next_temp_id);
            const payload_ptr_id = nextTempId(next_temp_id);
            const some_value0_id = nextTempId(next_temp_id);
            const some_value1_id = nextTempId(next_temp_id);
            const none_value0_id = nextTempId(next_temp_id);
            const none_value1_id = nextTempId(next_temp_id);
            const some_label = try std.fmt.allocPrint(allocator, "extern_export_optional_some_{}", .{out_id});
            defer allocator.free(some_label);
            const none_label = try std.fmt.allocPrint(allocator, "extern_export_optional_none_{}", .{out_id});
            defer allocator.free(none_label);
            const cont_label = try std.fmt.allocPrint(allocator, "extern_export_optional_cont_{}", .{out_id});
            defer allocator.free(cont_label);
            try writer.print("  %v{} = alloca {s}\n", .{ slot_id, public_ty });
            try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ semantic_value_id, semantic_ty, src_ptr_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ tag_id, semantic_ty, semantic_value_id });
            try writer.print("  %v{} = icmp ne i8 %v{}, 0\n", .{ is_some_id, tag_id });
            try writer.print("  %v{} = getelementptr inbounds {s}, ptr %v{}, i32 0, i32 1\n", .{ payload_ptr_id, semantic_ty, src_ptr_id });
            try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ is_some_id, some_label, none_label });
            try writer.print("{s}:\n", .{some_label});
            const payload_public_id = try emitExternExportBridgeValue(writer, allocator, module, next_temp_id, payload_ty, payload_ptr_id, null);
            try writer.print("  %v{} = insertvalue {s} undef, i8 %v{}, 0\n", .{ some_value0_id, public_ty, tag_id });
            try writer.print("  %v{} = insertvalue {s} %v{}, {s} %v{}, 1\n", .{ some_value1_id, public_ty, some_value0_id, payload_public_ty, payload_public_id });
            try writer.print("  store {s} %v{}, ptr %v{}\n", .{ public_ty, some_value1_id, slot_id });
            try writer.print("  br label %{s}\n", .{cont_label});
            try writer.print("{s}:\n", .{none_label});
            try writer.print("  %v{} = insertvalue {s} undef, i8 %v{}, 0\n", .{ none_value0_id, public_ty, tag_id });
            try writer.print("  %v{} = insertvalue {s} %v{}, {s} zeroinitializer, 1\n", .{ none_value1_id, public_ty, none_value0_id, payload_public_ty });
            try writer.print("  store {s} %v{}, ptr %v{}\n", .{ public_ty, none_value1_id, slot_id });
            try writer.print("  br label %{s}\n", .{cont_label});
            try writer.print("{s}:\n", .{cont_label});
            try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ out_id, public_ty, slot_id });
            break :blk out_id;
        },
        .result => |result_ty| blk: {
            const out_id = dest_id orelse nextTempId(next_temp_id);
            const semantic_ty = try types.llvmScalarType(allocator, module, ty);
            defer allocator.free(semantic_ty);
            const public_ty = (try abi.publicCallableBoundaryType(allocator, module, ty)).?;
            defer allocator.free(public_ty);
            const ok_public_ty = if (module.types[result_ty.ok] == .void)
                try allocator.dupe(u8, "i8")
            else
                try abi.callableBoundaryTypeOrSemantic(allocator, module, result_ty.ok);
            defer allocator.free(ok_public_ty);
            const err_public_ty = try abi.callableBoundaryTypeOrSemantic(allocator, module, result_ty.err);
            defer allocator.free(err_public_ty);
            const semantic_value_id = nextTempId(next_temp_id);
            const tag_id = nextTempId(next_temp_id);
            const is_err_id = nextTempId(next_temp_id);
            const slot_id = nextTempId(next_temp_id);
            const ok_ptr_id = nextTempId(next_temp_id);
            const err_ptr_id = nextTempId(next_temp_id);
            const ok_tag_value_id = nextTempId(next_temp_id);
            const ok_payload_value_id = nextTempId(next_temp_id);
            const ok_full_value_id = nextTempId(next_temp_id);
            const err_tag_value_id = nextTempId(next_temp_id);
            const err_payload_value_id = nextTempId(next_temp_id);
            const err_full_value_id = nextTempId(next_temp_id);
            const ok_label = try std.fmt.allocPrint(allocator, "extern_export_result_ok_{}", .{out_id});
            defer allocator.free(ok_label);
            const err_label = try std.fmt.allocPrint(allocator, "extern_export_result_err_{}", .{out_id});
            defer allocator.free(err_label);
            const cont_label = try std.fmt.allocPrint(allocator, "extern_export_result_cont_{}", .{out_id});
            defer allocator.free(cont_label);
            try writer.print("  %v{} = alloca {s}\n", .{ slot_id, public_ty });
            try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ semantic_value_id, semantic_ty, src_ptr_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ tag_id, semantic_ty, semantic_value_id });
            try writer.print("  %v{} = icmp ne i8 %v{}, 0\n", .{ is_err_id, tag_id });
            try writer.print("  %v{} = getelementptr inbounds {s}, ptr %v{}, i32 0, i32 1\n", .{ ok_ptr_id, semantic_ty, src_ptr_id });
            try writer.print("  %v{} = getelementptr inbounds {s}, ptr %v{}, i32 0, i32 2\n", .{ err_ptr_id, semantic_ty, src_ptr_id });
            try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ is_err_id, err_label, ok_label });
            try writer.print("{s}:\n", .{ok_label});
            const ok_public_id = if (module.types[result_ty.ok] == .void) blk_void: {
                const void_value_id = nextTempId(next_temp_id);
                try writer.print("  %v{} = or i8 0, 0\n", .{void_value_id});
                break :blk_void void_value_id;
            } else try emitExternExportBridgeValue(writer, allocator, module, next_temp_id, result_ty.ok, ok_ptr_id, null);
            try writer.print("  %v{} = insertvalue {s} undef, i8 %v{}, 0\n", .{ ok_tag_value_id, public_ty, tag_id });
            try writer.print("  %v{} = insertvalue {s} %v{}, {s} %v{}, 1\n", .{ ok_payload_value_id, public_ty, ok_tag_value_id, ok_public_ty, ok_public_id });
            try writer.print("  %v{} = insertvalue {s} %v{}, {s} zeroinitializer, 2\n", .{ ok_full_value_id, public_ty, ok_payload_value_id, err_public_ty });
            try writer.print("  store {s} %v{}, ptr %v{}\n", .{ public_ty, ok_full_value_id, slot_id });
            try writer.print("  br label %{s}\n", .{cont_label});
            try writer.print("{s}:\n", .{err_label});
            const err_public_id = try emitExternExportBridgeValue(writer, allocator, module, next_temp_id, result_ty.err, err_ptr_id, null);
            try writer.print("  %v{} = insertvalue {s} undef, i8 %v{}, 0\n", .{ err_tag_value_id, public_ty, tag_id });
            try writer.print("  %v{} = insertvalue {s} %v{}, {s} zeroinitializer, 1\n", .{ err_payload_value_id, public_ty, err_tag_value_id, ok_public_ty });
            try writer.print("  %v{} = insertvalue {s} %v{}, {s} %v{}, 2\n", .{ err_full_value_id, public_ty, err_payload_value_id, err_public_ty, err_public_id });
            try writer.print("  store {s} %v{}, ptr %v{}\n", .{ public_ty, err_full_value_id, slot_id });
            try writer.print("  br label %{s}\n", .{cont_label});
            try writer.print("{s}:\n", .{cont_label});
            try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ out_id, public_ty, slot_id });
            break :blk out_id;
        },
        else => blk: {
            const out_id = dest_id orelse nextTempId(next_temp_id);
            const semantic_ty = try types.llvmScalarType(allocator, module, ty);
            defer allocator.free(semantic_ty);
            try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ out_id, semantic_ty, src_ptr_id });
            break :blk out_id;
        },
    };
}

fn emitExternImportBridgeValue(
    writer: anytype,
    allocator: std.mem.Allocator,
    module: lir.Module,
    next_temp_id: *u32,
    ty: lir.TypeId,
    src_id: u32,
    dest_id: ?u32,
) Error!u32 {
    return switch (module.types[ty]) {
        .bool => blk: {
            const out_id = dest_id orelse nextTempId(next_temp_id);
            try writer.print("  %v{} = icmp ne i8 %v{}, 0\n", .{ out_id, src_id });
            break :blk out_id;
        },
        .dense_array => |elem_ty| blk: {
            const out_id = dest_id orelse nextTempId(next_temp_id);
            const expected_desc = try backend_support.descriptorGlobalName(allocator, module, elem_ty);
            defer allocator.free(expected_desc);
            const header_nonnull_id = nextTempId(next_temp_id);
            const header_id = nextTempId(next_temp_id);
            const elem_desc_id = nextTempId(next_temp_id);
            const data_id = nextTempId(next_temp_id);
            const len_id = nextTempId(next_temp_id);
            const cap_id = nextTempId(next_temp_id);
            const desc_ok_id = nextTempId(next_temp_id);
            const len_nonneg_id = nextTempId(next_temp_id);
            const cap_ge_len_id = nextTempId(next_temp_id);
            const cap_is_zero_id = nextTempId(next_temp_id);
            const data_is_null_id = nextTempId(next_temp_id);
            const data_ok_zero_id = nextTempId(next_temp_id);
            const data_present_nonzero_id = nextTempId(next_temp_id);
            const data_ok_nonzero_id = nextTempId(next_temp_id);
            const data_ok_id = nextTempId(next_temp_id);
            const shape_ok0_id = nextTempId(next_temp_id);
            const shape_ok1_id = nextTempId(next_temp_id);
            const shape_ok2_id = nextTempId(next_temp_id);
            const cv0_id = nextTempId(next_temp_id);
            const cv1_id = nextTempId(next_temp_id);
            const ok_label = try std.fmt.allocPrint(allocator, "extern_import_dense_ok_{}", .{out_id});
            defer allocator.free(ok_label);
            const fail_label = try std.fmt.allocPrint(allocator, "extern_import_dense_fail_{}", .{out_id});
            defer allocator.free(fail_label);
            try writer.print("  %v{} = icmp ne ptr %v{}, null\n", .{ header_nonnull_id, src_id });
            try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ header_nonnull_id, ok_label, fail_label });
            try writer.print("{s}:\n", .{ok_label});
            try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ header_id, dense_runtime_llvm_type, src_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ elem_desc_id, dense_runtime_llvm_type, header_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 3\n", .{ data_id, dense_runtime_llvm_type, header_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 1\n", .{ len_id, dense_runtime_llvm_type, header_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 2\n", .{ cap_id, dense_runtime_llvm_type, header_id });
            try writer.print("  %v{} = icmp eq ptr %v{}, @{s}\n", .{ desc_ok_id, elem_desc_id, expected_desc });
            try writer.print("  %v{} = icmp sge i64 %v{}, 0\n", .{ len_nonneg_id, len_id });
            try writer.print("  %v{} = icmp sge i64 %v{}, %v{}\n", .{ cap_ge_len_id, cap_id, len_id });
            try writer.print("  %v{} = icmp eq i64 %v{}, 0\n", .{ cap_is_zero_id, cap_id });
            try writer.print("  %v{} = icmp eq ptr %v{}, null\n", .{ data_is_null_id, data_id });
            try writer.print("  %v{} = select i1 %v{}, i1 %v{}, i1 true\n", .{ data_ok_zero_id, cap_is_zero_id, data_is_null_id });
            try writer.print("  %v{} = xor i1 %v{}, true\n", .{ data_present_nonzero_id, data_is_null_id });
            try writer.print("  %v{} = select i1 %v{}, i1 true, i1 %v{}\n", .{ data_ok_nonzero_id, cap_is_zero_id, data_present_nonzero_id });
            try writer.print("  %v{} = and i1 %v{}, %v{}\n", .{ shape_ok0_id, desc_ok_id, len_nonneg_id });
            try writer.print("  %v{} = and i1 %v{}, %v{}\n", .{ shape_ok1_id, shape_ok0_id, cap_ge_len_id });
            try writer.print("  %v{} = select i1 %v{}, i1 %v{}, i1 %v{}\n", .{ data_ok_id, cap_is_zero_id, data_ok_zero_id, data_ok_nonzero_id });
            try writer.print("  %v{} = and i1 %v{}, %v{}\n", .{ shape_ok2_id, shape_ok1_id, data_ok_id });
            try writer.print("  br i1 %v{}, label %extern_import_dense_cont_{}, label %{s}\n", .{ shape_ok2_id, out_id, fail_label });
            try writer.print("extern_import_dense_cont_{}:\n", .{out_id});
            try writer.print("  call void @cyna_runtime_tracked_free(ptr %v{})\n", .{src_id});
            try writer.print("  %v{} = insertvalue {s} undef, ptr %v{}, 0\n", .{ cv0_id, dense_carrier_llvm_type, data_id });
            try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 1\n", .{ cv1_id, dense_carrier_llvm_type, cv0_id, len_id });
            try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 2\n", .{ out_id, dense_carrier_llvm_type, cv1_id, cap_id });
            try writer.print("  br label %extern_import_dense_done_{}\n", .{out_id});
            try writer.print("{s}:\n", .{fail_label});
            try writer.writeAll("  call void @cyna_assert_fail()\n");
            try writer.writeAll("  unreachable\n");
            try writer.print("extern_import_dense_done_{}:\n", .{out_id});
            break :blk out_id;
        },
        .sparse_array => |elem_ty| blk: {
            const out_id = dest_id orelse nextTempId(next_temp_id);
            const expected_desc = try backend_support.descriptorGlobalName(allocator, module, elem_ty);
            defer allocator.free(expected_desc);
            const header_nonnull_id = nextTempId(next_temp_id);
            const header_id = nextTempId(next_temp_id);
            const elem_desc_id = nextTempId(next_temp_id);
            const data_id = nextTempId(next_temp_id);
            const occ_id = nextTempId(next_temp_id);
            const len_id = nextTempId(next_temp_id);
            const cap_id = nextTempId(next_temp_id);
            const desc_ok_id = nextTempId(next_temp_id);
            const len_nonneg_id = nextTempId(next_temp_id);
            const cap_nonneg_id = nextTempId(next_temp_id);
            const cap_ge_len_id = nextTempId(next_temp_id);
            const cap_is_zero_id = nextTempId(next_temp_id);
            const occ_is_null_id = nextTempId(next_temp_id);
            const data_is_null_id = nextTempId(next_temp_id);
            const zero_ok0_id = nextTempId(next_temp_id);
            const nonzero_occ_ok_id = nextTempId(next_temp_id);
            const nonzero_data_ok_id = nextTempId(next_temp_id);
            const nonzero_ok_id = nextTempId(next_temp_id);
            const ptrs_ok_id = nextTempId(next_temp_id);
            const shape_ok0_id = nextTempId(next_temp_id);
            const shape_ok1_id = nextTempId(next_temp_id);
            const shape_ok2_id = nextTempId(next_temp_id);
            const shape_ok3_id = nextTempId(next_temp_id);
            const scan_index_slot_id = nextTempId(next_temp_id);
            const scan_count_slot_id = nextTempId(next_temp_id);
            const scan_i_id = nextTempId(next_temp_id);
            const scan_cond_id = nextTempId(next_temp_id);
            const scan_occ_slot_id = nextTempId(next_temp_id);
            const scan_occ_byte_id = nextTempId(next_temp_id);
            const scan_is_zero_id = nextTempId(next_temp_id);
            const scan_is_one_id = nextTempId(next_temp_id);
            const scan_byte_ok_id = nextTempId(next_temp_id);
            const scan_present_id = nextTempId(next_temp_id);
            const scan_count_id = nextTempId(next_temp_id);
            const scan_count_inc_id = nextTempId(next_temp_id);
            const scan_count_next_id = nextTempId(next_temp_id);
            const scan_i_next_id = nextTempId(next_temp_id);
            const scan_final_count_id = nextTempId(next_temp_id);
            const scan_count_ok_id = nextTempId(next_temp_id);
            const cv0_id = nextTempId(next_temp_id);
            const cv1_id = nextTempId(next_temp_id);
            const cv2_id = nextTempId(next_temp_id);
            const ok_label = try std.fmt.allocPrint(allocator, "extern_import_sparse_ok_{}", .{out_id});
            defer allocator.free(ok_label);
            const validate_label = try std.fmt.allocPrint(allocator, "extern_import_sparse_validate_{}", .{out_id});
            defer allocator.free(validate_label);
            const scan_cond_label = try std.fmt.allocPrint(allocator, "extern_import_sparse_scan_cond_{}", .{out_id});
            defer allocator.free(scan_cond_label);
            const scan_body_label = try std.fmt.allocPrint(allocator, "extern_import_sparse_scan_body_{}", .{out_id});
            defer allocator.free(scan_body_label);
            const scan_inc_label = try std.fmt.allocPrint(allocator, "extern_import_sparse_scan_inc_{}", .{out_id});
            defer allocator.free(scan_inc_label);
            const scan_done_label = try std.fmt.allocPrint(allocator, "extern_import_sparse_scan_done_{}", .{out_id});
            defer allocator.free(scan_done_label);
            const fail_label = try std.fmt.allocPrint(allocator, "extern_import_sparse_fail_{}", .{out_id});
            defer allocator.free(fail_label);
            try writer.print("  %v{} = icmp ne ptr %v{}, null\n", .{ header_nonnull_id, src_id });
            try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ header_nonnull_id, ok_label, fail_label });
            try writer.print("{s}:\n", .{ok_label});
            try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ header_id, sparse_runtime_llvm_type, src_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ elem_desc_id, sparse_runtime_llvm_type, header_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 4\n", .{ data_id, sparse_runtime_llvm_type, header_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 3\n", .{ occ_id, sparse_runtime_llvm_type, header_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 1\n", .{ len_id, sparse_runtime_llvm_type, header_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 2\n", .{ cap_id, sparse_runtime_llvm_type, header_id });
            try writer.print("  %v{} = icmp eq ptr %v{}, @{s}\n", .{ desc_ok_id, elem_desc_id, expected_desc });
            try writer.print("  %v{} = icmp sge i64 %v{}, 0\n", .{ len_nonneg_id, len_id });
            try writer.print("  %v{} = icmp sge i64 %v{}, 0\n", .{ cap_nonneg_id, cap_id });
            try writer.print("  %v{} = icmp sge i64 %v{}, %v{}\n", .{ cap_ge_len_id, cap_id, len_id });
            try writer.print("  %v{} = icmp eq i64 %v{}, 0\n", .{ cap_is_zero_id, cap_id });
            try writer.print("  %v{} = icmp eq ptr %v{}, null\n", .{ occ_is_null_id, occ_id });
            try writer.print("  %v{} = icmp eq ptr %v{}, null\n", .{ data_is_null_id, data_id });
            try writer.print("  %v{} = and i1 %v{}, %v{}\n", .{ zero_ok0_id, occ_is_null_id, data_is_null_id });
            try writer.print("  %v{} = xor i1 %v{}, true\n", .{ nonzero_occ_ok_id, occ_is_null_id });
            try writer.print("  %v{} = xor i1 %v{}, true\n", .{ nonzero_data_ok_id, data_is_null_id });
            try writer.print("  %v{} = and i1 %v{}, %v{}\n", .{ nonzero_ok_id, nonzero_occ_ok_id, nonzero_data_ok_id });
            try writer.print("  %v{} = select i1 %v{}, i1 %v{}, i1 %v{}\n", .{ ptrs_ok_id, cap_is_zero_id, zero_ok0_id, nonzero_ok_id });
            try writer.print("  %v{} = and i1 %v{}, %v{}\n", .{ shape_ok0_id, desc_ok_id, len_nonneg_id });
            try writer.print("  %v{} = and i1 %v{}, %v{}\n", .{ shape_ok1_id, shape_ok0_id, cap_nonneg_id });
            try writer.print("  %v{} = and i1 %v{}, %v{}\n", .{ shape_ok2_id, shape_ok1_id, cap_ge_len_id });
            try writer.print("  %v{} = and i1 %v{}, %v{}\n", .{ shape_ok3_id, shape_ok2_id, ptrs_ok_id });
            try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ shape_ok3_id, validate_label, fail_label });
            try writer.print("{s}:\n", .{validate_label});
            try writer.print("  %v{} = alloca i64\n", .{scan_index_slot_id});
            try writer.print("  %v{} = alloca i64\n", .{scan_count_slot_id});
            try writer.print("  store i64 0, ptr %v{}\n", .{scan_index_slot_id});
            try writer.print("  store i64 0, ptr %v{}\n", .{scan_count_slot_id});
            try writer.print("  br label %{s}\n", .{scan_cond_label});
            try writer.print("{s}:\n", .{scan_cond_label});
            try writer.print("  %v{} = load i64, ptr %v{}\n", .{ scan_i_id, scan_index_slot_id });
            try writer.print("  %v{} = icmp slt i64 %v{}, %v{}\n", .{ scan_cond_id, scan_i_id, cap_id });
            try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ scan_cond_id, scan_body_label, scan_done_label });
            try writer.print("{s}:\n", .{scan_body_label});
            try writer.print("  %v{} = getelementptr inbounds i8, ptr %v{}, i64 %v{}\n", .{ scan_occ_slot_id, occ_id, scan_i_id });
            try writer.print("  %v{} = load i8, ptr %v{}\n", .{ scan_occ_byte_id, scan_occ_slot_id });
            try writer.print("  %v{} = icmp eq i8 %v{}, 0\n", .{ scan_is_zero_id, scan_occ_byte_id });
            try writer.print("  %v{} = icmp eq i8 %v{}, 1\n", .{ scan_is_one_id, scan_occ_byte_id });
            try writer.print("  %v{} = or i1 %v{}, %v{}\n", .{ scan_byte_ok_id, scan_is_zero_id, scan_is_one_id });
            try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ scan_byte_ok_id, scan_inc_label, fail_label });
            try writer.print("{s}:\n", .{scan_inc_label});
            try writer.print("  %v{} = icmp ne i8 %v{}, 0\n", .{ scan_present_id, scan_occ_byte_id });
            try writer.print("  %v{} = load i64, ptr %v{}\n", .{ scan_count_id, scan_count_slot_id });
            try writer.print("  %v{} = select i1 %v{}, i64 1, i64 0\n", .{ scan_count_inc_id, scan_present_id });
            try writer.print("  %v{} = add i64 %v{}, %v{}\n", .{ scan_count_next_id, scan_count_id, scan_count_inc_id });
            try writer.print("  store i64 %v{}, ptr %v{}\n", .{ scan_count_next_id, scan_count_slot_id });
            try writer.print("  %v{} = add i64 %v{}, 1\n", .{ scan_i_next_id, scan_i_id });
            try writer.print("  store i64 %v{}, ptr %v{}\n", .{ scan_i_next_id, scan_index_slot_id });
            try writer.print("  br label %{s}\n", .{scan_cond_label});
            try writer.print("{s}:\n", .{scan_done_label});
            try writer.print("  %v{} = load i64, ptr %v{}\n", .{ scan_final_count_id, scan_count_slot_id });
            try writer.print("  %v{} = icmp eq i64 %v{}, %v{}\n", .{ scan_count_ok_id, scan_final_count_id, len_id });
            try writer.print("  br i1 %v{}, label %extern_import_sparse_cont_{}, label %{s}\n", .{ scan_count_ok_id, out_id, fail_label });
            try writer.print("extern_import_sparse_cont_{}:\n", .{out_id});
            try writer.print("  call void @cyna_runtime_tracked_free(ptr %v{})\n", .{src_id});
            try writer.print("  %v{} = insertvalue {s} undef, ptr %v{}, 0\n", .{ cv0_id, sparse_carrier_llvm_type, data_id });
            try writer.print("  %v{} = insertvalue {s} %v{}, ptr %v{}, 1\n", .{ cv1_id, sparse_carrier_llvm_type, cv0_id, occ_id });
            try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 2\n", .{ cv2_id, sparse_carrier_llvm_type, cv1_id, len_id });
            try writer.print("  %v{} = insertvalue {s} %v{}, i64 %v{}, 3\n", .{ out_id, sparse_carrier_llvm_type, cv2_id, cap_id });
            try writer.print("  br label %extern_import_sparse_done_{}\n", .{out_id});
            try writer.print("{s}:\n", .{fail_label});
            try writer.writeAll("  call void @cyna_assert_fail()\n");
            try writer.writeAll("  unreachable\n");
            try writer.print("extern_import_sparse_done_{}:\n", .{out_id});
            break :blk out_id;
        },
        .optional => |payload_ty| blk: {
            const out_id = dest_id orelse nextTempId(next_temp_id);
            const optional_public_ty = (try abi.publicCallableBoundaryType(allocator, module, ty)).?;
            defer allocator.free(optional_public_ty);
            const payload_sem_ty = try types.llvmScalarType(allocator, module, payload_ty);
            defer allocator.free(payload_sem_ty);
            const optional_sem_ty = try types.llvmScalarType(allocator, module, ty);
            defer allocator.free(optional_sem_ty);
            if (abi.isNullablePointer(module, ty)) {
                const present_id = nextTempId(next_temp_id);
                const tag_id = nextTempId(next_temp_id);
                const tagged_id = nextTempId(next_temp_id);
                try writer.print("  %v{} = icmp ne ptr %v{}, null\n", .{ present_id, src_id });
                try writer.print("  %v{} = zext i1 %v{} to i8\n", .{ tag_id, present_id });
                try writer.print("  %v{} = insertvalue {s} zeroinitializer, i8 %v{}, 0\n", .{ tagged_id, optional_sem_ty, tag_id });
                try writer.print("  %v{} = insertvalue {s} %v{}, ptr %v{}, 1\n", .{ out_id, optional_sem_ty, tagged_id, src_id });
                break :blk out_id;
            }
            const tag_id = nextTempId(next_temp_id);
            const payload_src_id = nextTempId(next_temp_id);
            const tag_is_some_id = nextTempId(next_temp_id);
            const slot_id = nextTempId(next_temp_id);
            const none_value_id = nextTempId(next_temp_id);
            const some_value_id = nextTempId(next_temp_id);
            const some_payload_id = nextTempId(next_temp_id);
            const some_label = try std.fmt.allocPrint(allocator, "extern_import_optional_some_{}", .{out_id});
            defer allocator.free(some_label);
            const none_label = try std.fmt.allocPrint(allocator, "extern_import_optional_none_{}", .{out_id});
            defer allocator.free(none_label);
            const cont_label = try std.fmt.allocPrint(allocator, "extern_import_optional_cont_{}", .{out_id});
            defer allocator.free(cont_label);
            try writer.print("  %v{} = alloca {s}\n", .{ slot_id, optional_sem_ty });
            try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ tag_id, optional_public_ty, src_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 1\n", .{ payload_src_id, optional_public_ty, src_id });
            try writer.print("  %v{} = icmp ne i8 %v{}, 0\n", .{ tag_is_some_id, tag_id });
            try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ tag_is_some_id, some_label, none_label });
            try writer.print("{s}:\n", .{some_label});
            const payload_out_id = try emitExternImportBridgeValue(writer, allocator, module, next_temp_id, payload_ty, payload_src_id, null);
            try writer.print("  %v{}_tag = insertvalue {s} undef, i8 %v{}, 0\n", .{ some_value_id, optional_sem_ty, tag_id });
            try writer.print("  %v{} = insertvalue {s} %v{}_tag, {s} %v{}, 1\n", .{ some_payload_id, optional_sem_ty, some_value_id, payload_sem_ty, payload_out_id });
            try writer.print("  store {s} %v{}, ptr %v{}\n", .{ optional_sem_ty, some_payload_id, slot_id });
            try writer.print("  br label %{s}\n", .{cont_label});
            try writer.print("{s}:\n", .{none_label});
            try writer.print("  %v{}_tag = insertvalue {s} undef, i8 %v{}, 0\n", .{ none_value_id, optional_sem_ty, tag_id });
            try writer.print("  %v{} = insertvalue {s} %v{}_tag, {s} zeroinitializer, 1\n", .{ none_value_id, optional_sem_ty, none_value_id, payload_sem_ty });
            try writer.print("  store {s} %v{}, ptr %v{}\n", .{ optional_sem_ty, none_value_id, slot_id });
            try writer.print("  br label %{s}\n", .{cont_label});
            try writer.print("{s}:\n", .{cont_label});
            try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ out_id, optional_sem_ty, slot_id });
            break :blk out_id;
        },
        .result => |result_ty| blk: {
            const out_id = dest_id orelse nextTempId(next_temp_id);
            const result_public_ty = (try abi.publicCallableBoundaryType(allocator, module, ty)).?;
            defer allocator.free(result_public_ty);
            const result_sem_ty = try types.llvmScalarType(allocator, module, ty);
            defer allocator.free(result_sem_ty);
            const ok_sem_ty = try types.llvmResultOkType(allocator, module, ty);
            defer allocator.free(ok_sem_ty);
            const err_sem_ty = try types.llvmResultErrType(allocator, module, ty);
            defer allocator.free(err_sem_ty);
            const tag_id = nextTempId(next_temp_id);
            const ok_src_id = nextTempId(next_temp_id);
            const err_src_id = nextTempId(next_temp_id);
            const is_err_id = nextTempId(next_temp_id);
            const slot_id = nextTempId(next_temp_id);
            const ok_value_id = nextTempId(next_temp_id);
            const ok_payload_value_id = nextTempId(next_temp_id);
            const err_value_id = nextTempId(next_temp_id);
            const err_payload_value_id = nextTempId(next_temp_id);
            const ok_label = try std.fmt.allocPrint(allocator, "extern_import_result_ok_{}", .{out_id});
            defer allocator.free(ok_label);
            const err_label = try std.fmt.allocPrint(allocator, "extern_import_result_err_{}", .{out_id});
            defer allocator.free(err_label);
            const cont_label = try std.fmt.allocPrint(allocator, "extern_import_result_cont_{}", .{out_id});
            defer allocator.free(cont_label);
            try writer.print("  %v{} = alloca {s}\n", .{ slot_id, result_sem_ty });
            try writer.print("  %v{} = extractvalue {s} %v{}, 0\n", .{ tag_id, result_public_ty, src_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 1\n", .{ ok_src_id, result_public_ty, src_id });
            try writer.print("  %v{} = extractvalue {s} %v{}, 2\n", .{ err_src_id, result_public_ty, src_id });
            try writer.print("  %v{} = icmp ne i8 %v{}, 0\n", .{ is_err_id, tag_id });
            try writer.print("  br i1 %v{}, label %{s}, label %{s}\n", .{ is_err_id, err_label, ok_label });
            try writer.print("{s}:\n", .{ok_label});
            const ok_out_id = try emitExternImportBridgeValue(writer, allocator, module, next_temp_id, result_ty.ok, ok_src_id, null);
            try writer.print("  %v{}_tag = insertvalue {s} zeroinitializer, i8 %v{}, 0\n", .{ ok_value_id, result_sem_ty, tag_id });
            try writer.print("  %v{} = insertvalue {s} %v{}_tag, {s} %v{}, 1\n", .{ ok_payload_value_id, result_sem_ty, ok_value_id, ok_sem_ty, ok_out_id });
            try writer.print("  %v{}_full = insertvalue {s} %v{}, {s} zeroinitializer, 2\n", .{ ok_payload_value_id, result_sem_ty, ok_payload_value_id, err_sem_ty });
            try writer.print("  store {s} %v{}_full, ptr %v{}\n", .{ result_sem_ty, ok_payload_value_id, slot_id });
            try writer.print("  br label %{s}\n", .{cont_label});
            try writer.print("{s}:\n", .{err_label});
            const err_out_id = try emitExternImportBridgeValue(writer, allocator, module, next_temp_id, result_ty.err, err_src_id, null);
            try writer.print("  %v{}_tag = insertvalue {s} zeroinitializer, i8 %v{}, 0\n", .{ err_value_id, result_sem_ty, tag_id });
            try writer.print("  %v{} = insertvalue {s} %v{}_tag, {s} zeroinitializer, 1\n", .{ err_payload_value_id, result_sem_ty, err_value_id, ok_sem_ty });
            try writer.print("  %v{}_full = insertvalue {s} %v{}, {s} %v{}, 2\n", .{ err_payload_value_id, result_sem_ty, err_payload_value_id, err_sem_ty, err_out_id });
            try writer.print("  store {s} %v{}_full, ptr %v{}\n", .{ result_sem_ty, err_payload_value_id, slot_id });
            try writer.print("  br label %{s}\n", .{cont_label});
            try writer.print("{s}:\n", .{cont_label});
            try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ out_id, result_sem_ty, slot_id });
            break :blk out_id;
        },
        else => src_id,
    };
}

pub fn emitOwnershipTraceComments(writer: anytype, function: lir.Function) Error!void {
    if (function.ownership_trace.len == 0) return;
    try writer.writeAll("  ; ownership:\n");
    for (function.ownership_trace) |line| {
        try writer.writeAll("  ;   ");
        try writer.writeAll(line.text);
        try writer.writeByte('\n');
    }
}

fn emitTraceFileArgs(writer: anytype, function: lir.Function, string_literals: []const llvm_support.StringLiteral) Error!void {
    if (function.debug_source_path) |path| {
        const name = llvm_support.findStringLiteralName(string_literals, path) orelse return error.BackendInvariantViolation;
        try writer.print("ptr getelementptr inbounds ([{} x i8], ptr @{s}, i64 0, i64 0), i64 {}", .{ path.len + 1, name, path.len });
    } else {
        try writer.writeAll("ptr null, i64 0");
    }
}

pub fn emitInstruction(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    function: lir.Function,
    info: []const common.ValueInfo,
    inst: lir.Inst,
    string_literals: []const llvm_support.StringLiteral,
    next_temp_id: *u32,
) Error!void {
    if (inst.id) |id| {
        if (next_temp_id.* <= id) next_temp_id.* = id + 1;
    }
    switch (inst.data) {
        .const_int, .const_float, .const_bool, .param_ref, .type_desc, .global_addr => return,
        .const_string => |value| {
            const lit_name = llvm_support.findStringLiteralName(string_literals, value) orelse return error.BackendInvariantViolation;
            try writer.print("  %v{}_ptr = getelementptr inbounds [{d} x i8], ptr @{s}, i64 0, i64 0\n", .{
                inst.id.?,
                value.len + 1,
                lit_name,
            });
            try writer.print("  %v{}_len = insertvalue {{ ptr, i64 }} undef, ptr %v{}_ptr, 0\n", .{
                inst.id.?,
                inst.id.?,
            });
            try writer.print("  %v{} = insertvalue {{ ptr, i64 }} %v{}_len, i64 {}, 1\n", .{
                inst.id.?,
                inst.id.?,
                value.len,
            });
        },
        .const_c_str => |value| {
            const lit_name = llvm_support.findStringLiteralName(string_literals, value) orelse return error.BackendInvariantViolation;
            try writer.print("  %v{} = getelementptr inbounds [{d} x i8], ptr @{s}, i64 0, i64 0\n", .{
                inst.id.?,
                value.len + 1,
                lit_name,
            });
        },
        .stack_alloc => |pointee| {
            const pointee_ty = try types.llvmScalarType(allocator, module, pointee);
            defer allocator.free(pointee_ty);
            try writer.print("  %v{} = alloca {s}\n", .{ inst.id.?, pointee_ty });
        },
        .field_ptr => |field| {
            const base_pointee = info[field.ptr].pointee orelse return error.BackendInvariantViolation;
            switch (module.types[base_pointee]) {
                .@"struct" => |struct_ty| try requireAddressableStructFields(struct_ty),
                else => {},
            }
            const base_pointee_ty = try types.llvmPointeeType(allocator, module, info, field.ptr);
            defer allocator.free(base_pointee_ty);
            try writer.print("  %v{} = getelementptr inbounds {s}, ptr ", .{ inst.id.?, base_pointee_ty });
            try common.writeValueRef(writer, module, info, field.ptr);
            try writer.print(", i32 0, i32 {}\n", .{field.field_index});
        },
        .index_ptr => |index| {
            const base_pointee_ty = try types.llvmPointeeType(allocator, module, info, index.ptr);
            defer allocator.free(base_pointee_ty);
            const pointee_ty = info[index.ptr].pointee orelse return error.BackendInvariantViolation;
            switch (module.types[pointee_ty]) {
                .array => {
                    try writer.print("  %v{} = getelementptr inbounds {s}, ptr ", .{ inst.id.?, base_pointee_ty });
                    try common.writeValueRef(writer, module, info, index.ptr);
                    try writer.writeAll(", i32 0, i64 ");
                    try common.writeValueRef(writer, module, info, index.index);
                    try writer.writeByte('\n');
                },
                else => {
                    try writer.print("  %v{} = getelementptr inbounds {s}, ptr ", .{ inst.id.?, base_pointee_ty });
                    try common.writeValueRef(writer, module, info, index.ptr);
                    try writer.writeAll(", i64 ");
                    try common.writeValueRef(writer, module, info, index.index);
                    try writer.writeByte('\n');
                },
            }
        },
        .union_payload_ptr => |payload| {
            const base_pointee = info[payload.ptr].pointee orelse return error.BackendInvariantViolation;
            switch (module.types[base_pointee]) {
                .@"union" => {},
                else => return error.BackendInvariantViolation,
            }
            const base_pointee_ty = try types.llvmPointeeType(allocator, module, info, payload.ptr);
            defer allocator.free(base_pointee_ty);
            try writer.print("  %v{} = getelementptr inbounds {s}, ptr ", .{ inst.id.?, base_pointee_ty });
            try common.writeValueRef(writer, module, info, payload.ptr);
            try writer.print(", i32 0, i32 {}\n", .{@as(i64, payload.union_tag) + 1});
        },
        .load => |ptr| {
            const pointee_ty = try types.llvmPointeeType(allocator, module, info, ptr);
            defer allocator.free(pointee_ty);
            const pointee = info[ptr].pointee orelse return error.BackendInvariantViolation;
            try writer.print("  %v{} = load {s}, ptr ", .{ inst.id.?, pointee_ty });
            try common.writeValueRef(writer, module, info, ptr);
            try emitTypeAlignment(writer, module, pointee);
            try writer.writeByte('\n');
        },
        .volatile_load => |ptr| {
            const pointee_ty = try types.llvmPointeeType(allocator, module, info, ptr);
            defer allocator.free(pointee_ty);
            try writer.print("  %v{} = load volatile {s}, ptr ", .{ inst.id.?, pointee_ty });
            try common.writeValueRef(writer, module, info, ptr);
            try writer.writeByte('\n');
        },
        .store => |store| {
            const value_ty = try types.llvmValueType(allocator, module, info, store.value);
            defer allocator.free(value_ty);
            const semantic_ty = info[store.value].ty orelse return error.BackendInvariantViolation;
            try writer.print("  store {s} ", .{value_ty});
            try common.writeValueRef(writer, module, info, store.value);
            try writer.writeAll(", ptr ");
            try common.writeValueRef(writer, module, info, store.ptr);
            try emitTypeAlignment(writer, module, semantic_ty);
            try writer.writeByte('\n');
        },
        .volatile_store => |store| {
            const value_ty = try types.llvmValueType(allocator, module, info, store.value);
            defer allocator.free(value_ty);
            try writer.print("  store volatile {s} ", .{value_ty});
            try common.writeValueRef(writer, module, info, store.value);
            try writer.writeAll(", ptr ");
            try common.writeValueRef(writer, module, info, store.ptr);
            try writer.writeByte('\n');
        },
        .inline_asm => |asm_stmt| {
            const has_output = inst.id != null;
            const template = try buildInlineAsmTemplate(allocator, asm_stmt.lines, asm_stmt.output, asm_stmt.inout, asm_stmt.input_names, has_output);
            defer allocator.free(template);
            const escaped = try llvm_support.escapeBytes(allocator, template);
            defer allocator.free(escaped);
            const constraints = try buildInlineAsmConstraints(allocator, module, info, asm_stmt.output, asm_stmt.inout, asm_stmt.input_constraints, asm_stmt.args, asm_stmt.clobbers, has_output);
            defer allocator.free(constraints);
            if (has_output) {
                const result_ty = try types.llvmScalarType(allocator, module, inst.ty orelse return error.BackendInvariantViolation);
                defer allocator.free(result_ty);
                try writer.print("  %v{} = call {s} asm", .{ inst.id.?, result_ty });
            } else {
                try writer.writeAll("  call void asm");
            }
            if (asm_stmt.is_volatile) try writer.writeAll(" sideeffect");
            try writer.print(" \"{s}\", \"{s}\"(", .{ escaped, constraints });
            var emitted_arg = false;
            if (asm_stmt.inout) |inout| {
                const arg_ty = try types.llvmValueType(allocator, module, info, inout.seed);
                defer allocator.free(arg_ty);
                try writer.print("{s} ", .{arg_ty});
                try common.writeValueRef(writer, module, info, inout.seed);
                emitted_arg = true;
            }
            for (asm_stmt.args, 0..) |arg, i| {
                if (i != 0 or emitted_arg) try writer.writeAll(", ");
                const arg_ty = try types.llvmValueType(allocator, module, info, arg);
                defer allocator.free(arg_ty);
                try writer.print("{s} ", .{arg_ty});
                try common.writeValueRef(writer, module, info, arg);
            }
            try writer.writeAll(")\n");
        },
        .int_binop => |bin| {
            const inst_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(inst_ty);
            const op = switch (bin.op) {
                .add => "add",
                .wrap_add => "add",
                .sub => "sub",
                .wrap_sub => "sub",
                .mul => "mul",
                .wrap_mul => "mul",
                .div => blk: {
                    const int_ty = switch (module.types[inst.ty.?]) {
                        .int => |int_ty| int_ty,
                        else => return error.BackendInvariantViolation,
                    };
                    break :blk if (int_ty.signed) "sdiv" else "udiv";
                },
                .mod => blk: {
                    const int_ty = switch (module.types[inst.ty.?]) {
                        .int => |int_ty| int_ty,
                        else => return error.BackendInvariantViolation,
                    };
                    break :blk if (int_ty.signed) "srem" else "urem";
                },
                .shl => "shl",
                .shr => blk: {
                    const int_ty = switch (module.types[inst.ty.?]) {
                        .int => |int_ty| int_ty,
                        else => return error.BackendInvariantViolation,
                    };
                    break :blk if (int_ty.signed) "ashr" else "lshr";
                },
                .bit_and => "and",
                .bit_or => "or",
                .bit_xor => "xor",
            };
            try writer.print("  %v{} = {s} {s} ", .{
                inst.id.?,
                op,
                inst_ty,
            });
            try common.writeValueRef(writer, module, info, bin.lhs);
            try writer.writeAll(", ");
            try common.writeValueRef(writer, module, info, bin.rhs);
            try writer.writeByte('\n');
        },
        .int_cmp => |cmp| {
            const operand_ty = try types.llvmValueType(allocator, module, info, cmp.lhs);
            defer allocator.free(operand_ty);
            const predicate = switch (cmp.op) {
                .eq => "eq",
                .ne => "ne",
                .lt, .le, .gt, .ge => blk: {
                    const operand_value_ty = info[cmp.lhs].ty orelse return error.BackendInvariantViolation;
                    const int_ty = switch (module.types[operand_value_ty]) {
                        .int => |int_ty| int_ty,
                        else => return error.BackendInvariantViolation,
                    };
                    break :blk switch (cmp.op) {
                        .lt => if (int_ty.signed) "slt" else "ult",
                        .le => if (int_ty.signed) "sle" else "ule",
                        .gt => if (int_ty.signed) "sgt" else "ugt",
                        .ge => if (int_ty.signed) "sge" else "uge",
                        else => unreachable,
                    };
                },
            };
            try writer.print("  %v{} = icmp {s} {s} ", .{
                inst.id.?,
                predicate,
                operand_ty,
            });
            try common.writeValueRef(writer, module, info, cmp.lhs);
            try writer.writeAll(", ");
            try common.writeValueRef(writer, module, info, cmp.rhs);
            try writer.writeByte('\n');
        },
        .int_to_int => |value| {
            const src_value_ty = info[value].ty orelse return error.BackendInvariantViolation;
            const dst_value_ty = inst.ty.?;
            const src_ty = try types.llvmValueType(allocator, module, info, value);
            defer allocator.free(src_ty);
            const dst_ty = try types.llvmScalarType(allocator, module, dst_value_ty);
            defer allocator.free(dst_ty);
            const src_int = switch (module.types[src_value_ty]) {
                .int => |int_ty| int_ty,
                else => return error.BackendInvariantViolation,
            };
            const dst_int = switch (module.types[dst_value_ty]) {
                .int => |int_ty| int_ty,
                else => return error.BackendInvariantViolation,
            };
            const op: ?[]const u8 = if (src_int.bits > dst_int.bits)
                "trunc"
            else if (src_int.bits < dst_int.bits and src_int.signed)
                "sext"
            else if (src_int.bits < dst_int.bits)
                "zext"
            else
                null;
            if (op) |op_name| {
                try writer.print("  %v{} = {s} {s} ", .{ inst.id.?, op_name, src_ty });
                try common.writeValueRef(writer, module, info, value);
                try writer.print(" to {s}\n", .{dst_ty});
            } else {
                try writer.print("  %v{} = or {s} ", .{ inst.id.?, src_ty });
                try common.writeValueRef(writer, module, info, value);
                try writer.writeAll(", 0\n");
            }
        },
        .int_to_ptr => |value| {
            const src_ty = try types.llvmValueType(allocator, module, info, value);
            defer allocator.free(src_ty);
            const dst_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(dst_ty);
            try writer.print("  %v{} = inttoptr {s} ", .{ inst.id.?, src_ty });
            try common.writeValueRef(writer, module, info, value);
            try writer.print(" to {s}\n", .{dst_ty});
        },
        .ptr_to_int => |value| {
            const src_ty = try types.llvmValueType(allocator, module, info, value);
            defer allocator.free(src_ty);
            const dst_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(dst_ty);
            try writer.print("  %v{} = ptrtoint {s} ", .{ inst.id.?, src_ty });
            try common.writeValueRef(writer, module, info, value);
            try writer.print(" to {s}\n", .{dst_ty});
        },
        .bitcast => |value| {
            const src_ty = try types.llvmValueType(allocator, module, info, value);
            defer allocator.free(src_ty);
            const dst_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(dst_ty);
            if (std.mem.eql(u8, src_ty, dst_ty)) {
                if (std.mem.eql(u8, dst_ty, "ptr")) {
                    try writer.print("  %v{} = getelementptr i8, ptr ", .{inst.id.?});
                    try common.writeValueRef(writer, module, info, value);
                    try writer.writeAll(", i64 0\n");
                } else {
                    try writer.print("  %v{} = or {s} ", .{ inst.id.?, dst_ty });
                    try common.writeValueRef(writer, module, info, value);
                    try writer.writeAll(", 0\n");
                }
            } else {
                try writer.print("  %v{} = bitcast {s} ", .{ inst.id.?, src_ty });
                try common.writeValueRef(writer, module, info, value);
                try writer.print(" to {s}\n", .{dst_ty});
            }
        },
        .packed_to_int => |value| {
            const src_ty = try types.llvmValueType(allocator, module, info, value);
            defer allocator.free(src_ty);
            const dst_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(dst_ty);
            if (std.mem.eql(u8, src_ty, dst_ty)) {
                try writer.print("  %v{} = or {s} ", .{ inst.id.?, dst_ty });
                try common.writeValueRef(writer, module, info, value);
                try writer.writeAll(", 0\n");
            } else {
                try writer.print("  %v{} = bitcast {s} ", .{ inst.id.?, src_ty });
                try common.writeValueRef(writer, module, info, value);
                try writer.print(" to {s}\n", .{dst_ty});
            }
        },
        .int_to_packed => |value| {
            const src_value_ty = info[value].ty orelse return error.BackendInvariantViolation;
            const src_ty = try types.llvmValueType(allocator, module, info, value);
            defer allocator.free(src_ty);
            const dst_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(dst_ty);
            const src_int = switch (module.types[src_value_ty]) {
                .int => |int_ty| int_ty,
                else => return error.BackendInvariantViolation,
            };
            const dst_bits = switch (module.types[inst.ty.?]) {
                .@"struct" => |struct_ty| @max(@as(u32, 1), struct_ty.packed_bits),
                else => return error.BackendInvariantViolation,
            };
            const op: ?[]const u8 = if (src_int.bits > dst_bits)
                "trunc"
            else if (src_int.bits < dst_bits and src_int.signed)
                "sext"
            else if (src_int.bits < dst_bits)
                "zext"
            else
                null;
            if (op) |op_name| {
                try writer.print("  %v{} = {s} {s} ", .{ inst.id.?, op_name, src_ty });
                try common.writeValueRef(writer, module, info, value);
                try writer.print(" to {s}\n", .{dst_ty});
            } else {
                try writer.print("  %v{} = or {s} ", .{ inst.id.?, dst_ty });
                try common.writeValueRef(writer, module, info, value);
                try writer.writeAll(", 0\n");
            }
        },
        .int_to_float => |value| {
            const src_ty = try types.llvmValueType(allocator, module, info, value);
            defer allocator.free(src_ty);
            const dst_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(dst_ty);
            const src_value_ty = info[value].ty orelse return error.BackendInvariantViolation;
            const src_int = switch (module.types[src_value_ty]) {
                .int => |int_ty| int_ty,
                else => return error.BackendInvariantViolation,
            };
            try writer.print("  %v{} = {s} {s} ", .{ inst.id.?, if (src_int.signed) "sitofp" else "uitofp", src_ty });
            try common.writeValueRef(writer, module, info, value);
            try writer.print(" to {s}\n", .{dst_ty});
        },
        .float_to_int => |value| {
            const src_ty = try types.llvmValueType(allocator, module, info, value);
            defer allocator.free(src_ty);
            const dst_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(dst_ty);
            const dst_value_ty = inst.ty.?;
            const dst_int = switch (module.types[dst_value_ty]) {
                .int => |int_ty| int_ty,
                else => return error.BackendInvariantViolation,
            };
            try writer.print("  %v{} = {s} {s} ", .{ inst.id.?, if (dst_int.signed) "fptosi" else "fptoui", src_ty });
            try common.writeValueRef(writer, module, info, value);
            try writer.print(" to {s}\n", .{dst_ty});
        },
        .float_to_float => |value| {
            const src_value_ty = info[value].ty orelse return error.BackendInvariantViolation;
            const dst_value_ty = inst.ty.?;
            const src_ty = try types.llvmValueType(allocator, module, info, value);
            defer allocator.free(src_ty);
            const dst_ty = try types.llvmScalarType(allocator, module, dst_value_ty);
            defer allocator.free(dst_ty);
            const src_bits = switch (module.types[src_value_ty]) {
                .float => |float_ty| float_ty.bits,
                else => return error.BackendInvariantViolation,
            };
            const dst_bits = switch (module.types[dst_value_ty]) {
                .float => |float_ty| float_ty.bits,
                else => return error.BackendInvariantViolation,
            };
            const op = if (src_bits < dst_bits) "fpext" else if (src_bits > dst_bits) "fptrunc" else return error.BackendInvariantViolation;
            try writer.print("  %v{} = {s} {s} ", .{ inst.id.?, op, src_ty });
            try common.writeValueRef(writer, module, info, value);
            try writer.print(" to {s}\n", .{dst_ty});
        },
        .float_binop => |bin| {
            const inst_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(inst_ty);
            try writer.print("  %v{} = {s} {s} ", .{
                inst.id.?,
                switch (bin.op) {
                    .add => "fadd",
                    .sub => "fsub",
                    .mul => "fmul",
                    .div => "fdiv",
                },
                inst_ty,
            });
            try common.writeValueRef(writer, module, info, bin.lhs);
            try writer.writeAll(", ");
            try common.writeValueRef(writer, module, info, bin.rhs);
            try writer.writeByte('\n');
        },
        .float_cmp => |cmp| {
            const operand_ty = try types.llvmValueType(allocator, module, info, cmp.lhs);
            defer allocator.free(operand_ty);
            try writer.print("  %v{} = fcmp {s} {s} ", .{
                inst.id.?,
                switch (cmp.op) {
                    .eq => "oeq",
                    .ne => "une",
                    .lt => "olt",
                    .le => "ole",
                    .gt => "ogt",
                    .ge => "oge",
                },
                operand_ty,
            });
            try common.writeValueRef(writer, module, info, cmp.lhs);
            try writer.writeAll(", ");
            try common.writeValueRef(writer, module, info, cmp.rhs);
            try writer.writeByte('\n');
        },
        .string_cmp => |cmp| {
            try writer.print("  %v{}_lhs_ptr = extractvalue {{ ptr, i64 }} ", .{inst.id.?});
            try common.writeValueRef(writer, module, info, cmp.lhs);
            try writer.writeAll(", 0\n");
            try writer.print("  %v{}_lhs_len_raw = extractvalue {{ ptr, i64 }} ", .{inst.id.?});
            try common.writeValueRef(writer, module, info, cmp.lhs);
            try writer.writeAll(", 1\n");
            try writer.print("  %v{}_rhs_ptr = extractvalue {{ ptr, i64 }} ", .{inst.id.?});
            try common.writeValueRef(writer, module, info, cmp.rhs);
            try writer.writeAll(", 0\n");
            try writer.print("  %v{}_rhs_len_raw = extractvalue {{ ptr, i64 }} ", .{inst.id.?});
            try common.writeValueRef(writer, module, info, cmp.rhs);
            try writer.writeAll(", 1\n");
            try writer.print(
                "  %v{}_eq = call i1 @{s}(ptr %v{}_lhs_ptr, i64 %v{}_lhs_len_raw, ptr %v{}_rhs_ptr, i64 %v{}_rhs_len_raw)\n",
                .{ inst.id.?, runtime_symbols.string_eq_symbol, inst.id.?, inst.id.?, inst.id.?, inst.id.? },
            );
            if (cmp.op == .eq) {
                try writer.print("  %v{} = xor i1 %v{}_eq, false\n", .{ inst.id.?, inst.id.? });
            } else {
                try writer.print("  %v{} = xor i1 %v{}_eq, true\n", .{ inst.id.?, inst.id.? });
            }
        },
        .sequence_cmp => |cmp| {
            try writer.print("  %v{}_eq = call i1 @{s}(ptr ", .{ inst.id.?, runtime_symbols.sequence_eq_symbol });
            try common.writeValueRef(writer, module, info, cmp.lhs_ptr);
            try writer.writeAll(", i64 ");
            try common.writeValueRef(writer, module, info, cmp.lhs_len);
            try writer.writeAll(", ptr ");
            try common.writeValueRef(writer, module, info, cmp.rhs_ptr);
            try writer.writeAll(", i64 ");
            try common.writeValueRef(writer, module, info, cmp.rhs_len);
            try writer.writeAll(", ptr ");
            try common.writeValueRef(writer, module, info, cmp.elem_desc);
            try writer.writeAll(")\n");
            if (cmp.op == .eq) {
                try writer.print("  %v{} = xor i1 %v{}_eq, false\n", .{ inst.id.?, inst.id.? });
            } else {
                try writer.print("  %v{} = xor i1 %v{}_eq, true\n", .{ inst.id.?, inst.id.? });
            }
        },
        .sparse_cmp => |cmp| {
            try writer.print("  %v{}_lhs_data = extractvalue {s} ", .{ inst.id.?, sparse_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, cmp.lhs);
            try writer.writeAll(", 0\n");
            try writer.print("  %v{}_lhs_occ = extractvalue {s} ", .{ inst.id.?, sparse_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, cmp.lhs);
            try writer.writeAll(", 1\n");
            try writer.print("  %v{}_lhs_len = extractvalue {s} ", .{ inst.id.?, sparse_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, cmp.lhs);
            try writer.writeAll(", 2\n");
            try writer.print("  %v{}_lhs_cap = extractvalue {s} ", .{ inst.id.?, sparse_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, cmp.lhs);
            try writer.writeAll(", 3\n");
            try writer.print("  %v{}_rhs_data = extractvalue {s} ", .{ inst.id.?, sparse_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, cmp.rhs);
            try writer.writeAll(", 0\n");
            try writer.print("  %v{}_rhs_occ = extractvalue {s} ", .{ inst.id.?, sparse_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, cmp.rhs);
            try writer.writeAll(", 1\n");
            try writer.print("  %v{}_rhs_len = extractvalue {s} ", .{ inst.id.?, sparse_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, cmp.rhs);
            try writer.writeAll(", 2\n");
            try writer.print("  %v{}_rhs_cap = extractvalue {s} ", .{ inst.id.?, sparse_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, cmp.rhs);
            try writer.writeAll(", 3\n");
            try writer.print("  %v{}_eq = call i1 @{s}(ptr %v{}_lhs_data, ptr %v{}_lhs_occ, i64 %v{}_lhs_len, i64 %v{}_lhs_cap, ptr %v{}_rhs_data, ptr %v{}_rhs_occ, i64 %v{}_rhs_len, i64 %v{}_rhs_cap, ptr ", .{
                inst.id.?,
                runtime_symbols.sparse_eq_symbol,
                inst.id.?,
                inst.id.?,
                inst.id.?,
                inst.id.?,
                inst.id.?,
                inst.id.?,
                inst.id.?,
                inst.id.?,
            });
            try common.writeValueRef(writer, module, info, cmp.elem_desc);
            try writer.writeAll(")\n");
            if (cmp.op == .eq) {
                try writer.print("  %v{} = xor i1 %v{}_eq, false\n", .{ inst.id.?, inst.id.? });
            } else {
                try writer.print("  %v{} = xor i1 %v{}_eq, true\n", .{ inst.id.?, inst.id.? });
            }
        },
        .dense_new => |value| {
            _ = value;
            const temp0_id = nextTempId(next_temp_id);
            const temp1_id = nextTempId(next_temp_id);
            try writer.print("  %v{} = insertvalue {s} undef, ptr null, 0\n", .{ temp0_id, dense_carrier_llvm_type });
            try writer.print("  %v{} = insertvalue {s} %v{}, i64 0, 1\n", .{ temp1_id, dense_carrier_llvm_type, temp0_id });
            try writer.print("  %v{} = insertvalue {s} %v{}, i64 0, 2\n", .{ inst.id.?, dense_carrier_llvm_type, temp1_id });
        },
        .dense_copy => |value| try emitStructuralCopyViaDescriptor(allocator, writer, module, info, next_temp_id, inst.id.?, value),
        .dense_len => |value| {
            try writer.print("  %v{} = extractvalue {s} ", .{ inst.id.?, dense_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, value);
            try writer.writeAll(", 1\n");
        },
        .dense_clear => |value| try emitDenseClearMutation(writer, allocator, module, info, next_temp_id, value),
        .dense_reserve => |value| try emitDenseReserveMutation(writer, allocator, module, info, next_temp_id, value, null),
        .dense_data => |value| {
            try writer.print("  %v{} = extractvalue {s} ", .{ inst.id.?, dense_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, value);
            try writer.writeAll(", 0\n");
        },
        .dense_at => |value| {
            const elem_ty = try types.llvmPointeeType(allocator, module, info, inst.id.?);
            defer allocator.free(elem_ty);
            try writer.print("  %v{}_data = extractvalue {s} ", .{ inst.id.?, dense_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, value.a);
            try writer.writeAll(", 0\n");
            try writer.print("  %v{}_len = extractvalue {s} ", .{ inst.id.?, dense_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, value.a);
            try writer.writeAll(", 1\n");
            try writer.print("  %v{}_neg = icmp slt i64 ", .{inst.id.?});
            try common.writeValueRef(writer, module, info, value.b);
            try writer.writeAll(", 0\n");
            try writer.print("  %v{}_hi = icmp sge i64 ", .{inst.id.?});
            try common.writeValueRef(writer, module, info, value.b);
            try writer.print(", %v{}_len\n", .{inst.id.?});
            try writer.print("  %v{}_oob = or i1 %v{}_neg, %v{}_hi\n", .{ inst.id.?, inst.id.?, inst.id.? });
            try writer.print("  br i1 %v{}_oob, label %dense_at_fail_{}, label %dense_at_ok_{}\n", .{ inst.id.?, inst.id.?, inst.id.? });
            try writer.print("dense_at_fail_{}:\n", .{inst.id.?});
            try writer.print("  call void @{s}(i64 ", .{runtime_symbols.bounds_fail_symbol});
            try common.writeValueRef(writer, module, info, value.b);
            try writer.print(", i64 %v{}_len)\n", .{inst.id.?});
            try writer.writeAll("  unreachable\n");
            try writer.print("dense_at_ok_{}:\n", .{inst.id.?});
            try writer.print("  %v{} = getelementptr inbounds {s}, ptr %v{}_data, i64 ", .{ inst.id.?, elem_ty, inst.id.? });
            try common.writeValueRef(writer, module, info, value.b);
            try writer.writeByte('\n');
        },
        .dense_push => |value| try emitDensePushMutation(writer, allocator, module, info, next_temp_id, value, false),
        .dense_push_move => |value| try emitDensePushMutation(writer, allocator, module, info, next_temp_id, value, true),
        .dense_pop => |value| try emitDensePopMutation(writer, allocator, module, info, next_temp_id, value),
        .dense_drop => |value| try emitStructuralDropViaDescriptor(allocator, writer, module, info, next_temp_id, value),
        .sparse_new => |value| try emitSparseCarrierFromNewDirect(writer, allocator, module, info, next_temp_id, inst.id.?, value.lhs, value.rhs),
        .sparse_copy => |value| try emitStructuralCopyViaDescriptor(allocator, writer, module, info, next_temp_id, inst.id.?, value),
        .sparse_drop => |value| try emitStructuralDropViaDescriptor(allocator, writer, module, info, next_temp_id, value),
        .sparse_len => |value| {
            try writer.print("  %v{} = extractvalue {s} ", .{ inst.id.?, sparse_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, value);
            try writer.writeAll(", 2\n");
        },
        .sparse_capacity => |value| {
            try writer.print("  %v{} = extractvalue {s} ", .{ inst.id.?, sparse_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, value);
            try writer.writeAll(", 3\n");
        },
        .sparse_clear => |value| try emitSparseClearMutation(writer, allocator, module, info, next_temp_id, value),
        .sparse_indices => |value| try emitDenseCarrierFromSparseIndices(writer, allocator, module, info, next_temp_id, inst.id.?, value.lhs, value.rhs),
        .sparse_contains_index => |value| {
            try writer.print("  %v{}_occ = extractvalue {s} ", .{ inst.id.?, sparse_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, value.lhs);
            try writer.writeAll(", 1\n");
            try writer.print("  %v{}_cap = extractvalue {s} ", .{ inst.id.?, sparse_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, value.lhs);
            try writer.writeAll(", 3\n");
            try writer.print("  %v{}_neg = icmp slt i64 ", .{inst.id.?});
            try common.writeValueRef(writer, module, info, value.rhs);
            try writer.writeAll(", 0\n");
            try writer.print("  %v{}_hi = icmp sge i64 ", .{inst.id.?});
            try common.writeValueRef(writer, module, info, value.rhs);
            try writer.print(", %v{}_cap\n", .{inst.id.?});
            try writer.print("  %v{}_oob = or i1 %v{}_neg, %v{}_hi\n", .{ inst.id.?, inst.id.?, inst.id.? });
            try writer.print("  br i1 %v{}_oob, label %sparse_contains_fail_{}, label %sparse_contains_ok_{}\n", .{ inst.id.?, inst.id.?, inst.id.? });
            try writer.print("sparse_contains_fail_{}:\n", .{inst.id.?});
            try writer.print("  call void @{s}(i64 ", .{runtime_symbols.bounds_fail_symbol});
            try common.writeValueRef(writer, module, info, value.rhs);
            try writer.print(", i64 %v{}_cap)\n", .{inst.id.?});
            try writer.writeAll("  unreachable\n");
            try writer.print("sparse_contains_ok_{}:\n", .{inst.id.?});
            try writer.print("  %v{}_slot = getelementptr inbounds i8, ptr %v{}_occ, i64 ", .{ inst.id.?, inst.id.? });
            try common.writeValueRef(writer, module, info, value.rhs);
            try writer.writeByte('\n');
            try writer.print("  %v{}_byte = load i8, ptr %v{}_slot\n", .{ inst.id.?, inst.id.? });
            try writer.print("  %v{} = icmp ne i8 %v{}_byte, 0\n", .{ inst.id.?, inst.id.? });
        },
        .sparse_payload_ptr => |value| try emitSparsePayloadPtr(writer, allocator, module, info, inst.id.?, value),
        .sparse_get => |value| {
            const elem_ty = try types.llvmPointeeType(allocator, module, info, value.c);
            defer allocator.free(elem_ty);
            try writer.print("  %v{}_data = extractvalue {s} ", .{ inst.id.?, sparse_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, value.a);
            try writer.writeAll(", 0\n");
            try writer.print("  %v{}_occ = extractvalue {s} ", .{ inst.id.?, sparse_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, value.a);
            try writer.writeAll(", 1\n");
            try writer.print("  %v{}_cap = extractvalue {s} ", .{ inst.id.?, sparse_carrier_llvm_type });
            try common.writeValueRef(writer, module, info, value.a);
            try writer.writeAll(", 3\n");
            try writer.print("  %v{}_neg = icmp slt i64 ", .{inst.id.?});
            try common.writeValueRef(writer, module, info, value.b);
            try writer.writeAll(", 0\n");
            try writer.print("  %v{}_hi = icmp sge i64 ", .{inst.id.?});
            try common.writeValueRef(writer, module, info, value.b);
            try writer.print(", %v{}_cap\n", .{inst.id.?});
            try writer.print("  %v{}_oob = or i1 %v{}_neg, %v{}_hi\n", .{ inst.id.?, inst.id.?, inst.id.? });
            try writer.print("  br i1 %v{}_oob, label %sparse_get_fail_{}, label %sparse_get_check_{}\n", .{ inst.id.?, inst.id.?, inst.id.? });
            try writer.print("sparse_get_fail_{}:\n", .{inst.id.?});
            try writer.print("  call void @{s}(i64 ", .{runtime_symbols.bounds_fail_symbol});
            try common.writeValueRef(writer, module, info, value.b);
            try writer.print(", i64 %v{}_cap)\n", .{inst.id.?});
            try writer.writeAll("  unreachable\n");
            try writer.print("sparse_get_check_{}:\n", .{inst.id.?});
            try writer.print("  %v{}_occ_slot = getelementptr inbounds i8, ptr %v{}_occ, i64 ", .{ inst.id.?, inst.id.? });
            try common.writeValueRef(writer, module, info, value.b);
            try writer.writeByte('\n');
            try writer.print("  %v{}_occ_byte = load i8, ptr %v{}_occ_slot\n", .{ inst.id.?, inst.id.? });
            try writer.print("  %v{}_present = icmp ne i8 %v{}_occ_byte, 0\n", .{ inst.id.?, inst.id.? });
            try writer.print("  br i1 %v{}_present, label %sparse_get_copy_{}, label %sparse_get_none_{}\n", .{ inst.id.?, inst.id.?, inst.id.? });
            try writer.print("sparse_get_copy_{}:\n", .{inst.id.?});
            try writer.print("  %v{}_elem_ptr = getelementptr inbounds {s}, ptr %v{}_data, i64 ", .{ inst.id.?, elem_ty, inst.id.? });
            try common.writeValueRef(writer, module, info, value.b);
            try writer.writeByte('\n');
            try writer.print("  %v{}_copy_slot = getelementptr inbounds {s}, ptr ", .{ inst.id.?, runtime_symbols.type_desc_llvm_type });
            try common.writeValueRef(writer, module, info, value.d);
            try writer.print(", i32 0, i32 {d}\n", .{type_desc_copy_field_index});
            try writer.print("  %v{}_copy_fn = load ptr, ptr %v{}_copy_slot\n", .{ inst.id.?, inst.id.? });
            try writer.print("  call void %v{}_copy_fn(ptr ", .{inst.id.?});
            try common.writeValueRef(writer, module, info, value.c);
            try writer.print(", ptr %v{}_elem_ptr, ptr ", .{inst.id.?});
            try common.writeValueRef(writer, module, info, value.d);
            try writer.writeAll(")\n");
            try writer.print("  br label %sparse_get_done_{}\n", .{inst.id.?});
            try writer.print("sparse_get_none_{}:\n", .{inst.id.?});
            try writer.print("  br label %sparse_get_done_{}\n", .{inst.id.?});
            try writer.print("sparse_get_done_{}:\n", .{inst.id.?});
            try writer.print("  %v{} = xor i1 %v{}_present, false\n", .{ inst.id.?, inst.id.? });
        },
        .sparse_set => |value| try emitSparseSetMutation(writer, allocator, module, info, next_temp_id, value, false),
        .sparse_set_move => |value| try emitSparseSetMutation(writer, allocator, module, info, next_temp_id, value, true),
        .sparse_insert => |value| try emitSparseInsertMutation(writer, allocator, module, info, next_temp_id, value, false),
        .sparse_insert_move => |value| try emitSparseInsertMutation(writer, allocator, module, info, next_temp_id, value, true),
        .sparse_take => |value| try emitSparseTakeMutation(writer, allocator, module, info, next_temp_id, inst.id.?, value),
        .string_len => |value| {
            try writer.print("  %v{}_raw = extractvalue {{ ptr, i64 }} ", .{inst.id.?});
            try common.writeValueRef(writer, module, info, value);
            try writer.writeAll(", 1\n");
            try writer.print("  %v{} = and i64 %v{}_raw, 9223372036854775807\n", .{ inst.id.?, inst.id.? });
        },
        .call => |call| {
            const ArgCleanup = struct {
                ptr_id: u32,
                ty: lir.TypeId,
            };
            var arg_types = std.ArrayListUnmanaged([]u8).empty;
            defer {
                for (arg_types.items) |item| allocator.free(item);
                arg_types.deinit(allocator);
            }
            var arg_refs = std.ArrayListUnmanaged([]u8).empty;
            defer {
                for (arg_refs.items) |item| allocator.free(item);
                arg_refs.deinit(allocator);
            }
            var arg_cleanups = std.ArrayListUnmanaged(ArgCleanup).empty;
            defer arg_cleanups.deinit(allocator);
            const callee = findFunctionByAbiName(module, call.name);
            for (call.args, 0..) |arg, i| {
                if (callee) |callee_fn| {
                    const param = callee_fn.params[i];
                    if (try abi.indirectParamInfo(module, callee_fn, param.ty)) |_| {
                        if (try abi.publicCallableBoundaryType(allocator, module, param.ty)) |public_ty| {
                            defer allocator.free(public_ty);
                            const value_ty = info[arg].ty orelse return error.BackendInvariantViolation;
                            const semantic_ty = try types.llvmScalarType(allocator, module, value_ty);
                            defer allocator.free(semantic_ty);
                            const semantic_ptr_id = nextTempId(next_temp_id);
                            const public_value_id = nextTempId(next_temp_id);
                            const public_ptr_id = nextTempId(next_temp_id);
                            try writer.print("  %v{} = alloca {s}\n", .{ semantic_ptr_id, semantic_ty });
                            try writer.print("  store {s} ", .{semantic_ty});
                            try common.writeValueRef(writer, module, info, arg);
                            try writer.print(", ptr %v{}", .{semantic_ptr_id});
                            try emitTypeAlignment(writer, module, value_ty);
                            try writer.writeByte('\n');
                            _ = try emitExternExportBridgeValue(writer, allocator, module, next_temp_id, param.ty, semantic_ptr_id, public_value_id);
                            try writer.print("  %v{} = alloca {s}\n", .{ public_ptr_id, public_ty });
                            try writer.print("  store {s} %v{}, ptr %v{}", .{ public_ty, public_value_id, public_ptr_id });
                            try emitTypeAlignment(writer, module, param.ty);
                            try writer.writeByte('\n');
                            if (module.target_abi.is_x86_64_sysv and abi.usesCallableBoundary(callee_fn)) {
                                try arg_types.append(allocator, try std.fmt.allocPrint(allocator, "ptr byval({s})", .{public_ty}));
                            } else {
                                try arg_types.append(allocator, try allocator.dupe(u8, "ptr"));
                            }
                            try arg_refs.append(allocator, try std.fmt.allocPrint(allocator, "%v{}", .{public_ptr_id}));
                            continue;
                        }
                        const value_ty = info[arg].ty orelse return error.BackendInvariantViolation;
                        const semantic_ty = try types.llvmScalarType(allocator, module, value_ty);
                        defer allocator.free(semantic_ty);
                        const alloc_id = nextTempId(next_temp_id);
                        try writer.print("  %v{} = alloca {s}\n", .{ alloc_id, semantic_ty });
                        try writer.print("  store {s} ", .{semantic_ty});
                        try common.writeValueRef(writer, module, info, arg);
                        try writer.print(", ptr %v{}", .{alloc_id});
                        try emitTypeAlignment(writer, module, value_ty);
                        try writer.writeByte('\n');
                        if (module.target_abi.is_x86_64_sysv and abi.usesCallableBoundary(callee_fn)) {
                            const byval_ty = try abi.callableBoundaryTypeOrSemantic(allocator, module, param.ty);
                            defer allocator.free(byval_ty);
                            try arg_types.append(allocator, try std.fmt.allocPrint(allocator, "ptr byval({s})", .{byval_ty}));
                        } else {
                            try arg_types.append(allocator, try allocator.dupe(u8, "ptr"));
                        }
                        try arg_refs.append(allocator, try std.fmt.allocPrint(allocator, "%v{}", .{alloc_id}));
                        if (abi.needsExternImportValueBridge(callee_fn) and backend_support.descriptorHelperNeedsGeneration(module, param.ty)) {
                            try arg_cleanups.append(allocator, .{ .ptr_id = alloc_id, .ty = param.ty });
                        }
                        continue;
                    }
                    if (abi.needsExternImportValueBridge(callee_fn)) {
                        if (try abi.publicCallableBoundaryType(allocator, module, param.ty)) |public_ty| {
                            defer allocator.free(public_ty);
                            const value_ty = info[arg].ty orelse return error.BackendInvariantViolation;
                            const semantic_ty = try types.llvmScalarType(allocator, module, value_ty);
                            defer allocator.free(semantic_ty);
                            const semantic_ptr_id = nextTempId(next_temp_id);
                            try writer.print("  %v{} = alloca {s}\n", .{ semantic_ptr_id, semantic_ty });
                            try writer.print("  store {s} ", .{semantic_ty});
                            try common.writeValueRef(writer, module, info, arg);
                            try writer.print(", ptr %v{}", .{semantic_ptr_id});
                            try emitTypeAlignment(writer, module, value_ty);
                            try writer.writeByte('\n');
                            const public_id = try emitExternExportBridgeValue(writer, allocator, module, next_temp_id, param.ty, semantic_ptr_id, null);
                            const abi_ty = try abi.paramType(allocator, module, callee_fn, param.ty);
                            if (std.mem.eql(u8, abi_ty, public_ty)) {
                                try arg_types.append(allocator, abi_ty);
                                try arg_refs.append(allocator, try std.fmt.allocPrint(allocator, "%v{}", .{public_id}));
                            } else {
                                defer allocator.free(abi_ty);
                                const public_ref = try std.fmt.allocPrint(allocator, "%v{}", .{public_id});
                                defer allocator.free(public_ref);
                                const coerced_id = try emitMemoryCoercion(writer, next_temp_id, public_ty, abi_ty, abi_ty, public_ref);
                                try arg_types.append(allocator, try allocator.dupe(u8, abi_ty));
                                try arg_refs.append(allocator, try std.fmt.allocPrint(allocator, "%v{}", .{coerced_id}));
                            }
                            continue;
                        }
                        switch (try abi.callableBoundaryShape(module, callee_fn, param.ty)) {
                            .semantic => {},
                            .dense_header_ptr, .sparse_header_ptr => unreachable,
                            .indirect => unreachable,
                            .scalar_coercion => {
                                const abi_ty = (try abi.cLayoutAbiCoercionType(allocator, module, param.ty)).?;
                                const value_ty = info[arg].ty orelse return error.BackendInvariantViolation;
                                const semantic_ty = try types.llvmScalarType(allocator, module, value_ty);
                                defer allocator.free(semantic_ty);
                                const alloc_id = nextTempId(next_temp_id);
                                try writer.print("  %v{} = alloca {s}\n", .{ alloc_id, semantic_ty });
                                try writer.print("  store {s} ", .{semantic_ty});
                                try common.writeValueRef(writer, module, info, arg);
                                try writer.print(", ptr %v{}", .{alloc_id});
                                try emitTypeAlignment(writer, module, value_ty);
                                try writer.writeByte('\n');

                                const load_id = nextTempId(next_temp_id);
                                try writer.print("  %v{} = load {s}, ptr %v{}", .{ load_id, abi_ty, alloc_id });
                                try emitTypeAlignment(writer, module, param.ty);
                                try writer.writeByte('\n');
                                try arg_types.append(allocator, abi_ty);
                                try arg_refs.append(allocator, try std.fmt.allocPrint(allocator, "%v{}", .{load_id}));
                                continue;
                            },
                        }
                    }
                }

                const arg_ty = try types.llvmValueType(allocator, module, info, arg);
                var arg_ref_buf: std.ArrayListUnmanaged(u8) = .empty;
                errdefer arg_ref_buf.deinit(allocator);
                var arg_ref_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &arg_ref_buf);
                try common.writeValueRef(&arg_ref_writer.writer, module, info, arg);
                arg_ref_buf = arg_ref_writer.toArrayList();
                try arg_types.append(allocator, arg_ty);
                try arg_refs.append(allocator, try arg_ref_buf.toOwnedSlice(allocator));
            }

            if (callee) |callee_fn| {
                if (abi.takesTraceContext(module, callee_fn)) {
                    try arg_types.append(allocator, try allocator.dupe(u8, "ptr"));
                    try arg_refs.append(allocator, try allocator.dupe(u8, "%trace_context"));
                }
            }

            const abi_return_ty = if (callee) |callee_fn|
                try abi.returnType(allocator, module, callee_fn, inst.ty.?)
            else
                try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(abi_return_ty);

            const return_shape: abi.CallableBoundaryShape = if (callee) |callee_fn|
                try abi.callableBoundaryShape(module, callee_fn, inst.ty.?)
            else
                .semantic;
            const needs_public_return_bridge = blk: {
                const callee_fn = callee orelse break :blk false;
                if (!abi.needsExternImportValueBridge(callee_fn)) break :blk false;
                if (try abi.publicCallableBoundaryType(allocator, module, inst.ty.?)) |public_ty| {
                    allocator.free(public_ty);
                    break :blk true;
                }
                break :blk false;
            };
            const needs_return_unpack = if (callee) |callee_fn|
                abi.needsExternImportValueBridge(callee_fn) and return_shape == .scalar_coercion and !needs_public_return_bridge
            else
                false;

            const needs_indirect_return = if (callee) |callee_fn|
                try abi.needsIndirectReturn(module, callee_fn, inst.ty.?)
            else
                false;
            var result_ptr_id: ?u32 = null;
            var indirect_return_ty: ?[]u8 = null;
            defer if (indirect_return_ty) |value| allocator.free(value);

            if (std.mem.eql(u8, abi_return_ty, "void")) {
                if (needs_indirect_return) {
                    indirect_return_ty = if (callee) |callee_fn|
                        if (abi.usesCallableBoundary(callee_fn))
                            try abi.callableBoundaryTypeOrSemantic(allocator, module, inst.ty.?)
                        else
                            try types.llvmScalarType(allocator, module, inst.ty.?)
                    else
                        try types.llvmScalarType(allocator, module, inst.ty.?);
                    const alloc_id = nextTempId(next_temp_id);
                    result_ptr_id = alloc_id;
                    try writer.print("  %v{} = alloca {s}\n", .{ alloc_id, indirect_return_ty.? });
                }
                try writer.print("  call {s} ", .{abi_return_ty});
                try common.writeAtName(writer, call.name);
                try writer.writeByte('(');
                if (needs_indirect_return) {
                    try writer.print("ptr sret({s}) %v{}", .{ indirect_return_ty.?, result_ptr_id.? });
                    if (arg_types.items.len != 0) try writer.writeAll(", ");
                }
            } else {
                if (needs_return_unpack) {
                    const call_id = nextTempId(next_temp_id);
                    try writer.print("  %v{} = call {s} ", .{ call_id, abi_return_ty });
                    try common.writeAtName(writer, call.name);
                    try writer.writeByte('(');
                    for (arg_types.items, arg_refs.items, 0..) |arg_ty, arg_ref, i| {
                        if (i != 0) try writer.writeAll(", ");
                        try writer.print("{s} ", .{arg_ty});
                        try writer.writeAll(arg_ref);
                    }
                    try writer.writeAll(")\n");
                    for (arg_cleanups.items) |cleanup| {
                        try emitDropStoredValueByDescriptor(allocator, writer, module, cleanup.ty, cleanup.ptr_id);
                    }

                    const semantic_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
                    defer allocator.free(semantic_ty);
                    const alloc_id = nextTempId(next_temp_id);
                    try writer.print("  %v{} = alloca {s}\n", .{ alloc_id, semantic_ty });
                    try writer.print("  store {s} %v{}, ptr %v{}", .{ abi_return_ty, call_id, alloc_id });
                    try emitTypeAlignment(writer, module, inst.ty.?);
                    try writer.writeByte('\n');
                    try writer.print("  %v{} = load {s}, ptr %v{}", .{ inst.id.?, semantic_ty, alloc_id });
                    try emitTypeAlignment(writer, module, inst.ty.?);
                    try writer.writeByte('\n');
                    return;
                }

                if (callee) |callee_fn| {
                    if (needs_public_return_bridge or (abi.needsExternImportValueBridge(callee_fn) and return_shape != .semantic)) {
                        const call_id = nextTempId(next_temp_id);
                        try writer.print("  %v{} = call {s} ", .{ call_id, abi_return_ty });
                        try common.writeAtName(writer, call.name);
                        try writer.writeByte('(');
                        for (arg_types.items, arg_refs.items, 0..) |arg_ty, arg_ref, i| {
                            if (i != 0) try writer.writeAll(", ");
                            try writer.print("{s} ", .{arg_ty});
                            try writer.writeAll(arg_ref);
                        }
                        try writer.writeAll(")\n");
                        for (arg_cleanups.items) |cleanup| {
                            try emitDropStoredValueByDescriptor(allocator, writer, module, cleanup.ty, cleanup.ptr_id);
                        }
                        const bridge_src_id = if (needs_public_return_bridge) blk_bridge: {
                            const public_ty = (try abi.publicCallableBoundaryType(allocator, module, inst.ty.?)).?;
                            defer allocator.free(public_ty);
                            if (std.mem.eql(u8, abi_return_ty, public_ty)) break :blk_bridge call_id;
                            const call_ref = try std.fmt.allocPrint(allocator, "%v{}", .{call_id});
                            defer allocator.free(call_ref);
                            break :blk_bridge try emitMemoryCoercion(writer, next_temp_id, abi_return_ty, public_ty, abi_return_ty, call_ref);
                        } else call_id;
                        _ = try emitExternImportBridgeValue(writer, allocator, module, next_temp_id, inst.ty.?, bridge_src_id, inst.id.?);
                        return;
                    }
                }

                try writer.print("  %v{} = call {s} ", .{ inst.id.?, abi_return_ty });
                try common.writeAtName(writer, call.name);
                try writer.writeByte('(');
            }
            for (arg_types.items, arg_refs.items, 0..) |arg_ty, arg_ref, i| {
                if (i != 0) try writer.writeAll(", ");
                try writer.print("{s} ", .{arg_ty});
                try writer.writeAll(arg_ref);
            }
            try writer.writeAll(")\n");
            for (arg_cleanups.items) |cleanup| {
                try emitDropStoredValueByDescriptor(allocator, writer, module, cleanup.ty, cleanup.ptr_id);
            }
            if (needs_indirect_return) {
                if (callee) |callee_fn| {
                    if (abi.needsExternImportValueBridge(callee_fn)) {
                        if (try abi.publicCallableBoundaryType(allocator, module, inst.ty.?)) |public_return_ty| {
                            defer allocator.free(public_return_ty);
                            const public_value_id = nextTempId(next_temp_id);
                            try writer.print("  %v{} = load {s}, ptr %v{}", .{ public_value_id, public_return_ty, result_ptr_id.? });
                            try emitTypeAlignment(writer, module, inst.ty.?);
                            try writer.writeByte('\n');
                            _ = try emitExternImportBridgeValue(writer, allocator, module, next_temp_id, inst.ty.?, public_value_id, inst.id.?);
                            return;
                        }
                    }
                }
                const semantic_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
                defer allocator.free(semantic_ty);
                try writer.print("  %v{} = load {s}, ptr %v{}", .{ inst.id.?, semantic_ty, result_ptr_id.? });
                try emitTypeAlignment(writer, module, inst.ty.?);
                try writer.writeByte('\n');
            }
        },
        .indirect_call => |call| {
            var callee_abi = function;
            callee_abi.calling_convention = .cyna;
            callee_abi.is_extern = false;
            callee_abi.is_export = false;
            var arg_types = std.ArrayListUnmanaged([]u8).empty;
            defer {
                for (arg_types.items) |item| allocator.free(item);
                arg_types.deinit(allocator);
            }
            var arg_refs = std.ArrayListUnmanaged([]u8).empty;
            defer {
                for (arg_refs.items) |item| allocator.free(item);
                arg_refs.deinit(allocator);
            }
            for (call.args, call.address_args) |arg, address_arg| {
                const value_ty = info[arg].ty orelse return error.BackendInvariantViolation;
                if (try abi.indirectParamInfo(module, callee_abi, value_ty) != null) {
                    if (address_arg) {
                        try arg_types.append(allocator, try allocator.dupe(u8, "ptr"));
                        try arg_refs.append(allocator, try std.fmt.allocPrint(allocator, "%v{}", .{arg}));
                        continue;
                    }
                    const semantic_ty = try types.llvmScalarType(allocator, module, value_ty);
                    defer allocator.free(semantic_ty);
                    const alloc_id = nextTempId(next_temp_id);
                    try writer.print("  %v{} = alloca {s}\n", .{ alloc_id, semantic_ty });
                    try writer.print("  store {s} ", .{semantic_ty});
                    try common.writeValueRef(writer, module, info, arg);
                    try writer.print(", ptr %v{}", .{alloc_id});
                    try emitTypeAlignment(writer, module, value_ty);
                    try writer.writeByte('\n');
                    try arg_types.append(allocator, try allocator.dupe(u8, "ptr"));
                    try arg_refs.append(allocator, try std.fmt.allocPrint(allocator, "%v{}", .{alloc_id}));
                    continue;
                }
                try arg_types.append(allocator, try types.llvmValueType(allocator, module, info, arg));
                var arg_ref_buf: std.ArrayListUnmanaged(u8) = .empty;
                errdefer arg_ref_buf.deinit(allocator);
                var arg_ref_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &arg_ref_buf);
                try common.writeValueRef(&arg_ref_writer.writer, module, info, arg);
                arg_ref_buf = arg_ref_writer.toArrayList();
                try arg_refs.append(allocator, try arg_ref_buf.toOwnedSlice(allocator));
            }
            if (module.types[inst.ty.?] == .result) {
                try arg_types.append(allocator, try allocator.dupe(u8, "ptr"));
                try arg_refs.append(allocator, try allocator.dupe(u8, "%trace_context"));
            }

            const return_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(return_ty);
            const indirect_return = try abi.needsIndirectReturn(module, callee_abi, inst.ty.?);
            const result_ptr_id = if (indirect_return) nextTempId(next_temp_id) else null;
            if (result_ptr_id) |result_ptr| try writer.print("  %v{} = alloca {s}\n", .{ result_ptr, return_ty });
            if (indirect_return or std.mem.eql(u8, return_ty, "void")) {
                try writer.writeAll("  call void ");
            } else {
                try writer.print("  %v{} = call {s} ", .{ inst.id.?, return_ty });
            }
            try common.writeValueRef(writer, module, info, call.callee);
            try writer.writeByte('(');
            if (result_ptr_id) |result_ptr| {
                try writer.print("ptr sret({s}) %v{}", .{ return_ty, result_ptr });
                if (arg_types.items.len != 0) try writer.writeAll(", ");
            }
            for (arg_types.items, arg_refs.items, 0..) |arg_ty, arg_ref, i| {
                if (i != 0) try writer.writeAll(", ");
                try writer.print("{s} ", .{arg_ty});
                try writer.writeAll(arg_ref);
            }
            try writer.writeAll(")\n");
            if (result_ptr_id) |result_ptr| {
                try writer.print("  %v{} = load {s}, ptr %v{}", .{ inst.id.?, return_ty, result_ptr });
                try emitTypeAlignment(writer, module, inst.ty.?);
                try writer.writeByte('\n');
            }
        },
        .extract_tag => |value| {
            const result_ty = try types.llvmValueType(allocator, module, info, value);
            defer allocator.free(result_ty);
            const value_ty = info[value].ty orelse return error.BackendInvariantViolation;
            switch (module.types[value_ty]) {
                .optional, .result => {
                    const raw_id = nextTempId(next_temp_id);
                    try writer.print("  %v{} = extractvalue {s} ", .{ raw_id, result_ty });
                    try common.writeValueRef(writer, module, info, value);
                    try writer.writeAll(", 0\n");
                    try writer.print("  %v{} = icmp ne i8 %v{}, 0\n", .{ inst.id.?, raw_id });
                },
                else => {
                    try writer.print("  %v{} = extractvalue {s} ", .{ inst.id.?, result_ty });
                    try common.writeValueRef(writer, module, info, value);
                    try writer.writeAll(", 0\n");
                },
            }
        },
        .extract_payload => |payload| {
            const aggregate_ty = try types.llvmValueType(allocator, module, info, payload.value);
            defer allocator.free(aggregate_ty);
            const field_index: usize = blk: {
                const value_ty = info[payload.value].ty orelse return error.BackendInvariantViolation;
                switch (module.types[value_ty]) {
                    .@"union" => break :blk @intCast((payload.union_tag orelse return error.BackendInvariantViolation) + 1),
                    else => break :blk 1,
                }
            };
            try writer.print("  %v{} = extractvalue {s} ", .{ inst.id.?, aggregate_ty });
            try common.writeValueRef(writer, module, info, payload.value);
            try writer.print(", {}\n", .{field_index});
        },
        .extract_result => |value| {
            const result_ty = try types.llvmValueType(allocator, module, info, value.value);
            defer allocator.free(result_ty);
            const field_index: u8 = if (value.is_err) 2 else 1;
            try writer.print("  %v{} = extractvalue {s} ", .{ inst.id.?, result_ty });
            try common.writeValueRef(writer, module, info, value.value);
            try writer.print(", {}\n", .{field_index});
        },
        .trace_detail => |value| {
            const carrier_ty = try types.llvmValueType(allocator, module, info, value.carrier);
            defer allocator.free(carrier_ty);
            const handle_id = nextTempId(next_temp_id);
            try writer.print("  %v{} = extractvalue {s} ", .{ handle_id, carrier_ty });
            try common.writeValueRef(writer, module, info, value.carrier);
            try writer.writeAll(", 3\n");
            try writer.print("  %v{}_ptr = alloca {{ ptr, i32, i32 }}\n  store {{ ptr, i32, i32 }} %v{}, ptr %v{}_ptr\n", .{ handle_id, handle_id, handle_id });
            if (value.field == .site or value.field == .site_file) {
                const index = value.index orelse return error.BackendInvariantViolation;
                const file = value.field == .site_file;
                const item_ty: []const u8 = if (file) "{ ptr, i64 }" else "i32";
                const suffix: []const u8 = if (file) "site_file" else "site";
                try writer.print("  %v{}_site_out = alloca {s}\n  store {s} zeroinitializer, ptr %v{}_site_out\n", .{ inst.id.?, item_ty, item_ty, inst.id.? });
                try writer.print("  %v{}_site_found = call i1 @cyna_trace_{s}_abi(ptr %trace_context, ptr %v{}_ptr, i64 ", .{ inst.id.?, suffix, handle_id });
                try common.writeValueRef(writer, module, info, index);
                try writer.print(", ptr %v{}_site_out)\n", .{inst.id.?});
                try writer.print("  %v{}_site_tag = zext i1 %v{}_site_found to i8\n", .{ inst.id.?, inst.id.? });
                try writer.print("  %v{}_site_value = load {s}, ptr %v{}_site_out\n", .{ inst.id.?, item_ty, inst.id.? });
                try writer.print("  %v{}_site_partial = insertvalue {{ i8, {s} }} zeroinitializer, i8 %v{}_site_tag, 0\n", .{ inst.id.?, item_ty, inst.id.? });
                try writer.print("  %v{} = insertvalue {{ i8, {s} }} %v{}_site_partial, {s} %v{}_site_value, 1\n", .{ inst.id.?, item_ty, inst.id.?, item_ty, inst.id.? });
            } else if (value.field == .message or value.field == .origin_file) {
                try writer.print("  %v{}_ptr = alloca {{ ptr, i64 }}\n", .{inst.id.?});
                const suffix: []const u8 = if (value.field == .message) "message" else "origin_file";
                try writer.print("  call void @cyna_trace_{s}_abi(ptr %v{}_ptr, ptr %trace_context, ptr %v{}_ptr)\n", .{ suffix, inst.id.?, handle_id });
                try writer.print("  %v{} = load {{ ptr, i64 }}, ptr %v{}_ptr\n", .{ inst.id.?, inst.id.? });
            } else {
                const result_ty: []const u8 = switch (value.field) {
                    .available => "i1",
                    .origin => "i32",
                    .site_count, .omitted => "i64",
                    .message, .origin_file, .site, .site_file => unreachable,
                };
                try writer.print("  %v{} = call {s} @cyna_trace_{s}_abi(ptr %trace_context, ptr %v{}_ptr)\n", .{ inst.id.?, result_ty, @tagName(value.field), handle_id });
            }
        },
        .extract_field => |field| {
            const value_ty = info[field.value].ty orelse return error.BackendInvariantViolation;
            switch (module.types[value_ty]) {
                .@"struct" => |struct_decl| {
                    if (struct_decl.is_packed) {
                        const carrier_ty = try types.llvmValueType(allocator, module, info, field.value);
                        defer allocator.free(carrier_ty);
                        const field_decl = struct_decl.fields[field.field_index];
                        const field_ty = try types.llvmScalarType(allocator, module, field_decl.ty);
                        defer allocator.free(field_ty);

                        const shifted_id = if (field_decl.bit_offset == 0) blk: {
                            const copy_id = nextTempId(next_temp_id);
                            try writer.print("  %v{} = or {s} ", .{ copy_id, carrier_ty });
                            try common.writeValueRef(writer, module, info, field.value);
                            try writer.writeAll(", 0\n");
                            break :blk copy_id;
                        } else blk: {
                            const shift_id = nextTempId(next_temp_id);
                            try writer.print("  %v{} = lshr {s} ", .{ shift_id, carrier_ty });
                            try common.writeValueRef(writer, module, info, field.value);
                            try writer.print(", {}\n", .{field_decl.bit_offset});
                            break :blk shift_id;
                        };

                        if (field_decl.bit_width != struct_decl.packed_bits) {
                            try writer.print("  %v{} = trunc {s} %v{} to {s}\n", .{
                                inst.id.?,
                                carrier_ty,
                                shifted_id,
                                field_ty,
                            });
                        } else {
                            try writer.print("  %v{} = or {s} %v{}, 0\n", .{
                                inst.id.?,
                                field_ty,
                                shifted_id,
                            });
                        }
                        return;
                    }
                },
                else => {},
            }
            const struct_ty = try types.llvmValueType(allocator, module, info, field.value);
            defer allocator.free(struct_ty);
            try writer.print("  %v{} = extractvalue {s} ", .{ inst.id.?, struct_ty });
            try common.writeValueRef(writer, module, info, field.value);
            try writer.print(", {}\n", .{field.field_index});
        },
        .extract_slice_ptr => |value| {
            const slice_ty = try types.llvmValueType(allocator, module, info, value);
            defer allocator.free(slice_ty);
            try writer.print("  %v{} = extractvalue {s} ", .{ inst.id.?, slice_ty });
            try common.writeValueRef(writer, module, info, value);
            try writer.writeAll(", 0\n");
        },
        .extract_slice_len => |value| {
            const slice_ty = try types.llvmValueType(allocator, module, info, value);
            defer allocator.free(slice_ty);
            try writer.print("  %v{} = extractvalue {s} ", .{ inst.id.?, slice_ty });
            try common.writeValueRef(writer, module, info, value);
            try writer.writeAll(", 1\n");
        },
        .make_some => |value| {
            const optional_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(optional_ty);
            const payload_ty = try types.llvmOptionalPayloadType(allocator, module, inst.ty.?);
            defer allocator.free(payload_ty);
            try writer.print("  %v{}_tag = insertvalue {s} undef, i8 1, 0\n", .{ inst.id.?, optional_ty });
            try writer.print("  %v{} = insertvalue {s} %v{}_tag, {s} ", .{
                inst.id.?,
                optional_ty,
                inst.id.?,
                payload_ty,
            });
            try common.writeValueRef(writer, module, info, value);
            try writer.writeAll(", 1\n");
        },
        .make_none => {
            const optional_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(optional_ty);
            const payload_ty = try types.llvmOptionalPayloadType(allocator, module, inst.ty.?);
            defer allocator.free(payload_ty);
            try writer.print("  %v{}_tag = insertvalue {s} undef, i8 0, 0\n", .{ inst.id.?, optional_ty });
            try writer.print("  %v{} = insertvalue {s} %v{}_tag, {s} zeroinitializer, 1\n", .{
                inst.id.?,
                optional_ty,
                inst.id.?,
                payload_ty,
            });
        },
        .make_result => |value| {
            const result_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(result_ty);
            if (value.is_err) {
                const err_ty = try types.llvmResultErrType(allocator, module, inst.ty.?);
                defer allocator.free(err_ty);
                try writer.print("  %v{}_tag = insertvalue {s} zeroinitializer, i8 1, 0\n", .{ inst.id.?, result_ty });
                try writer.print("  %v{}{s} = insertvalue {s} %v{}_tag, {s} ", .{
                    inst.id.?,
                    if (value.trace == .none) @as([]const u8, "") else "_payload",
                    result_ty,
                    inst.id.?,
                    err_ty,
                });
                try common.writeValueRef(writer, module, info, value.payload orelse return error.BackendInvariantViolation);
                try writer.writeAll(", 2\n");
                switch (value.trace) {
                    .none => {},
                    .create => |creation| {
                        try writer.print("  %v{}_trace_ptr = alloca {{ ptr, i32, i32 }}\n", .{inst.id.?});
                        if (creation.message) |message| {
                            try writer.print("  %v{}_message_ptr = extractvalue {{ ptr, i64 }} %v{}, 0\n", .{ inst.id.?, message });
                            try writer.print("  %v{}_message_len = extractvalue {{ ptr, i64 }} %v{}, 1\n", .{ inst.id.?, message });
                            try writer.print("  call void @cyna_trace_create_location_abi(ptr %v{}_trace_ptr, ptr %trace_context, i32 {}, ", .{ inst.id.?, creation.origin });
                            try emitTraceFileArgs(writer, function, string_literals);
                            try writer.print(", ptr %v{}_message_ptr, i64 %v{}_message_len)\n", .{ inst.id.?, inst.id.? });
                        } else {
                            try writer.print("  call void @cyna_trace_create_location_abi(ptr %v{}_trace_ptr, ptr %trace_context, i32 {}, ", .{ inst.id.?, creation.origin });
                            try emitTraceFileArgs(writer, function, string_literals);
                            try writer.writeAll(", ptr null, i64 0)\n");
                        }
                        try writer.print("  %v{}_trace = load {{ ptr, i32, i32 }}, ptr %v{}_trace_ptr\n", .{ inst.id.?, inst.id.? });
                    },
                    .transfer => |transfer| {
                        const source_ty = try types.llvmValueType(allocator, module, info, transfer.carrier);
                        defer allocator.free(source_ty);
                        try writer.print("  %v{}_trace = extractvalue {s} ", .{ inst.id.?, source_ty });
                        try common.writeValueRef(writer, module, info, transfer.carrier);
                        try writer.writeAll(", 3\n");
                        if (transfer.append_site) |site| {
                            try writer.print("  %v{}_trace_ptr = alloca {{ ptr, i32, i32 }}\n  store {{ ptr, i32, i32 }} %v{}_trace, ptr %v{}_trace_ptr\n", .{ inst.id.?, inst.id.?, inst.id.? });
                            try writer.print("  call void @cyna_trace_append_location_abi(ptr %trace_context, ptr %v{}_trace_ptr, i32 {}, ", .{ inst.id.?, site });
                            try emitTraceFileArgs(writer, function, string_literals);
                            try writer.writeAll(")\n");
                        }
                    },
                }
                if (value.trace != .none) {
                    try writer.print("  %v{} = insertvalue {s} %v{}_payload, {{ ptr, i32, i32 }} %v{}_trace, 3\n", .{ inst.id.?, result_ty, inst.id.?, inst.id.? });
                }
            } else {
                const ok_ty = try types.llvmResultOkType(allocator, module, inst.ty.?);
                defer allocator.free(ok_ty);
                try writer.print("  %v{}_tag = insertvalue {s} zeroinitializer, i8 0, 0\n", .{ inst.id.?, result_ty });
                if (value.payload) |payload| {
                    try writer.print("  %v{} = insertvalue {s} %v{}_tag, {s} ", .{
                        inst.id.?,
                        result_ty,
                        inst.id.?,
                        ok_ty,
                    });
                    try common.writeValueRef(writer, module, info, payload);
                    try writer.writeAll(", 1\n");
                } else {
                    try writer.print("  %v{} = insertvalue {s} %v{}_tag, {s} zeroinitializer, 1\n", .{
                        inst.id.?,
                        result_ty,
                        inst.id.?,
                        ok_ty,
                    });
                }
            }
        },
        .make_union => |value| {
            const union_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(union_ty);
            switch (module.types[inst.ty.?]) {
                .@"union" => |union_decl| {
                    try writer.print("  %v{}_tag = insertvalue {s} undef, i64 {}, 0\n", .{
                        inst.id.?,
                        union_ty,
                        value.tag,
                    });
                    const payload_ty_id = union_decl.payloads[@intCast(value.tag)];
                    if (payload_ty_id) |ty_id| {
                        const payload_ty = try types.llvmScalarType(allocator, module, ty_id);
                        defer allocator.free(payload_ty);
                        if (value.payload) |payload| {
                            try writer.print("  %v{} = insertvalue {s} %v{}_tag, {s} ", .{
                                inst.id.?,
                                union_ty,
                                inst.id.?,
                                payload_ty,
                            });
                            try common.writeValueRef(writer, module, info, payload);
                            try writer.print(", {}\n", .{@as(usize, @intCast(value.tag + 1))});
                        } else {
                            try writer.print("  %v{} = insertvalue {s} %v{}_tag, {s} zeroinitializer, {}\n", .{
                                inst.id.?,
                                union_ty,
                                inst.id.?,
                                payload_ty,
                                @as(usize, @intCast(value.tag + 1)),
                            });
                        }
                    } else {
                        try writer.print("  %v{} = insertvalue {s} %v{}_tag, i8 0, {}\n", .{
                            inst.id.?,
                            union_ty,
                            inst.id.?,
                            @as(usize, @intCast(value.tag + 1)),
                        });
                    }
                },
                else => return error.BackendInvariantViolation,
            }
        },
        .make_struct => |value| {
            const struct_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(struct_ty);
            const struct_decl = switch (module.types[inst.ty.?]) {
                .@"struct" => |decl| decl,
                else => return error.BackendInvariantViolation,
            };
            if (struct_decl.is_packed) {
                if (value.fields.len == 0) {
                    try writer.print("  %v{} = {s} 0\n", .{ inst.id.?, struct_ty });
                    return;
                }

                var acc_id: ?u32 = null;
                for (value.fields, struct_decl.fields) |field_value, field_decl| {
                    const field_ty = try types.llvmValueType(allocator, module, info, field_value);
                    defer allocator.free(field_ty);

                    const widened_id = nextTempId(next_temp_id);
                    if (field_decl.bit_width != struct_decl.packed_bits) {
                        try writer.print("  %v{} = zext {s} ", .{ widened_id, field_ty });
                        try common.writeValueRef(writer, module, info, field_value);
                        try writer.print(" to {s}\n", .{struct_ty});
                    } else {
                        try writer.print("  %v{} = or {s} ", .{ widened_id, struct_ty });
                        try common.writeValueRef(writer, module, info, field_value);
                        try writer.writeAll(", 0\n");
                    }

                    const piece_id = if (field_decl.bit_offset == 0) widened_id else blk: {
                        const shift_id = nextTempId(next_temp_id);
                        try writer.print("  %v{} = shl {s} %v{}, {}\n", .{
                            shift_id,
                            struct_ty,
                            widened_id,
                            field_decl.bit_offset,
                        });
                        break :blk shift_id;
                    };

                    if (acc_id) |prev_id| {
                        const next_id = nextTempId(next_temp_id);
                        try writer.print("  %v{} = or {s} %v{}, %v{}\n", .{
                            next_id,
                            struct_ty,
                            prev_id,
                            piece_id,
                        });
                        acc_id = next_id;
                    } else {
                        acc_id = piece_id;
                    }
                }

                const final_id = acc_id orelse return error.BackendInvariantViolation;
                try writer.print("  %v{} = or {s} %v{}, 0\n", .{
                    inst.id.?,
                    struct_ty,
                    final_id,
                });
                return;
            }
            if (value.fields.len == 0) {
                const zero_ptr_id = nextTempId(next_temp_id);
                try writer.print("  %v{} = alloca {s}\n", .{ zero_ptr_id, struct_ty });
                try writer.print("  %v{} = load {s}, ptr %v{}\n", .{
                    inst.id.?,
                    struct_ty,
                    zero_ptr_id,
                });
                return;
            }
            for (value.fields, 0..) |field_value, i| {
                const field_ty = try types.llvmValueType(allocator, module, info, field_value);
                defer allocator.free(field_ty);
                if (i == 0) {
                    if (value.fields.len == 1) {
                        try writer.print("  %v{} = insertvalue {s} undef, {s} ", .{
                            inst.id.?,
                            struct_ty,
                            field_ty,
                        });
                        try common.writeValueRef(writer, module, info, field_value);
                        try writer.writeAll(", 0\n");
                    } else {
                        try writer.print("  %v{}_f0 = insertvalue {s} undef, {s} ", .{
                            inst.id.?,
                            struct_ty,
                            field_ty,
                        });
                        try common.writeValueRef(writer, module, info, field_value);
                        try writer.writeAll(", 0\n");
                    }
                } else if (i + 1 == value.fields.len) {
                    try writer.print("  %v{} = insertvalue {s} %v{}_f{}, {s} ", .{
                        inst.id.?,
                        struct_ty,
                        inst.id.?,
                        i - 1,
                        field_ty,
                    });
                    try common.writeValueRef(writer, module, info, field_value);
                    try writer.print(", {}\n", .{i});
                } else {
                    try writer.print("  %v{}_f{} = insertvalue {s} %v{}_f{}, {s} ", .{
                        inst.id.?,
                        i,
                        struct_ty,
                        inst.id.?,
                        i - 1,
                        field_ty,
                    });
                    try common.writeValueRef(writer, module, info, field_value);
                    try writer.print(", {}\n", .{i});
                }
            }
        },
        .make_array => |value| {
            const array_ty = try types.llvmScalarType(allocator, module, inst.ty.?);
            defer allocator.free(array_ty);
            if (value.items.len == 0) {
                const zero_ptr_id = nextTempId(next_temp_id);
                try writer.print("  %v{} = alloca {s}\n", .{ zero_ptr_id, array_ty });
                try writer.print("  %v{} = load {s}, ptr %v{}\n", .{
                    inst.id.?,
                    array_ty,
                    zero_ptr_id,
                });
                return;
            }
            for (value.items, 0..) |item_value, i| {
                const item_ty = try types.llvmValueType(allocator, module, info, item_value);
                defer allocator.free(item_ty);
                if (i == 0) {
                    if (value.items.len == 1) {
                        try writer.print("  %v{} = insertvalue {s} undef, {s} ", .{
                            inst.id.?,
                            array_ty,
                            item_ty,
                        });
                        try common.writeValueRef(writer, module, info, item_value);
                        try writer.writeAll(", 0\n");
                    } else {
                        try writer.print("  %v{}_i0 = insertvalue {s} undef, {s} ", .{
                            inst.id.?,
                            array_ty,
                            item_ty,
                        });
                        try common.writeValueRef(writer, module, info, item_value);
                        try writer.writeAll(", 0\n");
                    }
                } else if (i + 1 == value.items.len) {
                    try writer.print("  %v{} = insertvalue {s} %v{}_i{}, {s} ", .{
                        inst.id.?,
                        array_ty,
                        inst.id.?,
                        i - 1,
                        item_ty,
                    });
                    try common.writeValueRef(writer, module, info, item_value);
                    try writer.print(", {}\n", .{i});
                } else {
                    try writer.print("  %v{}_i{} = insertvalue {s} %v{}_i{}, {s} ", .{
                        inst.id.?,
                        i,
                        array_ty,
                        inst.id.?,
                        i - 1,
                        item_ty,
                    });
                    try common.writeValueRef(writer, module, info, item_value);
                    try writer.print(", {}\n", .{i});
                }
            }
        },
        .make_slice => |slice| {
            try writer.print("  %v{}_ptr = insertvalue {{ ptr, i64 }} undef, ptr ", .{inst.id.?});
            try common.writeValueRef(writer, module, info, slice.ptr);
            try writer.writeAll(", 0\n");
            try writer.print("  %v{} = insertvalue {{ ptr, i64 }} %v{}_ptr, i64 ", .{ inst.id.?, inst.id.? });
            try common.writeValueRef(writer, module, info, slice.len);
            try writer.writeAll(", 1\n");
        },
    }
}

fn requireAddressableStructFields(struct_ty: lir.StructType) capability.Error!void {
    if (struct_ty.is_packed) return error.BackendPackedFieldAddressUnsupported;
}

test "packed field address reports LLVM backend capability" {
    const normal: lir.StructType = .{
        .name = "Normal",
        .is_c_layout = false,
        .is_packed = false,
        .packed_bits = 0,
        .fields = &.{},
    };
    const packed_type: lir.StructType = .{
        .name = "Packed",
        .is_c_layout = false,
        .is_packed = true,
        .packed_bits = 8,
        .fields = &.{},
    };

    try requireAddressableStructFields(normal);
    try std.testing.expectError(error.BackendPackedFieldAddressUnsupported, requireAddressableStructFields(packed_type));
}

fn buildInlineAsmTemplate(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    output: ?lir.AsmOutput,
    inout: ?lir.AsmInOut,
    input_names: []const []const u8,
    has_output: bool,
) Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (lines, 0..) |line, i| {
        if (i != 0) try out.append(allocator, '\n');
        var cursor: usize = 0;
        while (cursor < line.len) {
            if (line[cursor] != '{') {
                try out.append(allocator, line[cursor]);
                cursor += 1;
                continue;
            }
            const start = cursor + 1;
            var end = start;
            while (end < line.len and line[end] != '}') : (end += 1) {}
            if (end >= line.len) return error.BackendInvariantViolation;
            const name = line[start..end];
            if (std.mem.eql(u8, name, "out")) {
                if (!has_output) return error.BackendInvariantViolation;
                if (output != null or inout != null) return error.BackendInvariantViolation;
                try out.appendSlice(allocator, "$0");
                cursor = end + 1;
                continue;
            }
            if (inout) |asm_inout| {
                if (std.mem.eql(u8, name, asm_inout.name)) {
                    if (!has_output) return error.BackendInvariantViolation;
                    try out.appendSlice(allocator, "$0");
                    cursor = end + 1;
                    continue;
                }
            }
            if (output) |asm_output| {
                if (std.mem.eql(u8, name, asm_output.name)) {
                    if (!has_output) return error.BackendInvariantViolation;
                    try out.appendSlice(allocator, "$0");
                    cursor = end + 1;
                    continue;
                }
            }
            const index = findInlineAsmInputIndex(input_names, name) orelse return error.BackendInvariantViolation;
            const placeholder = try std.fmt.allocPrint(allocator, "${}", .{if (has_output) index + 1 else index});
            defer allocator.free(placeholder);
            try out.appendSlice(allocator, placeholder);
            cursor = end + 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn findInlineAsmInputIndex(input_names: []const []const u8, name: []const u8) ?usize {
    for (input_names, 0..) |input_name, i| {
        if (std.mem.eql(u8, input_name, name)) return i;
    }
    return null;
}

fn buildInlineAsmConstraints(
    allocator: std.mem.Allocator,
    module: lir.Module,
    info: []const common.ValueInfo,
    output: ?lir.AsmOutput,
    inout: ?lir.AsmInOut,
    input_constraints: []const lir.AsmConstraint,
    args: []const lir.ValueId,
    clobbers: []const lir.AsmClobber,
    has_output: bool,
) Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (has_output) {
        if (inout) |asm_inout| {
            try out.append(allocator, '+');
            switch (asm_inout.constraint) {
                .reg => try out.append(allocator, 'r'),
                .tied_reg => return error.BackendInvariantViolation,
            }
        } else {
            try out.append(allocator, '=');
        }
        if (output) |asm_output| {
            switch (asm_output.constraint) {
                .reg => try out.append(allocator, 'r'),
                .tied_reg => return error.BackendInvariantViolation,
            }
        } else if (inout == null) {
            try out.append(allocator, 'r');
        }
    }
    for (args, input_constraints, 0..) |arg, constraint, i| {
        if (i != 0 or has_output) try out.append(allocator, ',');
        const ty = info[arg].ty orelse return error.BackendInvariantViolation;
        switch (module.types[ty]) {
            .int, .bool, .pointer => switch (constraint) {
                .reg => try out.append(allocator, 'r'),
                .tied_reg => try out.append(allocator, '0'),
            },
            else => return error.BackendInvariantViolation,
        }
    }
    for (clobbers) |clobber| {
        if (out.items.len != 0) try out.append(allocator, ',');
        switch (clobber) {
            .memory => try out.appendSlice(allocator, "~{memory}"),
            .flags => try out.appendSlice(allocator, "~{cc}"),
            .register => |name| {
                try out.appendSlice(allocator, "~{");
                try out.appendSlice(allocator, name);
                try out.append(allocator, '}');
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn emitTerminator(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    function: lir.Function,
    info: []const common.ValueInfo,
    term: lir.Terminator,
    next_temp_id: *u32,
) Error!void {
    switch (term) {
        .@"return" => |value| {
            if (abi.needsLocalTraceContext(module, function) and module.types[function.return_type] == .result) {
                if (value) |id| try emitTraceReleaseForCarrier(allocator, writer, module, function, info, id, next_temp_id);
            }
            if (abi.needsLocalTraceContext(module, function)) {
                try writer.writeAll("  call void @cyna_trace_release_root(ptr %trace_context)\n");
            }
            if (value) |id| {
                if (abi.isEntryResult(module, function)) {
                    const result_ty = try types.llvmValueType(allocator, module, info, id);
                    defer allocator.free(result_ty);
                    const tag_id = nextTempId(next_temp_id);
                    const exit_id = nextTempId(next_temp_id);
                    try writer.print("  %v{} = extractvalue {s} ", .{ tag_id, result_ty });
                    try common.writeValueRef(writer, module, info, id);
                    try writer.print(", 0\n  %v{} = zext i8 %v{} to i32\n  ret i32 %v{}\n", .{ exit_id, tag_id, exit_id });
                    return;
                }
                if (try abi.needsIndirectReturn(module, function, function.return_type)) {
                    const value_ty = try types.llvmValueType(allocator, module, info, id);
                    defer allocator.free(value_ty);
                    if (abi.needsExportValueBridge(function)) {
                        if (try abi.publicCallableBoundaryType(allocator, module, function.return_type)) |public_ty| {
                            defer allocator.free(public_ty);
                            const semantic_ptr_id = nextTempId(next_temp_id);
                            const public_id = nextTempId(next_temp_id);
                            try writer.print("  %v{} = alloca {s}\n", .{ semantic_ptr_id, value_ty });
                            try writer.print("  store {s} ", .{value_ty});
                            try common.writeValueRef(writer, module, info, id);
                            try writer.print(", ptr %v{}\n", .{semantic_ptr_id});
                            _ = try emitExternExportBridgeValue(writer, allocator, module, next_temp_id, function.return_type, semantic_ptr_id, public_id);
                            try writer.print("  store {s} %v{}, ptr %retptr\n", .{ public_ty, public_id });
                            try writer.writeAll("  ret void\n");
                            return;
                        }
                    }
                    try writer.print("  store {s} ", .{value_ty});
                    try common.writeValueRef(writer, module, info, id);
                    try writer.writeAll(", ptr %retptr\n");
                    try writer.writeAll("  ret void\n");
                    return;
                }
                if (abi.needsExportValueBridge(function)) {
                    if (try abi.publicCallableBoundaryType(allocator, module, function.return_type)) |public_ty| {
                        defer allocator.free(public_ty);
                        const semantic_ty = try types.llvmValueType(allocator, module, info, id);
                        defer allocator.free(semantic_ty);
                        const semantic_ptr_id = nextTempId(next_temp_id);
                        try writer.print("  %v{} = alloca {s}\n", .{ semantic_ptr_id, semantic_ty });
                        try writer.print("  store {s} ", .{semantic_ty});
                        try common.writeValueRef(writer, module, info, id);
                        try writer.print(", ptr %v{}\n", .{semantic_ptr_id});
                        const public_id = try emitExternExportBridgeValue(writer, allocator, module, next_temp_id, function.return_type, semantic_ptr_id, null);
                        const abi_return_ty = try abi.returnType(allocator, module, function, function.return_type);
                        defer allocator.free(abi_return_ty);
                        if (std.mem.eql(u8, abi_return_ty, public_ty)) {
                            try writer.print("  ret {s} %v{}\n", .{ public_ty, public_id });
                        } else {
                            const public_ref = try std.fmt.allocPrint(allocator, "%v{}", .{public_id});
                            defer allocator.free(public_ref);
                            const coerced_id = try emitMemoryCoercion(writer, next_temp_id, public_ty, abi_return_ty, abi_return_ty, public_ref);
                            try writer.print("  ret {s} %v{}\n", .{ abi_return_ty, coerced_id });
                        }
                        return;
                    }
                    switch (try abi.callableBoundaryShape(module, function, function.return_type)) {
                        .semantic => {},
                        .dense_header_ptr, .sparse_header_ptr => unreachable,
                        .indirect => unreachable,
                        .scalar_coercion => {
                            const abi_ty = (try abi.cLayoutAbiCoercionType(allocator, module, function.return_type)).?;
                            defer allocator.free(abi_ty);
                            const semantic_ty = try types.llvmValueType(allocator, module, info, id);
                            defer allocator.free(semantic_ty);
                            const alloc_id = nextTempId(next_temp_id);
                            try writer.print("  %v{} = alloca {s}\n", .{ alloc_id, semantic_ty });
                            try writer.print("  store {s} ", .{semantic_ty});
                            try common.writeValueRef(writer, module, info, id);
                            try writer.print(", ptr %v{}\n", .{alloc_id});
                            const load_id = nextTempId(next_temp_id);
                            try writer.print("  %v{} = load {s}, ptr %v{}\n", .{ load_id, abi_ty, alloc_id });
                            try writer.print("  ret {s} %v{}\n", .{ abi_ty, load_id });
                            return;
                        },
                    }
                }
                const value_ty = try types.llvmValueType(allocator, module, info, id);
                defer allocator.free(value_ty);
                try writer.print("  ret {s} ", .{value_ty});
                try common.writeValueRef(writer, module, info, id);
                try writer.writeByte('\n');
            } else {
                try writer.writeAll("  ret void\n");
            }
        },
        .br => |target| try writer.print("  br label %{s}\n", .{function.blocks[target].name}),
        .cond_br => |branch| {
            try writer.writeAll("  br i1 ");
            try common.writeValueRef(writer, module, info, branch.condition);
            try writer.print(", label %{s}, label %{s}\n", .{
                function.blocks[branch.then_block].name,
                function.blocks[branch.else_block].name,
            });
        },
        .@"unreachable" => try writer.writeAll("  call void @llvm.trap()\n  unreachable\n"),
        .none => return error.BackendInvariantViolation,
    }
}

fn emitTraceReleaseForCarrier(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    function: ?lir.Function,
    info: []const common.ValueInfo,
    carrier: lir.ValueId,
    next_temp_id: *u32,
) Error!void {
    const carrier_ty = try types.llvmValueType(allocator, module, info, carrier);
    defer allocator.free(carrier_ty);
    const handle_id = nextTempId(next_temp_id);
    try writer.print("  %v{} = extractvalue {s} ", .{ handle_id, carrier_ty });
    try common.writeValueRef(writer, module, info, carrier);
    try writer.writeAll(", 3\n");
    try writer.print("  %v{}_ptr = alloca {{ ptr, i32, i32 }}\n  store {{ ptr, i32, i32 }} %v{}, ptr %v{}_ptr\n", .{ handle_id, handle_id, handle_id });
    if (function != null and abi.isEntryResult(module, function.?)) {
        const tag_id = nextTempId(next_temp_id);
        try writer.print("  %v{} = extractvalue {s} ", .{ tag_id, carrier_ty });
        try common.writeValueRef(writer, module, info, carrier);
        try writer.print(", 0\n  call void @cyna_trace_print_unhandled_abi(i8 %v{}, ptr %v{}_ptr)\n", .{ tag_id, handle_id });
    }
    try writer.print("  call void @cyna_trace_release_abi(ptr %trace_context, ptr %v{}_ptr)\n", .{handle_id});
}

pub fn emitCatchTraceExits(
    allocator: std.mem.Allocator,
    writer: anytype,
    module: lir.Module,
    info: []const common.ValueInfo,
    exits: []const lir.CatchExit,
    next_temp_id: *u32,
) Error!void {
    for (exits) |catch_exit| {
        if (catch_exit.disposition == .handled) {
            try emitTraceReleaseForCarrier(allocator, writer, module, null, info, catch_exit.carrier, next_temp_id);
        }
    }
}

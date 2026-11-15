const std = @import("std");
const target_info = @import("../target.zig");

pub const TypeId = u32;
pub const ValueId = u32;
pub const BlockId = u32;
pub const LocalId = u32;

pub const CallingConvention = enum {
    cyna,
    c,
};

pub const VerifyError = error{
    InvalidTypeReference,
    InvalidTypeDefinition,
    InvalidGlobalType,
    InvalidFunctionType,
    InvalidFunctionStructure,
    InvalidBlockTarget,
    UnterminatedBlock,
    InvalidValueDefinition,
    InvalidValueReference,
    InvalidParameterReference,
    InvalidInlineAsm,
} || std.mem.Allocator.Error;

pub const Module = struct {
    types: []const TypeDecl,
    globals: []const Global,
    functions: []const Function,
    generated_names: []const []const u8 = &.{},
    target_abi: target_info.AbiLayout = target_info.abiLayout(null),

    pub fn deinit(self: Module, allocator: std.mem.Allocator) void {
        for (self.types) |ty| ty.deinit(allocator);
        allocator.free(self.types);
        for (self.globals) |global| global.deinit(allocator);
        allocator.free(self.globals);
        for (self.functions) |function| function.deinit(allocator);
        allocator.free(self.functions);
        for (self.generated_names) |name| allocator.free(name);
        allocator.free(self.generated_names);
    }

    pub fn dump(self: Module, writer: anytype) !void {
        if (self.globals.len != 0) {
            try writer.writeAll("globals:\n");
            for (self.globals) |global| {
                try writer.writeAll("  ");
                try global.dump(writer, self);
                try writer.writeByte('\n');
            }
            try writer.writeByte('\n');
        }
        for (self.functions, 0..) |function, i| {
            if (i != 0) try writer.writeByte('\n');
            try function.dump(writer, self);
        }
    }

    pub fn verify(self: Module, allocator: std.mem.Allocator) VerifyError!void {
        try self.verifyTypes();
        for (self.globals) |global| {
            if (!self.hasType(global.ty)) return error.InvalidGlobalType;
        }
        for (self.functions) |function| try self.verifyFunction(allocator, function);
    }

    fn verifyTypes(self: Module) VerifyError!void {
        for (self.types) |ty| switch (ty) {
            .void, .bool, .string => {},
            .int => |int_ty| if (int_ty.bits == 0) return error.InvalidTypeDefinition,
            .float => |float_ty| if (float_ty.bits == 0) return error.InvalidTypeDefinition,
            .pointer, .slice, .dense_array, .sparse_array, .optional => |child| {
                if (!self.hasType(child)) return error.InvalidTypeReference;
            },
            .array => |array_ty| {
                if (!self.hasType(array_ty.elem)) return error.InvalidTypeReference;
            },
            .result => |result_ty| {
                if (!self.hasType(result_ty.ok) or !self.hasType(result_ty.err)) {
                    return error.InvalidTypeReference;
                }
            },
            .@"struct" => |struct_ty| {
                if (struct_ty.shared_runtime != .none and !struct_ty.is_shared_value) {
                    return error.InvalidTypeDefinition;
                }
                for (struct_ty.fields) |field| {
                    if (!self.hasType(field.ty)) return error.InvalidTypeReference;
                    if (struct_ty.is_packed and field.bit_width == 0) return error.InvalidTypeDefinition;
                }
            },
            .@"union" => |union_ty| for (union_ty.payloads) |payload| {
                if (payload) |payload_ty| {
                    if (!self.hasType(payload_ty)) return error.InvalidTypeReference;
                }
            },
        };
    }

    fn verifyFunction(
        self: Module,
        allocator: std.mem.Allocator,
        function: Function,
    ) VerifyError!void {
        if (!self.hasType(function.return_type)) return error.InvalidFunctionType;
        for (function.params) |param| {
            if (!self.hasType(param.ty)) return error.InvalidFunctionType;
        }
        for (function.locals) |local| {
            if (!self.hasType(local.ty)) return error.InvalidFunctionType;
        }

        if (function.is_extern) {
            if (function.blocks.len != 0) return error.InvalidFunctionStructure;
            return;
        }
        if (function.blocks.len == 0 or function.entry >= function.blocks.len) {
            return error.InvalidFunctionStructure;
        }

        var value_count: usize = 0;
        for (function.blocks) |block| {
            for (block.instructions) |inst| {
                if (inst.id != null) value_count += 1;
            }
        }
        const value_types = try allocator.alloc(?TypeId, value_count);
        defer allocator.free(value_types);
        @memset(value_types, null);

        for (function.blocks) |block| {
            for (block.instructions) |inst| {
                if ((inst.id == null) != (inst.ty == null)) return error.InvalidValueDefinition;
                const id = inst.id orelse continue;
                const ty = inst.ty orelse return error.InvalidValueDefinition;
                if (!self.hasType(ty)) return error.InvalidTypeReference;
                if (id >= value_types.len or value_types[id] != null) {
                    return error.InvalidValueDefinition;
                }
                value_types[id] = ty;
            }
        }
        for (value_types) |ty| {
            if (ty == null) return error.InvalidValueDefinition;
        }

        for (function.blocks) |block| {
            for (block.instructions) |inst| {
                try self.verifyInst(function, value_types, inst);
            }
            try self.verifyTerminator(function, value_types, block.terminator);
        }
    }

    fn verifyInst(
        self: Module,
        function: Function,
        value_types: []const ?TypeId,
        inst: Inst,
    ) VerifyError!void {
        switch (inst.data) {
            .const_int, .const_float, .const_bool, .const_string, .const_c_str, .global_addr, .make_none => {},
            .param_ref => |index| {
                if (index >= function.params.len) return error.InvalidParameterReference;
                const result_ty = inst.ty orelse return error.InvalidValueDefinition;
                if (result_ty != function.params[index].ty) return error.InvalidParameterReference;
            },
            .type_desc, .stack_alloc => |ty| {
                if (!self.hasType(ty)) return error.InvalidTypeReference;
            },
            .field_ptr => |value| try verifyValueRef(value_types, value.ptr),
            .index_ptr => |value| {
                try verifyValueRef(value_types, value.ptr);
                try verifyValueRef(value_types, value.index);
            },
            .union_payload_ptr => |value| try verifyValueRef(value_types, value.ptr),
            .load,
            .volatile_load,
            .int_to_int,
            .int_to_ptr,
            .ptr_to_int,
            .bitcast,
            .packed_to_int,
            .int_to_packed,
            .int_to_float,
            .float_to_int,
            .float_to_float,
            .dense_len,
            .dense_data,
            .sparse_len,
            .sparse_capacity,
            .extract_tag,
            .string_len,
            .extract_slice_ptr,
            .extract_slice_len,
            .make_some,
            => |value| try verifyValueRef(value_types, value),
            .store,
            .volatile_store,
            => |value| {
                try verifyValueRef(value_types, value.ptr);
                try verifyValueRef(value_types, value.value);
            },
            .int_binop => |value| try verifyBinaryRefs(value_types, value.lhs, value.rhs),
            .int_cmp => |value| try verifyBinaryRefs(value_types, value.lhs, value.rhs),
            .float_binop => |value| try verifyBinaryRefs(value_types, value.lhs, value.rhs),
            .float_cmp => |value| try verifyBinaryRefs(value_types, value.lhs, value.rhs),
            .string_cmp => |value| try verifyBinaryRefs(value_types, value.lhs, value.rhs),
            .sequence_cmp => |value| {
                try verifyValueRef(value_types, value.lhs_ptr);
                try verifyValueRef(value_types, value.lhs_len);
                try verifyValueRef(value_types, value.rhs_ptr);
                try verifyValueRef(value_types, value.rhs_len);
                try verifyValueRef(value_types, value.elem_desc);
            },
            .sparse_cmp => |value| {
                try verifyValueRef(value_types, value.lhs);
                try verifyValueRef(value_types, value.rhs);
                try verifyValueRef(value_types, value.elem_desc);
            },
            .dense_new => |value| try verifyValueRef(value_types, value.value),
            .dense_copy,
            .dense_clear,
            .dense_drop,
            .sparse_new,
            .sparse_copy,
            .sparse_drop,
            .sparse_clear,
            .sparse_indices,
            .sparse_contains_index,
            .sparse_payload_ptr,
            => |value| {
                try verifyValueRef(value_types, value.lhs);
                try verifyValueRef(value_types, value.rhs);
            },
            .dense_reserve, .dense_at, .dense_push, .dense_push_move, .dense_pop => |value| {
                try verifyValueRef(value_types, value.a);
                try verifyValueRef(value_types, value.b);
                try verifyValueRef(value_types, value.c);
            },
            .sparse_get, .sparse_insert, .sparse_insert_move, .sparse_take => |value| {
                try verifyValueRef(value_types, value.a);
                try verifyValueRef(value_types, value.b);
                try verifyValueRef(value_types, value.c);
                try verifyValueRef(value_types, value.d);
            },
            .sparse_set, .sparse_set_move => |value| {
                try verifyValueRef(value_types, value.a);
                try verifyValueRef(value_types, value.b);
                try verifyValueRef(value_types, value.c);
                try verifyValueRef(value_types, value.d);
                try verifyValueRef(value_types, value.e);
            },
            .call => |call| try verifyValueRefs(value_types, call.args),
            .indirect_call => |call| {
                try verifyValueRef(value_types, call.callee);
                try verifyValueRefs(value_types, call.args);
            },
            .inline_asm => |asm_stmt| {
                if (asm_stmt.input_names.len != asm_stmt.input_constraints.len or
                    asm_stmt.input_names.len != asm_stmt.args.len)
                {
                    return error.InvalidInlineAsm;
                }
                if (asm_stmt.inout) |inout| try verifyValueRef(value_types, inout.seed);
                try verifyValueRefs(value_types, asm_stmt.args);
            },
            .extract_payload => |value| try verifyValueRef(value_types, value.value),
            .extract_result => |value| try verifyValueRef(value_types, value.value),
            .trace_detail => |value| {
                try verifyValueRef(value_types, value.carrier);
                if (value.index) |index| try verifyValueRef(value_types, index);
            },
            .extract_field => |value| try verifyValueRef(value_types, value.value),
            .make_array => |value| try verifyValueRefs(value_types, value.items),
            .make_slice => |value| {
                try verifyValueRef(value_types, value.ptr);
                try verifyValueRef(value_types, value.len);
            },
            .make_struct => |value| try verifyValueRefs(value_types, value.fields),
            .make_union => |value| if (value.payload) |payload| {
                try verifyValueRef(value_types, payload);
            },
            .make_result => |value| {
                if (value.payload) |payload| try verifyValueRef(value_types, payload);
                switch (value.trace) {
                    .create => |creation| if (creation.message) |message| {
                        try verifyValueRef(value_types, message);
                    },
                    .transfer => |transfer| try verifyValueRef(value_types, transfer.carrier),
                    else => {},
                }
            },
        }
    }

    fn verifyTerminator(
        self: Module,
        function: Function,
        value_types: []const ?TypeId,
        terminator: Terminator,
    ) VerifyError!void {
        switch (terminator) {
            .@"return" => |maybe_value| {
                if (maybe_value) |value| {
                    try verifyValueRef(value_types, value);
                    if (!typeIdsEqual(self.types, value_types[value].?, function.return_type)) {
                        return error.InvalidFunctionType;
                    }
                } else if (self.types[function.return_type] != .void) {
                    return error.InvalidFunctionType;
                }
            },
            .br => |target| {
                if (target >= function.blocks.len) return error.InvalidBlockTarget;
            },
            .cond_br => |branch| {
                try verifyValueRef(value_types, branch.condition);
                if (self.types[value_types[branch.condition].?] != .bool) {
                    return error.InvalidFunctionType;
                }
                if (branch.then_block >= function.blocks.len or
                    branch.else_block >= function.blocks.len)
                {
                    return error.InvalidBlockTarget;
                }
            },
            .@"unreachable" => {},
            .none => return error.UnterminatedBlock,
        }
    }

    fn hasType(self: Module, ty: TypeId) bool {
        return ty < self.types.len;
    }
};

fn verifyValueRef(value_types: []const ?TypeId, value: ValueId) VerifyError!void {
    if (value >= value_types.len or value_types[value] == null) {
        return error.InvalidValueReference;
    }
}

fn verifyValueRefs(value_types: []const ?TypeId, values: []const ValueId) VerifyError!void {
    for (values) |value| try verifyValueRef(value_types, value);
}

fn verifyBinaryRefs(
    value_types: []const ?TypeId,
    lhs: ValueId,
    rhs: ValueId,
) VerifyError!void {
    try verifyValueRef(value_types, lhs);
    try verifyValueRef(value_types, rhs);
}

pub fn typeIdsEqual(types: []const TypeDecl, a: TypeId, b: TypeId) bool {
    if (a == b) return true;
    if (a >= types.len or b >= types.len) return false;

    const left = types[a];
    const right = types[b];
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;

    return switch (left) {
        .void, .bool, .string => true,
        .int => |lhs| lhs.bits == right.int.bits and lhs.signed == right.int.signed,
        .float => |lhs| lhs.bits == right.float.bits,
        .pointer => |lhs| typeIdsEqual(types, lhs, right.pointer),
        .array => |lhs| lhs.len == right.array.len and typeIdsEqual(types, lhs.elem, right.array.elem),
        .slice => |lhs| typeIdsEqual(types, lhs, right.slice),
        .dense_array => |lhs| typeIdsEqual(types, lhs, right.dense_array),
        .sparse_array => |lhs| typeIdsEqual(types, lhs, right.sparse_array),
        .optional => |lhs| typeIdsEqual(types, lhs, right.optional),
        .result => |lhs| typeIdsEqual(types, lhs.ok, right.result.ok) and typeIdsEqual(types, lhs.err, right.result.err),
        .@"struct" => |lhs| blk: {
            const rhs = right.@"struct";
            if (!std.mem.eql(u8, lhs.name, rhs.name)) break :blk false;
            if (lhs.is_c_layout != rhs.is_c_layout or
                lhs.is_packed != rhs.is_packed or
                lhs.is_shared_value != rhs.is_shared_value or
                lhs.shared_runtime != rhs.shared_runtime or
                lhs.packed_bits != rhs.packed_bits)
            {
                break :blk false;
            }
            if (lhs.fields.len != rhs.fields.len) break :blk false;
            for (lhs.fields, rhs.fields) |lhs_field, rhs_field| {
                if (!std.mem.eql(u8, lhs_field.name, rhs_field.name)) break :blk false;
                if (lhs_field.bit_offset != rhs_field.bit_offset or
                    lhs_field.bit_width != rhs_field.bit_width)
                {
                    break :blk false;
                }
                if (!typeIdsEqual(types, lhs_field.ty, rhs_field.ty)) break :blk false;
            }
            break :blk true;
        },
        .@"union" => |lhs| blk: {
            const rhs = right.@"union";
            if (!std.mem.eql(u8, lhs.name, rhs.name)) break :blk false;
            if (lhs.payloads.len != rhs.payloads.len) break :blk false;
            for (lhs.payloads, rhs.payloads) |lhs_payload, rhs_payload| {
                if (lhs_payload == null or rhs_payload == null) {
                    if (lhs_payload != rhs_payload) break :blk false;
                    continue;
                }
                if (!typeIdsEqual(types, lhs_payload.?, rhs_payload.?)) break :blk false;
            }
            break :blk true;
        },
    };
}

pub const Global = struct {
    module_name: []const u8,
    owner: ?[]const u8 = null,
    name: []const u8,
    is_mutable: bool,
    is_extern: bool = false,
    abi_name: ?[]const u8 = null,
    is_symbol_addr: bool = false,
    ty: TypeId,
    init: ?GlobalInit,

    pub fn deinit(self: Global, allocator: std.mem.Allocator) void {
        if (self.init) |init| init.deinit(allocator);
    }

    pub fn dump(self: Global, writer: anytype, module: Module) !void {
        if (self.is_extern) try writer.writeAll("extern ");
        try writer.writeAll(if (self.is_mutable) "var " else "const ");
        if (self.module_name.len != 0) try writer.print("{s}.", .{self.module_name});
        if (self.owner) |owner| try writer.print("{s}.", .{owner});
        try writer.print("{s}: ", .{self.name});
        try dumpType(writer, module, self.ty);
        if (self.abi_name) |abi_name| {
            try writer.print(" = \"{s}\"", .{abi_name});
        }
        if (self.is_symbol_addr) {
            try writer.writeAll(" /*symbol_addr*/");
        } else if (self.init) |init| {
            try writer.writeAll(" = ");
            try init.dump(writer, module);
        }
    }
};

pub const GlobalInit = union(enum) {
    int: i64,
    string: []const u8,
    float: f64,
    bool: bool,
    enum_value: i64,
    none,
    symbol_addr: []const u8,
    some: *GlobalInit,
    @"union": UnionInit,
    array: []GlobalInit,
    @"struct": []GlobalInit,

    pub fn deinit(self: GlobalInit, allocator: std.mem.Allocator) void {
        switch (self) {
            .some => |value| {
                value.deinit(allocator);
                allocator.destroy(value);
            },
            .@"union" => |value| if (value.payload) |payload| {
                payload.deinit(allocator);
                allocator.destroy(payload);
            },
            .array => |items| {
                for (items) |item| item.deinit(allocator);
                allocator.free(items);
            },
            .@"struct" => |fields| {
                for (fields) |field| field.deinit(allocator);
                allocator.free(fields);
            },
            .symbol_addr => |name| allocator.free(name),
            .string => |value| allocator.free(value),
            else => {},
        }
    }

    pub fn dump(self: GlobalInit, writer: anytype, module: Module) !void {
        switch (self) {
            .int => |value| try writer.print("{}", .{value}),
            .string => |value| try writer.print("string {s}", .{value}),
            .float => |value| try writer.print("{d}", .{value}),
            .bool => |value| try writer.print("{}", .{value}),
            .enum_value => |value| try writer.print("enum {}", .{value}),
            .none => try writer.writeAll("none"),
            .symbol_addr => |name| try writer.print("symbol_addr {s}", .{name}),
            .some => |value| {
                try writer.writeAll("some(");
                try value.dump(writer, module);
                try writer.writeByte(')');
            },
            .@"union" => |value| {
                try writer.print("union(tag={}", .{value.tag});
                if (value.payload) |payload| {
                    try writer.writeAll(", ");
                    try payload.dump(writer, module);
                }
                try writer.writeByte(')');
            },
            .array => |items| {
                try writer.writeByte('[');
                for (items, 0..) |item, i| {
                    if (i != 0) try writer.writeAll(", ");
                    try item.dump(writer, module);
                }
                try writer.writeByte(']');
            },
            .@"struct" => |fields| {
                try writer.writeByte('{');
                for (fields, 0..) |field, i| {
                    if (i != 0) try writer.writeAll(", ");
                    try field.dump(writer, module);
                }
                try writer.writeByte('}');
            },
        }
    }
};

pub const UnionInit = struct {
    tag: u32,
    payload: ?*GlobalInit,
};

pub const TypeDecl = union(enum) {
    void,
    bool,
    int: IntType,
    float: FloatType,
    string,
    pointer: TypeId,
    array: ArrayType,
    slice: TypeId,
    dense_array: TypeId,
    sparse_array: TypeId,
    optional: TypeId,
    result: ResultType,
    @"struct": StructType,
    @"union": UnionType,

    pub fn deinit(self: TypeDecl, allocator: std.mem.Allocator) void {
        switch (self) {
            .@"struct" => |struct_ty| allocator.free(struct_ty.fields),
            .@"union" => |union_ty| allocator.free(union_ty.payloads),
            else => {},
        }
    }
};

pub const IntType = struct {
    bits: u16,
    signed: bool,
};

pub const FloatType = struct {
    bits: u16,
};

pub const ArrayType = struct {
    len: usize,
    elem: TypeId,
};

pub const ResultType = struct {
    ok: TypeId,
    err: TypeId,
};

pub const StructType = struct {
    name: []const u8,
    // Nominal declaration identity; storage belongs to Module.generated_names or SIR.
    qualified_name: ?[]const u8 = null,
    is_c_layout: bool,
    is_packed: bool,
    is_shared_value: bool = false,
    shared_runtime: SharedRuntime = .none,
    drop_runtime: DropRuntime = .none,
    packed_bits: u32,
    fields: []const StructField,
};

pub const SharedRuntime = enum {
    none,
    arc,
};

pub const DropRuntime = enum {
    none,
    task_discard,
};

pub const StructField = struct {
    name: []const u8,
    ty: TypeId,
    bit_offset: u32 = 0,
    bit_width: u16 = 0,
};

pub const UnionType = struct {
    name: []const u8,
    // Nominal declaration identity; storage belongs to Module.generated_names or SIR.
    qualified_name: ?[]const u8 = null,
    payloads: []const ?TypeId,
};

pub const Function = struct {
    module_name: []const u8 = "",
    name: []const u8,
    abi_name: ?[]const u8 = null,
    is_extern: bool = false,
    is_export: bool = false,
    is_test_entry: bool = false,
    calling_convention: CallingConvention = .cyna,
    params: []const Param,
    return_type: TypeId,
    locals: []const Local,
    ownership_trace: []const OwnershipTraceLine,
    blocks: []const BasicBlock,
    entry: BlockId,
    debug_source_path: ?[]const u8 = null,
    debug_line: u32 = 0,
    debug_column: u32 = 0,

    pub fn deinit(self: Function, allocator: std.mem.Allocator) void {
        allocator.free(self.params);
        allocator.free(self.locals);
        for (self.ownership_trace) |line| allocator.free(line.text);
        allocator.free(self.ownership_trace);
        for (self.blocks) |block| block.deinit(allocator);
        allocator.free(self.blocks);
        if (self.debug_source_path) |path| allocator.free(path);
    }

    pub fn dump(self: Function, writer: anytype, module: Module) !void {
        try writer.print("fn {s}(", .{self.name});
        for (self.params, 0..) |param, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.print("%{s}: ", .{param.name});
            try dumpType(writer, module, param.ty);
        }
        try writer.writeAll(") -> ");
        try dumpType(writer, module, self.return_type);
        try writer.writeByte('\n');

        if (self.locals.len != 0) {
            try writer.writeAll("locals:\n");
            for (self.locals, 0..) |local, i| {
                try writer.print("  local#{} {s}: ", .{ i, local.name });
                try dumpType(writer, module, local.ty);
                try writer.writeByte('\n');
            }
        }

        if (self.ownership_trace.len != 0) {
            try writer.writeAll("ownership:\n");
            for (self.ownership_trace) |line| {
                try writer.writeAll("  ");
                try writer.writeAll(line.text);
                try writer.writeByte('\n');
            }
        }

        for (self.blocks) |block| {
            try writer.print("{s}:\n", .{block.name});
            for (block.instructions) |inst| {
                try writer.writeAll("  ");
                try inst.dump(writer, module);
                try writer.writeByte('\n');
            }
            try writer.writeAll("  ");
            try block.terminator.dump(writer);
            try writer.writeByte('\n');
        }
    }
};

pub const Param = struct {
    name: []const u8,
    ty: TypeId,
};

pub const Local = struct {
    name: []const u8,
    ty: TypeId,
};

pub const OwnershipTraceLine = struct {
    text: []const u8,
};

pub const BasicBlock = struct {
    name: []const u8,
    instructions: []Inst,
    terminator: Terminator,
    // Error arm entered from a source `catch` block; the value identifies the
    // internal error carrier whose diagnostic record the block borrows.
    catch_failure: ?ValueId = null,
    // Catch scopes left by this block's terminator, innermost first. A
    // propagated alias keeps its diagnostic record; handled failures retire it.
    catch_exits: []const CatchExit = &.{},

    pub fn deinit(self: BasicBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.instructions) |inst| inst.deinit(allocator);
        allocator.free(self.instructions);
        if (self.catch_exits.len != 0) allocator.free(self.catch_exits);
    }
};

pub const CatchExit = struct {
    carrier: ValueId,
    disposition: enum { handled, propagated_alias },
};

pub const Inst = struct {
    id: ?ValueId,
    ty: ?TypeId,
    data: InstData,

    pub fn deinit(self: Inst, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }

    pub fn dump(self: Inst, writer: anytype, module: Module) !void {
        if (self.id) |id| {
            try writer.print("%{} = ", .{id});
        }
        try self.data.dump(writer, module);
    }
};

pub const InstData = union(enum) {
    const_int: i64,
    const_float: f64,
    const_bool: bool,
    const_string: []const u8,
    const_c_str: []const u8,
    param_ref: u32,
    type_desc: TypeId,
    global_addr: []const u8,

    stack_alloc: TypeId,
    field_ptr: FieldPtr,
    index_ptr: IndexPtr,
    union_payload_ptr: UnionPayloadPtr,
    load: ValueId,
    volatile_load: ValueId,
    store: Store,
    volatile_store: Store,

    int_binop: IntBinOp,
    int_cmp: IntCmp,
    int_to_int: ValueId,
    int_to_ptr: ValueId,
    ptr_to_int: ValueId,
    bitcast: ValueId,
    packed_to_int: ValueId,
    int_to_packed: ValueId,
    int_to_float: ValueId,
    float_to_int: ValueId,
    float_to_float: ValueId,
    float_binop: FloatBinOp,
    float_cmp: FloatCmp,
    string_cmp: StringCmp,
    sequence_cmp: SequenceCmp,
    sparse_cmp: SparseCmp,
    dense_new: UnaryValue,
    dense_copy: BinaryValue,
    dense_len: ValueId,
    dense_clear: BinaryValue,
    dense_reserve: TernaryValue,
    dense_data: ValueId,
    dense_at: TernaryValue,
    dense_push: TernaryValue,
    dense_push_move: TernaryValue,
    dense_pop: TernaryValue,
    dense_drop: BinaryValue,
    sparse_new: BinaryValue,
    sparse_copy: BinaryValue,
    sparse_drop: BinaryValue,
    sparse_len: ValueId,
    sparse_capacity: ValueId,
    sparse_clear: BinaryValue,
    sparse_indices: BinaryValue,
    sparse_contains_index: BinaryValue,
    sparse_payload_ptr: BinaryValue,
    sparse_get: QuaternaryValue,
    sparse_set: QuinaryValue,
    sparse_set_move: QuinaryValue,
    sparse_insert: QuaternaryValue,
    sparse_insert_move: QuaternaryValue,
    sparse_take: QuaternaryValue,

    call: Call,
    indirect_call: IndirectCall,
    inline_asm: InlineAsm,

    extract_tag: ValueId,
    extract_payload: ExtractPayload,
    extract_result: ExtractResult,
    trace_detail: TraceDetail,
    string_len: ValueId,
    extract_field: ExtractField,
    extract_slice_ptr: ValueId,
    extract_slice_len: ValueId,
    make_array: MakeArray,
    make_slice: MakeSlice,
    make_some: ValueId,
    make_none,
    make_struct: MakeStruct,
    make_union: MakeUnion,
    make_result: MakeResult,

    pub fn deinit(self: InstData, allocator: std.mem.Allocator) void {
        switch (self) {
            .call => |call| allocator.free(call.args),
            .indirect_call => |call| {
                allocator.free(call.args);
                allocator.free(call.address_args);
            },
            .inline_asm => |asm_stmt| {
                allocator.free(asm_stmt.lines);
                if (asm_stmt.output) |output| output.deinit(allocator);
                if (asm_stmt.inout) |inout| inout.deinit(allocator);
                allocator.free(asm_stmt.input_names);
                allocator.free(asm_stmt.input_constraints);
                allocator.free(asm_stmt.args);
                for (asm_stmt.clobbers) |clobber| clobber.deinit(allocator);
                allocator.free(asm_stmt.clobbers);
            },
            .const_string, .const_c_str => |value| allocator.free(value),
            .global_addr => |value| allocator.free(value),
            .make_array => |value| allocator.free(value.items),
            .make_struct => |value| allocator.free(value.fields),
            else => {},
        }
    }

    pub fn dump(self: InstData, writer: anytype, module: Module) !void {
        switch (self) {
            .const_int => |value| try writer.print("const_int {}", .{value}),
            .const_float => |value| try writer.print("const_float {d}", .{value}),
            .const_bool => |value| try writer.print("const_bool {}", .{value}),
            .const_string => |value| try writer.print("const_string \"{s}\"", .{value}),
            .const_c_str => |value| try writer.print("const_c_str \"{s}\"", .{value}),
            .param_ref => |index| try writer.print("param_ref {}", .{index}),
            .type_desc => |ty| {
                try writer.writeAll("type_desc ");
                try dumpType(writer, module, ty);
            },
            .global_addr => |name| try writer.print("global_addr {s}", .{name}),
            .stack_alloc => |ty| {
                try writer.writeAll("stack_alloc ");
                try dumpType(writer, module, ty);
            },
            .field_ptr => |field| try writer.print("field_ptr %{} .{}", .{ field.ptr, field.field_index }),
            .index_ptr => |index| try writer.print("index_ptr %{}[%{}]", .{ index.ptr, index.index }),
            .union_payload_ptr => |payload| try writer.print("union_payload_ptr %{} case={}", .{ payload.ptr, payload.union_tag }),
            .load => |ptr| try writer.print("load %{}", .{ptr}),
            .volatile_load => |ptr| try writer.print("volatile_load %{}", .{ptr}),
            .store => |store| try writer.print("store %{}, %{}", .{ store.ptr, store.value }),
            .volatile_store => |store| try writer.print("volatile_store %{}, %{}", .{ store.ptr, store.value }),
            .int_binop => |bin| try writer.print("int_binop {s} %{}, %{}", .{ @tagName(bin.op), bin.lhs, bin.rhs }),
            .int_cmp => |cmp| try writer.print("int_cmp {s} %{}, %{}", .{ @tagName(cmp.op), cmp.lhs, cmp.rhs }),
            .int_to_int => |value| try writer.print("int_to_int %{}", .{value}),
            .int_to_ptr => |value| try writer.print("int_to_ptr %{}", .{value}),
            .ptr_to_int => |value| try writer.print("ptr_to_int %{}", .{value}),
            .bitcast => |value| try writer.print("bitcast %{}", .{value}),
            .packed_to_int => |value| try writer.print("packed_to_int %{}", .{value}),
            .int_to_packed => |value| try writer.print("int_to_packed %{}", .{value}),
            .int_to_float => |value| try writer.print("int_to_float %{}", .{value}),
            .float_to_int => |value| try writer.print("float_to_int %{}", .{value}),
            .float_to_float => |value| try writer.print("float_to_float %{}", .{value}),
            .float_binop => |bin| try writer.print("float_binop {s} %{}, %{}", .{ @tagName(bin.op), bin.lhs, bin.rhs }),
            .float_cmp => |cmp| try writer.print("float_cmp {s} %{}, %{}", .{ @tagName(cmp.op), cmp.lhs, cmp.rhs }),
            .string_cmp => |cmp| try writer.print("string_cmp {s} %{}, %{}", .{ @tagName(cmp.op), cmp.lhs, cmp.rhs }),
            .sequence_cmp => |cmp| try writer.print("sequence_cmp {s} %{}, %{}, %{}, %{}, %{}", .{ @tagName(cmp.op), cmp.lhs_ptr, cmp.lhs_len, cmp.rhs_ptr, cmp.rhs_len, cmp.elem_desc }),
            .sparse_cmp => |cmp| try writer.print("sparse_cmp {s} %{}, %{}, %{}", .{ @tagName(cmp.op), cmp.lhs, cmp.rhs, cmp.elem_desc }),
            .dense_new => |value| try writer.print("dense_new %{}", .{value.value}),
            .dense_copy => |value| try writer.print("dense_copy %{}, %{}", .{ value.lhs, value.rhs }),
            .dense_len => |value| try writer.print("dense_len %{}", .{value}),
            .dense_clear => |value| try writer.print("dense_clear %{}, %{}", .{ value.lhs, value.rhs }),
            .dense_reserve => |value| try writer.print("dense_reserve %{}, %{}, %{}", .{ value.a, value.b, value.c }),
            .dense_data => |value| try writer.print("dense_data %{}", .{value}),
            .dense_at => |value| try writer.print("dense_at %{}, %{}, %{}", .{ value.a, value.b, value.c }),
            .dense_push => |value| try writer.print("dense_push %{}, %{}, %{}", .{ value.a, value.b, value.c }),
            .dense_push_move => |value| try writer.print("dense_push_move %{}, %{}, %{}", .{ value.a, value.b, value.c }),
            .dense_pop => |value| try writer.print("dense_pop %{}, %{}, %{}", .{ value.a, value.b, value.c }),
            .dense_drop => |value| try writer.print("dense_drop %{}, %{}", .{ value.lhs, value.rhs }),
            .sparse_new => |value| try writer.print("sparse_new %{}, %{}", .{ value.lhs, value.rhs }),
            .sparse_copy => |value| try writer.print("sparse_copy %{}, %{}", .{ value.lhs, value.rhs }),
            .sparse_drop => |value| try writer.print("sparse_drop %{}, %{}", .{ value.lhs, value.rhs }),
            .sparse_len => |value| try writer.print("sparse_len %{}", .{value}),
            .sparse_capacity => |value| try writer.print("sparse_capacity %{}", .{value}),
            .sparse_clear => |value| try writer.print("sparse_clear %{}, %{}", .{ value.lhs, value.rhs }),
            .sparse_indices => |value| try writer.print("sparse_indices %{}, %{}", .{ value.lhs, value.rhs }),
            .sparse_contains_index => |value| try writer.print("sparse_contains_index %{}, %{}", .{ value.lhs, value.rhs }),
            .sparse_payload_ptr => |value| try writer.print("sparse_payload_ptr %{}, %{}", .{ value.lhs, value.rhs }),
            .sparse_get => |value| try writer.print("sparse_get %{}, %{}, %{}, %{}", .{ value.a, value.b, value.c, value.d }),
            .sparse_set => |value| try writer.print("sparse_set %{}, %{}, %{}, %{}, %{}", .{ value.a, value.b, value.c, value.d, value.e }),
            .sparse_set_move => |value| try writer.print("sparse_set_move %{}, %{}, %{}, %{}, %{}", .{ value.a, value.b, value.c, value.d, value.e }),
            .sparse_insert => |value| try writer.print("sparse_insert %{}, %{}, %{}, %{}", .{ value.a, value.b, value.c, value.d }),
            .sparse_insert_move => |value| try writer.print("sparse_insert_move %{}, %{}, %{}, %{}", .{ value.a, value.b, value.c, value.d }),
            .sparse_take => |value| try writer.print("sparse_take %{}, %{}, %{}, %{}", .{ value.a, value.b, value.c, value.d }),
            .call => |call| {
                try writer.print("call {s}(", .{call.name});
                for (call.args, 0..) |arg, i| {
                    if (i != 0) try writer.writeAll(", ");
                    try writer.print("%{}", .{arg});
                }
                try writer.writeByte(')');
            },
            .indirect_call => |call| {
                try writer.print("indirect_call %{}(", .{call.callee});
                for (call.args, 0..) |arg, i| {
                    if (i != 0) try writer.writeAll(", ");
                    try writer.print("%{}", .{arg});
                }
                try writer.writeByte(')');
            },
            .inline_asm => |asm_stmt| {
                try writer.writeAll("inline_asm");
                if (asm_stmt.is_volatile) try writer.writeAll(" volatile");
                try writer.writeAll(" { ");
                for (asm_stmt.lines, 0..) |line, i| {
                    if (i != 0) try writer.writeAll(" ");
                    try writer.print("\"{s}\";", .{line});
                }
                if (asm_stmt.output) |output| {
                    try writer.print(" out {s} {s};", .{ @tagName(output.constraint), output.name });
                }
                if (asm_stmt.inout) |inout| {
                    try writer.print(" inout {s} {s}=%{};", .{ @tagName(inout.constraint), inout.name, inout.seed });
                }
                for (asm_stmt.input_names, asm_stmt.input_constraints, asm_stmt.args) |name, constraint, arg| {
                    try writer.print(" in {s} {s}=%{};", .{ @tagName(constraint), name, arg });
                }
                for (asm_stmt.clobbers) |clobber| {
                    switch (clobber) {
                        .memory => try writer.writeAll(" clobber memory;"),
                        .flags => try writer.writeAll(" clobber flags;"),
                        .register => |name| try writer.print(" clobber {s};", .{name}),
                    }
                }
                try writer.writeAll(" }");
            },
            .extract_tag => |value| try writer.print("extract_tag %{}", .{value}),
            .extract_payload => |payload| {
                try writer.print("extract_payload %{}", .{payload.value});
                if (payload.union_tag) |tag| {
                    try writer.print(" case={}", .{tag});
                }
            },
            .extract_result => |value| try writer.print("extract_result {s} %{}", .{ if (value.is_err) "err" else "ok", value.value }),
            .string_len => |value| try writer.print("string_len %{}", .{value}),
            .extract_field => |field| try writer.print("extract_field %{} .{}", .{ field.value, field.field_index }),
            .extract_slice_ptr => |value| try writer.print("extract_slice_ptr %{}", .{value}),
            .extract_slice_len => |value| try writer.print("extract_slice_len %{}", .{value}),
            .make_array => |array| {
                try writer.writeAll("make_array(");
                for (array.items, 0..) |item, i| {
                    if (i != 0) try writer.writeAll(", ");
                    try writer.print("%{}", .{item});
                }
                try writer.writeByte(')');
            },
            .make_slice => |slice| try writer.print("make_slice %{}, %{}", .{ slice.ptr, slice.len }),
            .make_some => |value| try writer.print("make_some %{}", .{value}),
            .make_none => try writer.writeAll("make_none"),
            .make_struct => |value| {
                try writer.writeAll("make_struct(");
                for (value.fields, 0..) |field, i| {
                    if (i != 0) try writer.writeAll(", ");
                    try writer.print("%{}", .{field});
                }
                try writer.writeByte(')');
            },
            .make_union => |value| {
                try writer.print("make_union tag={} ", .{value.tag});
                if (value.payload) |payload| {
                    try writer.print("%{}", .{payload});
                } else {
                    try writer.writeAll("void");
                }
            },
            .make_result => |value| {
                try writer.print("make_result {s} ", .{if (value.is_err) "err" else "ok"});
                if (value.payload) |payload| {
                    try writer.print("%{}", .{payload});
                } else {
                    try writer.writeAll("void");
                }
                switch (value.trace) {
                    .none => {},
                    .create => |creation| try writer.print(" trace_create {}", .{creation.origin}),
                    .transfer => |transfer| {
                        try writer.print(" trace_transfer %{}", .{transfer.carrier});
                        if (transfer.append_site) |site| try writer.print(" append {}", .{site});
                    },
                }
            },
            .trace_detail => |value| try writer.print("trace_detail {s} %{}", .{ @tagName(value.field), value.carrier }),
        }
    }
};

pub const Store = struct {
    ptr: ValueId,
    value: ValueId,
};

pub const FieldPtr = struct {
    ptr: ValueId,
    field_index: u32,
};

pub const IndexPtr = struct {
    ptr: ValueId,
    index: ValueId,
};

pub const UnionPayloadPtr = struct {
    ptr: ValueId,
    union_tag: i64,
};

pub const IntBinOp = struct {
    op: Op,
    lhs: ValueId,
    rhs: ValueId,

    pub const Op = enum {
        add,
        wrap_add,
        sub,
        wrap_sub,
        mul,
        wrap_mul,
        div,
        mod,
        shl,
        shr,
        bit_and,
        bit_or,
        bit_xor,
    };
};

pub const IntCmp = struct {
    op: Op,
    lhs: ValueId,
    rhs: ValueId,

    pub const Op = enum {
        eq,
        ne,
        lt,
        le,
        gt,
        ge,
    };
};

pub const FloatBinOp = struct {
    op: Op,
    lhs: ValueId,
    rhs: ValueId,

    pub const Op = enum {
        add,
        sub,
        mul,
        div,
    };
};

pub const FloatCmp = struct {
    op: Op,
    lhs: ValueId,
    rhs: ValueId,

    pub const Op = enum {
        eq,
        ne,
        lt,
        le,
        gt,
        ge,
    };
};

pub const StringCmp = struct {
    op: Op,
    lhs: ValueId,
    rhs: ValueId,

    pub const Op = enum {
        eq,
        ne,
    };
};

pub const SequenceCmp = struct {
    op: Op,
    lhs_ptr: ValueId,
    lhs_len: ValueId,
    rhs_ptr: ValueId,
    rhs_len: ValueId,
    elem_desc: ValueId,

    pub const Op = enum {
        eq,
        ne,
    };
};

pub const SparseCmp = struct {
    op: Op,
    lhs: ValueId,
    rhs: ValueId,
    elem_desc: ValueId,

    pub const Op = enum {
        eq,
        ne,
    };
};

pub const UnaryValue = struct {
    value: ValueId,
};

pub const BinaryValue = struct {
    lhs: ValueId,
    rhs: ValueId,
};

pub const TernaryValue = struct {
    a: ValueId,
    b: ValueId,
    c: ValueId,
};

pub const QuaternaryValue = struct {
    a: ValueId,
    b: ValueId,
    c: ValueId,
    d: ValueId,
};

pub const QuinaryValue = struct {
    a: ValueId,
    b: ValueId,
    c: ValueId,
    d: ValueId,
    e: ValueId,
};

pub const MakeUnion = struct {
    tag: i64,
    payload: ?ValueId,
};

pub const MakeResult = struct {
    is_err: bool,
    payload: ?ValueId,
    trace: TraceAction = .none,
};

// Compiler-only record provenance. A transfer keeps the source record's sole
// alias; append_site is set only for a propagating `try`.
pub const TraceAction = union(enum) {
    none,
    create: struct { origin: u32, message: ?ValueId = null },
    transfer: struct { carrier: ValueId, append_site: ?u32 = null },
};

pub const TraceDetailField = enum { available, origin, origin_file, site_count, omitted, message, site, site_file };

pub const TraceDetail = struct {
    carrier: ValueId,
    field: TraceDetailField,
    index: ?ValueId = null,
};

pub const ExtractPayload = struct {
    value: ValueId,
    union_tag: ?i64 = null,
};

pub const ExtractResult = struct {
    value: ValueId,
    is_err: bool,
};

pub const ExtractField = struct {
    value: ValueId,
    field_index: u32,
};

pub const MakeStruct = struct {
    fields: []const ValueId,
};

pub const MakeArray = struct {
    items: []const ValueId,
};

pub const MakeSlice = struct {
    ptr: ValueId,
    len: ValueId,
};

pub const Call = struct {
    name: []const u8,
    args: []const ValueId,
};

pub const IndirectCall = struct {
    callee: ValueId,
    args: []const ValueId,
    address_args: []const bool,
};

pub const InlineAsm = struct {
    lines: []const []const u8,
    output: ?AsmOutput = null,
    inout: ?AsmInOut = null,
    input_names: []const []const u8,
    input_constraints: []const AsmConstraint,
    args: []const ValueId,
    clobbers: []const AsmClobber,
    is_volatile: bool,
};

pub const AsmOutput = struct {
    name: []const u8,
    constraint: AsmConstraint = .reg,

    pub fn deinit(self: AsmOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const AsmInOut = struct {
    name: []const u8,
    constraint: AsmConstraint = .reg,
    seed: ValueId,

    pub fn deinit(self: AsmInOut, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const AsmConstraint = enum {
    reg,
    tied_reg,
};

pub const AsmClobber = union(enum) {
    memory,
    flags,

    register: []const u8,

    pub fn deinit(self: AsmClobber, allocator: std.mem.Allocator) void {
        switch (self) {
            .register => |name| allocator.free(name),
            else => {},
        }
    }
};

pub const Terminator = union(enum) {
    @"return": ?ValueId,
    br: BlockId,
    cond_br: CondBr,
    @"unreachable",
    none,

    pub fn dump(self: Terminator, writer: anytype) !void {
        switch (self) {
            .@"return" => |value| {
                if (value) |v| {
                    try writer.print("return %{}", .{v});
                } else {
                    try writer.writeAll("return");
                }
            },
            .br => |target| try writer.print("br bb{}", .{target}),
            .cond_br => |branch| try writer.print("cond_br %{}, bb{}, bb{}", .{ branch.condition, branch.then_block, branch.else_block }),
            .@"unreachable" => try writer.writeAll("unreachable"),
            .none => try writer.writeAll("<unterminated>"),
        }
    }
};

pub const CondBr = struct {
    condition: ValueId,
    then_block: BlockId,
    else_block: BlockId,
};

pub fn dumpType(writer: anytype, module: Module, ty: TypeId) !void {
    switch (module.types[ty]) {
        .void => try writer.writeAll("void"),
        .bool => try writer.writeAll("bool"),
        .int => |int_ty| {
            if (int_ty.signed) {
                try writer.print("i{}", .{int_ty.bits});
            } else {
                try writer.print("u{}", .{int_ty.bits});
            }
        },
        .float => |float_ty| try writer.print("f{}", .{float_ty.bits}),
        .string => try writer.writeAll("string"),
        .pointer => |child| {
            try writer.writeByte('&');
            try dumpType(writer, module, child);
        },
        .array => |array_ty| {
            try writer.print("[{d}]", .{array_ty.len});
            try dumpType(writer, module, array_ty.elem);
        },
        .slice => |item_ty| {
            try writer.writeAll("[]");
            try dumpType(writer, module, item_ty);
        },
        .dense_array => |item_ty| {
            try writer.writeAll("[:]");
            try dumpType(writer, module, item_ty);
        },
        .sparse_array => |item_ty| {
            try writer.writeAll("[;]");
            try dumpType(writer, module, item_ty);
        },
        .optional => |payload| {
            try writer.writeByte('?');
            try dumpType(writer, module, payload);
        },
        .result => |result_ty| {
            try writer.writeAll("result<");
            try dumpType(writer, module, result_ty.ok);
            try writer.writeAll(", ");
            try dumpType(writer, module, result_ty.err);
            try writer.writeByte('>');
        },
        .@"struct" => |struct_ty| try writer.writeAll(struct_ty.name),
        .@"union" => |union_ty| {
            try writer.writeAll(union_ty.name);
            if (union_ty.payloads.len != 0) {
                try writer.writeAll("/*");
                for (union_ty.payloads, 0..) |payload, i| {
                    if (i != 0) try writer.writeAll(", ");
                    if (payload) |payload_ty| {
                        try dumpType(writer, module, payload_ty);
                    } else {
                        try writer.writeAll("void");
                    }
                }
                try writer.writeAll("*/");
            }
        },
    }
}

test "LIR dumps union payload ptr instruction" {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    var text_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &text);

    const module = Module{
        .types = &.{.{ .void = {} }},
        .globals = &.{},
        .functions = &.{},
    };
    const data = InstData{ .union_payload_ptr = .{
        .ptr = 7,
        .union_tag = 2,
    } };

    try data.dump(&text_writer.writer, module);
    text = text_writer.toArrayList();
    try std.testing.expectEqualStrings("union_payload_ptr %7 case=2", text.items);
}

test "LIR verifier rejects invalid nested type references" {
    const module: Module = .{
        .types = &.{.{ .pointer = 4 }},
        .globals = &.{},
        .functions = &.{},
    };

    try std.testing.expectError(error.InvalidTypeReference, module.verify(std.testing.allocator));
}

test "LIR verifier rejects duplicate and missing value definitions" {
    var instructions = [_]Inst{
        .{ .id = 0, .ty = 1, .data = .{ .const_bool = true } },
        .{ .id = 0, .ty = 1, .data = .{ .const_bool = false } },
    };
    const blocks = [_]BasicBlock{.{
        .name = "entry",
        .instructions = &instructions,
        .terminator = .{ .@"return" = null },
    }};
    const functions = [_]Function{.{
        .name = "main",
        .params = &.{},
        .return_type = 0,
        .locals = &.{},
        .ownership_trace = &.{},
        .blocks = &blocks,
        .entry = 0,
    }};
    const module: Module = .{
        .types = &.{ .{ .void = {} }, .{ .bool = {} } },
        .globals = &.{},
        .functions = &functions,
    };

    try std.testing.expectError(error.InvalidValueDefinition, module.verify(std.testing.allocator));

    instructions[1] = .{ .id = 1, .ty = 1, .data = .{ .load = 2 } };
    try std.testing.expectError(error.InvalidValueReference, module.verify(std.testing.allocator));
}

test "LIR verifier rejects invalid control flow and unterminated blocks" {
    const instructions = [_]Inst{
        .{ .id = 0, .ty = 1, .data = .{ .const_bool = true } },
    };
    var blocks = [_]BasicBlock{.{
        .name = "entry",
        .instructions = @constCast(&instructions),
        .terminator = .{ .cond_br = .{
            .condition = 0,
            .then_block = 0,
            .else_block = 1,
        } },
    }};
    const functions = [_]Function{.{
        .name = "main",
        .params = &.{},
        .return_type = 0,
        .locals = &.{},
        .ownership_trace = &.{},
        .blocks = &blocks,
        .entry = 0,
    }};
    const module: Module = .{
        .types = &.{ .{ .void = {} }, .{ .bool = {} } },
        .globals = &.{},
        .functions = &functions,
    };

    try std.testing.expectError(error.InvalidBlockTarget, module.verify(std.testing.allocator));

    blocks[0].terminator = .none;
    try std.testing.expectError(error.UnterminatedBlock, module.verify(std.testing.allocator));
}

test "LIR verifier rejects mismatched inline asm inputs" {
    const input_names = [_][]const u8{"value"};
    const instructions = [_]Inst{.{
        .id = null,
        .ty = null,
        .data = .{ .inline_asm = .{
            .lines = &.{},
            .input_names = &input_names,
            .input_constraints = &.{},
            .args = &.{},
            .clobbers = &.{},
            .is_volatile = true,
        } },
    }};
    const blocks = [_]BasicBlock{.{
        .name = "entry",
        .instructions = @constCast(&instructions),
        .terminator = .{ .@"return" = null },
    }};
    const functions = [_]Function{.{
        .name = "main",
        .params = &.{},
        .return_type = 0,
        .locals = &.{},
        .ownership_trace = &.{},
        .blocks = &blocks,
        .entry = 0,
    }};
    const module: Module = .{
        .types = &.{.{ .void = {} }},
        .globals = &.{},
        .functions = &functions,
    };

    try std.testing.expectError(error.InvalidInlineAsm, module.verify(std.testing.allocator));
}

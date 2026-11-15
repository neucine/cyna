const std = @import("std");
const sir = @import("../sema/sir.zig");
const identity = @import("../sema/identity.zig");
const semantic_types = @import("../sema/types.zig");
const generated_names = @import("../generated_names.zig");
const capability = @import("../capability.zig");
const lir = @import("lir.zig");
const errors = @import("errors.zig");
const module_index = @import("module_index.zig");
const type_policy = @import("type_policy.zig");

pub const Builtins = struct {
    void_type: lir.TypeId,
    bool_type: lir.TypeId,
    i64_type: lir.TypeId,
    f32_type: lir.TypeId,
    f64_type: lir.TypeId,
    string_type: lir.TypeId,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    module: *const sir.Module,
    indexes: *const module_index.Indexes,
    target: ?[]const u8,
    types: *std.ArrayListUnmanaged(lir.TypeDecl),
    generated_names: *std.ArrayListUnmanaged([]const u8),
    union_types: *std.StringHashMapUnmanaged(lir.TypeId),
    struct_types: *std.StringHashMapUnmanaged(lir.TypeId),
    arrow_callable_type: *?lir.TypeId,
    builtins: Builtins,
};

pub fn appendType(context: *Context, ty: lir.TypeDecl) errors.Error!lir.TypeId {
    const id: lir.TypeId = @intCast(context.types.items.len);
    try context.types.append(context.allocator, ty);
    return id;
}

pub fn canonicalTypeNode(context: *const Context, maybe_type_id: ?sir.TypeId) errors.Error!*const semantic_types.Type {
    const type_id = maybe_type_id orelse return error.InvalidIdentity;
    const interner = if (context.module.canonical_types) |*types| types else return error.InvalidIdentity;
    return interner.get(type_id) catch return error.InvalidIdentity;
}

pub fn canonicalNominalDeclId(
    context: *const Context,
    maybe_type_id: ?sir.TypeId,
    expected_kind: semantic_types.NominalKind,
) errors.Error!identity.DeclId {
    return switch ((try canonicalTypeNode(context, maybe_type_id)).*) {
        .nominal => |nominal| if (nominal.kind == expected_kind) nominal.decl_id else error.InvalidIdentity,
        .generic_instance => |instance| if (instance.kind == expected_kind)
            instance.decl_id orelse error.InvalidIdentity
        else
            error.InvalidIdentity,
        else => error.InvalidIdentity,
    };
}

pub fn lowerCanonicalType(context: *Context, maybe_type_id: ?sir.TypeId) errors.Error!lir.TypeId {
    const node = try canonicalTypeNode(context, maybe_type_id);
    return switch (node.*) {
        .primitive => |primitive| switch (primitive) {
            .void, .c_void => context.builtins.void_type,
            .bool => context.builtins.bool_type,
            .rune => appendType(context, .{ .int = .{ .bits = 32, .signed = false } }),
            .string => context.builtins.string_type,
            .c_str => appendType(context, .{ .pointer = context.builtins.void_type }),
        },
        .inferred_integer => context.builtins.i64_type,
        .inferred_float => context.builtins.f64_type,
        .integer => |integer| appendType(context, .{ .int = .{ .bits = integer.bits, .signed = integer.signed } }),
        .float => |float| appendType(context, .{ .float = .{ .bits = float.bits } }),
        // A generic binder never reaches lowering: only instantiated bodies,
        // where every binder has a concrete substitution, are emitted.
        .generic_parameter => error.LowerInvariantViolation,
        .nominal => |nominal| switch (nominal.kind) {
            .type_alias => lowerCanonicalType(context, nominal.underlying),
            .@"enum" => lowerEnumTypeById(context, nominal.decl_id),
            .@"union" => lowerUnionTypeById(context, nominal.decl_id),
            .@"struct" => lowerStructTypeById(context, nominal.decl_id),
            .protocol => error.LowerInvariantViolation,
        },
        .generic_instance => |instance| switch (instance.kind) {
            .@"struct" => lowerStructTypeById(context, instance.decl_id orelse return error.InvalidIdentity),
            else => error.LowerInvariantViolation,
        },
        .optional => |payload| appendType(context, .{ .optional = try lowerCanonicalType(context, payload) }),
        .array => |array| appendType(context, .{ .array = .{
            .len = array.len,
            .elem = try lowerCanonicalType(context, array.item),
        } }),
        .tuple => |members| blk: {
            const key = try std.fmt.allocPrint(context.allocator, "__cyna_tuple_{d}", .{@backingInt(maybe_type_id.?)});
            if (context.struct_types.get(key)) |existing| {
                context.allocator.free(key);
                break :blk existing;
            }
            context.generated_names.append(context.allocator, key) catch |err| {
                context.allocator.free(key);
                return err;
            };
            const ty = try appendType(context, .{ .@"struct" = .{
                .name = key,
                .is_c_layout = false,
                .is_packed = false,
                .is_shared_value = false,
                .packed_bits = 0,
                .fields = &.{},
            } });
            try context.struct_types.put(context.allocator, key, ty);
            const fields = try context.allocator.alloc(lir.StructField, members.len);
            errdefer context.allocator.free(fields);
            for (members, fields, 0..) |member, *field, index| {
                const field_name = try std.fmt.allocPrint(context.allocator, "{d}", .{index});
                context.generated_names.append(context.allocator, field_name) catch |err| {
                    context.allocator.free(field_name);
                    return err;
                };
                field.* = .{ .name = field_name, .ty = try lowerCanonicalType(context, member) };
            }
            context.types.items[ty].@"struct".fields = fields;
            break :blk ty;
        },
        .dense_array => |item| appendType(context, .{ .dense_array = try lowerCanonicalType(context, item) }),
        .sparse_array => |item| appendType(context, .{ .sparse_array = try lowerCanonicalType(context, item) }),
        .slice => |slice| appendType(context, .{ .slice = try lowerCanonicalType(context, slice.item) }),
        .result => |result| appendType(context, .{ .result = .{
            .ok = try lowerCanonicalType(context, result.ok),
            .err = try lowerCanonicalType(context, result.err),
        } }),
        .error_union => |members| blk: {
            const name = try std.fmt.allocPrint(context.allocator, "__inline_error_union_{}", .{@backingInt(maybe_type_id.?)});
            errdefer context.allocator.free(name);
            const payloads = try context.allocator.alloc(?lir.TypeId, members.len);
            errdefer context.allocator.free(payloads);
            for (members, payloads) |member, *payload| payload.* = try lowerCanonicalType(context, member);
            try context.generated_names.append(context.allocator, name);
            errdefer context.generated_names.items.len -= 1;
            break :blk appendType(context, .{ .@"union" = .{ .name = name, .payloads = payloads } });
        },
        .ref_ => |ref_type| appendType(context, .{ .pointer = try lowerCanonicalType(context, ref_type.target) }),
        .owned => |target| lowerCanonicalType(context, target),
        .raw => |raw| appendType(context, .{ .pointer = try lowerCanonicalType(context, raw.target) }),
        .callable => |callable| switch (callable.kind) {
            .function => appendType(context, .{ .pointer = context.builtins.void_type }),
            .arrow => lowerArrowCallableType(context),
        },
    };
}

pub fn lowerType(context: *Context, kind: sir.Type, type_name: ?[]const u8) errors.Error!lir.TypeId {
    return switch (kind) {
        .void => context.builtins.void_type,
        .bool => context.builtins.bool_type,
        .rune => appendType(context, .{ .int = .{ .bits = 32, .signed = false } }),
        .int => if (type_name) |name| lowerExactNamedIntType(context, name) else context.builtins.i64_type,
        .float => if (type_name) |name|
            if (std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "c_float"))
                context.builtins.f32_type
            else
                context.builtins.f64_type
        else
            context.builtins.f64_type,
        .string => context.builtins.string_type,
        .function => appendType(context, .{ .pointer = context.builtins.void_type }),
        .arrow_callable => lowerArrowCallableType(context),
        else => error.LowerInvariantViolation,
    };
}

pub fn lowerArrowCallableType(context: *Context) errors.Error!lir.TypeId {
    if (context.arrow_callable_type.*) |ty| return ty;
    const ptr_ty = try appendType(context, .{ .pointer = context.builtins.void_type });
    const fields = try context.allocator.alloc(lir.StructField, 2);
    fields[0] = .{ .name = "__thunk", .ty = ptr_ty };
    fields[1] = .{ .name = "__env", .ty = ptr_ty };
    const ty = try appendType(context, .{ .@"struct" = .{
        .name = generated_names.arrow_callable_type,
        .is_c_layout = false,
        .is_packed = false,
        .is_shared_value = false,
        .packed_bits = 0,
        .fields = fields,
    } });
    context.arrow_callable_type.* = ty;
    return ty;
}

pub fn lowerSliceType(context: *Context, item_kind: sir.Type, item_name: ?[]const u8) errors.Error!lir.TypeId {
    return appendType(context, .{ .slice = try lowerType(context, item_kind, item_name) });
}

pub fn lowerArrayTypeFromCanonicalItem(context: *Context, len: usize, item_type_id: ?sir.TypeId) errors.Error!lir.TypeId {
    return appendType(context, .{ .array = .{ .len = len, .elem = try lowerCanonicalType(context, item_type_id) } });
}

pub fn lowerDenseArrayTypeFromCanonicalItem(context: *Context, item_type_id: ?sir.TypeId) errors.Error!lir.TypeId {
    return appendType(context, .{ .dense_array = try lowerCanonicalType(context, item_type_id) });
}

pub fn lowerSparseArrayTypeFromCanonicalItem(context: *Context, item_type_id: ?sir.TypeId) errors.Error!lir.TypeId {
    return appendType(context, .{ .sparse_array = try lowerCanonicalType(context, item_type_id) });
}

pub fn lowerExactNamedIntType(context: *Context, type_name: []const u8) errors.Error!lir.TypeId {
    if (type_policy.namedIntInfo(type_name, context.target)) |info| return appendType(context, .{ .int = info });
    return context.builtins.i64_type;
}

pub fn lowerEnumTypeById(context: *Context, decl_id: identity.DeclId) errors.Error!lir.TypeId {
    return lowerEnumDeclType(context, try context.indexes.enumDecl(context.module.*, decl_id));
}

pub fn lowerEnumDeclType(context: *Context, decl: sir.EnumDecl) errors.Error!lir.TypeId {
    if (decl.repr_name) |repr_name| return lowerExactNamedIntType(context, repr_name);
    return context.builtins.i64_type;
}

pub fn lowerStructTypeById(context: *Context, decl_id: identity.DeclId) errors.Error!lir.TypeId {
    return lowerStructDeclType(context, try context.indexes.structDecl(context.module.*, decl_id));
}

pub fn lowerStructDeclType(context: *Context, decl: sir.StructDecl) errors.Error!lir.TypeId {
    const key = try qualifiedTypeKey(context, decl.module_name, decl.name);
    if (context.struct_types.get(key)) |existing| return existing;

    const ty = try appendType(context, .{ .@"struct" = .{
        .name = decl.name,
        .qualified_name = key,
        .is_c_layout = decl.layout == .c,
        .is_packed = decl.layout == .@"packed",
        .is_shared_value = decl.is_shared_value,
        .shared_runtime = switch (decl.shared_runtime) {
            .none => .none,
            .arc => .arc,
        },
        .drop_runtime = switch (decl.drop_runtime) {
            .none => .none,
            .task_discard => .task_discard,
        },
        .packed_bits = 0,
        .fields = &.{},
    } });
    try context.struct_types.put(context.allocator, key, ty);

    const fields = try context.allocator.alloc(lir.StructField, decl.fields.len);
    errdefer context.allocator.free(fields);
    var packed_bit_cursor: u32 = 0;
    for (decl.fields, fields) |field, *out_field| {
        const field_ty = try lowerCanonicalType(context, field.type_id);
        const is_packed = decl.layout == .@"packed";
        const field_bit_width: u16 = if (is_packed) try packedBitWidthForType(context, field_ty) else 0;
        out_field.* = .{
            .name = field.name,
            .ty = field_ty,
            .bit_offset = if (is_packed) packed_bit_cursor else 0,
            .bit_width = field_bit_width,
        };
        if (is_packed) packed_bit_cursor += field_bit_width;
    }

    context.types.items[ty].@"struct".packed_bits = if (decl.layout == .@"packed") packed_bit_cursor else 0;
    context.types.items[ty].@"struct".fields = fields;
    return ty;
}

pub fn packedBitWidthForType(context: *Context, ty: lir.TypeId) errors.Error!u16 {
    return switch (context.types.items[ty]) {
        .int => |int_ty| int_ty.bits,
        .@"struct" => |struct_ty| blk: {
            if (!struct_ty.is_packed) return error.LowerInvariantViolation;
            break :blk try checkedPackedAggregateWidth(struct_ty.packed_bits);
        },
        else => error.LowerInvariantViolation,
    };
}

pub fn lowerOptionalType(context: *Context, payload_kind: sir.Type, payload_name: ?[]const u8) errors.Error!lir.TypeId {
    return appendType(context, .{ .optional = try lowerType(context, payload_kind, payload_name) });
}

pub fn lowerUnionTypeById(context: *Context, decl_id: identity.DeclId) errors.Error!lir.TypeId {
    return lowerUnionDeclType(context, try context.indexes.unionDecl(context.module.*, decl_id));
}

pub fn lowerUnionDeclType(context: *Context, decl: sir.UnionDecl) errors.Error!lir.TypeId {
    const key = try qualifiedTypeKey(context, decl.module_name, decl.name);
    if (context.union_types.get(key)) |existing| return existing;

    const ty = try appendType(context, .{ .@"union" = .{
        .name = decl.name,
        .qualified_name = key,
        .payloads = &.{},
    } });
    try context.union_types.put(context.allocator, key, ty);

    const payloads = try context.allocator.alloc(?lir.TypeId, decl.fields.len);
    errdefer context.allocator.free(payloads);
    for (decl.fields, payloads) |field, *payload_ty| {
        payload_ty.* = if (field.has_payload) try lowerCanonicalType(context, field.type_id) else null;
    }

    context.types.items[ty].@"union".payloads = payloads;
    return ty;
}

fn qualifiedTypeKey(context: *Context, module_name: ?[]const u8, type_name: []const u8) errors.Error![]const u8 {
    if (module_name) |module_name_value| {
        const key = try std.fmt.allocPrint(context.allocator, "{s}.{s}", .{ module_name_value, type_name });
        try context.generated_names.append(context.allocator, key);
        return key;
    }
    return type_name;
}

fn checkedPackedAggregateWidth(bits: u32) capability.Error!u16 {
    if (bits > std.math.maxInt(u16)) return error.BackendPackedAggregateTooWide;
    return @intCast(bits);
}

test "oversized packed aggregate reports backend capability" {
    try std.testing.expectEqual(@as(u16, 65535), try checkedPackedAggregateWidth(65535));
    try std.testing.expectError(error.BackendPackedAggregateTooWide, checkedPackedAggregateWidth(65536));
}

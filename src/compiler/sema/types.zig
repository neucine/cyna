const std = @import("std");
const identity = @import("identity.zig");

pub const TypeId = enum(u32) { _ };

pub const Primitive = enum {
    void,
    c_void,
    bool,
    rune,
    string,
    c_str,
};

pub const Integer = struct {
    bits: u16,
    signed: bool,
    domain: IntegerDomain = .fixed,
};

pub const IntegerDomain = enum {
    fixed,
    isize,
    usize,
    c_char,
    c_schar,
    c_uchar,
    c_short,
    c_ushort,
    c_int,
    c_uint,
    c_long,
    c_ulong,
    c_llong,
    c_ullong,
    c_ptrdiff_t,
    c_size_t,
};

pub const Float = struct {
    bits: u16,
    domain: FloatDomain = .fixed,
};

pub const FloatDomain = enum {
    fixed,
    c_float,
    c_double,
};

pub const NominalKind = enum {
    type_alias,
    @"enum",
    @"union",
    protocol,
    @"struct",
};

pub const Nominal = struct {
    kind: NominalKind,
    decl_id: identity.DeclId,
    /// Distinct aliases retain nominal identity while exposing the canonical
    /// representation used by layout consumers.
    underlying: ?TypeId = null,
};

pub const Array = struct {
    len: usize,
    item: TypeId,
};

pub const Slice = struct {
    item: TypeId,
    is_const: bool,
};

pub const Result = struct {
    ok: TypeId,
    err: TypeId,
};

pub const Raw = struct {
    target: TypeId,
    is_const: bool = false,
    is_volatile: bool,
};

pub const CallableKind = enum {
    function,
    arrow,
};

pub const CallingConvention = enum {
    cyna,
    c,
};

pub const Callable = struct {
    kind: CallableKind,
    calling_convention: CallingConvention,
    params: []const TypeId,
    return_type: TypeId,
};

pub const GenericArgument = union(enum) {
    type: TypeId,
    const_usize: usize,
};

pub const Ref = struct {
    target: TypeId,
    is_const: bool,
};

pub const GenericInstance = struct {
    kind: NominalKind,
    base_decl_id: identity.DeclId,
    /// The concrete declaration produced for this structural instantiation.
    decl_id: ?identity.DeclId = null,
    args: []const GenericArgument,
};

/// Definition-site identity of a generic binder: the parameter itself, not any
/// concrete substitution. Generic declaration bodies are lowered against these
/// so the checked body flow can admit a declaration before it is instantiated.
/// Identity comes from the scope the binder was declared in and its position
/// there; the name is carried only for diagnostics.
pub const GenericParameterRef = struct {
    scope: identity.GenericScopeId,
    ordinal: u32,
    name: []const u8,
};

/// Canonical semantic type nodes. Display names deliberately do not participate
/// in identity; nominal equality is defined by the resolved declaration.
pub const Type = union(enum) {
    primitive: Primitive,
    inferred_integer,
    inferred_float,
    integer: Integer,
    float: Float,
    generic_parameter: GenericParameterRef,
    nominal: Nominal,
    generic_instance: GenericInstance,
    optional: TypeId,
    array: Array,
    /// Ordered structural product; the interner owns the element slice.
    tuple: []const TypeId,
    dense_array: TypeId,
    sparse_array: TypeId,
    slice: Slice,
    result: Result,
    /// A closed, structural error set. Members are enum TypeIds in canonical order.
    error_union: []const TypeId,
    ref_: Ref,
    owned: TypeId,
    raw: Raw,
    callable: Callable,
};

pub const LookupError = error{InvalidTypeId};
pub const InternError = error{ OutOfMemory, InvalidTypeId };

const TypeContext = struct {
    pub fn hash(_: TypeContext, ty: Type) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, ty, .Deep);
        return hasher.final();
    }

    pub fn eql(_: TypeContext, lhs: Type, rhs: Type) bool {
        if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
        return switch (lhs) {
            .callable => |lhs_callable| blk: {
                const rhs_callable = rhs.callable;
                break :blk lhs_callable.kind == rhs_callable.kind and
                    lhs_callable.calling_convention == rhs_callable.calling_convention and
                    lhs_callable.return_type == rhs_callable.return_type and
                    std.mem.eql(TypeId, lhs_callable.params, rhs_callable.params);
            },
            .generic_instance => |lhs_instance| blk: {
                const rhs_instance = rhs.generic_instance;
                break :blk lhs_instance.kind == rhs_instance.kind and
                    lhs_instance.base_decl_id == rhs_instance.base_decl_id and
                    lhs_instance.decl_id == rhs_instance.decl_id and
                    genericArgumentsEqual(lhs_instance.args, rhs_instance.args);
            },
            .error_union => |lhs_members| std.mem.eql(TypeId, lhs_members, rhs.error_union),
            .tuple => |lhs_members| std.mem.eql(TypeId, lhs_members, rhs.tuple),
            else => std.meta.eql(lhs, rhs),
        };
    }
};

fn genericArgumentsEqual(lhs: []const GenericArgument, rhs: []const GenericArgument) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |lhs_arg, rhs_arg| {
        if (std.meta.activeTag(lhs_arg) != std.meta.activeTag(rhs_arg)) return false;
        switch (lhs_arg) {
            .type => |lhs_type| if (lhs_type != rhs_arg.type) return false,
            .const_usize => |lhs_value| if (lhs_value != rhs_arg.const_usize) return false,
        }
    }
    return true;
}

/// Compilation-owned canonical type table.
pub const TypeInterner = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Type) = .empty,
    ids_by_type: std.HashMapUnmanaged(
        Type,
        TypeId,
        TypeContext,
        std.hash_map.default_max_load_percentage,
    ) = .empty,

    pub fn init(allocator: std.mem.Allocator) TypeInterner {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TypeInterner) void {
        self.ids_by_type.deinit(self.allocator);
        for (self.nodes.items) |node| {
            switch (node) {
                .callable => |callable| self.allocator.free(callable.params),
                .generic_instance => |instance| self.allocator.free(instance.args),
                .error_union => |members| self.allocator.free(members),
                .tuple => |members| self.allocator.free(members),
                else => {},
            }
        }
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn intern(self: *TypeInterner, ty: Type) InternError!TypeId {
        try self.validateChildren(ty);
        if (self.ids_by_type.get(ty)) |existing| return existing;

        const stored = try self.cloneType(ty);
        errdefer self.deinitType(stored);
        const entry = try self.ids_by_type.getOrPut(self.allocator, stored);
        if (entry.found_existing) {
            self.deinitType(stored);
            return entry.value_ptr.*;
        }

        errdefer _ = self.ids_by_type.remove(stored);
        const id: TypeId = @fromBackingInt(@intCast(@as(u32, @intCast(self.nodes.items.len))));
        try self.nodes.append(self.allocator, stored);
        entry.value_ptr.* = id;
        return id;
    }

    pub fn get(self: *const TypeInterner, id: TypeId) LookupError!*const Type {
        const index: usize = @backingInt(id);
        if (index >= self.nodes.items.len) return error.InvalidTypeId;
        return &self.nodes.items[index];
    }

    pub fn count(self: *const TypeInterner) usize {
        return self.nodes.items.len;
    }

    pub fn clone(self: *const TypeInterner, allocator: std.mem.Allocator) InternError!TypeInterner {
        var copy = TypeInterner.init(allocator);
        errdefer copy.deinit();
        for (self.nodes.items, 0..) |node, index| {
            const copied_id = try copy.intern(node);
            if (@backingInt(copied_id) != index) return error.InvalidTypeId;
        }
        return copy;
    }

    fn validateChildren(self: *const TypeInterner, ty: Type) LookupError!void {
        switch (ty) {
            .optional, .dense_array, .sparse_array, .owned => |child| _ = try self.get(child),
            .ref_ => |ref_type| _ = try self.get(ref_type.target),
            .nominal => |nominal| {
                if (nominal.underlying) |underlying| _ = try self.get(underlying);
            },
            .array => |array| _ = try self.get(array.item),
            .slice => |slice| _ = try self.get(slice.item),
            .result => |result| {
                _ = try self.get(result.ok);
                _ = try self.get(result.err);
            },
            .error_union => |members| {
                for (members) |member| _ = try self.get(member);
            },
            .tuple => |members| {
                for (members) |member| _ = try self.get(member);
            },
            .raw => |raw| _ = try self.get(raw.target),
            .callable => |callable| {
                for (callable.params) |param| _ = try self.get(param);
                _ = try self.get(callable.return_type);
            },
            .generic_instance => |instance| {
                for (instance.args) |arg| switch (arg) {
                    .type => |type_id| _ = try self.get(type_id),
                    .const_usize => {},
                };
            },
            else => {},
        }
    }

    fn cloneType(self: *TypeInterner, ty: Type) error{OutOfMemory}!Type {
        return switch (ty) {
            .callable => |callable| .{ .callable = .{
                .kind = callable.kind,
                .calling_convention = callable.calling_convention,
                .params = try self.allocator.dupe(TypeId, callable.params),
                .return_type = callable.return_type,
            } },
            .generic_instance => |instance| .{ .generic_instance = .{
                .kind = instance.kind,
                .base_decl_id = instance.base_decl_id,
                .decl_id = instance.decl_id,
                .args = try self.allocator.dupe(GenericArgument, instance.args),
            } },
            .error_union => |members| .{ .error_union = try self.allocator.dupe(TypeId, members) },
            .tuple => |members| .{ .tuple = try self.allocator.dupe(TypeId, members) },
            else => ty,
        };
    }

    fn deinitType(self: *TypeInterner, ty: Type) void {
        switch (ty) {
            .callable => |callable| self.allocator.free(callable.params),
            .generic_instance => |instance| self.allocator.free(instance.args),
            .error_union => |members| self.allocator.free(members),
            .tuple => |members| self.allocator.free(members),
            else => {},
        }
    }
};

test "canonical leaf interner reuses structural identities" {
    var interner = TypeInterner.init(std.testing.allocator);
    defer interner.deinit();

    const bool_a = try interner.intern(.{ .primitive = .bool });
    const bool_b = try interner.intern(.{ .primitive = .bool });
    const i32_a = try interner.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const i32_b = try interner.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const unsigned_32 = try interner.intern(.{ .integer = .{ .bits = 32, .signed = false } });

    try std.testing.expectEqual(bool_a, bool_b);
    try std.testing.expectEqual(i32_a, i32_b);
    try std.testing.expect(i32_a != unsigned_32);
    try std.testing.expectEqual(@as(usize, 3), interner.count());
}

test "numeric identity preserves language and ABI domains" {
    var interner = TypeInterner.init(std.testing.allocator);
    defer interner.deinit();

    const fixed_i64 = try interner.intern(.{ .integer = .{ .bits = 64, .signed = true } });
    const pointer_signed = try interner.intern(.{ .integer = .{ .bits = 64, .signed = true, .domain = .isize } });
    const c_long_type = try interner.intern(.{ .integer = .{ .bits = 64, .signed = true, .domain = .c_long } });
    const fixed_f32 = try interner.intern(.{ .float = .{ .bits = 32 } });
    const c_float = try interner.intern(.{ .float = .{ .bits = 32, .domain = .c_float } });

    try std.testing.expect(fixed_i64 != pointer_signed);
    try std.testing.expect(fixed_i64 != c_long_type);
    try std.testing.expect(pointer_signed != c_long_type);
    try std.testing.expect(fixed_f32 != c_float);
}

test "canonical type table clone preserves IDs and owns dynamic nodes" {
    var interner = TypeInterner.init(std.testing.allocator);
    defer interner.deinit();

    const int_id = try interner.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const callable_id = try interner.intern(.{ .callable = .{
        .kind = .function,
        .calling_convention = .cyna,
        .params = &.{int_id},
        .return_type = int_id,
    } });

    var copy = try interner.clone(std.testing.allocator);
    defer copy.deinit();

    try std.testing.expectEqual(interner.count(), copy.count());
    try std.testing.expectEqual((try interner.get(int_id)).*, (try copy.get(int_id)).*);
    const copied_callable = (try copy.get(callable_id)).callable;
    try std.testing.expectEqualSlices(TypeId, &.{int_id}, copied_callable.params);
    try std.testing.expectEqual(int_id, copied_callable.return_type);
    try std.testing.expect(copied_callable.params.ptr != (try interner.get(callable_id)).callable.params.ptr);
}

test "nominal identity is declaration based" {
    var interner = TypeInterner.init(std.testing.allocator);
    defer interner.deinit();

    const left_decl: identity.DeclId = @fromBackingInt(@intCast(7));
    const right_decl: identity.DeclId = @fromBackingInt(@intCast(8));
    const left_a = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = left_decl } });
    const left_b = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = left_decl } });
    const right = try interner.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = right_decl } });

    try std.testing.expectEqual(left_a, left_b);
    try std.testing.expect(left_a != right);
}

test "generic instances use base declaration and structural arguments" {
    var interner = TypeInterner.init(std.testing.allocator);
    defer interner.deinit();

    const inferred_int = try interner.intern(.inferred_integer);
    const concrete_int = try interner.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const base_decl: identity.DeclId = @fromBackingInt(@intCast(20));
    var args = [_]GenericArgument{
        .{ .type = concrete_int },
        .{ .const_usize = 4 },
    };
    const first = try interner.intern(.{ .generic_instance = .{
        .kind = .@"struct",
        .base_decl_id = base_decl,
        .args = &args,
    } });
    args[0] = .{ .type = inferred_int };
    const changed_type = try interner.intern(.{ .generic_instance = .{
        .kind = .@"struct",
        .base_decl_id = base_decl,
        .args = &args,
    } });
    args[0] = .{ .type = concrete_int };
    const repeated = try interner.intern(.{ .generic_instance = .{
        .kind = .@"struct",
        .base_decl_id = base_decl,
        .args = &args,
    } });
    const changed_value = try interner.intern(.{ .generic_instance = .{
        .kind = .@"struct",
        .base_decl_id = base_decl,
        .args = &.{
            .{ .type = concrete_int },
            .{ .const_usize = 5 },
        },
    } });

    try std.testing.expectEqual(first, repeated);
    try std.testing.expect(first != changed_type);
    try std.testing.expect(first != changed_value);
}

test "invalid canonical type IDs fail explicitly" {
    var interner = TypeInterner.init(std.testing.allocator);
    defer interner.deinit();

    _ = try interner.intern(.{ .primitive = .void });
    const invalid: TypeId = @fromBackingInt(@intCast(99));
    try std.testing.expectError(error.InvalidTypeId, interner.get(invalid));
}

test "tuple types intern by ordered element identity" {
    var interner = TypeInterner.init(std.testing.allocator);
    defer interner.deinit();

    const integer = try interner.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const boolean = try interner.intern(.{ .primitive = .bool });
    const first = try interner.intern(.{ .tuple = &.{ integer, boolean } });
    const same = try interner.intern(.{ .tuple = &.{ integer, boolean } });
    const reversed = try interner.intern(.{ .tuple = &.{ boolean, integer } });
    const shorter = try interner.intern(.{ .tuple = &.{integer} });
    const empty = try interner.intern(.{ .tuple = &.{} });
    try std.testing.expectEqual(first, same);
    try std.testing.expect(first != reversed);
    try std.testing.expect(first != shorter);
    try std.testing.expect(empty != try interner.intern(.{ .primitive = .void }));

    var copy = try interner.clone(std.testing.allocator);
    defer copy.deinit();
    try std.testing.expectEqual(first, try copy.intern(.{ .tuple = &.{ integer, boolean } }));
    const invalid: TypeId = @fromBackingInt(@intCast(100));
    try std.testing.expectError(error.InvalidTypeId, interner.intern(.{ .tuple = &.{invalid} }));
}

test "recursive wrappers and collections intern structurally" {
    var interner = TypeInterner.init(std.testing.allocator);
    defer interner.deinit();

    const item = try interner.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const optional_a = try interner.intern(.{ .optional = item });
    const optional_b = try interner.intern(.{ .optional = item });
    const array_a = try interner.intern(.{ .array = .{ .len = 4, .item = optional_a } });
    const array_b = try interner.intern(.{ .array = .{ .len = 4, .item = optional_b } });
    const different_len = try interner.intern(.{ .array = .{ .len = 5, .item = optional_a } });
    const dense_a = try interner.intern(.{ .dense_array = item });
    const dense_b = try interner.intern(.{ .dense_array = item });
    const sparse = try interner.intern(.{ .sparse_array = item });
    const mutable_slice = try interner.intern(.{ .slice = .{ .item = item, .is_const = false } });
    const const_slice = try interner.intern(.{ .slice = .{ .item = item, .is_const = true } });
    const reference_a = try interner.intern(.{ .ref_ = .{ .target = array_a, .is_const = false } });
    const reference_b = try interner.intern(.{ .ref_ = .{ .target = array_b, .is_const = false } });
    const owned = try interner.intern(.{ .owned = array_a });
    const raw = try interner.intern(.{ .raw = .{ .target = array_a, .is_volatile = false } });
    const volatile_raw = try interner.intern(.{ .raw = .{ .target = array_a, .is_volatile = true } });

    try std.testing.expectEqual(optional_a, optional_b);
    try std.testing.expectEqual(array_a, array_b);
    try std.testing.expectEqual(dense_a, dense_b);
    try std.testing.expect(dense_a != sparse);
    try std.testing.expect(array_a != different_len);
    try std.testing.expect(mutable_slice != const_slice);
    try std.testing.expectEqual(reference_a, reference_b);
    try std.testing.expect(reference_a != owned);
    try std.testing.expect(raw != volatile_raw);
}

test "results and callable signatures use canonical child IDs" {
    var interner = TypeInterner.init(std.testing.allocator);
    defer interner.deinit();

    const void_type = try interner.intern(.{ .primitive = .void });
    const bool_type = try interner.intern(.{ .primitive = .bool });
    const error_decl: identity.DeclId = @fromBackingInt(@intCast(15));
    const error_type = try interner.intern(.{ .nominal = .{ .kind = .@"enum", .decl_id = error_decl } });
    const result_a = try interner.intern(.{ .result = .{ .ok = bool_type, .err = error_type } });
    const result_b = try interner.intern(.{ .result = .{ .ok = bool_type, .err = error_type } });

    var params = [_]TypeId{bool_type};
    const function_a = try interner.intern(.{ .callable = .{
        .kind = .function,
        .calling_convention = .cyna,
        .params = &params,
        .return_type = result_a,
    } });
    const function_b = try interner.intern(.{ .callable = .{
        .kind = .function,
        .calling_convention = .cyna,
        .params = &.{bool_type},
        .return_type = result_b,
    } });
    const c_function = try interner.intern(.{ .callable = .{
        .kind = .function,
        .calling_convention = .c,
        .params = &.{bool_type},
        .return_type = result_a,
    } });
    const arrow = try interner.intern(.{ .callable = .{
        .kind = .arrow,
        .calling_convention = .cyna,
        .params = &.{bool_type},
        .return_type = result_a,
    } });

    params[0] = void_type;
    const stored = (try interner.get(function_a)).callable;
    try std.testing.expectEqual(result_a, result_b);
    try std.testing.expectEqual(function_a, function_b);
    try std.testing.expect(function_a != c_function);
    try std.testing.expect(function_a != arrow);
    try std.testing.expectEqual(bool_type, stored.params[0]);
}

test "C ABI void marker has distinct canonical identity" {
    var interner = TypeInterner.init(std.testing.allocator);
    defer interner.deinit();

    const language_void = try interner.intern(.{ .primitive = .void });
    const c_void = try interner.intern(.{ .primitive = .c_void });

    try std.testing.expect(language_void != c_void);
    try std.testing.expectEqual(c_void, try interner.intern(.{ .primitive = .c_void }));
}

test "recursive nodes reject invalid child IDs" {
    var interner = TypeInterner.init(std.testing.allocator);
    defer interner.deinit();

    const invalid: TypeId = @fromBackingInt(@intCast(42));
    try std.testing.expectError(error.InvalidTypeId, interner.intern(.{ .optional = invalid }));
    try std.testing.expectError(error.InvalidTypeId, interner.intern(.{ .generic_instance = .{
        .kind = .@"struct",
        .base_decl_id = @fromBackingInt(@intCast(9)),
        .args = &.{.{ .type = invalid }},
    } }));
    try std.testing.expectEqual(@as(usize, 0), interner.count());
}

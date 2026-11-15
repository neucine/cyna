const std = @import("std");
const target_info = @import("../target.zig");
const identity = @import("identity.zig");
const semantic_types = @import("types.zig");
const session = @import("session.zig");
const diagnostics = @import("../diagnostics.zig");
const lexer = @import("../lexer/lexer.zig");
const ast = @import("../parser/ast.zig");
const declarations = @import("declarations.zig");
const generics = @import("generics.zig");
const language_contracts = @import("../language_contracts.zig");
const protocols = @import("protocols.zig");
const sir = @import("sir.zig");
const intrinsics = @import("../intrinsics.zig");

pub const Error = error{ SemanticFailed, OutOfMemory };

pub const Context = struct {
    allocator: std.mem.Allocator,
    abi_layout: target_info.AbiLayout,
    interner: ?*semantic_types.TypeInterner,
    generated_strings: *std.ArrayListUnmanaged([]const u8),
};

/// Session-level canonical type access. Owners build this namespace from their
/// own `SemaContext` type, so canonical interning and access stay inside this
/// module instead of being forwarded through the semantic entry module.
pub fn Canonical(comptime SemaContext: type) type {
    return struct {
        pub fn interContext(context: *SemaContext) Context {
            return .{
                .allocator = context.allocator,
                .abi_layout = context.abi_layout,
                .interner = if (context.canonical.types) |*types| types else null,
                .generated_strings = &context.output.generated_strings,
            };
        }
        pub fn internCallableType(
            context: *SemaContext,
            kind: semantic_types.CallableKind,
            calling_convention: semantic_types.CallingConvention,
            params: []const semantic_types.TypeId,
            return_type: semantic_types.TypeId,
        ) Error!semantic_types.TypeId {
            return callable(interContext(context), kind, calling_convention, params, return_type);
        }

        pub fn interner(context: *SemaContext) *semantic_types.TypeInterner {
            return if (context.canonical.types) |*types| types else unreachable;
        }

        pub fn typeNode(context: *SemaContext, type_id: semantic_types.TypeId) *const semantic_types.Type {
            return node(interContext(context), type_id);
        }

        pub fn typeVisited(visited: []const semantic_types.TypeId, type_id: semantic_types.TypeId) bool {
            for (visited) |entry| {
                if (entry == type_id) return true;
            }
            return false;
        }

        pub fn intBitWidth(context: *SemaContext, name: []const u8) ?u16 {
            return namedIntBitWidth(context.abi_layout, name);
        }

        pub fn floatBitWidth(name: []const u8) ?u16 {
            return namedFloatBitWidth(name);
        }

        pub fn primitiveType(context: *SemaContext, value: semantic_types.Primitive) Error!semantic_types.TypeId {
            return primitive(interContext(context), value);
        }

        pub fn inferredIntegerType(context: *SemaContext) Error!semantic_types.TypeId {
            return inferredInteger(interContext(context));
        }

        pub fn integerType(context: *SemaContext, name: ?[]const u8) Error!semantic_types.TypeId {
            return integer(interContext(context), name);
        }

        pub fn floatType(context: *SemaContext, name: ?[]const u8) Error!semantic_types.TypeId {
            return float(interContext(context), name);
        }

        pub fn integerLiteralType(context: *SemaContext, type_id: semantic_types.TypeId) Error!?[]const u8 {
            return integerLiteralTypeName(interContext(context), type_id);
        }

        pub fn floatLiteralType(context: *SemaContext, type_id: semantic_types.TypeId) ?[]const u8 {
            return floatLiteralTypeName(interContext(context), type_id);
        }

        pub fn optionalType(context: *SemaContext, payload: semantic_types.TypeId) Error!semantic_types.TypeId {
            return optional(interContext(context), payload);
        }

        pub fn resultType(context: *SemaContext, ok: semantic_types.TypeId, err: semantic_types.TypeId) Error!semantic_types.TypeId {
            return result(interContext(context), ok, err);
        }

        pub fn errorUnionType(context: *SemaContext, members: []const semantic_types.TypeId) Error!semantic_types.TypeId {
            return errorUnion(interContext(context), members);
        }

        pub fn sliceType(context: *SemaContext, item: semantic_types.TypeId, is_const: bool) Error!semantic_types.TypeId {
            return slice(interContext(context), item, is_const);
        }

        pub fn refType(context: *SemaContext, target: semantic_types.TypeId) Error!semantic_types.TypeId {
            return ref(interContext(context), target, false);
        }

        pub fn constRefType(context: *SemaContext, target: semantic_types.TypeId) Error!semantic_types.TypeId {
            return ref(interContext(context), target, true);
        }

        pub fn ownedType(context: *SemaContext, target: semantic_types.TypeId) Error!semantic_types.TypeId {
            return owned(interContext(context), target);
        }

        pub fn qualifiedRawType(context: *SemaContext, target: semantic_types.TypeId, is_const: bool, is_volatile: bool) Error!semantic_types.TypeId {
            return raw(interContext(context), target, is_const, is_volatile);
        }

        pub fn rawType(context: *SemaContext, target: semantic_types.TypeId, is_volatile: bool) Error!semantic_types.TypeId {
            return raw(interContext(context), target, false, is_volatile);
        }

        pub fn denseArrayType(context: *SemaContext, item: semantic_types.TypeId) Error!semantic_types.TypeId {
            return denseArray(interContext(context), item);
        }

        pub fn arrayType(context: *SemaContext, len: usize, item: semantic_types.TypeId) Error!semantic_types.TypeId {
            return array(interContext(context), len, item);
        }

        pub fn sparseArrayType(context: *SemaContext, item: semantic_types.TypeId) Error!semantic_types.TypeId {
            return sparseArray(interContext(context), item);
        }

        pub fn nominalType(context: *SemaContext, kind: semantic_types.NominalKind, decl_id: identity.DeclId, underlying: ?semantic_types.TypeId) Error!semantic_types.TypeId {
            return nominalForSession(SemaContext, context, kind, decl_id, underlying);
        }

        pub fn unwrapOwnedType(context: *SemaContext, type_id: semantic_types.TypeId) semantic_types.TypeId {
            return unwrapOwned(interContext(context), type_id);
        }

        pub fn sliceIsConstant(context: *SemaContext, type_id: semantic_types.TypeId) bool {
            return sliceIsConst(interContext(context), type_id);
        }

        pub fn sirType(context: *SemaContext, type_id: semantic_types.TypeId) sir.Type {
            return typeKind(interContext(context), type_id);
        }

        pub fn refTargetType(context: *SemaContext, type_id: semantic_types.TypeId) semantic_types.TypeId {
            return refTarget(interContext(context), type_id);
        }

        pub fn refIsConstant(context: *SemaContext, type_id: semantic_types.TypeId) bool {
            return refIsConst(interContext(context), type_id);
        }

        pub fn ownedTargetType(context: *SemaContext, type_id: semantic_types.TypeId) semantic_types.TypeId {
            return ownedTarget(interContext(context), type_id);
        }

        pub fn nominalDecl(context: *SemaContext, type_id: semantic_types.TypeId) ?identity.DeclId {
            return nominalDeclId(interContext(context), type_id);
        }

        pub fn voidLike(context: *SemaContext, type_id: semantic_types.TypeId) bool {
            return isVoidLike(interContext(context), type_id);
        }

        pub fn displayContext(context: *SemaContext) DisplayContext {
            return .{
                .types = interContext(context),
                .registry = if (context.declarations.registry) |*registry| registry else null,
            };
        }

        pub fn formatType(context: *SemaContext, type_id: semantic_types.TypeId) Error![]const u8 {
            return formatDisplay(displayContext(context), type_id, .display);
        }

        pub fn formatDiagnosticType(context: *SemaContext, type_id: semantic_types.TypeId) Error![]const u8 {
            return formatDisplay(displayContext(context), type_id, .diagnostic);
        }

        pub fn appendTypeDisplay(context: *SemaContext, buf: *std.ArrayListUnmanaged(u8), type_id: semantic_types.TypeId, mode: DisplayMode) Error!void {
            return appendDisplay(displayContext(context), buf, type_id, mode);
        }

        pub fn functionTypeSignature(
            context: *SemaContext,
            calling_convention: ast.CallingConvention,
            params: []const semantic_types.TypeId,
            return_type: semantic_types.TypeId,
        ) Error![]const u8 {
            return formatFunctionTypeSignature(displayContext(context), calling_convention, params, return_type);
        }

        pub fn arrowCallableTypeSignature(
            context: *SemaContext,
            params: []const semantic_types.TypeId,
            return_type: semantic_types.TypeId,
        ) Error![]const u8 {
            return formatArrowCallableTypeSignature(displayContext(context), params, return_type);
        }

        pub fn expectType(
            context: *SemaContext,
            path: []const u8,
            token: lexer.Token,
            expected: semantic_types.TypeId,
            actual: semantic_types.TypeId,
        ) Error!void {
            return expectTypeFrom(displayContext(context), &context.diagnostic_context, path, token, expected, actual, null);
        }

        pub fn expectTypeWithOrigin(
            context: *SemaContext,
            path: []const u8,
            token: lexer.Token,
            expected: semantic_types.TypeId,
            actual: semantic_types.TypeId,
            origin: ?session.TypeExpectationOrigin,
        ) Error!void {
            return expectTypeFrom(displayContext(context), &context.diagnostic_context, path, token, expected, actual, origin);
        }

        pub fn sourceContext(context: *SemaContext) SourceContext {
            return .{
                .policy = declarations.Lookup(SemaContext).policy(context),
                .registry = if (context.declarations.registry) |*registry| registry else null,
                .diagnostic_context = &context.diagnostic_context,
            };
        }

        pub fn aliasType(context: *const SemaContext, decl_id: identity.DeclId) ?semantic_types.TypeId {
            return aliasTypeId(&context.canonical, decl_id);
        }

        pub fn genericAliasType(
            context: *const SemaContext,
            decl_id: identity.DeclId,
            args: []const semantic_types.GenericArgument,
        ) ?semantic_types.TypeId {
            return genericAliasTypeId(&context.canonical, decl_id, args);
        }

        pub fn resolveDistinctAliasType(context: *SemaContext, alias: ast.TypeAlias, target: semantic_types.TypeId) Error!semantic_types.TypeId {
            return distinctAliasType(SemaContext, context, alias, target);
        }
    };
}

pub fn node(context: Context, type_id: semantic_types.TypeId) *const semantic_types.Type {
    return (context.interner orelse unreachable).get(type_id) catch unreachable;
}

pub fn primitive(context: Context, value: semantic_types.Primitive) Error!semantic_types.TypeId {
    return intern(context, .{ .primitive = value });
}

pub fn inferredInteger(context: Context) Error!semantic_types.TypeId {
    return intern(context, .inferred_integer);
}

pub fn integer(context: Context, name: ?[]const u8) Error!semantic_types.TypeId {
    if (name == null) return inferredInteger(context);
    return intern(context, .{ .integer = .{
        .bits = namedIntBitWidth(context.abi_layout, name.?) orelse return error.SemanticFailed,
        .signed = namedIntIsSigned(context.abi_layout, name.?) orelse return error.SemanticFailed,
        .domain = namedIntDomain(name.?) orelse return error.SemanticFailed,
    } });
}

pub fn float(context: Context, name: ?[]const u8) Error!semantic_types.TypeId {
    if (name == null) return intern(context, .inferred_float);
    const bits = namedFloatBitWidth(name.?) orelse if (std.mem.eql(u8, name.?, "c_float"))
        @as(u16, 32)
    else if (std.mem.eql(u8, name.?, "c_double"))
        @as(u16, 64)
    else
        return error.SemanticFailed;
    return intern(context, .{ .float = .{
        .bits = bits,
        .domain = namedFloatDomain(name.?) orelse return error.SemanticFailed,
    } });
}

pub fn optional(context: Context, payload: semantic_types.TypeId) Error!semantic_types.TypeId {
    return intern(context, .{ .optional = payload });
}

pub fn result(context: Context, ok: semantic_types.TypeId, err: semantic_types.TypeId) Error!semantic_types.TypeId {
    return intern(context, .{ .result = .{ .ok = ok, .err = err } });
}

pub fn errorUnion(context: Context, members: []const semantic_types.TypeId) Error!semantic_types.TypeId {
    if (members.len < 2) return error.SemanticFailed;
    for (members) |member| {
        if (typeKind(context, member) != .@"enum" or nominalDeclId(context, member) == null) return error.SemanticFailed;
    }
    const sorted = try context.allocator.dupe(semantic_types.TypeId, members);
    defer context.allocator.free(sorted);
    // Declaration identities are registered before body checking, so order does
    // not depend on which inline spelling is encountered first.
    std.mem.sort(semantic_types.TypeId, sorted, context, struct {
        fn lessThan(ctx: Context, a: semantic_types.TypeId, b: semantic_types.TypeId) bool {
            return @backingInt(nominalDeclId(ctx, a).?) < @backingInt(nominalDeclId(ctx, b).?);
        }
    }.lessThan);
    for (sorted[1..], 1..) |member, index| {
        if (nominalDeclId(context, member) == nominalDeclId(context, sorted[index - 1])) return error.SemanticFailed;
    }
    return intern(context, .{ .error_union = sorted });
}

pub fn slice(context: Context, item: semantic_types.TypeId, is_const: bool) Error!semantic_types.TypeId {
    return intern(context, .{ .slice = .{ .item = item, .is_const = is_const } });
}

pub fn ref(context: Context, target: semantic_types.TypeId, is_const: bool) Error!semantic_types.TypeId {
    return intern(context, .{ .ref_ = .{ .target = target, .is_const = is_const } });
}

pub fn owned(context: Context, target: semantic_types.TypeId) Error!semantic_types.TypeId {
    return intern(context, .{ .owned = target });
}

pub fn raw(context: Context, target: semantic_types.TypeId, is_const: bool, is_volatile: bool) Error!semantic_types.TypeId {
    return intern(context, .{ .raw = .{ .target = target, .is_const = is_const, .is_volatile = is_volatile } });
}

pub fn denseArray(context: Context, item: semantic_types.TypeId) Error!semantic_types.TypeId {
    return intern(context, .{ .dense_array = item });
}

pub fn array(context: Context, len: usize, item: semantic_types.TypeId) Error!semantic_types.TypeId {
    return intern(context, .{ .array = .{ .len = len, .item = item } });
}

pub fn sparseArray(context: Context, item: semantic_types.TypeId) Error!semantic_types.TypeId {
    return intern(context, .{ .sparse_array = item });
}

pub fn nominal(
    context: Context,
    kind: semantic_types.NominalKind,
    decl_id: identity.DeclId,
    underlying: ?semantic_types.TypeId,
) Error!semantic_types.TypeId {
    return intern(context, .{ .nominal = .{
        .kind = kind,
        .decl_id = decl_id,
        .underlying = underlying,
    } });
}

pub fn genericStructInstance(
    context: Context,
    base_decl_id: identity.DeclId,
    decl_id: identity.DeclId,
    args: []const semantic_types.GenericArgument,
) Error!semantic_types.TypeId {
    return intern(context, .{ .generic_instance = .{
        .kind = .@"struct",
        .base_decl_id = base_decl_id,
        .decl_id = decl_id,
        .args = args,
    } });
}

pub fn callable(
    context: Context,
    kind: semantic_types.CallableKind,
    calling_convention: semantic_types.CallingConvention,
    params: []const semantic_types.TypeId,
    return_type: semantic_types.TypeId,
) Error!semantic_types.TypeId {
    return intern(context, .{ .callable = .{
        .kind = kind,
        .calling_convention = calling_convention,
        .params = params,
        .return_type = return_type,
    } });
}

pub fn integerDisplayName(context: Context, value: semantic_types.Integer) Error![]const u8 {
    return switch (value.domain) {
        .fixed => blk: {
            const name = try std.fmt.allocPrint(
                context.allocator,
                "{c}{d}",
                .{ if (value.signed) @as(u8, 'i') else @as(u8, 'u'), value.bits },
            );
            errdefer context.allocator.free(name);
            try context.generated_strings.append(context.allocator, name);
            break :blk name;
        },
        .isize => "isize",
        .usize => "usize",
        .c_char => "c_char",
        .c_schar => "c_schar",
        .c_uchar => "c_uchar",
        .c_short => "c_short",
        .c_ushort => "c_ushort",
        .c_int => "c_int",
        .c_uint => "c_uint",
        .c_long => "c_long",
        .c_ulong => "c_ulong",
        .c_llong => "c_llong",
        .c_ullong => "c_ullong",
        .c_ptrdiff_t => "c_ptrdiff_t",
        .c_size_t => "c_size_t",
    };
}

pub fn intern(context: Context, value: semantic_types.Type) Error!semantic_types.TypeId {
    const interner = context.interner orelse return error.SemanticFailed;
    return internNode(interner, value);
}

pub fn internNode(interner: *semantic_types.TypeInterner, value: semantic_types.Type) Error!semantic_types.TypeId {
    return interner.intern(value) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidTypeId => error.SemanticFailed,
    };
}

fn namedIntBitWidth(layout: target_info.AbiLayout, name: []const u8) ?u16 {
    if (std.mem.eql(u8, name, "isize") or
        std.mem.eql(u8, name, "usize") or
        std.mem.eql(u8, name, "c_size_t") or
        std.mem.eql(u8, name, "c_ptrdiff_t"))
    {
        return layout.ptr_bits;
    }
    if (std.mem.eql(u8, name, "c_char")) return layout.char_bits;
    if (std.mem.eql(u8, name, "c_schar") or std.mem.eql(u8, name, "c_uchar")) return 8;
    if (std.mem.eql(u8, name, "c_short") or std.mem.eql(u8, name, "c_ushort")) return layout.short_bits;
    if (std.mem.eql(u8, name, "c_int") or std.mem.eql(u8, name, "c_uint")) return layout.int_bits;
    if (std.mem.eql(u8, name, "c_long") or std.mem.eql(u8, name, "c_ulong")) return layout.long_bits;
    if (std.mem.eql(u8, name, "c_llong") or std.mem.eql(u8, name, "c_ullong")) return layout.longlong_bits;
    if (name.len < 2 or (name[0] != 'i' and name[0] != 'u')) return null;
    return std.fmt.parseInt(u16, name[1..], 10) catch null;
}

fn namedIntIsSigned(layout: target_info.AbiLayout, name: []const u8) ?bool {
    if (std.mem.eql(u8, name, "isize") or std.mem.eql(u8, name, "c_ptrdiff_t")) return true;
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "c_size_t")) return false;
    if (std.mem.eql(u8, name, "c_char")) return layout.char_signed;
    if (std.mem.eql(u8, name, "c_schar") or
        std.mem.eql(u8, name, "c_short") or
        std.mem.eql(u8, name, "c_int") or
        std.mem.eql(u8, name, "c_long") or
        std.mem.eql(u8, name, "c_llong")) return true;
    if (std.mem.eql(u8, name, "c_uchar") or
        std.mem.eql(u8, name, "c_ushort") or
        std.mem.eql(u8, name, "c_uint") or
        std.mem.eql(u8, name, "c_ulong") or
        std.mem.eql(u8, name, "c_ullong")) return false;
    if (name.len < 2) return null;
    return switch (name[0]) {
        'i' => true,
        'u' => false,
        else => null,
    };
}

fn namedIntDomain(name: []const u8) ?semantic_types.IntegerDomain {
    if (isFixedWidthIntegerName(name)) return .fixed;
    inline for (.{
        .{ "isize", semantic_types.IntegerDomain.isize },
        .{ "usize", semantic_types.IntegerDomain.usize },
        .{ "c_char", semantic_types.IntegerDomain.c_char },
        .{ "c_schar", semantic_types.IntegerDomain.c_schar },
        .{ "c_uchar", semantic_types.IntegerDomain.c_uchar },
        .{ "c_short", semantic_types.IntegerDomain.c_short },
        .{ "c_ushort", semantic_types.IntegerDomain.c_ushort },
        .{ "c_int", semantic_types.IntegerDomain.c_int },
        .{ "c_uint", semantic_types.IntegerDomain.c_uint },
        .{ "c_long", semantic_types.IntegerDomain.c_long },
        .{ "c_ulong", semantic_types.IntegerDomain.c_ulong },
        .{ "c_llong", semantic_types.IntegerDomain.c_llong },
        .{ "c_ullong", semantic_types.IntegerDomain.c_ullong },
        .{ "c_ptrdiff_t", semantic_types.IntegerDomain.c_ptrdiff_t },
        .{ "c_size_t", semantic_types.IntegerDomain.c_size_t },
    }) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

fn namedFloatBitWidth(name: []const u8) ?u16 {
    if (std.mem.eql(u8, name, "f32")) return 32;
    if (std.mem.eql(u8, name, "f64")) return 64;
    return null;
}

fn namedFloatDomain(name: []const u8) ?semantic_types.FloatDomain {
    if (std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64")) return .fixed;
    if (std.mem.eql(u8, name, "c_float")) return .c_float;
    if (std.mem.eql(u8, name, "c_double")) return .c_double;
    return null;
}

pub fn isFixedWidthIntegerName(name: []const u8) bool {
    if (name.len < 2 or (name[0] != 'i' and name[0] != 'u') or name[1] == '0') return false;
    const width = std.fmt.parseInt(u8, name[1..], 10) catch return false;
    return width >= 1 and width <= 64;
}

pub fn isBuiltinTypeName(name: []const u8) bool {
    for ([_][]const u8{ "void", "c_void", "c_str", "bool", "char", "string", "isize", "usize", "f32", "f64" }) |builtin| {
        if (std.mem.eql(u8, name, builtin)) return true;
    }
    return isFixedWidthIntegerName(name) or isCAbiScalarTypeName(name);
}

// Compatibility and expectation decisions share the canonical interner with construction.

/// Assignment compatibility for already interned semantic_types. This reads canonical
/// nodes; it does not intern a type or report a diagnostic.
pub fn compatible(interner: *const semantic_types.TypeInterner, expected: semantic_types.TypeId, actual: semantic_types.TypeId) bool {
    if (expected == actual) return true;
    const expected_node = (interner.get(expected) catch unreachable).*;
    const actual_node = (interner.get(actual) catch unreachable).*;
    if (expected_node == .ref_ and actual_node == .ref_) {
        return expected_node.ref_.target == actual_node.ref_.target and
            (expected_node.ref_.is_const or !actual_node.ref_.is_const);
    }
    if (expected_node == .raw and actual_node == .raw) {
        return expected_node.raw.target == actual_node.raw.target and
            expected_node.raw.is_volatile == actual_node.raw.is_volatile and
            (expected_node.raw.is_const or !actual_node.raw.is_const);
    }
    if (callableSignaturesEqual(expected_node, actual_node)) {
        return expected_node.callable.kind == .arrow and actual_node.callable.kind == .function;
    }
    if (sliceTypesCompatible(expected_node, actual_node)) return true;
    if (intTypesCompatible(expected_node, actual_node)) return true;
    if (floatTypesCompatible(expected_node, actual_node)) return true;
    if (expected_node == .optional) {
        const payload_node = (interner.get(expected_node.optional) catch unreachable).*;
        return expected_node.optional == actual or
            intTypesCompatible(payload_node, actual_node) or
            floatTypesCompatible(payload_node, actual_node);
    }
    return false;
}

/// Definition-site binders have no concrete representation until substitution.
pub fn containsDefinitionSiteBinder(interner: *const semantic_types.TypeInterner, type_id: semantic_types.TypeId) bool {
    const type_node = (interner.get(type_id) catch unreachable).*;
    switch (type_node) {
        .generic_parameter => return true,
        .optional => |item| return containsDefinitionSiteBinder(interner, item),
        .array => |array_value| return containsDefinitionSiteBinder(interner, array_value.item),
        .dense_array => |item| return containsDefinitionSiteBinder(interner, item),
        .sparse_array => |item| return containsDefinitionSiteBinder(interner, item),
        .slice => |slice_value| return containsDefinitionSiteBinder(interner, slice_value.item),
        .result => |result_value| return containsDefinitionSiteBinder(interner, result_value.ok) or containsDefinitionSiteBinder(interner, result_value.err),
        .ref_ => |ref_| return containsDefinitionSiteBinder(interner, ref_.target),
        .owned => |item| return containsDefinitionSiteBinder(interner, item),
        .raw => |raw_value| return containsDefinitionSiteBinder(interner, raw_value.target),
        .generic_instance => |instance| {
            for (instance.args) |arg| {
                switch (arg) {
                    .type => |item| if (containsDefinitionSiteBinder(interner, item)) return true,
                    else => {},
                }
            }
            return false;
        },
        .callable => |callable_value| {
            for (callable_value.params) |param| if (containsDefinitionSiteBinder(interner, param)) return true;
            return containsDefinitionSiteBinder(interner, callable_value.return_type);
        },
        else => return false,
    }
}

/// A mismatch that specifically asks a read-only source to satisfy a writable
/// reference, slice, or raw pointer expectation.
pub fn losesWritableAccess(interner: *const semantic_types.TypeInterner, expected: semantic_types.TypeId, actual: semantic_types.TypeId) bool {
    const expected_node = (interner.get(expected) catch unreachable).*;
    const actual_node = (interner.get(actual) catch unreachable).*;
    return (expected_node == .ref_ and actual_node == .ref_ and
        expected_node.ref_.target == actual_node.ref_.target and
        !expected_node.ref_.is_const and actual_node.ref_.is_const) or
        (expected_node == .slice and actual_node == .slice and
            expected_node.slice.item == actual_node.slice.item and
            !expected_node.slice.is_const and actual_node.slice.is_const) or
        (expected_node == .raw and actual_node == .raw and
            expected_node.raw.target == actual_node.raw.target and
            expected_node.raw.is_volatile == actual_node.raw.is_volatile and
            !expected_node.raw.is_const and actual_node.raw.is_const);
}

pub fn callableSignaturesEqual(expected: semantic_types.Type, actual: semantic_types.Type) bool {
    if (expected != .callable or actual != .callable) return false;
    return expected.callable.return_type == actual.callable.return_type and
        std.mem.eql(semantic_types.TypeId, expected.callable.params, actual.callable.params);
}

fn sliceTypesCompatible(expected: semantic_types.Type, actual: semantic_types.Type) bool {
    if (expected != .slice or actual != .slice) return false;
    return expected.slice.item == actual.slice.item and (expected.slice.is_const or !actual.slice.is_const);
}

pub fn intTypesCompatible(expected: semantic_types.Type, actual: semantic_types.Type) bool {
    if (expected == .inferred_integer) return actual == .inferred_integer or actual == .integer;
    if (actual == .inferred_integer) return expected == .integer;
    return false;
}

fn floatTypesCompatible(expected: semantic_types.Type, actual: semantic_types.Type) bool {
    if (expected == .inferred_float) {
        return actual == .inferred_float or
            (actual == .float and actual.float.domain == .fixed);
    }
    if (actual == .inferred_float) {
        return expected == .float and expected.float.domain == .fixed;
    }
    return false;
}

test "compatibility permits access narrowing but rejects widening" {
    var interner = semantic_types.TypeInterner.init(std.testing.allocator);
    defer interner.deinit();
    const item = try interner.intern(.inferred_integer);
    const writable = try interner.intern(.{ .ref_ = .{ .target = item, .is_const = false } });
    const readonly = try interner.intern(.{ .ref_ = .{ .target = item, .is_const = true } });
    try std.testing.expect(compatible(&interner, readonly, writable));
    try std.testing.expect(!compatible(&interner, writable, readonly));
    try std.testing.expect(losesWritableAccess(&interner, writable, readonly));
    try std.testing.expect(!losesWritableAccess(&interner, readonly, writable));
}

test "definition-site binder detection follows nested type arguments" {
    var interner = semantic_types.TypeInterner.init(std.testing.allocator);
    defer interner.deinit();
    const concrete = try interner.intern(.inferred_integer);
    const binder = try interner.intern(.{ .generic_parameter = .{
        .scope = @fromBackingInt(@intCast(1)),
        .ordinal = 0,
        .name = "T",
    } });
    const nested = try interner.intern(.{ .result = .{
        .ok = concrete,
        .err = try interner.intern(.{ .optional = binder }),
    } });
    try std.testing.expect(!containsDefinitionSiteBinder(&interner, concrete));
    try std.testing.expect(containsDefinitionSiteBinder(&interner, nested));
}

/// Definition-site binders are checked after specialization.
pub fn acceptsExpectation(interner: *const semantic_types.TypeInterner, expected: semantic_types.TypeId, actual: semantic_types.TypeId) bool {
    if (compatible(interner, expected, actual)) return true;
    const expected_node = (interner.get(expected) catch unreachable).*;
    const actual_node = (interner.get(actual) catch unreachable).*;
    if (expected_node == .generic_parameter and actual_node == .generic_parameter) return true;
    return containsDefinitionSiteBinder(interner, expected) and containsDefinitionSiteBinder(interner, actual);
}

pub fn integerLiteralTypeName(context: Context, type_id: semantic_types.TypeId) Error!?[]const u8 {
    return switch (node(context, type_id).*) {
        .integer => |value| try integerDisplayName(context, value),
        else => null,
    };
}

pub fn floatLiteralTypeName(context: Context, type_id: semantic_types.TypeId) ?[]const u8 {
    return switch (node(context, type_id).*) {
        .float => |value| switch (value.domain) {
            .fixed => if (value.bits == 32) "f32" else "f64",
            .c_float => "c_float",
            .c_double => "c_double",
        },
        else => null,
    };
}

pub const DisplayMode = enum { key, display, diagnostic };

pub const DisplayContext = struct {
    types: Context,
    registry: ?*const identity.Registry,
};

pub fn formatDisplay(context: DisplayContext, type_id: semantic_types.TypeId, mode: DisplayMode) Error![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(context.types.allocator);
    try appendDisplay(context, &buf, type_id, mode);
    return buf.toOwnedSlice(context.types.allocator);
}

fn appendNominalName(
    context: DisplayContext,
    buf: *std.ArrayListUnmanaged(u8),
    decl_id: identity.DeclId,
    mode: DisplayMode,
) Error!void {
    const registry = context.registry orelse return error.SemanticFailed;
    const decl = registry.decl(decl_id) orelse return error.SemanticFailed;
    const module = registry.module(decl.module) orelse return error.SemanticFailed;
    if (mode != .display and module.name.len != 0) {
        try buf.appendSlice(context.types.allocator, module.name);
        try buf.append(context.types.allocator, '.');
    }
    try buf.appendSlice(context.types.allocator, decl.name);
}

pub fn appendDisplay(
    context: DisplayContext,
    buf: *std.ArrayListUnmanaged(u8),
    type_id: semantic_types.TypeId,
    mode: DisplayMode,
) Error!void {
    const allocator = context.types.allocator;
    switch (node(context.types, type_id).*) {
        .primitive => |primitive_value| try buf.appendSlice(allocator, switch (primitive_value) {
            .void => "void",
            .c_void => "c_void",
            .bool => "bool",
            .rune => "char",
            .string => "string",
            .c_str => "c_str",
        }),
        .inferred_integer => try buf.appendSlice(allocator, "int"),
        .inferred_float => try buf.appendSlice(allocator, "float"),
        .integer => |integer_value| try buf.appendSlice(allocator, try integerDisplayName(context.types, integer_value)),
        .float => |float_value| try buf.appendSlice(allocator, switch (float_value.domain) {
            .fixed => if (float_value.bits == 32) "f32" else "f64",
            .c_float => "c_float",
            .c_double => "c_double",
        }),
        .generic_parameter => |parameter| {
            if (mode == .key) {
                // Two declarations can spell the same binder identically, so the
                // scope keeps their specializations from sharing a generated name.
                try buf.print(allocator, "{s}@{d}", .{ parameter.name, @backingInt(parameter.scope) });
            } else {
                try buf.appendSlice(allocator, parameter.name);
            }
        },
        .nominal => |nominal_value| try appendNominalName(context, buf, nominal_value.decl_id, mode),
        .generic_instance => |instance| {
            const decl_id = instance.decl_id orelse instance.base_decl_id;
            try appendNominalName(context, buf, decl_id, mode);
            // A resolved specialization already carries its arguments in the
            // generated declaration name; an unresolved instance does not.
            if (mode == .key and instance.decl_id == null and instance.args.len != 0) {
                try buf.append(allocator, '<');
                for (instance.args, 0..) |arg, i| {
                    if (i != 0) try buf.appendSlice(allocator, ", ");
                    switch (arg) {
                        .type => |arg_type| try appendDisplay(context, buf, arg_type, .key),
                        .const_usize => |value| try buf.print(allocator, "{d}", .{value}),
                    }
                }
                try buf.append(allocator, '>');
            }
        },
        .optional => |payload| {
            try buf.append(allocator, '?');
            try appendDisplay(context, buf, payload, mode);
        },
        .array => |array_value| {
            try buf.print(allocator, "[{d}]", .{array_value.len});
            try appendDisplay(context, buf, array_value.item, mode);
        },
        .tuple => |members| {
            try buf.append(allocator, '(');
            for (members, 0..) |member, index| {
                if (index != 0) try buf.appendSlice(allocator, ", ");
                try appendDisplay(context, buf, member, mode);
            }
            if (members.len == 1) try buf.append(allocator, ',');
            try buf.append(allocator, ')');
        },
        .dense_array => |item| {
            try buf.appendSlice(allocator, "[:]");
            try appendDisplay(context, buf, item, mode);
        },
        .sparse_array => |item| {
            try buf.appendSlice(allocator, "[;]");
            try appendDisplay(context, buf, item, mode);
        },
        .slice => |slice_value| {
            try buf.appendSlice(allocator, if (slice_value.is_const) "[]const " else "[]");
            try appendDisplay(context, buf, slice_value.item, mode);
        },
        .result => |result_type| {
            try appendDisplay(context, buf, result_type.ok, mode);
            try buf.append(allocator, '!');
            try appendDisplay(context, buf, result_type.err, mode);
        },
        .error_union => |members| {
            for (members, 0..) |member, index| {
                if (index != 0) try buf.appendSlice(allocator, " | ");
                try appendDisplay(context, buf, member, mode);
            }
        },
        .ref_ => |ref_type| {
            try buf.appendSlice(allocator, if (ref_type.is_const) "&const " else "&");
            try appendDisplay(context, buf, ref_type.target, mode);
        },
        .owned => |target| {
            try buf.append(allocator, '^');
            try appendDisplay(context, buf, target, mode);
        },
        .raw => |raw_value| {
            try buf.append(allocator, '*');
            if (raw_value.is_const) try buf.appendSlice(allocator, "const ");
            if (mode != .key and raw_value.is_volatile) try buf.appendSlice(allocator, "volatile ");
            try appendDisplay(context, buf, raw_value.target, mode);
        },
        .callable => |callable_value| {
            if (callable_value.kind == .function) {
                if (callable_value.calling_convention == .c) try buf.appendSlice(allocator, "c ");
                try buf.appendSlice(allocator, "fn(");
            } else {
                try buf.append(allocator, '(');
            }
            for (callable_value.params, 0..) |param, i| {
                if (i != 0) try buf.appendSlice(allocator, ", ");
                try appendDisplay(context, buf, param, mode);
            }
            try buf.appendSlice(allocator, ") => ");
            try appendDisplay(context, buf, callable_value.return_type, mode);
        },
    }
}

/// Alias bindings are owned by the semantic session; lookup and deduplication
/// belong with canonical type resolution.
pub fn aliasTypeId(state: *const session.CanonicalState, decl_id: identity.DeclId) ?semantic_types.TypeId {
    for (state.aliases.items) |binding| {
        if (binding.decl_id == decl_id) return binding.type_id;
    }
    return null;
}

pub fn recordGenericAlias(
    allocator: std.mem.Allocator,
    state: *session.CanonicalState,
    decl_id: identity.DeclId,
    canonical_args: []const semantic_types.GenericArgument,
    resolved: semantic_types.TypeId,
) Error!void {
    const args = try allocator.dupe(semantic_types.GenericArgument, canonical_args);
    errdefer allocator.free(args);
    for (state.generic_aliases.items) |binding| {
        if (binding.decl_id != decl_id or !genericArgumentsEqual(binding.args, args)) continue;
        allocator.free(args);
        if (binding.type_id != resolved) return error.SemanticFailed;
        return;
    }
    try state.generic_aliases.append(allocator, .{
        .decl_id = decl_id,
        .args = args,
        .type_id = resolved,
    });
}

pub fn genericAliasTypeId(
    state: *const session.CanonicalState,
    decl_id: identity.DeclId,
    args: []const semantic_types.GenericArgument,
) ?semantic_types.TypeId {
    for (state.generic_aliases.items) |binding| {
        if (binding.decl_id == decl_id and genericArgumentsEqual(binding.args, args)) return binding.type_id;
    }
    return null;
}

fn genericArgumentsEqual(
    lhs: []const semantic_types.GenericArgument,
    rhs: []const semantic_types.GenericArgument,
) bool {
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

/// Diagnose a failed canonical type expectation with source and origin labels.
pub fn expectTypeFrom(
    context: DisplayContext,
    diagnostic_context: *diagnostics.Context,
    path: []const u8,
    token: lexer.Token,
    expected: semantic_types.TypeId,
    actual: semantic_types.TypeId,
    origin: ?session.TypeExpectationOrigin,
) Error!void {
    if (acceptsExpectation(context.types.interner orelse unreachable, expected, actual)) return;
    const allocator = context.types.allocator;
    var expected_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer expected_buf.deinit(allocator);
    try appendDisplay(context, &expected_buf, expected, .diagnostic);
    const expected_name = try allocator.dupe(u8, expected_buf.items);
    defer allocator.free(expected_name);
    var actual_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer actual_buf.deinit(allocator);
    try appendDisplay(context, &actual_buf, actual, .diagnostic);
    const actual_name = try allocator.dupe(u8, actual_buf.items);
    defer allocator.free(actual_name);
    var labels: [1]diagnostics.Label = undefined;
    const label_slice: []const diagnostics.Label = if (origin) |expectation| blk: {
        labels[0] = .{
            .span = diagnostics.SourceSpan.fromToken(expectation.path, expectation.token),
            .message = expectation.message,
        };
        break :blk &labels;
    } else &.{};
    const notes = [_][]const u8{if (origin == null)
        "the expected type comes from the surrounding expression context"
    else
        "the expected type is introduced by the related declaration"};
    const loses_access = losesWritableAccess(context.types.interner orelse unreachable, expected, actual);
    if (loses_access) {
        try diagnostic_context.emitTokenWith(path, token, .{
            .code = .type_mismatch,
            .labels = label_slice,
            .notes = &notes,
            .help = "use a writable source place or change the destination to read-only access",
        }, "cannot use read-only access `{s}` where writable access `{s}` is required", .{ actual_name, expected_name });
        return Error.SemanticFailed;
    }
    try diagnostic_context.emitTokenWith(path, token, .{
        .code = .type_mismatch,
        .labels = label_slice,
        .notes = &notes,
        .help = "change the expression type or the declaration that introduces the expectation",
    }, "type mismatch: expected {s}, got {s}", .{ expected_name, actual_name });
    return Error.SemanticFailed;
}

pub const SourceContext = struct {
    policy: declarations.resolution.AccessPolicy,
    registry: ?*identity.Registry,
    diagnostic_context: *diagnostics.Context,
};

fn typeDeclarationSpan(program: ast.Program, fallback_path: []const u8, module_name: []const u8, token: lexer.Token) diagnostics.SourceSpan {
    for (program.module_infos) |info| {
        if (std.mem.eql(u8, info.name, module_name) and info.source_path.len != 0)
            return diagnostics.SourceSpan.fromToken(info.source_path, token);
    }
    return diagnostics.SourceSpan.fromToken(fallback_path, token);
}

pub fn lookupModule(context: SourceContext, path: []const u8, program: ast.Program, current_module: []const u8, type_name: ast.TypeName) Error!?[]const u8 {
    if (type_name.module_name) |module_alias| {
        if (declarations.resolution.importedModulePath(program, current_module, module_alias)) |module_name| return module_name;
        const notes = [_][]const u8{"the qualifier must name a namespace import visible in this module"};
        try context.diagnostic_context.emitTokenWith(path, type_name.token, .{
            .code = .name_unknown_module,
            .notes = &notes,
            .help = "import the module or use its local import alias",
        }, "unknown imported module `{s}` in qualified type name", .{module_alias});
        return Error.SemanticFailed;
    }
    return null;
}
const ResolvedTypeKind = declarations.resolution.ResolvedTypeKind;
const ResolvedTypeName = declarations.resolution.ResolvedTypeName;
const AmbiguousResolvedTypeNames = declarations.resolution.AmbiguousResolvedTypeNames;
const ResolvedStructDecl = declarations.resolution.ResolvedStructDecl;
const ResolvedTypeAlias = declarations.resolution.ResolvedTypeAlias;
const ResolvedEnumDecl = declarations.resolution.ResolvedEnumDecl;
const ResolvedUnionDecl = declarations.resolution.ResolvedUnionDecl;
const StructLookupResult = declarations.resolution.StructLookupResult;
const TypeAliasLookupResult = declarations.resolution.TypeAliasLookupResult;
const EnumLookupResult = declarations.resolution.EnumLookupResult;
const UnionLookupResult = declarations.resolution.UnionLookupResult;

fn resolvedTypeDeclarationToken(program: ast.Program, desc: ResolvedTypeName) ?lexer.Token {
    return switch (desc.kind) {
        .@"struct" => if (declarations.resolution.structInModule(program, desc.module_name, desc.name)) |decl| decl.name_token else null,
        .type_alias => if (declarations.resolution.typeAliasInModule(program, desc.module_name, desc.name)) |decl| decl.name_token else null,
        .@"enum" => if (declarations.resolution.enumInModule(program, desc.module_name, desc.name)) |decl| decl.name_token else null,
        .@"union" => if (declarations.resolution.unionInModule(program, desc.module_name, desc.name)) |decl| decl.name_token else null,
    };
}

pub fn printAmbiguousResolvedTypeName(context: SourceContext, path: []const u8, program: ast.Program, token: lexer.Token, name: []const u8, ambiguous: AmbiguousResolvedTypeNames) Error!void {
    var labels: [2]diagnostics.Label = undefined;
    var label_count: usize = 0;
    if (resolvedTypeDeclarationToken(program, ambiguous.first)) |decl_token| {
        labels[label_count] = .{
            .span = typeDeclarationSpan(program, path, ambiguous.first.module_name, decl_token),
            .message = "first visible candidate declared here",
        };
        label_count += 1;
    }
    if (resolvedTypeDeclarationToken(program, ambiguous.second)) |decl_token| {
        labels[label_count] = .{
            .span = typeDeclarationSpan(program, path, ambiguous.second.module_name, decl_token),
            .message = "second visible candidate declared here",
        };
        label_count += 1;
    }
    const notes = [_][]const u8{"unqualified lookup found more than one visible declaration"};
    try context.diagnostic_context.emitTokenWith(path, token, .{
        .code = .name_ambiguous,
        .labels = labels[0..label_count],
        .notes = &notes,
        .help = "use a qualified type name",
    }, "ambiguous type name `{s}`; candidates are `{s}.{s}` and `{s}.{s}`; use a qualified name", .{
        name,
        ambiguous.first.module_name,
        ambiguous.first.name,
        ambiguous.second.module_name,
        ambiguous.second.name,
    });
    return Error.SemanticFailed;
}

pub fn printInaccessibleResolvedTypeName(context: SourceContext, path: []const u8, program: ast.Program, token: lexer.Token, name: []const u8, desc: ResolvedTypeName) Error!void {
    const kind = switch (desc.kind) {
        .@"struct" => "type",
        .type_alias => "type alias",
        .@"enum" => "type",
        .@"union" => "type",
    };
    var labels: [1]diagnostics.Label = undefined;
    const label_slice: []const diagnostics.Label = if (resolvedTypeDeclarationToken(program, desc)) |decl_token| blk: {
        labels[0] = .{
            .span = typeDeclarationSpan(program, path, desc.module_name, decl_token),
            .message = "private declaration is here",
        };
        break :blk &labels;
    } else &.{};
    const notes = [_][]const u8{"the declaration exists, but this module cannot access it"};
    try context.diagnostic_context.emitTokenWith(path, token, .{
        .code = .visibility_private,
        .labels = label_slice,
        .notes = &notes,
        .help = "make the declaration public or expose a public API from its module",
    }, "{s} `{s}` is not public in imported module", .{ kind, name });
    return Error.SemanticFailed;
}

pub fn resolveEnumInTypeScope(context: SourceContext, program: ast.Program, current_module: []const u8, lookup_module: ?[]const u8, name: []const u8) EnumLookupResult {
    return declarations.resolution.resolveEnumInTypeScope(context.policy, context.registry, program, current_module, lookup_module, name);
}

pub fn resolveUnionInTypeScope(context: SourceContext, program: ast.Program, current_module: []const u8, lookup_module: ?[]const u8, name: []const u8) UnionLookupResult {
    return declarations.resolution.resolveUnionInTypeScope(context.policy, context.registry, program, current_module, lookup_module, name);
}

pub fn resolveStructInTypeScope(context: SourceContext, program: ast.Program, current_module: []const u8, lookup_module: ?[]const u8, name: []const u8) StructLookupResult {
    return declarations.resolution.resolveStructInTypeScope(context.policy, context.registry, program, current_module, lookup_module, name);
}

pub fn resolveTypeAliasInTypeScope(context: SourceContext, program: ast.Program, current_module: []const u8, lookup_module: ?[]const u8, name: []const u8) TypeAliasLookupResult {
    return declarations.resolution.resolveTypeAliasInTypeScope(context.policy, context.registry, program, current_module, lookup_module, name);
}

pub fn isPlainCStrTypeName(type_name: ast.TypeName) bool {
    return !type_name.is_ref and
        !type_name.is_owned and
        !type_name.is_raw and
        !type_name.is_optional and
        !type_name.is_function and
        !type_name.is_slice and
        type_name.array_len == null and
        type_name.args.len == 0 and
        std.mem.eql(u8, type_name.name, "c_str");
}

pub fn rawPointeeTypeName(type_name: ast.TypeName) ast.TypeName {
    if (type_name.raw_target) |target| return target.*;
    var pointee = type_name;
    pointee.is_raw = false;
    pointee.raw_is_const = false;
    pointee.is_volatile_raw = false;
    pointee.raw_target = null;
    pointee.is_optional = false;
    return pointee;
}

pub fn expectBuiltinTypeArgCount(context: SourceContext, path: []const u8, type_name: ast.TypeName, expected_count: usize, rendered_name: []const u8) Error!void {
    if (type_name.args.len != expected_count) {
        try context.diagnostic_context.emitToken(path, type_name.token, "`{s}` expects {s} type argument{s}", .{
            rendered_name,
            if (expected_count == 1) "one" else "two",
            if (expected_count == 1) "" else "s",
        });
        return Error.SemanticFailed;
    }
}

pub fn rejectBuiltinOptionalOrArrayShape(context: SourceContext, path: []const u8, type_name: ast.TypeName, rendered_name: []const u8) Error!void {
    if (type_name.is_optional or type_name.array_len != null) {
        try context.diagnostic_context.emitToken(path, type_name.token, "`{s}` cannot have an additional optional or fixed-array modifier", .{rendered_name});
        return Error.SemanticFailed;
    }
}

pub fn findNestedStructInTypeScope(context: SourceContext, program: ast.Program, current_module: []const u8, owner_name: []const u8, nested_name: []const u8) ?ast.StructDecl {
    if (declarations.resolution.nestedStructInModule(program, current_module, owner_name, nested_name)) |decl| return decl;
    for (program.structs) |decl| {
        if (!declarations.resolution.canAccess(context.policy, current_module, decl.module_name, decl.is_pub)) continue;
        if (declarations.resolution.scopedNameMatches(decl.name, owner_name, nested_name)) return decl;
    }
    return null;
}

pub fn findNestedEnumInTypeScope(context: SourceContext, program: ast.Program, current_module: []const u8, owner_name: []const u8, nested_name: []const u8) ?ast.EnumDecl {
    if (declarations.resolution.nestedEnumInModule(program, current_module, owner_name, nested_name)) |decl| return decl;
    for (program.enums) |decl| {
        if (!declarations.resolution.canAccess(context.policy, current_module, decl.module_name, decl.is_pub)) continue;
        if (declarations.resolution.scopedNameMatches(decl.name, owner_name, nested_name)) return decl;
    }
    return null;
}

pub fn unwrapOwned(context: Context, type_id: semantic_types.TypeId) semantic_types.TypeId {
    return switch (node(context, type_id).*) {
        .owned => |target| target,
        else => type_id,
    };
}

pub fn sliceIsConst(context: Context, type_id: semantic_types.TypeId) bool {
    return switch (node(context, type_id).*) {
        .slice => |slice_value| slice_value.is_const,
        else => false,
    };
}

pub fn typeKind(context: Context, type_id: semantic_types.TypeId) sir.Type {
    return switch (node(context, type_id).*) {
        .primitive => |primitive_value| switch (primitive_value) {
            .void, .c_void => .void,
            .bool => .bool,
            .rune => .rune,
            .string => .string,
            .c_str => .raw,
        },
        .inferred_integer, .integer => .int,
        .inferred_float, .float => .float,
        // An uninstantiated binder has no representation of its own: it is an
        // opaque place whose concrete kind is decided by the substitution.
        .generic_parameter => .raw,
        .nominal => |nominal_value| switch (nominal_value.kind) {
            .@"enum" => .@"enum",
            .@"union" => .@"union",
            .@"struct" => .@"struct",
            .type_alias => if (nominal_value.underlying) |underlying| typeKind(context, underlying) else .void,
            .protocol => .void,
        },
        .generic_instance => |instance_value| switch (instance_value.kind) {
            .@"enum" => .@"enum",
            .@"union" => .@"union",
            .@"struct" => .@"struct",
            .type_alias => .void,
            .protocol => .void,
        },
        .optional => .optional,
        .array => .array,
        .dense_array => .dense_array,
        .sparse_array => .sparse_array,
        .slice => .slice,
        .result => .result,
        .error_union => .@"union",
        .tuple => .@"struct",
        .ref_ => .ref,
        .owned => .owned,
        .raw => .raw,
        .callable => |callable_value| if (callable_value.kind == .function) .function else .arrow_callable,
    };
}

pub fn refTarget(context: Context, type_id: semantic_types.TypeId) semantic_types.TypeId {
    return switch (node(context, type_id).*) {
        .ref_ => |ref_type| ref_type.target,
        else => unreachable,
    };
}

pub fn refIsConst(context: Context, type_id: semantic_types.TypeId) bool {
    return switch (node(context, type_id).*) {
        .ref_ => |ref_type| ref_type.is_const,
        else => false,
    };
}

pub fn ownedTarget(context: Context, type_id: semantic_types.TypeId) semantic_types.TypeId {
    return switch (node(context, type_id).*) {
        .owned => |target| target,
        else => unreachable,
    };
}

pub fn nominalDeclId(context: Context, type_id: semantic_types.TypeId) ?identity.DeclId {
    return switch (node(context, type_id).*) {
        .nominal => |nominal_value| nominal_value.decl_id,
        .generic_instance => |instance_value| instance_value.decl_id orelse instance_value.base_decl_id,
        else => null,
    };
}

pub fn isVoidLike(context: Context, type_id: semantic_types.TypeId) bool {
    return switch (node(context, type_id).*) {
        .primitive => |primitive_value| primitive_value == .void or primitive_value == .c_void,
        else => false,
    };
}

pub fn formatFunctionTypeSignature(
    context: DisplayContext,
    calling_convention: ast.CallingConvention,
    params: []const semantic_types.TypeId,
    return_type: semantic_types.TypeId,
) Error![]const u8 {
    const allocator = context.types.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    if (calling_convention == .c) {
        try buf.appendSlice(allocator, "c ");
    }
    try buf.appendSlice(allocator, "fn(");
    for (params, 0..) |param, i| {
        if (i != 0) try buf.appendSlice(allocator, ", ");
        const display = try formatDisplay(context, param, .display);
        defer allocator.free(display);
        try buf.appendSlice(allocator, display);
    }
    try buf.appendSlice(allocator, "): ");
    const return_display = try formatDisplay(context, return_type, .display);
    defer allocator.free(return_display);
    try buf.appendSlice(allocator, return_display);
    return try buf.toOwnedSlice(allocator);
}

pub fn formatArrowCallableTypeSignature(
    context: DisplayContext,
    params: []const semantic_types.TypeId,
    return_type: semantic_types.TypeId,
) Error![]const u8 {
    const allocator = context.types.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '(');
    for (params, 0..) |param, i| {
        if (i != 0) try buf.appendSlice(allocator, ", ");
        const display = try formatDisplay(context, param, .display);
        defer allocator.free(display);
        try buf.appendSlice(allocator, display);
    }
    try buf.appendSlice(allocator, ") => ");
    const return_display = try formatDisplay(context, return_type, .display);
    defer allocator.free(return_display);
    try buf.appendSlice(allocator, return_display);
    return try buf.toOwnedSlice(allocator);
}

/// Source nominal construction also recognizes an already-specialized struct
/// declaration in the session's generic state.
pub fn nominalForSession(
    comptime SemaContext: type,
    context: *SemaContext,
    nominal_kind: semantic_types.NominalKind,
    decl_id: identity.DeclId,
    underlying: ?semantic_types.TypeId,
) Error!semantic_types.TypeId {
    const construction = Context{
        .allocator = context.allocator,
        .abi_layout = context.abi_layout,
        .interner = if (context.canonical.types) |*interner| interner else null,
        .generated_strings = &context.output.generated_strings,
    };
    if (nominal_kind == .@"struct") {
        for (context.generic.instantiated_structs.items) |instance| {
            if (instance.id == null or instance.id.? != decl_id) continue;
            return genericStructInstance(
                construction,
                instance.base_decl_id orelse return error.SemanticFailed,
                instance.id orelse return error.SemanticFailed,
                instance.type_args,
            );
        }
    }
    return nominal(construction, nominal_kind, decl_id, underlying);
}

pub fn distinctAliasType(
    comptime SemaContext: type,
    context: *SemaContext,
    alias: ast.TypeAlias,
    target: semantic_types.TypeId,
) Error!semantic_types.TypeId {
    const decl_id = declarations.registration.findOptional(
        if (context.declarations.registry) |*registry| registry else null,
        alias.module_name,
        null,
        alias.name,
        .type_alias,
    ) orelse return error.SemanticFailed;
    return nominalForSession(SemaContext, context, .type_alias, decl_id, target);
}

pub fn Parser(comptime SemaContext: type, comptime Support: anytype) type {
    return struct {
        fn typeContext(context: *SemaContext) Context {
            return .{
                .allocator = context.allocator,
                .abi_layout = context.abi_layout,
                .interner = if (context.canonical.types) |*interner| interner else null,
                .generated_strings = &context.output.generated_strings,
            };
        }

        fn displayContext(context: *SemaContext) DisplayContext {
            return .{
                .types = typeContext(context),
                .registry = if (context.declarations.registry) |*registry| registry else null,
            };
        }

        fn sourceContext(context: *SemaContext) SourceContext {
            return .{
                .policy = .{ .friend = if (context.options.test_friend) |friend| .{
                    .test_module = friend.test_module,
                    .production_module = friend.production_module,
                } else null },
                .registry = if (context.declarations.registry) |*registry| registry else null,
                .diagnostic_context = &context.diagnostic_context,
            };
        }

        fn maybeRegisteredDeclId(
            context: *SemaContext,
            module_name: []const u8,
            owner: ?[]const u8,
            name: []const u8,
            kind: identity.DeclKind,
        ) ?identity.DeclId {
            return declarations.registration.findOptional(
                if (context.declarations.registry) |*registry| registry else null,
                module_name,
                owner,
                name,
                kind,
            );
        }

        fn isInvalidDenseStorageItemType(context: *SemaContext, type_id: semantic_types.TypeId) bool {
            const resolved_kind = typeKind(typeContext(context), type_id);
            return resolved_kind == .void or resolved_kind == .ref;
        }

        pub fn checkTypeAliases(context: *SemaContext, path: []const u8, program: ast.Program) Error!void {
            for (program.aliases) |alias| {
                try generics.validateGenericParams(SemaContext, context, path, program, alias.module_name, alias.type_params);
                if (alias.is_distinct and alias.type_params.len != 0) {
                    try context.diagnostic_context.emitToken(path, alias.name_token, "distinct type aliases cannot declare generic parameters; use a generic wrapper struct", .{});
                    return Error.SemanticFailed;
                }
                try rejectAliasArrowCallableTypeName(context, path, alias.name_token, alias.target);
                if (alias.type_params.len != 0) {
                    try validateTypeName(context, path, program, alias.module_name, alias.target, alias.type_params, null);
                } else {
                    const target = try parseTypeDepth(context, path, program, alias.module_name, alias.target, null, context.function_state.current_generic_params, context.function_state.current_generic_args, 0);
                    const target_kind = typeKind(typeContext(context), target);
                    if (alias.is_distinct and (target_kind == .@"struct" or target_kind == .@"enum" or target_kind == .@"union")) {
                        try context.diagnostic_context.emitToken(path, alias.name_token, "distinct aliases require scalar or pointer-like targets; use a wrapper declaration for aggregate types", .{});
                        return Error.SemanticFailed;
                    }
                }
            }
        }

        pub fn registerCanonicalAliasTypes(context: *SemaContext, path: []const u8, program: ast.Program) Error!void {
            for (program.aliases) |alias| {
                // Generic aliases are registered per concrete substitution because
                // the declaration alone has no single target TypeId.
                if (alias.type_params.len != 0) continue;

                const decl_id = try declarations.registration.find(if (context.declarations.registry) |*registry| registry else null, alias.module_name, null, alias.name, .type_alias);
                const alias_reference = ast.TypeName{
                    .name = alias.name,
                    .args = &.{},
                    .token = alias.name_token,
                };
                const parsed = try parseTypeDepth(context, path, program, alias.module_name, alias_reference, null, context.function_state.current_generic_params, context.function_state.current_generic_args, 0);
                if (alias.is_distinct) {
                    const parsed_node = context.canonical.types.?.get(parsed) catch return error.SemanticFailed;
                    if (parsed_node.* != .nominal or
                        parsed_node.nominal.kind != .type_alias or
                        parsed_node.nominal.decl_id != decl_id)
                    {
                        return error.SemanticFailed;
                    }
                }
                try context.canonical.aliases.append(context.allocator, .{
                    .decl_id = decl_id,
                    .type_id = parsed,
                    .is_distinct = alias.is_distinct,
                });
            }
        }

        fn rejectAliasArrowCallableTypeName(context: *SemaContext, path: []const u8, token: lexer.Token, type_name: ast.TypeName) Error!void {
            if (!generics.typeNameContainsArrowCallable(type_name)) return;
            try context.diagnostic_context.emitToken(
                path,
                token,
                "non-escaping callable types are valid only as function parameters because their capture environment is call-local; `{s}` cannot use one; use `fn(...)` for a non-capturing stored callback, or store explicit context beside the function pointer",
                .{"type alias"},
            );
            return Error.SemanticFailed;
        }

        pub fn validateTypeName(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
            generic_params: []const ast.GenericParam,
            self_type: ?semantic_types.TypeId,
        ) Error!void {
            if (type_name.is_const_value_arg) {
                try context.diagnostic_context.emitToken(path, type_name.token, "compile-time values cannot be used as types", .{});
                return Error.SemanticFailed;
            }
            for (type_name.function_params) |param| {
                try validateTypeName(context, path, program, current_module, param, generic_params, self_type);
            }
            if (type_name.function_return_type) |return_type| {
                try validateTypeName(context, path, program, current_module, return_type.*, generic_params, self_type);
            }
            for (type_name.args) |arg| {
                if (arg.is_const_value_arg) continue;
                if (!arg.is_ref and !arg.is_owned and !arg.is_raw and !arg.is_volatile_raw and !arg.is_optional and !arg.is_function and !arg.is_arrow_callable and !arg.is_slice and arg.array_len == null and arg.array_len_name == null and arg.args.len == 0 and generics.isArrayLenParamName(generic_params, arg.name)) continue;
                try validateTypeName(context, path, program, current_module, arg, generic_params, self_type);
            }
            if (type_name.is_function or type_name.is_arrow_callable) {
                return;
            }
            if (std.mem.eql(u8, type_name.name, "()")) return;
            if (type_name.is_function and generics.typeNameContainsParam(type_name, generic_params)) {
                return;
            }

            if (type_name.is_optional and type_name.is_owned) {
                try context.diagnostic_context.emitToken(path, type_name.token, "nested optional pointer forms are not supported", .{});
                return Error.SemanticFailed;
            }
            if (type_name.array_len_name) |len_name| {
                if (!generics.isArrayLenParamName(generic_params, len_name)) {
                    try context.diagnostic_context.emitToken(path, type_name.array_len_token orelse type_name.token, "unknown const generic array length `{s}`", .{len_name});
                    return Error.SemanticFailed;
                }
                var item_name = type_name;
                item_name.array_len_name = null;
                item_name.array_len_token = null;
                try validateTypeName(context, path, program, current_module, item_name, generic_params, self_type);
                return;
            }
            if (try protocols.validateAssociatedProjectionName(protocols.contextFromSession(SemaContext, context), path, program, current_module, type_name, generic_params)) return;
            if (generics.isTypeParamName(generic_params, type_name.name)) {
                if (type_name.args.len != 0) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "generic parameter `{s}` does not accept type arguments", .{type_name.name});
                    return Error.SemanticFailed;
                }
                return;
            }
            if (generics.typeNameContainsParam(type_name, generic_params)) {
                if (std.mem.eql(u8, type_name.name, "[:]") or
                    std.mem.eql(u8, type_name.name, "[;]"))
                {
                    if (type_name.args.len != 1) {
                        try context.diagnostic_context.emitToken(path, type_name.token, "type `{s}` expects one type argument", .{type_name.name});
                        return Error.SemanticFailed;
                    }
                    return;
                }
                if (std.mem.eql(u8, type_name.name, language_contracts.result_type_name)) {
                    if (type_name.args.len != 2) {
                        try context.diagnostic_context.emitToken(path, type_name.token, "type `{s}` expects two type arguments", .{type_name.name});
                        return Error.SemanticFailed;
                    }
                    return;
                }
                if (declarations.resolution.accessibleStruct(sourceContext(context).policy, program, current_module, type_name.name)) |decl| {
                    if (decl.type_params.len != type_name.args.len) {
                        try generics.emitGenericArity(&context.diagnostic_context, path, program, type_name.token, decl.module_name, decl.name_token, .@"struct", type_name.name, decl.type_params.len, type_name.args.len);
                        return Error.SemanticFailed;
                    }
                    return;
                }
                if (declarations.resolution.accessibleTypeAlias(sourceContext(context).policy, program, current_module, type_name.name)) |alias| {
                    if (alias.type_params.len != type_name.args.len) {
                        try generics.emitGenericArity(&context.diagnostic_context, path, program, type_name.token, alias.module_name, alias.name_token, .type_alias, type_name.name, alias.type_params.len, type_name.args.len);
                        return Error.SemanticFailed;
                    }
                    return;
                }
            }
            _ = try parseTypeDepth(context, path, program, current_module, type_name, self_type, context.function_state.current_generic_params, context.function_state.current_generic_args, 0);
        }

        pub fn parseTypeDepth(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
            self_type: ?semantic_types.TypeId,
            generic_params: []const ast.GenericParam,
            generic_args: []const semantic_types.GenericArgument,
            depth: usize,
        ) Error!semantic_types.TypeId {
            if (type_name.is_const_value_arg) {
                try context.diagnostic_context.emitToken(path, type_name.token, "compile-time values cannot be used as types", .{});
                return Error.SemanticFailed;
            }
            if (type_name.is_inline_error_union) {
                const members = try context.allocator.alloc(semantic_types.TypeId, type_name.args.len);
                defer context.allocator.free(members);
                for (type_name.args, members) |member_name, *member| {
                    member.* = try parseTypeDepth(context, path, program, current_module, member_name, self_type, generic_params, generic_args, depth + 1);
                    if (typeKind(typeContext(context), member.*) != .@"enum") {
                        try context.diagnostic_context.emitToken(path, member_name.token, "result error union member must be an enum", .{});
                        return Error.SemanticFailed;
                    }
                }
                return errorUnion(typeContext(context), members) catch |err| {
                    if (err == error.SemanticFailed) {
                        try context.diagnostic_context.emitToken(path, type_name.token, "result error union members must be distinct enums", .{});
                    }
                    return err;
                };
            }
            if (std.mem.eql(u8, type_name.name, "c_str") and !isPlainCStrTypeName(type_name)) {
                try context.diagnostic_context.emitToken(path, type_name.token, "`c_str` is an unwrapped borrowed parameter/local view; use `?*const c_char` for nullable C pointers and explicit raw-pointer types for stored forms", .{});
                return Error.SemanticFailed;
            }
            if (type_name.is_optional and (type_name.is_owned or type_name.is_raw)) {
                var payload_name = type_name;
                payload_name.is_optional = false;
                const payload = try parseTypeDepth(context, path, program, current_module, payload_name, self_type, generic_params, generic_args, depth);
                if (typeKind(typeContext(context), payload) == .optional) {
                    try context.diagnostic_context.emitTokenWith(path, type_name.token, .{
                        .code = .sum_type_shape,
                        .notes = &.{"an optional has one empty state and one payload state"},
                        .help = "use a named union when distinct empty states are required",
                    }, "nested optional types are not supported; use a named union when distinct empty states are required", .{});
                    return Error.SemanticFailed;
                }
                if (typeKind(typeContext(context), payload) == .void) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "optional void is not allowed", .{});
                    return Error.SemanticFailed;
                }
                return optional(typeContext(context), payload);
            }

            if (type_name.is_ref) {
                var target_name = type_name;
                target_name.is_ref = false;
                target_name.ref_is_const = false;
                const target = try parseTypeDepth(context, path, program, current_module, target_name, self_type, generic_params, generic_args, depth);
                if (typeKind(typeContext(context), target) == .void or typeKind(typeContext(context), target) == .ref) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "invalid alias pointer target type", .{});
                    return Error.SemanticFailed;
                }
                return if (type_name.ref_is_const)
                    ref(typeContext(context), target, true)
                else
                    ref(typeContext(context), target, false);
            }
            if (type_name.is_owned) {
                var target_name = type_name;
                target_name.is_owned = false;
                const target = try parseTypeDepth(context, path, program, current_module, target_name, self_type, generic_params, generic_args, depth);
                const target_kind = typeKind(typeContext(context), target);
                if (target_kind == .void or target_kind == .ref or target_kind == .owned) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "invalid owned pointer target type", .{});
                    return Error.SemanticFailed;
                }
                return owned(typeContext(context), target);
            }
            if (type_name.is_raw) {
                const target_name = rawPointeeTypeName(type_name);
                const target = try parseTypeDepth(context, path, program, current_module, target_name, self_type, generic_params, generic_args, depth);
                const target_kind = typeKind(typeContext(context), target);
                if ((target_kind == .void and !std.mem.eql(u8, target_name.name, "c_void")) or target_kind == .ref or target_kind == .owned) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "invalid raw pointer target type", .{});
                    return Error.SemanticFailed;
                }
                return raw(typeContext(context), target, type_name.raw_is_const, type_name.is_volatile_raw);
            }
            if (type_name.is_slice) {
                var item_name = type_name;
                item_name.is_slice = false;
                item_name.is_optional = type_name.slice_flags.item_is_optional;
                item_name.slice_flags = .{};
                const item_type = try parseTypeDepth(context, path, program, current_module, item_name, self_type, generic_params, generic_args, depth);
                if (typeKind(typeContext(context), item_type) == .void or typeKind(typeContext(context), item_type) == .ref) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "invalid slice item type", .{});
                    return Error.SemanticFailed;
                }
                const slice_type = try slice(typeContext(context), item_type, type_name.slice_flags.is_const);
                if (!type_name.is_optional) return slice_type;
                return try optional(typeContext(context), slice_type);
            }
            if (type_name.is_function) {
                return parseFunctionTypeDepth(context, path, program, current_module, type_name, self_type, generic_params, generic_args, depth);
            }
            if (type_name.is_arrow_callable) {
                return parseArrowCallableTypeDepth(context, path, program, current_module, type_name, self_type, generic_params, generic_args, depth);
            }
            if (std.mem.eql(u8, type_name.name, "()")) {
                const members = try context.allocator.alloc(semantic_types.TypeId, type_name.args.len);
                defer context.allocator.free(members);
                for (type_name.args, members) |member_name, *member| {
                    member.* = try parseTypeDepth(context, path, program, current_module, member_name, self_type, generic_params, generic_args, depth + 1);
                    if (typeKind(typeContext(context), member.*) == .void) {
                        try context.diagnostic_context.emitToken(path, member_name.token, "tuple element cannot have type `void`", .{});
                        return Error.SemanticFailed;
                    }
                }
                return intern(typeContext(context), .{ .tuple = members });
            }
            if (try protocols.resolveAssociatedTypeProjection(protocols.contextFromSession(SemaContext, context), path, program, current_module, type_name, self_type, generic_params, generic_args)) |projected| {
                return projected;
            }
            if (std.mem.eql(u8, type_name.name, "Array") and type_name.args.len != 0) {
                try context.diagnostic_context.emitToken(path, type_name.token, "`Array<T>` was replaced by `[:]T`", .{});
                return Error.SemanticFailed;
            }
            if (std.mem.eql(u8, type_name.name, "[:]")) {
                try expectBuiltinTypeArgCount(sourceContext(context), path, type_name, 1, "[:]");
                try rejectBuiltinOptionalOrArrayShape(sourceContext(context), path, type_name, "[:]T");
                const item_type = try parseTypeDepth(context, path, program, current_module, type_name.args[0], self_type, generic_params, generic_args, depth + 1);
                if (isInvalidDenseStorageItemType(context, item_type)) {
                    try context.diagnostic_context.emitToken(path, type_name.args[0].token, "invalid `[:]T` item type", .{});
                    return Error.SemanticFailed;
                }
                return denseArray(typeContext(context), item_type);
            }
            if (std.mem.eql(u8, type_name.name, "[;]")) {
                try expectBuiltinTypeArgCount(sourceContext(context), path, type_name, 1, "[;]");
                try rejectBuiltinOptionalOrArrayShape(sourceContext(context), path, type_name, "[;]T");
                const item_type = try parseTypeDepth(context, path, program, current_module, type_name.args[0], self_type, generic_params, generic_args, depth + 1);
                if (isInvalidDenseStorageItemType(context, item_type)) {
                    try context.diagnostic_context.emitToken(path, type_name.args[0].token, "invalid `[;]T` item type", .{});
                    return Error.SemanticFailed;
                }
                return sparseArray(typeContext(context), item_type);
            }
            if (std.mem.eql(u8, type_name.name, language_contracts.result_type_name)) {
                try expectBuiltinTypeArgCount(sourceContext(context), path, type_name, 2, language_contracts.result_type_name);
                try rejectBuiltinOptionalOrArrayShape(sourceContext(context), path, type_name, language_contracts.result_type_name);
                const ok_type = try parseTypeDepth(context, path, program, current_module, type_name.args[0], self_type, generic_params, generic_args, depth + 1);
                const err_type = try parseTypeDepth(context, path, program, current_module, type_name.args[1], self_type, generic_params, generic_args, depth + 1);
                const err_kind = typeKind(typeContext(context), err_type);
                if (node(typeContext(context), err_type).* == .error_union) {
                    // Members were validated while resolving the inline union.
                } else if (err_kind == .@"union") {
                    const union_id = nominalDeclId(typeContext(context), err_type) orelse return Error.SemanticFailed;
                    const decl = for (program.unions) |candidate| {
                        if (maybeRegisteredDeclId(context, candidate.module_name, null, candidate.name, .@"union") == union_id) break candidate;
                    } else return Error.SemanticFailed;
                    if (decl.kind != .type_union) {
                        try context.diagnostic_context.emitToken(path, type_name.args[1].token, "result error type must be an enum or a type union of enums", .{});
                        return Error.SemanticFailed;
                    }
                    for (decl.variants) |variant| {
                        const member = try parseTypeDepth(context, path, program, decl.module_name, variant, self_type, generic_params, generic_args, depth + 1);
                        if (typeKind(typeContext(context), member) != .@"enum") {
                            try context.diagnostic_context.emitToken(path, variant.token, "result error union member must be an enum", .{});
                            return Error.SemanticFailed;
                        }
                    }
                } else if (err_kind != .@"enum") {
                    try context.diagnostic_context.emitToken(path, type_name.args[1].token, "result error type must be an enum or a type union of enums", .{});
                    return Error.SemanticFailed;
                }
                return result(typeContext(context), ok_type, err_type);
            }
            const nested_enum = if (type_name.module_name) |owner_name| blk: {
                if (declarations.resolution.importedModulePath(program, current_module, owner_name) == null) {
                    break :blk findNestedEnumInTypeScope(sourceContext(context), program, current_module, owner_name, type_name.name);
                }
                break :blk null;
            } else null;
            const nested_struct = if (nested_enum == null and type_name.module_name != null) blk: {
                const owner_name = type_name.module_name.?;
                if (declarations.resolution.importedModulePath(program, current_module, owner_name) == null) {
                    break :blk findNestedStructInTypeScope(sourceContext(context), program, current_module, owner_name, type_name.name);
                }
                break :blk null;
            } else null;
            const lookup_module = if (nested_enum == null and nested_struct == null)
                try lookupModule(sourceContext(context), path, program, current_module, type_name)
            else
                null;
            const generic_payload: ?semantic_types.TypeId = if (type_name.args.len != 0) blk: {
                switch (resolveStructInTypeScope(sourceContext(context), program, current_module, lookup_module, type_name.name)) {
                    .found => |resolved| {
                        const decl = resolved.decl;
                        if (decl.type_params.len == 0) {
                            try context.diagnostic_context.emitToken(path, type_name.token, "type `{s}` does not accept type arguments", .{type_name.name});
                            return Error.SemanticFailed;
                        }
                        break :blk try generics.instantiateGenericStruct(SemaContext, Support.struct_support, context, path, program, current_module, decl, type_name.args, self_type, generic_params, generic_args);
                    },
                    .inaccessible => |resolved| try printInaccessibleResolvedTypeName(sourceContext(context), path, program, type_name.token, type_name.name, resolved.desc),
                    .ambiguous => |ambiguous| try printAmbiguousResolvedTypeName(sourceContext(context), path, program, type_name.token, type_name.name, ambiguous),
                    .missing => {},
                }
                switch (resolveTypeAliasInTypeScope(sourceContext(context), program, current_module, lookup_module, type_name.name)) {
                    .found => |resolved| {
                        const alias = resolved.alias;
                        if (alias.type_params.len == 0) {
                            try context.diagnostic_context.emitToken(path, type_name.token, "type alias `{s}` does not accept type arguments", .{type_name.name});
                            return Error.SemanticFailed;
                        }
                        break :blk try generics.instantiateTypeAlias(SemaContext, Support.alias_support, context, path, program, current_module, alias, type_name.args, self_type, generic_params, generic_args, depth);
                    },
                    .inaccessible => |resolved| try printInaccessibleResolvedTypeName(sourceContext(context), path, program, type_name.token, type_name.name, resolved.desc),
                    .ambiguous => |ambiguous| try printAmbiguousResolvedTypeName(sourceContext(context), path, program, type_name.token, type_name.name, ambiguous),
                    .missing => {},
                }
                try context.diagnostic_context.emitToken(path, type_name.token, "type `{s}` does not accept type arguments", .{type_name.name});
                return Error.SemanticFailed;
            } else null;
            const payload = if (generic_payload) |resolved| resolved else if (nested_enum) |decl| blk: {
                if (type_name.args.len != 0) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "nested type `{s}.{s}` does not accept type arguments", .{ type_name.module_name.?, type_name.name });
                    return Error.SemanticFailed;
                }
                break :blk try nominalForSession(SemaContext, context, .@"enum", maybeRegisteredDeclId(context, decl.module_name, null, decl.name, .@"enum") orelse return error.SemanticFailed, null);
            } else if (nested_struct) |decl| blk: {
                if (type_name.args.len != 0) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "nested type `{s}.{s}` does not accept type arguments", .{ type_name.module_name.?, type_name.name });
                    return Error.SemanticFailed;
                }
                break :blk try nominalForSession(SemaContext, context, .@"struct", maybeRegisteredDeclId(context, decl.module_name, null, decl.name, .@"struct") orelse return error.SemanticFailed, null);
            } else try parseNamedTypeDepth(context, path, program, current_module, lookup_module, type_name.token, type_name.name, self_type, generic_params, generic_args, depth);
            const resolved_array_len = if (type_name.array_len) |len|
                len
            else if (type_name.array_len_name) |len_name|
                generics.arrayLenForName(generic_params, generic_args, len_name) orelse {
                    try context.diagnostic_context.emitToken(path, type_name.array_len_token orelse type_name.token, "unknown const generic array length `{s}`", .{len_name});
                    return Error.SemanticFailed;
                }
            else
                null;
            const maybe_array = if (resolved_array_len) |len| blk: {
                if (typeKind(typeContext(context), payload) == .void) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "array item type cannot be void", .{});
                    return Error.SemanticFailed;
                }
                if (typeKind(typeContext(context), payload) == .array or typeKind(typeContext(context), payload) == .dense_array) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "nested fixed or owned arrays are not supported; use a wrapper struct for the inner array", .{});
                    return Error.SemanticFailed;
                }
                break :blk try array(typeContext(context), len, payload);
            } else payload;
            if (!type_name.is_optional) return maybe_array;
            if (typeKind(typeContext(context), maybe_array) == .optional) {
                try context.diagnostic_context.emitTokenWith(path, type_name.token, .{
                    .code = .sum_type_shape,
                    .notes = &.{"an optional has one empty state and one payload state"},
                    .help = "use a named union when distinct empty states are required",
                }, "nested optional types are not supported; use a named union when distinct empty states are required", .{});
                return Error.SemanticFailed;
            }
            if (typeKind(typeContext(context), maybe_array) == .void) {
                try context.diagnostic_context.emitToken(path, type_name.token, "optional void is not allowed", .{});
                return Error.SemanticFailed;
            }
            return optional(typeContext(context), maybe_array);
        }

        fn parseQualifiedNamedTypeDepth(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            lookup_module: []const u8,
            token: lexer.Token,
            name: []const u8,
            self_type: ?semantic_types.TypeId,
            generic_params: []const ast.GenericParam,
            generic_args: []const semantic_types.GenericArgument,
            depth: usize,
        ) Error!semantic_types.TypeId {
            switch (resolveEnumInTypeScope(sourceContext(context), program, current_module, lookup_module, name)) {
                .found => |resolved| return nominalForSession(SemaContext, context, .@"enum", resolved.desc.id orelse return error.SemanticFailed, null),
                .inaccessible => |resolved| try printInaccessibleResolvedTypeName(sourceContext(context), path, program, token, name, resolved.desc),
                .ambiguous => |ambiguous| try printAmbiguousResolvedTypeName(sourceContext(context), path, program, token, name, ambiguous),
                .missing => {},
            }
            switch (resolveUnionInTypeScope(sourceContext(context), program, current_module, lookup_module, name)) {
                .found => |resolved| return nominalForSession(SemaContext, context, .@"union", resolved.desc.id orelse return error.SemanticFailed, null),
                .inaccessible => |resolved| try printInaccessibleResolvedTypeName(sourceContext(context), path, program, token, name, resolved.desc),
                .ambiguous => |ambiguous| try printAmbiguousResolvedTypeName(sourceContext(context), path, program, token, name, ambiguous),
                .missing => {},
            }
            if (declarations.resolution.structInModule(program, lookup_module, name)) |decl| {
                if (!declarations.resolution.canAccess(sourceContext(context).policy, current_module, decl.module_name, decl.is_pub)) {
                    try printInaccessibleResolvedTypeName(sourceContext(context), path, program, token, name, .{
                        .id = maybeRegisteredDeclId(context, decl.module_name, null, decl.name, .@"struct"),
                        .kind = .@"struct",
                        .module_name = decl.module_name,
                        .name = decl.name,
                    });
                    return Error.SemanticFailed;
                }
                if (decl.type_params.len != 0) {
                    try context.diagnostic_context.emitToken(path, token, "generic type `{s}` requires explicit type arguments", .{name});
                    return Error.SemanticFailed;
                }
                return nominalForSession(SemaContext, context, .@"struct", maybeRegisteredDeclId(context, decl.module_name, null, decl.name, .@"struct") orelse return error.SemanticFailed, null);
            }
            if (declarations.resolution.typeAliasInModule(program, lookup_module, name)) |alias| {
                if (!declarations.resolution.canAccess(sourceContext(context).policy, current_module, alias.module_name, alias.is_pub)) {
                    try printInaccessibleResolvedTypeName(sourceContext(context), path, program, token, name, .{
                        .id = maybeRegisteredDeclId(context, alias.module_name, null, alias.name, .type_alias),
                        .kind = .type_alias,
                        .module_name = alias.module_name,
                        .name = alias.name,
                    });
                    return Error.SemanticFailed;
                }
                if (alias.type_params.len != 0) {
                    try context.diagnostic_context.emitToken(path, token, "generic type alias `{s}` requires explicit type arguments", .{name});
                    return Error.SemanticFailed;
                }
                if (alias.is_distinct) {
                    const target = try parseTypeDepth(context, path, program, alias.module_name, alias.target, self_type, generic_params, generic_args, depth + 1);
                    const target_kind = typeKind(typeContext(context), target);
                    if (target_kind == .@"struct" or target_kind == .@"enum" or target_kind == .@"union") {
                        try context.diagnostic_context.emitToken(path, alias.name_token, "distinct aliases require scalar or pointer-like targets; use a wrapper declaration for aggregate types", .{});
                        return Error.SemanticFailed;
                    }
                    return distinctAliasType(SemaContext, context, alias, target);
                }
                return parseTypeDepth(context, path, program, alias.module_name, alias.target, self_type, generic_params, generic_args, depth + 1);
            }
            try emitUnknownType(sourceContext(context), context.allocator, path, program, current_module, token, name, true);
            return Error.SemanticFailed;
        }

        fn parseNamedTypeDepth(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            lookup_module: ?[]const u8,
            token: lexer.Token,
            name: []const u8,
            self_type: ?semantic_types.TypeId,
            generic_params: []const ast.GenericParam,
            generic_args: []const semantic_types.GenericArgument,
            depth: usize,
        ) Error!semantic_types.TypeId {
            if (depth > 32) {
                try context.diagnostic_context.emitToken(path, token, "type alias cycle involving `{s}`", .{name});
                return Error.SemanticFailed;
            }
            if (lookup_module != null) {
                return parseQualifiedNamedTypeDepth(context, path, program, current_module, lookup_module.?, token, name, self_type, generic_params, generic_args, depth);
            }
            if (self_type) |ty| {
                if (std.mem.eql(u8, name, "Self")) return ty;
            }
            if (generics.typeArgForName(generic_params, generic_args, name)) |type_id| return type_id;
            if (std.mem.eql(u8, name, "void")) return primitive(typeContext(context), .void);
            if (std.mem.eql(u8, name, "c_void")) return primitive(typeContext(context), .c_void);
            if (std.mem.eql(u8, name, "c_str")) return primitive(typeContext(context), .c_str);
            if (std.mem.eql(u8, name, "bool")) return primitive(typeContext(context), .bool);
            if (std.mem.eql(u8, name, "char")) return primitive(typeContext(context), .rune);
            if (std.mem.eql(u8, name, "string")) return primitive(typeContext(context), .string);
            if (std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64") or std.mem.eql(u8, name, "c_float") or std.mem.eql(u8, name, "c_double")) return float(typeContext(context), name);
            if (isFixedWidthIntegerName(name) or std.mem.eql(u8, name, "isize") or std.mem.eql(u8, name, "usize") or isCAbiScalarTypeName(name)) return integer(typeContext(context), name);
            switch (resolveEnumInTypeScope(sourceContext(context), program, current_module, null, name)) {
                .found => |resolved| return nominalForSession(SemaContext, context, .@"enum", resolved.desc.id orelse return error.SemanticFailed, null),
                .inaccessible => |resolved| try printInaccessibleResolvedTypeName(sourceContext(context), path, program, token, name, resolved.desc),
                .ambiguous => |ambiguous| try printAmbiguousResolvedTypeName(sourceContext(context), path, program, token, name, ambiguous),
                .missing => {},
            }
            switch (resolveUnionInTypeScope(sourceContext(context), program, current_module, null, name)) {
                .found => |resolved| return nominalForSession(SemaContext, context, .@"union", resolved.desc.id orelse return error.SemanticFailed, null),
                .inaccessible => |resolved| try printInaccessibleResolvedTypeName(sourceContext(context), path, program, token, name, resolved.desc),
                .ambiguous => |ambiguous| try printAmbiguousResolvedTypeName(sourceContext(context), path, program, token, name, ambiguous),
                .missing => {},
            }
            switch (resolveStructInTypeScope(sourceContext(context), program, current_module, null, name)) {
                .found => |resolved| {
                    const decl = resolved.decl;
                    if (decl.type_params.len != 0) {
                        try context.diagnostic_context.emitToken(path, token, "generic type `{s}` requires explicit type arguments", .{name});
                        return Error.SemanticFailed;
                    }
                    return nominalForSession(SemaContext, context, .@"struct", resolved.desc.id orelse return error.SemanticFailed, null);
                },
                .inaccessible => |resolved| try printInaccessibleResolvedTypeName(sourceContext(context), path, program, token, name, resolved.desc),
                .ambiguous => |ambiguous| try printAmbiguousResolvedTypeName(sourceContext(context), path, program, token, name, ambiguous),
                .missing => {},
            }
            switch (resolveTypeAliasInTypeScope(sourceContext(context), program, current_module, null, name)) {
                .found => |resolved| {
                    const alias = resolved.alias;
                    if (alias.type_params.len != 0) {
                        try context.diagnostic_context.emitToken(path, token, "generic type alias `{s}` requires explicit type arguments", .{name});
                        return Error.SemanticFailed;
                    }
                    if (alias.is_distinct) {
                        const target = try parseTypeDepth(context, path, program, alias.module_name, alias.target, self_type, generic_params, generic_args, depth + 1);
                        const target_kind = typeKind(typeContext(context), target);
                        if (target_kind == .@"struct" or target_kind == .@"enum" or target_kind == .@"union") {
                            try context.diagnostic_context.emitToken(path, alias.name_token, "distinct aliases require scalar or pointer-like targets; use a wrapper declaration for aggregate types", .{});
                            return Error.SemanticFailed;
                        }
                        return distinctAliasType(SemaContext, context, alias, target);
                    }
                    return parseTypeDepth(context, path, program, alias.module_name, alias.target, self_type, generic_params, generic_args, depth + 1);
                },
                .inaccessible => |resolved| try printInaccessibleResolvedTypeName(sourceContext(context), path, program, token, name, resolved.desc),
                .ambiguous => |ambiguous| try printAmbiguousResolvedTypeName(sourceContext(context), path, program, token, name, ambiguous),
                .missing => {},
            }
            try emitUnknownType(sourceContext(context), context.allocator, path, program, current_module, token, name, false);
            return Error.SemanticFailed;
        }

        fn parseFunctionTypeDepth(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
            self_type: ?semantic_types.TypeId,
            generic_params: []const ast.GenericParam,
            generic_args: []const semantic_types.GenericArgument,
            depth: usize,
        ) Error!semantic_types.TypeId {
            const allocator = context.allocator;
            const params = try allocator.alloc(semantic_types.TypeId, type_name.function_params.len);
            defer allocator.free(params);
            for (type_name.function_params, 0..) |param, i| {
                params[i] = try parseTypeDepth(context, path, program, current_module, param, self_type, generic_params, generic_args, depth + 1);
                if (typeKind(typeContext(context), params[i]) == .void) {
                    try context.diagnostic_context.emitToken(path, param.token, "function parameter type cannot be void", .{});
                    return Error.SemanticFailed;
                }
            }
            const return_type = if (type_name.function_return_type) |return_type_name|
                try parseTypeDepth(context, path, program, current_module, return_type_name.*, self_type, generic_params, generic_args, depth + 1)
            else
                try primitive(typeContext(context), .void);
            const signature = try formatFunctionTypeSignature(
                displayContext(context),
                type_name.function_calling_convention,
                params,
                return_type,
            );
            context.output.generated_strings.append(allocator, signature) catch |err| {
                allocator.free(signature);
                return err;
            };
            return callable(
                typeContext(context),
                .function,
                if (type_name.function_calling_convention == .c) .c else .cyna,
                params,
                return_type,
            );
        }

        fn parseArrowCallableTypeDepth(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
            self_type: ?semantic_types.TypeId,
            generic_params: []const ast.GenericParam,
            generic_args: []const semantic_types.GenericArgument,
            depth: usize,
        ) Error!semantic_types.TypeId {
            const allocator = context.allocator;
            const params = try allocator.alloc(semantic_types.TypeId, type_name.function_params.len);
            defer allocator.free(params);
            for (type_name.function_params, 0..) |param, i| {
                params[i] = try parseTypeDepth(context, path, program, current_module, param, self_type, generic_params, generic_args, depth + 1);
                if (typeKind(typeContext(context), params[i]) == .void) {
                    try context.diagnostic_context.emitToken(path, param.token, "non-escaping callable parameter type cannot be void", .{});
                    return Error.SemanticFailed;
                }
            }
            const return_type = if (type_name.function_return_type) |return_type_name|
                try parseTypeDepth(context, path, program, current_module, return_type_name.*, self_type, generic_params, generic_args, depth + 1)
            else
                try primitive(typeContext(context), .void);
            const signature = try formatArrowCallableTypeSignature(displayContext(context), params, return_type);
            try context.output.generated_strings.append(allocator, signature);
            return callable(typeContext(context), .arrow, .cyna, params, return_type);
        }

        pub fn parseTypeWithBindings(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
            self_type: ?semantic_types.TypeId,
            generic_params: []const ast.GenericParam,
            generic_args: []const semantic_types.GenericArgument,
        ) Error!semantic_types.TypeId {
            return parseTypeDepth(context, path, program, current_module, type_name, self_type, generic_params, generic_args, 0);
        }

        pub fn parseType(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
        ) Error!semantic_types.TypeId {
            return parseTypeWithBindings(
                context,
                path,
                program,
                current_module,
                type_name,
                null,
                context.function_state.current_generic_params,
                context.function_state.current_generic_args,
            );
        }

        pub fn parseCanonicalType(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
        ) Error!semantic_types.TypeId {
            return parseType(context, path, program, current_module, type_name);
        }
    };
}

fn isCAbiScalarTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "c_char") or
        std.mem.eql(u8, name, "c_schar") or
        std.mem.eql(u8, name, "c_uchar") or
        std.mem.eql(u8, name, "c_short") or
        std.mem.eql(u8, name, "c_ushort") or
        std.mem.eql(u8, name, "c_int") or
        std.mem.eql(u8, name, "c_uint") or
        std.mem.eql(u8, name, "c_long") or
        std.mem.eql(u8, name, "c_ulong") or
        std.mem.eql(u8, name, "c_llong") or
        std.mem.eql(u8, name, "c_ullong") or
        std.mem.eql(u8, name, "c_float") or
        std.mem.eql(u8, name, "c_double") or
        std.mem.eql(u8, name, "c_ptrdiff_t") or
        std.mem.eql(u8, name, "c_size_t");
}

fn typeSuggestion(context: SourceContext, program: ast.Program, current_module: []const u8, name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = 3;
    var tied = false;
    for (program.structs) |decl| {
        if (declarations.resolution.canAccess(context.policy, current_module, decl.module_name, decl.is_pub)) declarations.considerNameSuggestion(name, decl.name, &best, &best_distance, &tied);
    }
    for (program.enums) |decl| {
        if (declarations.resolution.canAccess(context.policy, current_module, decl.module_name, decl.is_pub)) declarations.considerNameSuggestion(name, decl.name, &best, &best_distance, &tied);
    }
    for (program.unions) |decl| {
        if (declarations.resolution.canAccess(context.policy, current_module, decl.module_name, decl.is_pub)) declarations.considerNameSuggestion(name, decl.name, &best, &best_distance, &tied);
    }
    for (program.aliases) |decl| {
        if (declarations.resolution.canAccess(context.policy, current_module, decl.module_name, decl.is_pub)) declarations.considerNameSuggestion(name, decl.name, &best, &best_distance, &tied);
    }
    return if (tied) null else best;
}

fn moduleDefinesPublicType(program: ast.Program, module_name: []const u8, name: []const u8) bool {
    for (program.structs) |decl| if (decl.is_pub and std.mem.eql(u8, decl.module_name, module_name) and std.mem.eql(u8, decl.name, name)) return true;
    for (program.enums) |decl| if (decl.is_pub and std.mem.eql(u8, decl.module_name, module_name) and std.mem.eql(u8, decl.name, name)) return true;
    for (program.unions) |decl| if (decl.is_pub and std.mem.eql(u8, decl.module_name, module_name) and std.mem.eql(u8, decl.name, name)) return true;
    for (program.aliases) |decl| if (decl.is_pub and std.mem.eql(u8, decl.module_name, module_name) and std.mem.eql(u8, decl.name, name)) return true;
    return false;
}

fn qualificationSuggestion(program: ast.Program, current_module: []const u8, name: []const u8) ?[]const u8 {
    const info = declarations.resolution.moduleInfo(program, current_module) orelse return null;
    var found: ?[]const u8 = null;
    for (info.imports) |decl| {
        if (decl.items.len != 0 or !moduleDefinesPublicType(program, decl.path, name)) continue;
        const alias = declarations.resolution.importBindingLocalName(decl);
        if (found != null and !std.mem.eql(u8, found.?, alias)) return null;
        found = alias;
    }
    return found;
}

pub fn emitUnknownType(
    context: SourceContext,
    allocator: std.mem.Allocator,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    token: lexer.Token,
    name: []const u8,
    imported_module: bool,
) Error!void {
    const qualifier = if (!imported_module) qualificationSuggestion(program, current_module, name) else null;
    const suggestion = if (qualifier == null) typeSuggestion(context, program, current_module, name) else null;
    const help = if (qualifier) |alias|
        try std.fmt.allocPrint(allocator, "qualify the type as `{s}.{s}`", .{ alias, name })
    else if (suggestion) |candidate|
        try std.fmt.allocPrint(allocator, "did you mean `{s}`?", .{candidate})
    else if (imported_module)
        "export the type from that module or use a type it exposes"
    else
        "declare the type, import it by name, or qualify it through a module import";
    defer if (qualifier != null or suggestion != null) allocator.free(help);
    const notes = [_][]const u8{"type lookup is distinct from value and callable lookup"};
    if (imported_module) {
        try context.diagnostic_context.emitTokenWith(path, token, .{
            .code = .name_unknown_type,
            .notes = &notes,
            .help = help,
        }, "unknown type `{s}` in imported module", .{name});
    } else {
        try context.diagnostic_context.emitTokenWith(path, token, .{
            .code = .name_unknown_type,
            .notes = &notes,
            .help = help,
        }, "unknown type `{s}`", .{name});
    }
}

pub const BuiltinLenKind = enum {
    string,
    sequence,
    sparse,
    slice,
};

pub const BuiltinClearKind = enum {
    sequence,
    sparse,
};

pub const BuiltinContainsKind = enum {
    sparse_index,
};

pub const TypeIndexAccessRole = struct {
    key_type_id: semantic_types.TypeId,
    value_type_id: semantic_types.TypeId,
};

pub const TypeIterationRole = struct {
    item_type_id: semantic_types.TypeId,
};

pub const TypeBuiltinLenMethod = struct {
    owner_name: []const u8,
    kind: BuiltinLenKind,
};

pub const TypeBuiltinClearMethod = struct {
    owner_name: []const u8,
    receiver_name: []const u8,
    mutation_action: []const u8,
    kind: BuiltinClearKind,
};

pub const TypeBuiltinContainsMethod = struct {
    owner_name: []const u8,
    method_name: []const u8,
    arg_type_id: semantic_types.TypeId,
    kind: BuiltinContainsKind,
};

pub const TypeBuiltinInsertMethod = struct {
    owner_name: []const u8,
    receiver_name: []const u8,
    method_name: []const u8,
    mutation_action: []const u8,
    item_type_id: semantic_types.TypeId,
};

pub const TypeBuiltinReserveMethod = struct {
    owner_name: []const u8,
    receiver_name: []const u8,
    method_name: []const u8,
    mutation_action: []const u8,
};

pub const TypeBuiltinPopMethod = struct {
    owner_name: []const u8,
    receiver_name: []const u8,
    method_name: []const u8,
    mutation_action: []const u8,
    item_type_id: semantic_types.TypeId,
};

pub fn typeSliceViewItemType(context: Context, type_id: semantic_types.TypeId) ?semantic_types.TypeId {
    return switch (node(context, type_id).*) {
        .array => |array_value| array_value.item,
        .dense_array => |item| item,
        .slice => |slice_value| slice_value.item,
        else => null,
    };
}

pub fn typeIndexedAssignmentRoot(context: Context, type_id: semantic_types.TypeId) bool {
    return switch (node(context, type_id).*) {
        .array, .dense_array, .sparse_array => true,
        else => false,
    };
}

pub fn typeIndexAccessRole(context: Context, type_id: semantic_types.TypeId) Error!?TypeIndexAccessRole {
    const value_item_type = switch (node(context, type_id).*) {
        .array => |array_value| array_value.item,
        .dense_array, .sparse_array => |item| item,
        .slice => |slice_value| slice_value.item,
        else => return null,
    };
    const value_type = switch (node(context, type_id).*) {
        .sparse_array => try optional(context, value_item_type),
        .array, .dense_array, .slice => value_item_type,
        else => unreachable,
    };
    return .{
        .key_type_id = try inferredInteger(context),
        .value_type_id = value_type,
    };
}

pub fn typeIterationRole(context: Context, type_id: semantic_types.TypeId) Error!?TypeIterationRole {
    const item_type = switch (node(context, type_id).*) {
        .sparse_array => |item| try optional(context, item),
        .array => |array_value| array_value.item,
        .dense_array => |item| item,
        .slice => |slice_value| slice_value.item,
        else => null,
    };
    const resolved = item_type orelse return null;
    return .{ .item_type_id = resolved };
}

pub fn denseStorageLiteralItemType(context: Context, type_id: semantic_types.TypeId) ?semantic_types.TypeId {
    return switch (node(context, type_id).*) {
        .dense_array => |item_type_id| item_type_id,
        else => null,
    };
}

pub fn typeBuiltinLenMethod(context: Context, type_id: semantic_types.TypeId) ?TypeBuiltinLenMethod {
    return switch (typeKind(context, type_id)) {
        .string => .{ .owner_name = "string", .kind = .string },
        .dense_array => .{ .owner_name = "[:]", .kind = .sequence },
        .sparse_array => .{ .owner_name = "sparse", .kind = .sparse },
        .slice => .{ .owner_name = "slice", .kind = .slice },
        else => null,
    };
}

pub fn intrinsicReceiverForType(context: Context, type_id: semantic_types.TypeId) ?intrinsics.Receiver {
    return switch (typeKind(context, type_id)) {
        .string => .string,
        .dense_array => .sequence,
        .sparse_array => .sparse,
        .slice => .slice,
        .owned => .owned,
        else => null,
    };
}

pub fn typeBuiltinClearMethod(context: Context, type_id: semantic_types.TypeId) ?TypeBuiltinClearMethod {
    return switch (typeKind(context, type_id)) {
        .dense_array => .{
            .owner_name = "[:]",
            .receiver_name = "dense storage",
            .mutation_action = "mutate dense storage",
            .kind = .sequence,
        },
        .sparse_array => .{
            .owner_name = "sparse",
            .receiver_name = "sparse storage",
            .mutation_action = "mutate sparse storage",
            .kind = .sparse,
        },
        else => null,
    };
}

pub fn typeBuiltinContainsMethod(context: Context, type_id: semantic_types.TypeId) Error!?TypeBuiltinContainsMethod {
    return switch (typeKind(context, type_id)) {
        .sparse_array => .{
            .owner_name = "sparse",
            .method_name = "contains_index",
            .arg_type_id = try inferredInteger(context),
            .kind = .sparse_index,
        },
        else => null,
    };
}

pub fn typeBuiltinInsertMethod(context: Context, type_id: semantic_types.TypeId) Error!?TypeBuiltinInsertMethod {
    return switch (node(context, type_id).*) {
        .dense_array => |item_type_id| .{
            .owner_name = "[:]",
            .receiver_name = "dense storage",
            .method_name = "push",
            .mutation_action = "mutate dense storage",
            .item_type_id = item_type_id,
        },
        else => null,
    };
}

pub fn typeBuiltinReserveMethod(context: Context, type_id: semantic_types.TypeId) ?TypeBuiltinReserveMethod {
    return switch (typeKind(context, type_id)) {
        .dense_array => .{
            .owner_name = "[:]",
            .receiver_name = "dense storage",
            .method_name = "reserve",
            .mutation_action = "mutate dense storage",
        },
        else => null,
    };
}

pub fn typeBuiltinPopMethod(context: Context, type_id: semantic_types.TypeId) Error!?TypeBuiltinPopMethod {
    return switch (node(context, type_id).*) {
        .dense_array => |item_type_id| .{
            .owner_name = "[:]",
            .receiver_name = "dense storage",
            .method_name = "pop",
            .mutation_action = "mutate dense storage",
            .item_type_id = item_type_id,
        },
        else => null,
    };
}

pub fn expectArithmeticLike(context: DisplayContext, diagnostic_context: *diagnostics.Context, path: []const u8, token: lexer.Token, type_id: semantic_types.TypeId) Error!void {
    const kind = typeKind(context.types, type_id);
    if (kind == .int or kind == .float) return;
    const actual_name = try formatDisplay(context, type_id, .display);
    defer context.types.allocator.free(actual_name);
    const notes = [_][]const u8{"this operator requires an arithmetic operand"};
    try diagnostic_context.emitTokenWith(path, token, .{
        .code = .type_mismatch,
        .notes = &notes,
        .help = "use an integer or floating-point expression",
    }, "type mismatch: expected int or float, got {s}", .{actual_name});
    return Error.SemanticFailed;
}

pub fn expectSequenceEqualityElement(context: DisplayContext, diagnostic_context: *diagnostics.Context, path: []const u8, token: lexer.Token, type_id: semantic_types.TypeId) Error!void {
    const kind = typeKind(context.types, type_id);
    if (kind == .int or kind == .float or kind == .bool or kind == .string or kind == .@"enum") return;
    const actual_name = try formatDisplay(context, type_id, .display);
    defer context.types.allocator.free(actual_name);
    try diagnostic_context.emitToken(path, token, "sequence equality requires int, float, bool, string, or enum elements; got {s}", .{actual_name});
    return Error.SemanticFailed;
}

pub fn expectEqualitySupported(context: DisplayContext, diagnostic_context: *diagnostics.Context, path: []const u8, token: lexer.Token, type_id: semantic_types.TypeId) Error!void {
    switch (typeKind(context.types, type_id)) {
        .int, .float, .rune, .bool, .string, .@"enum", .raw, .ref => return,
        else => {},
    }
    const actual_name = try formatDisplay(context, type_id, .display);
    defer context.types.allocator.free(actual_name);
    try diagnostic_context.emitToken(path, token, "equality is not supported for type {s}", .{actual_name});
    return Error.SemanticFailed;
}

pub fn canonicalSequenceEqualityItemType(context: DisplayContext, left: semantic_types.TypeId, right: semantic_types.TypeId) ?semantic_types.TypeId {
    return switch (node(context.types, left).*) {
        .array => |left_array| switch (node(context.types, right).*) {
            .array => |right_array| if (left_array.len == right_array.len and left_array.item == right_array.item) left_array.item else null,
            else => null,
        },
        .dense_array => |left_item| switch (node(context.types, right).*) {
            .dense_array => |right_item| if (left_item == right_item) left_item else null,
            else => null,
        },
        .sparse_array => |left_item| switch (node(context.types, right).*) {
            .sparse_array => |right_item| if (left_item == right_item) left_item else null,
            else => null,
        },
        .slice => |left_slice| switch (node(context.types, right).*) {
            .slice => |right_slice| if (left_slice.item == right_slice.item) left_slice.item else null,
            else => null,
        },
        else => null,
    };
}

test "inline error unions intern by sorted enum declaration identity" {
    var interner = semantic_types.TypeInterner.init(std.testing.allocator);
    defer interner.deinit();
    var generated_strings: std.ArrayListUnmanaged([]const u8) = .empty;
    defer generated_strings.deinit(std.testing.allocator);
    const context = Context{
        .allocator = std.testing.allocator,
        .abi_layout = target_info.abiLayout(null),
        .interner = &interner,
        .generated_strings = &generated_strings,
    };
    const later = try nominal(context, .@"enum", @fromBackingInt(@intCast(21)), null);
    const earlier = try nominal(context, .@"enum", @fromBackingInt(@intCast(8)), null);
    const first = try errorUnion(context, &.{ later, earlier });
    const reversed = try errorUnion(context, &.{ earlier, later });
    try std.testing.expectEqual(first, reversed);
    try std.testing.expectEqualSlices(semantic_types.TypeId, &.{ earlier, later }, node(context, first).error_union);
    try std.testing.expectError(error.SemanticFailed, errorUnion(context, &.{ earlier, earlier }));
}

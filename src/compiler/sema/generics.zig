const std = @import("std");
const ast = @import("../parser/ast.zig");
const sir = @import("sir.zig");
const semantic_types = @import("types.zig");
const identity = @import("identity.zig");
const declarations = @import("declarations.zig");
const session = @import("session.zig");
const diagnostics = @import("../diagnostics.zig");
const protocols = @import("protocols.zig");
const lexer = @import("../lexer/lexer.zig");

pub fn typeNameContainsArrowCallable(type_name: ast.TypeName) bool {
    if (type_name.is_arrow_callable) return true;
    if (type_name.raw_target) |target| {
        if (typeNameContainsArrowCallable(target.*)) return true;
    }
    for (type_name.args) |arg| {
        if (typeNameContainsArrowCallable(arg)) return true;
    }
    for (type_name.function_params) |param| {
        if (typeNameContainsArrowCallable(param)) return true;
    }
    if (type_name.function_return_type) |return_type| {
        if (typeNameContainsArrowCallable(return_type.*)) return true;
    }
    return false;
}

pub fn isTypeParamName(params: []const ast.GenericParam, name: []const u8) bool {
    for (params) |param| {
        if (!param.is_const_value and std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

pub fn isArrayLenParamName(params: []const ast.GenericParam, name: []const u8) bool {
    for (params) |param| {
        if (param.is_const_value and std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

pub fn paramBindsName(param: ast.GenericParam, name: []const u8) bool {
    return std.mem.eql(u8, param.name, name);
}

pub fn typeArgForName(
    params: []const ast.GenericParam,
    args: []const semantic_types.GenericArgument,
    name: []const u8,
) ?semantic_types.TypeId {
    for (params, 0..) |param, i| {
        if (param.is_const_value or !std.mem.eql(u8, param.name, name)) continue;
        return switch (args[i]) {
            .type => |type_id| type_id,
            .const_usize => null,
        };
    }
    return null;
}

pub fn arrayLenForName(
    params: []const ast.GenericParam,
    args: []const semantic_types.GenericArgument,
    name: []const u8,
) ?usize {
    for (params, 0..) |param, i| {
        if (!param.is_const_value or !std.mem.eql(u8, param.name, name)) continue;
        return switch (args[i]) {
            .const_usize => |value| value,
            .type => null,
        };
    }
    return null;
}

pub fn typeNameContainsParam(type_name: ast.TypeName, params: []const ast.GenericParam) bool {
    if (isTypeParamName(params, type_name.name)) return true;
    if (type_name.raw_target) |target| {
        if (typeNameContainsParam(target.*, params)) return true;
    }
    if (type_name.array_len_name) |len_name| {
        if (isArrayLenParamName(params, len_name)) return true;
    }
    for (type_name.args) |arg| {
        if (typeNameContainsParam(arg, params)) return true;
    }
    for (type_name.function_params) |param| {
        if (typeNameContainsParam(param, params)) return true;
    }
    if (type_name.function_return_type) |return_type| {
        if (typeNameContainsParam(return_type.*, params)) return true;
    }
    return false;
}

pub fn argumentsEqual(
    a: ?[]const semantic_types.GenericArgument,
    b: ?[]const semantic_types.GenericArgument,
) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const lhs = a.?;
    const rhs = b.?;
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        switch (left) {
            .type => |left_type| if (left_type != right.type) return false,
            .const_usize => |left_value| if (left_value != right.const_usize) return false,
        }
    }
    return true;
}

pub fn findInstantiatedFunction(context: anytype, module_name: []const u8, owner: ?[]const u8, name: []const u8) ?sir.Function {
    for (context.generic.instantiated_functions.items) |function| {
        if (std.mem.eql(u8, function.module_name, module_name) and optionalNamesEqual(function.owner, owner) and std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn optionalNamesEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn instantiateFunction(
    context: anytype,
    allocator: std.mem.Allocator,
    path: []const u8,
    program: ast.Program,
    globals: anytype,
    function: ast.Function,
    inferred_args: []const semantic_types.GenericArgument,
    formatName: anytype,
    lowerNamed: anytype,
) !sir.Function {
    const instantiated_name = try formatName(context, function.name, inferred_args);
    if (findInstantiatedFunction(context, function.module_name, function.owner, instantiated_name)) |existing| {
        allocator.free(instantiated_name);
        return existing;
    }
    // Stage the name in the context-owned string list before registering the
    // declaration.  If registration fails, the name is already owned by
    // `generated_strings` and is released at teardown instead of leaking.
    context.output.generated_strings.append(allocator, instantiated_name) catch |err| {
        allocator.free(instantiated_name);
        return err;
    };
    // A generic function that references its own specialization (directly or
    // through another generic) would otherwise re-instantiate forever: the
    // lowered body only becomes discoverable after `lowerNamed` returns. We
    // publish an identity placeholder first so a re-entrant call settles to the
    // callee identity instead of lowering the body a second time.
    const decl_id = try declarations.registration.findOrRegisterGenerated(if (context.declarations.registry) |*registry| registry else null, function.module_name, function.owner, instantiated_name, .function);
    const placeholder_index = context.generic.instantiated_functions.items.len;
    const placeholder_body = try allocator.alloc(sir.Stmt, 0);
    errdefer allocator.free(placeholder_body);
    try context.generic.instantiated_functions.append(allocator, sir.Function{
        .decl_id = decl_id,
        .module_name = function.module_name,
        .owner = function.owner,
        .name = instantiated_name,
        .params = &.{},
        .return_type_id = null,
        .body = placeholder_body,
    });

    const saved_params = context.function_state.current_generic_params;
    const saved_args = context.function_state.current_generic_args;
    context.function_state.current_generic_params = function.type_params;
    context.function_state.current_generic_args = inferred_args;
    defer {
        context.function_state.current_generic_params = saved_params;
        context.function_state.current_generic_args = saved_args;
    }

    var lowered = try lowerNamed(context, allocator, path, program, globals, function, instantiated_name);
    lowered.decl_id = decl_id;
    allocator.free(placeholder_body);
    context.generic.instantiated_functions.items[placeholder_index] = lowered;
    return lowered;
}

pub fn instantiateStructMethod(
    context: anytype,
    allocator: std.mem.Allocator,
    path: []const u8,
    program: ast.Program,
    globals: anytype,
    lowered_owner: []const u8,
    method: ast.Function,
    type_params: []const ast.GenericParam,
    type_args: []const semantic_types.GenericArgument,
    formatName: anytype,
    lowerSpecialized: anytype,
) !sir.Function {
    const lowered_name = if (method.type_params.len == 0)
        method.name
    else
        try formatName(context, method.name, type_args[type_args.len - method.type_params.len ..]);
    if (findInstantiatedFunction(context, method.module_name, lowered_owner, lowered_name)) |existing| {
        if (method.type_params.len != 0) allocator.free(lowered_name);
        return existing;
    }
    if (method.type_params.len != 0) {
        context.output.generated_strings.append(allocator, lowered_name) catch |err| {
            allocator.free(lowered_name);
            return err;
        };
    }
    const decl_id = try declarations.registration.findOrRegisterGenerated(if (context.declarations.registry) |*registry| registry else null, method.module_name, lowered_owner, lowered_name, .function);
    const placeholder_index = context.generic.instantiated_functions.items.len;
    const placeholder_body = try allocator.alloc(sir.Stmt, 0);
    errdefer allocator.free(placeholder_body);
    try context.generic.instantiated_functions.append(allocator, sir.Function{
        .decl_id = decl_id,
        .module_name = method.module_name,
        .owner = lowered_owner,
        .name = lowered_name,
        .params = &.{},
        .return_type_id = null,
        .body = placeholder_body,
    });

    const saved_params = context.function_state.current_generic_params;
    const saved_args = context.function_state.current_generic_args;
    context.function_state.current_generic_params = type_params;
    context.function_state.current_generic_args = type_args;
    defer {
        context.function_state.current_generic_params = saved_params;
        context.function_state.current_generic_args = saved_args;
    }

    var lowered = try lowerSpecialized(context, allocator, path, program, globals, method, lowered_owner, lowered_name);
    lowered.decl_id = decl_id;
    allocator.free(placeholder_body);
    context.generic.instantiated_functions.items[placeholder_index] = lowered;
    return lowered;
}

/// Resolve one source argument against a generic parameter. Parsing a nested
/// type is a compile-time dependency on the type-resolution workflow.
pub fn resolveArgument(
    comptime SemaContext: type,
    comptime parseTypeDepth: anytype,
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    arg: ast.TypeName,
    param: ast.GenericParam,
    self_type: ?semantic_types.TypeId,
    generic_params: []const ast.GenericParam,
    generic_args: []const semantic_types.GenericArgument,
    depth: usize,
) error{ SemanticFailed, OutOfMemory }!semantic_types.GenericArgument {
    if (param.is_const_value) {
        if (arg.is_const_value_arg) {
            return .{ .const_usize = arg.const_value.? };
        }
        if (!arg.is_ref and !arg.is_owned and !arg.is_raw and !arg.is_volatile_raw and !arg.is_optional and !arg.is_function and !arg.is_arrow_callable and !arg.is_slice and arg.array_len == null and arg.array_len_name == null and arg.args.len == 0) {
            if (arrayLenForName(generic_params, generic_args, arg.name)) |value| {
                return .{ .const_usize = value };
            }
        }
        const notes = [_][]const u8{"this generic parameter is declared as a compile-time value parameter"};
        try context.diagnostic_context.emitTokenWith(path, arg.token, .{
            .code = .generic_argument_kind,
            .notes = &notes,
            .help = "pass a compile-time `usize` value in this generic argument position",
        }, "generic parameter `{s}` expects a compile-time `usize` value", .{param.name});
        return error.SemanticFailed;
    }

    if (arg.is_const_value_arg) {
        const notes = [_][]const u8{"this generic parameter is declared as a type parameter"};
        try context.diagnostic_context.emitTokenWith(path, arg.token, .{
            .code = .generic_argument_kind,
            .notes = &notes,
            .help = "pass a type in this generic argument position",
        }, "generic parameter `{s}` expects a type argument", .{param.name});
        return error.SemanticFailed;
    }
    return .{ .type = try parseTypeDepth(context, path, program, current_module, arg, self_type, generic_params, generic_args, depth) };
}

pub fn instantiateTypeAlias(
    comptime SemaContext: type,
    comptime Support: anytype,
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    alias: ast.TypeAlias,
    type_args: []const ast.TypeName,
    self_type: ?semantic_types.TypeId,
    generic_params: []const ast.GenericParam,
    generic_args: []const semantic_types.GenericArgument,
    depth: usize,
) error{ SemanticFailed, OutOfMemory }!semantic_types.TypeId {
    if (alias.type_params.len != type_args.len) {
        const token = if (type_args.len != 0) type_args[0].token else alias.name_token;
        try emitGenericArity(&context.diagnostic_context, path, program, token, alias.module_name, alias.name_token, .type_alias, alias.name, alias.type_params.len, type_args.len);
        return error.SemanticFailed;
    }

    const allocator = context.allocator;
    var lowered_args = try allocator.alloc(semantic_types.GenericArgument, type_args.len);
    defer allocator.free(lowered_args);
    for (type_args, 0..) |arg, i| {
        lowered_args[i] = try resolveArgument(SemaContext, Support.parseTypeDepth, context, path, program, current_module, arg, alias.type_params[i], self_type, generic_params, generic_args, depth + 1);
        if (!alias.type_params[i].is_const_value) {
            try protocols.expectGenericParamProtocolConformance(SemaContext, Support.typeIsOwnedForProtocol, context, path, program, alias.module_name, alias.type_params[i], arg.token, lowered_args[i].type);
        }
    }

    const target = try Support.parseTypeDepth(context, path, program, alias.module_name, alias.target, self_type, alias.type_params, lowered_args, depth + 1);
    const resolved = if (!alias.is_distinct)
        target
    else blk: {
        const target_kind = Support.canonicalTypeKind(context, target);
        if (target_kind == .@"struct" or target_kind == .@"enum" or target_kind == .@"union") {
            try context.diagnostic_context.emitToken(path, alias.name_token, "distinct aliases require scalar or pointer-like targets; use a wrapper declaration for aggregate types", .{});
            return error.SemanticFailed;
        }
        break :blk try Support.resolvedDistinctAliasType(context, alias, target);
    };
    try Support.recordCanonicalGenericAlias(context, alias, lowered_args, resolved);
    return resolved;
}

fn findInstantiatedStruct(comptime SemaContext: type, context: *SemaContext, name: []const u8) ?session.InstantiatedStructDecl {
    for (context.generic.instantiated_structs.items) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return decl;
    }
    return null;
}

pub fn formatInstantiatedStructName(comptime SemaContext: type, comptime appendCanonicalTypeDisplay: anytype, context: *SemaContext, base_name: []const u8, args: []const semantic_types.GenericArgument) error{ SemanticFailed, OutOfMemory }![]const u8 {
    const allocator = context.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, base_name);
    try buf.append(allocator, '<');
    for (args, 0..) |arg, i| {
        if (i != 0) try buf.appendSlice(allocator, ", ");
        switch (arg) {
            .type => |type_id| try appendCanonicalTypeDisplay(context, &buf, type_id, .key),
            .const_usize => |value| try buf.print(allocator, "{d}", .{value}),
        }
    }
    try buf.append(allocator, '>');
    return try buf.toOwnedSlice(allocator);
}

pub fn instantiateGenericStruct(
    comptime SemaContext: type,
    comptime Support: anytype,
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    decl: ast.StructDecl,
    type_args: []const ast.TypeName,
    self_type: ?semantic_types.TypeId,
    generic_params: []const ast.GenericParam,
    generic_args: []const semantic_types.GenericArgument,
) error{ SemanticFailed, OutOfMemory }!semantic_types.TypeId {
    if (decl.type_params.len != type_args.len) {
        const token = if (type_args.len != 0) type_args[0].token else decl.name_token;
        try emitGenericArity(&context.diagnostic_context, path, program, token, decl.module_name, decl.name_token, .@"struct", decl.name, decl.type_params.len, type_args.len);
        return error.SemanticFailed;
    }

    const allocator = context.allocator;
    var lowered_args = try allocator.alloc(semantic_types.GenericArgument, type_args.len);
    defer allocator.free(lowered_args);
    for (type_args, 0..) |arg, i| {
        lowered_args[i] = try resolveArgument(SemaContext, Support.parseTypeDepth, context, path, program, current_module, arg, decl.type_params[i], self_type, generic_params, generic_args, 0);
        if (!decl.type_params[i].is_const_value) {
            try protocols.expectGenericParamProtocolConformance(SemaContext, Support.typeIsOwnedForProtocol, context, path, program, decl.module_name, decl.type_params[i], arg.token, lowered_args[i].type);
        }
    }

    return instantiateGenericStructWithTypeArgs(SemaContext, Support, context, path, program, decl, lowered_args);
}

pub fn instantiateGenericStructWithTypeArgs(
    comptime SemaContext: type,
    comptime Support: anytype,
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    decl: ast.StructDecl,
    lowered_args: []const semantic_types.GenericArgument,
) error{ SemanticFailed, OutOfMemory }!semantic_types.TypeId {
    if (decl.type_params.len != lowered_args.len) {
        try emitGenericArity(&context.diagnostic_context, path, program, decl.name_token, decl.module_name, decl.name_token, .@"struct", decl.name, decl.type_params.len, lowered_args.len);
        return error.SemanticFailed;
    }
    const allocator = context.allocator;

    var inst_name = try formatInstantiatedStructName(SemaContext, Support.appendCanonicalTypeDisplay, context, decl.name, lowered_args);
    if (findInstantiatedStruct(SemaContext, context, inst_name)) |existing| {
        if (!std.mem.eql(u8, existing.module_name, decl.module_name)) {
            const qualified = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ decl.module_name, inst_name });
            allocator.free(inst_name);
            inst_name = qualified;
        }
    }
    if (findInstantiatedStruct(SemaContext, context, inst_name)) |existing| {
        allocator.free(inst_name);
        try protocols.materializeGenericImplConformances(SemaContext, Support.parseTypeDepth, Support.typeIsOwnedForProtocol, context, path, program, existing);
        return Support.canonicalInstantiatedStructTypeId(context, existing);
    }
    context.output.generated_strings.append(allocator, inst_name) catch |err| {
        allocator.free(inst_name);
        return err;
    };

    var fields: std.ArrayListUnmanaged(session.InstantiatedStructField) = .empty;
    errdefer fields.deinit(allocator);
    for (decl.fields) |field| {
        const field_ty = try Support.parseTypeDepth(context, path, program, decl.module_name, field.type_name, null, decl.type_params, lowered_args, 0);
        if (decl.layout == .c and Support.isPlainCStrTypeName(field.type_name)) {
            try context.diagnostic_context.emitToken(path, field.name_token, "`c_str` is a borrowed C string view and cannot be stored in a `c struct`; use `*const c_char` for stored C pointers", .{});
            return error.SemanticFailed;
        }
        if (decl.layout == .c and !try Support.canonicalTypeIsCStructFieldType(context, path, program, field_ty)) {
            try Support.emitCStructFieldTypeError(context, path, program, decl.module_name, field.name, field.name_token, field_ty);
            return error.SemanticFailed;
        }
        if (decl.layout == .@"packed") {
            if (try Support.packedFieldViolation(context, program, field_ty)) |violation| {
                try Support.emitPackedFieldViolation(context, path, field.name_token, field.name, violation);
                return error.SemanticFailed;
            }
        }
        try fields.append(allocator, .{
            .name = field.name,
            .type_id = field_ty,
            .default_value = field.default_value,
            .is_pub = field.is_pub,
        });
    }
    // A generated specialization keeps its declaration identity even after a
    // trial instantiation is discarded, so a repeated specialization reuses the
    // identity instead of colliding with the name already registered for it.
    const inst_id: ?identity.DeclId = declarations.registration.registerGenerated(if (context.declarations.registry) |*registry| registry else null, decl.module_name, null, inst_name, .@"struct") catch |err| switch (err) {
        error.SemanticFailed => declarations.registration.findOptional(if (context.declarations.registry) |*registry| registry else null, decl.module_name, null, inst_name, .@"struct") orelse return err,
        else => return err,
    };
    try context.generic.instantiated_structs.ensureUnusedCapacity(allocator, 1);
    const instantiated: session.InstantiatedStructDecl = blk: {
        const type_args = try allocator.dupe(semantic_types.GenericArgument, lowered_args);
        errdefer allocator.free(type_args);
        break :blk .{
            .id = inst_id,
            .base_decl_id = declarations.registration.findOptional(if (context.declarations.registry) |*registry| registry else null, decl.module_name, null, decl.name, .@"struct"),
            .name = inst_name,
            .base_name = decl.name,
            .module_name = decl.module_name,
            .layout = decl.layout,
            .is_shared_value = decl.is_shared_value,
            .is_owned_value = decl.is_owned_value,
            .is_sync_resource = decl.is_sync_resource,
            .type_args = type_args,
            .fields = try fields.toOwnedSlice(allocator),
        };
    };
    context.generic.instantiated_structs.appendAssumeCapacity(instantiated);
    try protocols.materializeGenericImplConformances(SemaContext, Support.parseTypeDepth, Support.typeIsOwnedForProtocol, context, path, program, instantiated);
    return Support.canonicalInstantiatedStructTypeId(context, instantiated);
}

fn genericDeclarationSpan(program: ast.Program, fallback_path: []const u8, module_name: []const u8, token: lexer.Token) diagnostics.SourceSpan {
    for (program.module_infos) |info| {
        if (std.mem.eql(u8, info.name, module_name) and info.source_path.len != 0)
            return diagnostics.SourceSpan.fromToken(info.source_path, token);
    }
    return diagnostics.SourceSpan.fromToken(fallback_path, token);
}

pub const GenericDeclKind = enum { function, method, @"struct", type_alias };

pub fn emitGenericArity(
    diagnostic_context: *diagnostics.Context,
    path: []const u8,
    program: ast.Program,
    token: lexer.Token,
    declaration_module: []const u8,
    declaration_token: lexer.Token,
    kind: GenericDeclKind,
    name: []const u8,
    expected: usize,
    actual: usize,
) error{ SemanticFailed, OutOfMemory }!void {
    const labels = [_]diagnostics.Label{.{
        .span = genericDeclarationSpan(program, path, declaration_module, declaration_token),
        .message = "generic declaration is here",
    }};
    const notes = [_][]const u8{"generic argument arity is fixed by the declaration"};
    const details: diagnostics.DiagnosticDetails = .{
        .code = .generic_arity,
        .labels = &labels,
        .notes = &notes,
        .help = "supply exactly one argument for each declared generic parameter",
    };
    switch (kind) {
        .function => try diagnostic_context.emitTokenWith(path, token, details, "generic function `{s}` expects {d} generic arguments, got {d}", .{ name, expected, actual }),
        .method => try diagnostic_context.emitTokenWith(path, token, details, "generic method `{s}` expects {d} generic arguments, got {d}", .{ name, expected, actual }),
        .@"struct" => try diagnostic_context.emitTokenWith(path, token, details, "generic struct `{s}` expects {d} type arguments, got {d}", .{ name, expected, actual }),
        .type_alias => try diagnostic_context.emitTokenWith(path, token, details, "generic type alias `{s}` expects {d} type arguments, got {d}", .{ name, expected, actual }),
    }
}

pub fn emitGenericInferenceFailure(
    diagnostic_context: *diagnostics.Context,
    path: []const u8,
    program: ast.Program,
    declaration_module: []const u8,
    param: ast.GenericParam,
    owner_kind: GenericDeclKind,
) error{ SemanticFailed, OutOfMemory }!void {
    const labels = [_]diagnostics.Label{.{
        .span = genericDeclarationSpan(program, path, declaration_module, param.name_token),
        .message = "uninferred generic parameter declared here",
    }};
    const notes = [_][]const u8{"no call argument provided a unique substitution for this parameter"};
    const details: diagnostics.DiagnosticDetails = .{
        .code = .generic_inference,
        .labels = &labels,
        .notes = &notes,
        .help = "provide explicit generic arguments or pass an argument whose type determines this parameter",
    };
    switch (owner_kind) {
        .function => try diagnostic_context.emitTokenWith(path, param.name_token, details, "could not infer generic parameter `{s}` from call arguments", .{param.name}),
        .method => try diagnostic_context.emitTokenWith(path, param.name_token, details, "could not infer generic parameter `{s}` from method arguments", .{param.name}),
        else => unreachable,
    }
}

pub fn validateGenericParams(comptime SemaContext: type, context: *SemaContext, path: []const u8, program: ast.Program, current_module: []const u8, params: []const ast.GenericParam) error{ SemanticFailed, OutOfMemory }!void {
    for (params, 0..) |param, i| {
        for (params[0..i]) |existing| {
            if (std.mem.eql(u8, existing.name, param.name)) {
                const labels = [_]diagnostics.Label{.{
                    .span = diagnostics.SourceSpan.fromToken(path, existing.name_token),
                    .message = "first generic parameter declared here",
                }};
                const notes = [_][]const u8{"generic parameter names must be unique within one declaration"};
                try context.diagnostic_context.emitTokenWith(path, param.name_token, .{
                    .code = .duplicate_declaration,
                    .labels = &labels,
                    .notes = &notes,
                    .help = "rename one of the generic parameters",
                }, "duplicate generic parameter `{s}`", .{param.name});
                return error.SemanticFailed;
            }
        }
        if (std.mem.eql(u8, param.name, "Self")) {
            try context.diagnostic_context.emitToken(path, param.name_token, "`Self` is reserved for protocol method signatures", .{});
            return error.SemanticFailed;
        }
        if (param.is_const_value) {
            const value_type = param.constraint orelse {
                try context.diagnostic_context.emitToken(path, param.name_token, "const generic parameter `{s}` requires a value type", .{param.name});
                return error.SemanticFailed;
            };
            if (value_type.is_ref or value_type.is_owned or value_type.is_raw or value_type.is_volatile_raw or value_type.is_optional or value_type.is_slice or value_type.array_len != null or value_type.array_len_name != null or value_type.args.len != 0 or !std.mem.eql(u8, value_type.name, "usize")) {
                try context.diagnostic_context.emitToken(path, value_type.token, "const generic parameters require type `usize`", .{});
                return error.SemanticFailed;
            }
            continue;
        }
        try protocols.validateGenericParamProtocolConstraints(protocols.contextFromSession(SemaContext, context), path, program, current_module, param);
    }
}

pub fn combineGenericParams(comptime SemaContext: type, context: *SemaContext, path: []const u8, base: []const ast.GenericParam, extra: []const ast.GenericParam) error{ SemanticFailed, OutOfMemory }![]ast.GenericParam {
    const allocator = context.allocator;
    var combined = try allocator.alloc(ast.GenericParam, base.len + extra.len);
    errdefer allocator.free(combined);
    @memcpy(combined[0..base.len], base);
    for (extra, 0..) |param, i| {
        for (base) |existing| {
            if (paramBindsName(existing, param.name)) {
                const labels = [_]diagnostics.Label{.{
                    .span = diagnostics.SourceSpan.fromToken(path, existing.name_token),
                    .message = "enclosing generic parameter declared here",
                }};
                const notes = [_][]const u8{"method generic parameters cannot shadow enclosing type parameters"};
                try context.diagnostic_context.emitTokenWith(path, param.name_token, .{
                    .code = .duplicate_declaration,
                    .labels = &labels,
                    .notes = &notes,
                    .help = "rename the method generic parameter",
                }, "generic parameter `{s}` conflicts with an enclosing generic parameter", .{param.name});
                return error.SemanticFailed;
            }
        }
        combined[base.len + i] = param;
    }
    return combined;
}

pub fn combineGenericArgs(comptime SemaContext: type, context: *SemaContext, base: []const semantic_types.GenericArgument, extra: []const semantic_types.GenericArgument) error{ SemanticFailed, OutOfMemory }![]semantic_types.GenericArgument {
    const allocator = context.allocator;
    var combined = try allocator.alloc(semantic_types.GenericArgument, base.len + extra.len);
    errdefer allocator.free(combined);
    @memcpy(combined[0..base.len], base);
    @memcpy(combined[base.len .. base.len + extra.len], extra);
    return combined;
}

pub fn recordAdmission(
    comptime SemaContext: type,
    context: *SemaContext,
    path: []const u8,
    token: lexer.Token,
    details: diagnostics.DiagnosticDetails,
    comptime fmt: []const u8,
    args: anytype,
) error{ SemanticFailed, OutOfMemory }!void {
    try context.diagnostic_context.emitTokenWith(path, token, details, fmt, args);
    if (context.generic.generic_admission_failure != null) return;
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print(fmt, args) catch return;
    const message = context.allocator.dupe(u8, writer.buffered()) catch return;
    errdefer context.allocator.free(message);
    const labels = if (details.labels.len > 0) context.allocator.dupe(diagnostics.Label, details.labels) catch return else &.{};
    errdefer if (labels.len > 0) context.allocator.free(labels);
    const help = if (details.help) |text| context.allocator.dupe(u8, text) catch null else null;
    context.generic.generic_admission_failure = .{
        .path = path,
        .token = token,
        .code = details.code,
        .message = message,
        .labels = labels,
        .help = help,
    };
}

pub const shapes = struct {
    /// Definition-site provenance, not a constraint inferred from a concrete type.
    pub const Origin = struct {
        parameter: ast.GenericParam,
        module_name: []const u8,
        owned_wrapper: bool = false,
        projected: bool = false,
    };

    pub const Shape = union(enum) {
        unknown,
        known,
        number_literal,
        parameter: Origin,
        projection: Origin,
        nominal: struct { declaration: identity.DeclId, args: []const *const Shape },
        wrapper: struct { kind: Wrapper, child: *const Shape },
        result: struct { ok: *const Shape, err: *const Shape },
        callable: struct { params: []const *const Shape, result: *const Shape },
        alternatives: struct { left: *const Shape, right: *const Shape },

        pub const Wrapper = enum { ref_, owned, raw, optional, array, slice, dense, sparse };

        pub fn receiver(self: *const Shape) ?Origin {
            var current = self;
            var owned = false;
            while (current.* == .wrapper) {
                switch (current.wrapper.kind) {
                    .ref_ => {},
                    .owned => owned = true,
                    else => return null,
                }
                current = current.wrapper.child;
            }
            var origin = switch (current.*) {
                .parameter => |origin| origin,
                .projection => |origin| origin,
                else => return null,
            };
            origin.projected = origin.projected or current.* == .projection;
            origin.owned_wrapper = owned;
            return origin;
        }

        pub fn unborrow(self: *const Shape) *const Shape {
            var current = self;
            while (current.* == .wrapper and (current.wrapper.kind == .ref_ or current.wrapper.kind == .owned)) current = current.wrapper.child;
            return current;
        }
    };

    /// Match a declaration's symbolic signature, never its concrete substitution.
    /// Parameter identity includes its definition token and module, so same-named
    /// caller and callee parameters do not become interchangeable by spelling.
    pub fn infer(store: *Store, allocator: std.mem.Allocator, formal: *const Shape, actual: *const Shape, parameters: []const ast.GenericParam, module_name: []const u8, bindings: []*const Shape) error{OutOfMemory}!void {
        if (formal.* == .parameter) {
            for (parameters, bindings) |parameter, *binding| {
                if (parameter.is_const_value or !std.mem.eql(u8, formal.parameter.module_name, module_name) or
                    parameter.name_token.offset != formal.parameter.parameter.name_token.offset or
                    !std.mem.eql(u8, parameter.name, formal.parameter.parameter.name)) continue;
                if (binding.*.* == .unknown) binding.* = actual;
            }
            return;
        }
        if (formal.* == .wrapper) {
            if (actual.* == .wrapper and formal.wrapper.kind == actual.wrapper.kind) {
                try infer(store, allocator, formal.wrapper.child, actual.wrapper.child, parameters, module_name, bindings);
            } else if (formal.wrapper.kind == .ref_) {
                try infer(store, allocator, formal.wrapper.child, actual.unborrow(), parameters, module_name, bindings);
            } else if (actual.receiver() != null) {
                try infer(store, allocator, formal.wrapper.child, try store.project(allocator, actual), parameters, module_name, bindings);
            }
            return;
        }
        if (formal.* == .nominal and actual.* == .nominal and formal.nominal.declaration == actual.nominal.declaration and formal.nominal.args.len == actual.nominal.args.len) {
            for (formal.nominal.args, actual.nominal.args) |expected, received| try infer(store, allocator, expected, received, parameters, module_name, bindings);
        } else if (formal.* == .result and actual.* == .result) {
            try infer(store, allocator, formal.result.ok, actual.result.ok, parameters, module_name, bindings);
            try infer(store, allocator, formal.result.err, actual.result.err, parameters, module_name, bindings);
        } else if (formal.* == .callable and actual.* == .callable and formal.callable.params.len == actual.callable.params.len) {
            for (formal.callable.params, actual.callable.params) |expected, received| try infer(store, allocator, expected, received, parameters, module_name, bindings);
            try infer(store, allocator, formal.callable.result, actual.callable.result, parameters, module_name, bindings);
        } else if ((formal.* == .nominal or formal.* == .result or formal.* == .callable) and actual.receiver() != null) {
            const projected = try store.project(allocator, actual);
            switch (formal.*) {
                .nominal => |nominal| for (nominal.args) |arg| try infer(store, allocator, arg, projected, parameters, module_name, bindings),
                .result => |result| {
                    try infer(store, allocator, result.ok, projected, parameters, module_name, bindings);
                    try infer(store, allocator, result.err, projected, parameters, module_name, bindings);
                },
                .callable => |callable| {
                    for (callable.params) |arg| try infer(store, allocator, arg, projected, parameters, module_name, bindings);
                    try infer(store, allocator, callable.result, projected, parameters, module_name, bindings);
                },
                else => {},
            }
        }
    }

    pub const unknown: Shape = .unknown;
    pub const known: Shape = .known;
    pub const number_literal: Shape = .number_literal;

    /// Shapes borrow declaration data but own their graph edges. Their arena lives
    /// through semantic analysis, including nested instantiations and summaries.
    pub const Store = struct {
        arena: ?std.heap.ArenaAllocator = null,

        pub fn allocator(self: *Store, backing: std.mem.Allocator) std.mem.Allocator {
            if (self.arena == null) self.arena = std.heap.ArenaAllocator.init(backing);
            return self.arena.?.allocator();
        }

        pub fn add(self: *Store, backing: std.mem.Allocator, value: Shape) !*const Shape {
            const result = try self.allocator(backing).create(Shape);
            result.* = value;
            return result;
        }

        pub fn wrap(self: *Store, backing: std.mem.Allocator, kind: Shape.Wrapper, child: *const Shape) !*const Shape {
            return self.add(backing, .{ .wrapper = .{ .kind = kind, .child = child } });
        }

        pub fn project(self: *Store, backing: std.mem.Allocator, source: *const Shape) !*const Shape {
            if (source.* == .alternatives) return self.add(backing, .{ .alternatives = .{
                .left = try self.project(backing, source.alternatives.left),
                .right = try self.project(backing, source.alternatives.right),
            } });
            var origin = source.receiver() orelse return &unknown;
            origin.projected = true;
            origin.owned_wrapper = false;
            return self.add(backing, .{ .projection = origin });
        }

        pub fn deinit(self: *Store) void {
            if (self.arena) |*arena| arena.deinit();
            self.* = .{};
        }
    };
};

/// Admit generic declarations: validate the type patterns a generic
/// declaration is allowed to mention before instantiation begins.
pub const admission = struct {
    pub fn Owner(comptime host: anytype) type {
        return struct {
            const SemaContext = host.SemaContext;
            const SemaError = host.SemaError;
            const parseCanonicalType = host.parseCanonicalType;
            const canonicalTypeKind = host.canonicalTypeKind;
            const validateTypeName = host.validateTypeName;

            fn isInvalidDenseStorageItemType(context: *SemaContext, type_id: semantic_types.TypeId) bool {
                const kind = canonicalTypeKind(context, type_id);
                return kind == .void or kind == .ref;
            }

            pub fn checkGenericDecls(context: *SemaContext, path: []const u8, program: ast.Program) SemaError!void {
                for (program.structs) |decl| {
                    try validateGenericParams(SemaContext, context, path, program, decl.module_name, decl.type_params);
                    for (decl.fields) |field| {
                        try validateTypeName(context, path, program, decl.module_name, field.type_name, decl.type_params, null);
                        try rejectArrowCallableTypeName(context, path, field.name_token, field.type_name, "struct field");
                    }
                    for (decl.methods) |method| {
                        try validateGenericParams(SemaContext, context, path, program, method.module_name, method.type_params);
                        const combined_params = try combineGenericParams(SemaContext, context, path, decl.type_params, method.type_params);
                        defer context.allocator.free(combined_params);
                        for (method.params) |param| {
                            try validateTypeName(context, path, program, method.module_name, param.type_name, combined_params, null);
                        }
                        if (method.return_type) |return_type| {
                            try validateTypeName(context, path, program, method.module_name, return_type, combined_params, null);
                            try rejectArrowCallableTypeName(context, path, method.name_token, return_type, "function return");
                        }
                    }
                }

                for (program.functions) |function| {
                    try validateGenericParams(SemaContext, context, path, program, function.module_name, function.type_params);
                    if (function.is_sequence_literal_factory) {
                        const return_pattern = function.return_type.?;
                        const item_pattern = function.params[0].type_name.args[0];
                        if ((!typeNameContainsParam(return_pattern, function.type_params) and
                            canonicalTypeKind(context, try parseCanonicalType(context, path, program, function.module_name, return_pattern)) == .void) or
                            (!typeNameContainsParam(item_pattern, function.type_params) and
                                isInvalidDenseStorageItemType(context, try parseCanonicalType(context, path, program, function.module_name, item_pattern))))
                        {
                            try context.diagnostic_context.emitToken(path, function.name_token, "attribute `syntax.sequence_literal` requires a valid owned-storage item type and a non-void return type", .{});
                            return SemaError.SemanticFailed;
                        }
                    }
                    if (function.return_type) |return_type| {
                        try rejectArrowCallableTypeName(context, path, function.name_token, return_type, "function return");
                    }
                    if (function.type_params.len == 0) continue;
                    for (function.params) |param| {
                        try validateTypeName(context, path, program, function.module_name, param.type_name, function.type_params, null);
                    }
                    if (function.return_type) |return_type| {
                        try validateTypeName(context, path, program, function.module_name, return_type, function.type_params, null);
                    }
                }

                for (program.impls) |decl| {
                    if (decl.type_params.len == 0) continue;
                    try validateGenericParams(SemaContext, context, path, program, decl.module_name, decl.type_params);
                    try validateTypeName(context, path, program, decl.module_name, decl.type_name, decl.type_params, null);
                    for (decl.associated_types) |binding| {
                        try validateTypeName(context, path, program, decl.module_name, binding.type_name, decl.type_params, null);
                    }
                    for (decl.methods) |method| {
                        for (method.params) |param| {
                            try validateTypeName(context, path, program, method.module_name, param.type_name, decl.type_params, null);
                        }
                        if (method.return_type) |return_type| {
                            try validateTypeName(context, path, program, method.module_name, return_type, decl.type_params, null);
                            try rejectArrowCallableTypeName(context, path, method.name_token, return_type, "protocol implementation return");
                        }
                    }
                }
            }

            pub fn rejectArrowCallableTypeName(sema: *SemaContext, path: []const u8, token: lexer.Token, type_name: ast.TypeName, use_context: []const u8) SemaError!void {
                if (!typeNameContainsArrowCallable(type_name)) return;
                try sema.diagnostic_context.emitToken(
                    path,
                    token,
                    "non-escaping callable types are valid only as function parameters because their capture environment is call-local; `{s}` cannot use one; use `fn(...)` for a non-capturing stored callback, or store explicit context beside the function pointer",
                    .{use_context},
                );
                return SemaError.SemanticFailed;
            }
        };
    }
};

pub const ResolvedMethodInstantiation = struct {
    decl_id: identity.DeclId,
    owner: ?[]const u8,
    name: []const u8,
    params: []const ast.GenericParam,
    args: []const semantic_types.GenericArgument,
    owns_bindings: bool,
};

/// Settle a method call against its struct owner: resolve explicit or inferred
/// generic arguments, combine them with the owner's specialization, and return
/// the concrete lowered method identity the body walker records.
pub const instantiation = struct {
    pub fn Owner(comptime host: anytype) type {
        return struct {
            const SemaContext = host.SemaContext;
            const SemaError = host.SemaError;
            const GlobalBinding = host.GlobalBinding;
            const TypedExpr = host.TypedExpr;
            const registeredDeclId = host.registeredDeclId;
            const instantiateGenericStructMethodForCall = host.instantiateGenericStructMethodForCall;
            const resolveExplicitGenericArgs = host.resolveExplicitGenericArgs;
            const unifyGenericBinding = host.unifyGenericBinding;
            const typeIsOwnedForProtocol = host.typeIsOwnedForProtocol;

            pub fn instantiateMethodCall(
                context: *SemaContext,
                allocator: std.mem.Allocator,
                path: []const u8,
                program: ast.Program,
                globals: []const GlobalBinding,
                current_module: []const u8,
                lowered_owner: []const u8,
                method_token: lexer.Token,
                method: ast.Function,
                base_params: []const ast.GenericParam,
                base_args: []const semantic_types.GenericArgument,
                explicit_type_args: []const ast.TypeName,
                inferred_type_args: ?[]const TypedExpr,
            ) SemaError!ResolvedMethodInstantiation {
                if (method.type_params.len == 0) {
                    if (explicit_type_args.len != 0) {
                        try context.diagnostic_context.emitToken(path, method_token, "method `{s}` does not accept explicit type arguments", .{method.name});
                        return SemaError.SemanticFailed;
                    }
                    if (base_params.len != 0) {
                        const concrete = try instantiateGenericStructMethodForCall(context, allocator, path, program, globals, lowered_owner, method_token, method, base_params, base_args);
                        return .{
                            .decl_id = concrete.decl_id orelse return error.SemanticFailed,
                            .owner = concrete.owner,
                            .name = concrete.name,
                            .params = base_params,
                            .args = base_args,
                            .owns_bindings = false,
                        };
                    }
                    return .{
                        .decl_id = try registeredDeclId(context, method.module_name, method.owner, method.name, .function),
                        .owner = lowered_owner,
                        .name = method.name,
                        .params = base_params,
                        .args = base_args,
                        .owns_bindings = false,
                    };
                }
                const method_args = if (explicit_type_args.len != 0)
                    try resolveExplicitGenericArgs(context, path, program, current_module, method, explicit_type_args)
                else if (inferred_type_args) |actual_args|
                    try inferGenericArgsFromMethodCall(context, path, program, current_module, method, actual_args)
                else {
                    try context.diagnostic_context.emitToken(path, method_token, "generic method `{s}` requires explicit type arguments or inferrable arguments", .{method.name});
                    return SemaError.SemanticFailed;
                };
                defer context.allocator.free(method_args);
                const combined_params = try combineGenericParams(SemaContext, context, path, base_params, method.type_params);
                errdefer context.allocator.free(combined_params);
                const combined_args = try combineGenericArgs(SemaContext, context, base_args, method_args);
                errdefer context.allocator.free(combined_args);
                const concrete = try instantiateGenericStructMethodForCall(context, allocator, path, program, globals, lowered_owner, method_token, method, combined_params, combined_args);
                return .{
                    .decl_id = concrete.decl_id orelse return error.SemanticFailed,
                    .owner = concrete.owner,
                    .name = concrete.name,
                    .params = combined_params,
                    .args = combined_args,
                    .owns_bindings = true,
                };
            }

            fn inferGenericArgsFromMethodCall(
                context: *SemaContext,
                path: []const u8,
                program: ast.Program,
                current_module: []const u8,
                method: ast.Function,
                actual_args: []const TypedExpr,
            ) SemaError![]semantic_types.GenericArgument {
                _ = current_module;
                const allocator = context.allocator;
                const inferred = try allocator.alloc(?semantic_types.GenericArgument, method.type_params.len);
                defer allocator.free(inferred);
                @memset(inferred, null);

                for (method.params[1..], actual_args) |param, actual| {
                    try unifyGenericBinding(context, path, program, method.module_name, param.type_name, actual.type_id, method.type_params, inferred);
                }

                var result = try allocator.alloc(semantic_types.GenericArgument, method.type_params.len);
                errdefer allocator.free(result);
                for (method.type_params, inferred, 0..) |param, maybe_ty, i| {
                    const ty = maybe_ty orelse {
                        try emitGenericInferenceFailure(&context.diagnostic_context, path, program, method.module_name, param, .method);
                        return SemaError.SemanticFailed;
                    };
                    if (!param.is_const_value) {
                        try protocols.expectGenericParamProtocolConformance(SemaContext, typeIsOwnedForProtocol, context, path, program, method.module_name, param, param.name_token, ty.type);
                    }
                    result[i] = ty;
                }
                return result;
            }
        };
    }
};

test "generic shape authority distinguishes parameter from nominal with parameter arguments" {
    var store: shapes.Store = .{};
    defer store.deinit();
    const origin: shapes.Origin = .{ .module_name = "caller", .parameter = .{ .name = "T", .constraint = null, .name_token = std.mem.zeroes(@import("../lexer/token.zig").Token) } };
    const parameter = try store.add(std.testing.allocator, .{ .parameter = origin });
    const borrowed = try store.wrap(std.testing.allocator, .ref_, parameter);
    try std.testing.expectEqualStrings("caller", borrowed.receiver().?.module_name);
    const owned = try store.wrap(std.testing.allocator, .owned, parameter);
    try std.testing.expect(owned.receiver().?.owned_wrapper);
    const array = try store.wrap(std.testing.allocator, .array, parameter);
    try std.testing.expect(array.receiver() == null);
    const nominal = try store.add(std.testing.allocator, .{ .nominal = .{ .declaration = @fromBackingInt(@intCast(7)), .args = &.{parameter} } });
    try std.testing.expect(nominal.receiver() == null);
    const raw = try store.wrap(std.testing.allocator, .raw, parameter);
    try std.testing.expect(raw.receiver() == null);
    const projected = try store.project(std.testing.allocator, parameter);
    try std.testing.expect(projected.receiver().?.projected);
    const projected_ref = try store.wrap(std.testing.allocator, .ref_, projected);
    try std.testing.expect(projected_ref.receiver().?.projected);
}

test "generic shape projection preserves every alternative origin" {
    var store: shapes.Store = .{};
    defer store.deinit();
    const token = std.mem.zeroes(@import("../lexer/token.zig").Token);
    const a = try store.add(std.testing.allocator, .{ .parameter = .{ .module_name = "caller", .parameter = .{ .name = "A", .constraint = null, .name_token = token } } });
    const b = try store.add(std.testing.allocator, .{ .parameter = .{ .module_name = "caller", .parameter = .{ .name = "B", .constraint = null, .name_token = token } } });
    const c = try store.add(std.testing.allocator, .{ .parameter = .{ .module_name = "caller", .parameter = .{ .name = "C", .constraint = null, .name_token = token } } });
    const inner = try store.add(std.testing.allocator, .{ .alternatives = .{ .left = a, .right = b } });
    const outer = try store.add(std.testing.allocator, .{ .alternatives = .{ .left = inner, .right = c } });
    const projected = try store.project(std.testing.allocator, outer);
    try std.testing.expectEqualStrings("A", projected.alternatives.left.alternatives.left.receiver().?.parameter.name);
    try std.testing.expectEqualStrings("B", projected.alternatives.left.alternatives.right.receiver().?.parameter.name);
    try std.testing.expectEqualStrings("C", projected.alternatives.right.receiver().?.parameter.name);
    try std.testing.expect(projected.alternatives.left.alternatives.left.receiver().?.projected);
    try std.testing.expect(projected.alternatives.left.alternatives.right.receiver().?.projected);
    try std.testing.expect(projected.alternatives.right.receiver().?.projected);
}

test "generic shape inference preserves caller identity through nominal and callable signatures" {
    var store: shapes.Store = .{};
    defer store.deinit();
    var parameter: ast.GenericParam = .{ .name = "T", .constraint = null, .name_token = std.mem.zeroes(@import("../lexer/token.zig").Token) };
    parameter.name_token.offset = 12;
    var caller_parameter = parameter;
    caller_parameter.name_token.offset = 34;
    const formal = try store.add(std.testing.allocator, .{ .parameter = .{ .parameter = parameter, .module_name = "callee" } });
    const actual = try store.add(std.testing.allocator, .{ .parameter = .{ .parameter = caller_parameter, .module_name = "caller" } });
    const expected = try store.add(std.testing.allocator, .{ .nominal = .{ .declaration = @fromBackingInt(@intCast(7)), .args = &.{formal} } });
    const received = try store.add(std.testing.allocator, .{ .nominal = .{ .declaration = @fromBackingInt(@intCast(7)), .args = &.{actual} } });
    var bindings = [_]*const shapes.Shape{&shapes.unknown};
    try shapes.infer(&store, std.testing.allocator, expected, received, &.{parameter}, "callee", &bindings);
    try std.testing.expect(bindings[0] == actual);
    try std.testing.expectEqualStrings("caller", bindings[0].receiver().?.module_name);
    bindings[0] = &shapes.unknown;
    try shapes.infer(&store, std.testing.allocator, actual, formal, &.{parameter}, "callee", &bindings);
    try std.testing.expect(bindings[0] == &shapes.unknown);
    const formal_callable = try store.add(std.testing.allocator, .{ .callable = .{ .params = &.{formal}, .result = formal } });
    const actual_callable = try store.add(std.testing.allocator, .{ .callable = .{ .params = &.{actual}, .result = actual } });
    try shapes.infer(&store, std.testing.allocator, formal_callable, actual_callable, &.{parameter}, "callee", &bindings);
    try std.testing.expect(bindings[0] == actual);
    bindings[0] = &shapes.unknown;
    const raw_formal = try store.wrap(std.testing.allocator, .raw, formal);
    try shapes.infer(&store, std.testing.allocator, raw_formal, actual, &.{parameter}, "callee", &bindings);
    try std.testing.expect(bindings[0].receiver().?.projected);
    try std.testing.expectEqualStrings("caller", bindings[0].receiver().?.module_name);
}

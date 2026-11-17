const type_resolution = @import("type_resolution.zig");
const std = @import("std");
const ast = @import("../parser/ast.zig");
const diagnostics = @import("../diagnostics.zig");
const identity = @import("identity.zig");
const semantic_types = @import("types.zig");
const intrinsics = @import("../intrinsics.zig");
const session = @import("session.zig");
const generics = @import("generics.zig");
const name_resolution = resolution;

pub const CheckError = error{ SemanticFailed, OutOfMemory };

pub const ResolvedFunction = struct {
    id: ?identity.DeclId,
    decl: ast.Function,
    impl_decl: ?ast.ImplDecl = null,
    generic_params: ?[]const ast.GenericParam = null,
    generic_args: ?[]const semantic_types.GenericArgument = null,
};

/// Resolve an AST function after admission. The caller supplies the base of a
/// specialized owner, if any, so this owner does not depend on generic state.
pub fn findFunctionDecl(
    program: ast.Program,
    policy: resolution.AccessPolicy,
    instantiated_base_name: ?[]const u8,
    requester_module: []const u8,
    owner: ?[]const u8,
    name: []const u8,
) ?ast.Function {
    if (owner) |owner_name| {
        // A qualified module call can share its spelling with a synthetic
        // namespace struct introduced by a consumer's dependency import.
        // Resolve the module's free function before treating the owner as a
        // struct namespace.
        for (program.functions) |function| {
            if (function.owner == null and
                std.mem.eql(u8, function.module_name, owner_name) and
                std.mem.eql(u8, function.name, name) and
                resolution.canAccess(policy, requester_module, function.module_name, function.is_pub)) return function;
        }
        // Qualified owners have already passed import resolution. Loader
        // module names may omit that owner's dependency package prefix.
        // Refuse an ambiguous suffix rather than selecting by load order.
        var suffix_match: ?ast.Function = null;
        for (program.functions) |function| {
            if (function.owner != null or !std.mem.eql(u8, function.name, name) or
                owner_name.len <= function.module_name.len or
                !std.mem.endsWith(u8, owner_name, function.module_name) or
                owner_name[owner_name.len - function.module_name.len - 1] != '.') continue;
            if (!resolution.canAccess(policy, requester_module, function.module_name, function.is_pub)) continue;
            if (suffix_match != null) return null;
            suffix_match = function;
        }
        if (suffix_match) |function| return function;
        // Calls made inside a dependency may use the relative owner while
        // the loader stores the function under its package-prefixed module.
        if (std.mem.indexOfScalar(u8, requester_module, '.')) |prefix_len| {
            if (resolution.moduleInfo(program, requester_module)) |module_info| {
                for (module_info.imports) |import_decl| {
                    if (!std.mem.endsWith(u8, import_decl.path, owner_name) or
                        (import_decl.path.len > owner_name.len and import_decl.path[import_decl.path.len - owner_name.len - 1] != '.')) continue;
                    for (program.functions) |function| {
                        if (function.owner != null or !std.mem.eql(u8, function.name, name) or
                            function.module_name.len != prefix_len + 1 + owner_name.len or
                            !std.mem.eql(u8, function.module_name[0..prefix_len], requester_module[0..prefix_len]) or
                            function.module_name[prefix_len] != '.' or
                            !std.mem.eql(u8, function.module_name[prefix_len + 1 ..], owner_name)) continue;
                        if (resolution.canAccess(policy, requester_module, function.module_name, function.is_pub)) return function;
                    }
                }
            }
        }
        if (resolution.accessibleStruct(policy, program, requester_module, owner_name)) |decl| {
            for (decl.methods) |method| {
                if (std.mem.eql(u8, method.name, name) and resolution.canAccess(policy, requester_module, method.module_name, method.is_pub)) return method;
            }
            return null;
        }
        if (resolution.structAny(program, owner_name)) |decl| {
            for (decl.methods) |method| {
                if (std.mem.eql(u8, method.name, name) and resolution.canAccess(policy, requester_module, method.module_name, method.is_pub)) return method;
            }
            return null;
        }
        if (instantiated_base_name) |base_name| {
            if (resolution.accessibleStruct(policy, program, requester_module, base_name)) |decl| {
                for (decl.methods) |method| {
                    if (std.mem.eql(u8, method.name, name) and resolution.canAccess(policy, requester_module, method.module_name, method.is_pub)) return method;
                }
                return null;
            }
            if (resolution.structAny(program, base_name)) |decl| {
                for (decl.methods) |method| {
                    if (std.mem.eql(u8, method.name, name) and resolution.canAccess(policy, requester_module, method.module_name, method.is_pub)) return method;
                }
                return null;
            }
        }
        return null;
    }

    for (program.functions) |function| {
        if (std.mem.eql(u8, requester_module, function.module_name) and std.mem.eql(u8, function.name, name)) return function;
    }
    if (resolution.namedImportedFunction(policy, program, requester_module, name)) |function| return function;
    return resolution.autoloadFunction(program, name);
}

pub fn findFunction(
    registry: ?*identity.Registry,
    program: ast.Program,
    policy: resolution.AccessPolicy,
    instantiated_base_name: ?[]const u8,
    requester_module: []const u8,
    owner: ?[]const u8,
    name: []const u8,
) ?ResolvedFunction {
    const decl = findFunctionDecl(program, policy, instantiated_base_name, requester_module, owner, name) orelse return null;
    return .{
        .id = registration.findOptional(registry, decl.module_name, decl.owner, decl.name, .function),
        .decl = decl,
    };
}

pub fn resolveFunction(
    registry: ?*identity.Registry,
    program: ast.Program,
    policy: resolution.AccessPolicy,
    instantiated_base_name: ?[]const u8,
    requester_module: []const u8,
    owner: ?[]const u8,
    name: []const u8,
) ?ResolvedFunction {
    const resolved = findFunction(registry, program, policy, instantiated_base_name, requester_module, owner, name) orelse return null;
    if (resolved.id == null) return null;
    return resolved;
}

pub fn findFunctionExact(
    registry: ?*identity.Registry,
    program: ast.Program,
    module_name: []const u8,
    owner: ?[]const u8,
    name: []const u8,
) ?ResolvedFunction {
    for (program.functions) |function| {
        if (std.mem.eql(u8, function.module_name, module_name) and
            optionalEql(function.owner, owner) and
            std.mem.eql(u8, function.name, name))
        {
            return .{
                .id = registration.findOptional(registry, function.module_name, function.owner, function.name, .function),
                .decl = function,
            };
        }
    }
    return null;
}

/// Locate a function in a lowered SIR module. The owner form also accepts a
/// module-named free function, which is how a generated owner resolves a
/// helper that stayed outside the struct.
pub fn findSirFunction(module: sir.Module, name: []const u8) ?sir.Function {
    return findSirFunctionIn(module, null, name);
}

pub fn findSirFunctionIn(module: sir.Module, owner: ?[]const u8, name: []const u8) ?sir.Function {
    for (module.functions) |function| {
        if (optionalEql(function.owner, owner) and std.mem.eql(u8, function.name, name)) return function;
    }
    if (owner) |owner_name| {
        for (module.functions) |function| {
            if (function.owner == null and std.mem.eql(u8, function.module_name, owner_name) and std.mem.eql(u8, function.name, name)) return function;
        }
    }
    return null;
}

pub fn checkNames(diagnostic_context: *diagnostics.Context, path: []const u8, program: ast.Program) CheckError!void {
    try checkGlobalNames(diagnostic_context, path, program);
    try checkTypeAliasNames(diagnostic_context, path, program);
    try checkEnums(diagnostic_context, path, program);
    try checkUnions(diagnostic_context, path, program);
    try checkStructNames(diagnostic_context, path, program);
    try checkProtocolNames(diagnostic_context, path, program);
    try checkFunctionNames(diagnostic_context, path, program);
    try checkImportAliases(diagnostic_context, path, program);
    try checkImportAmbiguities(diagnostic_context, path, program);
}

fn checkGlobalNames(diagnostic_context: *diagnostics.Context, path: []const u8, program: ast.Program) CheckError!void {
    for (program.globals, 0..) |global, i| {
        if (global.type_name) |type_name| {
            if (type_resolution.isPlainCStrTypeName(type_name)) {
                try diagnostic_context.emitToken(path, type_name.token, "`c_str` is a borrowed C string view and cannot be stored in a global; use `*const c_char` for stored C pointers", .{});
                return CheckError.SemanticFailed;
            }
        }
        for (program.globals[0..i]) |existing| {
            if (std.mem.eql(u8, global.module_name, existing.module_name) and optionalEql(global.owner, existing.owner) and std.mem.eql(u8, global.name, existing.name)) {
                try diagnostic_context.emitToken(path, global.name_token, "duplicate global `{s}`", .{global.name});
                return CheckError.SemanticFailed;
            }
        }
    }
    for (program.asm_consts, 0..) |asm_const, i| {
        for (program.asm_consts[0..i]) |existing| {
            if (std.mem.eql(u8, asm_const.module_name, existing.module_name) and std.mem.eql(u8, asm_const.name, existing.name)) {
                try diagnostic_context.emitToken(path, asm_const.name_token, "duplicate asm constant `{s}`", .{asm_const.name});
                return CheckError.SemanticFailed;
            }
            const symbol_name = asm_const.abi_name orelse asm_const.name;
            const existing_symbol_name = existing.abi_name orelse existing.name;
            if (std.mem.eql(u8, symbol_name, existing_symbol_name)) {
                try diagnostic_context.emitToken(path, asm_const.name_token, "duplicate exported assembler symbol `{s}`", .{symbol_name});
                return CheckError.SemanticFailed;
            }
        }
        for (program.globals) |global| {
            if (global.owner == null and std.mem.eql(u8, asm_const.module_name, global.module_name) and std.mem.eql(u8, asm_const.name, global.name)) {
                try diagnostic_context.emitToken(path, asm_const.name_token, "asm constant `{s}` conflicts with a global binding", .{asm_const.name});
                return CheckError.SemanticFailed;
            }
        }
        for (program.functions) |function| {
            if (function.owner == null and std.mem.eql(u8, asm_const.module_name, function.module_name) and std.mem.eql(u8, asm_const.name, function.name)) {
                try diagnostic_context.emitToken(path, asm_const.name_token, "asm constant `{s}` conflicts with a function binding", .{asm_const.name});
                return CheckError.SemanticFailed;
            }
        }
    }
}

fn checkTypeAliasNames(diagnostic_context: *diagnostics.Context, path: []const u8, program: ast.Program) CheckError!void {
    for (program.aliases, 0..) |alias, i| {
        if (type_resolution.isBuiltinTypeName(alias.name)) {
            try diagnostic_context.emitToken(path, alias.name_token, "type alias `{s}` conflicts with a built-in type", .{alias.name});
            return CheckError.SemanticFailed;
        }
        for (program.aliases[0..i]) |existing| {
            if (std.mem.eql(u8, existing.module_name, alias.module_name) and std.mem.eql(u8, existing.name, alias.name)) {
                try diagnostic_context.emitToken(path, alias.name_token, "duplicate type alias `{s}`", .{alias.name});
                return CheckError.SemanticFailed;
            }
        }
        if (name_resolution.enumInModule(program, alias.module_name, alias.name) != null or name_resolution.unionInModule(program, alias.module_name, alias.name) != null or name_resolution.structInModule(program, alias.module_name, alias.name) != null or name_resolution.protocolInModule(program, alias.module_name, alias.name) != null) {
            try diagnostic_context.emitToken(path, alias.name_token, "type alias `{s}` conflicts with an existing type", .{alias.name});
            return CheckError.SemanticFailed;
        }
    }
}

fn checkEnums(diagnostic_context: *diagnostics.Context, path: []const u8, program: ast.Program) CheckError!void {
    for (program.enums, 0..) |decl, i| {
        for (program.enums[0..i]) |existing| {
            if (std.mem.eql(u8, existing.module_name, decl.module_name) and std.mem.eql(u8, existing.name, decl.name)) {
                try diagnostic_context.emitToken(path, decl.name_token, "duplicate enum `{s}`", .{decl.name});
                return CheckError.SemanticFailed;
            }
        }

        for (decl.cases, 0..) |case, case_i| {
            for (decl.cases[0..case_i]) |existing| {
                if (std.mem.eql(u8, existing.name, case.name)) {
                    try diagnostic_context.emitToken(path, case.name_token, "duplicate enum case `{s}`", .{case.name});
                    return CheckError.SemanticFailed;
                }
            }
        }
    }
}

fn checkUnions(diagnostic_context: *diagnostics.Context, path: []const u8, program: ast.Program) CheckError!void {
    for (program.unions, 0..) |decl, i| {
        for (program.unions[0..i]) |existing| {
            if (std.mem.eql(u8, existing.module_name, decl.module_name) and std.mem.eql(u8, existing.name, decl.name)) {
                try diagnostic_context.emitToken(path, decl.name_token, "duplicate union `{s}`", .{decl.name});
                return CheckError.SemanticFailed;
            }
        }
        for (decl.fields, 0..) |field, field_i| {
            if (field.type_name) |type_name| {
                if (type_resolution.isPlainCStrTypeName(type_name)) {
                    try diagnostic_context.emitToken(path, field.name_token, "`c_str` is a borrowed C string view and cannot be stored in a union; use `*const c_char` for stored C pointers", .{});
                    return CheckError.SemanticFailed;
                }
            }
            for (decl.fields[0..field_i]) |existing| {
                if (std.mem.eql(u8, existing.name, field.name)) {
                    try diagnostic_context.emitToken(path, field.name_token, "duplicate union field `{s}`", .{field.name});
                    return CheckError.SemanticFailed;
                }
            }
        }
    }
}

fn checkStructNames(diagnostic_context: *diagnostics.Context, path: []const u8, program: ast.Program) CheckError!void {
    for (program.structs, 0..) |decl, i| {
        for (program.structs[0..i]) |existing| {
            if (std.mem.eql(u8, existing.module_name, decl.module_name) and std.mem.eql(u8, existing.name, decl.name)) {
                try diagnostic_context.emitToken(path, decl.name_token, "duplicate struct `{s}`", .{decl.name});
                return CheckError.SemanticFailed;
            }
        }

        for (decl.fields, 0..) |field, field_i| {
            for (decl.fields[0..field_i]) |existing| {
                if (std.mem.eql(u8, existing.name, field.name)) {
                    try diagnostic_context.emitToken(path, field.name_token, "duplicate field `{s}`", .{field.name});
                    return CheckError.SemanticFailed;
                }
            }
        }
    }
}

fn checkProtocolNames(diagnostic_context: *diagnostics.Context, path: []const u8, program: ast.Program) CheckError!void {
    for (program.protocols, 0..) |decl, i| {
        for (program.protocols[0..i]) |existing| {
            if (std.mem.eql(u8, existing.module_name, decl.module_name) and std.mem.eql(u8, existing.name, decl.name)) {
                try diagnostic_context.emitToken(path, decl.name_token, "duplicate protocol `{s}`", .{decl.name});
                return CheckError.SemanticFailed;
            }
        }
        if (name_resolution.typeAliasInModule(program, decl.module_name, decl.name) != null or
            name_resolution.enumInModule(program, decl.module_name, decl.name) != null or
            name_resolution.unionInModule(program, decl.module_name, decl.name) != null or
            name_resolution.structInModule(program, decl.module_name, decl.name) != null)
        {
            try diagnostic_context.emitToken(path, decl.name_token, "protocol `{s}` conflicts with an existing type", .{decl.name});
            return CheckError.SemanticFailed;
        }

        for (decl.methods, 0..) |method, method_i| {
            for (decl.methods[0..method_i]) |existing| {
                if (std.mem.eql(u8, existing.name, method.name)) {
                    try diagnostic_context.emitToken(path, method.name_token, "duplicate protocol method `{s}`", .{method.name});
                    return CheckError.SemanticFailed;
                }
            }
        }
    }
}

fn checkFunctionNames(diagnostic_context: *diagnostics.Context, path: []const u8, program: ast.Program) CheckError!void {
    for (program.functions, 0..) |function, i| {
        if (function.is_sequence_literal_factory) {
            const valid = function.owner == null and function.is_pub and !function.is_extern and
                function.calling_convention == .cyna and function.params.len == 1 and
                function.return_type != null and !isVoidTypeName(function.return_type.?) and
                isSequenceStoragePattern(function.params[0].type_name);
            if (!valid) {
                try diagnostic_context.emitToken(path, function.name_token, "attribute `syntax.sequence_literal` requires a public top-level Cyna factory with one owned `[:]Item` parameter and a non-void return type", .{});
                return CheckError.SemanticFailed;
            }
            for (function.type_params) |param| {
                if (!generics.typeNameContainsParam(function.return_type.?, &.{param}) and
                    !generics.typeNameContainsParam(function.params[0].type_name.args[0], &.{param}))
                {
                    try diagnostic_context.emitToken(path, function.name_token, "attribute `syntax.sequence_literal` cannot infer generic parameter `{s}` of factory `{s}` from its return or item type", .{ param.name, function.name });
                    return CheckError.SemanticFailed;
                }
            }
        }
        if (function.intrinsic_name) |intrinsic_name| {
            const token = function.intrinsic_token orelse function.name_token;
            if (!moduleIsCompilerOwned(program, function.module_name)) {
                try diagnostic_context.emitToken(path, token, "intrinsic declarations are only allowed in compiler-owned modules", .{});
                return CheckError.SemanticFailed;
            }
            const intrinsic_id = intrinsics.resolveExplicit(intrinsic_name) orelse {
                try diagnostic_context.emitToken(path, token, "unknown compiler intrinsic `{s}`", .{intrinsic_name});
                return CheckError.SemanticFailed;
            };
            for (program.functions[0..i]) |existing| {
                if (existing.intrinsic_name) |existing_name| {
                    if (intrinsics.resolveExplicit(existing_name) == intrinsic_id) {
                        try diagnostic_context.emitToken(path, token, "duplicate declaration for compiler intrinsic `{s}`", .{intrinsic_name});
                        return CheckError.SemanticFailed;
                    }
                }
            }
            switch (intrinsic_id) {
                .value_eq => if (!isValueEqIntrinsicSignature(function)) {
                    try diagnostic_context.emitToken(path, function.name_token, "intrinsic `value.eq` must have signature `fn <T>(&const T, &const T): bool`", .{});
                    return CheckError.SemanticFailed;
                },
                else => unreachable,
            }
        }
        if (isBuiltinPrintName(function.name)) {
            try diagnostic_context.emitToken(path, function.name_token, "function name `{s}` is reserved for the builtin print surface", .{function.name});
            return CheckError.SemanticFailed;
        }
        for (program.functions[0..i]) |existing| {
            if (std.mem.eql(u8, existing.module_name, function.module_name) and optionalEql(existing.owner, function.owner) and std.mem.eql(u8, existing.name, function.name)) {
                try diagnostic_context.emitToken(path, function.name_token, "duplicate function `{s}`", .{function.name});
                return CheckError.SemanticFailed;
            }
        }
    }

    for (program.structs) |decl| {
        for (decl.methods, 0..) |method, i| {
            for (decl.methods[0..i]) |existing| {
                if (std.mem.eql(u8, existing.name, method.name)) {
                    try diagnostic_context.emitToken(path, method.name_token, "duplicate method `{s}`", .{method.name});
                    return CheckError.SemanticFailed;
                }
            }
        }
    }
}

fn checkImportAliases(diagnostic_context: *diagnostics.Context, path: []const u8, program: ast.Program) CheckError!void {
    for (program.module_infos) |info| {
        for (info.imports) |decl| {
            if (decl.local_name) |local_name| {
                if (std.mem.eql(u8, local_name, name_resolution.importModuleBasename(decl.path))) {
                    try diagnostic_context.emitPath(path, "redundant import alias");
                    return CheckError.SemanticFailed;
                }
            }

            for (decl.items) |item| {
                if (item.local_name) |local_name| {
                    if (std.mem.eql(u8, local_name, item.name)) {
                        try diagnostic_context.emitPath(path, "redundant import alias");
                        return CheckError.SemanticFailed;
                    }
                }
            }
        }
    }
}

fn checkImportAmbiguities(diagnostic_context: *diagnostics.Context, path: []const u8, program: ast.Program) CheckError!void {
    for (program.module_infos) |info| {
        for (info.imports, 0..) |left, i| {
            if (left.items.len == 0) {
                const left_name = name_resolution.importBindingLocalName(left);
                for (info.imports[i + 1 ..]) |right| {
                    if (right.items.len == 0) {
                        if (std.mem.eql(u8, left_name, name_resolution.importBindingLocalName(right))) {
                            try diagnostic_context.emitPath(path, "duplicate import binding name");
                            return CheckError.SemanticFailed;
                        }
                    } else {
                        for (right.items) |item| {
                            if (std.mem.eql(u8, left_name, name_resolution.importItemLocalName(item))) {
                                try diagnostic_context.emitPath(path, "duplicate import binding name");
                                return CheckError.SemanticFailed;
                            }
                        }
                    }
                }
            }

            for (left.items, 0..) |item, item_i| {
                const item_name = name_resolution.importItemLocalName(item);
                for (info.imports[i + 1 ..]) |right| {
                    if (right.items.len == 0) {
                        if (std.mem.eql(u8, item_name, name_resolution.importBindingLocalName(right))) {
                            try diagnostic_context.emitPath(path, "duplicate import binding name");
                            return CheckError.SemanticFailed;
                        }
                    } else {
                        for (right.items) |other| {
                            if (std.mem.eql(u8, item_name, name_resolution.importItemLocalName(other))) {
                                try diagnostic_context.emitPath(path, "duplicate import binding name");
                                return CheckError.SemanticFailed;
                            }
                        }
                    }
                }
                for (left.items[item_i + 1 ..]) |other| {
                    if (std.mem.eql(u8, item_name, name_resolution.importItemLocalName(other))) {
                        try diagnostic_context.emitPath(path, "duplicate import binding name");
                        return CheckError.SemanticFailed;
                    }
                }
            }
        }
    }
}

fn isSequenceStoragePattern(ty: ast.TypeName) bool {
    return std.mem.eql(u8, ty.name, "[:]") and ty.args.len == 1 and
        !ty.is_ref and !ty.is_owned and !ty.is_raw and !ty.is_optional and
        !ty.is_slice and ty.array_len == null and ty.array_len_name == null;
}

fn isVoidTypeName(type_name: ast.TypeName) bool {
    return !type_name.is_ref and
        !type_name.is_owned and
        !type_name.is_raw and
        !type_name.is_volatile_raw and
        !type_name.is_optional and
        !type_name.is_function and
        !type_name.is_slice and
        type_name.array_len == null and
        type_name.args.len == 0 and
        std.mem.eql(u8, type_name.name, "void");
}

fn isValueEqIntrinsicSignature(function: ast.Function) bool {
    if (function.owner != null or function.type_params.len != 1 or function.params.len != 2) return false;
    const param = function.type_params[0];
    if (param.is_const_value or param.constraint != null or param.extra_constraints.len != 0) return false;
    for (function.params) |value_param| {
        const ty = value_param.type_name;
        if (!ty.is_ref or !ty.ref_is_const or ty.module_name != null or ty.args.len != 0 or
            ty.is_owned or ty.is_raw or ty.is_optional or ty.is_slice or ty.array_len != null or
            !std.mem.eql(u8, ty.name, param.name)) return false;
    }
    const return_type = function.return_type orelse return false;
    return !return_type.is_ref and !return_type.is_owned and !return_type.is_raw and
        !return_type.is_optional and !return_type.is_slice and return_type.array_len == null and
        return_type.module_name == null and return_type.args.len == 0 and
        std.mem.eql(u8, return_type.name, "bool");
}

fn moduleIsCompilerOwned(program: ast.Program, module_name: []const u8) bool {
    const info = name_resolution.moduleInfo(program, module_name) orelse return false;
    return info.compiler_owned;
}

fn isBuiltinPrintName(name: []const u8) bool {
    const intrinsic = intrinsics.resolveCall(null, name) orelse return false;
    return intrinsics.isPrint(intrinsic);
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Registration and identity lookup for source and generated declarations.
pub const registration = struct {
    pub const Error = error{ SemanticFailed, OutOfMemory };

    pub fn build(
        allocator: std.mem.Allocator,
        path: []const u8,
        program: ast.Program,
    ) Error!identity.Registry {
        var registry = identity.Registry.init(allocator);
        errdefer registry.deinit();

        const source_id = registry.registerSource(path) catch |err| return registrationFailure(err);
        _ = ensureModule(&registry, source_id, "") catch |err| return registrationFailure(err);
        for (program.module_infos) |module_info| {
            const source_path = if (module_info.source_path.len != 0) module_info.source_path else path;
            const module_source_id = registry.findSource(source_path) orelse
                registry.registerSource(source_path) catch |err| return registrationFailure(err);
            _ = ensureModule(&registry, module_source_id, module_info.name) catch |err| return registrationFailure(err);
        }

        for (program.globals) |decl| {
            try registerAstDecl(&registry, source_id, decl.module_name, decl.owner, decl.name, .global);
        }
        for (program.aliases) |decl| {
            try registerAstDecl(&registry, source_id, decl.module_name, null, decl.name, .type_alias);
        }
        for (program.enums) |decl| {
            try registerAstDecl(&registry, source_id, decl.module_name, null, decl.name, .@"enum");
        }
        for (program.unions) |decl| {
            try registerAstDecl(&registry, source_id, decl.module_name, null, decl.name, .@"union");
        }
        for (program.protocols) |decl| {
            try registerAstDecl(&registry, source_id, decl.module_name, null, decl.name, .protocol);
            for (decl.methods) |method| {
                try registerAstDecl(&registry, source_id, decl.module_name, decl.name, method.name, .protocol_method);
            }
        }
        for (program.impls) |decl| {
            for (decl.methods) |method| {
                try registerAstDecl(&registry, source_id, method.module_name, decl.method_owner, method.name, .function);
            }
        }
        for (program.structs) |decl| {
            try registerAstDecl(&registry, source_id, decl.module_name, null, decl.name, .@"struct");
            for (decl.methods) |method| {
                try registerAstDecl(
                    &registry,
                    source_id,
                    method.module_name,
                    method.owner orelse decl.name,
                    method.name,
                    .function,
                );
            }
        }
        for (program.functions) |decl| {
            try registerAstDecl(&registry, source_id, decl.module_name, decl.owner, decl.name, .function);
        }

        return registry;
    }

    pub fn find(
        registry: ?*identity.Registry,
        module_name: []const u8,
        owner: ?[]const u8,
        name: []const u8,
        kind: identity.DeclKind,
    ) Error!identity.DeclId {
        const value = registry orelse return error.SemanticFailed;
        const module_id = value.findModule(module_name) orelse return error.SemanticFailed;
        return (value.findDecl(module_id, owner, name, kind) catch return error.OutOfMemory) orelse
            error.SemanticFailed;
    }

    pub fn findOptional(
        registry: ?*identity.Registry,
        module_name: []const u8,
        owner: ?[]const u8,
        name: []const u8,
        kind: identity.DeclKind,
    ) ?identity.DeclId {
        const value = registry orelse return null;
        const module_id = value.findModule(module_name) orelse return null;
        return value.findDecl(module_id, owner, name, kind) catch null;
    }

    pub fn registerGenerated(
        registry: ?*identity.Registry,
        module_name: []const u8,
        owner: ?[]const u8,
        name: []const u8,
        kind: identity.DeclKind,
    ) Error!?identity.DeclId {
        const value = registry orelse return null;
        const module_id = value.findModule(module_name) orelse return error.SemanticFailed;
        return value.registerDecl(module_id, owner, name, kind) catch |err| return registrationFailure(err);
    }

    pub fn findOrRegisterGenerated(
        registry: ?*identity.Registry,
        module_name: []const u8,
        owner: ?[]const u8,
        name: []const u8,
        kind: identity.DeclKind,
    ) Error!identity.DeclId {
        if (findOptional(registry, module_name, owner, name, kind)) |id| return id;
        return (try registerGenerated(registry, module_name, owner, name, kind)) orelse
            error.SemanticFailed;
    }

    fn ensureModule(
        registry: *identity.Registry,
        source_id: identity.SourceId,
        module_name: []const u8,
    ) identity.RegisterError!identity.ModuleId {
        return registry.findModule(module_name) orelse try registry.registerModule(source_id, module_name);
    }

    fn registerAstDecl(
        registry: *identity.Registry,
        source_id: identity.SourceId,
        module_name: []const u8,
        owner: ?[]const u8,
        name: []const u8,
        kind: identity.DeclKind,
    ) Error!void {
        const module_id = ensureModule(registry, source_id, module_name) catch |err|
            return registrationFailure(err);
        _ = registry.registerDecl(module_id, owner, name, kind) catch |err|
            return registrationFailure(err);
    }

    fn registrationFailure(err: identity.RegisterError) Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.SemanticFailed,
        };
    }
};

/// Source declaration lookup and import access policy.
fn boundedEditDistance(left: []const u8, right: []const u8) ?usize {
    const max_len = 96;
    if (left.len > max_len or right.len > max_len) return null;
    if (left.len > right.len + 2 or right.len > left.len + 2) return null;

    var previous: [max_len + 1]usize = undefined;
    var current: [max_len + 1]usize = undefined;
    for (0..right.len + 1) |i| previous[i] = i;
    for (left, 0..) |left_byte, row| {
        current[0] = row + 1;
        var row_min = current[0];
        for (right, 0..) |right_byte, column| {
            const substitution = previous[column] + @intFromBool(left_byte != right_byte);
            current[column + 1] = @min(@min(previous[column + 1] + 1, current[column] + 1), substitution);
            row_min = @min(row_min, current[column + 1]);
        }
        if (row_min > 2) return null;
        @memcpy(previous[0 .. right.len + 1], current[0 .. right.len + 1]);
    }
    return if (previous[right.len] <= 2) previous[right.len] else null;
}

pub fn considerNameSuggestion(needle: []const u8, candidate: []const u8, best: *?[]const u8, best_distance: *usize, tied: *bool) void {
    const distance = boundedEditDistance(needle, candidate) orelse return;
    if (distance < best_distance.*) {
        best.* = candidate;
        best_distance.* = distance;
        tied.* = false;
    } else if (distance == best_distance.* and (best.* == null or !std.mem.eql(u8, best.*.?, candidate))) {
        tied.* = true;
    }
}

pub fn sameTypeName(left: ast.TypeName, right: ast.TypeName) bool {
    if (left.is_ref != right.is_ref or
        left.ref_is_const != right.ref_is_const or
        left.is_owned != right.is_owned or
        left.is_raw != right.is_raw or
        left.raw_is_const != right.raw_is_const or
        left.is_volatile_raw != right.is_volatile_raw or
        left.is_optional != right.is_optional or
        left.is_function != right.is_function or
        left.is_arrow_callable != right.is_arrow_callable or
        left.is_slice != right.is_slice or
        left.slice_flags.is_const != right.slice_flags.is_const or
        left.array_len != right.array_len or
        !optionalEql(left.module_name, right.module_name) or
        !std.mem.eql(u8, left.name, right.name) or
        left.args.len != right.args.len or
        left.function_params.len != right.function_params.len)
    {
        return false;
    }
    if (left.raw_target != null or right.raw_target != null) {
        if (left.raw_target == null or right.raw_target == null) return false;
        if (!sameTypeName(left.raw_target.?.*, right.raw_target.?.*)) return false;
    }
    for (left.args, right.args) |left_arg, right_arg| {
        if (!sameTypeName(left_arg, right_arg)) return false;
    }
    for (left.function_params, right.function_params) |left_param, right_param| {
        if (!sameTypeName(left_param, right_param)) return false;
    }
    if (left.function_return_type != null or right.function_return_type != null) {
        if (left.function_return_type == null or right.function_return_type == null) return false;
        if (!sameTypeName(left.function_return_type.?.*, right.function_return_type.?.*)) return false;
    }
    return true;
}

pub const resolution = struct {
    const declaration_index = registration;
    pub const FriendAccess = struct {
        test_module: []const u8,
        production_module: []const u8,
    };

    pub const AccessPolicy = struct {
        friend: ?FriendAccess = null,
    };

    pub const NamedImport = struct {
        module_name: []const u8,
        original_name: []const u8,
    };

    pub const ResolvedTypeKind = enum {
        @"struct",
        type_alias,
        @"enum",
        @"union",
    };

    pub const ResolvedTypeName = struct {
        id: ?identity.DeclId,
        kind: ResolvedTypeKind,
        module_name: []const u8,
        name: []const u8,
    };

    pub const AmbiguousResolvedTypeNames = struct {
        first: ResolvedTypeName,
        second: ResolvedTypeName,
    };

    pub const ResolvedStructDecl = struct {
        desc: ResolvedTypeName,
        decl: ast.StructDecl,
    };

    pub const ResolvedTypeAlias = struct {
        desc: ResolvedTypeName,
        alias: ast.TypeAlias,
    };

    pub const ResolvedEnumDecl = struct {
        desc: ResolvedTypeName,
        decl: ast.EnumDecl,
    };

    pub const ResolvedUnionDecl = struct {
        desc: ResolvedTypeName,
        decl: ast.UnionDecl,
    };

    pub const StructLookupResult = union(enum) {
        missing,
        found: ResolvedStructDecl,
        inaccessible: ResolvedStructDecl,
        ambiguous: AmbiguousResolvedTypeNames,
    };

    pub const TypeAliasLookupResult = union(enum) {
        missing,
        found: ResolvedTypeAlias,
        inaccessible: ResolvedTypeAlias,
        ambiguous: AmbiguousResolvedTypeNames,
    };

    pub const EnumLookupResult = union(enum) {
        missing,
        found: ResolvedEnumDecl,
        inaccessible: ResolvedEnumDecl,
        ambiguous: AmbiguousResolvedTypeNames,
    };

    pub const UnionLookupResult = union(enum) {
        missing,
        found: ResolvedUnionDecl,
        inaccessible: ResolvedUnionDecl,
        ambiguous: AmbiguousResolvedTypeNames,
    };

    pub fn canAccess(
        policy: AccessPolicy,
        requester_module: []const u8,
        decl_module: []const u8,
        is_pub: bool,
    ) bool {
        if (std.mem.eql(u8, requester_module, decl_module) or is_pub) return true;
        const friend = policy.friend orelse return false;
        return std.mem.eql(u8, requester_module, friend.test_module) and
            std.mem.eql(u8, decl_module, friend.production_module);
    }

    pub fn moduleInfo(program: ast.Program, module_name: []const u8) ?ast.ModuleInfo {
        for (program.module_infos) |info| {
            if (std.mem.eql(u8, info.name, module_name)) return info;
        }
        return null;
    }

    pub fn importBindingLocalName(decl: ast.ImportDecl) []const u8 {
        return decl.local_name orelse importModuleBasename(decl.path);
    }

    pub fn importItemLocalName(item: ast.ImportItem) []const u8 {
        return item.local_name orelse item.name;
    }

    pub fn importModuleBasename(path: []const u8) []const u8 {
        const last_dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return path;
        return path[last_dot + 1 ..];
    }

    pub fn importedModulePath(program: ast.Program, requester_module: []const u8, alias: []const u8) ?[]const u8 {
        const info = moduleInfo(program, requester_module) orelse return null;
        for (info.imports) |decl| {
            if (decl.items.len == 0 and std.mem.eql(u8, importBindingLocalName(decl), alias)) return decl.path;
        }
        return null;
    }

    pub fn rootPackageImportedModulePath(program: ast.Program, requester_module: []const u8, alias: []const u8) ?[]const u8 {
        const info = moduleInfo(program, requester_module) orelse return null;
        for (info.imports) |decl| {
            if (!decl.is_root_package or decl.items.len != 0) continue;
            if (std.mem.eql(u8, importBindingLocalName(decl), alias)) return decl.path;
        }
        return null;
    }

    pub fn namedImport(program: ast.Program, requester_module: []const u8, local_name: []const u8) ?NamedImport {
        const info = moduleInfo(program, requester_module) orelse return null;
        for (info.imports) |decl| {
            for (decl.items) |item| {
                if (std.mem.eql(u8, importItemLocalName(item), local_name)) {
                    return .{ .module_name = decl.path, .original_name = item.name };
                }
            }
        }
        return null;
    }

    pub fn structInModule(program: ast.Program, module_name: []const u8, name: []const u8) ?ast.StructDecl {
        for (program.structs) |decl| {
            if (std.mem.eql(u8, decl.module_name, module_name) and std.mem.eql(u8, decl.name, name)) return decl;
        }
        return null;
    }

    pub fn unionInModule(program: ast.Program, module_name: []const u8, name: []const u8) ?ast.UnionDecl {
        for (program.unions) |decl| {
            if (std.mem.eql(u8, decl.module_name, module_name) and std.mem.eql(u8, decl.name, name)) return decl;
        }
        return null;
    }

    pub fn enumInModule(program: ast.Program, module_name: []const u8, name: []const u8) ?ast.EnumDecl {
        for (program.enums) |decl| {
            if (std.mem.eql(u8, decl.module_name, module_name) and std.mem.eql(u8, decl.name, name)) return decl;
        }
        return null;
    }

    pub fn typeAliasInModule(program: ast.Program, module_name: []const u8, name: []const u8) ?ast.TypeAlias {
        for (program.aliases) |decl| {
            if (std.mem.eql(u8, decl.module_name, module_name) and std.mem.eql(u8, decl.name, name)) return decl;
        }
        return null;
    }

    pub fn protocolInModule(program: ast.Program, module_name: []const u8, name: []const u8) ?ast.ProtocolDecl {
        for (program.protocols) |decl| {
            if (std.mem.eql(u8, decl.module_name, module_name) and std.mem.eql(u8, decl.name, name)) return decl;
        }
        return null;
    }

    pub fn nestedStructInModule(
        program: ast.Program,
        module_name: []const u8,
        owner_name: []const u8,
        nested_name: []const u8,
    ) ?ast.StructDecl {
        for (program.structs) |decl| {
            if (std.mem.eql(u8, decl.module_name, module_name) and
                scopedNameMatches(decl.name, owner_name, nested_name)) return decl;
        }
        return null;
    }

    pub fn nestedEnumInModule(
        program: ast.Program,
        module_name: []const u8,
        owner_name: []const u8,
        nested_name: []const u8,
    ) ?ast.EnumDecl {
        for (program.enums) |decl| {
            if (std.mem.eql(u8, decl.module_name, module_name) and
                scopedNameMatches(decl.name, owner_name, nested_name)) return decl;
        }
        return null;
    }

    pub fn scopedNameMatches(decl_name: []const u8, owner_name: []const u8, nested_name: []const u8) bool {
        if (decl_name.len != owner_name.len + 1 + nested_name.len) return false;
        if (!std.mem.eql(u8, decl_name[0..owner_name.len], owner_name)) return false;
        if (decl_name[owner_name.len] != '$' and decl_name[owner_name.len] != '_') return false;
        return std.mem.eql(u8, decl_name[owner_name.len + 1 ..], nested_name);
    }

    pub fn structAny(program: ast.Program, name: []const u8) ?ast.StructDecl {
        for (program.structs) |decl| if (std.mem.eql(u8, decl.name, name)) return decl;
        return null;
    }

    pub fn unionAny(program: ast.Program, name: []const u8) ?ast.UnionDecl {
        for (program.unions) |decl| if (std.mem.eql(u8, decl.name, name)) return decl;
        return null;
    }

    pub fn enumAny(program: ast.Program, name: []const u8) ?ast.EnumDecl {
        for (program.enums) |decl| if (std.mem.eql(u8, decl.name, name)) return decl;
        return null;
    }

    pub fn accessibleStruct(policy: AccessPolicy, program: ast.Program, requester_module: []const u8, name: []const u8) ?ast.StructDecl {
        if (structInModule(program, requester_module, name)) |decl| return decl;
        if (namedImport(program, requester_module, name)) |binding| {
            const decl = structInModule(program, binding.module_name, binding.original_name) orelse return null;
            if (canAccess(policy, requester_module, decl.module_name, decl.is_pub)) return decl;
        }
        return autoloadStruct(program, name);
    }

    pub fn accessibleUnion(policy: AccessPolicy, program: ast.Program, requester_module: []const u8, name: []const u8) ?ast.UnionDecl {
        if (unionInModule(program, requester_module, name)) |decl| return decl;
        if (namedImport(program, requester_module, name)) |binding| {
            const decl = unionInModule(program, binding.module_name, binding.original_name) orelse return null;
            if (canAccess(policy, requester_module, decl.module_name, decl.is_pub)) return decl;
        }
        return autoloadUnion(program, name) orelse unionAny(program, name);
    }

    pub fn accessibleEnum(policy: AccessPolicy, program: ast.Program, requester_module: []const u8, name: []const u8) ?ast.EnumDecl {
        if (enumInModule(program, requester_module, name)) |decl| return decl;
        if (namedImport(program, requester_module, name)) |binding| {
            const decl = enumInModule(program, binding.module_name, binding.original_name) orelse return null;
            if (canAccess(policy, requester_module, decl.module_name, decl.is_pub)) return decl;
        }
        return autoloadEnum(program, name) orelse enumAny(program, name);
    }

    pub fn accessibleTypeAlias(policy: AccessPolicy, program: ast.Program, requester_module: []const u8, name: []const u8) ?ast.TypeAlias {
        if (typeAliasInModule(program, requester_module, name)) |decl| return decl;
        if (namedImport(program, requester_module, name)) |binding| {
            const decl = typeAliasInModule(program, binding.module_name, binding.original_name) orelse return null;
            if (canAccess(policy, requester_module, decl.module_name, decl.is_pub)) return decl;
        }
        return autoloadTypeAlias(program, name);
    }

    pub fn accessibleProtocol(policy: AccessPolicy, program: ast.Program, requester_module: []const u8, name: []const u8) ?ast.ProtocolDecl {
        if (protocolInModule(program, requester_module, name)) |decl| return decl;
        if (namedImport(program, requester_module, name)) |binding| {
            const decl = protocolInModule(program, binding.module_name, binding.original_name) orelse return null;
            if (canAccess(policy, requester_module, decl.module_name, decl.is_pub)) return decl;
        }
        return autoloadProtocol(program, name);
    }

    pub fn namedImportedFunction(
        policy: AccessPolicy,
        program: ast.Program,
        requester_module: []const u8,
        name: []const u8,
    ) ?ast.Function {
        const binding = namedImport(program, requester_module, name) orelse return null;
        for (program.functions) |function| {
            if (function.owner == null and
                std.mem.eql(u8, function.module_name, binding.module_name) and
                std.mem.eql(u8, function.name, binding.original_name) and
                canAccess(policy, requester_module, function.module_name, function.is_pub)) return function;
        }
        return null;
    }

    pub fn resolveEnumInTypeScope(
        policy: AccessPolicy,
        registry: ?*identity.Registry,
        program: ast.Program,
        current_module: []const u8,
        lookup_module: ?[]const u8,
        name: []const u8,
    ) EnumLookupResult {
        if (lookup_module) |module_name| {
            const decl = enumInModule(program, module_name, name) orelse return .missing;
            const resolved = resolvedEnum(registry, decl);
            return if (canAccess(policy, current_module, decl.module_name, decl.is_pub))
                .{ .found = resolved }
            else
                .{ .inaccessible = resolved };
        }
        var found: ?ResolvedEnumDecl = null;
        for (program.enums) |decl| {
            if (!std.mem.eql(u8, decl.module_name, current_module) or !enumNameMatchesShort(decl, name)) continue;
            if (mergeResolved(ResolvedEnumDecl, &found, resolvedEnum(registry, decl))) |ambiguous| return .{ .ambiguous = ambiguous };
        }
        if (found) |resolved| return .{ .found = resolved };
        if (namedImport(program, current_module, name)) |binding| {
            const decl = enumInModule(program, binding.module_name, binding.original_name) orelse return .missing;
            const resolved = resolvedEnum(registry, decl);
            return if (canAccess(policy, current_module, decl.module_name, decl.is_pub))
                .{ .found = resolved }
            else
                .{ .inaccessible = resolved };
        }
        for (program.enums) |decl| {
            if (!enumNameMatchesShort(decl, name)) continue;
            if (mergeResolved(ResolvedEnumDecl, &found, resolvedEnum(registry, decl))) |ambiguous| return .{ .ambiguous = ambiguous };
        }
        return if (found) |resolved| .{ .found = resolved } else .missing;
    }

    pub fn resolveUnionInTypeScope(
        policy: AccessPolicy,
        registry: ?*identity.Registry,
        program: ast.Program,
        current_module: []const u8,
        lookup_module: ?[]const u8,
        name: []const u8,
    ) UnionLookupResult {
        if (lookup_module) |module_name| {
            const decl = unionInModule(program, module_name, name) orelse return .missing;
            const resolved = resolvedUnion(registry, decl);
            return if (canAccess(policy, current_module, decl.module_name, decl.is_pub))
                .{ .found = resolved }
            else
                .{ .inaccessible = resolved };
        }
        var found: ?ResolvedUnionDecl = null;
        for (program.unions) |decl| {
            if (!std.mem.eql(u8, decl.module_name, current_module) or !std.mem.eql(u8, decl.name, name)) continue;
            if (mergeResolved(ResolvedUnionDecl, &found, resolvedUnion(registry, decl))) |ambiguous| return .{ .ambiguous = ambiguous };
        }
        if (found) |resolved| return .{ .found = resolved };
        if (namedImport(program, current_module, name)) |binding| {
            const decl = unionInModule(program, binding.module_name, binding.original_name) orelse return .missing;
            const resolved = resolvedUnion(registry, decl);
            return if (canAccess(policy, current_module, decl.module_name, decl.is_pub))
                .{ .found = resolved }
            else
                .{ .inaccessible = resolved };
        }
        for (program.unions) |decl| {
            if (!std.mem.eql(u8, decl.name, name)) continue;
            if (mergeResolved(ResolvedUnionDecl, &found, resolvedUnion(registry, decl))) |ambiguous| return .{ .ambiguous = ambiguous };
        }
        return if (found) |resolved| .{ .found = resolved } else .missing;
    }

    pub fn resolveStructInTypeScope(
        policy: AccessPolicy,
        registry: ?*identity.Registry,
        program: ast.Program,
        current_module: []const u8,
        lookup_module: ?[]const u8,
        name: []const u8,
    ) StructLookupResult {
        if (lookup_module) |module_name| {
            const decl = structInModule(program, module_name, name) orelse return .missing;
            const resolved = resolvedStruct(registry, decl);
            return if (canAccess(policy, current_module, decl.module_name, decl.is_pub))
                .{ .found = resolved }
            else
                .{ .inaccessible = resolved };
        }
        var found: ?ResolvedStructDecl = null;
        for (program.structs) |decl| {
            if (!std.mem.eql(u8, decl.module_name, current_module) or !structNameMatchesShort(decl, name)) continue;
            if (mergeResolved(ResolvedStructDecl, &found, resolvedStruct(registry, decl))) |ambiguous| return .{ .ambiguous = ambiguous };
        }
        if (found) |resolved| return .{ .found = resolved };
        if (namedImport(program, current_module, name)) |binding| {
            const decl = structInModule(program, binding.module_name, binding.original_name) orelse return .missing;
            const resolved = resolvedStruct(registry, decl);
            return if (canAccess(policy, current_module, decl.module_name, decl.is_pub))
                .{ .found = resolved }
            else
                .{ .inaccessible = resolved };
        }
        for (program.structs) |decl| {
            if (!structNameMatchesShort(decl, name)) continue;
            if (mergeResolved(ResolvedStructDecl, &found, resolvedStruct(registry, decl))) |ambiguous| return .{ .ambiguous = ambiguous };
        }
        return if (found) |resolved| .{ .found = resolved } else .missing;
    }

    pub fn resolveTypeAliasInTypeScope(
        policy: AccessPolicy,
        registry: ?*identity.Registry,
        program: ast.Program,
        current_module: []const u8,
        lookup_module: ?[]const u8,
        name: []const u8,
    ) TypeAliasLookupResult {
        if (lookup_module) |module_name| {
            const decl = typeAliasInModule(program, module_name, name) orelse return .missing;
            const resolved = resolvedAlias(registry, decl);
            return if (canAccess(policy, current_module, decl.module_name, decl.is_pub))
                .{ .found = resolved }
            else
                .{ .inaccessible = resolved };
        }
        var found: ?ResolvedTypeAlias = null;
        for (program.aliases) |decl| {
            if (!std.mem.eql(u8, decl.module_name, current_module) or !typeAliasNameMatchesShort(decl, name)) continue;
            if (mergeResolved(ResolvedTypeAlias, &found, resolvedAlias(registry, decl))) |ambiguous| return .{ .ambiguous = ambiguous };
        }
        if (found) |resolved| return .{ .found = resolved };
        if (namedImport(program, current_module, name)) |binding| {
            const decl = typeAliasInModule(program, binding.module_name, binding.original_name) orelse return .missing;
            const resolved = resolvedAlias(registry, decl);
            return if (canAccess(policy, current_module, decl.module_name, decl.is_pub))
                .{ .found = resolved }
            else
                .{ .inaccessible = resolved };
        }
        for (program.aliases) |decl| {
            if (!typeAliasNameMatchesShort(decl, name)) continue;
            if (mergeResolved(ResolvedTypeAlias, &found, resolvedAlias(registry, decl))) |ambiguous| return .{ .ambiguous = ambiguous };
        }
        return if (found) |resolved| .{ .found = resolved } else .missing;
    }

    fn mergeResolved(
        comptime T: type,
        found: *?T,
        candidate: T,
    ) ?AmbiguousResolvedTypeNames {
        if (found.*) |existing| {
            if (!sameResolvedTypeName(existing.desc, candidate.desc)) {
                return .{ .first = existing.desc, .second = candidate.desc };
            }
        } else {
            found.* = candidate;
        }
        return null;
    }

    fn resolvedStruct(registry: ?*identity.Registry, decl: ast.StructDecl) ResolvedStructDecl {
        return .{ .desc = resolvedName(registry, .@"struct", decl.module_name, decl.name, .@"struct"), .decl = decl };
    }

    fn resolvedAlias(registry: ?*identity.Registry, decl: ast.TypeAlias) ResolvedTypeAlias {
        return .{ .desc = resolvedName(registry, .type_alias, decl.module_name, decl.name, .type_alias), .alias = decl };
    }

    fn resolvedEnum(registry: ?*identity.Registry, decl: ast.EnumDecl) ResolvedEnumDecl {
        return .{ .desc = resolvedName(registry, .@"enum", decl.module_name, decl.name, .@"enum"), .decl = decl };
    }

    fn resolvedUnion(registry: ?*identity.Registry, decl: ast.UnionDecl) ResolvedUnionDecl {
        return .{ .desc = resolvedName(registry, .@"union", decl.module_name, decl.name, .@"union"), .decl = decl };
    }

    fn resolvedName(
        registry: ?*identity.Registry,
        resolved_kind: ResolvedTypeKind,
        module_name: []const u8,
        name: []const u8,
        decl_kind: identity.DeclKind,
    ) ResolvedTypeName {
        return .{
            .id = declaration_index.findOptional(registry, module_name, null, name, decl_kind),
            .kind = resolved_kind,
            .module_name = module_name,
            .name = name,
        };
    }

    fn sameResolvedTypeName(a: ResolvedTypeName, b: ResolvedTypeName) bool {
        if (a.id != null and b.id != null) return a.id.? == b.id.?;
        return a.kind == b.kind and
            std.mem.eql(u8, a.module_name, b.module_name) and
            std.mem.eql(u8, a.name, b.name);
    }

    fn shortDeclName(name: []const u8, allow_underscore_scope: bool) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, name, '$')) |index| return name[index + 1 ..];
        if (allow_underscore_scope) {
            if (std.mem.lastIndexOfScalar(u8, name, '_')) |index| return name[index + 1 ..];
        }
        return name;
    }

    fn structNameMatchesShort(decl: ast.StructDecl, name: []const u8) bool {
        return std.mem.eql(u8, shortDeclName(decl.name, decl.owns_name), name);
    }

    fn typeAliasNameMatchesShort(decl: ast.TypeAlias, name: []const u8) bool {
        return std.mem.eql(u8, shortDeclName(decl.name, false), name);
    }

    fn enumNameMatchesShort(decl: ast.EnumDecl, name: []const u8) bool {
        return std.mem.eql(u8, shortDeclName(decl.name, decl.owns_name), name);
    }

    pub fn autoloadFunction(program: ast.Program, name: []const u8) ?ast.Function {
        for (program.functions) |function| {
            if (function.owner == null and function.is_pub and
                std.mem.eql(u8, function.name, name) and isAutoloadModule(program, function.module_name)) return function;
        }
        return null;
    }

    pub fn autoloadStruct(program: ast.Program, name: []const u8) ?ast.StructDecl {
        for (program.structs) |decl| {
            if (decl.is_pub and std.mem.eql(u8, decl.name, name) and isAutoloadModule(program, decl.module_name)) return decl;
        }
        return null;
    }

    pub fn autoloadUnion(program: ast.Program, name: []const u8) ?ast.UnionDecl {
        for (program.unions) |decl| {
            if (decl.is_pub and std.mem.eql(u8, decl.name, name) and isAutoloadModule(program, decl.module_name)) return decl;
        }
        return null;
    }

    pub fn autoloadEnum(program: ast.Program, name: []const u8) ?ast.EnumDecl {
        for (program.enums) |decl| {
            if (decl.is_pub and std.mem.eql(u8, decl.name, name) and isAutoloadModule(program, decl.module_name)) return decl;
        }
        return null;
    }

    pub fn autoloadTypeAlias(program: ast.Program, name: []const u8) ?ast.TypeAlias {
        for (program.aliases) |decl| {
            if (decl.is_pub and std.mem.eql(u8, decl.name, name) and isAutoloadModule(program, decl.module_name)) return decl;
        }
        return null;
    }

    pub fn autoloadProtocol(program: ast.Program, name: []const u8) ?ast.ProtocolDecl {
        for (program.protocols) |decl| {
            if (decl.is_pub and std.mem.eql(u8, decl.name, name) and isAutoloadModule(program, decl.module_name)) return decl;
        }
        return null;
    }

    pub fn isAutoloadModule(program: ast.Program, module_name: []const u8) bool {
        const info = moduleInfo(program, module_name) orelse return false;
        return info.autoload;
    }
};

/// Declaration-shaped view of a struct aggregate: either the source declaration
/// or an instantiated generic struct. Owners project fields and payloads through it.
pub const StructLookup = struct {
    module_name: []const u8,
    layout: ast.StructLayout,
    is_shared_value: bool = false,
    is_owned_value: bool = false,
    is_concurrency_shareable: bool = false,
    fields: Fields,

    const Fields = union(enum) {
        ast_fields: []const ast.FieldDecl,
        inst_fields: []const session.InstantiatedStructField,
    };
};

pub const StructFieldLookup = struct {
    name: []const u8,
    type_id: ?semantic_types.TypeId,
    type_name: ?ast.TypeName,
    default_value: ?*ast.Expr,
    is_pub: bool,
};

/// Session-scoped declaration-name resolution. Every owner instantiates this from
/// its own `SemaContext` instead of receiving wrapper functions through the
/// host table.
pub fn Lookup(comptime SemaContext: type) type {
    const names = resolution;
    const canonical = type_resolution.Canonical(SemaContext);
    return struct {
        pub fn policy(context: *const SemaContext) names.AccessPolicy {
            return .{ .friend = if (context.options.test_friend) |friend| .{
                .test_module = friend.test_module,
                .production_module = friend.production_module,
            } else null };
        }

        pub fn findStruct(context: *const SemaContext, program: ast.Program, requester_module: []const u8, name: []const u8) ?ast.StructDecl {
            return names.accessibleStruct(policy(context), program, requester_module, name);
        }
        pub fn findUnion(context: *const SemaContext, program: ast.Program, requester_module: []const u8, name: []const u8) ?ast.UnionDecl {
            return names.accessibleUnion(policy(context), program, requester_module, name);
        }
        pub fn findStructAny(program: ast.Program, name: []const u8) ?ast.StructDecl {
            return names.structAny(program, name);
        }
        pub fn findUnionAny(program: ast.Program, name: []const u8) ?ast.UnionDecl {
            return names.unionAny(program, name);
        }
        pub fn findEnum(context: *const SemaContext, program: ast.Program, requester_module: []const u8, name: []const u8) ?ast.EnumDecl {
            return names.accessibleEnum(policy(context), program, requester_module, name);
        }
        pub fn findTypeAlias(context: *const SemaContext, program: ast.Program, requester_module: []const u8, name: []const u8) ?ast.TypeAlias {
            return names.accessibleTypeAlias(policy(context), program, requester_module, name);
        }
        pub fn canAccessDecl(context: *const SemaContext, requester_module: []const u8, decl_module: []const u8, is_pub: bool) bool {
            return names.canAccess(policy(context), requester_module, decl_module, is_pub);
        }
        pub fn nextBindingId(context: *SemaContext) CheckError!identity.BindingId {
            if (context.declarations.next_binding_id >= (@as(u64, 1) << 62)) return error.SemanticFailed;
            const id: identity.BindingId = @fromBackingInt(@intCast(context.declarations.next_binding_id));
            context.declarations.next_binding_id += 1;
            return id;
        }
        pub fn moduleInfo(program: ast.Program, module_name: []const u8) ?ast.ModuleInfo {
            return names.moduleInfo(program, module_name);
        }
        pub fn importBindingLocalName(decl: ast.ImportDecl) []const u8 {
            return names.importBindingLocalName(decl);
        }
        pub fn importItemLocalName(item: ast.ImportItem) []const u8 {
            return names.importItemLocalName(item);
        }
        pub fn importModuleBasename(path: []const u8) []const u8 {
            return names.importModuleBasename(path);
        }
        pub fn findImportedModulePath(program: ast.Program, requester_module: []const u8, alias: []const u8) ?[]const u8 {
            return names.importedModulePath(program, requester_module, alias);
        }
        pub fn findRootPackageImportedModulePath(program: ast.Program, requester_module: []const u8, alias: []const u8) ?[]const u8 {
            return names.rootPackageImportedModulePath(program, requester_module, alias);
        }
        pub fn findNamedImport(program: ast.Program, requester_module: []const u8, local_name: []const u8) ?names.NamedImport {
            return names.namedImport(program, requester_module, local_name);
        }
        pub fn findStructInModule(program: ast.Program, module_name: []const u8, name: []const u8) ?ast.StructDecl {
            return names.structInModule(program, module_name, name);
        }
        /// A method whose owner struct is generic is lowered as a generic
        /// definition, not as an ordinary function.
        pub fn isGenericOwnerMethod(program: ast.Program, function: ast.Function) bool {
            const owner = function.owner orelse return false;
            const decl = findStructInModule(program, function.module_name, owner) orelse return false;
            return decl.type_params.len != 0;
        }
        pub fn findNestedStructInModule(program: ast.Program, module_name: []const u8, owner_name: []const u8, nested_name: []const u8) ?ast.StructDecl {
            return names.nestedStructInModule(program, module_name, owner_name, nested_name);
        }
        pub fn findNestedEnumInModule(program: ast.Program, module_name: []const u8, owner_name: []const u8, nested_name: []const u8) ?ast.EnumDecl {
            return names.nestedEnumInModule(program, module_name, owner_name, nested_name);
        }
        pub fn scopedNameMatches(decl_name: []const u8, owner_name: []const u8, nested_name: []const u8) bool {
            return names.scopedNameMatches(decl_name, owner_name, nested_name);
        }
        pub fn findUnionInModule(program: ast.Program, module_name: []const u8, name: []const u8) ?ast.UnionDecl {
            return names.unionInModule(program, module_name, name);
        }
        pub fn findEnumInModule(program: ast.Program, module_name: []const u8, name: []const u8) ?ast.EnumDecl {
            return names.enumInModule(program, module_name, name);
        }
        pub fn findTypeAliasInModule(program: ast.Program, module_name: []const u8, name: []const u8) ?ast.TypeAlias {
            return names.typeAliasInModule(program, module_name, name);
        }
        pub fn findProtocolInModule(program: ast.Program, module_name: []const u8, name: []const u8) ?ast.ProtocolDecl {
            return names.protocolInModule(program, module_name, name);
        }
        pub fn findAccessibleStruct(context: *const SemaContext, program: ast.Program, requester_module: []const u8, name: []const u8) ?ast.StructDecl {
            return names.accessibleStruct(policy(context), program, requester_module, name);
        }
        pub fn findAccessibleUnion(context: *const SemaContext, program: ast.Program, requester_module: []const u8, name: []const u8) ?ast.UnionDecl {
            return names.accessibleUnion(policy(context), program, requester_module, name);
        }
        pub fn findAccessibleEnum(context: *const SemaContext, program: ast.Program, requester_module: []const u8, name: []const u8) ?ast.EnumDecl {
            return names.accessibleEnum(policy(context), program, requester_module, name);
        }
        pub fn findAccessibleTypeAlias(context: *const SemaContext, program: ast.Program, requester_module: []const u8, name: []const u8) ?ast.TypeAlias {
            return names.accessibleTypeAlias(policy(context), program, requester_module, name);
        }
        pub fn findAccessibleProtocol(context: *const SemaContext, program: ast.Program, requester_module: []const u8, name: []const u8) ?ast.ProtocolDecl {
            return names.accessibleProtocol(policy(context), program, requester_module, name);
        }
        pub fn findNamedImportedFunction(context: *const SemaContext, program: ast.Program, requester_module: []const u8, name: []const u8) ?ast.Function {
            return names.namedImportedFunction(policy(context), program, requester_module, name);
        }
        pub fn findAutoloadFunction(program: ast.Program, name: []const u8) ?ast.Function {
            return names.autoloadFunction(program, name);
        }
        pub fn isAutoloadModule(program: ast.Program, module_name: []const u8) bool {
            return names.isAutoloadModule(program, module_name);
        }
        pub fn findAutoloadStruct(program: ast.Program, name: []const u8) ?ast.StructDecl {
            return names.autoloadStruct(program, name);
        }
        pub fn findAutoloadUnion(program: ast.Program, name: []const u8) ?ast.UnionDecl {
            return names.autoloadUnion(program, name);
        }
        pub fn findAutoloadEnum(program: ast.Program, name: []const u8) ?ast.EnumDecl {
            return names.autoloadEnum(program, name);
        }
        pub fn findAutoloadTypeAlias(program: ast.Program, name: []const u8) ?ast.TypeAlias {
            return names.autoloadTypeAlias(program, name);
        }
        pub fn findAutoloadProtocol(program: ast.Program, name: []const u8) ?ast.ProtocolDecl {
            return names.autoloadProtocol(program, name);
        }
        pub fn registry(context: *SemaContext) ?*identity.Registry {
            return if (context.declarations.registry) |*value| value else null;
        }
        pub fn registeredDeclId(
            context: *SemaContext,
            module_name: []const u8,
            owner: ?[]const u8,
            name: []const u8,
            kind: identity.DeclKind,
        ) registration.Error!identity.DeclId {
            return registration.find(registry(context), module_name, owner, name, kind);
        }
        pub fn maybeRegisteredDeclId(
            context: *SemaContext,
            module_name: []const u8,
            owner: ?[]const u8,
            name: []const u8,
            kind: identity.DeclKind,
        ) ?identity.DeclId {
            return registration.findOptional(registry(context), module_name, owner, name, kind);
        }
        pub fn registerGeneratedDecl(
            context: *SemaContext,
            module_name: []const u8,
            owner: ?[]const u8,
            name: []const u8,
            kind: identity.DeclKind,
        ) registration.Error!?identity.DeclId {
            return registration.registerGenerated(registry(context), module_name, owner, name, kind);
        }
        pub fn findInstantiatedStruct(context: *SemaContext, name: []const u8) ?session.InstantiatedStructDecl {
            for (context.generic.instantiated_structs.items) |decl| {
                if (std.mem.eql(u8, decl.name, name)) return decl;
            }
            return null;
        }
        pub fn lookupEnumDeclById(context: *SemaContext, program: ast.Program, decl_id: identity.DeclId) ?ast.EnumDecl {
            for (program.enums) |decl| {
                const candidate_id = maybeRegisteredDeclId(context, decl.module_name, null, decl.name, .@"enum") orelse continue;
                if (candidate_id == decl_id) return decl;
            }
            return null;
        }
        pub fn lookupStructField(decl: StructLookup, name: []const u8) ?StructFieldLookup {
            return switch (decl.fields) {
                .ast_fields => |fields| for (fields) |field| {
                    if (std.mem.eql(u8, field.name, name)) return .{
                        .name = field.name,
                        .type_id = null,
                        .type_name = field.type_name,
                        .default_value = field.default_value,
                        .is_pub = field.is_pub,
                    };
                } else null,
                .inst_fields => |fields| for (fields) |field| {
                    if (std.mem.eql(u8, field.name, name)) return .{
                        .name = field.name,
                        .type_id = field.type_id,
                        .type_name = null,
                        .default_value = field.default_value,
                        .is_pub = field.is_pub,
                    };
                } else null,
            };
        }
        pub fn lookupStructDeclById(context: *SemaContext, program: ast.Program, decl_id: identity.DeclId) ?StructLookup {
            for (program.structs) |decl| {
                const candidate_id = maybeRegisteredDeclId(context, decl.module_name, null, decl.name, .@"struct") orelse continue;
                if (candidate_id != decl_id) continue;
                return .{
                    .module_name = decl.module_name,
                    .layout = decl.layout,
                    .is_shared_value = decl.is_shared_value,
                    .is_owned_value = decl.is_owned_value,
                    .is_concurrency_shareable = decl.is_concurrency_shareable,
                    .fields = .{ .ast_fields = decl.fields },
                };
            }
            for (context.generic.instantiated_structs.items) |decl| {
                if (decl.id == null or decl.id.? != decl_id) continue;
                return .{
                    .module_name = decl.module_name,
                    .layout = decl.layout,
                    .is_shared_value = decl.is_shared_value,
                    .is_owned_value = decl.is_owned_value,
                    .is_concurrency_shareable = decl.is_concurrency_shareable,
                    .fields = .{ .inst_fields = decl.fields },
                };
            }
            return null;
        }
        pub fn lookupUnionDeclById(context: *SemaContext, program: ast.Program, decl_id: identity.DeclId) ?ast.UnionDecl {
            for (program.unions) |decl| {
                const candidate_id = maybeRegisteredDeclId(context, decl.module_name, null, decl.name, .@"union") orelse continue;
                if (candidate_id == decl_id) return decl;
            }
            return null;
        }
        pub fn canonicalInstantiatedStructTypeId(context: *SemaContext, instance: session.InstantiatedStructDecl) CheckError!semantic_types.TypeId {
            return type_resolution.genericStructInstance(
                canonical.interContext(context),
                instance.base_decl_id orelse return error.SemanticFailed,
                instance.id orelse return error.SemanticFailed,
                instance.type_args,
            );
        }
        pub fn findInstantiatedStructForCanonicalType(context: *SemaContext, type_id: semantic_types.TypeId) ?session.InstantiatedStructDecl {
            for (context.generic.instantiated_structs.items) |decl| {
                if (decl.id == null) continue;
                const candidate = canonicalInstantiatedStructTypeId(context, decl) catch continue;
                if (candidate == type_id) return decl;
            }
            return null;
        }
        pub fn canonicalNominalDeclName(context: *SemaContext, program: ast.Program, type_id: semantic_types.TypeId) ?[]const u8 {
            if (canonical.typeNode(context, type_id).* == .generic_instance) {
                return if (findInstantiatedStructForCanonicalType(context, type_id)) |decl| decl.name else null;
            }
            const decl_id = canonical.nominalDecl(context, type_id) orelse return null;
            for (program.structs) |decl| {
                if (maybeRegisteredDeclId(context, decl.module_name, null, decl.name, .@"struct") == decl_id) return decl.name;
            }
            for (program.unions) |decl| {
                if (maybeRegisteredDeclId(context, decl.module_name, null, decl.name, .@"union") == decl_id) return decl.name;
            }
            for (program.enums) |decl| {
                if (maybeRegisteredDeclId(context, decl.module_name, null, decl.name, .@"enum") == decl_id) return decl.name;
            }
            for (program.aliases) |decl| {
                if (maybeRegisteredDeclId(context, decl.module_name, null, decl.name, .type_alias) == decl_id) return decl.name;
            }
            return null;
        }
        pub fn canonicalStructLookup(context: *SemaContext, program: ast.Program, type_id: semantic_types.TypeId) ?StructLookup {
            return switch (canonical.typeNode(context, type_id).*) {
                .nominal => |nominal| if (nominal.kind == .@"struct")
                    lookupStructDeclById(context, program, nominal.decl_id)
                else
                    null,
                .generic_instance => |instance| if (instance.kind == .@"struct")
                    if (findInstantiatedStructForCanonicalType(context, type_id)) |decl|
                        .{
                            .module_name = decl.module_name,
                            .layout = decl.layout,
                            .is_shared_value = decl.is_shared_value,
                            .is_owned_value = decl.is_owned_value,
                            .is_concurrency_shareable = decl.is_concurrency_shareable,
                            .fields = .{ .inst_fields = decl.fields },
                        }
                    else
                        null
                else
                    null,
                else => null,
            };
        }
        pub fn canonicalUnionLookup(context: *SemaContext, program: ast.Program, type_id: semantic_types.TypeId) ?ast.UnionDecl {
            return switch (canonical.typeNode(context, type_id).*) {
                .nominal => |nominal| if (nominal.kind == .@"union")
                    lookupUnionDeclById(context, program, nominal.decl_id)
                else
                    null,
                else => null,
            };
        }
        pub fn lookupStructAstDeclById(context: *SemaContext, program: ast.Program, decl_id: identity.DeclId) ?ast.StructDecl {
            for (program.structs) |decl| {
                if (maybeRegisteredDeclId(context, decl.module_name, null, decl.name, .@"struct") == decl_id) return decl;
            }
            return null;
        }
        pub fn canonicalBaseStructDecl(context: *SemaContext, program: ast.Program, type_id: semantic_types.TypeId) ?ast.StructDecl {
            return switch (canonical.typeNode(context, type_id).*) {
                .ref_ => |reference| canonicalBaseStructDecl(context, program, reference.target),
                .owned => |target| canonicalBaseStructDecl(context, program, target),
                .nominal => |nominal| if (nominal.kind == .@"struct")
                    lookupStructAstDeclById(context, program, nominal.decl_id)
                else
                    null,
                .generic_instance => |instance| if (instance.kind == .@"struct")
                    lookupStructAstDeclById(context, program, instance.base_decl_id)
                else
                    null,
                else => null,
            };
        }
    };
}
const lexer = @import("../lexer/lexer.zig");
const sir = @import("sir.zig");
const asm_owner = @import("asm.zig");

/// Global binding lookup. Owners instantiate it with their own context and the
/// binding record they carry, so no owner receives a global finder through a
/// host table.
pub fn GlobalLookup(comptime SemaContext: type, comptime GlobalBinding: type) type {
    const names = Lookup(SemaContext);
    return struct {
        pub fn findGlobal(
            context: *const SemaContext,
            program: ast.Program,
            globals: []const GlobalBinding,
            requester_module: []const u8,
            name: []const u8,
        ) ?GlobalBinding {
            for (globals) |global| {
                if (global.owner == null and std.mem.eql(u8, global.module_name, requester_module) and std.mem.eql(u8, global.name, name)) return global;
            }
            if (names.findNamedImport(program, requester_module, name)) |binding| {
                for (globals) |global| {
                    if (global.owner == null and
                        std.mem.eql(u8, global.module_name, binding.module_name) and
                        std.mem.eql(u8, global.name, binding.original_name) and
                        names.canAccessDecl(context, requester_module, global.module_name, global.is_pub)) return global;
                }
            }
            if (findAutoloadGlobal(globals, name)) |global| return global;
            return null;
        }
        pub fn findGlobalInModule(globals: []const GlobalBinding, module_name: []const u8, name: []const u8) ?GlobalBinding {
            return findGlobalMemberInModule(globals, module_name, null, name);
        }
        pub fn findGlobalMemberInModule(globals: []const GlobalBinding, module_name: []const u8, owner: ?[]const u8, name: []const u8) ?GlobalBinding {
            for (globals) |global| {
                if (std.mem.eql(u8, global.module_name, module_name) and optionalEql(global.owner, owner) and std.mem.eql(u8, global.name, name)) return global;
            }
            return null;
        }
        pub fn findAutoloadGlobal(globals: []const GlobalBinding, name: []const u8) ?GlobalBinding {
            for (globals) |global| {
                if (global.owner == null and global.is_pub and global.autoload and std.mem.eql(u8, global.name, name)) return global;
            }
            return null;
        }
    };
}

pub const global_lowering = struct {
    /// Lower and validate top-level globals after declaration identity exists.
    pub fn Owner(comptime host: anytype) type {
        return struct {
            const SemaContext = host.SemaContext;
            const SemaError = host.SemaError;
            const GlobalBinding = host.GlobalBinding;
            const lookup = Lookup(SemaContext);
            const registeredDeclId = lookup.registeredDeclId;
            const parseCanonicalType = host.parseCanonicalType;
            const rejectArrowCallableStorageType = host.rejectArrowCallableStorageType;
            const typeIsOwnedValue = host.typeIsOwnedValue;
            const canonical = type_resolution.Canonical(SemaContext);
            const canonicalTypeKind = canonical.sirType;
            const maybeRecordSemanticHoverFact = host.maybeRecordSemanticHoverFact;
            const rootedBorrowProvenanceForType = host.rootedBorrowProvenanceForType;
            const loweredCAbiSymbolName = host.loweredCAbiSymbolName;
            const isAutoloadModule = lookup.isAutoloadModule;
            const lowerExprInContext = host.lowerExprInContext;
            const expectType = canonical.expectType;
            const recordExprSink = host.recordExprSink;
            const semanticExprMetadata = host.semanticExprMetadata;
            const canonicalTypeNode = canonical.typeNode;
            const resolveComptimeMetadata = host.resolveComptimeMetadata;
            const global_lookup = GlobalLookup(SemaContext, GlobalBinding);
            const findGlobal = global_lookup.findGlobal;
            const findImportedModulePath = lookup.findImportedModulePath;
            const findAccessibleStruct = lookup.findAccessibleStruct;
            const findStructInModule = lookup.findStructInModule;
            const findGlobalInModule = global_lookup.findGlobalInModule;
            const findGlobalMemberInModule = global_lookup.findGlobalMemberInModule;

            pub fn lowerAsmConst(
                context: *SemaContext,
                path: []const u8,
                program: ast.Program,
                globals: []const GlobalBinding,
                decl: ast.AsmConst,
            ) SemaError!sir.AsmConst {
                const allocator = context.allocator;
                const symbol_name = decl.abi_name orelse decl.name;
                if (!isAsmSymbolName(symbol_name)) {
                    try context.diagnostic_context.emitToken(path, decl.name_token, "invalid assembler symbol name `{s}`", .{symbol_name});
                    return SemaError.SemanticFailed;
                }
                if (!(try isDeclarativeGlobalInit(context, path, program, globals, decl.module_name, decl.init))) {
                    try context.diagnostic_context.emitToken(path, decl.name_token, "export asm const initializer must be a compile-time integer expression", .{});
                    return SemaError.SemanticFailed;
                }
                const declared_type_id = try parseCanonicalType(context, path, program, decl.module_name, decl.type_name);
                if (canonicalTypeKind(context, declared_type_id) != .int) {
                    try context.diagnostic_context.emitToken(path, decl.name_token, "export asm const type must be an integer type", .{});
                    return SemaError.SemanticFailed;
                }
                const init = try lowerExprInContext(context, allocator, path, program, decl.module_name, globals, &.{}, decl.init, declared_type_id);
                defer init.expr.destroy(allocator);
                try expectType(context, path, decl.name_token, declared_type_id, init.type_id);
                const value = switch (init.expr.*) {
                    .int => |int| int.value,
                    else => {
                        try context.diagnostic_context.emitToken(path, decl.name_token, "export asm const initializer must resolve to a single integer value", .{});
                        return SemaError.SemanticFailed;
                    },
                };
                return .{
                    .name = symbol_name,
                    .value = value,
                };
            }

            fn isAsmSymbolName(name: []const u8) bool {
                return asm_owner.isAsmSymbolName(name);
            }

            pub const LoweredGlobal = struct {
                global: sir.Global,
                binding: GlobalBinding,
            };

            pub fn lowerGlobal(
                context: *SemaContext,
                path: []const u8,
                program: ast.Program,
                globals: []const GlobalBinding,
                global: ast.Global,
            ) SemaError!LoweredGlobal {
                const allocator = context.allocator;
                const decl_id = try registeredDeclId(context, global.module_name, global.owner, global.name, .global);
                if (global.is_extern) {
                    const declared_type_name = global.type_name orelse {
                        try context.diagnostic_context.emitToken(path, global.name_token, "extern globals require an explicit type", .{});
                        return SemaError.SemanticFailed;
                    };
                    const declared_type_id = try parseCanonicalType(context, path, program, global.module_name, declared_type_name);
                    try rejectArrowCallableStorageType(context, path, global.name_token, declared_type_id, "extern global");
                    if (try typeIsOwnedValue(context, path, program, declared_type_id)) {
                        try context.diagnostic_context.emitToken(path, global.name_token, "resource-valued extern globals are not supported", .{});
                        return SemaError.SemanticFailed;
                    }
                    const is_symbol_addr = canonicalTypeKind(context, declared_type_id) == .raw;
                    if (is_symbol_addr and global.is_mutable) {
                        try context.diagnostic_context.emitToken(path, global.name_token, "raw-pointer extern globals are imported symbol addresses and must be `const`", .{});
                        return SemaError.SemanticFailed;
                    }
                    try maybeRecordSemanticHoverFact(
                        context,
                        allocator,
                        path,
                        program,
                        global.module_name,
                        global.name_token,
                        global.name,
                        declared_type_id,
                        try rootedBorrowProvenanceForType(context, path, program, global.module_name, declared_type_id, .global, global.name),
                    );
                    return .{
                        .global = .{
                            .decl_id = decl_id,
                            .module_name = global.module_name,
                            .owner = global.owner,
                            .name = global.name,
                            .is_mutable = global.is_mutable,
                            .is_extern = true,
                            .abi_name = try loweredCAbiSymbolName(context, allocator, global.module_name, global.name, global.abi_name),
                            .is_symbol_addr = is_symbol_addr,
                            .type_id = declared_type_id,
                            .init = null,
                        },
                        .binding = .{
                            .id = decl_id,
                            .name = global.name,
                            .owner = global.owner,
                            .module_name = global.module_name,
                            .is_pub = global.is_pub,
                            .autoload = isAutoloadModule(program, global.module_name),
                            .is_mutable = global.is_mutable,
                            .is_extern = true,
                            .is_symbol_addr = is_symbol_addr,
                            .type_id = declared_type_id,
                            .init = null,
                        },
                    };
                }

                const declared_type_id = if (global.type_name) |type_name|
                    try parseCanonicalType(context, path, program, global.module_name, type_name)
                else
                    null;
                const init = try lowerExprInContext(context, allocator, path, program, global.module_name, globals, &.{}, global.init.?, declared_type_id);
                errdefer init.expr.destroy(allocator);
                const final_type_id = declared_type_id orelse init.type_id;
                try rejectArrowCallableStorageType(context, path, global.name_token, final_type_id, "top-level binding");
                try expectType(context, path, global.name_token, final_type_id, init.type_id);

                if (!(try isStaticGlobalInit(path, program, globals, global.module_name, init.expr))) {
                    try context.diagnostic_context.emitToken(path, global.name_token, "top-level initializer must be declarative; move runtime setup into a function", .{});
                    return SemaError.SemanticFailed;
                }
                try validateStaticGlobalOperations(context, path, global.name_token, globals, global.module_name, init.expr);

                if (!isDeclarativeGlobalType(context, final_type_id)) {
                    try context.diagnostic_context.emitToken(path, global.name_token, "top-level binding type must be declarative and copy-valued", .{});
                    return SemaError.SemanticFailed;
                }
                if (try typeIsOwnedValue(context, path, program, final_type_id)) {
                    try context.diagnostic_context.emitToken(path, global.name_token, "resource-valued top-level bindings are not supported", .{});
                    return SemaError.SemanticFailed;
                }
                try recordExprSink(context, init.expr, .initialize);

                try maybeRecordSemanticHoverFact(
                    context,
                    allocator,
                    path,
                    program,
                    global.module_name,
                    global.name_token,
                    global.name,
                    final_type_id,
                    init.provenance,
                );

                return .{
                    .global = .{
                        .decl_id = decl_id,
                        .module_name = global.module_name,
                        .owner = global.owner,
                        .name = global.name,
                        .is_mutable = global.is_mutable,
                        .is_extern = false,
                        .abi_name = global.abi_name,
                        .is_symbol_addr = false,
                        .type_id = final_type_id,
                        .init = init.expr,
                    },
                    .binding = .{
                        .id = decl_id,
                        .name = global.name,
                        .owner = global.owner,
                        .module_name = global.module_name,
                        .is_pub = global.is_pub,
                        .autoload = isAutoloadModule(program, global.module_name),
                        .is_mutable = global.is_mutable,
                        .is_extern = false,
                        .is_symbol_addr = false,
                        .type_id = final_type_id,
                        .init = init.expr,
                    },
                };
            }

            fn validateStaticGlobalOperations(
                context: *SemaContext,
                path: []const u8,
                token: lexer.Token,
                globals: []const GlobalBinding,
                current_module: []const u8,
                expr: *const sir.Expr,
            ) SemaError!void {
                switch (expr.*) {
                    .union_case => |case| if (case.value) |value| {
                        try validateStaticGlobalOperations(context, path, token, globals, current_module, value);
                    },
                    .unary => |unary| try validateStaticGlobalOperations(context, path, token, globals, current_module, unary.expr),
                    .binary => |binary| {
                        try validateStaticGlobalOperations(context, path, token, globals, current_module, binary.left);
                        try validateStaticGlobalOperations(context, path, token, globals, current_module, binary.right);
                        const metadata = semanticExprMetadata(context, expr) orelse return error.SemanticFailed;
                        try validateStaticIntegerBinary(
                            context,
                            path,
                            token,
                            globals,
                            current_module,
                            metadata.type_id,
                            binary.op,
                            binary.left,
                            binary.right,
                        );
                    },
                    .array_literal => |literal| for (literal.items) |item| {
                        try validateStaticGlobalOperations(context, path, token, globals, current_module, item);
                    },
                    .tuple_literal => |literal| for (literal.items) |item| {
                        try validateStaticGlobalOperations(context, path, token, globals, current_module, item);
                    },
                    .struct_literal => |literal| for (literal.fields) |field| {
                        try validateStaticGlobalOperations(context, path, token, globals, current_module, field.value);
                    },
                    else => {},
                }
            }

            fn validateStaticIntegerBinary(
                context: *SemaContext,
                path: []const u8,
                token: lexer.Token,
                globals: []const GlobalBinding,
                current_module: []const u8,
                result_type_id: semantic_types.TypeId,
                op: sir.BinaryOp,
                left: *const sir.Expr,
                right: *const sir.Expr,
            ) SemaError!void {
                if (canonicalTypeKind(context, result_type_id) != .int) return;
                const value = staticIntegerValue(globals, current_module, right, 0) orelse return;
                switch (op) {
                    .div, .mod => {
                        if (value == 0) {
                            try context.diagnostic_context.emitToken(path, token, "integer divisor must not be zero", .{});
                            return SemaError.SemanticFailed;
                        }
                        if (op == .div and value == -1 and staticIntegerValue(globals, current_module, left, 0) == std.math.minInt(i64)) {
                            try context.diagnostic_context.emitToken(path, token, "integer division result is outside the compiler integer range", .{});
                            return SemaError.SemanticFailed;
                        }
                    },
                    .shl, .shr => {
                        const bits: u16 = switch (canonicalTypeNode(context, result_type_id).*) {
                            .integer => |integer| integer.bits,
                            .inferred_integer => 64,
                            else => unreachable,
                        };
                        if (value < 0 or value >= bits) {
                            try context.diagnostic_context.emitToken(path, token, "shift count must be between 0 and {d} for this integer type", .{bits - 1});
                            return SemaError.SemanticFailed;
                        }
                    },
                    else => {},
                }
            }

            fn staticIntegerValue(
                globals: []const GlobalBinding,
                current_module: []const u8,
                expr: *const sir.Expr,
                depth: usize,
            ) ?i64 {
                if (depth >= 64) return null;
                return switch (expr.*) {
                    .int => |int| int.value,
                    .unary => |unary| if (unary.op == .negate) blk: {
                        const value = staticIntegerValue(globals, current_module, unary.expr, depth + 1) orelse break :blk null;
                        break :blk if (value == std.math.minInt(i64)) null else -value;
                    } else null,
                    .local => |name| blk: {
                        const global = findGlobalInModule(globals, current_module, name) orelse break :blk null;
                        break :blk staticIntegerValue(globals, global.module_name, global.init orelse break :blk null, depth + 1);
                    },
                    .global_ref => |global_ref| blk: {
                        const global = findGlobalMemberInModule(globals, global_ref.module_name, global_ref.owner, global_ref.name) orelse break :blk null;
                        break :blk staticIntegerValue(globals, global.module_name, global.init orelse break :blk null, depth + 1);
                    },
                    .binary => |binary| blk: {
                        const left = staticIntegerValue(globals, current_module, binary.left, depth + 1) orelse break :blk null;
                        const right = staticIntegerValue(globals, current_module, binary.right, depth + 1) orelse break :blk null;
                        break :blk switch (binary.op) {
                            .add, .wrap_add => left +% right,
                            .sub, .wrap_sub => left -% right,
                            .mul, .wrap_mul => left *% right,
                            .div => if (right == 0 or (left == std.math.minInt(i64) and right == -1)) null else @divTrunc(left, right),
                            .mod => if (right == 0) null else if (left == std.math.minInt(i64) and right == -1) 0 else @rem(left, right),
                            .shl => if (right < 0 or right >= 64) null else left << @as(u6, @intCast(right)),
                            .shr => if (right < 0 or right >= 64) null else left >> @as(u6, @intCast(right)),
                            .bit_and => left & right,
                            .bit_or => left | right,
                            .bit_xor => left ^ right,
                            else => null,
                        };
                    },
                    else => null,
                };
            }

            pub fn isDeclarativeGlobalInit(context: *SemaContext, path: []const u8, program: ast.Program, globals: []const GlobalBinding, current_module: []const u8, expr: *ast.Expr) SemaError!bool {
                return switch (expr.*) {
                    .int, .string, .bool, .none, .enum_case => true,
                    .union_case => |case| blk: {
                        if (case.value) |value| break :blk try isDeclarativeGlobalInit(context, path, program, globals, current_module, value);
                        break :blk true;
                    },
                    .is_test => false,
                    .cast => false,
                    .@"comptime" => |ct| blk: {
                        _ = try resolveComptimeMetadata(context, path, program, current_module, ct.expr, ct.token);
                        break :blk true;
                    },
                    .name => |name| blk: {
                        const global = findGlobal(context, program, globals, current_module, name.text) orelse break :blk false;
                        break :blk !global.is_extern;
                    },
                    .field => |field| blk: {
                        if (field.object.* == .name) {
                            if (findImportedModulePath(program, current_module, field.object.name.text)) |module_name| {
                                const global = findGlobalInModule(globals, module_name, field.field) orelse break :blk false;
                                break :blk global.is_pub and !global.is_mutable and !global.is_extern;
                            }
                            if (findAccessibleStruct(context, program, current_module, field.object.name.text)) |decl| {
                                const global = findGlobalMemberInModule(globals, decl.module_name, decl.name, field.field) orelse break :blk false;
                                break :blk (std.mem.eql(u8, current_module, decl.module_name) or global.is_pub) and !global.is_mutable and !global.is_extern;
                            }
                            break :blk false;
                        }
                        if (field.object.* == .field and field.object.field.object.* == .name) {
                            const namespace = field.object.field;
                            const module_name = findImportedModulePath(program, current_module, namespace.object.name.text) orelse break :blk false;
                            const decl = findStructInModule(program, module_name, namespace.field) orelse break :blk false;
                            if (!decl.is_pub) break :blk false;
                            const global = findGlobalMemberInModule(globals, module_name, decl.name, field.field) orelse break :blk false;
                            break :blk global.is_pub and !global.is_mutable and !global.is_extern;
                        }
                        break :blk false;
                    },
                    .unary => |unary| (unary.op == .not or unary.op == .bit_not or unary.op == .negate) and try isDeclarativeGlobalInit(context, path, program, globals, current_module, unary.expr),
                    .binary => |binary| (try isDeclarativeGlobalInit(context, path, program, globals, current_module, binary.left)) and (try isDeclarativeGlobalInit(context, path, program, globals, current_module, binary.right)),
                    .array_literal => |literal| blk: {
                        for (literal.items) |item| {
                            if (!(try isDeclarativeGlobalInit(context, path, program, globals, current_module, item))) break :blk false;
                        }
                        break :blk true;
                    },
                    .sequence_repeat => |repeat| blk: {
                        if (!(try isDeclarativeGlobalInit(context, path, program, globals, current_module, repeat.count))) break :blk false;
                        for (repeat.items) |item| {
                            if (!(try isDeclarativeGlobalInit(context, path, program, globals, current_module, item))) break :blk false;
                        }
                        break :blk true;
                    },
                    .typed_sequence_literal => |literal| blk: {
                        for (literal.items) |item| {
                            if (!(try isDeclarativeGlobalInit(context, path, program, globals, current_module, item))) break :blk false;
                        }
                        break :blk true;
                    },
                    .fixed_array_construct => |construct| blk: {
                        for (construct.items) |item| {
                            if (!(try isDeclarativeGlobalInit(context, path, program, globals, current_module, item))) break :blk false;
                        }
                        break :blk true;
                    },
                    .struct_literal => |literal| blk: {
                        for (literal.fields) |field| {
                            if (!(try isDeclarativeGlobalInit(context, path, program, globals, current_module, field.value))) break :blk false;
                        }
                        break :blk true;
                    },
                    .keyed_literal => |literal| blk: {
                        for (literal.entries) |entry| {
                            if (!(try isDeclarativeGlobalInit(context, path, program, globals, current_module, entry.value))) break :blk false;
                        }
                        break :blk true;
                    },
                    else => false,
                };
            }

            fn isStaticGlobalInit(path: []const u8, program: ast.Program, globals: []const GlobalBinding, current_module: []const u8, expr: *const sir.Expr) SemaError!bool {
                return switch (expr.*) {
                    .int, .float, .bool, .string, .none, .enum_case, .function_ref => true,
                    .union_case => |case| blk: {
                        if (case.value) |value| break :blk try isStaticGlobalInit(path, program, globals, current_module, value);
                        break :blk true;
                    },
                    .global_ref => |global_ref| blk: {
                        const global = findGlobalMemberInModule(globals, global_ref.module_name, global_ref.owner, global_ref.name) orelse break :blk false;
                        if (global.is_extern) break :blk false;
                        if (!std.mem.eql(u8, global_ref.module_name, current_module) and !global.is_pub) break :blk false;
                        break :blk true;
                    },
                    .local => |name| blk: {
                        const global = findGlobalInModule(globals, current_module, name) orelse break :blk false;
                        break :blk !global.is_extern;
                    },
                    .unary => |unary| (unary.op == .not or unary.op == .bit_not or unary.op == .negate) and try isStaticGlobalInit(path, program, globals, current_module, unary.expr),
                    .binary => |binary| (try isStaticGlobalInit(path, program, globals, current_module, binary.left)) and
                        (try isStaticGlobalInit(path, program, globals, current_module, binary.right)),
                    .array_default => true,
                    .array_literal => |literal| blk: {
                        for (literal.items) |item| {
                            if (!(try isStaticGlobalInit(path, program, globals, current_module, item))) break :blk false;
                        }
                        break :blk true;
                    },
                    .tuple_literal => |literal| blk: {
                        for (literal.items) |item| {
                            if (!(try isStaticGlobalInit(path, program, globals, current_module, item))) break :blk false;
                        }
                        break :blk true;
                    },
                    .struct_literal => |literal| blk: {
                        for (literal.fields) |field| {
                            if (!(try isStaticGlobalInit(path, program, globals, current_module, field.value))) break :blk false;
                        }
                        break :blk true;
                    },
                    else => false,
                };
            }

            fn isDeclarativeGlobalType(context: *SemaContext, type_id: semantic_types.TypeId) bool {
                return switch (canonicalTypeNode(context, type_id).*) {
                    .inferred_integer, .integer, .inferred_float, .float => true,
                    .primitive => |primitive| primitive == .string or primitive == .bool,
                    .nominal => |nominal| switch (nominal.kind) {
                        .@"enum", .@"struct" => true,
                        .type_alias => if (nominal.underlying) |underlying| isDeclarativeGlobalType(context, underlying) else false,
                        else => false,
                    },
                    .generic_instance => |instance| instance.kind == .@"struct",
                    .optional => |payload| isDeclarativeGlobalType(context, payload),
                    .array => |array| isDeclarativeGlobalType(context, array.item),
                    .tuple => |members| blk: {
                        for (members) |member| {
                            if (!isDeclarativeGlobalType(context, member)) break :blk false;
                        }
                        break :blk true;
                    },
                    else => false,
                };
            }
        };
    }
};

/// Lower enum, union and struct declarations into SIR, and validate the
/// declaration attributes that gate that lowering.
pub const lowering = struct {
    pub fn Owner(comptime host: anytype) type {
        return struct {
            const SemaContext = host.SemaContext;
            const SemaError = host.SemaError;
            const lookup = Lookup(SemaContext);
            const registeredDeclId = lookup.registeredDeclId;
            const canonical = type_resolution.Canonical(SemaContext);
            const canonicalPrimitiveTypeId = canonical.primitiveType;
            const canonicalTypeKind = canonical.sirType;
            const canonicalTypeNode = canonical.typeNode;
            const formatType = canonical.formatType;
            const parseCanonicalType = host.parseCanonicalType;
            const parseType = host.parseType;
            const canonicalStructLookup = lookup.canonicalStructLookup;
            const lookupEnumDeclById = lookup.lookupEnumDeclById;
            const validateSliceViewMethods = host.validateSliceViewMethods;
            const validateSyntaxMethods = host.validateSyntaxMethods;
            const ownershipClass = host.ownershipClass;
            const canonicalTypeIsCStructFieldType = host.canonicalTypeIsCStructFieldType;
            const emitCStructFieldTypeError = host.emitCStructFieldTypeError;

            pub fn lowerEnum(context: *SemaContext, decl: ast.EnumDecl) SemaError!sir.EnumDecl {
                const allocator = context.allocator;
                var cases: std.ArrayListUnmanaged(sir.EnumCase) = .empty;
                errdefer cases.deinit(allocator);

                var next_value: i64 = 0;
                for (decl.cases) |case| {
                    const value = case.value orelse next_value;
                    try cases.append(allocator, .{ .name = case.name, .value = value });
                    next_value = value + 1;
                }

                return .{
                    .decl_id = try registeredDeclId(context, decl.module_name, null, decl.name, .@"enum"),
                    .module_name = decl.module_name,
                    .name = decl.name,
                    .layout = switch (decl.layout) {
                        .normal => .normal,
                        .c => .c,
                        .flags => .flags,
                    },
                    .repr_name = decl.repr_name,
                    .cases = try cases.toOwnedSlice(allocator),
                };
            }

            pub fn lowerUnion(context: *SemaContext, path: []const u8, program: ast.Program, decl: ast.UnionDecl) SemaError!sir.UnionDecl {
                const allocator = context.allocator;
                var fields: std.ArrayListUnmanaged(sir.UnionField) = .empty;
                errdefer fields.deinit(allocator);

                switch (decl.kind) {
                    .named_cases => {
                        for (decl.fields) |field| {
                            const lowered_type = if (field.type_name) |type_name|
                                try parseCanonicalType(context, path, program, decl.module_name, type_name)
                            else
                                null;
                            try fields.append(allocator, .{
                                .name = field.name,
                                .type_id = lowered_type orelse try canonicalPrimitiveTypeId(context, .void),
                                .has_payload = field.type_name != null,
                            });
                        }
                    },
                    .type_union => {
                        if (decl.variants.len < 2) {
                            try context.diagnostic_context.emitToken(path, decl.name_token, "type union `{s}` must contain at least two variants", .{decl.name});
                            return SemaError.SemanticFailed;
                        }
                        var variant_types: std.ArrayListUnmanaged(semantic_types.TypeId) = .empty;
                        defer variant_types.deinit(allocator);
                        for (decl.variants) |variant| {
                            const lowered_type = try parseCanonicalType(context, path, program, decl.module_name, variant);
                            if (canonicalTypeKind(context, lowered_type) == .void or canonicalTypeKind(context, lowered_type) == .ref) {
                                const display = try formatType(context, lowered_type);
                                defer allocator.free(display);
                                try context.diagnostic_context.emitToken(path, variant.token, "type-union variant cannot be {s}", .{display});
                                return SemaError.SemanticFailed;
                            }
                            for (variant_types.items) |existing| {
                                if (existing == lowered_type) {
                                    const display = try formatType(context, lowered_type);
                                    defer allocator.free(display);
                                    try context.diagnostic_context.emitToken(path, variant.token, "duplicate type-union variant `{s}`", .{display});
                                    return SemaError.SemanticFailed;
                                }
                            }
                            const case_name = blk: {
                                const owned = try formatType(context, lowered_type);
                                errdefer allocator.free(owned);
                                try context.output.generated_strings.append(allocator, owned);
                                break :blk owned;
                            };
                            try variant_types.append(allocator, lowered_type);
                            try fields.append(allocator, .{
                                .name = case_name,
                                .type_id = lowered_type,
                                .has_payload = true,
                            });
                        }
                    },
                }

                return .{
                    .decl_id = try registeredDeclId(context, decl.module_name, null, decl.name, .@"union"),
                    .module_name = decl.module_name,
                    .name = decl.name,
                    .layout = switch (decl.layout) {
                        .normal => .normal,
                        .c => .c,
                    },
                    .kind = switch (decl.kind) {
                        .named_cases => .named_cases,
                        .type_union => .type_union,
                    },
                    .fields = try fields.toOwnedSlice(allocator),
                };
            }

            pub fn lowerStruct(context: *SemaContext, path: []const u8, program: ast.Program, decl: ast.StructDecl) SemaError!sir.StructDecl {
                const allocator = context.allocator;
                var fields: std.ArrayListUnmanaged(sir.FieldDecl) = .empty;
                errdefer fields.deinit(allocator);

                for (decl.fields) |field| {
                    const type_id = try parseCanonicalType(context, path, program, decl.module_name, field.type_name);
                    if (decl.layout == .@"packed") {
                        if (try packedFieldViolation(context, program, type_id)) |violation| {
                            try emitPackedFieldViolation(context, path, field.name_token, field.name, violation);
                            return SemaError.SemanticFailed;
                        }
                    }
                    try fields.append(allocator, .{
                        .name = field.name,
                        .type_id = type_id,
                    });
                }

                return .{
                    .decl_id = try registeredDeclId(context, decl.module_name, null, decl.name, .@"struct"),
                    .module_name = decl.module_name,
                    .name = decl.name,
                    .layout = switch (decl.layout) {
                        .normal => .normal,
                        .c => .c,
                        .@"packed" => .@"packed",
                    },
                    .is_shared_value = decl.is_shared_value,
                    .shared_runtime = sharedRuntimeForContract(decl.module_name, decl.name),
                    .drop_runtime = dropRuntimeForContract(decl.module_name, decl.name),
                    .fields = try fields.toOwnedSlice(allocator),
                };
            }

            pub const PackedFieldViolation = union(enum) {
                bool_field,
                float_field: semantic_types.TypeId,
                enum_without_repr: semantic_types.TypeId,
                non_packed_struct: semantic_types.TypeId,
                fixed_array,
                pointer_like,
                other: semantic_types.TypeId,
            };

            pub fn packedFieldViolation(context: *SemaContext, program: ast.Program, type_id: semantic_types.TypeId) SemaError!?PackedFieldViolation {
                return switch (canonicalTypeKind(context, type_id)) {
                    .int, .rune => null,
                    .@"enum" => if (isPackedEnumType(context, program, type_id))
                        null
                    else
                        .{ .enum_without_repr = type_id },
                    .@"struct" => if (try isPackedStructType(context, program, type_id))
                        null
                    else
                        .{ .non_packed_struct = type_id },
                    .bool => .bool_field,
                    .float => .{ .float_field = type_id },
                    .array => .fixed_array,
                    .function, .ref, .owned, .raw => .pointer_like,
                    .arrow_callable => .{ .other = type_id },
                    .@"union", .string, .void, .optional, .dense_array, .sparse_array, .slice, .result => .{ .other = type_id },
                };
            }

            pub fn emitPackedFieldViolation(context: *SemaContext, path: []const u8, token: lexer.Token, field_name: []const u8, violation: PackedFieldViolation) SemaError!void {
                switch (violation) {
                    .bool_field => try context.diagnostic_context.emitToken(path, token, "packed struct field `{s}` cannot use `bool`; use `u1` or `i1` for bit fields", .{field_name}),
                    .float_field => |type_id| {
                        const name = try formatType(context, type_id);
                        defer context.allocator.free(name);
                        try context.diagnostic_context.emitToken(path, token, "packed struct field `{s}` cannot use floating-point type `{s}`; use an integer, int-backed enum, or nested packed struct", .{ field_name, name });
                    },
                    .enum_without_repr => |type_id| {
                        const name = try formatType(context, type_id);
                        defer context.allocator.free(name);
                        try context.diagnostic_context.emitToken(path, token, "packed struct field `{s}` uses enum `{s}` without an explicit integer representation", .{ field_name, name });
                    },
                    .non_packed_struct => |type_id| {
                        const name = try formatType(context, type_id);
                        defer context.allocator.free(name);
                        try context.diagnostic_context.emitToken(path, token, "packed struct field `{s}` must use a nested packed struct; `{s}` is not packed", .{ field_name, name });
                    },
                    .fixed_array => try context.diagnostic_context.emitToken(path, token, "packed struct field `{s}` cannot use fixed arrays; use integer fields or nested packed structs instead", .{field_name}),
                    .pointer_like => try context.diagnostic_context.emitToken(path, token, "packed struct field `{s}` cannot use pointer-like storage; use an integer, int-backed enum, or nested packed struct", .{field_name}),
                    .other => |type_id| {
                        const name = try formatType(context, type_id);
                        defer context.allocator.free(name);
                        try context.diagnostic_context.emitToken(path, token, "packed struct field `{s}` cannot use `{s}`; use an integer, int-backed enum, or nested packed struct", .{ field_name, name });
                    },
                }
            }

            fn isPackedEnumType(context: *SemaContext, program: ast.Program, type_id: semantic_types.TypeId) bool {
                const node = canonicalTypeNode(context, type_id);
                if (node.* != .nominal or node.nominal.kind != .@"enum") return false;
                const decl = lookupEnumDeclById(context, program, node.nominal.decl_id) orelse return false;
                return decl.repr_name != null;
            }

            pub fn checkStructs(context: *SemaContext, path: []const u8, program: ast.Program) SemaError!void {
                for (program.structs) |decl| {
                    try validateSliceViewMethods(context, path, decl);
                    try validateSyntaxMethods(context, path, decl);
                    if (decl.is_concurrency_shareable and !intrinsics.moduleHasCapability(decl.module_name, .declare_concurrency_shareable)) {
                        try context.diagnostic_context.emitToken(path, decl.name_token, "attribute `concurrency.shareable` is only supported in std/core modules", .{});
                        return SemaError.SemanticFailed;
                    }
                    if (decl.is_shared_value and !intrinsics.moduleHasCapability(decl.module_name, .declare_concurrency_shareable)) {
                        try context.diagnostic_context.emitToken(path, decl.name_token, "attribute `shared_value` is only supported in std/core modules", .{});
                        return SemaError.SemanticFailed;
                    }
                    if (decl.is_shared_value and sharedRuntimeForContract(decl.module_name, decl.name) == .none) {
                        try context.diagnostic_context.emitToken(path, decl.name_token, "shared ownership requires a trusted retain and release runtime contract", .{});
                        return SemaError.SemanticFailed;
                    }
                    if (decl.is_owned_value and !intrinsics.moduleHasCapability(decl.module_name, .declare_concurrency_shareable)) {
                        try context.diagnostic_context.emitToken(path, decl.name_token, "attribute `ownership.owned` is only supported in std/core modules", .{});
                        return SemaError.SemanticFailed;
                    }

                    for (decl.fields) |field| {
                        if (decl.is_shared_value and !generics.typeNameContainsParam(field.type_name, decl.type_params)) {
                            const field_ty = try parseType(context, path, program, decl.module_name, field.type_name);
                            if (try ownershipClass(context, path, program, decl.module_name, field_ty) == .owned) {
                                try context.diagnostic_context.emitToken(path, field.name_token, "shared owner cannot contain a unique field without a checked duplication contract", .{});
                                return SemaError.SemanticFailed;
                            }
                        }
                        if (type_resolution.isPlainCStrTypeName(field.type_name)) {
                            try context.diagnostic_context.emitToken(path, field.name_token, "`c_str` is a borrowed C string view and cannot be stored in a struct; use `*const c_char` for stored C pointers", .{});
                            return SemaError.SemanticFailed;
                        }
                        if (decl.layout == .c) {
                            if (decl.type_params.len != 0 and generics.typeNameContainsParam(field.type_name, decl.type_params)) {
                                continue;
                            }
                            const field_ty = try parseType(context, path, program, decl.module_name, field.type_name);
                            if (!try canonicalTypeIsCStructFieldType(context, path, program, field_ty)) {
                                try emitCStructFieldTypeError(context, path, program, decl.module_name, field.name, field.name_token, field_ty);
                                return SemaError.SemanticFailed;
                            }
                        }
                    }
                }
            }

            pub fn sharedRuntimeForContract(module_name: []const u8, type_name: []const u8) sir.SharedRuntime {
                const contract = intrinsics.definition(.std_own_arc_type);
                if (std.mem.eql(u8, module_name, contract.module_name.?) and
                    std.mem.eql(u8, type_name, contract.name))
                {
                    return .arc;
                }
                return .none;
            }

            pub fn dropRuntimeForContract(module_name: []const u8, type_name: []const u8) sir.DropRuntime {
                if (std.mem.eql(u8, module_name, "std.thread") and std.mem.eql(u8, type_name, "Task")) return .task_discard;
                return .none;
            }

            pub fn isPackedFieldType(context: *SemaContext, program: ast.Program, type_id: semantic_types.TypeId) SemaError!bool {
                return (try packedFieldViolation(context, program, type_id)) == null;
            }

            pub fn isPackedStructType(context: *SemaContext, program: ast.Program, type_id: semantic_types.TypeId) SemaError!bool {
                const decl = canonicalStructLookup(context, program, type_id) orelse return false;
                if (decl.layout != .@"packed") return false;
                switch (decl.fields) {
                    .ast_fields => |fields| for (fields) |field| {
                        const field_type_id = try parseCanonicalType(context, "", program, decl.module_name, field.type_name);
                        if (!try isPackedFieldType(context, program, field_type_id)) return false;
                    },
                    .inst_fields => |fields| for (fields) |field| {
                        if (!try isPackedFieldType(context, program, field.type_id)) return false;
                    },
                }
                return true;
            }
        };
    }
};

const std = @import("std");
const ast = @import("../compiler/parser/ast.zig");
const diagnostics = @import("../compiler/diagnostics.zig");
const lexer = @import("../compiler/lexer/token.zig");
const loader = @import("../compiler/loader.zig");

pub fn renderHeader(allocator: std.mem.Allocator, path: []const u8, loaded: loader.LoadedProgram) ![]u8 {
    var diagnostic_context = diagnostics.Context.discarded();
    return renderHeaderWithDiagnostics(allocator, path, loaded, &diagnostic_context);
}

pub fn renderHeaderWithDiagnostics(
    allocator: std.mem.Allocator,
    path: []const u8,
    loaded: loader.LoadedProgram,
    diagnostic_context: *diagnostics.Context,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const root_module_name = loaded.root_module_name;
    const guard = try headerGuard(allocator, path, root_module_name);
    defer allocator.free(guard);

    const prefix = try std.fmt.allocPrint(allocator, "#ifndef {s}\n#define {s}\n\n#include <cyna.h>\n\n", .{ guard, guard });
    defer allocator.free(prefix);
    try out.appendSlice(allocator, prefix);

    var needed_enums: std.StringHashMapUnmanaged(void) = .empty;
    defer needed_enums.deinit(allocator);
    var needed_structs: std.StringHashMapUnmanaged(void) = .empty;
    defer needed_structs.deinit(allocator);
    var needed_aliases: std.StringHashMapUnmanaged(void) = .empty;
    defer needed_aliases.deinit(allocator);
    var collecting_aliases: std.StringHashMapUnmanaged(void) = .empty;
    defer collecting_aliases.deinit(allocator);

    for (loaded.program.functions) |function| {
        if (!isHeaderRootModule(function.module_name, root_module_name)) continue;
        if (!function.is_export or function.calling_convention != .c) continue;
        for (function.params) |param| {
            try collectHeaderTypeDeps(diagnostic_context, allocator, path, loaded.program, root_module_name, &needed_enums, &needed_structs, &needed_aliases, &collecting_aliases, param.type_name, false);
        }
        if (function.return_type) |return_type| {
            try collectHeaderTypeDeps(diagnostic_context, allocator, path, loaded.program, root_module_name, &needed_enums, &needed_structs, &needed_aliases, &collecting_aliases, return_type, false);
        }
    }

    var emitted_any = false;

    for (loaded.program.enums) |decl| {
        if (!isHeaderRootModule(decl.module_name, root_module_name)) continue;
        if (decl.layout != .c and decl.layout != .flags) continue;
        if (!needed_enums.contains(decl.name)) continue;
        try renderEnumDecl(allocator, &out, decl);
        emitted_any = true;
    }

    var wrote_struct_forwards = false;
    for (loaded.program.structs) |decl| {
        if (!isHeaderRootModule(decl.module_name, root_module_name)) continue;
        if (decl.layout != .c) continue;
        if (!needed_structs.contains(decl.name)) continue;
        const forward = try std.fmt.allocPrint(allocator, "typedef struct {s} {s};\n", .{ decl.name, decl.name });
        defer allocator.free(forward);
        try out.appendSlice(allocator, forward);
        wrote_struct_forwards = true;
        emitted_any = true;
    }
    if (wrote_struct_forwards) {
        try out.appendSlice(allocator, "\n");
    }

    var rendered_aliases: std.StringHashMapUnmanaged(void) = .empty;
    defer rendered_aliases.deinit(allocator);
    var rendering_aliases: std.StringHashMapUnmanaged(void) = .empty;
    defer rendering_aliases.deinit(allocator);
    for (loaded.program.aliases) |alias| {
        if (!isHeaderRootModule(alias.module_name, root_module_name)) continue;
        if (!alias.is_pub) continue;
        if (!needed_aliases.contains(alias.name)) continue;
        try renderAliasDeclRecursive(diagnostic_context, allocator, path, loaded.program, root_module_name, &out, &rendered_aliases, &rendering_aliases, alias);
        emitted_any = true;
    }
    if (rendered_aliases.count() != 0) {
        try out.appendSlice(allocator, "\n");
    }

    var rendered_abi_helpers: std.StringHashMapUnmanaged(void) = .empty;
    defer rendered_abi_helpers.deinit(allocator);
    for (loaded.program.functions) |function| {
        if (!isHeaderRootModule(function.module_name, root_module_name)) continue;
        if (!function.is_export or function.calling_convention != .c) continue;
        for (function.params) |param| {
            try renderAbiHelperTypes(allocator, &out, &rendered_abi_helpers, param.type_name);
        }
        if (function.return_type) |return_type| {
            try renderAbiHelperTypes(allocator, &out, &rendered_abi_helpers, return_type);
        }
    }
    if (rendered_abi_helpers.count() != 0) {
        try out.appendSlice(allocator, "\n");
    }

    var rendered_structs: std.StringHashMapUnmanaged(void) = .empty;
    defer rendered_structs.deinit(allocator);
    var rendering_structs: std.StringHashMapUnmanaged(void) = .empty;
    defer rendering_structs.deinit(allocator);
    for (loaded.program.structs) |decl| {
        if (!isHeaderRootModule(decl.module_name, root_module_name)) continue;
        if (decl.layout != .c) continue;
        if (!needed_structs.contains(decl.name)) continue;
        try renderStructDeclRecursive(diagnostic_context, allocator, path, loaded.program, root_module_name, &out, needed_structs, &rendered_structs, &rendering_structs, decl);
    }

    for (loaded.program.functions) |function| {
        if (!isHeaderRootModule(function.module_name, root_module_name)) continue;
        if (!function.is_export or function.calling_convention != .c) continue;
        try renderExportFunctionDecl(allocator, &out, function);
        emitted_any = true;
    }

    if (emitted_any) {
        try out.appendSlice(allocator, "\n");
    }
    const suffix = try std.fmt.allocPrint(allocator, "#endif /* {s} */\n", .{guard});
    defer allocator.free(suffix);
    try out.appendSlice(allocator, suffix);
    return out.toOwnedSlice(allocator);
}

fn isHeaderRootModule(module_name: []const u8, root_module_name: []const u8) bool {
    return std.mem.eql(u8, module_name, root_module_name) or module_name.len == 0;
}

fn collectHeaderTypeDeps(
    diagnostic_context: *diagnostics.Context,
    allocator: std.mem.Allocator,
    path: []const u8,
    program: ast.Program,
    root_module_name: []const u8,
    needed_enums: *std.StringHashMapUnmanaged(void),
    needed_structs: *std.StringHashMapUnmanaged(void),
    needed_aliases: *std.StringHashMapUnmanaged(void),
    collecting_aliases: *std.StringHashMapUnmanaged(void),
    type_name: ast.TypeName,
    through_indirection: bool,
) !void {
    if (std.mem.eql(u8, type_name.name, "c_str")) return;
    if (isBuiltinCTypeName(type_name.name)) return;

    if (type_name.is_raw or type_name.is_optional) {
        const pointee = if (type_name.is_raw) rawPointeeTypeName(type_name) else blk: {
            var payload = type_name;
            payload.is_optional = false;
            break :blk payload;
        };
        try collectHeaderTypeDeps(diagnostic_context, allocator, path, program, root_module_name, needed_enums, needed_structs, needed_aliases, collecting_aliases, pointee, true);
        return;
    }

    if (std.mem.eql(u8, type_name.name, "string")) return;
    if ((std.mem.eql(u8, type_name.name, "[:]") or std.mem.eql(u8, type_name.name, "[;]")) and type_name.args.len == 1) {
        return;
    }
    if (std.mem.eql(u8, type_name.name, "result") and type_name.args.len == 2) {
        try collectHeaderTypeDeps(diagnostic_context, allocator, path, program, root_module_name, needed_enums, needed_structs, needed_aliases, collecting_aliases, type_name.args[0], false);
        try collectHeaderTypeDeps(diagnostic_context, allocator, path, program, root_module_name, needed_enums, needed_structs, needed_aliases, collecting_aliases, type_name.args[1], false);
        return;
    }
    if (type_name.args.len != 0) {
        try diagnostic_context.emitToken(path, type_name.token, "cannot emit C header: generic type `{s}` is not supported in the C header surface", .{type_name.name});
        return error.HeaderGenerationFailed;
    }

    if (findHeaderAlias(program, root_module_name, type_name.name)) |alias| {
        if (collecting_aliases.contains(alias.name)) {
            if (through_indirection) return;
            const message = try std.fmt.allocPrint(allocator, "cannot emit C header: type alias cycle involving `{s}`", .{alias.name});
            defer allocator.free(message);
            try diagnostic_context.emitPath(path, message);
            return error.HeaderGenerationFailed;
        }
        try collecting_aliases.put(allocator, alias.name, {});
        defer _ = collecting_aliases.remove(alias.name);
        try needed_aliases.put(allocator, alias.name, {});
        try collectHeaderTypeDeps(diagnostic_context, allocator, path, program, root_module_name, needed_enums, needed_structs, needed_aliases, collecting_aliases, alias.target, through_indirection);
        return;
    }

    for (program.enums) |decl| {
        if (!isHeaderRootModule(decl.module_name, root_module_name)) continue;
        if (!std.mem.eql(u8, decl.name, type_name.name)) continue;
        if (decl.layout != .c and decl.layout != .flags) {
            try diagnostic_context.emitToken(path, type_name.token, "cannot emit C header: type `{s}` is not a `c enum` or `flags` type", .{type_name.name});
            return error.HeaderGenerationFailed;
        }
        try needed_enums.put(allocator, decl.name, {});
        return;
    }

    for (program.structs) |decl| {
        if (!isHeaderRootModule(decl.module_name, root_module_name)) continue;
        if (!std.mem.eql(u8, decl.name, type_name.name)) continue;
        if (decl.layout != .c) {
            try diagnostic_context.emitToken(path, type_name.token, "cannot emit C header: type `{s}` is not a `c struct` type", .{type_name.name});
            return error.HeaderGenerationFailed;
        }
        const result = try needed_structs.getOrPut(allocator, decl.name);
        if (result.found_existing) return;
        for (decl.fields) |field| {
            try collectHeaderTypeDeps(diagnostic_context, allocator, path, program, root_module_name, needed_enums, needed_structs, needed_aliases, collecting_aliases, field.type_name, through_indirection);
        }
        return;
    }

    try diagnostic_context.emitToken(path, type_name.token, "cannot emit C header: type `{s}` is not supported in the C header surface", .{type_name.name});
    return error.HeaderGenerationFailed;
}

fn renderAliasDeclRecursive(
    diagnostic_context: *diagnostics.Context,
    allocator: std.mem.Allocator,
    path: []const u8,
    program: ast.Program,
    root_module_name: []const u8,
    out: *std.ArrayListUnmanaged(u8),
    rendered_aliases: *std.StringHashMapUnmanaged(void),
    rendering_aliases: *std.StringHashMapUnmanaged(void),
    alias: ast.TypeAlias,
) !void {
    if (rendered_aliases.contains(alias.name)) return;
    if (rendering_aliases.contains(alias.name)) {
        try diagnostic_context.emitToken(path, alias.name_token, "cannot emit C header: type alias cycle involving `{s}`", .{alias.name});
        return error.HeaderGenerationFailed;
    }
    try rendering_aliases.put(allocator, alias.name, {});
    defer _ = rendering_aliases.remove(alias.name);

    if (findHeaderAlias(program, root_module_name, alias.target.name)) |target_alias| {
        try renderAliasDeclRecursive(diagnostic_context, allocator, path, program, root_module_name, out, rendered_aliases, rendering_aliases, target_alias);
    }

    const declarator = try renderCDeclaratorForType(allocator, alias.target, alias.name);
    defer allocator.free(declarator);
    const line = try std.fmt.allocPrint(allocator, "typedef {s};\n", .{declarator});
    defer allocator.free(line);
    try out.appendSlice(allocator, line);
    try rendered_aliases.put(allocator, alias.name, {});
}

fn findHeaderAlias(program: ast.Program, root_module_name: []const u8, name: []const u8) ?ast.TypeAlias {
    for (program.aliases) |alias| {
        if (!isHeaderRootModule(alias.module_name, root_module_name)) continue;
        if (!alias.is_pub) continue;
        if (std.mem.eql(u8, alias.name, name)) return alias;
    }
    return null;
}

fn renderStructDeclRecursive(
    diagnostic_context: *diagnostics.Context,
    allocator: std.mem.Allocator,
    path: []const u8,
    program: ast.Program,
    root_module_name: []const u8,
    out: *std.ArrayListUnmanaged(u8),
    needed_structs: std.StringHashMapUnmanaged(void),
    rendered_structs: *std.StringHashMapUnmanaged(void),
    rendering_structs: *std.StringHashMapUnmanaged(void),
    decl: ast.StructDecl,
) !void {
    if (rendered_structs.contains(decl.name)) return;
    if (rendering_structs.contains(decl.name)) {
        try diagnostic_context.emitToken(path, decl.name_token, "cannot emit C header: by-value `c struct` cycle involving `{s}`", .{decl.name});
        return error.HeaderGenerationFailed;
    }
    try rendering_structs.put(allocator, decl.name, {});
    defer _ = rendering_structs.remove(decl.name);

    for (decl.fields) |field| {
        if (findByValueStructDep(program, root_module_name, needed_structs, field.type_name)) |dep| {
            try renderStructDeclRecursive(diagnostic_context, allocator, path, program, root_module_name, out, needed_structs, rendered_structs, rendering_structs, dep.*);
        }
    }

    try renderStructDecl(allocator, out, decl);
    try rendered_structs.put(allocator, decl.name, {});
}

fn findByValueStructDep(
    program: ast.Program,
    root_module_name: []const u8,
    needed_structs: std.StringHashMapUnmanaged(void),
    type_name: ast.TypeName,
) ?*const ast.StructDecl {
    if (type_name.is_raw) return null;

    if (type_name.array_len != null) {
        var item = type_name;
        item.array_len = null;
        return findByValueStructDep(program, root_module_name, needed_structs, item);
    }

    if (type_name.is_optional) return null;

    for (program.structs) |*decl| {
        if (!isHeaderRootModule(decl.module_name, root_module_name)) continue;
        if (decl.layout != .c) continue;
        if (!needed_structs.contains(decl.name)) continue;
        if (std.mem.eql(u8, decl.name, type_name.name)) return decl;
    }
    return null;
}

fn headerGuard(allocator: std.mem.Allocator, path: []const u8, root_module_name: []const u8) ![]u8 {
    const seed = if (root_module_name.len != 0) root_module_name else std.fs.path.stem(path);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "CYNA_HEADER_");
    for (seed) |c| {
        const upper = std.ascii.toUpper(c);
        if (std.ascii.isAlphanumeric(upper)) {
            try out.append(allocator, upper);
        } else {
            try out.append(allocator, '_');
        }
    }
    try out.append(allocator, '_');
    try out.append(allocator, 'H');
    return out.toOwnedSlice(allocator);
}

fn renderEnumDecl(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), decl: ast.EnumDecl) !void {
    const prefix = try std.fmt.allocPrint(allocator, "typedef enum {s} {{\n", .{decl.name});
    defer allocator.free(prefix);
    try out.appendSlice(allocator, prefix);
    for (decl.cases, 0..) |case_decl, i| {
        const case_prefix = try std.fmt.allocPrint(allocator, "    {s}", .{case_decl.name});
        defer allocator.free(case_prefix);
        try out.appendSlice(allocator, case_prefix);
        if (case_decl.value) |value| {
            const case_value = try std.fmt.allocPrint(allocator, " = {d}", .{value});
            defer allocator.free(case_value);
            try out.appendSlice(allocator, case_value);
        }
        if (i + 1 < decl.cases.len) {
            try out.appendSlice(allocator, ",");
        }
        try out.appendSlice(allocator, "\n");
    }
    const suffix = try std.fmt.allocPrint(allocator, "}} {s};\n\n", .{decl.name});
    defer allocator.free(suffix);
    try out.appendSlice(allocator, suffix);
}

fn renderStructDecl(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), decl: ast.StructDecl) !void {
    const prefix = try std.fmt.allocPrint(allocator, "struct {s} {{\n", .{decl.name});
    defer allocator.free(prefix);
    try out.appendSlice(allocator, prefix);
    for (decl.fields) |field| {
        const declarator = try renderCDeclaratorForType(allocator, field.type_name, field.name);
        defer allocator.free(declarator);
        const line = try std.fmt.allocPrint(allocator, "    {s};\n", .{declarator});
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
    try out.appendSlice(allocator, "};\n\n");
}

fn renderExportFunctionDecl(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), function: ast.Function) !void {
    const return_type = try renderCType(allocator, function.return_type orelse ast.TypeName{
        .is_ref = false,
        .is_owned = false,
        .is_raw = false,
        .is_optional = false,
        .is_slice = false,
        .array_len = null,
        .name = "void",
        .args = &.{},
        .token = .{ .tag = .identifier, .lexeme = "", .line = 0, .column = 0, .end_column = 0 },
    });
    defer allocator.free(return_type);
    const function_decl = try renderCDeclarator(allocator, return_type, function.abi_name orelse function.name);
    defer allocator.free(function_decl);
    const prefix = try std.fmt.allocPrint(allocator, "{s}(", .{function_decl});
    defer allocator.free(prefix);
    try out.appendSlice(allocator, prefix);
    for (function.params, 0..) |param, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        const declarator = try renderCDeclaratorForType(allocator, param.type_name, param.name);
        defer allocator.free(declarator);
        try out.appendSlice(allocator, declarator);
    }
    if (function.params.len == 0) {
        try out.appendSlice(allocator, "void");
    }
    try out.appendSlice(allocator, ");\n\n");
}

fn renderAbiHelperTypes(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    rendered_helpers: *std.StringHashMapUnmanaged(void),
    type_name: ast.TypeName,
) !void {
    if (type_name.is_raw) {
        const pointee = rawPointeeTypeName(type_name);
        try renderAbiHelperTypes(allocator, out, rendered_helpers, pointee);
        return;
    }
    if (type_name.is_optional) {
        var payload = type_name;
        payload.is_optional = false;
        try renderAbiHelperTypes(allocator, out, rendered_helpers, payload);
        const helper_name = try abiHelperName(allocator, type_name);
        defer allocator.free(helper_name);
        const found = try rendered_helpers.getOrPut(allocator, helper_name);
        if (found.found_existing) return;
        const payload_c_type = try renderCType(allocator, payload);
        defer allocator.free(payload_c_type);
        const line = try std.fmt.allocPrint(allocator, "typedef struct {s} {{\n    uint8_t tag;\n    {s} payload;\n}} {s};\n", .{
            helper_name,
            payload_c_type,
            helper_name,
        });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
        return;
    }
    if (std.mem.eql(u8, type_name.name, "string")) return;
    if (std.mem.eql(u8, type_name.name, "[:]") and type_name.args.len == 1) return;
    if (std.mem.eql(u8, type_name.name, "[;]") and type_name.args.len == 1) return;
    if (std.mem.eql(u8, type_name.name, "result") and type_name.args.len == 2) {
        try renderAbiHelperTypes(allocator, out, rendered_helpers, type_name.args[0]);
        try renderAbiHelperTypes(allocator, out, rendered_helpers, type_name.args[1]);
        const helper_name = try abiHelperName(allocator, type_name);
        defer allocator.free(helper_name);
        const found = try rendered_helpers.getOrPut(allocator, helper_name);
        if (found.found_existing) return;
        const ok_c_type = try renderAbiResultOkFieldType(allocator, type_name.args[0]);
        defer allocator.free(ok_c_type);
        const err_c_type = try renderCType(allocator, type_name.args[1]);
        defer allocator.free(err_c_type);
        const line = try std.fmt.allocPrint(allocator, "typedef struct {s} {{\n    uint8_t tag;\n    {s} ok;\n    {s} err;\n}} {s};\n", .{
            helper_name,
            ok_c_type,
            err_c_type,
            helper_name,
        });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
        return;
    }
}

fn abiHelperName(allocator: std.mem.Allocator, type_name: ast.TypeName) ![]u8 {
    if (type_name.is_optional) {
        var payload = type_name;
        payload.is_optional = false;
        const payload_name = try abiNameToken(allocator, payload);
        defer allocator.free(payload_name);
        return std.fmt.allocPrint(allocator, "CynaAbiOptional_{s}", .{payload_name});
    }
    if (std.mem.eql(u8, type_name.name, "result") and type_name.args.len == 2) {
        const ok_name = try abiNameToken(allocator, type_name.args[0]);
        defer allocator.free(ok_name);
        const err_name = try abiNameToken(allocator, type_name.args[1]);
        defer allocator.free(err_name);
        return std.fmt.allocPrint(allocator, "CynaAbiResult_{s}_{s}", .{ ok_name, err_name });
    }
    return abiNameToken(allocator, type_name);
}

fn renderAbiResultOkFieldType(allocator: std.mem.Allocator, type_name: ast.TypeName) ![]u8 {
    if (std.mem.eql(u8, type_name.name, "void") and !type_name.is_raw and !type_name.is_optional and type_name.args.len == 0) {
        return allocator.dupe(u8, "uint8_t");
    }
    return renderCType(allocator, type_name);
}

fn abiNameToken(allocator: std.mem.Allocator, type_name: ast.TypeName) ![]u8 {
    if (type_name.is_raw) {
        const pointee = rawPointeeTypeName(type_name);
        const child = try abiNameToken(allocator, pointee);
        defer allocator.free(child);
        return std.fmt.allocPrint(allocator, "Ptr_{s}", .{child});
    }
    if (type_name.is_optional) {
        var payload = type_name;
        payload.is_optional = false;
        const child = try abiNameToken(allocator, payload);
        defer allocator.free(child);
        return std.fmt.allocPrint(allocator, "Optional_{s}", .{child});
    }
    if (std.mem.eql(u8, type_name.name, "string")) return allocator.dupe(u8, "String");
    if (std.mem.eql(u8, type_name.name, "[:]")) return allocator.dupe(u8, "Dense");
    if (std.mem.eql(u8, type_name.name, "[;]")) return allocator.dupe(u8, "Sparse");
    if (std.mem.eql(u8, type_name.name, "result") and type_name.args.len == 2) {
        const ok_name = try abiNameToken(allocator, type_name.args[0]);
        defer allocator.free(ok_name);
        const err_name = try abiNameToken(allocator, type_name.args[1]);
        defer allocator.free(err_name);
        return std.fmt.allocPrint(allocator, "Result_{s}_{s}", .{ ok_name, err_name });
    }
    return sanitizeAbiName(allocator, type_name.name);
}

fn sanitizeAbiName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '_');
        }
    }
    return out.toOwnedSlice(allocator);
}

fn renderCDeclarator(allocator: std.mem.Allocator, c_type: []const u8, name: []const u8) ![]u8 {
    if (c_type.len > 0 and c_type[c_type.len - 1] == '*') {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ c_type, name });
    }
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ c_type, name });
}

fn renderCDeclaratorForType(allocator: std.mem.Allocator, type_name: ast.TypeName, name: []const u8) ![]u8 {
    const c_type = try renderCType(allocator, type_name);
    defer allocator.free(c_type);
    const declarator = try renderCDeclarator(allocator, c_type, name);
    if (type_name.array_len) |len| {
        defer allocator.free(declarator);
        return std.fmt.allocPrint(allocator, "{s}[{d}]", .{ declarator, len });
    }
    return declarator;
}

fn renderCType(allocator: std.mem.Allocator, type_name: ast.TypeName) std.mem.Allocator.Error![]u8 {
    if (std.mem.eql(u8, type_name.name, "c_str")) {
        return allocator.dupe(u8, "const char *");
    }

    if (type_name.is_raw) {
        return renderRawCType(allocator, type_name);
    }

    if (type_name.is_optional) {
        return abiHelperName(allocator, type_name);
    }
    if (std.mem.eql(u8, type_name.name, "string")) {
        return allocator.dupe(u8, "CynaAbiString");
    }
    if (std.mem.eql(u8, type_name.name, "[:]") and type_name.args.len == 1) {
        return allocator.dupe(u8, "CynaAbiDense *");
    }
    if (std.mem.eql(u8, type_name.name, "[;]") and type_name.args.len == 1) {
        return allocator.dupe(u8, "CynaAbiSparse *");
    }
    if (std.mem.eql(u8, type_name.name, "result") and type_name.args.len == 2) {
        return abiHelperName(allocator, type_name);
    }

    return switch (type_name.name[0]) {
        else => if (std.mem.eql(u8, type_name.name, "c_int"))
            allocator.dupe(u8, "int")
        else if (std.mem.eql(u8, type_name.name, "c_uint"))
            allocator.dupe(u8, "unsigned int")
        else if (std.mem.eql(u8, type_name.name, "c_long"))
            allocator.dupe(u8, "long")
        else if (std.mem.eql(u8, type_name.name, "c_ulong"))
            allocator.dupe(u8, "unsigned long")
        else if (std.mem.eql(u8, type_name.name, "c_llong"))
            allocator.dupe(u8, "long long")
        else if (std.mem.eql(u8, type_name.name, "c_ullong"))
            allocator.dupe(u8, "unsigned long long")
        else if (std.mem.eql(u8, type_name.name, "c_float"))
            allocator.dupe(u8, "float")
        else if (std.mem.eql(u8, type_name.name, "c_double"))
            allocator.dupe(u8, "double")
        else if (std.mem.eql(u8, type_name.name, "c_short"))
            allocator.dupe(u8, "short")
        else if (std.mem.eql(u8, type_name.name, "c_ushort"))
            allocator.dupe(u8, "unsigned short")
        else if (std.mem.eql(u8, type_name.name, "c_char"))
            allocator.dupe(u8, "char")
        else if (std.mem.eql(u8, type_name.name, "c_schar"))
            allocator.dupe(u8, "signed char")
        else if (std.mem.eql(u8, type_name.name, "c_uchar"))
            allocator.dupe(u8, "unsigned char")
        else if (std.mem.eql(u8, type_name.name, "c_ptrdiff_t"))
            allocator.dupe(u8, "ptrdiff_t")
        else if (std.mem.eql(u8, type_name.name, "c_size_t"))
            allocator.dupe(u8, "size_t")
        else if (std.mem.eql(u8, type_name.name, "c_void") or std.mem.eql(u8, type_name.name, "void"))
            allocator.dupe(u8, "void")
        else
            allocator.dupe(u8, type_name.name),
    };
}

fn renderRawCType(allocator: std.mem.Allocator, type_name: ast.TypeName) std.mem.Allocator.Error![]u8 {
    var levels: std.ArrayListUnmanaged(ast.TypeName) = .empty;
    defer levels.deinit(allocator);

    var current = type_name;
    while (current.is_raw) {
        try levels.append(allocator, current);
        current = rawPointeeTypeName(current);
    }

    const base = try renderCType(allocator, current);
    defer allocator.free(base);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const innermost = levels.items[levels.items.len - 1];
    try appendCQualifiers(allocator, &out, innermost);
    try out.appendSlice(allocator, base);

    var index = levels.items.len;
    while (index > 0) {
        index -= 1;
        if (index == levels.items.len - 1 or rawLevelHasQualifier(levels.items[index])) {
            try out.appendSlice(allocator, " *");
        } else {
            try out.append(allocator, '*');
        }
        if (index > 0) try appendCPostfixQualifiers(allocator, &out, levels.items[index - 1]);
    }
    return out.toOwnedSlice(allocator);
}

fn rawLevelHasQualifier(type_name: ast.TypeName) bool {
    return type_name.raw_is_const or type_name.is_volatile_raw;
}

fn appendCQualifiers(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), type_name: ast.TypeName) !void {
    if (type_name.raw_is_const) try out.appendSlice(allocator, "const ");
    if (type_name.is_volatile_raw) try out.appendSlice(allocator, "volatile ");
}

fn appendCPostfixQualifiers(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), type_name: ast.TypeName) !void {
    if (type_name.raw_is_const) try out.appendSlice(allocator, " const");
    if (type_name.is_volatile_raw) try out.appendSlice(allocator, " volatile");
}

fn rawPointeeTypeName(type_name: ast.TypeName) ast.TypeName {
    if (type_name.raw_target) |target| return target.*;
    var pointee = type_name;
    pointee.is_raw = false;
    pointee.raw_is_const = false;
    pointee.is_volatile_raw = false;
    pointee.raw_target = null;
    pointee.is_optional = false;
    return pointee;
}

fn isBuiltinCTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "c_int") or
        std.mem.eql(u8, name, "c_uint") or
        std.mem.eql(u8, name, "c_long") or
        std.mem.eql(u8, name, "c_ulong") or
        std.mem.eql(u8, name, "c_llong") or
        std.mem.eql(u8, name, "c_ullong") or
        std.mem.eql(u8, name, "c_float") or
        std.mem.eql(u8, name, "c_double") or
        std.mem.eql(u8, name, "c_short") or
        std.mem.eql(u8, name, "c_ushort") or
        std.mem.eql(u8, name, "c_char") or
        std.mem.eql(u8, name, "c_schar") or
        std.mem.eql(u8, name, "c_uchar") or
        std.mem.eql(u8, name, "c_ptrdiff_t") or
        std.mem.eql(u8, name, "c_size_t") or
        std.mem.eql(u8, name, "c_void") or
        std.mem.eql(u8, name, "void");
}

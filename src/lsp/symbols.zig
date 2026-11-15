const std = @import("std");
const analysis = @import("analysis.zig");
const compat = @import("../compat.zig");
const compiler_diagnostics = @import("../compiler/diagnostics.zig");
const loader = @import("../compiler/loader.zig");
const lexer = @import("../compiler/lexer/lexer.zig");
const parser = @import("../compiler/parser/parser.zig");
const ast = @import("../compiler/parser/ast.zig");
const sema = @import("../compiler/sema/sema.zig");

const SymbolKind = struct {
    const method = 6;
    const field = 8;
    const enum_kind = 10;
    const interface_kind = 11;
    const function = 12;
    const variable = 13;
    const constant = 14;
    const enum_member = 22;
    const struct_kind = 23;
    const type_parameter = 26;
};

pub fn documentSymbolsJson(allocator: std.mem.Allocator, path: []const u8, text: []const u8) ![]u8 {
    const tokens = lexer.lexAll(allocator, text) catch return try allocator.dupe(u8, "[]");
    defer allocator.free(tokens);

    var diagnostic_context = compiler_diagnostics.Context.discarded();
    var program = parser.parseWithDiagnostics(allocator, path, text, tokens, &diagnostic_context) catch return try allocator.dupe(u8, "[]");
    defer program.deinit(allocator);

    return documentSymbolsFromProgramJson(allocator, program);
}

pub fn documentSymbolsFromProgramJson(allocator: std.mem.Allocator, program: ast.Program) ![]u8 {
    var payload = try std.array_list.Managed(u8).initCapacity(allocator, 512);
    errdefer payload.deinit();

    try payload.append('[');
    var needs_comma = false;

    for (program.aliases) |decl| {
        try appendComma(&payload, &needs_comma);
        try appendSymbol(&payload, decl.name, SymbolKind.type_parameter, decl.name_token);
    }
    for (program.globals) |decl| {
        try appendComma(&payload, &needs_comma);
        try appendSymbol(
            &payload,
            decl.name,
            if (decl.is_mutable) SymbolKind.variable else SymbolKind.constant,
            decl.name_token,
        );
    }
    for (program.enums) |decl| {
        try appendComma(&payload, &needs_comma);
        try appendEnum(&payload, decl);
    }
    for (program.unions) |decl| {
        try appendComma(&payload, &needs_comma);
        try appendUnion(&payload, decl);
    }
    for (program.protocols) |decl| {
        try appendComma(&payload, &needs_comma);
        try appendProtocol(&payload, decl);
    }
    for (program.structs) |decl| {
        try appendComma(&payload, &needs_comma);
        try appendStruct(&payload, decl);
    }
    for (program.functions) |decl| {
        try appendComma(&payload, &needs_comma);
        try appendSymbol(&payload, decl.name, SymbolKind.function, decl.name_token);
    }

    try payload.append(']');
    return try payload.toOwnedSlice();
}

pub fn hoverJson(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    line: usize,
    character: usize,
) ![]u8 {
    const tokens = lexer.lexAll(allocator, text) catch return try allocator.dupe(u8, "null");
    defer allocator.free(tokens);

    var diagnostic_context = compiler_diagnostics.Context.discarded();
    var program = parser.parseWithDiagnostics(allocator, path, text, tokens, &diagnostic_context) catch return try allocator.dupe(u8, "null");
    defer program.deinit(allocator);

    return hoverFromProgramJson(allocator, text, program, line, character);
}

pub fn hoverFromProgramJson(
    allocator: std.mem.Allocator,
    text: []const u8,
    program: ast.Program,
    line: usize,
    character: usize,
) ![]u8 {
    const word = wordAtPosition(text, line, character) orelse return try allocator.dupe(u8, "null");
    const info = findHoverInfo(allocator, program, word.text) orelse return try allocator.dupe(u8, "null");
    defer info.deinit(allocator);
    return try buildHoverResponseJson(allocator, word, info.detail, info.help);
}

pub fn hoverFromSemanticSnapshotJson(
    allocator: std.mem.Allocator,
    text: []const u8,
    snapshot: *const analysis.Snapshot,
    fallback_program: ?ast.Program,
    line: usize,
    character: usize,
) ![]u8 {
    const word = wordAtPosition(text, line, character) orelse return try allocator.dupe(u8, "null");
    if (findSemanticHoverFact(snapshot.hover_facts, word.line, word.start)) |fact| {
        return try buildHoverResponseFromMarkdownJson(allocator, word, fact.markdown);
    }

    const qualifier = qualifierBeforeWord(text, word.line, word.start);
    if (snapshot.loaded) |loaded| {
        const current_module_name = snapshot.current_module_name orelse loaded.root_module_name;
        if (findLoadedHoverInfo(allocator, loaded, current_module_name, qualifier, word.text)) |info| {
            defer info.deinit(allocator);
            return try buildHoverResponseJson(allocator, word, info.detail, info.help);
        }
    }
    if (fallback_program) |program| {
        if (findHoverInfo(allocator, program, word.text)) |info| {
            defer info.deinit(allocator);
            return try buildHoverResponseJson(allocator, word, info.detail, info.help);
        }
    }
    return try allocator.dupe(u8, "null");
}

pub fn hoverJsonLoaded(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    line: usize,
    character: usize,
) ![]u8 {
    const word = wordAtPosition(text, line, character) orelse return try allocator.dupe(u8, "null");
    const qualifier = qualifierBeforeWord(text, word.line, word.start);

    const diagnostic_context = compiler_diagnostics.Context.discarded();
    var loaded = loader.loadProgramWithOptions(allocator, path, .{
        .allow_test_root = std.mem.endsWith(u8, path, ".test.cy"),
        .diagnostic_context = diagnostic_context,
    }) catch return try hoverJson(allocator, path, text, line, character);
    defer loaded.deinit(allocator);

    const current_module_name = moduleNameForPath(loaded, path) orelse loaded.root_module_name;
    const friend_module = try loaded.testFriendModule(allocator, path);
    const semantic_facts = sema.collectSemanticHoverFactsWithOptions(allocator, path, loaded.program, current_module_name, .{
        .diagnostic_context = diagnostic_context,
        .test_friend = if (friend_module) |production_module| .{
            .test_module = loaded.root_module_name,
            .production_module = production_module,
        } else null,
    }) catch null;
    defer if (semantic_facts) |facts| {
        for (facts) |fact| fact.deinit(allocator);
        allocator.free(facts);
    };
    if (semantic_facts) |facts| {
        if (findSemanticHoverFact(facts, word.line, word.start)) |fact| {
            return try buildHoverResponseFromMarkdownJson(allocator, word, fact.markdown);
        }
    }
    const info = findLoadedHoverInfo(allocator, loaded, current_module_name, qualifier, word.text) orelse
        return try hoverJson(allocator, path, text, line, character);
    defer info.deinit(allocator);
    return try buildHoverResponseJson(allocator, word, info.detail, info.help);
}

pub fn definitionJson(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    line: usize,
    character: usize,
) ![]u8 {
    const tokens = lexer.lexAll(allocator, text) catch return try allocator.dupe(u8, "null");
    defer allocator.free(tokens);

    var diagnostic_context = compiler_diagnostics.Context.discarded();
    var program = parser.parseWithDiagnostics(allocator, path, text, tokens, &diagnostic_context) catch return try allocator.dupe(u8, "null");
    defer program.deinit(allocator);

    return definitionFromProgramJson(allocator, path, text, program, line, character);
}

pub fn definitionFromProgramJson(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    program: ast.Program,
    line: usize,
    character: usize,
) ![]u8 {
    const word = wordAtPosition(text, line, character) orelse return try allocator.dupe(u8, "null");
    const qualifier = qualifierBeforeWord(text, word.line, word.start);
    const location = findDefinitionLocation(program, qualifier, word.text) orelse return try allocator.dupe(u8, "null");

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendLocationJson(&out, path, location.line, location.start, location.end, allocator);
    return try out.toOwnedSlice(allocator);
}

pub fn definitionFromSemanticSnapshotJson(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    snapshot: *const analysis.Snapshot,
    fallback_program: ?ast.Program,
    line: usize,
    character: usize,
) ![]u8 {
    const word = wordAtPosition(text, line, character) orelse return try allocator.dupe(u8, "null");
    const qualifier = qualifierBeforeWord(text, word.line, word.start);
    if (snapshot.loaded) |loaded| {
        const current_module_name = snapshot.current_module_name orelse loaded.root_module_name;
        if (findLoadedDefinitionLocation(loaded, current_module_name, qualifier, word.text)) |location| {
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(allocator);
            try appendLocationJson(&out, location.path, location.line, location.start, location.end, allocator);
            return try out.toOwnedSlice(allocator);
        }
    }
    if (fallback_program) |program| {
        if (findDefinitionLocation(program, qualifier, word.text)) |location| {
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(allocator);
            try appendLocationJson(&out, path, location.line, location.start, location.end, allocator);
            return try out.toOwnedSlice(allocator);
        }
    }
    return try allocator.dupe(u8, "null");
}

pub fn definitionJsonLoaded(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    line: usize,
    character: usize,
) ![]u8 {
    const word = wordAtPosition(text, line, character) orelse return try allocator.dupe(u8, "null");
    const qualifier = qualifierBeforeWord(text, word.line, word.start);

    const diagnostic_context = compiler_diagnostics.Context.discarded();
    var loaded = loader.loadProgramWithOptions(allocator, path, .{
        .allow_test_root = std.mem.endsWith(u8, path, ".test.cy"),
        .diagnostic_context = diagnostic_context,
    }) catch return try definitionJson(allocator, path, text, line, character);
    defer loaded.deinit(allocator);

    const current_module_name = moduleNameForPath(loaded, path) orelse loaded.root_module_name;
    const location = findLoadedDefinitionLocation(loaded, current_module_name, qualifier, word.text) orelse
        return try definitionJson(allocator, path, text, line, character);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendLocationJson(&out, location.path, location.line, location.start, location.end, allocator);
    return try out.toOwnedSlice(allocator);
}

fn appendStruct(payload: *std.array_list.Managed(u8), decl: ast.StructDecl) !void {
    try appendSymbolStart(payload, decl.name, SymbolKind.struct_kind, decl.name_token);
    try payload.appendSlice(",\"children\":[");
    var needs_comma = false;
    for (decl.fields) |field| {
        try appendComma(payload, &needs_comma);
        try appendSymbol(payload, field.name, SymbolKind.field, field.name_token);
    }
    for (decl.methods) |method| {
        try appendComma(payload, &needs_comma);
        try appendSymbol(payload, method.name, SymbolKind.method, method.name_token);
    }
    try payload.appendSlice("]}");
}

fn appendUnion(payload: *std.array_list.Managed(u8), decl: ast.UnionDecl) !void {
    try appendSymbolStart(payload, decl.name, SymbolKind.struct_kind, decl.name_token);
    try payload.appendSlice(",\"children\":[");
    var needs_comma = false;
    for (decl.fields) |field| {
        try appendComma(payload, &needs_comma);
        try appendSymbol(payload, field.name, SymbolKind.field, field.name_token);
    }
    try payload.appendSlice("]}");
}

fn appendProtocol(payload: *std.array_list.Managed(u8), decl: ast.ProtocolDecl) !void {
    try appendSymbolStart(payload, decl.name, SymbolKind.interface_kind, decl.name_token);
    try payload.appendSlice(",\"children\":[");
    var needs_comma = false;
    for (decl.associated_types) |associated| {
        try appendComma(payload, &needs_comma);
        try appendSymbol(payload, associated.name, SymbolKind.type_parameter, associated.name_token);
    }
    for (decl.methods) |method| {
        try appendComma(payload, &needs_comma);
        try appendSymbol(payload, method.name, SymbolKind.method, method.name_token);
    }
    try payload.appendSlice("]}");
}

fn appendEnum(payload: *std.array_list.Managed(u8), decl: ast.EnumDecl) !void {
    try appendSymbolStart(payload, decl.name, SymbolKind.enum_kind, decl.name_token);
    try payload.appendSlice(",\"children\":[");
    var needs_comma = false;
    for (decl.cases) |case_decl| {
        try appendComma(payload, &needs_comma);
        try appendSymbol(payload, case_decl.name, SymbolKind.enum_member, case_decl.name_token);
    }
    try payload.appendSlice("]}");
}

fn appendSymbol(
    payload: *std.array_list.Managed(u8),
    name: []const u8,
    kind: u8,
    token: anytype,
) !void {
    try appendSymbolStart(payload, name, kind, token);
    try payload.append('}');
}

fn appendSymbolStart(
    payload: *std.array_list.Managed(u8),
    name: []const u8,
    kind: u8,
    token: anytype,
) !void {
    const line = if (token.line > 0) token.line - 1 else 0;
    const start_char = if (token.column > 0) token.column - 1 else 0;
    const end_char = if (token.end_column > 0) token.end_column - 1 else start_char + 1;
    try payload.print(
        "{{\"name\":{f},\"kind\":{},\"range\":{{\"start\":{{\"line\":{},\"character\":{}}},\"end\":{{\"line\":{},\"character\":{}}}}},\"selectionRange\":{{\"start\":{{\"line\":{},\"character\":{}}},\"end\":{{\"line\":{},\"character\":{}}}}}",
        .{
            std.json.fmt(name, .{}),
            kind,
            line,
            start_char,
            line,
            if (end_char > start_char) end_char else start_char + 1,
            line,
            start_char,
            line,
            if (end_char > start_char) end_char else start_char + 1,
        },
    );
}

fn appendComma(payload: *std.array_list.Managed(u8), needs_comma: *bool) !void {
    if (needs_comma.*) {
        try payload.append(',');
    } else {
        needs_comma.* = true;
    }
}

const HoverWord = struct {
    text: []const u8,
    line: usize,
    start: usize,
    end: usize,
};

const DefinitionLocation = struct {
    line: usize,
    start: usize,
    end: usize,
};

const LoadedDefinitionLocation = struct {
    path: []const u8,
    line: usize,
    start: usize,
    end: usize,
};

const HoverInfo = struct {
    detail: []u8,
    help: ?[]u8 = null,

    fn deinit(self: HoverInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.detail);
        if (self.help) |help| allocator.free(help);
    }
};

fn wordAtPosition(text: []const u8, target_line: usize, target_char: usize) ?HoverWord {
    var line_index: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            if (line_index == target_line) {
                const line_text = text[line_start..i];
                if (target_char > line_text.len) return null;
                var start = @min(target_char, line_text.len);
                while (start > 0 and isWordChar(line_text[start - 1])) start -= 1;
                var end = @min(target_char, line_text.len);
                while (end < line_text.len and isWordChar(line_text[end])) end += 1;
                if (start == end) return null;
                return .{ .text = line_text[start..end], .line = target_line, .start = start, .end = end };
            }
            line_index += 1;
            line_start = i + 1;
        }
    }
    return null;
}

fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn qualifierBeforeWord(text: []const u8, target_line: usize, word_start: usize) ?[]const u8 {
    var line_index: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            if (line_index == target_line) {
                const line_text = text[line_start..i];
                if (word_start == 0 or word_start > line_text.len) return null;
                var cursor = word_start;
                while (cursor > 0 and std.ascii.isWhitespace(line_text[cursor - 1])) cursor -= 1;
                if (cursor == 0 or line_text[cursor - 1] != '.') return null;
                var end = cursor - 1;
                while (end > 0 and std.ascii.isWhitespace(line_text[end - 1])) end -= 1;
                var start = end;
                while (start > 0) {
                    if (isWordChar(line_text[start - 1])) {
                        start -= 1;
                        continue;
                    }
                    if (line_text[start - 1] != '.') break;
                    var dot_cursor = start - 1;
                    while (dot_cursor > 0 and std.ascii.isWhitespace(line_text[dot_cursor - 1])) dot_cursor -= 1;
                    if (dot_cursor == 0 or !isWordChar(line_text[dot_cursor - 1])) break;
                    start = dot_cursor;
                }
                if (start == end) return null;
                return std.mem.trim(u8, line_text[start..end], " \t");
            }
            line_index += 1;
            line_start = i + 1;
        }
    }
    return null;
}

fn findDefinitionLocation(program: ast.Program, qualifier: ?[]const u8, name: []const u8) ?DefinitionLocation {
    if (qualifier) |owner_name| {
        if (findOwnedMember(program, owner_name, name)) |location| return location;
    }

    for (program.aliases) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return tokenLocation(decl.name_token);
    }
    for (program.globals) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return tokenLocation(decl.name_token);
    }
    for (program.enums) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return tokenLocation(decl.name_token);
        for (decl.cases) |case_decl| {
            if (std.mem.eql(u8, case_decl.name, name)) return tokenLocation(case_decl.name_token);
        }
    }
    for (program.unions) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return tokenLocation(decl.name_token);
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return tokenLocation(field.name_token);
        }
    }
    for (program.protocols) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return tokenLocation(decl.name_token);
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return tokenLocation(method.name_token);
        }
    }
    for (program.structs) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return tokenLocation(decl.name_token);
        for (decl.type_params) |param| {
            if (std.mem.eql(u8, param.name, name)) return tokenLocation(param.name_token);
        }
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return tokenLocation(field.name_token);
        }
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return tokenLocation(method.name_token);
        }
    }
    for (program.functions) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return tokenLocation(decl.name_token);
        for (decl.type_params) |param| {
            if (std.mem.eql(u8, param.name, name)) return tokenLocation(param.name_token);
        }
        for (decl.params) |param| {
            if (std.mem.eql(u8, param.name, name)) return tokenLocation(param.name_token);
        }
    }
    return null;
}

fn findOwnedMember(program: ast.Program, owner_name: []const u8, name: []const u8) ?DefinitionLocation {
    for (program.structs) |decl| {
        if (!std.mem.eql(u8, decl.name, owner_name)) continue;
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return tokenLocation(field.name_token);
        }
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return tokenLocation(method.name_token);
        }
    }
    for (program.protocols) |decl| {
        if (!std.mem.eql(u8, decl.name, owner_name)) continue;
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return tokenLocation(method.name_token);
        }
    }
    for (program.unions) |decl| {
        if (!std.mem.eql(u8, decl.name, owner_name)) continue;
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return tokenLocation(field.name_token);
        }
    }
    for (program.enums) |decl| {
        if (!std.mem.eql(u8, decl.name, owner_name)) continue;
        for (decl.cases) |case_decl| {
            if (std.mem.eql(u8, case_decl.name, name)) return tokenLocation(case_decl.name_token);
        }
    }
    return null;
}

fn findLoadedDefinitionLocation(
    loaded: loader.LoadedProgram,
    current_module_name: []const u8,
    qualifier: ?[]const u8,
    name: []const u8,
) ?LoadedDefinitionLocation {
    const current_info = findModuleInfo(loaded.program, current_module_name);

    if (qualifier) |owner_or_module| {
        if (current_info) |info| {
            if (resolveImportedModulePath(info.imports, owner_or_module)) |module_name| {
                if (findModuleTopLevelLocation(loaded, module_name, name)) |location| return location;
            }
        }
        if (findOwnedMemberLoaded(loaded, current_module_name, owner_or_module, name)) |location| return location;
        if (findOwnedMemberAnyModule(loaded, owner_or_module, name)) |location| return location;
        if (findModuleTopLevelLocation(loaded, owner_or_module, name)) |location| return location;
    }

    if (findLoadedModuleLocalLocation(loaded, current_module_name, name)) |location| return location;

    if (current_info) |info| {
        if (resolveImportedItemLocation(loaded, info.imports, name)) |location| return location;
    }

    if (findTopLevelAnyModule(loaded, name)) |location| return location;
    return null;
}

fn findLoadedModuleLocalLocation(
    loaded: loader.LoadedProgram,
    module_name: []const u8,
    name: []const u8,
) ?LoadedDefinitionLocation {
    if (findAliasLocation(loaded, module_name, name)) |location| return location;
    if (findGlobalLocation(loaded, module_name, name)) |location| return location;
    if (findEnumLocation(loaded, module_name, name)) |location| return location;
    if (findUnionLocation(loaded, module_name, name)) |location| return location;
    if (findProtocolLocation(loaded, module_name, name)) |location| return location;
    if (findStructLocation(loaded, module_name, name)) |location| return location;
    if (findFunctionLocation(loaded, module_name, name)) |location| return location;
    return null;
}

fn resolveImportedItemLocation(
    loaded: loader.LoadedProgram,
    imports: []const ast.ImportDecl,
    name: []const u8,
) ?LoadedDefinitionLocation {
    for (imports) |decl| {
        for (decl.items) |item| {
            const local_name = item.local_name orelse item.name;
            if (!std.mem.eql(u8, local_name, name)) continue;
            if (findLoadedModuleLocalLocation(loaded, decl.path, item.name)) |location| return location;
        }
    }
    return null;
}

fn resolveImportedModulePath(imports: []const ast.ImportDecl, qualifier: []const u8) ?[]const u8 {
    for (imports) |decl| {
        if (decl.items.len != 0) continue;
        const local_name = decl.local_name orelse lastPathSegment(decl.path);
        if (std.mem.eql(u8, local_name, qualifier)) return decl.path;
        if (std.mem.eql(u8, decl.path, qualifier)) return decl.path;
    }
    return null;
}

fn lastPathSegment(path: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, path, '.') orelse return path;
    return path[idx + 1 ..];
}

fn findModuleInfo(program: ast.Program, module_name: []const u8) ?ast.ModuleInfo {
    for (program.module_infos) |info| {
        if (std.mem.eql(u8, info.name, module_name)) return info;
    }
    return null;
}

fn moduleNameForPath(loaded: loader.LoadedProgram, path: []const u8) ?[]const u8 {
    const canonical_path = compat.cwdRealpathAlloc(std.heap.page_allocator, path) catch return null;
    defer std.heap.page_allocator.free(canonical_path);
    for (loaded.source_paths, loaded.module_names) |source_path, module_name| {
        if (std.mem.eql(u8, source_path, canonical_path)) return module_name;
    }
    return null;
}

fn findOwnedMemberLoaded(
    loaded: loader.LoadedProgram,
    module_name: []const u8,
    owner_name: []const u8,
    name: []const u8,
) ?LoadedDefinitionLocation {
    for (loaded.program.structs) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name) or !std.mem.eql(u8, decl.name, owner_name)) continue;
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return loadedTokenLocation(loaded, decl.module_name, field.name_token);
        }
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return loadedTokenLocation(loaded, decl.module_name, method.name_token);
        }
    }
    for (loaded.program.protocols) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name) or !std.mem.eql(u8, decl.name, owner_name)) continue;
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return loadedTokenLocation(loaded, decl.module_name, method.name_token);
        }
    }
    for (loaded.program.unions) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name) or !std.mem.eql(u8, decl.name, owner_name)) continue;
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return loadedTokenLocation(loaded, decl.module_name, field.name_token);
        }
    }
    for (loaded.program.enums) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name) or !std.mem.eql(u8, decl.name, owner_name)) continue;
        for (decl.cases) |case_decl| {
            if (std.mem.eql(u8, case_decl.name, name)) return loadedTokenLocation(loaded, decl.module_name, case_decl.name_token);
        }
    }
    return null;
}

fn findOwnedMemberAnyModule(loaded: loader.LoadedProgram, owner_name: []const u8, name: []const u8) ?LoadedDefinitionLocation {
    for (loaded.module_names) |module_name| {
        if (findOwnedMemberLoaded(loaded, module_name, owner_name, name)) |location| return location;
    }
    return null;
}

fn findModuleTopLevelLocation(
    loaded: loader.LoadedProgram,
    module_name: []const u8,
    name: []const u8,
) ?LoadedDefinitionLocation {
    return findLoadedModuleLocalLocation(loaded, module_name, name);
}

fn findTopLevelAnyModule(loaded: loader.LoadedProgram, name: []const u8) ?LoadedDefinitionLocation {
    for (loaded.module_names) |module_name| {
        if (findLoadedModuleLocalLocation(loaded, module_name, name)) |location| return location;
    }
    return null;
}

fn findLoadedHoverInfo(
    allocator: std.mem.Allocator,
    loaded: loader.LoadedProgram,
    current_module_name: []const u8,
    qualifier: ?[]const u8,
    name: []const u8,
) ?HoverInfo {
    const current_info = findModuleInfo(loaded.program, current_module_name);

    if (qualifier) |owner_or_module| {
        if (current_info) |info| {
            if (resolveImportedModulePath(info.imports, owner_or_module)) |module_name| {
                if (findLoadedModuleLocalHoverInfo(allocator, loaded, module_name, name)) |detail| return detail;
            }
        }
        if (findOwnedMemberLoadedHoverInfo(allocator, loaded, current_module_name, owner_or_module, name)) |detail| return detail;
        if (findOwnedMemberLoadedHoverInfoAnyModule(allocator, loaded, owner_or_module, name)) |detail| return detail;
        if (findLoadedModuleLocalHoverInfo(allocator, loaded, owner_or_module, name)) |detail| return detail;
    }

    if (findLoadedModuleLocalHoverInfo(allocator, loaded, current_module_name, name)) |detail| return detail;

    if (current_info) |info| {
        if (resolveImportedItemHoverInfo(allocator, loaded, info.imports, name)) |detail| return detail;
    }

    if (findTopLevelAnyModuleHoverInfo(allocator, loaded, name)) |detail| return detail;
    return null;
}

fn findLoadedModuleLocalHoverInfo(
    allocator: std.mem.Allocator,
    loaded: loader.LoadedProgram,
    module_name: []const u8,
    name: []const u8,
) ?HoverInfo {
    for (loaded.program.aliases) |decl| {
        if (std.mem.eql(u8, decl.module_name, module_name) and std.mem.eql(u8, decl.name, name)) {
            return makeHoverInfo(allocator, formatTypeAlias(allocator, decl) catch return null, hoverHelpForTypeAlias(allocator, decl) catch null);
        }
    }
    for (loaded.program.globals) |decl| {
        if (std.mem.eql(u8, decl.module_name, module_name) and std.mem.eql(u8, decl.name, name)) {
            return makeHoverInfo(allocator, formatGlobal(allocator, decl) catch return null, hoverHelpForGlobal(allocator, decl) catch null);
        }
    }
    for (loaded.program.enums) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name)) continue;
        if (std.mem.eql(u8, decl.name, name)) return makeHoverInfo(allocator, std.fmt.allocPrint(allocator, "enum {s}", .{decl.name}) catch return null, null);
        for (decl.cases) |case_decl| {
            if (std.mem.eql(u8, case_decl.name, name)) return makeHoverInfo(allocator, std.fmt.allocPrint(allocator, "{s}.{s}", .{ decl.name, case_decl.name }) catch return null, null);
        }
    }
    for (loaded.program.unions) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name)) continue;
        if (std.mem.eql(u8, decl.name, name)) return makeHoverInfo(allocator, std.fmt.allocPrint(allocator, "union {s}", .{decl.name}) catch return null, null);
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return makeHoverInfo(allocator, formatUnionField(allocator, decl.name, field) catch return null, hoverHelpForUnionField(allocator, field) catch null);
        }
    }
    for (loaded.program.protocols) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name)) continue;
        if (std.mem.eql(u8, decl.name, name)) return makeHoverInfo(allocator, std.fmt.allocPrint(allocator, "protocol {s}", .{decl.name}) catch return null, null);
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return makeHoverInfo(allocator, formatProtocolMethod(allocator, decl.name, method) catch return null, hoverHelpForProtocolMethod(allocator, method) catch null);
            for (method.params) |param| {
                if (std.mem.eql(u8, param.name, name)) return makeHoverInfo(allocator, formatParam(allocator, param) catch return null, hoverHelpForParam(allocator, param) catch null);
            }
        }
    }
    for (loaded.program.structs) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name)) continue;
        if (std.mem.eql(u8, decl.name, name)) return makeHoverInfo(allocator, std.fmt.allocPrint(allocator, "struct {s}", .{decl.name}) catch return null, null);
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return makeHoverInfo(allocator, formatField(allocator, field) catch return null, hoverHelpForField(allocator, field) catch null);
        }
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return makeHoverInfo(allocator, formatMethod(allocator, decl.name, method) catch return null, hoverHelpForFunction(allocator, method) catch null);
            for (method.params) |param| {
                if (std.mem.eql(u8, param.name, name)) return makeHoverInfo(allocator, formatParam(allocator, param) catch return null, hoverHelpForParam(allocator, param) catch null);
            }
        }
    }
    for (loaded.program.functions) |decl| {
        if (std.mem.eql(u8, decl.module_name, module_name) and std.mem.eql(u8, decl.name, name)) {
            return makeHoverInfo(allocator, formatFunction(allocator, decl) catch return null, hoverHelpForFunction(allocator, decl) catch null);
        }
        if (std.mem.eql(u8, decl.module_name, module_name)) {
            for (decl.params) |param| {
                if (std.mem.eql(u8, param.name, name)) return makeHoverInfo(allocator, formatParam(allocator, param) catch return null, hoverHelpForParam(allocator, param) catch null);
            }
        }
    }
    return null;
}

fn resolveImportedItemHoverInfo(
    allocator: std.mem.Allocator,
    loaded: loader.LoadedProgram,
    imports: []const ast.ImportDecl,
    name: []const u8,
) ?HoverInfo {
    for (imports) |decl| {
        for (decl.items) |item| {
            const local_name = item.local_name orelse item.name;
            if (!std.mem.eql(u8, local_name, name)) continue;
            if (findLoadedModuleLocalHoverInfo(allocator, loaded, decl.path, item.name)) |detail| return detail;
        }
    }
    return null;
}

fn findOwnedMemberLoadedHoverInfo(
    allocator: std.mem.Allocator,
    loaded: loader.LoadedProgram,
    module_name: []const u8,
    owner_name: []const u8,
    name: []const u8,
) ?HoverInfo {
    for (loaded.program.structs) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name) or !std.mem.eql(u8, decl.name, owner_name)) continue;
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return makeHoverInfo(allocator, formatField(allocator, field) catch return null, hoverHelpForField(allocator, field) catch null);
        }
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return makeHoverInfo(allocator, formatMethod(allocator, decl.name, method) catch return null, hoverHelpForFunction(allocator, method) catch null);
        }
    }
    for (loaded.program.protocols) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name) or !std.mem.eql(u8, decl.name, owner_name)) continue;
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return makeHoverInfo(allocator, formatProtocolMethod(allocator, decl.name, method) catch return null, hoverHelpForProtocolMethod(allocator, method) catch null);
        }
    }
    for (loaded.program.unions) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name) or !std.mem.eql(u8, decl.name, owner_name)) continue;
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return makeHoverInfo(allocator, formatUnionField(allocator, decl.name, field) catch return null, hoverHelpForUnionField(allocator, field) catch null);
        }
    }
    for (loaded.program.enums) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name) or !std.mem.eql(u8, decl.name, owner_name)) continue;
        for (decl.cases) |case_decl| {
            if (std.mem.eql(u8, case_decl.name, name)) return makeHoverInfo(allocator, std.fmt.allocPrint(allocator, "{s}.{s}", .{ decl.name, case_decl.name }) catch return null, null);
        }
    }
    return null;
}

fn findOwnedMemberLoadedHoverInfoAnyModule(
    allocator: std.mem.Allocator,
    loaded: loader.LoadedProgram,
    owner_name: []const u8,
    name: []const u8,
) ?HoverInfo {
    for (loaded.module_names) |module_name| {
        if (findOwnedMemberLoadedHoverInfo(allocator, loaded, module_name, owner_name, name)) |detail| return detail;
    }
    return null;
}

fn findTopLevelAnyModuleHoverInfo(
    allocator: std.mem.Allocator,
    loaded: loader.LoadedProgram,
    name: []const u8,
) ?HoverInfo {
    for (loaded.module_names) |module_name| {
        if (findLoadedModuleLocalHoverInfo(allocator, loaded, module_name, name)) |detail| return detail;
    }
    return null;
}

fn findAliasLocation(loaded: loader.LoadedProgram, module_name: []const u8, name: []const u8) ?LoadedDefinitionLocation {
    for (loaded.program.aliases) |decl| {
        if (std.mem.eql(u8, decl.module_name, module_name) and std.mem.eql(u8, decl.name, name)) {
            return loadedTokenLocation(loaded, decl.module_name, decl.name_token);
        }
    }
    return null;
}

fn findGlobalLocation(loaded: loader.LoadedProgram, module_name: []const u8, name: []const u8) ?LoadedDefinitionLocation {
    for (loaded.program.globals) |decl| {
        if (std.mem.eql(u8, decl.module_name, module_name) and std.mem.eql(u8, decl.name, name)) {
            return loadedTokenLocation(loaded, decl.module_name, decl.name_token);
        }
    }
    return null;
}

fn findEnumLocation(loaded: loader.LoadedProgram, module_name: []const u8, name: []const u8) ?LoadedDefinitionLocation {
    for (loaded.program.enums) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name)) continue;
        if (std.mem.eql(u8, decl.name, name)) return loadedTokenLocation(loaded, decl.module_name, decl.name_token);
        for (decl.cases) |case_decl| {
            if (std.mem.eql(u8, case_decl.name, name)) return loadedTokenLocation(loaded, decl.module_name, case_decl.name_token);
        }
    }
    return null;
}

fn findUnionLocation(loaded: loader.LoadedProgram, module_name: []const u8, name: []const u8) ?LoadedDefinitionLocation {
    for (loaded.program.unions) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name)) continue;
        if (std.mem.eql(u8, decl.name, name)) return loadedTokenLocation(loaded, decl.module_name, decl.name_token);
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return loadedTokenLocation(loaded, decl.module_name, field.name_token);
        }
    }
    return null;
}

fn findProtocolLocation(loaded: loader.LoadedProgram, module_name: []const u8, name: []const u8) ?LoadedDefinitionLocation {
    for (loaded.program.protocols) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name)) continue;
        if (std.mem.eql(u8, decl.name, name)) return loadedTokenLocation(loaded, decl.module_name, decl.name_token);
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return loadedTokenLocation(loaded, decl.module_name, method.name_token);
        }
    }
    return null;
}

fn findStructLocation(loaded: loader.LoadedProgram, module_name: []const u8, name: []const u8) ?LoadedDefinitionLocation {
    for (loaded.program.structs) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name)) continue;
        if (std.mem.eql(u8, decl.name, name)) return loadedTokenLocation(loaded, decl.module_name, decl.name_token);
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return loadedTokenLocation(loaded, decl.module_name, field.name_token);
        }
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return loadedTokenLocation(loaded, decl.module_name, method.name_token);
        }
    }
    return null;
}

fn findFunctionLocation(loaded: loader.LoadedProgram, module_name: []const u8, name: []const u8) ?LoadedDefinitionLocation {
    for (loaded.program.functions) |decl| {
        if (std.mem.eql(u8, decl.module_name, module_name) and std.mem.eql(u8, decl.name, name)) {
            return loadedTokenLocation(loaded, decl.module_name, decl.name_token);
        }
    }
    return null;
}

fn loadedTokenLocation(loaded: loader.LoadedProgram, module_name: []const u8, token: anytype) ?LoadedDefinitionLocation {
    const path = pathForModule(loaded, module_name) orelse return null;
    const location = tokenLocation(token);
    return .{
        .path = path,
        .line = location.line,
        .start = location.start,
        .end = location.end,
    };
}

fn pathForModule(loaded: loader.LoadedProgram, module_name: []const u8) ?[]const u8 {
    for (loaded.module_names, loaded.source_paths) |candidate_module_name, source_path| {
        if (std.mem.eql(u8, candidate_module_name, module_name)) return source_path;
    }
    return null;
}

fn tokenLocation(token: anytype) DefinitionLocation {
    const line = if (token.line > 0) token.line - 1 else 0;
    const start_char = if (token.column > 0) token.column - 1 else 0;
    const end_char = if (token.end_column > 0) token.end_column - 1 else start_char + 1;
    return .{
        .line = line,
        .start = start_char,
        .end = if (end_char > start_char) end_char else start_char + 1,
    };
}

fn appendLocationJson(
    out: *std.ArrayList(u8),
    uri_path: []const u8,
    line: usize,
    start: usize,
    end: usize,
    allocator: std.mem.Allocator,
) !void {
    const uri = try std.fmt.allocPrint(allocator, "file://{s}", .{uri_path});
    defer allocator.free(uri);
    try out.appendSlice(allocator, "{\"uri\":");
    try out.print(allocator, "{f}", .{std.json.fmt(uri, .{})});
    try out.appendSlice(allocator, ",\"range\":{\"start\":{\"line\":");
    try out.print(allocator, "{}", .{line});
    try out.appendSlice(allocator, ",\"character\":");
    try out.print(allocator, "{}", .{start});
    try out.appendSlice(allocator, "},\"end\":{\"line\":");
    try out.print(allocator, "{}", .{line});
    try out.appendSlice(allocator, ",\"character\":");
    try out.print(allocator, "{}", .{end});
    try out.appendSlice(allocator, "}}}");
}

fn findHoverInfo(allocator: std.mem.Allocator, program: ast.Program, name: []const u8) ?HoverInfo {
    for (program.aliases) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return makeHoverInfo(allocator, formatTypeAlias(allocator, decl) catch return null, hoverHelpForTypeAlias(allocator, decl) catch null);
    }
    for (program.globals) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return makeHoverInfo(allocator, formatGlobal(allocator, decl) catch return null, hoverHelpForGlobal(allocator, decl) catch null);
    }
    for (program.enums) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return makeHoverInfo(allocator, std.fmt.allocPrint(allocator, "enum {s}", .{decl.name}) catch return null, null);
        for (decl.cases) |case_decl| {
            if (std.mem.eql(u8, case_decl.name, name)) return makeHoverInfo(allocator, std.fmt.allocPrint(allocator, "{s}.{s}", .{ decl.name, case_decl.name }) catch return null, null);
        }
    }
    for (program.unions) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return makeHoverInfo(allocator, std.fmt.allocPrint(allocator, "union {s}", .{decl.name}) catch return null, null);
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return makeHoverInfo(allocator, formatUnionField(allocator, decl.name, field) catch return null, hoverHelpForUnionField(allocator, field) catch null);
        }
    }
    for (program.protocols) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return makeHoverInfo(allocator, std.fmt.allocPrint(allocator, "protocol {s}", .{decl.name}) catch return null, null);
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return makeHoverInfo(allocator, formatProtocolMethod(allocator, decl.name, method) catch return null, hoverHelpForProtocolMethod(allocator, method) catch null);
            for (method.params) |param| {
                if (std.mem.eql(u8, param.name, name)) return makeHoverInfo(allocator, formatParam(allocator, param) catch return null, hoverHelpForParam(allocator, param) catch null);
            }
        }
    }
    for (program.structs) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return makeHoverInfo(allocator, std.fmt.allocPrint(allocator, "struct {s}", .{decl.name}) catch return null, null);
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return makeHoverInfo(allocator, formatField(allocator, field) catch return null, hoverHelpForField(allocator, field) catch null);
        }
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return makeHoverInfo(allocator, formatMethod(allocator, decl.name, method) catch return null, hoverHelpForFunction(allocator, method) catch null);
            for (method.params) |param| {
                if (std.mem.eql(u8, param.name, name)) return makeHoverInfo(allocator, formatParam(allocator, param) catch return null, hoverHelpForParam(allocator, param) catch null);
            }
        }
    }
    for (program.functions) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return makeHoverInfo(allocator, formatFunction(allocator, decl) catch return null, hoverHelpForFunction(allocator, decl) catch null);
        for (decl.params) |param| {
            if (std.mem.eql(u8, param.name, name)) return makeHoverInfo(allocator, formatParam(allocator, param) catch return null, hoverHelpForParam(allocator, param) catch null);
        }
    }
    return null;
}

fn makeHoverInfo(_: std.mem.Allocator, detail: []u8, help: ?[]u8) HoverInfo {
    return .{ .detail = detail, .help = help };
}

fn buildHoverResponseJson(
    allocator: std.mem.Allocator,
    word: HoverWord,
    detail: []const u8,
    help: ?[]const u8,
) ![]u8 {
    const markdown = if (help) |note|
        try std.fmt.allocPrint(allocator, "```cyna\n{s}\n```\n\n{s}", .{ detail, note })
    else
        try std.fmt.allocPrint(allocator, "```cyna\n{s}\n```", .{detail});
    defer allocator.free(markdown);
    return try buildHoverResponseFromMarkdownJson(allocator, word, markdown);
}

fn buildHoverResponseFromMarkdownJson(
    allocator: std.mem.Allocator,
    word: HoverWord,
    markdown: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"contents\":{\"kind\":\"markdown\",\"value\":");
    try out.print(allocator, "{f}", .{std.json.fmt(markdown, .{})});
    try out.appendSlice(allocator, "},\"range\":{\"start\":{\"line\":");
    try out.print(allocator, "{}", .{word.line});
    try out.appendSlice(allocator, ",\"character\":");
    try out.print(allocator, "{}", .{word.start});
    try out.appendSlice(allocator, "},\"end\":{\"line\":");
    try out.print(allocator, "{}", .{word.line});
    try out.appendSlice(allocator, ",\"character\":");
    try out.print(allocator, "{}", .{word.end});
    try out.appendSlice(allocator, "}}}");
    return try out.toOwnedSlice(allocator);
}

fn findSemanticHoverFact(
    facts: []const sema.SemanticHoverFact,
    line: usize,
    character: usize,
) ?sema.SemanticHoverFact {
    for (facts) |fact| {
        if (fact.line != line) continue;
        if (character < fact.start or character > fact.end) continue;
        return fact;
    }
    return null;
}

fn hoverHelpForTypeAlias(allocator: std.mem.Allocator, decl: ast.TypeAlias) !?[]u8 {
    return try hoverHelpForStandaloneType(allocator, decl.target);
}

fn hoverHelpForGlobal(allocator: std.mem.Allocator, decl: ast.Global) !?[]u8 {
    if (decl.type_name) |ty| return try hoverHelpForStandaloneType(allocator, ty);
    return null;
}

fn hoverHelpForField(allocator: std.mem.Allocator, field: ast.FieldDecl) !?[]u8 {
    return try hoverHelpForStandaloneType(allocator, field.type_name);
}

fn hoverHelpForParam(allocator: std.mem.Allocator, param: ast.Param) !?[]u8 {
    return try hoverHelpForStandaloneType(allocator, param.type_name);
}

fn hoverHelpForUnionField(allocator: std.mem.Allocator, field: ast.UnionField) !?[]u8 {
    if (field.type_name) |ty| return try hoverHelpForStandaloneType(allocator, ty);
    return null;
}

fn hoverHelpForFunction(allocator: std.mem.Allocator, decl: ast.Function) !?[]u8 {
    return try hoverHelpForSignature(allocator, decl.params, decl.return_type);
}

fn hoverHelpForProtocolMethod(allocator: std.mem.Allocator, decl: ast.ProtocolMethod) !?[]u8 {
    return try hoverHelpForSignature(allocator, decl.params, decl.return_type);
}

fn hoverHelpForStandaloneType(allocator: std.mem.Allocator, ty: ast.TypeName) !?[]u8 {
    const role = ownershipRoleForType(ty) orelse return null;
    return try std.fmt.allocPrint(allocator, "**Ownership:** {s}.", .{role});
}

fn hoverHelpForSignature(
    allocator: std.mem.Allocator,
    params: anytype,
    return_type: ?ast.TypeName,
) !?[]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var has_lines = false;

    for (params) |param| {
        if (ownershipRoleForType(param.type_name)) |role| {
            if (!has_lines) {
                try out.appendSlice(allocator, "**Ownership:**\n");
                has_lines = true;
            }
            try out.print(allocator, "- `{s}` is {s}.\n", .{ param.name, role });
        }
    }
    if (return_type) |ty| {
        if (ownershipRoleForType(ty)) |role| {
            if (!has_lines) {
                try out.appendSlice(allocator, "**Ownership:**\n");
                has_lines = true;
            }
            try out.print(allocator, "- returns {s}.\n", .{role});
        }
    }

    if (!has_lines) return null;
    return try out.toOwnedSlice(allocator);
}

fn ownershipRoleForType(ty: ast.TypeName) ?[]const u8 {
    if (ty.is_ref) return "a borrowed reference";
    if (ty.is_owned) return "an owned pointer";
    if (ty.is_volatile_raw) return "a volatile raw pointer";
    if (ty.is_raw) return "a raw pointer";
    if (ty.is_slice) {
        return if (ty.slice_flags.is_const) "a read-only view" else "a borrowed view";
    }
    if (std.mem.eql(u8, ty.name, "[:]")) return "a dense array";
    if (std.mem.eql(u8, ty.name, "[;]")) return "a sparse array";
    return null;
}

fn formatTypeAlias(allocator: std.mem.Allocator, decl: ast.TypeAlias) ![]u8 {
    const target = try renderTypeName(allocator, decl.target);
    defer allocator.free(target);
    return std.fmt.allocPrint(allocator, "type {s} = {s}", .{ decl.name, target });
}

fn formatGlobal(allocator: std.mem.Allocator, decl: ast.Global) ![]u8 {
    if (decl.type_name) |ty| {
        const rendered = try renderTypeName(allocator, ty);
        defer allocator.free(rendered);
        return std.fmt.allocPrint(allocator, "{s} {s}: {s}", .{ if (decl.is_mutable) "var" else "const", decl.name, rendered });
    }
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ if (decl.is_mutable) "var" else "const", decl.name });
}

fn formatField(allocator: std.mem.Allocator, field: ast.FieldDecl) ![]u8 {
    const rendered = try renderTypeName(allocator, field.type_name);
    defer allocator.free(rendered);
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ field.name, rendered });
}

fn formatParam(allocator: std.mem.Allocator, param: ast.Param) ![]u8 {
    const rendered = try renderTypeName(allocator, param.type_name);
    defer allocator.free(rendered);
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ param.name, rendered });
}

fn formatUnionField(allocator: std.mem.Allocator, owner: []const u8, field: ast.UnionField) ![]u8 {
    if (field.type_name) |ty| {
        const rendered = try renderTypeName(allocator, ty);
        defer allocator.free(rendered);
        return std.fmt.allocPrint(allocator, "{s}.{s}: {s}", .{ owner, field.name, rendered });
    }
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ owner, field.name });
}

fn formatMethod(allocator: std.mem.Allocator, owner: []const u8, decl: ast.Function) ![]u8 {
    const sig = try formatParamsAndReturn(allocator, decl.params, decl.return_type);
    defer allocator.free(sig);
    return std.fmt.allocPrint(allocator, "fn {s}.{s}{s}", .{ owner, decl.name, sig });
}

fn formatProtocolMethod(allocator: std.mem.Allocator, owner: []const u8, decl: ast.ProtocolMethod) ![]u8 {
    const sig = try formatParamsAndReturn(allocator, decl.params, decl.return_type);
    defer allocator.free(sig);
    return std.fmt.allocPrint(allocator, "fn {s}.{s}{s}", .{ owner, decl.name, sig });
}

fn formatFunction(allocator: std.mem.Allocator, decl: ast.Function) ![]u8 {
    const sig = try formatParamsAndReturn(allocator, decl.params, decl.return_type);
    defer allocator.free(sig);
    return std.fmt.allocPrint(allocator, "fn {s}{s}", .{ decl.name, sig });
}

fn formatParamsAndReturn(allocator: std.mem.Allocator, params: anytype, return_type: ?ast.TypeName) ![]u8 {
    var out = try std.array_list.Managed(u8).initCapacity(allocator, 64);
    errdefer out.deinit();
    try out.append('(');
    for (params, 0..) |param, idx| {
        if (idx != 0) try out.appendSlice(", ");
        const rendered = try renderTypeName(allocator, param.type_name);
        defer allocator.free(rendered);
        try out.print("{s}: {s}", .{ param.name, rendered });
    }
    try out.append(')');
    if (return_type) |ty| {
        const rendered = try renderTypeName(allocator, ty);
        defer allocator.free(rendered);
        try out.print(": {s}", .{rendered});
    }
    return try out.toOwnedSlice();
}

fn renderTypeName(allocator: std.mem.Allocator, ty: ast.TypeName) ![]u8 {
    var out = try std.array_list.Managed(u8).initCapacity(allocator, 32);
    errdefer out.deinit();
    if (ty.is_optional) try out.append('?');
    if (ty.is_ref) try out.append('&');
    if (ty.is_owned) try out.append('^');
    if (ty.is_volatile_raw) {
        try out.appendSlice("*volatile ");
    } else if (ty.is_raw) {
        try out.append('*');
    }
    if (ty.is_slice) {
        if (ty.slice_flags.is_const) {
            try out.appendSlice("[:const]");
        } else {
            try out.appendSlice("[:]");
        }
    } else if (ty.array_len) |len| {
        try out.print("[{}]", .{len});
    }
    if (ty.slice_flags.item_is_optional) try out.append('?');
    try out.appendSlice(ty.name);
    if (ty.args.len != 0) {
        try out.append('<');
        for (ty.args, 0..) |arg, idx| {
            if (idx != 0) try out.appendSlice(", ");
            const rendered = try renderTypeName(allocator, arg);
            defer allocator.free(rendered);
            try out.appendSlice(rendered);
        }
        try out.append('>');
    }
    return try out.toOwnedSlice();
}

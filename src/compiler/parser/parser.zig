const std = @import("std");
const language_contracts = @import("../language_contracts.zig");
const ast = @import("ast.zig");
const diagnostics = @import("../diagnostics.zig");
const lexer = @import("../lexer/token.zig");

pub const ParseError = error{ ParseFailed, OutOfMemory };
const NumericLiteralError = error{Invalid};

pub fn parse(allocator: std.mem.Allocator, path: []const u8, source: []const u8, tokens: []const lexer.Token) ParseError!ast.Program {
    var diagnostic_context = diagnostics.Context.discarded();
    return parseWithDiagnostics(allocator, path, source, tokens, &diagnostic_context);
}

pub fn parseWithDiagnostics(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    tokens: []const lexer.Token,
    diagnostic_context: *diagnostics.Context,
) ParseError!ast.Program {
    var parser_diagnostic_context = diagnostic_context.*;
    parser_diagnostic_context.default_code = .parse_syntax;
    var p = Parser{
        .allocator = allocator,
        .diagnostic_context = &parser_diagnostic_context,
        .path = path,
        .source = source,
        .tokens = tokens,
        .index = 0,
        .unchecked_depth = 0,
        .imports = .empty,
        .globals = .empty,
        .asm_consts = .empty,
        .aliases = .empty,
        .enums = .empty,
        .unions = .empty,
        .protocols = .empty,
        .impls = .empty,
        .structs = .empty,
        .functions = .empty,
        .tests = .empty,
    };
    return p.parseProgram();
}

const Parser = struct {
    allocator: std.mem.Allocator,
    diagnostic_context: *diagnostics.Context,
    path: []const u8,
    source: []const u8,
    tokens: []const lexer.Token,
    index: usize,
    unchecked_depth: usize,
    imports: std.ArrayListUnmanaged(ast.ImportDecl),
    globals: std.ArrayListUnmanaged(ast.Global),
    asm_consts: std.ArrayListUnmanaged(ast.AsmConst),
    aliases: std.ArrayListUnmanaged(ast.TypeAlias),
    enums: std.ArrayListUnmanaged(ast.EnumDecl),
    unions: std.ArrayListUnmanaged(ast.UnionDecl),
    protocols: std.ArrayListUnmanaged(ast.ProtocolDecl),
    impls: std.ArrayListUnmanaged(ast.ImplDecl),
    structs: std.ArrayListUnmanaged(ast.StructDecl),
    functions: std.ArrayListUnmanaged(ast.Function),
    tests: std.ArrayListUnmanaged(ast.InlineTest),

    const DeclAttrs = struct {
        abi_c: bool = false,
        link_import: bool = false,
        link_export: bool = false,
        asm_export: bool = false,
        isolated: bool = false,
        concurrency_shareable: bool = false,
        shared_value: bool = false,
        owned_value: bool = false,
        concurrency_trusted_extern: bool = false,
        intrinsic_name: ?[]const u8 = null,
        intrinsic_token: ?lexer.Token = null,
        sequence_literal: bool = false,
        slice_view: bool = false,
        syntax_role: ?ast.SyntaxRole = null,
        abi_name: ?[]const u8 = null,
        first_token: ?lexer.Token = null,

        fn hasAny(self: DeclAttrs) bool {
            return self.abi_c or self.link_import or self.link_export or self.asm_export or self.isolated or self.concurrency_shareable or self.shared_value or self.owned_value or self.concurrency_trusted_extern or self.intrinsic_name != null or self.sequence_literal or self.slice_view or self.syntax_role != null;
        }
    };

    fn parseProgram(self: *Parser) ParseError!ast.Program {
        errdefer {
            for (self.imports.items) |decl| decl.deinit(self.allocator);
            self.imports.deinit(self.allocator);
            for (self.globals.items) |global| global.deinit(self.allocator);
            self.globals.deinit(self.allocator);
            for (self.asm_consts.items) |asm_consts| asm_consts.deinit(self.allocator);
            self.asm_consts.deinit(self.allocator);
            for (self.aliases.items) |alias| alias.deinit(self.allocator);
            self.aliases.deinit(self.allocator);
            for (self.enums.items) |decl| decl.deinit(self.allocator);
            self.enums.deinit(self.allocator);
            for (self.unions.items) |decl| decl.deinit(self.allocator);
            self.unions.deinit(self.allocator);
            for (self.protocols.items) |decl| decl.deinit(self.allocator);
            self.protocols.deinit(self.allocator);
            for (self.impls.items) |decl| decl.deinit(self.allocator);
            self.impls.deinit(self.allocator);
            for (self.structs.items) |decl| decl.deinit(self.allocator);
            self.structs.deinit(self.allocator);
            for (self.functions.items) |function| function.deinit(self.allocator);
            self.functions.deinit(self.allocator);
            for (self.tests.items) |inline_test| inline_test.deinit(self.allocator);
            self.tests.deinit(self.allocator);
        }

        while (self.match(.keyword_import)) {
            try self.parseImport();
        }

        var recovered_errors: usize = 0;
        while (!self.check(.eof)) {
            const declaration_start = self.index;
            self.parseTopLevelDeclaration() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ParseFailed => {
                    recovered_errors += 1;
                    if (recovered_errors >= max_recovered_errors) break;
                    self.synchronizeTopLevel(declaration_start);
                },
            };
        }
        if (recovered_errors != 0) return ParseError.ParseFailed;

        const imports = try self.imports.toOwnedSlice(self.allocator);
        errdefer {
            for (imports) |decl| decl.deinit(self.allocator);
            self.allocator.free(imports);
        }

        var module_infos = try self.allocator.alloc(ast.ModuleInfo, 1);
        var initialized_infos: usize = 0;
        errdefer {
            for (module_infos[0..initialized_infos]) |info| info.deinit(self.allocator);
            self.allocator.free(module_infos);
        }

        var module_imports = try self.allocator.alloc(ast.ImportDecl, imports.len);
        var initialized_imports: usize = 0;
        var module_imports_attached = false;
        errdefer if (!module_imports_attached) {
            for (module_imports[0..initialized_imports]) |decl| decl.deinit(self.allocator);
            self.allocator.free(module_imports);
        };
        for (imports, 0..) |decl, i| {
            module_imports[i] = try self.dupImportDecl(decl);
            initialized_imports = i + 1;
        }
        module_infos[0] = .{
            .name = self.path,
            .source_path = self.path,
            .imports = module_imports,
        };
        initialized_infos = 1;
        module_imports_attached = true;

        const globals = try self.globals.toOwnedSlice(self.allocator);
        errdefer {
            for (globals) |global| global.deinit(self.allocator);
            self.allocator.free(globals);
        }
        const asm_consts = try self.asm_consts.toOwnedSlice(self.allocator);
        errdefer {
            for (asm_consts) |value| value.deinit(self.allocator);
            self.allocator.free(asm_consts);
        }
        const aliases = try self.aliases.toOwnedSlice(self.allocator);
        errdefer {
            for (aliases) |alias| alias.deinit(self.allocator);
            self.allocator.free(aliases);
        }
        const enums = try self.enums.toOwnedSlice(self.allocator);
        errdefer {
            for (enums) |decl| decl.deinit(self.allocator);
            self.allocator.free(enums);
        }
        const unions = try self.unions.toOwnedSlice(self.allocator);
        errdefer {
            for (unions) |decl| decl.deinit(self.allocator);
            self.allocator.free(unions);
        }
        const protocols = try self.protocols.toOwnedSlice(self.allocator);
        errdefer {
            for (protocols) |decl| decl.deinit(self.allocator);
            self.allocator.free(protocols);
        }
        const impls = try self.impls.toOwnedSlice(self.allocator);
        errdefer {
            for (impls) |decl| decl.deinit(self.allocator);
            self.allocator.free(impls);
        }
        const structs = try self.structs.toOwnedSlice(self.allocator);
        errdefer {
            for (structs) |decl| decl.deinit(self.allocator);
            self.allocator.free(structs);
        }
        const functions = try self.functions.toOwnedSlice(self.allocator);
        errdefer {
            for (functions) |function| function.deinit(self.allocator);
            self.allocator.free(functions);
        }
        const tests = try self.tests.toOwnedSlice(self.allocator);
        errdefer {
            for (tests) |inline_test| inline_test.deinit(self.allocator);
            self.allocator.free(tests);
        }

        return .{
            .source = self.source,
            .tokens = self.tokens,
            .imports = imports,
            .module_infos = module_infos,
            .globals = globals,
            .asm_consts = asm_consts,
            .aliases = aliases,
            .enums = enums,
            .unions = unions,
            .protocols = protocols,
            .impls = impls,
            .structs = structs,
            .functions = functions,
            .tests = tests,
        };
    }

    const max_recovered_errors: usize = 8;

    fn parseTopLevelDeclaration(self: *Parser) ParseError!void {
        var attrs = try self.parseDeclAttrs();
        const is_pub = self.match(.keyword_pub);
        if (is_pub) attrs = try self.parseDeclAttrsInto(attrs);
        if (attrs.slice_view or attrs.syntax_role != null) return self.rejectAttrs(attrs, "top-level declarations");
        if (attrs.sequence_literal and !self.check(.keyword_fn)) return self.rejectAttrs(attrs, "non-function declarations");

        if (self.match(.keyword_type)) {
            try self.rejectAttrs(attrs, "type aliases");
            return self.parseTypeAlias(is_pub);
        }
        if (self.match(.keyword_const)) return self.parseGlobalWithAttrs(false, is_pub, attrs);
        if (self.match(.keyword_var)) return self.parseGlobalWithAttrs(true, is_pub, attrs);
        if (self.check(.identifier) and std.mem.eql(u8, self.peek().lexeme, "c")) {
            switch (self.peekAhead(1).tag) {
                .keyword_enum => {
                    _ = self.advance();
                    _ = self.advance();
                    try self.rejectAttrs(attrs, "enums");
                    return self.parseEnum(.c, is_pub);
                },
                .keyword_union => {
                    _ = self.advance();
                    _ = self.advance();
                    try self.rejectAttrs(attrs, "unions");
                    return self.parseUnion(.c, is_pub);
                },
                .keyword_struct => {
                    _ = self.advance();
                    _ = self.advance();
                    return self.parseStructWithAttrs(.c, is_pub, attrs);
                },
                else => {},
            }
        }
        if (self.match(.keyword_enum)) {
            try self.rejectAttrs(attrs, "enums");
            return self.parseEnum(.normal, is_pub);
        }
        if (self.match(.keyword_flags)) {
            try self.rejectAttrs(attrs, "flags");
            return self.parseEnum(.flags, is_pub);
        }
        if (self.match(.keyword_union)) {
            try self.rejectAttrs(attrs, "unions");
            return self.parseUnion(.normal, is_pub);
        }
        if (self.match(.keyword_protocol)) {
            try self.rejectAttrs(attrs, "protocols");
            return self.parseProtocol(is_pub);
        }
        if (self.match(.keyword_impl)) {
            try self.rejectAttrs(attrs, "impl declarations");
            if (is_pub) {
                try self.diagnostic_context.emitToken(self.path, self.previous(), "`pub impl` is not supported", .{});
                return ParseError.ParseFailed;
            }
            return self.parseImpl();
        }
        if (self.match(.keyword_struct)) return self.parseStructWithAttrs(.normal, is_pub, attrs);
        if (self.match(.keyword_packed)) {
            if (attrs.concurrency_shareable and !(attrs.abi_c or attrs.link_import or attrs.link_export or attrs.asm_export or attrs.isolated or attrs.concurrency_trusted_extern)) {
                try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `concurrency.shareable` is not supported on packed structs", .{});
                return ParseError.ParseFailed;
            }
            try self.rejectAttrs(attrs, "structs");
            _ = try self.expect(.keyword_struct, "expected `struct` after `packed`");
            return self.parseStruct(.@"packed", is_pub, .{});
        }
        if (self.match(.keyword_extern)) return self.parseExternDecl(is_pub, attrs);
        if (self.match(.keyword_export)) {
            try self.rejectAttrs(attrs, "`export` declarations");
            return self.parseExportDecl(is_pub);
        }
        if (self.match(.keyword_fn)) return self.parseFunctionWithAttrs(null, is_pub, attrs);
        if (self.match(.keyword_test)) {
            try self.rejectAttrs(attrs, "tests");
            if (is_pub) {
                try self.diagnostic_context.emitToken(self.path, self.previous(), "`pub test` is not supported", .{});
                return ParseError.ParseFailed;
            }
            return self.parseInlineTest();
        }
        if (attrs.hasAny()) {
            try self.diagnostic_context.emitToken(self.path, self.peek(), "attribute list must be followed by a declaration", .{});
            return ParseError.ParseFailed;
        }
        if (self.check(.identifier) and std.mem.eql(u8, self.peek().lexeme, "interface")) {
            try self.diagnostic_context.emitToken(self.path, self.peek(), "`interface` has been removed; use `protocol`", .{});
            return ParseError.ParseFailed;
        }
        if (is_pub) {
            try self.diagnostic_context.emitToken(self.path, self.peek(), "`pub` must be followed by `const`, `var`, `type`, `fn`, `struct`, `c struct`, `packed struct`, `enum`, `c enum`, `flags`, `union`, `c union`, or `protocol`", .{});
            return ParseError.ParseFailed;
        }
        try self.diagnostic_context.emitToken(self.path, self.peek(), "expected top-level declaration", .{});
        return ParseError.ParseFailed;
    }

    fn synchronizeTopLevel(self: *Parser, declaration_start: usize) void {
        if (self.check(.eof)) return;
        if (self.index <= declaration_start) _ = self.advance();
        while (!self.check(.eof)) {
            const token = self.peek();
            if (token.column == 1 and (isTopLevelDeclarationStart(token.tag) or
                (self.check(.identifier) and std.mem.eql(u8, self.peek().lexeme, "c") and switch (self.peekAhead(1).tag) {
                    .keyword_struct, .keyword_enum, .keyword_union => true,
                    else => false,
                }))) return;
            _ = self.advance();
        }
    }

    fn isTopLevelDeclarationStart(tag: lexer.TokenTag) bool {
        return switch (tag) {
            .at,
            .keyword_pub,
            .keyword_type,
            .keyword_const,
            .keyword_var,
            .keyword_enum,
            .keyword_flags,
            .keyword_union,
            .keyword_protocol,
            .keyword_impl,
            .keyword_struct,
            .keyword_packed,
            .keyword_extern,
            .keyword_export,
            .keyword_fn,
            .keyword_test,
            => true,
            else => false,
        };
    }

    fn dupImportDecl(self: *Parser, decl: ast.ImportDecl) !ast.ImportDecl {
        var items = try self.allocator.alloc(ast.ImportItem, decl.items.len);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| item.deinit(self.allocator);
            self.allocator.free(items);
        }
        for (decl.items, 0..) |item, i| {
            items[i] = .{
                .name = item.name,
                .local_name = if (item.local_name) |local_name| try self.allocator.dupe(u8, local_name) else null,
                .name_token = item.name_token,
            };
            initialized = i + 1;
        }
        return .{
            .path = try self.allocator.dupe(u8, decl.path),
            .is_root_package = decl.is_root_package,
            .local_name = if (decl.local_name) |local_name| try self.allocator.dupe(u8, local_name) else null,
            .items = items,
            .path_token = decl.path_token,
        };
    }

    fn parseDeclAttrs(self: *Parser) ParseError!DeclAttrs {
        return self.parseDeclAttrsInto(.{});
    }

    fn parseDeclAttrsInto(self: *Parser, initial: DeclAttrs) ParseError!DeclAttrs {
        var attrs = initial;
        while (self.match(.at)) {
            const at_token = self.previous();
            if (attrs.first_token == null) attrs.first_token = at_token;
            const name = try self.parseAttributeName();
            defer self.allocator.free(name);

            var arg: ?lexer.Token = null;
            var arg_count: usize = 0;
            if (self.match(.l_paren)) {
                if (!self.check(.r_paren)) {
                    while (true) {
                        const value = self.peek();
                        switch (value.tag) {
                            .string_lit, .int_lit, .keyword_true, .keyword_false, .identifier => _ = self.advance(),
                            else => {
                                try self.diagnostic_context.emitToken(self.path, value, "attribute arguments must be literals or identifiers", .{});
                                return ParseError.ParseFailed;
                            },
                        }
                        if (arg_count == 0) arg = value;
                        arg_count += 1;
                        if (!self.match(.comma)) break;
                    }
                }
                _ = try self.expect(.r_paren, "expected `)` after attribute arguments");
            }

            if (std.mem.eql(u8, name, "abi")) {
                if (attrs.abi_c) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "duplicate attribute `abi`", .{});
                    return ParseError.ParseFailed;
                }
                if (arg_count != 1 or arg == null or arg.?.tag != .string_lit) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "attribute `abi` expects one string literal argument", .{});
                    return ParseError.ParseFailed;
                }
                const abi_name = arg.?.lexeme[1 .. arg.?.lexeme.len - 1];
                if (!std.mem.eql(u8, abi_name, "c")) {
                    try self.diagnostic_context.emitToken(self.path, arg.?, "unsupported ABI `{s}`", .{abi_name});
                    return ParseError.ParseFailed;
                }
                attrs.abi_c = true;
                continue;
            }

            if (std.mem.eql(u8, name, "link.import")) {
                if (attrs.link_import) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "duplicate attribute `link.import`", .{});
                    return ParseError.ParseFailed;
                }
                if (attrs.link_export) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "attribute `link.import` conflicts with `link.export`", .{});
                    return ParseError.ParseFailed;
                }
                attrs.link_import = true;
                attrs.abi_name = try self.parseOptionalStringAttributeArg("link.import", at_token, arg, arg_count);
                continue;
            }

            if (std.mem.eql(u8, name, "link.export")) {
                if (attrs.link_export) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "duplicate attribute `link.export`", .{});
                    return ParseError.ParseFailed;
                }
                if (attrs.link_import) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "attribute `link.export` conflicts with `link.import`", .{});
                    return ParseError.ParseFailed;
                }
                attrs.link_export = true;
                attrs.abi_name = try self.parseOptionalStringAttributeArg("link.export", at_token, arg, arg_count);
                continue;
            }

            if (std.mem.eql(u8, name, "asm.export")) {
                if (attrs.asm_export) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "duplicate attribute `asm.export`", .{});
                    return ParseError.ParseFailed;
                }
                attrs.asm_export = true;
                attrs.abi_name = try self.parseOptionalStringAttributeArg("asm.export", at_token, arg, arg_count);
                continue;
            }

            if (std.mem.eql(u8, name, "concurrency.isolated")) {
                if (attrs.isolated) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "duplicate attribute `concurrency.isolated`", .{});
                    return ParseError.ParseFailed;
                }
                if (arg_count != 0) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "attribute `concurrency.isolated` expects no arguments", .{});
                    return ParseError.ParseFailed;
                }
                attrs.isolated = true;
                continue;
            }

            if (std.mem.eql(u8, name, "concurrency.shareable")) {
                if (attrs.concurrency_shareable) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "duplicate attribute `concurrency.shareable`", .{});
                    return ParseError.ParseFailed;
                }
                if (arg_count != 0) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "attribute `concurrency.shareable` expects no arguments", .{});
                    return ParseError.ParseFailed;
                }
                attrs.concurrency_shareable = true;
                continue;
            }

            if (std.mem.eql(u8, name, "ownership.owned")) {
                if (attrs.owned_value or attrs.shared_value or arg_count != 0) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "attribute `ownership.owned` must appear once, have no arguments, and cannot combine with shared ownership", .{});
                    return ParseError.ParseFailed;
                }
                attrs.owned_value = true;
                continue;
            }

            if (std.mem.eql(u8, name, "ownership.shared") or std.mem.eql(u8, name, "shared_value")) {
                if (attrs.shared_value) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "duplicate shared ownership attribute", .{});
                    return ParseError.ParseFailed;
                }
                if (arg_count != 0) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "shared ownership attribute expects no arguments", .{});
                    return ParseError.ParseFailed;
                }
                if (attrs.owned_value) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "shared and owned behavior attributes cannot combine", .{});
                    return ParseError.ParseFailed;
                }
                attrs.shared_value = true;
                continue;
            }

            if (std.mem.eql(u8, name, "concurrency.trusted_extern")) {
                if (attrs.concurrency_trusted_extern) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "duplicate attribute `concurrency.trusted_extern`", .{});
                    return ParseError.ParseFailed;
                }
                if (arg_count != 0) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "attribute `concurrency.trusted_extern` expects no arguments", .{});
                    return ParseError.ParseFailed;
                }
                attrs.concurrency_trusted_extern = true;
                continue;
            }

            if (std.mem.eql(u8, name, "intrinsic")) {
                if (attrs.intrinsic_name != null) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "duplicate attribute `intrinsic`", .{});
                    return ParseError.ParseFailed;
                }
                if (arg_count != 1 or arg == null or arg.?.tag != .string_lit) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "attribute `intrinsic` expects one string literal argument", .{});
                    return ParseError.ParseFailed;
                }
                attrs.intrinsic_name = arg.?.lexeme[1 .. arg.?.lexeme.len - 1];
                attrs.intrinsic_token = at_token;
                continue;
            }

            if (std.mem.startsWith(u8, name, "syntax.")) {
                if (std.meta.stringToEnum(ast.SyntaxRole, name[7..])) |role| {
                    if (attrs.syntax_role != null or arg_count != 0) {
                        try self.diagnostic_context.emitToken(self.path, at_token, "syntax role attributes expect no arguments and cannot be repeated or combined", .{});
                        return ParseError.ParseFailed;
                    }
                    attrs.syntax_role = role;
                    continue;
                }
            }

            if (std.mem.eql(u8, name, "syntax.slice_view")) {
                if (attrs.slice_view) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "duplicate attribute `syntax.slice_view`", .{});
                    return ParseError.ParseFailed;
                }
                if (arg_count != 0) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "attribute `syntax.slice_view` expects no arguments", .{});
                    return ParseError.ParseFailed;
                }
                attrs.slice_view = true;
                continue;
            }

            if (std.mem.eql(u8, name, "syntax.sequence_literal")) {
                if (attrs.sequence_literal) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "duplicate attribute `syntax.sequence_literal`", .{});
                    return ParseError.ParseFailed;
                }
                if (arg_count != 0) {
                    try self.diagnostic_context.emitToken(self.path, at_token, "attribute `syntax.sequence_literal` expects no arguments", .{});
                    return ParseError.ParseFailed;
                }
                attrs.sequence_literal = true;
                continue;
            }

            try self.diagnostic_context.emitToken(self.path, at_token, "unknown attribute `{s}`", .{name});
            return ParseError.ParseFailed;
        }
        return attrs;
    }

    fn parseAttributeName(self: *Parser) ParseError![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const first = try self.expectAttributeNameSegment("expected attribute name after `@`");
        try out.appendSlice(self.allocator, first.lexeme);
        while (self.match(.dot)) {
            const next = try self.expectAttributeNameSegment("expected attribute name segment after `.`");
            try out.append(self.allocator, '.');
            try out.appendSlice(self.allocator, next.lexeme);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn expectAttributeNameSegment(self: *Parser, message: []const u8) ParseError!lexer.Token {
        if (self.check(.identifier) or self.check(.keyword_import) or self.check(.keyword_export) or self.check(.keyword_asm)) return self.advance();
        try self.diagnostic_context.emitToken(self.path, self.peek(), "{s}", .{message});
        return ParseError.ParseFailed;
    }

    fn parseOptionalStringAttributeArg(self: *Parser, attr_name: []const u8, attr_token: lexer.Token, arg: ?lexer.Token, arg_count: usize) ParseError!?[]const u8 {
        if (arg_count == 0) return null;
        if (arg_count != 1 or arg == null or arg.?.tag != .string_lit) {
            try self.diagnostic_context.emitToken(self.path, attr_token, "attribute `{s}` expects zero arguments or one string literal argument", .{attr_name});
            return ParseError.ParseFailed;
        }
        return arg.?.lexeme[1 .. arg.?.lexeme.len - 1];
    }

    fn rejectAttrs(self: *Parser, attrs: DeclAttrs, target: []const u8) ParseError!void {
        if (!attrs.hasAny()) return;
        if (attrs.syntax_role) |role| {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `syntax.{s}` is only supported on inherent instance methods", .{@tagName(role)});
            return ParseError.ParseFailed;
        }
        if (attrs.slice_view) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `syntax.slice_view` is only supported on instance methods", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.sequence_literal) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `syntax.sequence_literal` is only supported on top-level factory functions", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.isolated and !attrs.abi_c and !attrs.link_import and !attrs.link_export and !attrs.asm_export) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `concurrency.isolated` is only supported on functions", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.concurrency_shareable and !(attrs.abi_c or attrs.link_import or attrs.link_export or attrs.asm_export or attrs.isolated or attrs.concurrency_trusted_extern)) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `concurrency.shareable` is only supported on structs", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.shared_value and !(attrs.abi_c or attrs.link_import or attrs.link_export or attrs.asm_export or attrs.isolated or attrs.concurrency_shareable or attrs.concurrency_trusted_extern)) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `shared_value` is only supported on structs", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.owned_value) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `ownership.owned` is only supported on structs", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.concurrency_trusted_extern and !(attrs.abi_c or attrs.link_import or attrs.link_export or attrs.asm_export or attrs.isolated or attrs.concurrency_shareable or attrs.shared_value)) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `concurrency.trusted_extern` is only supported on extern functions", .{});
            return ParseError.ParseFailed;
        }
        try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attributes are not supported on {s}", .{target});
        return ParseError.ParseFailed;
    }

    fn validateLinkAttrsRequireAbi(self: *Parser, attrs: DeclAttrs) ParseError!void {
        if ((attrs.link_import or attrs.link_export) and !attrs.abi_c) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "`link.import` and `link.export` require `@abi(\"c\")`", .{});
            return ParseError.ParseFailed;
        }
    }

    fn parseTypeAlias(self: *Parser, is_pub: bool) ParseError!void {
        const name = try self.expect(.identifier, "expected type alias name");
        const type_params = try self.parseGenericParams();
        errdefer {
            for (type_params) |param| param.deinit(self.allocator);
            self.allocator.free(type_params);
        }
        _ = try self.expect(.equal, "expected `=` after type alias name");
        const is_distinct = self.matchIdent("distinct");
        const target = try self.parseTypeName("expected aliased type");
        _ = try self.expect(.semicolon, "expected `;` after type alias");
        self.aliases.append(self.allocator, .{
            .module_name = "",
            .name = name.lexeme,
            .type_params = type_params,
            .target = target,
            .is_pub = is_pub,
            .is_distinct = is_distinct,
            .name_token = name,
        }) catch |err| {
            target.deinit(self.allocator);
            return err;
        };
    }

    fn parseImport(self: *Parser) ParseError!void {
        if (self.match(.l_brace)) {
            var items: std.ArrayListUnmanaged(ast.ImportItem) = .empty;
            errdefer {
                for (items.items) |item| item.deinit(self.allocator);
                items.deinit(self.allocator);
            }

            while (true) {
                const name = try self.expect(.identifier, "expected imported name");
                const local_name = if (self.match(.keyword_as))
                    try self.expectOwnedIdentifier("expected local import alias")
                else
                    null;
                try items.append(self.allocator, .{
                    .name = name.lexeme,
                    .local_name = local_name,
                    .name_token = name,
                });
                if (!self.match(.comma)) break;
            }

            _ = try self.expect(.r_brace, "expected `}` after import list");
            if (!self.matchIdent("from")) {
                try self.diagnostic_context.emitToken(self.path, self.peek(), "expected `from` after import list", .{});
                return ParseError.ParseFailed;
            }
            const path_token = self.peek();
            const import_path_info = try self.parseImportPath("expected import path");
            _ = try self.expect(.semicolon, "expected `;` after import");
            try self.imports.append(self.allocator, .{
                .path = import_path_info.path,
                .is_root_package = import_path_info.is_root_package,
                .local_name = null,
                .items = try items.toOwnedSlice(self.allocator),
                .path_token = path_token,
            });
            return;
        }

        const path_token = self.peek();
        const import_path_info = try self.parseImportPath("expected import path");
        const local_name = if (self.match(.keyword_as))
            try self.expectOwnedIdentifier("expected import alias")
        else
            null;
        _ = try self.expect(.semicolon, "expected `;` after import");
        try self.imports.append(self.allocator, .{
            .path = import_path_info.path,
            .is_root_package = import_path_info.is_root_package,
            .local_name = local_name,
            .items = try self.allocator.alloc(ast.ImportItem, 0),
            .path_token = path_token,
        });
    }

    fn parseEnum(self: *Parser, layout: ast.EnumLayout, is_pub: bool) ParseError!void {
        try self.parseEnumInNamespace(null, layout, is_pub);
    }

    fn parseEnumInNamespace(self: *Parser, owner_name: ?[]const u8, layout: ast.EnumLayout, is_pub: bool) ParseError!void {
        const name = try self.expect(.identifier, "expected enum name");
        const stored_name = if (owner_name) |owner|
            try std.fmt.allocPrint(self.allocator, "{s}${s}", .{ owner, name.lexeme })
        else
            name.lexeme;
        errdefer if (owner_name != null) self.allocator.free(stored_name);
        const has_repr = self.match(.colon);
        var repr_name: ?[]const u8 = null;
        if (has_repr) {
            const repr = try self.expect(.identifier, "expected enum representation type");
            repr_name = repr.lexeme;
        } else if (layout == .c) {
            try self.diagnostic_context.emitToken(self.path, name, "`c enum` requires an explicit representation type", .{});
            return ParseError.ParseFailed;
        } else if (layout == .flags) {
            try self.diagnostic_context.emitToken(self.path, name, "`flags` requires an explicit representation type", .{});
            return ParseError.ParseFailed;
        }
        _ = try self.expect(.l_brace, "expected enum body");

        var cases: std.ArrayListUnmanaged(ast.EnumCase) = .empty;
        errdefer cases.deinit(self.allocator);

        while (!self.check(.r_brace) and !self.check(.eof)) {
            const case_name = try self.expect(.identifier, "expected enum case name");
            const value: ?i64 = if (self.match(.equal)) blk: {
                const value_token = try self.expect(.int_lit, "expected enum case integer value");
                break :blk std.fmt.parseInt(i64, value_token.lexeme, 10) catch {
                    try self.diagnostic_context.emitToken(self.path, value_token, "invalid enum value `{s}`", .{value_token.lexeme});
                    return ParseError.ParseFailed;
                };
            } else null;
            try cases.append(self.allocator, .{
                .name = case_name.lexeme,
                .value = value,
                .name_token = case_name,
            });

            if (self.match(.comma) or self.match(.semicolon)) continue;
            if (!self.check(.r_brace)) {
                try self.diagnostic_context.emitToken(self.path, self.peek(), "expected `,` after enum case", .{});
                return ParseError.ParseFailed;
            }
        }

        _ = try self.expect(.r_brace, "expected `}` after enum body");
        try self.enums.append(self.allocator, .{
            .module_name = "",
            .name = stored_name,
            .layout = layout,
            .repr_name = repr_name,
            .cases = try cases.toOwnedSlice(self.allocator),
            .is_pub = is_pub,
            .owns_name = owner_name != null,
            .name_token = name,
        });
    }

    fn parseUnion(self: *Parser, layout: ast.UnionLayout, is_pub: bool) ParseError!void {
        const name = try self.expect(.identifier, "expected union name");
        if (self.match(.equal)) {
            if (layout == .c) {
                try self.diagnostic_context.emitToken(self.path, name, "`c union` does not support type-union syntax", .{});
                return ParseError.ParseFailed;
            }
            var variants: std.ArrayListUnmanaged(ast.TypeName) = .empty;
            errdefer {
                for (variants.items) |variant| variant.deinit(self.allocator);
                variants.deinit(self.allocator);
            }
            while (true) {
                const variant = try self.parseTypeName("expected type-union variant type");
                try variants.append(self.allocator, variant);
                if (!self.match(.pipe)) break;
            }
            _ = try self.expect(.semicolon, "expected `;` after type union");
            try self.unions.append(self.allocator, .{
                .module_name = "",
                .name = name.lexeme,
                .layout = layout,
                .kind = .type_union,
                .fields = try self.allocator.alloc(ast.UnionField, 0),
                .variants = try variants.toOwnedSlice(self.allocator),
                .is_pub = is_pub,
                .name_token = name,
            });
            return;
        }
        _ = try self.expect(.l_brace, "expected union body");

        var fields: std.ArrayListUnmanaged(ast.UnionField) = .empty;
        errdefer {
            for (fields.items) |field| field.deinit(self.allocator);
            fields.deinit(self.allocator);
        }

        while (!self.check(.r_brace) and !self.check(.eof)) {
            if (self.match(.keyword_pub)) {
                try self.diagnostic_context.emitToken(self.path, self.previous(), "union cases cannot be marked `pub`; visibility applies to the union declaration", .{});
                return ParseError.ParseFailed;
            }

            const field_name = try self.expectUnionCaseName("expected union field name");
            const type_name = if (self.match(.colon))
                try self.parseTypeName("expected union field type")
            else if (layout == .c) {
                try self.diagnostic_context.emitToken(self.path, field_name, "`c union` fields require an explicit type", .{});
                return ParseError.ParseFailed;
            } else null;
            _ = try self.expect(.semicolon, "expected `;` after union field");
            try fields.append(self.allocator, .{
                .name = field_name.lexeme,
                .type_name = type_name,
                .name_token = field_name,
            });
        }

        _ = try self.expect(.r_brace, "expected `}` after union body");
        try self.unions.append(self.allocator, .{
            .module_name = "",
            .name = name.lexeme,
            .layout = layout,
            .kind = .named_cases,
            .fields = try fields.toOwnedSlice(self.allocator),
            .variants = try self.allocator.alloc(ast.TypeName, 0),
            .is_pub = is_pub,
            .name_token = name,
        });
    }

    fn parseProtocol(self: *Parser, is_pub: bool) ParseError!void {
        const name = try self.expect(.identifier, "expected protocol name");
        _ = try self.expect(.l_brace, "expected protocol body");

        var associated_types: std.ArrayListUnmanaged(ast.AssociatedTypeDecl) = .empty;
        errdefer associated_types.deinit(self.allocator);
        var methods: std.ArrayListUnmanaged(ast.ProtocolMethod) = .empty;
        errdefer {
            for (methods.items) |method| method.deinit(self.allocator);
            methods.deinit(self.allocator);
        }

        while (!self.check(.r_brace) and !self.check(.eof)) {
            if (self.match(.keyword_type)) {
                const associated_name = try self.expect(.identifier, "expected associated type name");
                _ = try self.expect(.semicolon, "expected `;` after associated type");
                try associated_types.append(self.allocator, .{
                    .name = associated_name.lexeme,
                    .name_token = associated_name,
                });
                continue;
            }
            _ = try self.expect(.keyword_fn, "expected protocol method");
            const method_name = try self.expect(.identifier, "expected protocol method name");
            const params = try self.parseParams();
            errdefer self.allocator.free(params);
            const return_type: ?ast.TypeName = if (self.match(.colon))
                try self.parseReturnTypeName("expected return type")
            else
                null;
            errdefer if (return_type) |ty| ty.deinit(self.allocator);
            _ = try self.expect(.semicolon, "expected `;` after protocol method");
            try methods.append(self.allocator, .{
                .name = method_name.lexeme,
                .params = params,
                .return_type = return_type,
                .name_token = method_name,
            });
        }

        _ = try self.expect(.r_brace, "expected `}` after protocol body");
        try self.protocols.append(self.allocator, .{
            .module_name = "",
            .name = name.lexeme,
            .associated_types = try associated_types.toOwnedSlice(self.allocator),
            .methods = try methods.toOwnedSlice(self.allocator),
            .is_pub = is_pub,
            .name_token = name,
        });
    }

    fn parseImpl(self: *Parser) ParseError!void {
        const token = self.previous();
        const type_params = try self.parseGenericParams();
        errdefer {
            for (type_params) |param| param.deinit(self.allocator);
            self.allocator.free(type_params);
        }
        const type_name = try self.parseTypeName("expected implemented type");
        errdefer type_name.deinit(self.allocator);
        _ = try self.expect(.colon, "expected `:` in impl declaration");
        const protocol_name = try self.parseTypeName("expected protocol name");
        errdefer protocol_name.deinit(self.allocator);
        const method_owner = try std.fmt.allocPrint(self.allocator, "__impl${d}", .{self.impls.items.len});
        errdefer self.allocator.free(method_owner);
        var associated_types: std.ArrayListUnmanaged(ast.AssociatedTypeBinding) = .empty;
        errdefer {
            for (associated_types.items) |binding| binding.deinit(self.allocator);
            associated_types.deinit(self.allocator);
        }
        var methods: std.ArrayListUnmanaged(ast.Function) = .empty;
        errdefer {
            for (methods.items) |method| method.deinit(self.allocator);
            methods.deinit(self.allocator);
        }

        if (!self.match(.semicolon)) {
            _ = try self.expect(.l_brace, "expected `{` or `;` after impl declaration");
            while (!self.check(.r_brace) and !self.check(.eof)) {
                if (self.match(.keyword_pub)) {
                    try self.diagnostic_context.emitToken(self.path, self.previous(), "protocol implementation methods cannot be `pub`", .{});
                    return ParseError.ParseFailed;
                }
                if (self.match(.keyword_type)) {
                    const associated_name = try self.expect(.identifier, "expected associated type name");
                    _ = try self.expect(.equal, "expected `=` in associated type binding");
                    const associated_type = try self.parseTypeName("expected associated type");
                    errdefer associated_type.deinit(self.allocator);
                    _ = try self.expect(.semicolon, "expected `;` after associated type binding");
                    try associated_types.append(self.allocator, .{
                        .name = associated_name.lexeme,
                        .type_name = associated_type,
                        .name_token = associated_name,
                    });
                    continue;
                }
                _ = try self.expect(.keyword_fn, "expected protocol implementation method");
                try methods.append(self.allocator, try self.parseFunctionDecl(method_owner, false, .cyna, false, false, false, false, true, null));
            }
            _ = try self.expect(.r_brace, "expected `}` after impl body");
        }
        try self.impls.append(self.allocator, .{
            .module_name = "",
            .type_params = type_params,
            .method_owner = method_owner,
            .type_name = type_name,
            .protocol_name = protocol_name,
            .associated_types = try associated_types.toOwnedSlice(self.allocator),
            .methods = try methods.toOwnedSlice(self.allocator),
            .token = token,
        });
    }

    fn parseGlobal(self: *Parser, is_mutable: bool, is_pub: bool) ParseError!void {
        const name = try self.expect(.identifier, "expected global name");
        const type_name = if (self.match(.colon))
            try self.parseTypeName("expected global type")
        else
            null;
        _ = try self.expect(.equal, "expected `=` after global name");
        const init = try self.parseExpr();
        _ = try self.expect(.semicolon, "expected `;` after global declaration");
        try self.globals.append(self.allocator, .{
            .module_name = "",
            .is_mutable = is_mutable,
            .is_pub = is_pub,
            .is_extern = false,
            .calling_convention = .cyna,
            .name = name.lexeme,
            .abi_name = null,
            .type_name = type_name,
            .init = init,
            .name_token = name,
        });
    }

    fn parseGlobalWithAttrs(self: *Parser, is_mutable: bool, is_pub: bool, attrs: DeclAttrs) ParseError!void {
        if (attrs.sequence_literal) return self.rejectAttrs(attrs, "globals");
        if (!attrs.hasAny()) {
            try self.parseGlobal(is_mutable, is_pub);
            return;
        }
        if (attrs.isolated) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `concurrency.isolated` is only supported on functions", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.concurrency_shareable) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `concurrency.shareable` is only supported on structs", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.shared_value) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `shared_value` is only supported on structs", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.owned_value) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `ownership.owned` is only supported on structs", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.concurrency_trusted_extern) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `concurrency.trusted_extern` is only supported on extern functions", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.link_export) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `link.export` requires a function declaration", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.asm_export) {
            if (is_mutable) {
                try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `asm.export` is only valid on constants", .{});
                return ParseError.ParseFailed;
            }
            if (attrs.abi_c or attrs.link_import) {
                try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `asm.export` cannot be combined with ABI or link attributes", .{});
                return ParseError.ParseFailed;
            }
            try self.parseExportAsmConst(attrs.abi_name);
            return;
        }
        try self.validateLinkAttrsRequireAbi(attrs);
        if (!attrs.link_import) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `abi` on globals requires `link.import`", .{});
            return ParseError.ParseFailed;
        }
        if (is_pub) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "extern globals cannot be exported from a Cyna module; expose an accessor function instead", .{});
            return ParseError.ParseFailed;
        }
        try self.parseExternGlobal(is_mutable, attrs.abi_name);
    }

    fn parseStructWithAttrs(self: *Parser, layout: ast.StructLayout, is_pub: bool, attrs: DeclAttrs) ParseError!void {
        if (attrs.sequence_literal) return self.rejectAttrs(attrs, "structs");
        if (!attrs.hasAny()) {
            try self.parseStruct(layout, is_pub, .{});
            return;
        }
        if ((attrs.concurrency_shareable and (attrs.shared_value or attrs.owned_value)) or
            (attrs.shared_value and attrs.owned_value) or
            (!attrs.concurrency_shareable and !attrs.shared_value and !attrs.owned_value) or
            attrs.abi_c or attrs.link_import or attrs.link_export or attrs.asm_export or attrs.isolated or attrs.concurrency_trusted_extern)
        {
            try self.rejectAttrs(attrs, "structs");
            return;
        }
        try self.parseStruct(layout, is_pub, .{ .is_concurrency_shareable = attrs.concurrency_shareable, .is_shared_value = attrs.shared_value, .is_owned_value = attrs.owned_value });
    }

    const StructAttrFlags = struct {
        is_concurrency_shareable: bool = false,
        is_shared_value: bool = false,
        is_owned_value: bool = false,
    };

    fn parseStruct(self: *Parser, layout: ast.StructLayout, is_pub: bool, flags: StructAttrFlags) ParseError!void {
        const name = try self.expect(.identifier, "expected struct name");
        const type_params = try self.parseGenericParams();
        errdefer {
            for (type_params) |param| param.deinit(self.allocator);
            self.allocator.free(type_params);
        }
        _ = try self.expect(.l_brace, "expected struct body");

        var fields: std.ArrayListUnmanaged(ast.FieldDecl) = .empty;
        var methods: std.ArrayListUnmanaged(ast.Function) = .empty;
        errdefer {
            for (fields.items) |field| field.deinit(self.allocator);
            fields.deinit(self.allocator);
            for (methods.items) |method| method.deinit(self.allocator);
            methods.deinit(self.allocator);
        }

        while (!self.check(.r_brace) and !self.check(.eof)) {
            var attrs = try self.parseDeclAttrs();
            const member_is_pub = self.match(.keyword_pub);
            if (member_is_pub) {
                attrs = try self.parseDeclAttrsInto(attrs);
            }

            if (self.match(.keyword_fn)) {
                try methods.append(self.allocator, try self.parseStructMethodDecl(name.lexeme, member_is_pub, attrs));
                continue;
            }

            if (self.match(.keyword_const)) {
                try self.rejectAttrs(attrs, "struct constants");
                try self.parseStructConst(name.lexeme, member_is_pub);
                continue;
            }

            if (self.match(.keyword_enum)) {
                try self.rejectAttrs(attrs, "enums");
                try self.parseEnumInNamespace(name.lexeme, .normal, member_is_pub);
                continue;
            }

            if (self.match(.keyword_flags)) {
                try self.rejectAttrs(attrs, "flags");
                try self.parseEnumInNamespace(name.lexeme, .flags, member_is_pub);
                continue;
            }

            if (self.match(.keyword_var)) {
                try self.rejectAttrs(attrs, "struct namespace variables");
                try self.diagnostic_context.emitToken(self.path, self.previous(), "struct namespace variables are not supported; use `const` for static members", .{});
                return ParseError.ParseFailed;
            }

            if (self.match(.keyword_struct)) {
                try self.rejectAttrs(attrs, "structs");
                try self.parseNestedStruct(name.lexeme, .normal, member_is_pub);
                continue;
            }

            if (self.match(.keyword_packed)) {
                try self.rejectAttrs(attrs, "structs");
                _ = try self.expect(.keyword_struct, "expected `struct` after `packed`");
                try self.parseNestedStruct(name.lexeme, .@"packed", member_is_pub);
                continue;
            }

            if (attrs.hasAny()) {
                try self.diagnostic_context.emitToken(self.path, self.peek(), "attribute list inside a struct must be followed by a method", .{});
                return ParseError.ParseFailed;
            }

            if (member_is_pub and !self.check(.identifier)) {
                try self.diagnostic_context.emitToken(self.path, self.peek(), "`pub` inside a struct must be followed by a field, method, `const`, `enum`, `flags`, `struct`, or `packed struct`", .{});
                return ParseError.ParseFailed;
            }

            const field_name = try self.expect(.identifier, "expected field name");
            _ = try self.expect(.colon, "expected `:` after field name");
            const type_name = try self.parseTypeName("expected field type");
            const default_value = if (self.match(.equal)) try self.parseExpr() else null;
            _ = try self.expect(.semicolon, "expected `;` after field");
            fields.append(self.allocator, .{
                .name = field_name.lexeme,
                .type_name = type_name,
                .default_value = default_value,
                .is_pub = member_is_pub,
                .name_token = field_name,
            }) catch |err| {
                type_name.deinit(self.allocator);
                return err;
            };
        }

        _ = try self.expect(.r_brace, "expected `}` after struct body");
        try self.structs.append(self.allocator, .{
            .module_name = "",
            .name = name.lexeme,
            .type_params = type_params,
            .layout = layout,
            .fields = try fields.toOwnedSlice(self.allocator),
            .methods = try methods.toOwnedSlice(self.allocator),
            .is_pub = is_pub,
            .is_concurrency_shareable = flags.is_concurrency_shareable,
            .is_shared_value = flags.is_shared_value,
            .is_owned_value = flags.is_owned_value,
            .name_token = name,
        });
    }

    fn parseStructConst(self: *Parser, owner_name: []const u8, is_pub: bool) ParseError!void {
        const name = try self.expect(.identifier, "expected struct constant name");
        const type_name = if (self.match(.colon))
            try self.parseTypeName("expected struct constant type")
        else
            null;
        _ = try self.expect(.equal, "expected `=` after struct constant name");
        const init = try self.parseExpr();
        _ = try self.expect(.semicolon, "expected `;` after struct constant declaration");
        try self.globals.append(self.allocator, .{
            .module_name = "",
            .owner = owner_name,
            .is_mutable = false,
            .is_pub = is_pub,
            .is_extern = false,
            .calling_convention = .cyna,
            .name = name.lexeme,
            .abi_name = null,
            .type_name = type_name,
            .init = init,
            .name_token = name,
        });
    }

    fn parseNestedStruct(self: *Parser, owner_name: []const u8, layout: ast.StructLayout, is_pub: bool) ParseError!void {
        const name = try self.expect(.identifier, "expected nested struct name");
        const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ owner_name, name.lexeme });
        errdefer self.allocator.free(qualified_name);
        const namespace_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ owner_name, name.lexeme });
        defer self.allocator.free(namespace_name);
        const type_params = try self.parseGenericParams();
        errdefer {
            for (type_params) |param| param.deinit(self.allocator);
            self.allocator.free(type_params);
        }
        _ = try self.expect(.l_brace, "expected nested struct body");

        var fields: std.ArrayListUnmanaged(ast.FieldDecl) = .empty;
        var methods: std.ArrayListUnmanaged(ast.Function) = .empty;
        errdefer {
            for (fields.items) |field| field.deinit(self.allocator);
            fields.deinit(self.allocator);
            for (methods.items) |method| method.deinit(self.allocator);
            methods.deinit(self.allocator);
        }

        while (!self.check(.r_brace) and !self.check(.eof)) {
            var attrs = try self.parseDeclAttrs();
            const member_is_pub = self.match(.keyword_pub);
            if (member_is_pub) {
                attrs = try self.parseDeclAttrsInto(attrs);
            }

            if (self.match(.keyword_fn)) {
                try methods.append(self.allocator, try self.parseStructMethodDecl(qualified_name, member_is_pub, attrs));
                continue;
            }
            if (self.match(.keyword_enum)) {
                try self.rejectAttrs(attrs, "enums");
                try self.parseEnumInNamespace(namespace_name, .normal, member_is_pub);
                continue;
            }
            if (self.match(.keyword_flags)) {
                try self.rejectAttrs(attrs, "flags");
                try self.parseEnumInNamespace(namespace_name, .flags, member_is_pub);
                continue;
            }
            if (attrs.hasAny()) {
                try self.diagnostic_context.emitToken(self.path, self.peek(), "attribute list inside a nested struct must be followed by a method", .{});
                return ParseError.ParseFailed;
            }
            if (member_is_pub and !self.check(.identifier)) {
                try self.diagnostic_context.emitToken(self.path, self.peek(), "`pub` inside a nested struct must be followed by a field, method, `enum`, or `flags`", .{});
                return ParseError.ParseFailed;
            }
            const field_name = try self.expect(.identifier, "expected field name");
            _ = try self.expect(.colon, "expected `:` after field name");
            const type_name = try self.parseTypeName("expected field type");
            const default_value = if (self.match(.equal)) try self.parseExpr() else null;
            _ = try self.expect(.semicolon, "expected `;` after field");
            fields.append(self.allocator, .{
                .name = field_name.lexeme,
                .type_name = type_name,
                .default_value = default_value,
                .is_pub = member_is_pub,
                .name_token = field_name,
            }) catch |err| {
                type_name.deinit(self.allocator);
                return err;
            };
        }

        _ = try self.expect(.r_brace, "expected `}` after nested struct body");
        try self.structs.append(self.allocator, .{
            .module_name = "",
            .name = qualified_name,
            .type_params = type_params,
            .layout = layout,
            .fields = try fields.toOwnedSlice(self.allocator),
            .methods = try methods.toOwnedSlice(self.allocator),
            .is_pub = is_pub,
            .owns_name = true,
            .name_token = name,
        });
    }

    fn parseExternDecl(self: *Parser, is_pub: bool, attrs: DeclAttrs) ParseError!void {
        if (self.match(.l_brace)) {
            if (attrs.hasAny()) {
                try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attributes are not supported on extern blocks", .{});
                return ParseError.ParseFailed;
            }
            if (is_pub) {
                try self.diagnostic_context.emitToken(self.path, self.previous(), "`pub extern` blocks are not supported; put `pub` on individual extern functions", .{});
                return ParseError.ParseFailed;
            }
            try self.parseExternBlock();
            return;
        }

        const abi_name = try self.parseCAbiSpecifier("extern");

        if (self.match(.keyword_fn)) {
            if (attrs.hasAny() and (!attrs.concurrency_trusted_extern or attrs.abi_c or attrs.link_import or attrs.link_export or attrs.asm_export or attrs.isolated or attrs.concurrency_shareable)) {
                try self.rejectAttrs(attrs, "`extern` declarations");
                return;
            }
            try self.functions.append(self.allocator, try self.parseFunctionDecl(null, is_pub, .c, true, false, false, attrs.concurrency_trusted_extern, false, abi_name));
            _ = try self.expect(.semicolon, "expected `;` after extern function declaration");
            return;
        }

        if (attrs.concurrency_trusted_extern) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `concurrency.trusted_extern` is only supported on extern functions", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.hasAny()) {
            try self.rejectAttrs(attrs, "`extern` declarations");
            return;
        }

        if (self.match(.keyword_const)) {
            if (is_pub) {
                try self.diagnostic_context.emitToken(self.path, self.previous(), "extern globals cannot be exported from a Cyna module; expose an accessor function instead", .{});
                return ParseError.ParseFailed;
            }
            try self.parseExternGlobal(false, abi_name);
            return;
        }

        if (self.match(.keyword_var)) {
            if (is_pub) {
                try self.diagnostic_context.emitToken(self.path, self.previous(), "extern globals cannot be exported from a Cyna module; expose an accessor function instead", .{});
                return ParseError.ParseFailed;
            }
            try self.parseExternGlobal(true, abi_name);
            return;
        }

        try self.diagnostic_context.emitToken(self.path, self.peek(), "expected `fn`, `const`, `var`, or `{{` after `extern` ABI specifier", .{});
        return ParseError.ParseFailed;
    }

    fn parseExternBlock(self: *Parser) ParseError!void {
        while (!self.check(.r_brace) and !self.check(.eof)) {
            const member_is_pub = self.match(.keyword_pub);
            const abi_name = try self.parseCAbiSpecifier("extern block member");
            if (self.match(.keyword_fn)) {
                try self.functions.append(self.allocator, try self.parseFunctionDecl(null, member_is_pub, .c, true, false, false, false, false, abi_name));
                _ = try self.expect(.semicolon, "expected `;` after extern function declaration");
                continue;
            }
            if (self.match(.keyword_const)) {
                if (member_is_pub) {
                    try self.diagnostic_context.emitToken(self.path, self.previous(), "extern globals cannot be exported from a Cyna module; expose an accessor function instead", .{});
                    return ParseError.ParseFailed;
                }
                try self.parseExternGlobal(false, abi_name);
                continue;
            }
            if (self.match(.keyword_var)) {
                if (member_is_pub) {
                    try self.diagnostic_context.emitToken(self.path, self.previous(), "extern globals cannot be exported from a Cyna module; expose an accessor function instead", .{});
                    return ParseError.ParseFailed;
                }
                try self.parseExternGlobal(true, abi_name);
                continue;
            }
            try self.diagnostic_context.emitToken(self.path, self.peek(), "expected `fn`, `const`, or `var` after extern block ABI specifier", .{});
            return ParseError.ParseFailed;
        }
        _ = try self.expect(.r_brace, "expected `}` after extern block");
    }

    fn parseExternGlobal(self: *Parser, is_mutable: bool, abi_name_override: ?[]const u8) ParseError!void {
        const name = try self.expect(.identifier, "expected extern global name");
        _ = try self.expect(.colon, "expected `:` after extern global name");
        const type_name = try self.parseTypeName("expected extern global type");
        _ = try self.expect(.semicolon, "expected `;` after extern global declaration");
        try self.globals.append(self.allocator, .{
            .module_name = "",
            .is_mutable = is_mutable,
            .is_pub = false,
            .is_extern = true,
            .calling_convention = .c,
            .name = name.lexeme,
            .abi_name = abi_name_override,
            .type_name = type_name,
            .init = null,
            .name_token = name,
        });
    }

    fn parseExportDecl(self: *Parser, is_pub: bool) ParseError!void {
        if (self.check(.identifier) and std.mem.eql(u8, self.peek().lexeme, "c")) {
            const abi_name = try self.parseCAbiSpecifier("export");
            _ = try self.expect(.keyword_fn, "expected `fn` after `export c`");
            try self.functions.append(self.allocator, try self.parseFunctionDecl(null, is_pub, .c, false, true, false, false, true, abi_name));
            return;
        }
        if (self.check(.keyword_asm)) {
            const abi_name = try self.parseAsmAbiSpecifier();
            if (is_pub) {
                try self.diagnostic_context.emitToken(self.path, self.previous(), "`pub export asm const` is not supported; asm constants are emitted symbols, not module bindings", .{});
                return ParseError.ParseFailed;
            }
            _ = try self.expect(.keyword_const, "expected `const` after `export asm`");
            try self.parseExportAsmConst(abi_name);
            return;
        }
        try self.diagnostic_context.emitToken(self.path, self.peek(), "expected `c` or `asm` after `export`", .{});
        return ParseError.ParseFailed;
    }

    fn parseCAbiSpecifier(self: *Parser, boundary: []const u8) ParseError!?[]const u8 {
        if (!self.matchIdent("c")) {
            try self.diagnostic_context.emitToken(self.path, self.peek(), "expected calling convention after `{s}`", .{boundary});
            return ParseError.ParseFailed;
        }
        if (!self.match(.l_paren)) return null;
        const symbol = try self.expect(.string_lit, "expected ABI symbol name string literal");
        _ = try self.expect(.r_paren, "expected `)` after ABI symbol name");
        return symbol.lexeme[1 .. symbol.lexeme.len - 1];
    }

    fn parseAsmAbiSpecifier(self: *Parser) ParseError!?[]const u8 {
        _ = try self.expect(.keyword_asm, "expected `asm` after `export`");
        if (!self.match(.l_paren)) return null;
        const symbol = try self.expect(.string_lit, "expected assembler symbol name string literal");
        _ = try self.expect(.r_paren, "expected `)` after assembler symbol name");
        return symbol.lexeme[1 .. symbol.lexeme.len - 1];
    }

    fn parseExportAsmConst(self: *Parser, abi_name: ?[]const u8) ParseError!void {
        const name = try self.expect(.identifier, "expected asm constant name");
        _ = try self.expect(.colon, "expected `:` after asm constant name");
        const type_name = try self.parseTypeName("expected asm constant type");
        _ = try self.expect(.equal, "expected `=` after asm constant type");
        const init = try self.parseExpr();
        _ = try self.expect(.semicolon, "expected `;` after asm constant initializer");
        try self.asm_consts.append(self.allocator, .{
            .module_name = "",
            .name = name.lexeme,
            .abi_name = abi_name,
            .type_name = type_name,
            .init = init,
            .name_token = name,
        });
    }

    fn parseFunction(self: *Parser, owner: ?[]const u8, is_pub: bool, calling_convention: ast.CallingConvention, is_extern: bool, is_export: bool) ParseError!void {
        const function = try self.parseFunctionDecl(owner, is_pub, calling_convention, is_extern, is_export, false, false, true, null);
        errdefer function.deinit(self.allocator);
        try self.functions.append(self.allocator, function);
    }

    fn parseFunctionWithAttrs(self: *Parser, owner: ?[]const u8, is_pub: bool, attrs: DeclAttrs) ParseError!void {
        if (!attrs.hasAny()) {
            try self.parseFunction(owner, is_pub, .cyna, false, false);
            return;
        }
        if (attrs.asm_export) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `asm.export` is only valid on constants", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.concurrency_shareable) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `concurrency.shareable` is only supported on structs", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.owned_value) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `ownership.owned` is only supported on structs", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.sequence_literal) {
            if (owner != null or !is_pub or attrs.abi_c or attrs.link_import or attrs.link_export or attrs.asm_export or attrs.shared_value or attrs.isolated or attrs.intrinsic_name != null or attrs.concurrency_trusted_extern) {
                try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `syntax.sequence_literal` requires a public Cyna factory function", .{});
                return ParseError.ParseFailed;
            }
            var function = try self.parseFunctionDecl(null, true, .cyna, false, false, false, false, true, null);
            function.is_sequence_literal_factory = true;
            try self.functions.append(self.allocator, function);
            return;
        }
        if (attrs.intrinsic_name) |intrinsic_name| {
            if (attrs.abi_c or attrs.link_import or attrs.link_export or attrs.asm_export or attrs.isolated or attrs.concurrency_shareable or attrs.shared_value or attrs.concurrency_trusted_extern) {
                try self.diagnostic_context.emitToken(self.path, attrs.intrinsic_token.?, "attribute `intrinsic` cannot be combined with other function attributes", .{});
                return ParseError.ParseFailed;
            }
            var function = try self.parseFunctionDecl(owner, is_pub, .cyna, false, false, false, false, false, null);
            function.intrinsic_name = intrinsic_name;
            function.intrinsic_token = attrs.intrinsic_token;
            try self.functions.append(self.allocator, function);
            _ = try self.expect(.semicolon, "expected `;` after intrinsic function declaration");
            return;
        }
        if (attrs.concurrency_trusted_extern and !attrs.link_import) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `concurrency.trusted_extern` is only supported on extern functions", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.isolated and (attrs.abi_c or attrs.link_import or attrs.link_export)) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `concurrency.isolated` cannot be combined with ABI or link attributes yet", .{});
            return ParseError.ParseFailed;
        }
        try self.validateLinkAttrsRequireAbi(attrs);
        if (attrs.isolated and !attrs.abi_c and !attrs.link_import and !attrs.link_export) {
            try self.functions.append(self.allocator, try self.parseFunctionDecl(owner, is_pub, .cyna, false, false, true, false, true, null));
            return;
        }
        if (attrs.abi_c and !attrs.link_import and !attrs.link_export) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `abi` on declarations requires `link.import` or `link.export`", .{});
            return ParseError.ParseFailed;
        }
        const is_extern = attrs.link_import;
        const is_export = attrs.link_export;
        const expect_body = !is_extern;
        try self.functions.append(self.allocator, try self.parseFunctionDecl(owner, is_pub, .c, is_extern, is_export, false, attrs.concurrency_trusted_extern, expect_body, attrs.abi_name));
        if (is_extern) {
            _ = try self.expect(.semicolon, "expected `;` after imported function declaration");
        }
    }

    fn parseStructMethodDecl(self: *Parser, owner: []const u8, is_pub: bool, attrs: DeclAttrs) ParseError!ast.Function {
        if (attrs.syntax_role) |role| {
            var remaining = attrs;
            remaining.syntax_role = null;
            if (remaining.hasAny()) {
                try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `syntax.{s}` cannot be combined with other method attributes", .{@tagName(role)});
                return ParseError.ParseFailed;
            }
            var method = try self.parseFunctionDecl(owner, is_pub, .cyna, false, false, false, false, true, null);
            method.syntax_role = role;
            return method;
        }
        if (attrs.slice_view) {
            if (attrs.abi_c or attrs.link_import or attrs.link_export or attrs.asm_export or attrs.isolated or attrs.concurrency_shareable or attrs.shared_value or attrs.concurrency_trusted_extern or attrs.intrinsic_name != null or attrs.sequence_literal) {
                try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `syntax.slice_view` cannot be combined with other method attributes", .{});
                return ParseError.ParseFailed;
            }
            var method = try self.parseFunctionDecl(owner, is_pub, .cyna, false, false, false, false, true, null);
            method.is_slice_view = true;
            return method;
        }
        if (!attrs.hasAny()) {
            return self.parseFunctionDecl(owner, is_pub, .cyna, false, false, false, false, true, null);
        }
        if (attrs.asm_export) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `asm.export` is only valid on constants", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.concurrency_shareable) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `concurrency.shareable` is only supported on structs", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.sequence_literal) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `syntax.sequence_literal` is only supported on top-level factory functions", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.intrinsic_name != null) {
            try self.diagnostic_context.emitToken(self.path, attrs.intrinsic_token.?, "intrinsic declarations must be top-level functions", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.concurrency_trusted_extern) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "attribute `concurrency.trusted_extern` is only supported on extern functions", .{});
            return ParseError.ParseFailed;
        }
        if (attrs.abi_c or attrs.link_import or attrs.link_export) {
            try self.diagnostic_context.emitToken(self.path, attrs.first_token.?, "ABI and link attributes are not supported on struct methods", .{});
            return ParseError.ParseFailed;
        }
        return self.parseFunctionDecl(owner, is_pub, .cyna, false, false, attrs.isolated, false, true, null);
    }

    fn parseInlineTest(self: *Parser) ParseError!void {
        const name = try self.expect(.string_lit, "expected test name string literal");
        _ = try self.expect(.l_brace, "expected test body");
        const body = try self.parseBlockBody();
        try self.tests.append(self.allocator, .{
            .module_name = "",
            .name = name.lexeme[1 .. name.lexeme.len - 1],
            .body = body,
            .name_token = name,
        });
    }

    fn parseFunctionDecl(self: *Parser, owner: ?[]const u8, is_pub: bool, calling_convention: ast.CallingConvention, is_extern: bool, is_export: bool, is_isolated: bool, is_concurrency_trusted_extern: bool, expect_body: bool, abi_name_override: ?[]const u8) ParseError!ast.Function {
        const name = try self.expect(.identifier, "expected function name");
        const type_params = try self.parseGenericParams();
        errdefer {
            for (type_params) |param| param.deinit(self.allocator);
            self.allocator.free(type_params);
        }
        const params = try self.parseParams();
        errdefer self.allocator.free(params);

        const return_type: ?ast.TypeName = if (self.match(.colon))
            try self.parseReturnTypeName("expected return type")
        else
            null;
        errdefer if (return_type) |ty| ty.deinit(self.allocator);

        if (return_type) |ty| {
            if (ty.is_inferred_result_return and (is_extern or is_export or !expect_body)) {
                try self.diagnostic_context.emitToken(self.path, ty.token, "exported and bodyless functions require an explicit error type after `!`", .{});
                return ParseError.ParseFailed;
            }
        }

        const body = if (expect_body) blk: {
            _ = try self.expect(.l_brace, "expected function body");
            break :blk try self.parseBlockBody();
        } else try self.allocator.alloc(ast.Stmt, 0);

        return .{
            .module_name = "",
            .owner = owner,
            .name = name.lexeme,
            .abi_name = abi_name_override,
            .type_params = type_params,
            .params = params,
            .return_type = return_type,
            .body = body,
            .is_pub = is_pub,
            .is_extern = is_extern,
            .is_export = is_export,
            .is_isolated = is_isolated,
            .is_concurrency_trusted_extern = is_concurrency_trusted_extern,
            .calling_convention = calling_convention,
            .name_token = name,
        };
    }

    fn parsePath(self: *Parser, message: []const u8) ParseError![]const u8 {
        const first = try self.expectPathSegment(message);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, first.lexeme);
        while (self.match(.dot)) {
            const next = try self.expectPathSegment("expected path segment after `.`");
            try out.append(self.allocator, '.');
            try out.appendSlice(self.allocator, next.lexeme);
        }
        return out.toOwnedSlice(self.allocator);
    }

    const ParsedImportPath = struct {
        path: []const u8,
        is_root_package: bool,
    };

    fn parseImportPath(self: *Parser, message: []const u8) ParseError!ParsedImportPath {
        const is_root_package = self.match(.dot);
        const path = try self.parsePath(if (is_root_package) "expected path segment after `.`" else message);
        return .{
            .path = path,
            .is_root_package = is_root_package,
        };
    }

    fn expectPathSegment(self: *Parser, message: []const u8) ParseError!lexer.Token {
        const token = self.peek();
        return switch (token.tag) {
            .identifier, .keyword_alloc => blk: {
                self.index += 1;
                break :blk token;
            },
            else => self.expect(.identifier, message),
        };
    }

    fn parseParams(self: *Parser) ParseError![]ast.Param {
        _ = try self.expect(.l_paren, "expected parameter list");
        var params: std.ArrayListUnmanaged(ast.Param) = .empty;
        errdefer {
            for (params.items) |param| param.deinit(self.allocator);
            params.deinit(self.allocator);
        }

        if (!self.check(.r_paren)) {
            while (true) {
                const name = try self.expect(.identifier, "expected parameter name");
                _ = try self.expect(.colon, "expected `:` after parameter name");
                const type_name = try self.parseTypeName("expected parameter type");
                const default_value = if (self.match(.equal)) try self.parseExpr() else null;
                params.append(self.allocator, .{
                    .name = name.lexeme,
                    .type_name = type_name,
                    .default_value = default_value,
                    .name_token = name,
                }) catch |err| {
                    type_name.deinit(self.allocator);
                    if (default_value) |value| value.destroy(self.allocator);
                    return err;
                };

                if (!self.match(.comma)) break;
            }
        }

        _ = try self.expect(.r_paren, "expected `)` after parameters");
        return params.toOwnedSlice(self.allocator);
    }

    fn parseFunctionExprParams(self: *Parser) ParseError![]ast.FunctionExprParam {
        _ = try self.expect(.l_paren, "expected function expression parameter list");
        var params: std.ArrayListUnmanaged(ast.FunctionExprParam) = .empty;
        errdefer {
            for (params.items) |param| param.deinit(self.allocator);
            params.deinit(self.allocator);
        }

        if (!self.check(.r_paren)) {
            while (true) {
                const name = try self.expect(.identifier, "expected function expression parameter name");
                const type_name = if (self.match(.colon))
                    try self.parseTypeName("expected function expression parameter type")
                else
                    null;
                try params.append(self.allocator, .{
                    .name = name.lexeme,
                    .type_name = type_name,
                    .name_token = name,
                });

                if (!self.match(.comma)) break;
            }
        }

        _ = try self.expect(.r_paren, "expected `)` after function expression parameters");
        return params.toOwnedSlice(self.allocator);
    }

    fn parseGenericParams(self: *Parser) ParseError![]ast.GenericParam {
        var params: std.ArrayListUnmanaged(ast.GenericParam) = .empty;
        errdefer {
            for (params.items) |param| param.deinit(self.allocator);
            params.deinit(self.allocator);
        }

        if (!self.match(.less)) {
            return self.allocator.alloc(ast.GenericParam, 0);
        }

        while (true) {
            if (self.match(.l_bracket)) {
                try self.diagnostic_context.emitToken(self.path, self.previous(), "fixed-array shape generic parameters are no longer supported; use `T, const N: usize`", .{});
                return ParseError.ParseFailed;
            }
            if (self.match(.keyword_const)) {
                const name = try self.expect(.identifier, "expected const generic parameter name");
                _ = try self.expect(.colon, "expected `:` after const generic parameter name");
                const value_type = try self.parseTypeName("expected const generic parameter type");
                try params.append(self.allocator, .{
                    .name = name.lexeme,
                    .constraint = value_type,
                    .name_token = name,
                    .is_const_value = true,
                });
                if (!self.match(.comma)) break;
                continue;
            }
            const name = try self.expect(.identifier, "expected generic parameter name");
            var extra_constraints: std.ArrayListUnmanaged(ast.TypeName) = .empty;
            errdefer {
                for (extra_constraints.items) |constraint| constraint.deinit(self.allocator);
                extra_constraints.deinit(self.allocator);
            }
            const constraint = if (self.match(.colon)) blk: {
                const first = try self.parseTypeName("expected generic constraint");
                while (self.match(.amp)) {
                    try extra_constraints.append(self.allocator, try self.parseTypeName("expected generic constraint after `&`"));
                }
                if (self.match(.plus)) {
                    try self.diagnostic_context.emitToken(self.path, self.previous(), "protocol constraints use `&`, not `+`", .{});
                    first.deinit(self.allocator);
                    return ParseError.ParseFailed;
                }
                break :blk first;
            } else null;
            try params.append(self.allocator, .{
                .name = name.lexeme,
                .constraint = constraint,
                .extra_constraints = try extra_constraints.toOwnedSlice(self.allocator),
                .name_token = name,
            });
            if (!self.match(.comma)) break;
        }

        _ = try self.expect(.greater, "expected `>` after generic parameters");
        return params.toOwnedSlice(self.allocator);
    }

    fn parseBlockBody(self: *Parser) ParseError![]ast.Stmt {
        var stmts: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        errdefer {
            for (stmts.items) |stmt| stmt.deinit(self.allocator);
            stmts.deinit(self.allocator);
        }

        while (!self.check(.r_brace) and !self.check(.eof)) {
            if (self.check(.keyword_var) and (self.peekAhead(1).tag == .l_brace or self.peekAhead(1).tag == .l_bracket or self.peekAhead(1).tag == .l_paren)) {
                try self.diagnostic_context.emitToken(self.path, self.peek(), "destructuring declarations require `const`", .{});
                return ParseError.ParseFailed;
            }
            if (self.check(.keyword_const) and (self.peekAhead(1).tag == .l_brace or self.peekAhead(1).tag == .l_bracket or self.peekAhead(1).tag == .l_paren)) {
                try self.parseDestructure(&stmts);
                continue;
            }
            const stmt = try self.parseStmt();
            errdefer stmt.deinit(self.allocator);
            try stmts.append(self.allocator, stmt);
        }

        _ = try self.expect(.r_brace, "expected `}` after function body");
        return stmts.toOwnedSlice(self.allocator);
    }

    const DestructureStep = union(enum) {
        field: lexer.Token,
        index: struct { position: usize, token: lexer.Token },
        tuple_index: struct { position: usize, token: lexer.Token },
    };

    const DestructureLeaf = struct {
        name: lexer.Token,
        steps: []DestructureStep,
    };

    fn parseDestructurePattern(
        self: *Parser,
        path_steps: *std.ArrayListUnmanaged(DestructureStep),
        leaves: *std.ArrayListUnmanaged(DestructureLeaf),
    ) ParseError!void {
        const is_struct = self.match(.l_brace);
        const is_tuple = !is_struct and self.match(.l_paren);
        const open = if (is_struct or is_tuple) self.previous() else try self.expect(.l_bracket, "expected destructuring pattern");
        const close: lexer.TokenTag = if (is_struct) .r_brace else if (is_tuple) .r_paren else .r_bracket;
        const starting_leaves = leaves.items.len;
        var fields_seen: std.ArrayListUnmanaged(lexer.Token) = .empty;
        defer fields_seen.deinit(self.allocator);
        var position: usize = 0;
        while (!self.check(close) and !self.check(.eof)) {
            var leaf: ?lexer.Token = null;
            if (is_struct) {
                const field = try self.expect(.identifier, "expected field name in struct pattern");
                for (fields_seen.items) |earlier| {
                    if (std.mem.eql(u8, earlier.lexeme, field.lexeme)) {
                        try self.diagnostic_context.emitToken(self.path, field, "duplicate field `{s}` in destructuring pattern", .{field.lexeme});
                        return ParseError.ParseFailed;
                    }
                }
                try fields_seen.append(self.allocator, field);
                try path_steps.append(self.allocator, .{ .field = field });
                if (self.match(.colon)) {
                    if (self.check(.l_brace) or self.check(.l_bracket) or self.check(.l_paren)) {
                        try self.parseDestructurePattern(path_steps, leaves);
                    } else {
                        leaf = try self.expect(.identifier, "expected binding name after `:`");
                    }
                } else {
                    leaf = field;
                }
            } else {
                try path_steps.append(self.allocator, if (is_tuple)
                    .{ .tuple_index = .{ .position = position, .token = open } }
                else
                    .{ .index = .{ .position = position, .token = open } });
                position += 1;
                if (self.check(.l_brace) or self.check(.l_bracket) or self.check(.l_paren)) {
                    try self.parseDestructurePattern(path_steps, leaves);
                } else {
                    leaf = try self.expect(.identifier, "expected binding name in indexed pattern");
                }
            }
            if (leaf) |name| {
                if (std.mem.eql(u8, name.lexeme, "_")) {
                    try self.diagnostic_context.emitToken(self.path, name, "destructuring leaf must declare a name", .{});
                    return ParseError.ParseFailed;
                }
                const steps = try self.allocator.dupe(DestructureStep, path_steps.items);
                errdefer self.allocator.free(steps);
                try leaves.append(self.allocator, .{
                    .name = name,
                    .steps = steps,
                });
            }
            _ = path_steps.pop();
            if (!self.match(.comma)) {
                if (is_tuple and position == 1) {
                    try self.diagnostic_context.emitToken(self.path, self.peek(), "one-element tuple pattern requires a trailing comma", .{});
                    return ParseError.ParseFailed;
                }
                break;
            }
            if (self.check(close)) break;
        }
        _ = try self.expect(close, if (is_struct) "expected `}` after struct pattern" else if (is_tuple) "expected `)` after tuple pattern" else "expected `]` after indexed pattern");
        if (leaves.items.len == starting_leaves) {
            try self.diagnostic_context.emitToken(self.path, open, "destructuring pattern must bind at least one name", .{});
            return ParseError.ParseFailed;
        }
    }

    fn parseDestructure(self: *Parser, stmts: *std.ArrayListUnmanaged(ast.Stmt)) ParseError!void {
        const declaration = try self.expect(.keyword_const, "expected `const` before destructuring pattern");
        var leaves: std.ArrayListUnmanaged(DestructureLeaf) = .empty;
        defer {
            for (leaves.items) |leaf| self.allocator.free(leaf.steps);
            leaves.deinit(self.allocator);
        }
        var path_steps: std.ArrayListUnmanaged(DestructureStep) = .empty;
        defer path_steps.deinit(self.allocator);
        try self.parseDestructurePattern(&path_steps, &leaves);
        const type_name: ?ast.TypeName = if (self.match(.colon))
            try self.parseTypeName("expected destructuring source type")
        else
            null;
        var init = try self.parseDestructureInit(type_name);
        errdefer init.deinit(self.allocator);
        const hidden_name = try std.fmt.allocPrint(self.allocator, "@destructure:{d}", .{declaration.offset});
        var hidden_attached = false;
        errdefer if (!hidden_attached) self.allocator.free(hidden_name);
        try stmts.append(self.allocator, .{ .local = .{
            .is_mutable = false,
            .name = hidden_name,
            .owns_name = true,
            .type_name = init.type_name,
            .init = init.expr.?,
            .name_token = declaration,
        } });
        hidden_attached = true;
        init.type_name = null;
        init.expr = null;
        for (leaves.items, 0..) |leaf, leaf_index| {
            var base_name: []const u8 = hidden_name;
            for (leaf.steps, 0..) |step, step_index| {
                const base = try self.allocator.create(ast.Expr);
                base.* = .{ .name = .{ .text = base_name, .token = declaration } };
                const expr = self.allocator.create(ast.Expr) catch |err| {
                    base.destroy(self.allocator);
                    return err;
                };
                switch (step) {
                    .field => |field| expr.* = .{ .field = .{ .object = base, .field = field.lexeme, .field_token = field } },
                    .index => |index| {
                        const index_expr = self.allocator.create(ast.Expr) catch |err| {
                            self.allocator.destroy(expr);
                            base.destroy(self.allocator);
                            return err;
                        };
                        index_expr.* = .{ .int = .{ .value = @intCast(index.position), .token = index.token } };
                        expr.* = .{ .index = .{ .object = base, .index = index_expr, .token = index.token } };
                    },
                    .tuple_index => |index| {
                        const field_name = std.fmt.allocPrint(self.allocator, "{d}", .{index.position}) catch |err| {
                            self.allocator.destroy(expr);
                            base.destroy(self.allocator);
                            return err;
                        };
                        var token = index.token;
                        token.tag = .int_lit;
                        token.lexeme = field_name;
                        expr.* = .{ .field = .{ .object = base, .field = field_name, .field_token = token, .owns_field = true } };
                    },
                }
                errdefer expr.destroy(self.allocator);
                const is_leaf = step_index + 1 == leaf.steps.len;
                const name = if (is_leaf) leaf.name.lexeme else try std.fmt.allocPrint(self.allocator, "@destructure:{d}:{d}:{d}", .{ declaration.offset, leaf_index, step_index });
                var name_attached = is_leaf;
                errdefer if (!name_attached) self.allocator.free(name);
                try stmts.append(self.allocator, .{ .local = .{
                    .is_mutable = false,
                    .name = name,
                    .owns_name = !is_leaf,
                    .type_name = null,
                    .init = expr,
                    .name_token = if (is_leaf) leaf.name else declaration,
                } });
                name_attached = true;
                base_name = name;
            }
        }
    }

    const DestructureInit = struct {
        type_name: ?ast.TypeName,
        expr: ?*ast.Expr,

        fn deinit(self: DestructureInit, allocator: std.mem.Allocator) void {
            if (self.type_name) |type_name| type_name.deinit(allocator);
            if (self.expr) |expr| expr.destroy(allocator);
        }
    };

    fn parseDestructureInit(self: *Parser, type_name: ?ast.TypeName) ParseError!DestructureInit {
        errdefer if (type_name) |ty| ty.deinit(self.allocator);
        _ = try self.expect(.equal, "expected `=` in destructuring declaration");
        const expr = try self.parseExpr();
        errdefer expr.destroy(self.allocator);
        _ = try self.expect(.semicolon, "expected `;` after destructuring declaration");
        return .{ .type_name = type_name, .expr = expr };
    }

    fn parseStmt(self: *Parser) ParseError!ast.Stmt {
        if (self.match(.keyword_unreachable)) {
            const token = self.previous();
            _ = try self.expect(.semicolon, "expected `;` after unreachable");
            const condition = try self.allocator.create(ast.Expr);
            errdefer self.allocator.destroy(condition);
            condition.* = .{ .bool = .{ .value = false, .token = token } };
            const args = try self.allocator.alloc(ast.CallArg, 1);
            errdefer self.allocator.free(args);
            args[0] = .{ .value = condition };
            const type_args = try self.allocator.alloc(ast.TypeName, 0);
            errdefer self.allocator.free(type_args);
            const call = try self.allocator.create(ast.Expr);
            call.* = .{ .call = .{ .owner = null, .callee = "assert", .callee_token = token, .type_args = type_args, .args = args } };
            return .{ .expr = call };
        }
        if (self.match(.keyword_const)) return self.parseLocal(false);
        if (self.match(.keyword_var)) return self.parseLocal(true);
        if (self.match(.keyword_if)) return self.parseIf();
        if (self.match(.keyword_while)) return self.parseWhile();
        if (self.match(.keyword_for)) return self.parseFor();
        if (self.match(.keyword_continue)) {
            const token = self.previous();
            _ = try self.expect(.semicolon, "expected `;` after continue");
            return .{ .@"continue" = token };
        }
        if (self.match(.keyword_break)) {
            const token = self.previous();
            _ = try self.expect(.semicolon, "expected `;` after break");
            return .{ .@"break" = token };
        }
        if (self.match(.keyword_switch)) return .{ .@"switch" = try self.parseSwitch() };
        if (self.match(.keyword_using)) return self.parseUsingAlloc();
        if (self.match(.keyword_unchecked)) return self.parseUnchecked();
        if (self.match(.keyword_asm)) return self.parseAsmStmt();

        if (self.match(.keyword_try)) {
            const expr = try self.parseExpr();
            _ = try self.expect(.semicolon, "expected `;` after try");
            return .{ .@"try" = expr };
        }

        if (self.match(.keyword_defer)) {
            const expr = try self.parseExpr();
            _ = try self.expect(.semicolon, "expected `;` after defer");
            return .{ .@"defer" = expr };
        }

        if (self.match(.keyword_drop)) {
            const name = try self.expect(.identifier, "expected local name after drop");
            _ = try self.expect(.semicolon, "expected `;` after drop");
            return .{ .drop = .{ .name = name.lexeme, .name_token = name } };
        }

        if (self.matchIdent("throw")) {
            const token = self.previous();
            const code = try self.parseExpr();
            errdefer code.destroy(self.allocator);
            var message: ?ast.StringLiteral = null;
            errdefer if (message) |literal| if (literal.owns_text) self.allocator.free(literal.text);
            if (self.match(.comma)) {
                const message_token = try self.expect(.string_lit, "expected string literal after `throw` code and comma");
                const decoded = try self.parseStringLiteral(message_token);
                message = .{ .text = decoded.text, .token = message_token, .owns_text = decoded.owns_text };
            }
            _ = try self.expect(.semicolon, "expected `;` after throw");
            const result = try self.allocator.create(ast.Expr);
            result.* = .{ .union_case = .{ .case_name = "err", .value = code, .token = token, .is_synthetic_throw = true, .throw_message = message } };
            return .{ .@"return" = .{ .token = token, .value = result, .is_throw = true } };
        }

        if (self.match(.keyword_return)) {
            const token = self.previous();
            if (self.match(.semicolon)) {
                return .{ .@"return" = .{ .token = token, .value = null } };
            }
            const expr = try self.parseExpr();
            _ = try self.expect(.semicolon, "expected `;` after return");
            return .{ .@"return" = .{ .token = token, .value = expr } };
        }

        if (self.match(.keyword_yield)) {
            const token = self.previous();
            if (self.match(.semicolon)) return .{ .yield = .{ .token = token, .value = null } };
            const expr = try self.parseExpr();
            errdefer expr.destroy(self.allocator);
            _ = try self.expect(.semicolon, "expected `;` after yield");
            return .{ .yield = .{ .token = token, .value = expr } };
        }

        const expr = try self.parseExpr();
        if (self.match(.equal)) {
            const value = try self.parseExpr();
            const capture: ?ast.AssignmentCapture = if (self.match(.at)) blk: {
                const is_mutable = if (self.match(.keyword_const)) false else if (self.match(.keyword_var)) true else {
                    try self.diagnostic_context.emitToken(self.path, self.peek(), "expected `const` or `var` after assignment capture `@`", .{});
                    return ParseError.ParseFailed;
                };
                const name = try self.expect(.identifier, "expected binding name after assignment capture");
                break :blk .{ .name = name.lexeme, .name_token = name, .is_mutable = is_mutable };
            } else null;
            _ = try self.expect(.semicolon, "expected `;` after assignment");
            if (capture != null and expr.* != .field) {
                try self.diagnostic_context.emitToken(self.path, capture.?.name_token, "assignment capture currently requires a struct field target", .{});
                expr.destroy(self.allocator);
                value.destroy(self.allocator);
                return ParseError.ParseFailed;
            }
            switch (expr.*) {
                .name => |name| {
                    self.allocator.destroy(expr);
                    return .{ .assign = .{ .name = name.text, .value = value, .name_token = name.token } };
                },
                .index => |index| {
                    const object = index.object;
                    const index_expr = index.index;
                    const token = index.token;
                    self.allocator.destroy(expr);
                    return .{ .index_assign = .{
                        .object = object,
                        .index = index_expr,
                        .value = value,
                        .token = token,
                    } };
                },
                .deref => |deref| {
                    const pointer = deref.expr;
                    const token = deref.token;
                    self.allocator.destroy(expr);
                    return .{ .deref_assign = .{
                        .pointer = pointer,
                        .value = value,
                        .token = token,
                    } };
                },
                .field => {
                    if (try self.lowerFieldAssignTarget(expr, value, capture)) |stmt| return stmt;
                    try self.diagnostic_context.emitToken(self.path, ast.firstExprToken(expr), "invalid assignment target", .{});
                    expr.destroy(self.allocator);
                    value.destroy(self.allocator);
                    return ParseError.ParseFailed;
                },
                else => {
                    try self.diagnostic_context.emitToken(self.path, ast.firstExprToken(expr), "invalid assignment target", .{});
                    expr.destroy(self.allocator);
                    value.destroy(self.allocator);
                    return ParseError.ParseFailed;
                },
            }
        }
        _ = try self.expect(.semicolon, "expected `;` after expression statement");
        return .{ .expr = expr };
    }

    fn parseLocal(self: *Parser, is_mutable: bool) ParseError!ast.Stmt {
        const name = try self.expect(.identifier, "expected local name");
        if (is_mutable and std.mem.eql(u8, name.lexeme, "_")) {
            try self.diagnostic_context.emitToken(self.path, name, "discard binding must use `const _`", .{});
            return ParseError.ParseFailed;
        }
        const type_name: ?ast.TypeName = if (self.match(.colon))
            try self.parseTypeName("expected local type")
        else
            null;
        errdefer if (type_name) |ty| ty.deinit(self.allocator);
        if (!is_mutable and std.mem.eql(u8, name.lexeme, "_") and type_name != null) {
            try self.diagnostic_context.emitToken(self.path, name, "discard binding cannot have a type annotation", .{});
            return ParseError.ParseFailed;
        }
        _ = try self.expect(.equal, "expected `=` in local declaration");
        const init = try self.parseExpr();
        _ = try self.expect(.semicolon, "expected `;` after local declaration");

        if (!is_mutable and std.mem.eql(u8, name.lexeme, "_")) {
            return .{ .discard = init };
        }

        return .{ .local = .{
            .is_mutable = is_mutable,
            .name = name.lexeme,
            .type_name = type_name,
            .init = init,
            .name_token = name,
        } };
    }

    fn lowerFieldAssignTarget(self: *Parser, expr: *ast.Expr, value: *ast.Expr, capture: ?ast.AssignmentCapture) ParseError!?ast.Stmt {
        var reversed: std.ArrayListUnmanaged(ast.DerefFieldAssignStep) = .empty;
        defer reversed.deinit(self.allocator);
        var field_nodes: std.ArrayListUnmanaged(*ast.Expr) = .empty;
        defer field_nodes.deinit(self.allocator);

        var cursor = expr;
        while (true) {
            switch (cursor.*) {
                .field => |field| {
                    try field_nodes.append(self.allocator, cursor);
                    try reversed.append(self.allocator, .{
                        .field = field.field,
                        .field_token = field.field_token,
                    });
                    cursor = field.object;
                },
                .name => {
                    const fields = try self.allocator.alloc(ast.DerefFieldAssignStep, reversed.items.len);
                    errdefer self.allocator.free(fields);
                    for (0..reversed.items.len) |i| {
                        fields[i] = reversed.items[reversed.items.len - 1 - i];
                    }
                    const token = ast.firstExprToken(expr);
                    for (field_nodes.items) |node| self.allocator.destroy(node);
                    return .{ .field_assign = .{
                        .object = cursor,
                        .fields = fields,
                        .value = value,
                        .token = token,
                        .capture = capture,
                    } };
                },
                .deref => |deref| {
                    if (capture != null) {
                        try self.diagnostic_context.emitToken(self.path, capture.?.name_token, "assignment capture currently requires a named struct field root", .{});
                        expr.destroy(self.allocator);
                        value.destroy(self.allocator);
                        return ParseError.ParseFailed;
                    }
                    const fields = try self.allocator.alloc(ast.DerefFieldAssignStep, reversed.items.len);
                    errdefer self.allocator.free(fields);
                    for (0..reversed.items.len) |i| {
                        fields[i] = reversed.items[reversed.items.len - 1 - i];
                    }
                    const pointer = deref.expr;
                    const token = deref.token;
                    self.allocator.destroy(cursor);
                    for (field_nodes.items) |node| self.allocator.destroy(node);
                    return .{ .deref_field_assign = .{
                        .pointer = pointer,
                        .fields = fields,
                        .value = value,
                        .token = token,
                    } };
                },
                else => return null,
            }
        }
    }

    fn parseUnchecked(self: *Parser) ParseError!ast.Stmt {
        _ = try self.expect(.l_brace, "expected `{` after unchecked");
        self.unchecked_depth += 1;
        defer self.unchecked_depth -= 1;
        return .{ .unchecked = try self.parseBlockBody() };
    }

    fn parseAsmStmt(self: *Parser) ParseError!ast.Stmt {
        const token = self.previous();
        if (self.unchecked_depth == 0) {
            try self.diagnostic_context.emitToken(self.path, token, "inline assembly requires `unchecked`", .{});
            return ParseError.ParseFailed;
        }

        const is_volatile = self.matchIdent("volatile");
        _ = try self.expect(.l_brace, "expected `{` after asm");

        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        var inputs: std.ArrayListUnmanaged(ast.AsmInput) = .empty;
        var clobbers: std.ArrayListUnmanaged(ast.AsmClobber) = .empty;
        errdefer {
            lines.deinit(self.allocator);
            for (inputs.items) |input| input.deinit(self.allocator);
            inputs.deinit(self.allocator);
            clobbers.deinit(self.allocator);
        }

        while (!self.check(.r_brace) and !self.check(.eof)) {
            if (self.match(.string_lit)) {
                const line = self.previous();
                try lines.append(self.allocator, line.lexeme[1 .. line.lexeme.len - 1]);
                _ = try self.expect(.semicolon, "expected `;` after assembly template string");
                continue;
            }
            if (self.match(.keyword_in)) {
                const constraint = if (self.matchIdent("tied")) blk: {
                    _ = self.matchIdent("reg");
                    break :blk ast.AsmConstraint.tied_reg;
                } else if (self.matchIdent("reg")) ast.AsmConstraint.reg else ast.AsmConstraint.reg;
                const name = try self.expect(.identifier, "expected asm input name");
                _ = try self.expect(.equal, "expected `=` after asm input name");
                const value = try self.parseExpr();
                try inputs.append(self.allocator, .{
                    .name = name.lexeme,
                    .constraint = constraint,
                    .value = value,
                    .name_token = name,
                });
                _ = try self.expect(.semicolon, "expected `;` after asm input");
                continue;
            }
            if (self.matchIdent("clobber")) {
                const name = if (self.match(.identifier) or self.match(.keyword_flags))
                    self.previous()
                else
                    try self.expect(.identifier, "expected clobber name");
                const clobber = if (std.mem.eql(u8, name.lexeme, "memory"))
                    ast.AsmClobber.memory
                else if (std.mem.eql(u8, name.lexeme, "flags"))
                    ast.AsmClobber.flags
                else
                    ast.AsmClobber{ .register = try self.allocator.dupe(u8, name.lexeme) };
                try clobbers.append(self.allocator, clobber);
                _ = try self.expect(.semicolon, "expected `;` after asm clobber");
                continue;
            }
            try self.diagnostic_context.emitToken(self.path, self.peek(), "expected asm template string, `in` operand, or `clobber`", .{});
            return ParseError.ParseFailed;
        }

        _ = try self.expect(.r_brace, "expected `}` after asm block");
        if (lines.items.len == 0) {
            try self.diagnostic_context.emitToken(self.path, token, "asm block requires at least one template string", .{});
            return ParseError.ParseFailed;
        }

        return .{ .asm_stmt = .{
            .lines = try lines.toOwnedSlice(self.allocator),
            .inputs = try inputs.toOwnedSlice(self.allocator),
            .clobbers = try clobbers.toOwnedSlice(self.allocator),
            .is_volatile = is_volatile,
            .token = token,
        } };
    }

    fn parseAsmExpr(self: *Parser, token: lexer.Token) ParseError!*ast.Expr {
        if (self.unchecked_depth == 0) {
            try self.diagnostic_context.emitToken(self.path, token, "inline assembly requires `unchecked`", .{});
            return ParseError.ParseFailed;
        }

        _ = try self.expect(.l_paren, "expected `(` after asm");
        const result_type = try self.parseTypeName("expected asm result type");
        errdefer result_type.deinit(self.allocator);
        _ = try self.expect(.r_paren, "expected `)` after asm result type");
        const is_volatile = self.matchIdent("volatile");
        _ = try self.expect(.l_brace, "expected `{` after asm result type");

        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        var output: ?ast.AsmOutput = null;
        var inout: ?ast.AsmInput = null;
        var inputs: std.ArrayListUnmanaged(ast.AsmInput) = .empty;
        var clobbers: std.ArrayListUnmanaged(ast.AsmClobber) = .empty;
        errdefer {
            lines.deinit(self.allocator);
            if (inout) |operand| operand.deinit(self.allocator);
            for (inputs.items) |input| input.deinit(self.allocator);
            inputs.deinit(self.allocator);
            clobbers.deinit(self.allocator);
        }

        while (!self.check(.r_brace) and !self.check(.eof)) {
            if (self.match(.string_lit)) {
                const line = self.previous();
                try lines.append(self.allocator, line.lexeme[1 .. line.lexeme.len - 1]);
                _ = try self.expect(.semicolon, "expected `;` after assembly template string");
                continue;
            }
            if (self.match(.keyword_in)) {
                const constraint = if (self.matchIdent("tied")) blk: {
                    _ = self.matchIdent("reg");
                    break :blk ast.AsmConstraint.tied_reg;
                } else if (self.matchIdent("reg")) ast.AsmConstraint.reg else ast.AsmConstraint.reg;
                const name = try self.expect(.identifier, "expected asm input name");
                _ = try self.expect(.equal, "expected `=` after asm input name");
                const value = try self.parseExpr();
                try inputs.append(self.allocator, .{
                    .name = name.lexeme,
                    .constraint = constraint,
                    .value = value,
                    .name_token = name,
                });
                _ = try self.expect(.semicolon, "expected `;` after asm input");
                continue;
            }
            if (self.matchIdent("inout")) {
                if (inout != null) {
                    try self.diagnostic_context.emitToken(self.path, self.previous(), "asm expression supports only one inout operand", .{});
                    return ParseError.ParseFailed;
                }
                if (output != null) {
                    try self.diagnostic_context.emitToken(self.path, self.previous(), "asm expression cannot combine `out` and `inout` operands", .{});
                    return ParseError.ParseFailed;
                }
                const constraint = if (self.matchIdent("reg")) ast.AsmConstraint.reg else ast.AsmConstraint.reg;
                const name = try self.expect(.identifier, "expected asm inout name");
                _ = try self.expect(.equal, "expected `=` after asm inout name");
                const value = try self.parseExpr();
                inout = .{
                    .name = name.lexeme,
                    .constraint = constraint,
                    .value = value,
                    .name_token = name,
                };
                _ = try self.expect(.semicolon, "expected `;` after asm inout");
                continue;
            }
            if (self.matchIdent("out")) {
                if (output != null) {
                    try self.diagnostic_context.emitToken(self.path, self.previous(), "asm expression supports only one output operand", .{});
                    return ParseError.ParseFailed;
                }
                if (inout != null) {
                    try self.diagnostic_context.emitToken(self.path, self.previous(), "asm expression cannot combine `out` and `inout` operands", .{});
                    return ParseError.ParseFailed;
                }
                const constraint = if (self.matchIdent("reg")) ast.AsmConstraint.reg else ast.AsmConstraint.reg;
                const name = try self.expect(.identifier, "expected asm output name");
                output = .{
                    .name = name.lexeme,
                    .constraint = constraint,
                    .name_token = name,
                };
                _ = try self.expect(.semicolon, "expected `;` after asm output");
                continue;
            }
            if (self.matchIdent("clobber")) {
                const name = if (self.match(.identifier) or self.match(.keyword_flags))
                    self.previous()
                else
                    try self.expect(.identifier, "expected clobber name");
                const clobber = if (std.mem.eql(u8, name.lexeme, "memory"))
                    ast.AsmClobber.memory
                else if (std.mem.eql(u8, name.lexeme, "flags"))
                    ast.AsmClobber.flags
                else
                    ast.AsmClobber{ .register = try self.allocator.dupe(u8, name.lexeme) };
                try clobbers.append(self.allocator, clobber);
                _ = try self.expect(.semicolon, "expected `;` after asm clobber");
                continue;
            }
            try self.diagnostic_context.emitToken(self.path, self.peek(), "expected asm template string, `in` operand, `inout` operand, `out` operand, or `clobber`", .{});
            return ParseError.ParseFailed;
        }

        _ = try self.expect(.r_brace, "expected `}` after asm block");
        if (lines.items.len == 0) {
            try self.diagnostic_context.emitToken(self.path, token, "asm block requires at least one template string", .{});
            return ParseError.ParseFailed;
        }

        const expr = try self.allocator.create(ast.Expr);
        expr.* = .{ .asm_expr = .{
            .result_type = result_type,
            .lines = try lines.toOwnedSlice(self.allocator),
            .output = output,
            .inout = inout,
            .inputs = try inputs.toOwnedSlice(self.allocator),
            .clobbers = try clobbers.toOwnedSlice(self.allocator),
            .is_volatile = is_volatile,
            .token = token,
        } };
        return expr;
    }

    fn parseUsingAlloc(self: *Parser) ParseError!ast.Stmt {
        const using_token = self.previous();
        const is_scoped = self.match(.keyword_scoped);
        _ = try self.expect(.keyword_alloc, "expected `alloc` after using");
        _ = try self.expect(.equal, "expected `=` after allocator binding");
        const allocator_expr = try self.parseExpr();
        _ = try self.expect(.l_brace, "expected `{` after allocator context");
        return .{ .using_alloc = .{
            .is_scoped = is_scoped,
            .allocator_expr = allocator_expr,
            .body = try self.parseBlockBody(),
            .token = using_token,
        } };
    }

    /// `T!E` is the public return-position spelling of the internal result carrier.
    fn parseReturnTypeName(self: *Parser, message: []const u8) ParseError!ast.TypeName {
        var success = try self.parseTypeName(message);
        if (!self.match(.bang)) return success;
        errdefer success.deinit(self.allocator);
        const bang = self.previous();
        if (self.check(.l_brace)) {
            success.is_inferred_result_return = true;
            return success;
        }
        if (!self.check(.identifier)) {
            try self.diagnostic_context.emitToken(self.path, bang, "expected error type after `!`; inferred `T!` returns require a body", .{});
            return ParseError.ParseFailed;
        }
        var err_type = try self.parseTypeName("expected error type after `!`");
        var err_type_owned = true;
        errdefer if (err_type_owned) err_type.deinit(self.allocator);
        if (self.match(.pipe)) {
            var members: std.ArrayListUnmanaged(ast.TypeName) = .empty;
            errdefer {
                for (members.items) |member| member.deinit(self.allocator);
                members.deinit(self.allocator);
            }
            try members.append(self.allocator, err_type);
            err_type_owned = false;
            while (true) {
                const member = try self.parseTypeName("expected error enum after `|`");
                members.append(self.allocator, member) catch |err| {
                    member.deinit(self.allocator);
                    return err;
                };
                if (!self.match(.pipe)) break;
            }
            const first_token = members.items[0].token;
            err_type = .{ .is_inline_error_union = true, .name = "|", .args = try members.toOwnedSlice(self.allocator), .token = first_token };
            err_type_owned = true;
        }
        const args = try self.allocator.alloc(ast.TypeName, 2);
        args[0] = success;
        args[1] = err_type;
        return .{ .name = "result", .args = args, .token = success.token };
    }

    fn parseTypeName(self: *Parser, message: []const u8) ParseError!ast.TypeName {
        if (self.check(.l_paren) and self.arrowCallableTypeAhead()) {
            return self.parseArrowCallableTypeName();
        }

        const is_ref = self.match(.amp);
        const ref_is_const = if (is_ref) self.match(.keyword_const) else false;
        const is_optional = self.match(.question);
        const is_owned = self.match(.caret);
        const is_double_raw = self.match(.star_star);
        const is_raw = self.match(.star);
        var raw_is_const = false;
        var is_volatile_raw = false;
        if (is_raw or is_double_raw) {
            while (true) {
                if (!raw_is_const and self.match(.keyword_const)) {
                    raw_is_const = true;
                } else if (!is_volatile_raw and self.matchIdent("volatile")) {
                    is_volatile_raw = true;
                } else break;
            }
        }
        if (@intFromBool(is_ref) + @intFromBool(is_owned) + @intFromBool(is_raw or is_double_raw) > 1) {
            try self.diagnostic_context.emitToken(self.path, self.previous(), "types cannot combine `&`, `^`, and `*`", .{});
            return ParseError.ParseFailed;
        }
        if (is_double_raw) {
            const pointee = try self.allocator.create(ast.TypeName);
            errdefer self.allocator.destroy(pointee);
            pointee.* = try self.parseTypeName(message);
            const inner = try self.allocator.create(ast.TypeName);
            errdefer self.allocator.destroy(inner);
            inner.* = .{
                .is_raw = true,
                .raw_is_const = raw_is_const,
                .is_volatile_raw = is_volatile_raw,
                .raw_target = pointee,
                .name = pointee.name,
                .args = &.{},
                .token = pointee.token,
            };
            return .{
                .is_raw = true,
                .is_optional = is_optional,
                .raw_target = inner,
                .name = pointee.name,
                .args = &.{},
                .token = pointee.token,
            };
        }
        if (is_raw and self.check(.star)) {
            const target = try self.allocator.create(ast.TypeName);
            errdefer self.allocator.destroy(target);
            target.* = try self.parseTypeName(message);
            return .{
                .is_raw = true,
                .raw_is_const = raw_is_const,
                .is_volatile_raw = is_volatile_raw,
                .is_optional = is_optional,
                .raw_target = target,
                .name = target.name,
                .args = &.{},
                .token = target.token,
            };
        }
        var is_slice = false;
        var slice_is_const = false;
        var array_len_name: ?[]const u8 = null;
        var array_len_token: ?lexer.Token = null;
        const array_len: ?usize = if (self.match(.l_bracket)) blk: {
            if (self.match(.r_bracket)) {
                is_slice = true;
                break :blk null;
            }
            if (self.match(.colon)) {
                _ = try self.expect(.r_bracket, "expected `]` after `:` in runtime array type");
                const item_type = try self.parseTypeName(message);
                errdefer item_type.deinit(self.allocator);
                const args = try self.allocator.alloc(ast.TypeName, 1);
                args[0] = item_type;
                return .{
                    .is_ref = is_ref,
                    .ref_is_const = ref_is_const,
                    .is_owned = is_owned,
                    .is_raw = is_raw,
                    .raw_is_const = raw_is_const,
                    .is_volatile_raw = is_volatile_raw,
                    .is_optional = is_optional,
                    .is_function = false,
                    .is_arrow_callable = false,
                    .is_slice = false,
                    .array_len = null,
                    .name = "[:]",
                    .args = args,
                    .token = item_type.token,
                };
            }
            if (self.match(.semicolon)) {
                _ = try self.expect(.r_bracket, "expected `]` after `;` in sparse storage type");
                const item_type = try self.parseTypeName(message);
                errdefer item_type.deinit(self.allocator);
                const args = try self.allocator.alloc(ast.TypeName, 1);
                args[0] = item_type;
                return .{
                    .is_ref = is_ref,
                    .ref_is_const = ref_is_const,
                    .is_owned = is_owned,
                    .is_raw = is_raw,
                    .raw_is_const = raw_is_const,
                    .is_volatile_raw = is_volatile_raw,
                    .is_optional = is_optional,
                    .is_function = false,
                    .is_arrow_callable = false,
                    .is_slice = false,
                    .array_len = null,
                    .name = "[;]",
                    .args = args,
                    .token = item_type.token,
                };
            }
            if (self.match(.identifier)) {
                array_len_token = self.previous();
                array_len_name = array_len_token.?.lexeme;
                _ = try self.expect(.r_bracket, "expected `]` after fixed array length");
                break :blk null;
            }
            const len_token = try self.expect(.int_lit, "expected fixed array length");
            _ = try self.expect(.r_bracket, "expected `]` after fixed array length");
            break :blk std.fmt.parseInt(usize, len_token.lexeme, 10) catch {
                try self.diagnostic_context.emitToken(self.path, len_token, "invalid fixed array length `{s}`", .{len_token.lexeme});
                return ParseError.ParseFailed;
            };
        } else null;
        if (is_slice) {
            slice_is_const = self.match(.keyword_const);
            const item_type = try self.parseTypeName(message);
            return .{
                .is_ref = is_ref or item_type.is_ref,
                .ref_is_const = ref_is_const or item_type.ref_is_const,
                .is_owned = is_owned or item_type.is_owned,
                .is_raw = is_raw or item_type.is_raw,
                .raw_is_const = raw_is_const or item_type.raw_is_const,
                .is_volatile_raw = is_volatile_raw or item_type.is_volatile_raw,
                .raw_target = item_type.raw_target,
                .is_optional = is_optional or item_type.is_optional,
                .is_function = item_type.is_function,
                .is_arrow_callable = item_type.is_arrow_callable,
                .is_slice = true,
                .slice_flags = .{ .is_const = slice_is_const, .item_is_optional = item_type.is_optional },
                .array_len = item_type.array_len,
                .array_len_name = item_type.array_len_name,
                .array_len_token = item_type.array_len_token,
                .module_name = item_type.module_name,
                .owns_module_name = item_type.owns_module_name,
                .name = item_type.name,
                .args = item_type.args,
                .function_calling_convention = item_type.function_calling_convention,
                .function_params = item_type.function_params,
                .function_return_type = item_type.function_return_type,
                .token = item_type.token,
            };
        }
        if (self.check(.keyword_fn) or
            (self.check(.identifier) and std.mem.eql(u8, self.peek().lexeme, "c") and self.peekAhead(1).tag == .keyword_fn))
        {
            return self.parseFunctionTypeName(is_ref, ref_is_const, is_optional, is_owned, is_raw, raw_is_const, is_volatile_raw);
        }
        if (self.match(.l_paren)) {
            const open = self.previous();
            var members: std.ArrayListUnmanaged(ast.TypeName) = .empty;
            errdefer {
                for (members.items) |member| member.deinit(self.allocator);
                members.deinit(self.allocator);
            }
            if (!self.check(.r_paren)) {
                while (true) {
                    const member = try self.parseTypeName("expected tuple element type");
                    members.append(self.allocator, member) catch |err| {
                        member.deinit(self.allocator);
                        return err;
                    };
                    if (!self.match(.comma)) {
                        if (members.items.len == 1) {
                            _ = try self.expect(.r_paren, "expected `)` after parenthesized type");
                            var grouped = members.items[0];
                            members.deinit(self.allocator);
                            if ((is_ref or is_owned or is_raw) and (grouped.is_ref or grouped.is_owned or grouped.is_raw) or
                                (is_slice and grouped.is_slice) or (array_len != null and grouped.array_len != null))
                            {
                                try self.diagnostic_context.emitToken(self.path, open, "conflicting modifiers on parenthesized type", .{});
                                grouped.deinit(self.allocator);
                                return ParseError.ParseFailed;
                            }
                            grouped.is_ref = grouped.is_ref or is_ref;
                            grouped.ref_is_const = grouped.ref_is_const or ref_is_const;
                            grouped.is_owned = grouped.is_owned or is_owned;
                            grouped.is_raw = grouped.is_raw or is_raw;
                            grouped.raw_is_const = grouped.raw_is_const or raw_is_const;
                            grouped.is_volatile_raw = grouped.is_volatile_raw or is_volatile_raw;
                            grouped.is_optional = grouped.is_optional or is_optional;
                            grouped.is_slice = grouped.is_slice or is_slice;
                            grouped.slice_flags.is_const = grouped.slice_flags.is_const or slice_is_const;
                            if (array_len != null or array_len_name != null) {
                                grouped.array_len = array_len;
                                grouped.array_len_name = array_len_name;
                                grouped.array_len_token = array_len_token;
                            }
                            return grouped;
                        }
                        break;
                    }
                    if (self.check(.r_paren)) break;
                }
            }
            _ = try self.expect(.r_paren, "expected `)` after tuple type");
            return .{
                .is_ref = is_ref,
                .ref_is_const = ref_is_const,
                .is_optional = is_optional,
                .is_owned = is_owned,
                .is_raw = is_raw,
                .raw_is_const = raw_is_const,
                .is_volatile_raw = is_volatile_raw,
                .is_slice = is_slice,
                .slice_flags = .{ .is_const = slice_is_const },
                .array_len = array_len,
                .array_len_name = array_len_name,
                .array_len_token = array_len_token,
                .name = "()",
                .args = try members.toOwnedSlice(self.allocator),
                .token = open,
            };
        }
        var token = try self.expect(.identifier, message);
        var path_segments: std.ArrayListUnmanaged([]const u8) = .empty;
        defer path_segments.deinit(self.allocator);
        try path_segments.append(self.allocator, token.lexeme);
        while (self.match(.dot)) {
            token = try self.expect(.identifier, "expected type name after type qualifier");
            try path_segments.append(self.allocator, token.lexeme);
        }
        const module_name: ?[]const u8 = if (path_segments.items.len > 1) blk: {
            if (path_segments.items.len == 2) break :blk path_segments.items[0];
            var joined: std.ArrayListUnmanaged(u8) = .empty;
            errdefer joined.deinit(self.allocator);
            for (path_segments.items[0 .. path_segments.items.len - 1], 0..) |segment, i| {
                if (i != 0) try joined.append(self.allocator, '.');
                try joined.appendSlice(self.allocator, segment);
            }
            break :blk try joined.toOwnedSlice(self.allocator);
        } else null;
        const owns_module_name = path_segments.items.len > 2;
        var args: std.ArrayListUnmanaged(ast.TypeName) = .empty;
        errdefer {
            if (owns_module_name) self.allocator.free(module_name.?);
            for (args.items) |arg| arg.deinit(self.allocator);
            args.deinit(self.allocator);
        }
        if (self.match(.less)) {
            if (std.mem.eql(u8, token.lexeme, "result") and module_name == null) {
                try self.diagnostic_context.emitToken(self.path, token, "explicit `result<T, E>` is unavailable; use `T!E` in a return type", .{});
                return ParseError.ParseFailed;
            }
            if (!typeAcceptsArgs(token.lexeme)) {
                try self.diagnostic_context.emitToken(self.path, token, "only generic struct names accept type arguments; use `[:]T` for owned runtime arrays", .{});
                return ParseError.ParseFailed;
            }
            while (true) {
                var arg = try self.parseGenericArgument();
                if (std.mem.eql(u8, token.lexeme, "result") and args.items.len == 1 and self.match(.pipe)) {
                    var members: std.ArrayListUnmanaged(ast.TypeName) = .empty;
                    errdefer {
                        for (members.items) |member| member.deinit(self.allocator);
                        members.deinit(self.allocator);
                    }
                    members.append(self.allocator, arg) catch |err| {
                        arg.deinit(self.allocator);
                        return err;
                    };
                    while (true) {
                        const member = try self.parseTypeName("expected error enum after `|`");
                        members.append(self.allocator, member) catch |err| {
                            member.deinit(self.allocator);
                            return err;
                        };
                        if (!self.match(.pipe)) break;
                    }
                    arg = .{
                        .is_inline_error_union = true,
                        .name = "|",
                        .args = try members.toOwnedSlice(self.allocator),
                        .token = arg.token,
                    };
                }
                args.append(self.allocator, arg) catch |err| {
                    arg.deinit(self.allocator);
                    return err;
                };
                if (!self.match(.comma)) break;
            }
            _ = try self.expect(.greater, "expected `>` after type arguments");
        }
        return .{
            .is_ref = is_ref,
            .ref_is_const = ref_is_const,
            .is_owned = is_owned,
            .is_raw = is_raw,
            .raw_is_const = raw_is_const,
            .is_volatile_raw = is_volatile_raw,
            .is_optional = is_optional,
            .is_function = false,
            .is_arrow_callable = false,
            .is_slice = is_slice,
            .slice_flags = .{},
            .array_len = array_len,
            .array_len_name = array_len_name,
            .array_len_token = array_len_token,
            .module_name = module_name,
            .owns_module_name = owns_module_name,
            .name = token.lexeme,
            .args = try args.toOwnedSlice(self.allocator),
            .token = token,
        };
    }

    fn parseFunctionTypeName(
        self: *Parser,
        is_ref: bool,
        ref_is_const: bool,
        is_optional: bool,
        is_owned: bool,
        is_raw: bool,
        raw_is_const: bool,
        is_volatile_raw: bool,
    ) ParseError!ast.TypeName {
        const calling_convention: ast.CallingConvention = if (self.check(.identifier) and std.mem.eql(u8, self.peek().lexeme, "c")) blk: {
            _ = self.advance();
            break :blk .c;
        } else .cyna;
        const token = try self.expect(.keyword_fn, "expected `fn` in function type");
        _ = try self.expect(.l_paren, "expected `(` after `fn` in function type");

        var params: std.ArrayListUnmanaged(ast.TypeName) = .empty;
        errdefer {
            for (params.items) |param| param.deinit(self.allocator);
            params.deinit(self.allocator);
        }

        if (!self.check(.r_paren)) {
            while (true) {
                if (self.check(.identifier) and self.peekAhead(1).tag == .colon) {
                    _ = self.advance();
                    _ = self.advance();
                }
                const param_type = try self.parseTypeName("expected function parameter type");
                params.append(self.allocator, param_type) catch |err| {
                    param_type.deinit(self.allocator);
                    return err;
                };
                if (!self.match(.comma)) break;
            }
        }

        _ = try self.expect(.r_paren, "expected `)` after function type parameters");

        const return_type = if (self.match(.colon)) blk: {
            const value = try self.allocator.create(ast.TypeName);
            errdefer self.allocator.destroy(value);
            value.* = try self.parseReturnTypeName("expected function return type");
            break :blk value;
        } else null;

        return .{
            .is_ref = is_ref,
            .ref_is_const = ref_is_const,
            .is_owned = is_owned,
            .is_raw = is_raw,
            .raw_is_const = raw_is_const,
            .is_volatile_raw = is_volatile_raw,
            .is_optional = is_optional,
            .is_function = true,
            .is_arrow_callable = false,
            .is_slice = false,
            .slice_flags = .{},
            .array_len = null,
            .name = "fn",
            .args = try self.allocator.alloc(ast.TypeName, 0),
            .function_calling_convention = calling_convention,
            .function_params = try params.toOwnedSlice(self.allocator),
            .function_return_type = return_type,
            .token = token,
        };
    }

    fn parseArrowCallableTypeName(self: *Parser) ParseError!ast.TypeName {
        const token = try self.expect(.l_paren, "expected `(` before non-escaping callable parameters");

        var params: std.ArrayListUnmanaged(ast.TypeName) = .empty;
        errdefer {
            for (params.items) |param| param.deinit(self.allocator);
            params.deinit(self.allocator);
        }

        if (!self.check(.r_paren)) {
            while (true) {
                if (self.check(.identifier) and self.peekAhead(1).tag == .colon) {
                    _ = self.advance();
                    _ = self.advance();
                }
                const param_type = try self.parseTypeName("expected non-escaping callable parameter type");
                params.append(self.allocator, param_type) catch |err| {
                    param_type.deinit(self.allocator);
                    return err;
                };
                if (!self.match(.comma)) break;
            }
        }

        _ = try self.expect(.r_paren, "expected `)` after non-escaping callable parameters");
        _ = try self.expect(.fat_arrow, "expected `=>` after non-escaping callable parameters");

        const return_type = try self.allocator.create(ast.TypeName);
        errdefer self.allocator.destroy(return_type);
        return_type.* = try self.parseReturnTypeName("expected non-escaping callable return type");

        return .{
            .is_ref = false,
            .is_owned = false,
            .is_raw = false,
            .is_volatile_raw = false,
            .is_optional = false,
            .is_function = false,
            .is_arrow_callable = true,
            .is_slice = false,
            .slice_flags = .{},
            .array_len = null,
            .name = "=>",
            .args = try self.allocator.alloc(ast.TypeName, 0),
            .function_calling_convention = .cyna,
            .function_params = try params.toOwnedSlice(self.allocator),
            .function_return_type = return_type,
            .token = token,
        };
    }

    fn parseIf(self: *Parser) ParseError!ast.Stmt {
        const condition = try self.parseExpr();
        errdefer condition.destroy(self.allocator);

        _ = try self.expect(.l_brace, "expected `{` after if condition");
        const then_body = try self.parseBlockBody();
        errdefer {
            for (then_body) |stmt| stmt.deinit(self.allocator);
            self.allocator.free(then_body);
        }

        const else_body = if (self.match(.keyword_else)) blk: {
            if (self.match(.keyword_if)) {
                const nested_if = try self.parseIf();
                errdefer nested_if.deinit(self.allocator);
                const body = try self.allocator.alloc(ast.Stmt, 1);
                body[0] = nested_if;
                break :blk body;
            }
            _ = try self.expect(.l_brace, "expected `{` after else");
            break :blk try self.parseBlockBody();
        } else try self.allocator.alloc(ast.Stmt, 0);

        return .{ .@"if" = .{
            .condition = condition,
            .then_body = then_body,
            .else_body = else_body,
        } };
    }

    fn parseFor(self: *Parser) ParseError!ast.Stmt {
        const name = try self.expect(.identifier, "expected loop item name");
        _ = try self.expect(.keyword_in, "expected `in` after loop item name");
        const iterable = try self.parseExpr();
        errdefer iterable.destroy(self.allocator);

        _ = try self.expect(.l_brace, "expected `{` after for iterable");
        const body = try self.parseBlockBody();
        errdefer {
            for (body) |stmt| stmt.deinit(self.allocator);
            self.allocator.free(body);
        }

        return .{ .@"for" = .{
            .name = name.lexeme,
            .name_token = name,
            .iterable = iterable,
            .body = body,
        } };
    }

    fn parseWhile(self: *Parser) ParseError!ast.Stmt {
        const condition = try self.parseExpr();
        errdefer condition.destroy(self.allocator);

        _ = try self.expect(.l_brace, "expected `{` after while condition");
        const body = try self.parseBlockBody();

        return .{ .@"while" = .{
            .condition = condition,
            .body = body,
        } };
    }

    fn parseSwitch(self: *Parser) ParseError!ast.Switch {
        const value = try self.parseExpr();
        return self.parseSwitchWithValue(value);
    }

    fn parseSwitchWithValue(self: *Parser, value: *ast.Expr) ParseError!ast.Switch {
        errdefer value.destroy(self.allocator);

        _ = try self.expect(.l_brace, "expected `{` after switch value");
        var cases: std.ArrayListUnmanaged(ast.SwitchCase) = .empty;
        var else_body: ?[]ast.Stmt = null;
        var has_else = false;
        errdefer {
            for (cases.items) |case| case.deinit(self.allocator);
            cases.deinit(self.allocator);
            if (else_body) |body| {
                for (body) |stmt| stmt.deinit(self.allocator);
                self.allocator.free(body);
            }
        }

        while (!self.check(.r_brace) and !self.check(.eof)) {
            if (self.check(.keyword_case)) {
                try self.diagnostic_context.emitToken(self.path, self.peek(), "switch arms use `pattern =>` without `case`", .{});
                return ParseError.ParseFailed;
            }
            if (self.check(.keyword_else)) {
                try self.diagnostic_context.emitToken(self.path, self.peek(), "switch wildcard arms use `_ =>` instead of `else`", .{});
                return ParseError.ParseFailed;
            }
            const wildcard = self.check(.identifier) and std.mem.eql(u8, self.peek().lexeme, "_");
            if (wildcard) {
                const wildcard_token = self.advance();
                if (has_else) {
                    try self.diagnostic_context.emitToken(self.path, self.previous(), "duplicate switch wildcard", .{});
                    return ParseError.ParseFailed;
                }
                has_else = true;
                _ = try self.expect(.fat_arrow, "expected `=>` after switch wildcard");
                else_body = try self.parseSwitchArmBody();
                if (!self.check(.r_brace)) {
                    try self.diagnostic_context.emitToken(self.path, wildcard_token, "switch wildcard must be the final arm", .{});
                    return ParseError.ParseFailed;
                }
                continue;
            }

            if (self.check(.int_lit) or self.check(.string_lit) or self.check(.minus) or
                self.check(.l_paren) or (self.check(.identifier) and switch (self.peekAhead(1).tag) {
                .plus, .minus, .star, .slash, .percent, .amp, .pipe, .caret, .less, .greater => true,
                else => false,
            })) {
                const pattern = try self.parseExpr();
                errdefer pattern.destroy(self.allocator);
                _ = try self.expect(.fat_arrow, "expected `=>` after switch pattern");
                const body = try self.parseSwitchArmBody();
                errdefer {
                    for (body) |stmt| stmt.deinit(self.allocator);
                    self.allocator.free(body);
                }
                try cases.append(self.allocator, .{
                    .type_name = null,
                    .case_name = "",
                    .scalar_pattern = pattern,
                    .payload_name = null,
                    .token = ast.firstExprToken(pattern),
                    .body = body,
                });
                continue;
            }
            var type_name: ?[]const u8 = null;
            var type_variant: ?ast.TypeName = null;
            const case_name = if (self.match(.dot)) try self.expectUnionCaseName("expected switch case name") else blk: {
                const first = try self.expect(.identifier, "expected switch case label");
                if (self.match(.dot)) {
                    type_name = first.lexeme;
                    break :blk try self.expectUnionCaseName("expected switch case name");
                }
                type_variant = .{
                    .array_len = null,
                    .name = first.lexeme,
                    .args = try self.allocator.alloc(ast.TypeName, 0),
                    .token = first,
                };
                break :blk first;
            };
            errdefer if (type_variant) |variant| variant.deinit(self.allocator);
            const payload_name: ?[]const u8 = if (self.match(.l_paren)) blk: {
                const binding = try self.expect(.identifier, "expected switch payload binding name");
                _ = try self.expect(.r_paren, "expected `)` after switch payload binding");
                break :blk binding.lexeme;
            } else null;
            _ = try self.expect(.fat_arrow, "expected `=>` after switch pattern");
            const body = try self.parseSwitchArmBody();
            errdefer {
                for (body) |stmt| stmt.deinit(self.allocator);
                self.allocator.free(body);
            }
            try cases.append(self.allocator, .{
                .type_name = type_name,
                .case_name = case_name.lexeme,
                .type_variant = type_variant,
                .payload_name = payload_name,
                .token = case_name,
                .body = body,
            });
        }

        _ = try self.expect(.r_brace, "expected `}` after switch body");
        const owned_cases = try cases.toOwnedSlice(self.allocator);
        errdefer {
            for (owned_cases) |case| case.deinit(self.allocator);
            self.allocator.free(owned_cases);
        }
        return .{
            .value = value,
            .cases = owned_cases,
            .has_else = has_else,
            .else_body = else_body orelse try self.allocator.alloc(ast.Stmt, 0),
        };
    }

    fn parseSwitchArmBody(self: *Parser) ParseError![]ast.Stmt {
        if (self.match(.l_brace)) return self.parseBlockBody();
        if (self.check(.keyword_return) or self.check(.keyword_unreachable) or (self.check(.identifier) and std.mem.eql(u8, self.peek().lexeme, "throw"))) {
            const stmt = try self.parseStmt();
            errdefer stmt.deinit(self.allocator);
            const body = try self.allocator.alloc(ast.Stmt, 1);
            body[0] = stmt;
            return body;
        }
        const expr = try self.parseExpr();
        errdefer expr.destroy(self.allocator);
        _ = try self.expect(.semicolon, "expected `;` after switch expression arm");
        const body = try self.allocator.alloc(ast.Stmt, 1);
        body[0] = .{ .yield = .{ .token = ast.firstExprToken(expr), .value = expr } };
        return body;
    }

    fn parseExpr(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.parseOr();
        errdefer expr.destroy(self.allocator);
        while (self.match(.keyword_catch)) {
            const token = self.previous();
            var catch_failure_name: ?[]const u8 = null;
            const catch_code_name: ?[]const u8 = if (self.match(.l_paren)) blk: {
                const binding = try self.expect(.identifier, "expected error code name after `catch (`");
                if (std.mem.eql(u8, binding.lexeme, "_")) {
                    try self.diagnostic_context.emitToken(self.path, binding, "error code needs a name", .{});
                    return ParseError.ParseFailed;
                }
                const failure_name: ?[]const u8 = if (self.match(.comma)) detail: {
                    const detail_binding = try self.expect(.identifier, "expected failure detail name after comma");
                    if (std.mem.eql(u8, detail_binding.lexeme, "_") or std.mem.eql(u8, detail_binding.lexeme, binding.lexeme)) {
                        try self.diagnostic_context.emitToken(self.path, detail_binding, "failure detail needs a distinct name", .{});
                        return ParseError.ParseFailed;
                    }
                    break :detail detail_binding.lexeme;
                } else null;
                _ = try self.expect(.r_paren, "expected `)` after catch bindings");
                if (!self.check(.l_brace) and !self.check(.fat_arrow)) {
                    try self.diagnostic_context.emitToken(self.path, self.peek(), "expected `{{` or `=>` after catch bindings", .{});
                    return ParseError.ParseFailed;
                }
                catch_failure_name = failure_name;
                break :blk binding.lexeme;
            } else null;
            if (catch_code_name) |code_name| {
                const handler = try self.parseCatchBlock(code_name, token);
                expr = try self.makeCatchFallback(expr, handler, token, true, code_name, catch_failure_name);
            } else {
                try self.diagnostic_context.emitToken(self.path, token, "expected `catch (code) {{ ... }}` or `catch (code) => expression`", .{});
                return ParseError.ParseFailed;
            }
        }
        return expr;
    }

    fn parseCatchBlock(self: *Parser, code_name: []const u8, token: lexer.Token) ParseError!*ast.Expr {
        const body = if (self.match(.fat_arrow)) blk: {
            const value = try self.parseExpr();
            errdefer value.destroy(self.allocator);
            const statements = try self.allocator.alloc(ast.Stmt, 1);
            statements[0] = .{ .yield = .{ .token = ast.firstExprToken(value), .value = value } };
            break :blk statements;
        } else blk: {
            _ = try self.expect(.l_brace, "expected `{{` after catch view");
            break :blk try self.parseBlockBody();
        };
        errdefer {
            for (body) |stmt| stmt.deinit(self.allocator);
            self.allocator.free(body);
        }
        const error_name = try self.allocator.create(ast.Expr);
        error_name.* = .{ .name = .{ .text = code_name, .token = token } };
        errdefer error_name.destroy(self.allocator);
        const empty_cases = try self.allocator.alloc(ast.SwitchCase, 0);
        errdefer self.allocator.free(empty_cases);
        const handler = try self.allocator.create(ast.Expr);
        handler.* = .{ .@"switch" = .{
            .value = error_name,
            .cases = empty_cases,
            .has_else = true,
            .else_body = body,
            .catch_code_name = code_name,
        } };
        return handler;
    }

    fn makeCatchFallback(self: *Parser, source: *ast.Expr, fallback: *ast.Expr, token: lexer.Token, captures_error: bool, code_name: ?[]const u8, failure_name: ?[]const u8) ParseError!*ast.Expr {
        const allocator = self.allocator;
        var owns_fallback = true;
        errdefer if (owns_fallback) fallback.destroy(allocator);

        const ok_value = try allocator.create(ast.Expr);
        ok_value.* = .{ .name = .{ .text = "__cyna_catch_ok", .token = token } };
        var owns_ok_value = true;
        errdefer if (owns_ok_value) ok_value.destroy(allocator);

        const ok_body = try allocator.alloc(ast.Stmt, 1);
        ok_body[0] = .{ .yield = .{ .token = token, .value = ok_value } };
        owns_ok_value = false;
        var owns_ok_body = true;
        errdefer if (owns_ok_body) {
            ok_body[0].deinit(allocator);
            allocator.free(ok_body);
        };

        const err_body = try allocator.alloc(ast.Stmt, 1);
        err_body[0] = .{ .yield = .{ .token = token, .value = fallback } };
        owns_fallback = false;
        var owns_err_body = true;
        errdefer if (owns_err_body) {
            err_body[0].deinit(allocator);
            allocator.free(err_body);
        };

        const cases = try allocator.alloc(ast.SwitchCase, 2);
        cases[0] = .{ .type_name = null, .case_name = "ok", .payload_name = "__cyna_catch_ok", .token = token, .body = ok_body };
        cases[1] = .{ .type_name = null, .case_name = "err", .payload_name = if (captures_error) code_name orelse "__cyna_catch_err" else null, .token = token, .body = err_body };
        owns_ok_body = false;
        owns_err_body = false;
        errdefer {
            for (cases) |case| case.deinit(allocator);
            allocator.free(cases);
        }

        const else_body = try allocator.alloc(ast.Stmt, 0);
        errdefer allocator.free(else_body);
        const parent = try allocator.create(ast.Expr);
        parent.* = .{ .@"switch" = .{
            .value = source,
            .cases = cases,
            .has_else = false,
            .else_body = else_body,
            .catch_fallback = true,
            .catch_failure_name = failure_name,
        } };
        return parent;
    }

    fn parseOr(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.parseLogicalAnd();
        errdefer expr.destroy(self.allocator);

        while (self.match(.keyword_or)) {
            const right = try self.parseLogicalAnd();
            errdefer right.destroy(self.allocator);
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .binary = .{
                .op = .@"or",
                .left = expr,
                .right = right,
            } };
            expr = parent;
        }

        return expr;
    }

    fn parseLogicalAnd(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.parseIs();
        errdefer expr.destroy(self.allocator);

        while (self.match(.keyword_and)) {
            const right = try self.parseIs();
            errdefer right.destroy(self.allocator);
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .binary = .{
                .op = .@"and",
                .left = expr,
                .right = right,
            } };
            expr = parent;
        }

        return expr;
    }

    fn parseIs(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.parseMembership();
        errdefer expr.destroy(self.allocator);

        while (self.match(.keyword_is)) {
            const token = self.previous();
            var kind: ast.IsTestKind = .optional_some;
            var case_name: ?[]const u8 = null;
            var capture_name: ?[]const u8 = null;
            var capture_token: ?lexer.Token = null;
            if (self.match(.keyword_none)) {
                kind = .optional_none;
            } else if (self.match(.dot)) {
                kind = .union_case;
                const case_token = try self.expectUnionCaseName("expected union case name");
                case_name = case_token.lexeme;
                if (self.match(.l_paren)) {
                    const capture = try self.expect(.identifier, "expected capture name in `is .tag(name)`");
                    capture_name = capture.lexeme;
                    capture_token = capture;
                    _ = try self.expect(.r_paren, "expected `)` after union capture");
                }
            } else {
                const capture = try self.expect(.identifier, "expected capture name or `none` after `is`");
                capture_name = capture.lexeme;
                capture_token = capture;
            }

            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .is_test = .{
                .subject = expr,
                .kind = kind,
                .case_name = case_name,
                .capture_name = capture_name,
                .capture_token = capture_token,
                .token = token,
            } };
            expr = parent;
        }

        return expr;
    }

    fn parseMembership(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.parseBitOr();
        errdefer expr.destroy(self.allocator);

        while (self.match(.keyword_in)) {
            const right = try self.parseBitOr();
            errdefer right.destroy(self.allocator);
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .binary = .{
                .op = .in,
                .left = expr,
                .right = right,
            } };
            expr = parent;
        }

        return expr;
    }

    fn parseBitOr(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.parseBitXor();
        errdefer expr.destroy(self.allocator);

        while (self.match(.pipe)) {
            const right = try self.parseBitXor();
            errdefer right.destroy(self.allocator);
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .binary = .{
                .op = .bit_or,
                .left = expr,
                .right = right,
            } };
            expr = parent;
        }

        return expr;
    }

    fn parseBitXor(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.parseBitAnd();
        errdefer expr.destroy(self.allocator);

        while (self.match(.caret)) {
            const right = try self.parseBitAnd();
            errdefer right.destroy(self.allocator);
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .binary = .{
                .op = .bit_xor,
                .left = expr,
                .right = right,
            } };
            expr = parent;
        }

        return expr;
    }

    fn parseBitAnd(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.parseCompare();
        errdefer expr.destroy(self.allocator);

        while (self.match(.amp)) {
            const right = try self.parseCompare();
            errdefer right.destroy(self.allocator);
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .binary = .{
                .op = .bit_and,
                .left = expr,
                .right = right,
            } };
            expr = parent;
        }

        return expr;
    }

    fn parseCompare(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.parseShift();
        errdefer expr.destroy(self.allocator);

        while (self.matchComparison()) |op| {
            const right = try self.parseShift();
            errdefer right.destroy(self.allocator);
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .binary = .{
                .op = op,
                .left = expr,
                .right = right,
            } };
            expr = parent;
        }

        return expr;
    }

    fn parseShift(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.parseAdd();
        errdefer expr.destroy(self.allocator);

        while (self.matchShift()) |op| {
            const right = try self.parseAdd();
            errdefer right.destroy(self.allocator);
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .binary = .{
                .op = op,
                .left = expr,
                .right = right,
            } };
            expr = parent;
        }

        return expr;
    }

    fn parseAdd(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.parseMul();
        errdefer expr.destroy(self.allocator);

        while (self.match(.plus) or self.match(.plus_percent) or self.match(.minus) or self.match(.minus_percent)) {
            const op_token = self.previous();
            const right = try self.parseMul();
            errdefer right.destroy(self.allocator);
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .binary = .{
                .op = switch (op_token.tag) {
                    .plus => .add,
                    .plus_percent => .wrap_add,
                    .minus => .sub,
                    .minus_percent => .wrap_sub,
                    else => unreachable,
                },
                .left = expr,
                .right = right,
            } };
            expr = parent;
        }

        return expr;
    }

    fn parseMul(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.parseRepeat();
        errdefer expr.destroy(self.allocator);

        while (self.match(.star) or self.match(.star_percent) or self.match(.slash) or self.match(.percent)) {
            const op_token = self.previous();
            const right = try self.parseRepeat();
            errdefer right.destroy(self.allocator);
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .binary = .{
                .op = switch (op_token.tag) {
                    .star => .mul,
                    .star_percent => .wrap_mul,
                    .slash => .div,
                    .percent => .mod,
                    else => unreachable,
                },
                .left = expr,
                .right = right,
            } };
            expr = parent;
        }

        return expr;
    }

    fn parseRepeat(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.parseCast();
        errdefer expr.destroy(self.allocator);

        while (self.match(.star_star)) {
            const token = self.previous();
            if (expr.* != .array_literal) {
                try self.diagnostic_context.emitToken(self.path, token, "sequence repeat requires a bracket sequence on the left", .{});
                return ParseError.ParseFailed;
            }
            const count = try self.parseCast();
            const items = expr.array_literal.items;
            const pattern_token = expr.array_literal.token;
            self.allocator.destroy(expr);
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .sequence_repeat = .{
                .token = pattern_token,
                .items = items,
                .count = count,
            } };
            expr = parent;
        }

        return expr;
    }

    fn parseCast(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.parseUnary();
        errdefer expr.destroy(self.allocator);

        while (self.match(.keyword_as)) {
            const token = self.previous();
            const reinterpret = self.match(.bang);
            const fallible = if (reinterpret) false else self.match(.question);
            const target = try self.parseTypeName("expected cast target type");
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .cast = .{
                .subject = expr,
                .target = target,
                .fallible = fallible,
                .reinterpret = reinterpret,
                .token = token,
            } };
            expr = parent;
        }

        return expr;
    }

    fn parseUnary(self: *Parser) ParseError!*ast.Expr {
        if (self.match(.tilde)) {
            const expr = try self.parseUnary();
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .unary = .{
                .op = .bit_not,
                .expr = expr,
            } };
            return parent;
        }

        if (self.match(.amp)) {
            const token = self.previous();
            const inner = try self.parseUnary();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = .{ .address_of = .{ .expr = inner, .token = token } };
            return expr;
        }

        if (self.match(.keyword_try)) {
            const token = self.previous();
            const expr = try self.parseUnary();
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .@"try" = .{
                .expr = expr,
                .token = token,
            } };
            return parent;
        }

        if (self.match(.keyword_comptime)) {
            const token = self.previous();
            const expr = try self.parseUnary();
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .@"comptime" = .{
                .expr = expr,
                .token = token,
            } };
            return parent;
        }

        if (self.match(.keyword_not)) {
            const expr = try self.parseUnary();
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .unary = .{
                .op = .not,
                .expr = expr,
            } };
            return parent;
        }

        if (self.match(.minus)) {
            const minus = self.previous();
            if (self.match(.int_lit)) {
                const token = self.previous();
                const parsed = parseIntegerLiteral(self.allocator, token.lexeme) catch {
                    try self.diagnostic_context.emitToken(self.path, token, "invalid integer literal `{s}`", .{token.lexeme});
                    return ParseError.ParseFailed;
                };
                const value = negateIntegerLiteral(parsed) catch {
                    try self.diagnostic_context.emitToken(self.path, minus, "invalid negative integer literal", .{});
                    return ParseError.ParseFailed;
                };
                const expr = try self.allocator.create(ast.Expr);
                expr.* = .{ .int = .{
                    .value = value,
                    .unsigned_value = null,
                    .token = token,
                } };
                return expr;
            }
            if (self.match(.float_lit)) {
                const token = self.previous();
                const value = parseFloatLiteral(self.allocator, token.lexeme) catch {
                    try self.diagnostic_context.emitToken(self.path, token, "invalid float literal `{s}`", .{token.lexeme});
                    return ParseError.ParseFailed;
                };
                const expr = try self.allocator.create(ast.Expr);
                expr.* = .{ .float = .{ .value = -value, .token = token } };
                return expr;
            }
            const inner = try self.parseUnary();
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .unary = .{
                .op = .negate,
                .expr = inner,
            } };
            return parent;
        }

        if (self.check(.identifier) and
            std.mem.eql(u8, self.peek().lexeme, "take") and
            self.peekAhead(1).tag != .l_paren)
        {
            _ = self.advance();
            const expr = try self.parseUnary();
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .unary = .{
                .op = .take,
                .expr = expr,
            } };
            return parent;
        }

        if (self.match(.star)) {
            const token = self.previous();
            if (self.unchecked_depth == 0) {
                try self.diagnostic_context.emitToken(self.path, token, "raw pointer dereference requires `unchecked`", .{});
                return ParseError.ParseFailed;
            }
            const expr = try self.parseUnary();
            const parent = try self.allocator.create(ast.Expr);
            parent.* = .{ .deref = .{ .expr = expr, .token = token } };
            return parent;
        }

        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) ParseError!*ast.Expr {
        var expr = try self.parsePrimary();
        errdefer expr.destroy(self.allocator);

        while (true) {
            if (self.match(.l_bracket)) {
                const token = self.previous();
                const parent = try self.allocator.create(ast.Expr);
                if (self.match(.dot_dot)) {
                    const end = if (!self.check(.r_bracket)) try self.parseExpr() else null;
                    _ = try self.expect(.r_bracket, "expected `]` after slice expression");
                    parent.* = .{ .slice_range = .{
                        .object = expr,
                        .start = null,
                        .end = end,
                        .token = token,
                    } };
                } else {
                    const first = try self.parseExpr();
                    if (self.match(.dot_dot)) {
                        const end = if (!self.check(.r_bracket)) try self.parseExpr() else null;
                        _ = try self.expect(.r_bracket, "expected `]` after slice expression");
                        parent.* = .{ .slice_range = .{
                            .object = expr,
                            .start = first,
                            .end = end,
                            .token = token,
                        } };
                    } else {
                        _ = try self.expect(.r_bracket, "expected `]` after index expression");
                        parent.* = .{ .index = .{
                            .object = expr,
                            .index = first,
                            .token = token,
                        } };
                    }
                }
                expr = parent;
                continue;
            }

            if (!self.match(.dot)) break;

            const field = if (self.check(.int_lit)) self.advance() else try self.expectPathSegment("expected field name after `.`");
            const parent = try self.allocator.create(ast.Expr);
            const call_type_args = try self.parseCallTypeArgsIfPresent();
            errdefer {
                for (call_type_args) |arg| arg.deinit(self.allocator);
                self.allocator.free(call_type_args);
            }
            if (self.match(.l_paren)) {
                var args: std.ArrayListUnmanaged(ast.CallArg) = .empty;
                errdefer {
                    for (args.items) |arg| arg.deinit(self.allocator);
                    args.deinit(self.allocator);
                }

                try self.parseCallArgs(&args);
                _ = try self.expect(.r_paren, "expected `)` after method call arguments");
                if (expr.* == .name and isTypeLikeName(expr.name.text)) {
                    const owner = expr.name.text;
                    expr.destroy(self.allocator);
                    parent.* = .{ .call = .{
                        .owner = owner,
                        .callee = field.lexeme,
                        .callee_token = field,
                        .type_args = call_type_args,
                        .args = try args.toOwnedSlice(self.allocator),
                    } };
                } else {
                    parent.* = .{ .method_call = .{
                        .object = expr,
                        .method = field.lexeme,
                        .method_token = field,
                        .type_args = call_type_args,
                        .args = try args.toOwnedSlice(self.allocator),
                    } };
                }
            } else {
                if (call_type_args.len != 0) {
                    try self.diagnostic_context.emitToken(self.path, field, "expected `(` after explicit type arguments", .{});
                    return ParseError.ParseFailed;
                }
                if (expr.* == .name and isTypeLikeName(expr.name.text)) {
                    const owner = expr.name.text;
                    expr.destroy(self.allocator);
                    parent.* = .{ .enum_case = .{
                        .type_name = owner,
                        .case_name = field.lexeme,
                        .token = field,
                    } };
                } else {
                    parent.* = .{ .field = .{
                        .object = expr,
                        .field = field.lexeme,
                        .field_token = field,
                    } };
                }
            }
            expr = parent;
        }

        return expr;
    }

    fn parsePrimary(self: *Parser) ParseError!*ast.Expr {
        if (self.match(.keyword_switch)) {
            const switch_expr = try self.parseSwitch();
            errdefer switch_expr.deinit(self.allocator);
            const expr = try self.allocator.create(ast.Expr);
            expr.* = .{ .@"switch" = switch_expr };
            return expr;
        }
        if (self.match(.pipe)) {
            return self.parseLambdaExpr(self.previous());
        }

        if (self.match(.keyword_fn)) {
            return self.parseFunctionExpr(self.previous(), .cyna);
        }

        if (self.check(.identifier) and std.mem.eql(u8, self.peek().lexeme, "c") and self.peekAhead(1).tag == .keyword_fn) {
            const token = self.advance();
            _ = self.advance();
            return self.parseFunctionExpr(token, .c);
        }

        if (self.match(.float_lit)) {
            const token = self.previous();
            const value = parseFloatLiteral(self.allocator, token.lexeme) catch {
                try self.diagnostic_context.emitToken(self.path, token, "invalid float literal `{s}`", .{token.lexeme});
                return ParseError.ParseFailed;
            };
            const expr = try self.allocator.create(ast.Expr);
            expr.* = .{ .float = .{ .value = value, .token = token } };
            return expr;
        }

        if (self.match(.int_lit)) {
            const token = self.previous();
            const value = parseIntegerLiteral(self.allocator, token.lexeme) catch {
                try self.diagnostic_context.emitToken(self.path, token, "invalid integer literal `{s}`", .{token.lexeme});
                return ParseError.ParseFailed;
            };
            const expr = try self.allocator.create(ast.Expr);
            expr.* = .{ .int = .{
                .value = value.value,
                .unsigned_value = value.unsigned_value,
                .token = token,
            } };
            return expr;
        }

        if (self.match(.rune_lit)) {
            const token = self.previous();
            const value = parseRuneLiteral(token.lexeme) catch {
                try self.diagnostic_context.emitToken(self.path, token, "invalid rune literal `{s}`", .{token.lexeme});
                return ParseError.ParseFailed;
            };
            const expr = try self.allocator.create(ast.Expr);
            expr.* = .{ .rune = .{ .value = value, .token = token } };
            return expr;
        }

        if (self.match(.string_lit)) {
            const token = self.previous();
            const decoded = try self.parseStringLiteral(token);
            errdefer if (decoded.owns_text) self.allocator.free(decoded.text);
            const expr = try self.allocator.create(ast.Expr);
            expr.* = .{ .string = .{
                .text = decoded.text,
                .token = token,
                .owns_text = decoded.owns_text,
            } };
            return expr;
        }

        if (self.match(.interpolated_string_lit)) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            errdefer self.allocator.destroy(expr);
            expr.* = .{ .interpolated_string = try self.parseInterpolatedString(token) };
            return expr;
        }

        if (self.match(.keyword_true) or self.match(.keyword_false)) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = .{ .bool = .{ .value = token.tag == .keyword_true, .token = token } };
            return expr;
        }

        if (self.match(.keyword_none)) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = .{ .none = token };
            return expr;
        }

        if (self.match(.keyword_new)) {
            return self.parseNewExpr(self.previous());
        }

        if (self.match(.keyword_asm)) {
            return self.parseAsmExpr(self.previous());
        }

        if (self.match(.dot)) {
            const case_name = try self.expectUnionCaseName("expected union case name");
            const value = if (self.match(.l_paren)) blk: {
                if (self.match(.r_paren)) break :blk null;
                const payload = try self.parseExpr();
                _ = try self.expect(.r_paren, "expected `)` after union case payload");
                break :blk payload;
            } else null;
            const expr = try self.allocator.create(ast.Expr);
            expr.* = .{ .union_case = .{
                .case_name = case_name.lexeme,
                .value = value,
                .token = case_name,
            } };
            return expr;
        }

        if (self.match(.identifier)) {
            const name = self.previous();

            if (isTypeLikeName(name.lexeme) and (self.check(.less) or self.check(.l_brace) or self.check(.l_bracket))) {
                const type_args = try self.parseTypeArgsForName(name);
                errdefer {
                    for (type_args) |arg| arg.deinit(self.allocator);
                    self.allocator.free(type_args);
                }
                if (self.match(.l_brace)) {
                    const fields = try self.parseStructLiteralFields();
                    const expr = try self.allocator.create(ast.Expr);
                    expr.* = .{ .struct_literal = .{
                        .type_name = name.lexeme,
                        .type_args = type_args,
                        .type_token = name,
                        .fields = fields,
                    } };
                    return expr;
                }
                _ = try self.expect(.l_bracket, "expected `[` or `{` after type name");
                const items = try self.parseBracketSequenceItems();
                const expr = try self.allocator.create(ast.Expr);
                expr.* = .{ .typed_sequence_literal = .{
                    .token = name,
                    .target = .{
                        .is_ref = false,
                        .is_owned = false,
                        .is_raw = false,
                        .is_volatile_raw = false,
                        .is_optional = false,
                        .is_slice = false,
                        .slice_flags = .{},
                        .array_len = null,
                        .name = name.lexeme,
                        .args = type_args,
                        .token = name,
                    },
                    .storage_capacity = null,
                    .items = items,
                } };
                return expr;
            }

            const call_type_args = try self.parseCallTypeArgsIfPresent();
            errdefer {
                for (call_type_args) |arg| arg.deinit(self.allocator);
                self.allocator.free(call_type_args);
            }

            if (self.match(.l_paren)) {
                var args: std.ArrayListUnmanaged(ast.CallArg) = .empty;
                errdefer {
                    for (args.items) |arg| arg.deinit(self.allocator);
                    args.deinit(self.allocator);
                }

                try self.parseCallArgs(&args);
                _ = try self.expect(.r_paren, "expected `)` after call arguments");

                const expr = try self.allocator.create(ast.Expr);
                if (std.mem.eql(u8, name.lexeme, "ok")) {
                    if (call_type_args.len != 0) {
                        try self.diagnostic_context.emitToken(self.path, name, "`ok` does not accept explicit type arguments", .{});
                        return ParseError.ParseFailed;
                    }
                    if (args.items.len > 1) {
                        try self.diagnostic_context.emitToken(self.path, name, "`ok` expects zero or one argument", .{});
                        return ParseError.ParseFailed;
                    }
                    const value = if (args.items.len == 1) args.items[0].value else null;
                    args.items.len = 0;
                    args.deinit(self.allocator);
                    expr.* = .{ .union_case = .{
                        .case_name = "ok",
                        .value = value,
                        .token = name,
                    } };
                } else if (std.mem.eql(u8, name.lexeme, "err")) {
                    if (call_type_args.len != 0) {
                        try self.diagnostic_context.emitToken(self.path, name, "`err` does not accept explicit type arguments", .{});
                        return ParseError.ParseFailed;
                    }
                    if (args.items.len != 1) {
                        try self.diagnostic_context.emitToken(self.path, name, "`err` expects one argument", .{});
                        return ParseError.ParseFailed;
                    }
                    const value = args.items[0].value;
                    args.items.len = 0;
                    args.deinit(self.allocator);
                    expr.* = .{ .union_case = .{
                        .case_name = "err",
                        .value = value,
                        .token = name,
                    } };
                } else {
                    expr.* = .{ .call = .{
                        .owner = null,
                        .callee = name.lexeme,
                        .callee_token = name,
                        .type_args = call_type_args,
                        .args = try args.toOwnedSlice(self.allocator),
                    } };
                }
                return expr;
            }

            if (call_type_args.len != 0) {
                try self.diagnostic_context.emitToken(self.path, name, "expected `(` after explicit type arguments", .{});
                return ParseError.ParseFailed;
            }

            const expr = try self.allocator.create(ast.Expr);
            expr.* = .{ .name = .{ .text = name.lexeme, .token = name } };
            return expr;
        }

        if (self.match(.l_brace)) {
            const open = self.previous();
            const entries = try self.parseKeyedLiteralEntries();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = .{ .keyed_literal = .{
                .token = open,
                .entries = entries,
            } };
            return expr;
        }

        if (self.match(.l_bracket)) {
            const open = self.previous();
            if (self.match(.colon)) {
                if (self.match(.r_bracket)) {
                    const item_type = try self.parseTypeName("expected runtime array item type");
                    errdefer item_type.deinit(self.allocator);
                    _ = try self.expect(.l_bracket, "expected `[` after runtime array type");
                    const items = try self.parseBracketSequenceItems();
                    const type_args = try self.allocator.alloc(ast.TypeName, 1);
                    type_args[0] = item_type;
                    const expr = try self.allocator.create(ast.Expr);
                    expr.* = .{ .typed_sequence_literal = .{
                        .token = open,
                        .target = .{
                            .is_ref = false,
                            .is_owned = false,
                            .is_raw = false,
                            .is_volatile_raw = false,
                            .is_optional = false,
                            .is_slice = false,
                            .slice_flags = .{},
                            .array_len = null,
                            .name = "[:]",
                            .args = type_args,
                            .token = open,
                        },
                        .storage_capacity = null,
                        .items = items,
                    } };
                    return expr;
                }

                const capacity_expr = try self.parseExpr();
                _ = try self.expect(.r_bracket, "expected `]` after dense storage capacity");
                if (self.check(.l_bracket)) {
                    _ = self.advance();
                    const items = try self.parseBracketSequenceItems();
                    const capacity = switch (capacity_expr.*) {
                        .int => |value| blk: {
                            if (value.value < 0) {
                                try self.diagnostic_context.emitToken(self.path, value.token, "dense storage capacity {d} cannot be negative", .{value.value});
                                return ParseError.ParseFailed;
                            }
                            break :blk @as(usize, @intCast(value.value));
                        },
                        else => {
                            try self.diagnostic_context.emitToken(self.path, ast.firstExprToken(capacity_expr), "capacity-bearing dense literal requires an integer literal; use `[: expr]T` for runtime capacity", .{});
                            return ParseError.ParseFailed;
                        },
                    };
                    capacity_expr.destroy(self.allocator);
                    const expr = try self.allocator.create(ast.Expr);
                    expr.* = .{ .typed_sequence_literal = .{
                        .token = open,
                        .target = .{
                            .is_ref = false,
                            .is_owned = false,
                            .is_raw = false,
                            .is_volatile_raw = false,
                            .is_optional = false,
                            .is_slice = false,
                            .slice_flags = .{},
                            .array_len = null,
                            .name = "[:]",
                            .args = try self.allocator.alloc(ast.TypeName, 0),
                            .token = open,
                        },
                        .storage_capacity = capacity,
                        .items = items,
                    } };
                    return expr;
                }

                const item_type = try self.parseTypeName("expected runtime array item type");
                const expr = try self.allocator.create(ast.Expr);
                expr.* = .{ .new_array = .{
                    .token = open,
                    .len = capacity_expr,
                    .item_type = item_type,
                } };
                return expr;
            }
            if (self.match(.semicolon)) {
                if (self.check(.r_bracket)) {
                    _ = self.advance();
                    const item_type = try self.parseTypeName("expected sparse storage item type");
                    errdefer item_type.deinit(self.allocator);
                    const type_args = try self.allocator.alloc(ast.TypeName, 1);
                    errdefer self.allocator.free(type_args);
                    type_args[0] = item_type;
                    if (self.match(.l_brace)) {
                        const entries = try self.parseKeyedLiteralEntries();
                        const expr = try self.allocator.create(ast.Expr);
                        expr.* = .{ .keyed_literal = .{
                            .token = open,
                            .target = .{
                                .is_ref = false,
                                .is_owned = false,
                                .is_raw = false,
                                .is_volatile_raw = false,
                                .is_optional = false,
                                .is_slice = false,
                                .slice_flags = .{},
                                .array_len = null,
                                .name = "[;]",
                                .args = type_args,
                                .token = open,
                            },
                            .storage_capacity = null,
                            .entries = entries,
                        } };
                        return expr;
                    }
                    if (!self.match(.l_bracket)) {
                        try self.diagnostic_context.emitToken(self.path, open, "sparse storage type literal requires `[...]` or `{{...}}` initializer; use `[; capacity]T` for explicit empty construction", .{});
                        return ParseError.ParseFailed;
                    }
                    const items = try self.parseBracketSequenceItems();
                    const expr = try self.allocator.create(ast.Expr);
                    expr.* = .{ .typed_sequence_literal = .{
                        .token = open,
                        .target = .{
                            .is_ref = false,
                            .is_owned = false,
                            .is_raw = false,
                            .is_volatile_raw = false,
                            .is_optional = false,
                            .is_slice = false,
                            .slice_flags = .{},
                            .array_len = null,
                            .name = "[;]",
                            .args = type_args,
                            .token = open,
                        },
                        .storage_capacity = null,
                        .items = items,
                    } };
                    return expr;
                }
                const capacity_expr = try self.parseExpr();
                _ = try self.expect(.r_bracket, "expected `]` after sparse storage capacity");
                if (self.match(.l_brace)) {
                    const capacity = switch (capacity_expr.*) {
                        .int => |value| blk: {
                            if (value.value < 0) {
                                try self.diagnostic_context.emitToken(self.path, value.token, "sparse storage capacity {d} cannot be negative", .{value.value});
                                return ParseError.ParseFailed;
                            }
                            break :blk @as(usize, @intCast(value.value));
                        },
                        else => {
                            try self.diagnostic_context.emitToken(self.path, ast.firstExprToken(capacity_expr), "target-typed sparse storage capacity must be an integer literal; use `[; expr]T` for runtime capacity", .{});
                            return ParseError.ParseFailed;
                        },
                    };
                    capacity_expr.destroy(self.allocator);
                    const entries = try self.parseKeyedLiteralEntries();
                    const expr = try self.allocator.create(ast.Expr);
                    expr.* = .{ .keyed_literal = .{
                        .token = open,
                        .target = .{
                            .is_ref = false,
                            .is_owned = false,
                            .is_raw = false,
                            .is_volatile_raw = false,
                            .is_optional = false,
                            .is_slice = false,
                            .slice_flags = .{},
                            .array_len = null,
                            .name = "[;]",
                            .args = try self.allocator.alloc(ast.TypeName, 0),
                            .token = open,
                        },
                        .storage_capacity = capacity,
                        .entries = entries,
                    } };
                    return expr;
                }
                if (self.match(.l_bracket)) {
                    const capacity = switch (capacity_expr.*) {
                        .int => |value| blk: {
                            if (value.value < 0) {
                                try self.diagnostic_context.emitToken(self.path, value.token, "sparse storage capacity {d} cannot be negative", .{value.value});
                                return ParseError.ParseFailed;
                            }
                            break :blk @as(usize, @intCast(value.value));
                        },
                        else => {
                            try self.diagnostic_context.emitToken(self.path, ast.firstExprToken(capacity_expr), "target-typed sparse storage capacity must be an integer literal; use `[; expr]T` for runtime capacity", .{});
                            return ParseError.ParseFailed;
                        },
                    };
                    capacity_expr.destroy(self.allocator);
                    const items = try self.parseBracketSequenceItems();
                    const expr = try self.allocator.create(ast.Expr);
                    expr.* = .{ .typed_sequence_literal = .{
                        .token = open,
                        .target = .{
                            .is_ref = false,
                            .is_owned = false,
                            .is_raw = false,
                            .is_volatile_raw = false,
                            .is_optional = false,
                            .is_slice = false,
                            .slice_flags = .{},
                            .array_len = null,
                            .name = "[;]",
                            .args = try self.allocator.alloc(ast.TypeName, 0),
                            .token = open,
                        },
                        .storage_capacity = capacity,
                        .items = items,
                    } };
                    return expr;
                }
                if (self.canStartTypeName()) {
                    const item_type = try self.parseTypeName("expected sparse storage item type");
                    errdefer item_type.deinit(self.allocator);
                    if (self.check(.l_brace) or self.check(.l_bracket)) {
                        const capacity = switch (capacity_expr.*) {
                            .int => |value| blk: {
                                if (value.value < 0) {
                                    try self.diagnostic_context.emitToken(self.path, value.token, "sparse storage capacity {d} cannot be negative", .{value.value});
                                    return ParseError.ParseFailed;
                                }
                                break :blk @as(usize, @intCast(value.value));
                            },
                            else => {
                                try self.diagnostic_context.emitToken(self.path, ast.firstExprToken(capacity_expr), "capacity-bearing sparse literal requires an integer literal; use `[; expr]T` for runtime capacity", .{});
                                return ParseError.ParseFailed;
                            },
                        };
                        capacity_expr.destroy(self.allocator);
                        const type_args = try self.allocator.alloc(ast.TypeName, 1);
                        errdefer self.allocator.free(type_args);
                        type_args[0] = item_type;
                        if (self.match(.l_brace)) {
                            const entries = try self.parseKeyedLiteralEntries();
                            const expr = try self.allocator.create(ast.Expr);
                            expr.* = .{ .keyed_literal = .{
                                .token = open,
                                .target = .{
                                    .is_ref = false,
                                    .is_owned = false,
                                    .is_raw = false,
                                    .is_volatile_raw = false,
                                    .is_optional = false,
                                    .is_slice = false,
                                    .slice_flags = .{},
                                    .array_len = null,
                                    .name = "[;]",
                                    .args = type_args,
                                    .token = open,
                                },
                                .storage_capacity = capacity,
                                .entries = entries,
                            } };
                            return expr;
                        }
                        _ = self.advance();
                        const items = try self.parseBracketSequenceItems();
                        const expr = try self.allocator.create(ast.Expr);
                        expr.* = .{ .typed_sequence_literal = .{
                            .token = open,
                            .target = .{
                                .is_ref = false,
                                .is_owned = false,
                                .is_raw = false,
                                .is_volatile_raw = false,
                                .is_optional = false,
                                .is_slice = false,
                                .slice_flags = .{},
                                .array_len = null,
                                .name = "[;]",
                                .args = type_args,
                                .token = open,
                            },
                            .storage_capacity = capacity,
                            .items = items,
                        } };
                        return expr;
                    }
                    const expr = try self.allocator.create(ast.Expr);
                    expr.* = .{ .new_sparse = .{
                        .token = open,
                        .capacity = capacity_expr,
                        .item_type = item_type,
                    } };
                    return expr;
                }
                const capacity = switch (capacity_expr.*) {
                    .int => |value| blk: {
                        if (value.value < 0) {
                            try self.diagnostic_context.emitToken(self.path, value.token, "sparse storage capacity {d} cannot be negative", .{value.value});
                            return ParseError.ParseFailed;
                        }
                        break :blk @as(usize, @intCast(value.value));
                    },
                    else => {
                        try self.diagnostic_context.emitToken(self.path, ast.firstExprToken(capacity_expr), "target-typed sparse storage capacity must be an integer literal; use `[; expr]T` for runtime capacity", .{});
                        return ParseError.ParseFailed;
                    },
                };
                capacity_expr.destroy(self.allocator);
                const expr = try self.allocator.create(ast.Expr);
                expr.* = .{ .typed_sequence_literal = .{
                    .token = open,
                    .target = .{
                        .is_ref = false,
                        .is_owned = false,
                        .is_raw = false,
                        .is_volatile_raw = false,
                        .is_optional = false,
                        .is_slice = false,
                        .slice_flags = .{},
                        .array_len = null,
                        .name = "[;]",
                        .args = try self.allocator.alloc(ast.TypeName, 0),
                        .token = open,
                    },
                    .storage_capacity = capacity,
                    .items = try self.allocator.alloc(*ast.Expr, 0),
                } };
                return expr;
            }
            if (self.check(.int_lit) and self.peekAhead(1).tag == .r_bracket and self.peekAhead(2).tag == .identifier) {
                const len_token = self.advance();
                _ = try self.expect(.r_bracket, "expected `]` after fixed array length");
                const item_type = try self.parseTypeName("expected fixed array item type");
                const len = std.fmt.parseInt(usize, len_token.lexeme, 10) catch {
                    try self.diagnostic_context.emitToken(self.path, len_token, "invalid fixed array length `{s}`", .{len_token.lexeme});
                    return ParseError.ParseFailed;
                };
                errdefer item_type.deinit(self.allocator);
                _ = try self.expect(.l_bracket, "expected `[` after fixed array type");
                const items = try self.parseBracketSequenceItems();
                const expr = try self.allocator.create(ast.Expr);
                expr.* = .{ .typed_sequence_literal = .{
                    .token = open,
                    .target = .{
                        .is_ref = item_type.is_ref,
                        .is_owned = item_type.is_owned,
                        .is_raw = item_type.is_raw,
                        .is_volatile_raw = item_type.is_volatile_raw,
                        .is_optional = item_type.is_optional,
                        .is_slice = item_type.is_slice,
                        .slice_flags = item_type.slice_flags,
                        .array_len = len,
                        .array_len_name = item_type.array_len_name,
                        .array_len_token = item_type.array_len_token,
                        .module_name = item_type.module_name,
                        .owns_module_name = item_type.owns_module_name,
                        .name = item_type.name,
                        .args = item_type.args,
                        .function_calling_convention = item_type.function_calling_convention,
                        .function_params = item_type.function_params,
                        .function_return_type = item_type.function_return_type,
                        .token = open,
                    },
                    .storage_capacity = null,
                    .items = items,
                } };
                return expr;
            }

            var items: std.ArrayListUnmanaged(*ast.Expr) = .empty;
            errdefer {
                for (items.items) |item| item.destroy(self.allocator);
                items.deinit(self.allocator);
            }

            if (!self.check(.r_bracket)) {
                while (true) {
                    try items.append(self.allocator, try self.parseExpr());
                    if (!self.match(.comma)) break;
                    if (self.check(.r_bracket)) break;
                }
            }

            _ = try self.expect(.r_bracket, "expected `]` after array literal");
            const expr = try self.allocator.create(ast.Expr);
            expr.* = .{ .array_literal = .{
                .token = open,
                .items = try items.toOwnedSlice(self.allocator),
            } };
            return expr;
        }

        if (self.match(.l_paren)) {
            const open = self.previous();
            var items: std.ArrayListUnmanaged(*ast.Expr) = .empty;
            errdefer {
                for (items.items) |item| item.destroy(self.allocator);
                items.deinit(self.allocator);
            }
            if (!self.check(.r_paren)) {
                const first = try self.parseExpr();
                items.append(self.allocator, first) catch |err| {
                    first.destroy(self.allocator);
                    return err;
                };
                if (!self.match(.comma)) {
                    _ = try self.expect(.r_paren, "expected `)` after expression");
                    items.deinit(self.allocator);
                    return first;
                }
                while (!self.check(.r_paren)) {
                    const item = try self.parseExpr();
                    items.append(self.allocator, item) catch |err| {
                        item.destroy(self.allocator);
                        return err;
                    };
                    if (!self.match(.comma)) break;
                }
            }
            _ = try self.expect(.r_paren, "expected `)` after tuple expression");
            const owned_items = try items.toOwnedSlice(self.allocator);
            errdefer {
                for (owned_items) |item| item.destroy(self.allocator);
                self.allocator.free(owned_items);
            }
            const expr = try self.allocator.create(ast.Expr);
            expr.* = .{ .array_literal = .{ .token = open, .items = owned_items } };
            return expr;
        }

        try self.diagnostic_context.emitToken(self.path, self.peek(), "expected expression", .{});
        return ParseError.ParseFailed;
    }

    fn parseLambdaExpr(self: *Parser, token: lexer.Token) ParseError!*ast.Expr {
        var params: std.ArrayListUnmanaged(ast.FunctionExprParam) = .empty;
        errdefer {
            for (params.items) |param| param.deinit(self.allocator);
            params.deinit(self.allocator);
        }

        if (!self.check(.pipe)) {
            while (true) {
                const name = try self.expect(.identifier, "expected lambda parameter name");
                const type_name = if (self.match(.colon))
                    try self.parseTypeName("expected lambda parameter type")
                else
                    null;
                try params.append(self.allocator, .{
                    .name = name.lexeme,
                    .type_name = type_name,
                    .name_token = name,
                });

                if (!self.match(.comma)) break;
            }
        }

        _ = try self.expect(.pipe, "expected `|` after lambda parameters");
        const return_type: ?ast.TypeName = if (self.match(.colon))
            try self.parseReturnTypeName("expected lambda return type")
        else
            null;
        errdefer if (return_type) |ty| ty.deinit(self.allocator);

        _ = try self.expect(.l_brace, "expected lambda body");
        const body = try self.parseBlockBody();
        errdefer {
            for (body) |stmt| stmt.deinit(self.allocator);
            self.allocator.free(body);
        }

        const expr = try self.allocator.create(ast.Expr);
        expr.* = .{ .function_expr = .{
            .calling_convention = .cyna,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .body = body,
            .token = token,
            .is_lambda = true,
        } };
        return expr;
    }

    fn parseFunctionExpr(self: *Parser, token: lexer.Token, calling_convention: ast.CallingConvention) ParseError!*ast.Expr {
        const params = try self.parseFunctionExprParams();
        errdefer {
            for (params) |param| param.deinit(self.allocator);
            self.allocator.free(params);
        }

        const return_type: ?ast.TypeName = if (self.match(.colon))
            try self.parseReturnTypeName("expected function expression return type")
        else
            null;
        errdefer if (return_type) |ty| ty.deinit(self.allocator);

        _ = try self.expect(.l_brace, "expected function expression body");
        const body = try self.parseBlockBody();
        errdefer {
            for (body) |stmt| stmt.deinit(self.allocator);
            self.allocator.free(body);
        }

        const expr = try self.allocator.create(ast.Expr);
        expr.* = .{ .function_expr = .{
            .calling_convention = calling_convention,
            .params = params,
            .return_type = return_type,
            .body = body,
            .token = token,
            .is_lambda = false,
        } };
        return expr;
    }

    const DecodedString = struct {
        text: []const u8,
        owns_text: bool,
    };

    fn parseStringLiteral(self: *Parser, token: lexer.Token) ParseError!DecodedString {
        const body = token.lexeme[1 .. token.lexeme.len - 1];
        if (std.mem.indexOfScalar(u8, body, '\\') == null) {
            return .{ .text = body, .owns_text = false };
        }

        var decoded: std.ArrayListUnmanaged(u8) = .empty;
        errdefer decoded.deinit(self.allocator);
        var i: usize = 0;
        while (i < body.len) {
            const ch = body[i];
            if (ch != '\\') {
                try decoded.append(self.allocator, ch);
                i += 1;
                continue;
            }
            if (i + 1 >= body.len) {
                try self.diagnostic_context.emitToken(self.path, token, "unterminated escape sequence in string literal", .{});
                return ParseError.ParseFailed;
            }
            const escaped = body[i + 1];
            try decoded.append(self.allocator, switch (escaped) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '"' => '"',
                '{' => '{',
                '}' => '}',
                else => escaped,
            });
            i += 2;
        }
        return .{ .text = try decoded.toOwnedSlice(self.allocator), .owns_text = true };
    }

    fn parseInterpolatedString(self: *Parser, token: lexer.Token) ParseError!ast.InterpolatedString {
        const body = token.lexeme[2 .. token.lexeme.len - 1];
        var parts: std.ArrayListUnmanaged(ast.InterpolatedStringPart) = .empty;
        errdefer {
            for (parts.items) |part| part.deinit(self.allocator);
            parts.deinit(self.allocator);
        }

        var literal = std.ArrayListUnmanaged(u8).empty;
        defer literal.deinit(self.allocator);

        var i: usize = 0;
        while (i < body.len) {
            const ch = body[i];
            if (ch == '\\') {
                if (i + 1 >= body.len) {
                    try self.diagnostic_context.emitToken(self.path, token, "unterminated escape sequence in interpolated string", .{});
                    return ParseError.ParseFailed;
                }
                const escaped = body[i + 1];
                try literal.append(self.allocator, switch (escaped) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    '{' => '{',
                    '}' => '}',
                    else => escaped,
                });
                i += 2;
                continue;
            }

            if (ch == '}') {
                try self.diagnostic_context.emitToken(self.path, token, "unescaped `}}` in interpolated string; use `\\}}` for a literal brace", .{});
                return ParseError.ParseFailed;
            }

            if (ch != '{') {
                try literal.append(self.allocator, ch);
                i += 1;
                continue;
            }

            if (literal.items.len != 0) {
                try parts.append(self.allocator, .{ .literal = try self.allocator.dupe(u8, literal.items) });
                literal.clearRetainingCapacity();
            }

            i += 1;
            const hole_start = i;
            while (i < body.len and body[i] != '}') : (i += 1) {}
            if (i >= body.len) {
                try self.diagnostic_context.emitToken(self.path, token, "unterminated interpolation expression", .{});
                return ParseError.ParseFailed;
            }
            const hole_text = std.mem.trim(u8, body[hole_start..i], " \t\r\n");
            if (hole_text.len == 0) {
                try self.diagnostic_context.emitToken(self.path, token, "empty interpolation expression", .{});
                return ParseError.ParseFailed;
            }
            try parts.append(self.allocator, .{ .hole = try self.parseInterpolationHole(token, hole_text) });
            i += 1;
        }

        if (literal.items.len != 0) {
            try parts.append(self.allocator, .{ .literal = try self.allocator.dupe(u8, literal.items) });
        }

        return .{
            .parts = try parts.toOwnedSlice(self.allocator),
            .token = token,
        };
    }

    fn parseInterpolationHole(self: *Parser, token: lexer.Token, text: []const u8) ParseError!ast.InterpolationHole {
        var path_text = text;
        var format: ast.InterpolationFormat = .direct;
        if (std.mem.indexOfScalar(u8, text, ':')) |colon| {
            path_text = std.mem.trim(u8, text[0..colon], " \t\r\n");
            const format_text = std.mem.trim(u8, text[colon + 1 ..], " \t\r\n");
            if (format_text.len != 1) {
                try self.diagnostic_context.emitToken(self.path, token, "interpolation format must be one of `d`, `x`, `X`, `b`, or `o`", .{});
                return ParseError.ParseFailed;
            }
            format = switch (format_text[0]) {
                'd' => .decimal,
                'x' => .hex_lower,
                'X' => .hex_upper,
                'b' => .binary,
                'o' => .octal,
                else => {
                    try self.diagnostic_context.emitToken(self.path, token, "unknown interpolation format `{s}`", .{format_text});
                    return ParseError.ParseFailed;
                },
            };
        }
        if (path_text.len == 0) {
            try self.diagnostic_context.emitToken(self.path, token, "empty interpolation expression", .{});
            return ParseError.ParseFailed;
        }

        var cursor: usize = 0;
        const base_text = parseInterpolationIdent(path_text, &cursor) orelse {
            try self.diagnostic_context.emitToken(self.path, token, "interpolation supports identifiers and field paths only; assign the expression to a local first", .{});
            return ParseError.ParseFailed;
        };
        var fields: std.ArrayListUnmanaged(ast.Name) = .empty;
        errdefer fields.deinit(self.allocator);
        while (cursor < path_text.len) {
            if (path_text[cursor] != '.') {
                try self.diagnostic_context.emitToken(self.path, token, "interpolation supports identifiers and field paths only; assign the expression to a local first", .{});
                return ParseError.ParseFailed;
            }
            cursor += 1;
            const field_text = parseInterpolationIdent(path_text, &cursor) orelse {
                try self.diagnostic_context.emitToken(self.path, token, "expected field name in interpolation path", .{});
                return ParseError.ParseFailed;
            };
            try fields.append(self.allocator, .{ .text = field_text, .token = token });
        }

        return .{
            .base = .{ .text = base_text, .token = token },
            .fields = try fields.toOwnedSlice(self.allocator),
            .format = format,
            .token = token,
        };
    }

    fn parseInterpolationIdent(text: []const u8, cursor: *usize) ?[]const u8 {
        if (cursor.* >= text.len or !isInterpolationIdentStart(text[cursor.*])) return null;
        const start = cursor.*;
        cursor.* += 1;
        while (cursor.* < text.len and isInterpolationIdentContinue(text[cursor.*])) {
            cursor.* += 1;
        }
        return text[start..cursor.*];
    }

    fn isInterpolationIdentStart(ch: u8) bool {
        return std.ascii.isAlphabetic(ch) or ch == '_';
    }

    fn isInterpolationIdentContinue(ch: u8) bool {
        return isInterpolationIdentStart(ch) or std.ascii.isDigit(ch);
    }

    fn parseArrayConstructItems(self: *Parser) ParseError![]*ast.Expr {
        var items: std.ArrayListUnmanaged(*ast.Expr) = .empty;
        errdefer {
            for (items.items) |item| item.destroy(self.allocator);
            items.deinit(self.allocator);
        }

        if (!self.check(.r_brace)) {
            while (true) {
                try items.append(self.allocator, try self.parseExpr());
                if (!self.match(.comma)) break;
            }
        }

        _ = try self.expect(.r_brace, "expected `}` after fixed array construction");
        return items.toOwnedSlice(self.allocator);
    }

    fn parseBracketSequenceItems(self: *Parser) ParseError![]*ast.Expr {
        var items: std.ArrayListUnmanaged(*ast.Expr) = .empty;
        errdefer {
            for (items.items) |item| item.destroy(self.allocator);
            items.deinit(self.allocator);
        }

        if (!self.check(.r_bracket)) {
            while (true) {
                try items.append(self.allocator, try self.parseExpr());
                if (!self.match(.comma)) break;
                if (self.check(.r_bracket)) break;
            }
        }

        _ = try self.expect(.r_bracket, "expected `]` after sequence construction");
        return items.toOwnedSlice(self.allocator);
    }

    fn parseNewExpr(self: *Parser, token: lexer.Token) ParseError!*ast.Expr {
        if (!self.match(.l_bracket)) {
            const type_token = try self.expect(.identifier, "expected type name after `new`");
            const type_args = try self.parseTypeArgsForName(type_token);
            errdefer {
                for (type_args) |arg| arg.deinit(self.allocator);
                self.allocator.free(type_args);
            }
            _ = try self.expect(.l_brace, "expected `{` after `new` type");
            const fields = try self.parseStructLiteralFields();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = .{ .new_owned = .{
                .type_name = type_token.lexeme,
                .type_args = type_args,
                .type_token = token,
                .fields = fields,
            } };
            return expr;
        }

        if (!self.match(.semicolon)) {
            try self.diagnostic_context.emitToken(self.path, token, "`new [size]T` was removed; use `[: expr]T`, `[: n] [a, b, c]`, or `[:]T [a, b, c]`", .{});
            return ParseError.ParseFailed;
        }
        try self.diagnostic_context.emitToken(self.path, token, "`new [; expr]T` was removed; use `[; expr]T`", .{});
        return ParseError.ParseFailed;
    }

    fn canStartTypeName(self: *Parser) bool {
        return switch (self.peek().tag) {
            .identifier, .amp, .question, .caret, .star, .l_bracket => true,
            else => false,
        };
    }

    fn parseStructLiteralFields(self: *Parser) ParseError![]ast.StructLiteralField {
        var fields: std.ArrayListUnmanaged(ast.StructLiteralField) = .empty;
        errdefer {
            for (fields.items) |field| field.value.destroy(self.allocator);
            fields.deinit(self.allocator);
        }

        if (!self.check(.r_brace)) {
            while (true) {
                const field_name = try self.expect(.identifier, "expected struct literal field name");
                _ = try self.expect(.colon, "expected `:` after struct literal field name");
                const value = try self.parseExpr();
                try fields.append(self.allocator, .{
                    .name = field_name.lexeme,
                    .name_token = field_name,
                    .value = value,
                });
                if (!self.match(.comma)) break;
                if (self.check(.r_brace)) break;
            }
        }

        _ = try self.expect(.r_brace, "expected `}` after struct literal");
        return fields.toOwnedSlice(self.allocator);
    }

    fn parseKeyedLiteralEntries(self: *Parser) ParseError![]ast.KeyedLiteralEntry {
        var entries: std.ArrayListUnmanaged(ast.KeyedLiteralEntry) = .empty;
        errdefer {
            for (entries.items) |entry| {
                entry.key.destroy(self.allocator);
                entry.value.destroy(self.allocator);
            }
            entries.deinit(self.allocator);
        }

        if (!self.check(.r_brace)) {
            while (true) {
                const key = try self.parseExpr();
                errdefer key.destroy(self.allocator);
                _ = try self.expect(.colon, "expected `:` after keyed literal key");
                const value = try self.parseExpr();
                errdefer value.destroy(self.allocator);
                try entries.append(self.allocator, .{
                    .key = key,
                    .value = value,
                });
                if (!self.match(.comma)) break;
                if (self.check(.r_brace)) break;
            }
        }

        _ = try self.expect(.r_brace, "expected `}` after keyed literal");
        return entries.toOwnedSlice(self.allocator);
    }

    fn parseTypeArgsForName(self: *Parser, token: lexer.Token) ParseError![]ast.TypeName {
        var args: std.ArrayListUnmanaged(ast.TypeName) = .empty;
        errdefer {
            for (args.items) |arg| arg.deinit(self.allocator);
            args.deinit(self.allocator);
        }

        if (!self.match(.less)) return args.toOwnedSlice(self.allocator);

        if (!typeAcceptsArgs(token.lexeme)) {
            try self.diagnostic_context.emitToken(self.path, token, "type `{s}` does not accept type arguments", .{token.lexeme});
            return ParseError.ParseFailed;
        }
        while (true) {
            const arg = try self.parseGenericArgument();
            args.append(self.allocator, arg) catch |err| {
                arg.deinit(self.allocator);
                return err;
            };
            if (!self.match(.comma)) break;
        }
        _ = try self.expect(.greater, "expected `>` after type arguments");
        return args.toOwnedSlice(self.allocator);
    }

    fn parseTypeArgs(self: *Parser) ParseError![]ast.TypeName {
        var args: std.ArrayListUnmanaged(ast.TypeName) = .empty;
        errdefer {
            for (args.items) |arg| arg.deinit(self.allocator);
            args.deinit(self.allocator);
        }

        _ = try self.expect(.less, "expected `<` before type arguments");
        while (true) {
            const arg = try self.parseGenericArgument();
            args.append(self.allocator, arg) catch |err| {
                arg.deinit(self.allocator);
                return err;
            };
            if (!self.match(.comma)) break;
        }
        _ = try self.expect(.greater, "expected `>` after type arguments");
        return args.toOwnedSlice(self.allocator);
    }

    fn parseGenericArgument(self: *Parser) ParseError!ast.TypeName {
        if (self.match(.int_lit)) {
            const token = self.previous();
            const value = std.fmt.parseInt(usize, token.lexeme, 10) catch {
                try self.diagnostic_context.emitToken(self.path, token, "invalid const generic argument `{s}`", .{token.lexeme});
                return ParseError.ParseFailed;
            };
            return .{
                .is_const_value_arg = true,
                .const_value = value,
                .name = token.lexeme,
                .args = try self.allocator.alloc(ast.TypeName, 0),
                .token = token,
            };
        }
        return self.parseTypeName("expected generic argument");
    }

    fn parseCallTypeArgsIfPresent(self: *Parser) ParseError![]ast.TypeName {
        if (!self.check(.less)) return self.allocator.alloc(ast.TypeName, 0);
        if (!self.callTypeArgsLeadIntoCall()) return self.allocator.alloc(ast.TypeName, 0);

        const saved_index = self.index;
        const args = self.parseTypeArgs() catch |err| {
            self.index = saved_index;
            return err;
        };
        if (!self.check(.l_paren)) {
            for (args) |arg| arg.deinit(self.allocator);
            self.allocator.free(args);
            self.index = saved_index;
            return self.allocator.alloc(ast.TypeName, 0);
        }
        return args;
    }

    fn callTypeArgsLeadIntoCall(self: *const Parser) bool {
        if (!self.check(.less)) return false;

        var depth: usize = 0;
        var i = self.index;
        while (i < self.tokens.len) : (i += 1) {
            switch (self.tokens[i].tag) {
                .less => depth += 1,
                .greater => {
                    if (depth == 0) return false;
                    depth -= 1;
                    if (depth == 0) {
                        return i + 1 < self.tokens.len and self.tokens[i + 1].tag == .l_paren;
                    }
                },
                .eof, .semicolon, .l_brace, .r_brace, .keyword_or, .keyword_and => return false,
                else => {},
            }
        }

        return false;
    }

    fn arrowCallableTypeAhead(self: *const Parser) bool {
        if (!self.check(.l_paren)) return false;

        var depth: usize = 0;
        var i = self.index;
        while (i < self.tokens.len) : (i += 1) {
            switch (self.tokens[i].tag) {
                .l_paren => depth += 1,
                .r_paren => {
                    if (depth == 0) return false;
                    depth -= 1;
                    if (depth == 0) {
                        return i + 1 < self.tokens.len and self.tokens[i + 1].tag == .fat_arrow;
                    }
                },
                .eof, .semicolon, .l_brace, .r_brace => return false,
                else => {},
            }
        }

        return false;
    }

    fn parseCallArgs(self: *Parser, args: *std.ArrayListUnmanaged(ast.CallArg)) ParseError!void {
        if (self.check(.r_paren)) return;

        while (true) {
            if (self.check(.identifier) and self.peekAhead(1).tag == .equal) {
                const name = self.advance();
                _ = try self.expect(.equal, "expected `=` after argument name");
                try args.append(self.allocator, .{
                    .value = try self.parseExpr(),
                    .name = name.lexeme,
                    .name_token = name,
                });
            } else {
                try args.append(self.allocator, .{ .value = try self.parseExpr() });
            }
            if (!self.match(.comma)) break;
        }
    }

    fn matchIdent(self: *Parser, name: []const u8) bool {
        if (!self.check(.identifier)) return false;
        if (!std.mem.eql(u8, self.peek().lexeme, name)) return false;
        self.index += 1;
        return true;
    }

    fn expectOwnedIdentifier(self: *Parser, message: []const u8) ParseError![]const u8 {
        const token = try self.expect(.identifier, message);
        return try self.allocator.dupe(u8, token.lexeme);
    }

    fn expect(self: *Parser, tag: lexer.TokenTag, message: []const u8) ParseError!lexer.Token {
        if (self.check(tag)) return self.advance();
        if (tag == .identifier and isKeywordToken(self.peek().tag)) {
            try self.diagnostic_context.emitToken(self.path, self.peek(), "reserved keyword `{s}` cannot be used as an identifier", .{self.peek().lexeme});
            return ParseError.ParseFailed;
        }
        try self.diagnostic_context.emitToken(self.path, self.peek(), "{s}", .{message});
        return ParseError.ParseFailed;
    }

    fn expectUnionCaseName(self: *Parser, message: []const u8) ParseError!lexer.Token {
        if (self.check(.keyword_none)) return self.advance();
        return self.expect(.identifier, message);
    }

    fn match(self: *Parser, tag: lexer.TokenTag) bool {
        if (!self.check(tag)) return false;
        _ = self.advance();
        return true;
    }

    fn check(self: *const Parser, tag: lexer.TokenTag) bool {
        return self.peek().tag == tag;
    }

    fn advance(self: *Parser) lexer.Token {
        const token = self.peek();
        if (token.tag != .eof) self.index += 1;
        return token;
    }

    fn peek(self: *const Parser) lexer.Token {
        return self.tokens[self.index];
    }

    fn previous(self: *const Parser) lexer.Token {
        return self.tokens[self.index - 1];
    }

    fn peekAhead(self: *const Parser, offset: usize) lexer.Token {
        const at = self.index + offset;
        if (at >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[at];
    }

    fn matchComparison(self: *Parser) ?ast.BinaryOp {
        if (self.match(.equal_equal)) return .eq;
        if (self.match(.bang_equal)) return .ne;
        if (self.match(.less)) return .lt;
        if (self.match(.less_equal)) return .le;
        if (self.match(.greater)) return .gt;
        if (self.match(.greater_equal)) return .ge;
        return null;
    }

    fn matchShift(self: *Parser) ?ast.BinaryOp {
        if (self.check(.less) and self.peekAhead(1).tag == .less) {
            self.index += 2;
            return .shl;
        }
        if (self.check(.greater) and self.peekAhead(1).tag == .greater) {
            self.index += 2;
            return .shr;
        }
        return null;
    }
};

fn isKeywordToken(tag: lexer.TokenTag) bool {
    return switch (tag) {
        .keyword_import, .keyword_module, .keyword_const, .keyword_var, .keyword_fn, .keyword_return, .keyword_unreachable, .keyword_if, .keyword_else, .keyword_while, .keyword_for, .keyword_continue, .keyword_break, .keyword_in, .keyword_switch, .keyword_case, .keyword_struct, .keyword_packed, .keyword_enum, .keyword_flags, .keyword_union, .keyword_protocol, .keyword_impl, .keyword_pub, .keyword_extern, .keyword_export, .keyword_test, .keyword_type, .keyword_comptime, .keyword_try, .keyword_catch, .keyword_defer, .keyword_drop, .keyword_new, .keyword_unchecked, .keyword_using, .keyword_alloc, .keyword_scoped, .keyword_asm, .keyword_none, .keyword_is, .keyword_as, .keyword_and, .keyword_or, .keyword_not, .keyword_true, .keyword_false => true,
        else => false,
    };
}

const ParsedIntegerLiteral = struct {
    value: i64,
    unsigned_value: ?u64 = null,
};

fn parseIntegerLiteral(allocator: std.mem.Allocator, lexeme: []const u8) NumericLiteralError!ParsedIntegerLiteral {
    const base: u8, const digits: []const u8 = if (std.mem.startsWith(u8, lexeme, "0x") or std.mem.startsWith(u8, lexeme, "0X")) .{ 16, lexeme[2..] } else if (std.mem.startsWith(u8, lexeme, "0b") or std.mem.startsWith(u8, lexeme, "0B")) .{ 2, lexeme[2..] } else if (std.mem.startsWith(u8, lexeme, "0o") or std.mem.startsWith(u8, lexeme, "0O")) .{ 8, lexeme[2..] } else .{ 10, lexeme };

    if (base == 10 and lexeme.len > 1 and lexeme[0] == '0') return NumericLiteralError.Invalid;
    if (!isWellFormedDigits(digits, base)) return NumericLiteralError.Invalid;

    const sanitized = stripSeparatorsAlloc(allocator, digits) catch return NumericLiteralError.Invalid;
    defer allocator.free(sanitized);

    const unsigned_value = std.fmt.parseInt(u64, sanitized, base) catch return NumericLiteralError.Invalid;
    if (unsigned_value <= @as(u64, @intCast(std.math.maxInt(i64)))) {
        return .{ .value = @intCast(unsigned_value) };
    }
    return .{
        .value = @as(i64, @bitCast(unsigned_value)),
        .unsigned_value = unsigned_value,
    };
}

fn negateIntegerLiteral(value: ParsedIntegerLiteral) NumericLiteralError!i64 {
    if (value.unsigned_value) |unsigned_value| {
        const min_magnitude = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
        if (unsigned_value == min_magnitude) return std.math.minInt(i64);
        return NumericLiteralError.Invalid;
    }
    return -value.value;
}

fn parseRuneLiteral(lexeme: []const u8) NumericLiteralError!u32 {
    if (lexeme.len < 2 or lexeme[0] != '\'' or lexeme[lexeme.len - 1] != '\'') return NumericLiteralError.Invalid;
    const body = lexeme[1 .. lexeme.len - 1];
    if (body.len == 0) return NumericLiteralError.Invalid;

    const value: u21 = if (body[0] == '\\') blk: {
        if (body.len < 2) return NumericLiteralError.Invalid;
        if (body[1] == 'u') {
            if (body.len < 5 or body[2] != '{' or body[body.len - 1] != '}') return NumericLiteralError.Invalid;
            const digits = body[3 .. body.len - 1];
            if (digits.len == 0 or digits.len > 6) return NumericLiteralError.Invalid;
            var scalar: u32 = 0;
            for (digits) |digit| {
                const nibble = digitValue(digit) orelse return NumericLiteralError.Invalid;
                if (nibble >= 16) return NumericLiteralError.Invalid;
                scalar = scalar * 16 + nibble;
                if (scalar > 0x10FFFF) return NumericLiteralError.Invalid;
            }
            break :blk @intCast(scalar);
        }
        if (body.len != 2) return NumericLiteralError.Invalid;
        break :blk switch (body[1]) {
            '0' => 0,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '\'' => '\'',
            '"' => '"',
            '\\' => '\\',
            else => return NumericLiteralError.Invalid,
        };
    } else blk: {
        const len = std.unicode.utf8ByteSequenceLength(body[0]) catch return NumericLiteralError.Invalid;
        if (len != body.len) return NumericLiteralError.Invalid;
        break :blk std.unicode.utf8Decode(body) catch return NumericLiteralError.Invalid;
    };

    if (!isUnicodeScalar(value)) return NumericLiteralError.Invalid;
    return @intCast(value);
}

fn isUnicodeScalar(value: u21) bool {
    return value <= 0x10FFFF and !(value >= 0xD800 and value <= 0xDFFF);
}

fn parseFloatLiteral(allocator: std.mem.Allocator, lexeme: []const u8) NumericLiteralError!f64 {
    const dot_index = std.mem.indexOfScalar(u8, lexeme, '.') orelse return NumericLiteralError.Invalid;
    const whole = lexeme[0..dot_index];
    const fraction = lexeme[dot_index + 1 ..];

    if (whole.len == 0 or fraction.len == 0) return NumericLiteralError.Invalid;
    if (whole.len > 1 and whole[0] == '0') return NumericLiteralError.Invalid;
    if (!isWellFormedDigits(whole, 10) or !isWellFormedDigits(fraction, 10)) return NumericLiteralError.Invalid;

    const sanitized = stripSeparatorsAlloc(allocator, lexeme) catch return NumericLiteralError.Invalid;
    defer allocator.free(sanitized);

    return std.fmt.parseFloat(f64, sanitized) catch NumericLiteralError.Invalid;
}

fn isWellFormedDigits(text: []const u8, base: u8) bool {
    if (text.len == 0) return false;
    if (text[0] == '_' or text[text.len - 1] == '_') return false;

    var prev_was_separator = false;
    for (text) |c| {
        if (c == '_') {
            if (prev_was_separator) return false;
            prev_was_separator = true;
            continue;
        }
        if (digitValue(c)) |value| {
            if (value >= base) return false;
        } else {
            return false;
        }
        prev_was_separator = false;
    }
    return true;
}

fn digitValue(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return 10 + (c - 'a');
    if (c >= 'A' and c <= 'F') return 10 + (c - 'A');
    return null;
}

fn stripSeparatorsAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, text.len);
    errdefer allocator.free(out);

    var index: usize = 0;
    for (text) |c| {
        if (c == '_') continue;
        out[index] = c;
        index += 1;
    }

    return allocator.realloc(out, index);
}

fn isTypeLikeName(name: []const u8) bool {
    return (name.len > 0 and std.ascii.isUpper(name[0])) or std.mem.eql(u8, name, "string");
}

fn typeAcceptsArgs(name: []const u8) bool {
    return std.mem.eql(u8, name, language_contracts.result_type_name) or
        isTypeLikeName(name);
}

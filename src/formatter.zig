//! Source-preserving token formatter. Parsing gates edits; comments and literal
//! bytes come from source spans rather than the semantic AST.
const std = @import("std");
const lexer = @import("compiler/lexer/lexer.zig");
const parser = @import("compiler/parser/parser.zig");
const diagnostics = @import("compiler/diagnostics.zig");
const loader = @import("compiler/loader.zig");
const sema = @import("compiler/sema/sema.zig");
const Tag = lexer.TokenTag;
const Token = lexer.Token;

pub fn format(allocator: std.mem.Allocator, path: []const u8, source: []const u8, context: *diagnostics.Context) ![]u8 {
    const formatted = try formatTokens(allocator, path, source, context);
    errdefer allocator.free(formatted);
    const slice_normalized = try normalizeSliceViews(allocator, path, formatted);
    defer if (slice_normalized) |bytes| allocator.free(bytes);
    const after_slices = slice_normalized orelse formatted;
    const index_normalized = try normalizeIndexCasts(allocator, path, after_slices);
    defer if (index_normalized) |bytes| allocator.free(bytes);
    const after_indexes = index_normalized orelse after_slices;
    const literal_normalized = try normalizeLiteralCasts(allocator, path, after_indexes);
    defer if (literal_normalized) |bytes| allocator.free(bytes);
    if (slice_normalized != null or index_normalized != null or literal_normalized != null) {
        const result = try formatTokens(allocator, path, literal_normalized orelse after_indexes, context);
        allocator.free(formatted);
        return result;
    }
    return formatted;
}

fn normalizeLiteralCasts(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, source, " as ") == null) return null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const tokens = try lexer.lexAll(scratch, source);
    var has_candidate = false;
    for (tokens, 0..) |token, index| {
        if (token.tag == .keyword_as and index > 0 and index + 1 < tokens.len and
            (tokens[index - 1].tag == .int_lit or tokens[index - 1].tag == .float_lit) and tokens[index + 1].tag == .identifier)
        {
            has_candidate = true;
            break;
        }
    }
    if (!has_candidate) return null;
    var normalizations: std.ArrayListUnmanaged(sema.IndexCastNormalization) = .empty;
    const options = sema.BuildOptions{ .literal_cast_normalizations = &normalizations };
    var root_module = path;
    if (loader.loadProgramWithRootSourceOptions(scratch, path, source, .{ .allow_test_root = true })) |loaded| {
        root_module = loaded.root_module_name;
        _ = sema.buildSirWithOptions(scratch, path, loaded.program, options) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
    } else |load_error| {
        if (load_error == error.OutOfMemory) return load_error;
        var diagnostic_context = diagnostics.Context.discarded();
        const program = parser.parseWithDiagnostics(scratch, path, source, tokens, &diagnostic_context) catch return null;
        root_module = "";
        _ = sema.buildSirWithOptions(scratch, path, program, options) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
    }
    std.mem.sort(sema.IndexCastNormalization, normalizations.items, {}, struct {
        fn lessThan(_: void, left: sema.IndexCastNormalization, right: sema.IndexCastNormalization) bool {
            return left.cast_offset < right.cast_offset;
        }
    }.lessThan);
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);
    var offset: usize = 0;
    for (normalizations.items) |normalization| {
        if (!std.mem.eql(u8, normalization.module_name, root_module) or normalization.cast_offset < offset or
            normalization.target_end_offset > source.len or
            std.mem.indexOf(u8, source[normalization.cast_offset..normalization.target_end_offset], "//") != null or
            std.mem.indexOf(u8, source[normalization.cast_offset..normalization.target_end_offset], "/*") != null) continue;
        var collapsed_parens = false;
        for (tokens, 0..) |token, index| {
            if (token.offset != normalization.cast_offset or token.tag != .keyword_as or index < 2 or index + 2 >= tokens.len) continue;
            const literal = tokens[index - 1];
            const left = tokens[index - 2];
            const right = tokens[index + 2];
            const call_paren = if (index >= 3) switch (tokens[index - 3].tag) {
                .identifier, .r_paren, .r_bracket => true,
                else => false,
            } else false;
            if (call_paren or left.tag != .l_paren or right.tag != .r_paren or
                tokens[index + 1].end_offset != normalization.target_end_offset or left.offset < offset or
                std.mem.indexOf(u8, source[left.end_offset..literal.offset], "//") != null or
                std.mem.indexOf(u8, source[left.end_offset..literal.offset], "/*") != null or
                std.mem.indexOf(u8, source[normalization.target_end_offset..right.offset], "//") != null or
                std.mem.indexOf(u8, source[normalization.target_end_offset..right.offset], "/*") != null) break;
            try result.appendSlice(allocator, source[offset..left.offset]);
            try result.appendSlice(allocator, source[literal.offset..literal.end_offset]);
            offset = right.end_offset;
            collapsed_parens = true;
            break;
        }
        if (!collapsed_parens) {
            try result.appendSlice(allocator, source[offset..normalization.cast_offset]);
            offset = normalization.target_end_offset;
        }
    }
    if (offset == 0) return null;
    try result.appendSlice(allocator, source[offset..]);
    return try result.toOwnedSlice(allocator);
}

fn normalizeIndexCasts(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, source, " as ") == null) return null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const tokens = try lexer.lexAll(scratch, source);
    var has_candidate = false;
    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_as or index + 2 >= tokens.len or tokens[index + 1].tag != .identifier) continue;
        if (tokens[index + 2].tag == .r_bracket or
            (tokens[index + 2].tag == .r_paren and index + 3 < tokens.len and tokens[index + 3].tag == .r_bracket))
        {
            has_candidate = true;
            break;
        }
    }
    if (!has_candidate) return null;
    var normalizations: std.ArrayListUnmanaged(sema.IndexCastNormalization) = .empty;
    const options = sema.BuildOptions{ .index_cast_normalizations = &normalizations };
    var root_module = path;
    if (loader.loadProgramWithRootSourceOptions(scratch, path, source, .{ .allow_test_root = true })) |loaded| {
        root_module = loaded.root_module_name;
        _ = sema.buildSirWithOptions(scratch, path, loaded.program, options) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
    } else |load_error| {
        if (load_error == error.OutOfMemory) return load_error;
        var diagnostic_context = diagnostics.Context.discarded();
        const program = parser.parseWithDiagnostics(scratch, path, source, tokens, &diagnostic_context) catch return null;
        root_module = "";
        _ = sema.buildSirWithOptions(scratch, path, program, options) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
    }
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);
    std.mem.sort(sema.IndexCastNormalization, normalizations.items, {}, struct {
        fn lessThan(_: void, left: sema.IndexCastNormalization, right: sema.IndexCastNormalization) bool {
            return left.cast_offset < right.cast_offset;
        }
    }.lessThan);
    var offset: usize = 0;
    for (normalizations.items) |normalization| {
        if (!std.mem.eql(u8, normalization.module_name, root_module) or normalization.cast_offset < offset or
            normalization.target_end_offset > source.len or
            std.mem.indexOf(u8, source[normalization.cast_offset..normalization.target_end_offset], "//") != null or
            std.mem.indexOf(u8, source[normalization.cast_offset..normalization.target_end_offset], "/*") != null) continue;
        try result.appendSlice(allocator, source[offset..normalization.cast_offset]);
        offset = normalization.target_end_offset;
    }
    if (offset == 0) return null;
    try result.appendSlice(allocator, source[offset..]);
    return try result.toOwnedSlice(allocator);
}

fn normalizeSliceViews(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !?[]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const tokens = try lexer.lexAll(scratch, source);
    var has_candidates = false;
    for (tokens, 0..) |token, index| {
        if (token.tag == .dot and index + 3 < tokens.len and tokens[index + 1].tag == .identifier and
            tokens[index + 2].tag == .l_paren and tokens[index + 3].tag == .r_paren) has_candidates = true;
    }
    if (!has_candidates) return null;
    var normalizations: std.ArrayListUnmanaged(sema.SliceViewNormalization) = .empty;
    const options = sema.BuildOptions{ .slice_view_normalizations = &normalizations };
    var root_module = path;
    if (loader.loadProgramWithRootSourceOptions(scratch, path, source, .{ .allow_test_root = true })) |loaded| {
        root_module = loaded.root_module_name;
        _ = sema.buildSirWithOptions(scratch, path, loaded.program, options) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
    } else |load_error| {
        if (load_error == error.OutOfMemory) return load_error;
        var diagnostic_context = diagnostics.Context.discarded();
        const program = parser.parseWithDiagnostics(scratch, path, source, tokens, &diagnostic_context) catch return null;
        root_module = "";
        _ = sema.buildSirWithOptions(scratch, path, program, options) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
    }
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);
    var offset: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.tag != .dot or index + 3 >= tokens.len or tokens[index + 1].tag != .identifier or
            tokens[index + 2].tag != .l_paren or tokens[index + 3].tag != .r_paren) continue;
        var proven = false;
        for (normalizations.items) |normalization| {
            if (normalization.method_offset == tokens[index + 1].offset and std.mem.eql(u8, normalization.module_name, root_module)) {
                proven = true;
                break;
            }
        }
        if (!proven or std.mem.indexOf(u8, source[token.offset..tokens[index + 3].end_offset], "//") != null) continue;
        try result.appendSlice(allocator, source[offset..token.offset]);
        try result.appendSlice(allocator, "[..]");
        offset = tokens[index + 3].end_offset;
    }
    if (offset == 0) return null;
    try result.appendSlice(allocator, source[offset..]);
    return try result.toOwnedSlice(allocator);
}

fn formatTokens(allocator: std.mem.Allocator, path: []const u8, source: []const u8, context: *diagnostics.Context) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const tokens = try lexer.lexAll(scratch, source);
    _ = try parser.parseWithDiagnostics(scratch, path, source, tokens, context);

    const omitted = try scratch.alloc(bool, tokens.len);
    @memset(omitted, false);
    // Only a directly annotated, simple named type and a complete initializer.
    // Do not rewrite optional/coercion contexts or constructors in larger expressions.
    for (tokens, 0..) |token, i| {
        if (token.tag != .keyword_const and token.tag != .keyword_var) continue;
        if (i + 6 >= tokens.len) continue;
        if (tokens[i + 1].tag != .identifier or tokens[i + 2].tag != .colon or
            tokens[i + 3].tag != .identifier or tokens[i + 4].tag != .equal or
            tokens[i + 5].tag != .identifier or tokens[i + 6].tag != .l_brace) continue;
        if (!std.mem.eql(u8, tokens[i + 3].lexeme, tokens[i + 5].lexeme)) continue;
        var depth: usize = 0;
        var end = i + 6;
        while (end < tokens.len) : (end += 1) {
            if (tokens[end].tag == .l_brace) depth += 1;
            if (tokens[end].tag == .r_brace) {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (end + 1 < tokens.len and tokens[end + 1].tag == .semicolon) omitted[i + 5] = true;
    }
    omitRedundantDenseReturnTypes(tokens, source, omitted);

    var writer = Writer{ .allocator = allocator };
    errdefer writer.output.deinit(allocator);
    var stack: std.ArrayListUnmanaged(Frame) = .empty;
    defer stack.deinit(scratch);
    var previous: ?Token = null;
    var previous_unary = false;
    var previous_import_close = false;
    var angle_depth: usize = 0;
    var offset: usize = 0;
    for (tokens, 0..) |token, i| {
        // Even an omitted token's surrounding comments must survive.
        const gap = source[offset..token.offset];
        const has_comment = std.mem.indexOf(u8, gap, "//") != null;
        if (has_comment) try writer.comments(gap);
        offset = token.end_offset;
        if (omitted[i]) continue;
        if (token.tag == .eof) break;
        var next_index = i + 1;
        while (next_index < tokens.len and omitted[next_index]) : (next_index += 1) {}
        const next: Tag = if (next_index < tokens.len) tokens[next_index].tag else .eof;
        const prev: Tag = if (previous) |p| p.tag else .eof;
        const gap_lines = std.mem.count(u8, gap, "\n");

        var closing_import = false;
        if (token.tag == .r_brace or token.tag == .r_paren or token.tag == .r_bracket) {
            if (stack.items.len == 0) return error.InvalidDelimiter;
            const frame = stack.pop().?;
            closing_import = frame.is_import;
            if (frame.indented) {
                writer.indent -= 1;
                try writer.newline();
            }
        }
        if (!has_comment and previous != null) {
            const after_close = prev == .r_brace and !previous_import_close and switch (token.tag) {
                .semicolon, .comma, .r_paren, .r_bracket, .dot, .l_paren, .l_bracket, .keyword_else => false,
                else => !isOperator(token.tag),
            };
            if (prev == .l_brace and token.tag != .r_brace and !(stack.items.len > 0 and stack.items[stack.items.len - 1].is_import and !stack.items[stack.items.len - 1].indented)) {
                try writer.newline();
            } else if (prev == .semicolon and token.tag != .r_bracket and (stack.items.len == 0 or stack.items[stack.items.len - 1].tag == .l_brace)) {
                try writer.newline();
            } else if (prev == .comma and angle_depth == 0 and stack.items.len > 0 and stack.items[stack.items.len - 1].tag == .l_brace and !(stack.items[stack.items.len - 1].is_import and !stack.items[stack.items.len - 1].indented)) {
                try writer.newline();
            } else if (after_close) {
                try writer.newline();
            } else if (gap_lines > 0 and token.tag != .l_brace and token.tag != .keyword_else and
                token.tag != .semicolon and token.tag != .comma and token.tag != .r_brace and
                token.tag != .r_paren and token.tag != .r_bracket)
            {
                try writer.newline();
            }
            if (gap_lines > 1 and writer.atLineStart()) try writer.blankLine();
        }
        const unary = isPrefix(token.tag) and !endsExpression(prev) and !(token.tag == .bang and prev == .keyword_as);
        const from_dot = token.tag == .dot and previous != null and previous.?.tag == .identifier and std.mem.eql(u8, previous.?.lexeme, "from");
        if (closing_import and !writer.atLineStart()) try writer.space();
        if (!writer.atLineStart() and (from_dot or needsSpace(prev, token.tag, previous_unary, gap))) try writer.space();
        try writer.write(source[token.offset..token.end_offset]);

        if (token.tag == .l_brace or token.tag == .l_paren or token.tag == .l_bracket) {
            // Braces use one field/statement per line; preserve multiline lists
            // and parameter lists without forcing short lists to expand.
            const is_import = token.tag == .l_brace and prev == .keyword_import;
            const indented = if (is_import)
                importHasNewline(source, tokens, i)
            else if (token.tag == .l_brace)
                next != .r_brace or std.mem.indexOf(u8, source[token.end_offset..tokens[next_index].offset], "//") != null or
                    std.mem.indexOfScalar(u8, source[token.end_offset..tokens[next_index].offset], '\n') != null
            else blk: {
                var nesting: usize = 1;
                var j = i + 1;
                var end_offset = token.end_offset;
                var multiline = false;
                while (j < tokens.len) : (j += 1) {
                    const candidate = tokens[j];
                    if (nesting == 1 and std.mem.indexOfScalar(u8, source[end_offset..candidate.offset], '\n') != null) multiline = true;
                    switch (candidate.tag) {
                        .l_paren, .l_bracket, .l_brace => nesting += 1,
                        .r_paren, .r_bracket, .r_brace => {
                            nesting -= 1;
                            if (nesting == 0) break;
                        },
                        else => {},
                    }
                    end_offset = candidate.end_offset;
                }
                break :blk multiline;
            };
            try stack.append(scratch, .{ .tag = token.tag, .indented = indented, .is_import = is_import });
            if (indented) writer.indent += 1;
        }
        if (token.tag == .less and prev == .identifier and gap.len == 0 and hasGenericClose(tokens, i)) angle_depth += 1;
        if (token.tag == .greater and angle_depth > 0) angle_depth -= 1;
        previous = token;
        previous_unary = unary;
        previous_import_close = closing_import;
    }
    // Validate the result as an additional guard before publishing any edit.
    try writer.newline();
    const result = try writer.output.toOwnedSlice(allocator);
    errdefer allocator.free(result);
    const formatted_tokens = try lexer.lexAll(scratch, result);
    _ = try parser.parse(scratch, path, result, formatted_tokens);
    // Formatting may change trivia and the selected constructor token only.
    var original_index: usize = 0;
    for (formatted_tokens) |token| {
        while (original_index < tokens.len and omitted[original_index]) : (original_index += 1) {}
        if (original_index >= tokens.len) return error.TokenMismatch;
        const original = tokens[original_index];
        if (token.tag != original.tag or !std.mem.eql(u8, token.lexeme, original.lexeme)) return error.TokenMismatch;
        original_index += 1;
    }
    if (original_index != tokens.len) return error.TokenMismatch;
    return result;
}

fn omitRedundantDenseReturnTypes(tokens: []const Token, source: []const u8, omitted: []bool) void {
    for (tokens, 0..) |token, i| {
        if (token.tag != .keyword_fn) continue;
        var open = i + 1;
        while (open < tokens.len and tokens[open].tag != .l_paren and tokens[open].tag != .l_brace and tokens[open].tag != .eof) : (open += 1) {}
        if (open >= tokens.len or tokens[open].tag != .l_paren) continue;
        var paren_depth: usize = 1;
        var close = open + 1;
        while (close < tokens.len and paren_depth > 0) : (close += 1) {
            if (tokens[close].tag == .l_paren) paren_depth += 1;
            if (tokens[close].tag == .r_paren) paren_depth -= 1;
        }
        if (paren_depth != 0 or close + 5 >= tokens.len) continue;
        if (tokens[close].tag != .colon or tokens[close + 1].tag != .l_bracket or
            tokens[close + 2].tag != .colon or tokens[close + 3].tag != .r_bracket or
            tokens[close + 4].tag != .identifier or tokens[close + 5].tag != .l_brace) continue;
        const item_type = tokens[close + 4].lexeme;
        var brace_depth: usize = 1;
        var j = close + 6;
        while (j < tokens.len and brace_depth > 0) : (j += 1) {
            if (tokens[j].tag == .l_brace) brace_depth += 1;
            if (tokens[j].tag == .r_brace) brace_depth -= 1;
            if (brace_depth != 1 or tokens[j].tag != .keyword_return or j + 5 >= tokens.len) continue;
            if (tokens[j + 1].tag != .l_bracket or tokens[j + 2].tag != .colon or
                tokens[j + 3].tag != .r_bracket or tokens[j + 4].tag != .identifier or
                tokens[j + 5].tag != .l_bracket or
                !std.mem.eql(u8, tokens[j + 4].lexeme, item_type)) continue;
            const prefix = source[tokens[j].end_offset..tokens[j + 5].offset];
            if (std.mem.indexOf(u8, prefix, "//") != null or std.mem.indexOf(u8, prefix, "/*") != null) continue;
            @memset(omitted[j + 1 .. j + 5], true);
        }
    }
}

fn hasGenericClose(tokens: []const Token, open: usize) bool {
    var depth: usize = 1;
    var i = open + 1;
    while (i < tokens.len) : (i += 1) {
        switch (tokens[i].tag) {
            .less => depth += 1,
            .greater => {
                depth -= 1;
                if (depth == 0) return true;
            },
            .equal, .semicolon, .l_brace, .r_brace, .eof => return false,
            else => {},
        }
    }
    return false;
}

const Frame = struct { tag: Tag, indented: bool, is_import: bool = false };

fn importHasNewline(source: []const u8, tokens: []const Token, open: usize) bool {
    var depth: usize = 1;
    var i = open + 1;
    while (i < tokens.len) : (i += 1) {
        if (tokens[i].tag == .l_brace) depth += 1;
        if (tokens[i].tag == .r_brace) {
            depth -= 1;
            if (depth == 0) return std.mem.indexOfScalar(u8, source[tokens[open].end_offset..tokens[i].offset], '\n') != null;
        }
    }
    return false;
}

const Writer = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayListUnmanaged(u8) = .empty,
    indent: usize = 0,

    fn atLineStart(self: *const Writer) bool {
        return self.output.items.len == 0 or self.output.items[self.output.items.len - 1] == '\n';
    }
    fn write(self: *Writer, bytes: []const u8) !void {
        if (self.atLineStart()) try self.output.appendNTimes(self.allocator, ' ', self.indent * 4);
        try self.output.appendSlice(self.allocator, bytes);
    }
    fn space(self: *Writer) !void {
        if (!self.atLineStart() and self.output.items[self.output.items.len - 1] != ' ') try self.output.append(self.allocator, ' ');
    }
    fn newline(self: *Writer) !void {
        while (self.output.items.len > 0 and self.output.items[self.output.items.len - 1] == ' ') self.output.items.len -= 1;
        if (!self.atLineStart()) try self.output.append(self.allocator, '\n');
    }
    fn blankLine(self: *Writer) !void {
        const items = self.output.items;
        if (items.len > 0 and (items.len < 2 or items[items.len - 2] != '\n')) try self.output.append(self.allocator, '\n');
    }
    fn comments(self: *Writer, gap: []const u8) !void {
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, gap, cursor, "//")) |start| {
            const preceding_lines = std.mem.count(u8, gap[cursor..start], "\n");
            if (preceding_lines > 0) {
                try self.newline();
                if (preceding_lines > 1) try self.blankLine();
            } else try self.space();
            const end = std.mem.indexOfScalarPos(u8, gap, start, '\n') orelse gap.len;
            try self.write(std.mem.trimEnd(u8, gap[start..end], " \t\r"));
            try self.newline();
            cursor = end;
        }
        if (std.mem.count(u8, gap[cursor..], "\n") > 1) try self.blankLine();
    }
};

fn endsExpression(tag: Tag) bool {
    return switch (tag) {
        .identifier, .int_lit, .float_lit, .rune_lit, .string_lit, .interpolated_string_lit, .keyword_true, .keyword_false, .keyword_none, .r_paren, .r_bracket, .r_brace => true,
        else => false,
    };
}

fn isPrefix(tag: Tag) bool {
    return switch (tag) {
        .amp, .caret, .star, .minus, .bang, .tilde => true,
        else => false,
    };
}

fn isOperator(tag: Tag) bool {
    return switch (tag) {
        .equal, .equal_equal, .bang_equal, .plus, .plus_percent, .minus, .minus_percent, .star, .star_percent, .slash, .percent, .amp, .pipe, .caret, .less, .greater, .less_equal, .greater_equal, .fat_arrow, .keyword_and, .keyword_or => true,
        else => false,
    };
}

fn needsSpace(prev: Tag, current: Tag, previous_unary: bool, gap: []const u8) bool {
    if (current == .dot) return !endsExpression(prev) and prev != .l_paren and prev != .l_bracket;
    if (current == .colon or current == .semicolon or current == .comma or current == .dot_dot or
        current == .r_paren or current == .r_bracket or current == .r_brace) return false;
    if (prev == .at) return current == .keyword_const or current == .keyword_var;
    if (prev == .dot or prev == .dot_dot or prev == .l_paren or prev == .l_bracket) return false;
    if (prev == .l_brace) return current != .r_brace;
    if (current == .l_brace) return true;
    if (prev == .colon or prev == .comma or prev == .semicolon) return true;
    // Generic angles and type suffixes share tokens with operators. Retain their
    // original adjacency until the formatter has a full concrete syntax model.
    if (prev == .less or prev == .greater or current == .less or current == .greater or
        prev == .question or current == .question or prev == .star_star or current == .star_star)
        return gap.len > 0;
    if (previous_unary) return false;
    if (current == .l_paren) return switch (prev) {
        .identifier, .keyword_asm, .r_paren, .r_bracket, .greater => false,
        else => true,
    };
    if (current == .l_bracket) return switch (prev) {
        .identifier, .r_paren, .r_bracket => false,
        else => true,
    };
    if (isOperator(prev) or isOperator(current)) return true;
    if (current == .bang) return prev != .keyword_as;
    if (prev == .bang) return !previous_unary;
    if (current == .amp or current == .caret or current == .tilde) return true;
    // Keep adjacent type constructors such as []const and pointer qualifiers tight.
    if (prev == .r_bracket) return gap.len > 0;
    return true;
}

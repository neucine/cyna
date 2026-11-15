const std = @import("std");
const token_defs = @import("token.zig");

pub const TokenTag = token_defs.TokenTag;
pub const Token = token_defs.Token;

pub const LexerError = error{
    UnexpectedCharacter,
    InvalidIdentifier,
    UnterminatedIdentifier,
    UnterminatedString,
    UnterminatedRune,
};

pub fn lexAll(allocator: std.mem.Allocator, source: []const u8) ![]Token {
    var lx = Lexer.init(source);
    var tokens: std.ArrayListUnmanaged(Token) = .empty;
    errdefer tokens.deinit(allocator);

    while (true) {
        const token = try lx.next();
        try tokens.append(allocator, token);
        if (token.tag == .eof) break;
    }

    return tokens.toOwnedSlice(allocator);
}

const Lexer = struct {
    source: []const u8,
    index: usize,
    line: usize,
    column: usize,

    fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .index = 0,
            .line = 1,
            .column = 1,
        };
    }

    fn next(self: *Lexer) LexerError!Token {
        self.skipWhitespaceAndComments();

        const start = self.index;
        const line = self.line;
        const column = self.column;

        if (self.peek() == null) {
            return .{
                .tag = .eof,
                .lexeme = self.source[start..start],
                .offset = start,
                .end_offset = start,
                .line = line,
                .column = column,
                .end_column = column,
            };
        }

        const c = self.advance().?;

        if (isIdentStart(c)) {
            while (self.peek()) |p| {
                if (!isIdentContinue(p)) break;
                _ = self.advance();
            }
            const text = self.source[start..self.index];
            return .{
                .tag = keywordTag(text),
                .lexeme = text,
                .offset = start,
                .end_offset = self.index,
                .line = line,
                .column = column,
                .end_column = self.column,
            };
        }

        if (std.ascii.isDigit(c)) {
            if (c == '0') {
                if (self.peek()) |p| {
                    if (p == 'x' or p == 'X' or p == 'b' or p == 'B' or p == 'o' or p == 'O') {
                        _ = self.advance();
                        while (self.peek()) |digit| {
                            if (!isPrefixedIntContinue(digit)) break;
                            _ = self.advance();
                        }
                        return .{
                            .tag = .int_lit,
                            .lexeme = self.source[start..self.index],
                            .offset = start,
                            .end_offset = self.index,
                            .line = line,
                            .column = column,
                            .end_column = self.column,
                        };
                    }
                }
            }

            while (self.peek()) |p| {
                if (!isDecimalDigitOrSeparator(p)) break;
                _ = self.advance();
            }
            if (!(start > 0 and self.source[start - 1] == '.') and
                self.peek() == '.' and self.peekNext() != null and isDecimalDigitOrSeparator(self.peekNext().?))
            {
                _ = self.advance();
                while (self.peek()) |p| {
                    if (!isDecimalDigitOrSeparator(p)) break;
                    _ = self.advance();
                }
                return .{
                    .tag = .float_lit,
                    .lexeme = self.source[start..self.index],
                    .offset = start,
                    .end_offset = self.index,
                    .line = line,
                    .column = column,
                    .end_column = self.column,
                };
            }
            return .{
                .tag = .int_lit,
                .lexeme = self.source[start..self.index],
                .offset = start,
                .end_offset = self.index,
                .line = line,
                .column = column,
                .end_column = self.column,
            };
        }

        if (c == '$' and self.peek() == '"') {
            _ = self.advance();
            return self.lexStringLiteral(start, line, column, .interpolated_string_lit);
        }

        if (c == '`') {
            return self.lexEscapedIdentifier(start, line, column);
        }

        if (c == '"') {
            return self.lexStringLiteral(start, line, column, .string_lit);
        }

        if (c == '\'') {
            return self.lexRuneLiteral(start, line, column);
        }

        const tag: TokenTag = switch (c) {
            '(' => .l_paren,
            ')' => .r_paren,
            '{' => .l_brace,
            '}' => .r_brace,
            '[' => .l_bracket,
            ']' => .r_bracket,
            ':' => .colon,
            ';' => .semicolon,
            ',' => .comma,
            '.' => if (self.matchChar('.')) .dot_dot else .dot,
            '=' => if (self.matchChar('=')) .equal_equal else if (self.matchChar('>')) .fat_arrow else .equal,
            '+' => if (self.matchChar('%')) .plus_percent else .plus,
            '-' => if (self.matchChar('%')) .minus_percent else .minus,
            '*' => if (self.matchChar('*')) .star_star else if (self.matchChar('%')) .star_percent else .star,
            '/' => .slash,
            '%' => .percent,
            '&' => .amp,
            '|' => .pipe,
            '!' => if (self.matchChar('=')) .bang_equal else .bang,
            '?' => .question,
            '^' => .caret,
            '~' => .tilde,
            '@' => .at,
            '<' => if (self.matchChar('=')) .less_equal else .less,
            '>' => if (self.matchChar('=')) .greater_equal else .greater,
            else => return LexerError.UnexpectedCharacter,
        };

        return .{
            .tag = tag,
            .lexeme = self.source[start..self.index],
            .offset = start,
            .end_offset = self.index,
            .line = line,
            .column = column,
            .end_column = self.column,
        };
    }

    fn lexEscapedIdentifier(self: *Lexer, start: usize, line: usize, column: usize) LexerError!Token {
        const content_start = self.index;
        while (self.peek()) |p| {
            if (p == '`') {
                const content_end = self.index;
                _ = self.advance();
                if (content_end == content_start) return LexerError.InvalidIdentifier;
                return .{
                    .tag = .identifier,
                    .lexeme = self.source[content_start..content_end],
                    .offset = start,
                    .end_offset = self.index,
                    .line = line,
                    .column = column,
                    .end_column = self.column,
                };
            }
            if (!isEscapedIdentContinue(p)) return LexerError.InvalidIdentifier;
            _ = self.advance();
        }
        return LexerError.UnterminatedIdentifier;
    }

    fn lexStringLiteral(self: *Lexer, start: usize, line: usize, column: usize, tag: TokenTag) LexerError!Token {
        while (self.peek()) |p| {
            if (p == '\\') {
                _ = self.advance();
                if (self.peek() == null or self.peek() == '\n') return LexerError.UnterminatedString;
                _ = self.advance();
                continue;
            }
            if (p == '"') {
                _ = self.advance();
                return .{
                    .tag = tag,
                    .lexeme = self.source[start..self.index],
                    .offset = start,
                    .end_offset = self.index,
                    .line = line,
                    .column = column,
                    .end_column = self.column,
                };
            }
            if (p == '\n') return LexerError.UnterminatedString;
            _ = self.advance();
        }
        return LexerError.UnterminatedString;
    }

    fn lexRuneLiteral(self: *Lexer, start: usize, line: usize, column: usize) LexerError!Token {
        while (self.peek()) |p| {
            if (p == '\\') {
                _ = self.advance();
                if (self.peek() == null or self.peek() == '\n') return LexerError.UnterminatedRune;
                _ = self.advance();
                continue;
            }
            if (p == '\'') {
                _ = self.advance();
                return .{
                    .tag = .rune_lit,
                    .lexeme = self.source[start..self.index],
                    .offset = start,
                    .end_offset = self.index,
                    .line = line,
                    .column = column,
                    .end_column = self.column,
                };
            }
            if (p == '\n') return LexerError.UnterminatedRune;
            _ = self.advance();
        }
        return LexerError.UnterminatedRune;
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.peek()) |c| {
            if (std.ascii.isWhitespace(c)) {
                _ = self.advance();
                continue;
            }

            if (c == '/' and self.peekNext() == '/') {
                while (self.peek()) |p| {
                    _ = self.advance();
                    if (p == '\n') break;
                }
                continue;
            }

            break;
        }
    }

    fn peek(self: *const Lexer) ?u8 {
        if (self.index >= self.source.len) return null;
        return self.source[self.index];
    }

    fn peekNext(self: *const Lexer) ?u8 {
        if (self.index + 1 >= self.source.len) return null;
        return self.source[self.index + 1];
    }

    fn advance(self: *Lexer) ?u8 {
        if (self.index >= self.source.len) return null;
        const c = self.source[self.index];
        self.index += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return c;
    }

    fn matchChar(self: *Lexer, expected: u8) bool {
        if (self.peek() != expected) return false;
        _ = self.advance();
        return true;
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

fn isEscapedIdentContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn isDecimalDigitOrSeparator(c: u8) bool {
    return std.ascii.isDigit(c) or c == '_';
}

fn isPrefixedIntContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn keywordTag(text: []const u8) TokenTag {
    if (std.mem.eql(u8, text, "import")) return .keyword_import;
    if (std.mem.eql(u8, text, "module")) return .keyword_module;
    if (std.mem.eql(u8, text, "const")) return .keyword_const;
    if (std.mem.eql(u8, text, "var")) return .keyword_var;
    if (std.mem.eql(u8, text, "fn")) return .keyword_fn;
    if (std.mem.eql(u8, text, "return")) return .keyword_return;
    if (std.mem.eql(u8, text, "unreachable")) return .keyword_unreachable;
    if (std.mem.eql(u8, text, "yield")) return .keyword_yield;
    if (std.mem.eql(u8, text, "if")) return .keyword_if;
    if (std.mem.eql(u8, text, "else")) return .keyword_else;
    if (std.mem.eql(u8, text, "while")) return .keyword_while;
    if (std.mem.eql(u8, text, "for")) return .keyword_for;
    if (std.mem.eql(u8, text, "continue")) return .keyword_continue;
    if (std.mem.eql(u8, text, "break")) return .keyword_break;
    if (std.mem.eql(u8, text, "in")) return .keyword_in;
    if (std.mem.eql(u8, text, "switch")) return .keyword_switch;
    if (std.mem.eql(u8, text, "case")) return .keyword_case;
    if (std.mem.eql(u8, text, "struct")) return .keyword_struct;
    if (std.mem.eql(u8, text, "packed")) return .keyword_packed;
    if (std.mem.eql(u8, text, "enum")) return .keyword_enum;
    if (std.mem.eql(u8, text, "flags")) return .keyword_flags;
    if (std.mem.eql(u8, text, "union")) return .keyword_union;
    if (std.mem.eql(u8, text, "protocol")) return .keyword_protocol;
    if (std.mem.eql(u8, text, "impl")) return .keyword_impl;
    if (std.mem.eql(u8, text, "pub")) return .keyword_pub;
    if (std.mem.eql(u8, text, "extern")) return .keyword_extern;
    if (std.mem.eql(u8, text, "export")) return .keyword_export;
    if (std.mem.eql(u8, text, "test")) return .keyword_test;
    if (std.mem.eql(u8, text, "type")) return .keyword_type;
    if (std.mem.eql(u8, text, "comptime")) return .keyword_comptime;
    if (std.mem.eql(u8, text, "try")) return .keyword_try;
    if (std.mem.eql(u8, text, "catch")) return .keyword_catch;
    if (std.mem.eql(u8, text, "defer")) return .keyword_defer;
    if (std.mem.eql(u8, text, "drop")) return .keyword_drop;
    if (std.mem.eql(u8, text, "new")) return .keyword_new;
    if (std.mem.eql(u8, text, "unchecked")) return .keyword_unchecked;
    if (std.mem.eql(u8, text, "using")) return .keyword_using;
    if (std.mem.eql(u8, text, "alloc")) return .keyword_alloc;
    if (std.mem.eql(u8, text, "scoped")) return .keyword_scoped;
    if (std.mem.eql(u8, text, "asm")) return .keyword_asm;
    if (std.mem.eql(u8, text, "none")) return .keyword_none;
    if (std.mem.eql(u8, text, "is")) return .keyword_is;
    if (std.mem.eql(u8, text, "as")) return .keyword_as;
    if (std.mem.eql(u8, text, "and")) return .keyword_and;
    if (std.mem.eql(u8, text, "or")) return .keyword_or;
    if (std.mem.eql(u8, text, "not")) return .keyword_not;
    if (std.mem.eql(u8, text, "true")) return .keyword_true;
    if (std.mem.eql(u8, text, "false")) return .keyword_false;
    return .identifier;
}

test "lexes a tiny function" {
    const tokens = try lexAll(std.testing.allocator, "fn main(): i32 { return 0; }");
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(TokenTag.keyword_fn, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqual(TokenTag.eof, tokens[tokens.len - 1].tag);
}

test "lexes escaped identifiers as identifiers" {
    const tokens = try lexAll(std.testing.allocator, "struct S { pub `protocol`: i32; }");
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(TokenTag.identifier, tokens[4].tag);
    try std.testing.expectEqualStrings("protocol", tokens[4].lexeme);
}

test "tokens retain half-open byte offsets" {
    const source = "fn main() {\n    return `value`;\n}";
    const tokens = try lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 0), tokens[0].offset);
    try std.testing.expectEqual(@as(usize, 2), tokens[0].end_offset);
    try std.testing.expectEqualStrings("fn", source[tokens[0].offset..tokens[0].end_offset]);

    var escaped: ?Token = null;
    for (tokens) |token| {
        if (token.tag == .identifier and std.mem.eql(u8, token.lexeme, "value")) {
            escaped = token;
            break;
        }
    }
    try std.testing.expect(escaped != null);
    try std.testing.expectEqualStrings("`value`", source[escaped.?.offset..escaped.?.end_offset]);
    try std.testing.expectEqual(source.len, tokens[tokens.len - 1].offset);
    try std.testing.expectEqual(source.len, tokens[tokens.len - 1].end_offset);
}

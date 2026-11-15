const type_resolution = @import("type_resolution.zig");
const std = @import("std");
const ast = @import("../parser/ast.zig");
const sir = @import("sir.zig");
const semantic_types = @import("types.zig");
const lexer = @import("../lexer/lexer.zig");

pub fn isAsmSymbolName(name: []const u8) bool {
    if (name.len == 0 or !isAsmSymbolStart(name[0])) return false;
    for (name[1..]) |ch| {
        if (!isAsmSymbolContinue(ch)) return false;
    }
    return true;
}

fn isAarch64AsmRegister(name: []const u8) bool {
    if (std.mem.eql(u8, name, "sp") or
        std.mem.eql(u8, name, "lr") or
        std.mem.eql(u8, name, "fp")) return true;
    if (name.len < 2 or name.len > 3) return false;
    if (name[0] != 'x' and name[0] != 'w') return false;
    const index = std.fmt.parseInt(u8, name[1..], 10) catch return false;
    return index <= 30;
}

fn isAsmSymbolStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_' or ch == '.';
}

fn isAsmSymbolContinue(ch: u8) bool {
    return isAsmSymbolStart(ch) or std.ascii.isDigit(ch) or ch == '$';
}

pub fn Owner(comptime host: anytype) type {
    return struct {
        const SemaContext = host.SemaContext;
        const SemaError = host.SemaError;
        const canonical = type_resolution.Canonical(SemaContext);
        const canonicalTypeKind = canonical.sirType;
        const canonicalTypeNode = canonical.typeNode;
        const isDefinitionSiteBinder = host.isDefinitionSiteBinder;

        pub fn expectAsmInputType(context: *SemaContext, path: []const u8, token: lexer.Token, type_id: semantic_types.TypeId) SemaError!void {
            switch (canonicalTypeNode(context, type_id).*) {
                .inferred_integer, .integer, .ref_, .raw => return,
                .primitive => |primitive| if (primitive == .bool) return,
                else => {
                    try context.diagnostic_context.emitToken(path, token, "asm inputs must be integers, bools, or pointer-like values", .{});
                    return SemaError.SemanticFailed;
                },
            }
        }

        pub fn expectAsmResultType(context: *SemaContext, path: []const u8, token: lexer.Token, type_id: semantic_types.TypeId) SemaError!void {
            // A binder result has no concrete kind yet; the specialization that
            // substitutes it re-checks the kind when the body is lowered for real.
            if (isDefinitionSiteBinder(context, type_id)) return;
            switch (canonicalTypeNode(context, type_id).*) {
                .inferred_integer, .integer, .ref_, .raw => return,
                .primitive => |primitive| if (primitive == .bool) return,
                else => {
                    try context.diagnostic_context.emitToken(path, token, "asm results must be integers, bools, or pointer-like values", .{});
                    return SemaError.SemanticFailed;
                },
            }
        }

        pub fn lowerAsmConstraint(constraint: ast.AsmConstraint) sir.AsmConstraint {
            return switch (constraint) {
                .reg => .reg,
                .tied_reg => .tied_reg,
            };
        }

        pub fn lowerAsmClobber(context: *SemaContext, allocator: std.mem.Allocator, path: []const u8, token: lexer.Token, clobber: ast.AsmClobber) SemaError!sir.AsmClobber {
            return switch (clobber) {
                .memory => .memory,
                .flags => .flags,
                .register => |name| .{ .register = try validateAsmRegisterClobber(context, allocator, path, token, name) },
            };
        }

        fn validateAsmRegisterClobber(context: *SemaContext, allocator: std.mem.Allocator, path: []const u8, token: lexer.Token, name: []const u8) SemaError![]const u8 {
            if (context.abi_layout.is_aarch64) {
                if (isAarch64AsmRegister(name)) return allocator.dupe(u8, name);
                try context.diagnostic_context.emitToken(path, token, "unsupported AArch64 asm clobber register `{s}`", .{name});
                return SemaError.SemanticFailed;
            }
            try context.diagnostic_context.emitTokenWith(path, token, .{
                .code = .capability,
                .notes = &.{"register names and clobber support are target capabilities"},
                .help = "use `memory` or `flags` clobbers for target-independent effects",
            }, "register asm clobbers are unavailable for this target; use `memory` or `flags` clobbers", .{});
            return SemaError.SemanticFailed;
        }

        pub fn validateAsmPlaceholders(context: *SemaContext, path: []const u8, asm_stmt: ast.AsmStmt, used_inputs: []bool) SemaError!void {
            for (asm_stmt.inputs) |input| {
                if (input.constraint == .tied_reg) {
                    try context.diagnostic_context.emitToken(path, input.name_token, "tied asm inputs require expression asm with an explicit `out` operand", .{});
                    return SemaError.SemanticFailed;
                }
            }
            for (asm_stmt.lines) |line| {
                var i: usize = 0;
                while (i < line.len) : (i += 1) {
                    if (line[i] != '{') continue;
                    const start = i + 1;
                    var end = start;
                    while (end < line.len and line[end] != '}') : (end += 1) {}
                    if (end >= line.len) {
                        try context.diagnostic_context.emitPath(path, "asm placeholder is missing closing `}`");
                        return SemaError.SemanticFailed;
                    }
                    const name = line[start..end];
                    if (name.len == 0) {
                        try context.diagnostic_context.emitPath(path, "asm placeholder name cannot be empty");
                        return SemaError.SemanticFailed;
                    }
                    const index = findAsmInputIndex(asm_stmt.inputs, name) orelse {
                        try context.diagnostic_context.emitPath(path, "asm placeholder refers to an undeclared input");
                        return SemaError.SemanticFailed;
                    };
                    used_inputs[index] = true;
                    i = end;
                }
            }

            for (asm_stmt.inputs, 0..) |input, i| {
                if (!used_inputs[i]) {
                    try context.diagnostic_context.emitToken(path, input.name_token, "asm input `{s}` is declared but never used in a template", .{input.name});
                    return SemaError.SemanticFailed;
                }
            }
        }

        fn findAsmInputIndex(inputs: []const ast.AsmInput, name: []const u8) ?usize {
            for (inputs, 0..) |input, i| {
                if (std.mem.eql(u8, input.name, name)) return i;
            }
            return null;
        }

        pub fn validateAsmExprPlaceholders(context: *SemaContext, path: []const u8, asm_expr: ast.AsmExpr, used_inputs: []bool) SemaError!void {
            for (asm_expr.inputs) |input| {
                if (input.constraint == .tied_reg and asm_expr.output == null) {
                    try context.diagnostic_context.emitToken(path, input.name_token, "tied asm inputs require an explicit `out` operand", .{});
                    return SemaError.SemanticFailed;
                }
                if (input.constraint == .tied_reg and asm_expr.inout != null) {
                    try context.diagnostic_context.emitToken(path, input.name_token, "tied asm inputs cannot be combined with `inout`; use the inout operand directly", .{});
                    return SemaError.SemanticFailed;
                }
            }
            var saw_output = false;
            for (asm_expr.lines) |line| {
                var i: usize = 0;
                while (i < line.len) : (i += 1) {
                    if (line[i] != '{') continue;
                    const start = i + 1;
                    var end = start;
                    while (end < line.len and line[end] != '}') : (end += 1) {}
                    if (end >= line.len) {
                        try context.diagnostic_context.emitPath(path, "asm placeholder is missing closing `}`");
                        return SemaError.SemanticFailed;
                    }
                    const name = line[start..end];
                    if (name.len == 0) {
                        try context.diagnostic_context.emitPath(path, "asm placeholder name cannot be empty");
                        return SemaError.SemanticFailed;
                    }
                    if (asm_expr.inout) |inout| {
                        if (std.mem.eql(u8, name, "out")) {
                            try context.diagnostic_context.emitToken(path, asm_expr.token, "asm expression with explicit inout must use the declared inout name", .{});
                            return SemaError.SemanticFailed;
                        }
                        if (std.mem.eql(u8, name, inout.name)) {
                            saw_output = true;
                            i = end;
                            continue;
                        }
                    } else if (asm_expr.output) |output| {
                        if (std.mem.eql(u8, name, "out")) {
                            try context.diagnostic_context.emitToken(path, asm_expr.token, "asm expression with explicit output must use the declared output name", .{});
                            return SemaError.SemanticFailed;
                        }
                        if (std.mem.eql(u8, name, output.name)) {
                            saw_output = true;
                            i = end;
                            continue;
                        }
                    } else if (std.mem.eql(u8, name, "out")) {
                        saw_output = true;
                        i = end;
                        continue;
                    }
                    const index = findAsmInputIndex(asm_expr.inputs, name) orelse {
                        try context.diagnostic_context.emitPath(path, "asm placeholder refers to an undeclared input");
                        return SemaError.SemanticFailed;
                    };
                    used_inputs[index] = true;
                    i = end;
                }
            }

            if (asm_expr.inout) |inout| {
                if (!saw_output) {
                    try context.diagnostic_context.emitToken(path, inout.name_token, "asm expression template must use the declared inout placeholder `{{{s}}}`", .{inout.name});
                    return SemaError.SemanticFailed;
                }
            } else if (asm_expr.output) |output| {
                if (!saw_output) {
                    try context.diagnostic_context.emitToken(path, output.name_token, "asm expression template must use the declared output placeholder `{{{s}}}`", .{output.name});
                    return SemaError.SemanticFailed;
                }
            } else if (!saw_output) {
                try context.diagnostic_context.emitToken(path, asm_expr.token, "asm expression template must use `{{out}}` for the result placeholder", .{});
                return SemaError.SemanticFailed;
            }

            for (asm_expr.inputs, 0..) |input, i| {
                if (!used_inputs[i]) {
                    try context.diagnostic_context.emitToken(path, input.name_token, "asm input `{s}` is declared but never used in a template", .{input.name});
                    return SemaError.SemanticFailed;
                }
            }
        }
    };
}

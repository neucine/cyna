const std = @import("std");
const compiler = @import("cyna").compiler;

const diagnostics = compiler.diagnostics;

fn token(offset: usize, line: usize, column: usize) compiler.lexer.Token {
    return .{
        .tag = .identifier,
        .lexeme = "x",
        .offset = offset,
        .end_offset = offset + 1,
        .line = line,
        .column = column,
        .end_column = column + 1,
    };
}

test "parser recovery reports bounded errors at top-level synchronization points" {
    const allocator = std.testing.allocator;
    const source =
        \\fn broken_one(: i32): i32 { return 0; }
        \\fn valid(): i32 { return 1; }
        \\fn broken_two(): i32 {
        \\    const value = ;
        \\    return value;
        \\}
        \\fn main(): i32 { return valid(); }
        \\
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    var context = diagnostics.Context.structured(&sink);

    try std.testing.expectError(
        error.ParseFailed,
        compiler.parser.parseWithDiagnostics(allocator, "multi_error.cy", source, tokens, &context),
    );
    try sink.normalize(.{});
    try std.testing.expectEqual(@as(usize, 2), sink.records.items.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.parse_syntax, sink.records.items[0].code);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.parse_syntax, sink.records.items[1].code);
    try std.testing.expect(sink.records.items[0].primary.?.start < sink.records.items[1].primary.?.start);
}

test "parser recovery stops at the declared error bound" {
    const allocator = std.testing.allocator;
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(allocator);
    for (0..10) |index| {
        try source.print(allocator, "broken_{d}\nfn valid_{d}(): i32 {{ return {d}; }}\n", .{
            index,
            index,
            index,
        });
    }
    const tokens = try compiler.lexer.lexAll(allocator, source.items);
    defer allocator.free(tokens);
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    var context = diagnostics.Context.structured(&sink);

    try std.testing.expectError(
        error.ParseFailed,
        compiler.parser.parseWithDiagnostics(allocator, "bounded_recovery.cy", source.items, tokens, &context),
    );
    try sink.normalize(.{});
    try std.testing.expectEqual(@as(usize, 8), sink.records.items.len);
}

test "diagnostic normalization orders and deduplicates deterministically" {
    const allocator = std.testing.allocator;
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    const context = diagnostics.Context.structured(&sink);

    try context.emitTokenWith("z.cy", token(20, 3, 1), .{ .code = .type_mismatch }, "later", .{});
    try context.emitTokenWith("a.cy", token(10, 2, 1), .{ .code = .name_unknown_value }, "first", .{});
    try context.emitTokenWith("a.cy", token(10, 2, 1), .{ .code = .name_unknown_value }, "first", .{});
    try context.emitTokenWith("a.cy", token(30, 4, 1), .{ .code = .type_mismatch }, "second", .{});

    try sink.normalize(.{});
    try std.testing.expectEqual(@as(usize, 3), sink.records.items.len);
    try std.testing.expectEqualStrings("a.cy", sink.records.items[0].path);
    try std.testing.expectEqualStrings("first", sink.records.items[0].message);
    try std.testing.expectEqualStrings("second", sink.records.items[1].message);
    try std.testing.expectEqualStrings("z.cy", sink.records.items[2].path);
}

test "deduplication preserves distinct structured explanations" {
    const allocator = std.testing.allocator;
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    const context = diagnostics.Context.structured(&sink);
    const failure_token = token(10, 2, 1);

    try context.emitTokenWith("details.cy", failure_token, .{
        .code = .type_mismatch,
        .notes = &.{"expectation came from the return type"},
    }, "type mismatch", .{});
    try context.emitTokenWith("details.cy", failure_token, .{
        .code = .type_mismatch,
        .notes = &.{"expectation came from the parameter"},
    }, "type mismatch", .{});

    try sink.normalize(.{});
    try std.testing.expectEqual(@as(usize, 2), sink.records.items.len);
    try std.testing.expect(!std.mem.eql(
        u8,
        sink.records.items[0].notes[0],
        sink.records.items[1].notes[0],
    ));
}

test "structured semantic error suppresses dependent fallback at the same span" {
    const allocator = std.testing.allocator;
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    const context = diagnostics.Context.structured(&sink);
    const failure_token = token(12, 2, 5);

    try context.emitToken("cascade.cy", failure_token, "generic semantic failure", .{});
    try context.emitTokenWith(
        "cascade.cy",
        failure_token,
        .{ .code = .type_mismatch },
        "type mismatch: expected i32, got string",
        .{},
    );

    try sink.normalize(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.records.items.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.type_mismatch, sink.records.items[0].code);
}

test "semantic analysis emits one authoritative error for a dependent expression" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main(): i32 {
        \\    return missing_value;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "semantic_cascade.cy", source, tokens);
    defer program.deinit(allocator);
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();

    try std.testing.expectError(error.SemanticFailed, compiler.sema.buildSirWithOptions(
        allocator,
        "semantic_cascade.cy",
        program,
        .{ .diagnostic_context = diagnostics.Context.structured(&sink) },
    ));
    try sink.normalize(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.records.items.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.name_unknown_value, sink.records.items[0].code);
}

test "diagnostic limit retains deterministic prefix and reports suppression" {
    const allocator = std.testing.allocator;
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    const context = diagnostics.Context.structured(&sink);

    try context.emitTokenWith("limit.cy", token(30, 4, 1), .{ .code = .parse_syntax }, "third", .{});
    try context.emitTokenWith("limit.cy", token(10, 2, 1), .{ .code = .parse_syntax }, "first", .{});
    try context.emitTokenWith("limit.cy", token(20, 3, 1), .{ .code = .parse_syntax }, "second", .{});
    try context.emitTokenWith("limit.cy", token(40, 5, 1), .{ .code = .parse_syntax }, "fourth", .{});

    try sink.normalize(.{ .max_diagnostics = 2 });
    try std.testing.expectEqual(@as(usize, 3), sink.records.items.len);
    try std.testing.expectEqualStrings("first", sink.records.items[0].message);
    try std.testing.expectEqualStrings("second", sink.records.items[1].message);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.diagnostic_limit_reached, sink.records.items[2].code);
    try std.testing.expect(std.mem.indexOf(u8, sink.records.items[2].message, "2 additional diagnostics suppressed") != null);
}

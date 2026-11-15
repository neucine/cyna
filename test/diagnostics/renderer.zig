const std = @import("std");
const compiler = @import("cyna").compiler;
const diagnostics = compiler.diagnostics;
const renderer = compiler.diagnostic_renderer;
const source_registry = compiler.diagnostic_sources;

fn emit(sink: *diagnostics.Sink, spec: diagnostics.DiagnosticSpec) !void {
    const context = diagnostics.Context.structured(sink);
    try context.emit(spec);
}

test "diagnostic source registry owns text and resolves byte-offset lines" {
    var registry = source_registry.Registry.init(std.testing.allocator);
    defer registry.deinit();

    var path = [_]u8{ 'm', 'a', 'i', 'n', '.', 'c', 'y' };
    var text = [_]u8{ 'a', '\n', 'b', 'e', 't', 'a' };
    const id = try registry.register(&path, &text);
    @memset(&path, 'x');
    @memset(&text, 'x');

    const source = registry.get(id).?;
    try std.testing.expectEqualStrings("main.cy", source.path);
    try std.testing.expectEqualStrings("a\nbeta", source.text);
    const line = registry.lineAt(id, 4).?;
    try std.testing.expectEqual(@as(usize, 2), line.number);
    try std.testing.expectEqual(@as(usize, 2), line.start);
    try std.testing.expectEqualStrings("beta", line.text);
    try std.testing.expectError(error.DuplicateSource, registry.register("main.cy", "other"));
}

test "diagnostic compact renderer remains exactly compatible" {
    var sink = diagnostics.Sink.init(std.testing.allocator);
    defer sink.deinit();
    try emit(&sink, .{
        .path = "main.cy",
        .message = "expected expression",
        .primary = .{
            .path = "main.cy",
            .start = 8,
            .end = 9,
            .line = 2,
            .column = 5,
            .end_column = 6,
        },
    });
    var registry = source_registry.Registry.init(std.testing.allocator);
    defer registry.deinit();

    const rendered = try renderer.renderAlloc(std.testing.allocator, &registry, sink.records.items, .{ .mode = .compact });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "main.cy:2:5:6: error: expected expression\n",
        rendered,
    );
}

test "diagnostic human renderer shows multi-file labels notes help fixes and tabs" {
    var sink = diagnostics.Sink.init(std.testing.allocator);
    defer sink.deinit();
    const labels = [_]diagnostics.Label{.{
        .span = .{
            .path = "lib.cy",
            .start = 6,
            .end = 12,
            .line = 1,
            .column = 7,
            .end_column = 13,
        },
        .message = "borrow created here",
    }};
    const notes = [_][]const u8{"the borrow remains live"};
    const fixes = [_]diagnostics.Fix{.{
        .span = .{
            .path = "main.cy",
            .start = 10,
            .end = 16,
            .line = 2,
            .column = 2,
            .end_column = 8,
        },
        .replacement = "copy value",
        .applicability = .maybe_incorrect,
    }};
    try emit(&sink, .{
        .code = .ownership,
        .path = "main.cy",
        .message = "cannot mutate while borrowed",
        .primary = .{
            .path = "main.cy",
            .start = 10,
            .end = 16,
            .line = 2,
            .column = 2,
            .end_column = 8,
        },
        .labels = &labels,
        .notes = &notes,
        .help = "copy the value before borrowing",
        .fixes = &fixes,
    });
    var registry = source_registry.Registry.init(std.testing.allocator);
    defer registry.deinit();
    _ = try registry.register("main.cy", "fn f() {\n\tmutate(value);\n}\n");
    _ = try registry.register("lib.cy", "const borrow = value;\n");

    const rendered = try renderer.renderAlloc(std.testing.allocator, &registry, sink.records.items, .{});
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "error[E-ownership]: cannot mutate while borrowed\n" ++
            " --> main.cy:2:5\n" ++
            "2 |     mutate(value);\n" ++
            "  |     ^~~~~~\n" ++
            " ::: lib.cy:1:7\n" ++
            "1 | const borrow = value;\n" ++
            "  |       ------ borrow created here\n" ++
            "  = note: the borrow remains live\n" ++
            "  = help: copy the value before borrowing\n" ++
            "  = fix (maybe-incorrect): replace main.cy:10..16 with `copy value`\n",
        rendered,
    );
}

test "diagnostic human renderer handles unicode multiline and unavailable sources" {
    var sink = diagnostics.Sink.init(std.testing.allocator);
    defer sink.deinit();
    try emit(&sink, .{
        .code = .parse_syntax,
        .path = "unicode.cy",
        .message = "invalid block",
        .primary = .{
            .path = "unicode.cy",
            .start = 2,
            .end = 12,
            .line = 1,
            .column = 3,
            .end_column = 13,
        },
    });
    try emit(&sink, .{
        .path = "missing.cy",
        .message = "missing source",
        .primary = .{
            .path = "missing.cy",
            .start = 4,
            .end = 5,
            .line = 4,
            .column = 2,
            .end_column = 3,
        },
    });
    var registry = source_registry.Registry.init(std.testing.allocator);
    defer registry.deinit();
    _ = try registry.register("unicode.cy", "é start\n\tfinish\n");

    const rendered = try renderer.renderAlloc(std.testing.allocator, &registry, sink.records.items, .{});
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "error[E-parse_syntax]: invalid block\n" ++
            " --> unicode.cy:1:2\n" ++
            "1 | é start\n" ++
            "  |  ^~~~~~\n" ++
            "  | ...\n" ++
            "2 |     finish\n" ++
            "  | ^~~~~~\n" ++
            "\n" ++
            "error[E-legacy_unclassified]: missing source\n" ++
            " --> missing.cy:4:2\n" ++
            "  = note: source unavailable; excerpt omitted\n",
        rendered,
    );
}

test "diagnostic human renderer keeps path-only diagnostics visible" {
    var sink = diagnostics.Sink.init(std.testing.allocator);
    defer sink.deinit();
    try emit(&sink, .{
        .code = .capability,
        .path = "cyna.toml",
        .message = "target is unsupported",
    });
    var registry = source_registry.Registry.init(std.testing.allocator);
    defer registry.deinit();

    const rendered = try renderer.renderAlloc(std.testing.allocator, &registry, sink.records.items, .{});
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "error[E-capability]: target is unsupported\n" ++
            " --> cyna.toml\n",
        rendered,
    );
}

test "diagnostic human renderer aligns multi-digit line gutters" {
    var sink = diagnostics.Sink.init(std.testing.allocator);
    defer sink.deinit();
    try emit(&sink, .{
        .path = "many-lines.cy",
        .message = "bad name",
        .primary = .{
            .path = "many-lines.cy",
            .start = 9,
            .end = 12,
            .line = 10,
            .column = 1,
            .end_column = 4,
        },
    });
    var registry = source_registry.Registry.init(std.testing.allocator);
    defer registry.deinit();
    _ = try registry.register("many-lines.cy", "\n\n\n\n\n\n\n\n\nbad\n");

    const rendered = try renderer.renderAlloc(std.testing.allocator, &registry, sink.records.items, .{});
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "error[E-legacy_unclassified]: bad name\n" ++
            " --> many-lines.cy:10:1\n" ++
            "10 | bad\n" ++
            "   | ^~~\n",
        rendered,
    );
}

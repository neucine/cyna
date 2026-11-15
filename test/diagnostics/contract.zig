const std = @import("std");
const compiler = @import("cyna").compiler;
const diagnostics = compiler.diagnostics;

fn emitRichDiagnostic(allocator: std.mem.Allocator) !void {
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    const context = diagnostics.Context.structured(&sink);
    const labels = [_]diagnostics.Label{.{
        .span = .{
            .path = "related.cy",
            .start = 1,
            .end = 2,
            .line = 1,
            .column = 2,
            .end_column = 3,
        },
        .message = "related declaration",
    }};
    const notes = [_][]const u8{"a note"};
    const fixes = [_]diagnostics.Fix{.{
        .span = .{
            .path = "main.cy",
            .start = 3,
            .end = 4,
            .line = 1,
            .column = 4,
            .end_column = 5,
        },
        .replacement = "replacement",
    }};
    try context.emit(.{
        .code = .type_mismatch,
        .path = "main.cy",
        .message = "type mismatch",
        .primary = .{
            .path = "main.cy",
            .start = 3,
            .end = 4,
            .line = 1,
            .column = 4,
            .end_column = 5,
        },
        .labels = &labels,
        .notes = &notes,
        .help = "change the expression",
        .fixes = &fixes,
    });
}

test "diagnostic contract releases every partial allocation on failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        emitRichDiagnostic,
        .{},
    );
}

test "diagnostic contract owns nested data and preserves order" {
    var sink = diagnostics.Sink.init(std.testing.allocator);
    defer sink.deinit();
    const context = diagnostics.Context.structured(&sink);

    var path = [_]u8{ 'm', 'a', 'i', 'n', '.', 'c', 'y' };
    var message = [_]u8{ 'b', 'o', 'r', 'r', 'o', 'w' };
    var label_path = [_]u8{ 'l', 'i', 'b', '.', 'c', 'y' };
    var label_message = [_]u8{ 'c', 'r', 'e', 'a', 't', 'e', 'd' };
    var note = [_]u8{ 's', 't', 'i', 'l', 'l', ' ', 'l', 'i', 'v', 'e' };
    var help = [_]u8{ 'c', 'o', 'p', 'y', ' ', 'i', 't' };
    const labels = [_]diagnostics.Label{.{
        .span = .{
            .path = &label_path,
            .start = 2,
            .end = 9,
            .line = 2,
            .column = 3,
            .end_column = 10,
        },
        .message = &label_message,
    }};
    const notes = [_][]const u8{&note};

    try context.emit(.{
        .code = .ownership,
        .severity = .warning,
        .path = &path,
        .message = &message,
        .primary = .{
            .path = &path,
            .start = 12,
            .end = 18,
            .line = 3,
            .column = 5,
            .end_column = 11,
        },
        .labels = &labels,
        .notes = &notes,
        .help = &help,
    });
    try context.emitPath("second.cy", "second failure");

    @memset(&path, 'x');
    @memset(&message, 'x');
    @memset(&label_path, 'x');
    @memset(&label_message, 'x');
    @memset(&note, 'x');
    @memset(&help, 'x');

    try std.testing.expectEqual(@as(usize, 2), sink.records.items.len);
    const record = sink.records.items[0];
    try std.testing.expectEqual(diagnostics.DiagnosticCode.ownership, record.code);
    try std.testing.expectEqual(diagnostics.Severity.warning, record.severity);
    try std.testing.expectEqualStrings("main.cy", record.path);
    try std.testing.expectEqualStrings("borrow", record.message);
    try std.testing.expectEqualStrings("lib.cy", record.labels[0].span.path);
    try std.testing.expectEqualStrings("created", record.labels[0].message);
    try std.testing.expectEqualStrings("still live", record.notes[0]);
    try std.testing.expectEqualStrings("copy it", record.help.?);
    try std.testing.expectEqualStrings("second failure", sink.records.items[1].message);
}

test "diagnostic contract preserves compact rendering and disabled contexts" {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var context = diagnostics.Context.capturing(std.testing.allocator, &buffer);
    try context.emitPath("path.cy", "path failure");
    try context.emitToken("token.cy", .{
        .tag = .identifier,
        .lexeme = "name",
        .line = 3,
        .column = 5,
        .end_column = 9,
    }, "unknown `{s}`", .{"name"});
    try std.testing.expectEqualStrings(
        "path.cy: error: path failure\n" ++
            "token.cy:3:5:9: error: unknown `name`\n",
        buffer.items,
    );

    var sink = diagnostics.Sink.init(std.testing.allocator);
    defer sink.deinit();
    context = diagnostics.Context.structured(&sink);
    context.enabled = false;
    try context.emitPath("path.cy", "ignored");
    try std.testing.expectEqual(@as(usize, 0), sink.records.items.len);
}

test "diagnostic spans use lexer half-open byte offsets" {
    const source = "fn main() {\n    return `value`;\n}";
    const tokens = try compiler.lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 0), tokens[0].offset);
    try std.testing.expectEqual(@as(usize, 2), tokens[0].end_offset);
    var escaped: ?compiler.lexer.Token = null;
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

const std = @import("std");
const cyna = @import("cyna");
const analysis = cyna.lsp.analysis;
const compat = cyna.compat;
const compiler = cyna.compiler;
const presentation = cyna.lsp.presentation;

const TestOverlay = struct {
    path: []const u8,
    text: []const u8,

    fn source(context: *anyopaque, canonical_path: []const u8) ?[]const u8 {
        const self: *TestOverlay = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, self.path, canonical_path)) return self.text;
        return null;
    }
};

fn makeStructuredSnapshot(allocator: std.mem.Allocator) !analysis.Snapshot {
    var sink = compiler.diagnostics.Sink.init(allocator);
    defer sink.deinit();
    const context = compiler.diagnostics.Context.structured(&sink);

    const labels = [_]compiler.diagnostics.Label{.{
        .span = .{
            .path = "/workspace/lib.cy",
            .start = 2,
            .end = 6,
            .line = 1,
            .column = 3,
            .end_column = 7,
        },
        .message = "declared here",
    }};
    try context.emit(.{
        .code = .ownership,
        .severity = .warning,
        .path = "/workspace/main.cy",
        .message = "borrow remains live",
        .primary = .{
            .path = "/workspace/main.cy",
            .start = 5,
            .end = 8,
            .line = 1,
            .column = 6,
            .end_column = 9,
        },
        .labels = &labels,
    });
    try context.emit(.{
        .code = .capability,
        .path = "cyna.toml",
        .message = "target is unsupported",
    });
    try context.emit(.{
        .code = .parse_syntax,
        .path = "/workspace/unavailable.cy",
        .message = "source is unavailable",
        .primary = .{
            .path = "/workspace/unavailable.cy",
            .start = 1,
            .end = 2,
            .line = 1,
            .column = 2,
            .end_column = 3,
        },
    });

    var sources = compiler.diagnostic_sources.Registry.init(allocator);
    errdefer sources.deinit();
    _ = try sources.register("/workspace/main.cy", "a😀bad\n");
    _ = try sources.register("/workspace/lib.cy", "édecl\n");
    const records = try sink.takeRecords();
    errdefer {
        for (records) |record| record.deinit(allocator);
        allocator.free(records);
    }
    const hover_facts = try allocator.alloc(compiler.sema.SemanticHoverFact, 0);
    errdefer allocator.free(hover_facts);
    const dependencies = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(dependencies);
    return .{
        .allocator = allocator,
        .diagnostics = records,
        .hover_facts = hover_facts,
        .dependencies = dependencies,
        .sources = sources,
        .loaded = null,
        .current_module_name = null,
        .matches_disk = false,
    };
}

test "lsp positions convert UTF-8 byte boundaries to UTF-16" {
    const text = "a😀é\nx";
    try std.testing.expectEqual(presentation.Position{ .line = 0, .character = 0 }, presentation.positionAt(text, 0).?);
    try std.testing.expectEqual(presentation.Position{ .line = 0, .character = 1 }, presentation.positionAt(text, 1).?);
    try std.testing.expectEqual(presentation.Position{ .line = 0, .character = 3 }, presentation.positionAt(text, 5).?);
    try std.testing.expectEqual(presentation.Position{ .line = 0, .character = 4 }, presentation.positionAt(text, 7).?);
    try std.testing.expectEqual(presentation.Position{ .line = 1, .character = 0 }, presentation.positionAt(text, 8).?);
    try std.testing.expect(presentation.positionAt(text, 2) == null);
}

test "lsp publication groups by source and separates workspace failures" {
    var snapshot = try makeStructuredSnapshot(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    var publication = try presentation.build(std.testing.allocator, &snapshot);
    defer publication.deinit();

    try std.testing.expectEqual(@as(usize, 1), publication.documents.items.len);
    const group = publication.documents.items[0];
    try std.testing.expectEqualStrings("/workspace/main.cy", group.path);
    try std.testing.expectEqual(@as(usize, 1), group.diagnostics.items.len);
    const diagnostic = group.diagnostics.items[0];
    try std.testing.expectEqual(@as(u8, 2), diagnostic.severity);
    try std.testing.expectEqual(compiler.diagnostics.DiagnosticCode.ownership, diagnostic.code);
    try std.testing.expectEqual(presentation.Position{ .line = 0, .character = 3 }, diagnostic.range.start);
    try std.testing.expectEqual(presentation.Position{ .line = 0, .character = 6 }, diagnostic.range.end);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.related.len);
    try std.testing.expectEqualStrings("/workspace/lib.cy", diagnostic.related[0].path);
    try std.testing.expectEqual(presentation.Position{ .line = 0, .character = 1 }, diagnostic.related[0].range.start);
    try std.testing.expectEqual(presentation.Position{ .line = 0, .character = 5 }, diagnostic.related[0].range.end);

    try std.testing.expectEqual(@as(usize, 2), publication.workspace.items.len);
    try std.testing.expectEqualStrings("/workspace/unavailable.cy", publication.workspace.items[0].path);
    try std.testing.expectEqualStrings("cyna.toml", publication.workspace.items[1].path);
}

test "lsp publication retains an imported module diagnostic owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const main_source =
        \\import .broken;
        \\fn main(): i32 { return 0; }
        \\
    ;
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = main_source });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "broken.cy", .data =
        \\fn broken(): i32 {
        \\    const value = ;
        \\    return 0;
        \\}
        \\
    });
    const main_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(main_path);
    const broken_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "broken.cy");
    defer std.testing.allocator.free(broken_path);

    var snapshot = try analysis.build(std.testing.allocator, main_path, main_source, true);
    defer snapshot.deinit(std.testing.allocator);
    var publication = try presentation.build(std.testing.allocator, &snapshot);
    defer publication.deinit();

    try std.testing.expectEqual(@as(usize, 1), publication.documents.items.len);
    try std.testing.expectEqualStrings(broken_path, publication.documents.items[0].path);
    try std.testing.expect(std.mem.indexOf(
        u8,
        publication.documents.items[0].diagnostics.items[0].message,
        "expected expression",
    ) != null);
}

test "lsp publication uses unsaved imported source overlays" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const main_source =
        \\import .broken;
        \\fn main(): i32 { return 0; }
        \\
    ;
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = main_source });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "broken.cy", .data =
        \\pub fn broken(): i32 { return 1; }
        \\
    });
    const main_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(main_path);
    const broken_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "broken.cy");
    defer std.testing.allocator.free(broken_path);
    const unsaved_broken =
        \\pub fn broken(): i32 {
        \\    const marker = "😀";
        \\    const value = ;
        \\    return 1;
        \\}
        \\
    ;
    var overlay = TestOverlay{ .path = broken_path, .text = unsaved_broken };

    var snapshot = try analysis.buildWithOptions(std.testing.allocator, main_path, main_source, .{
        .matches_disk = true,
        .source_overlay = .{
            .context = &overlay,
            .getFn = TestOverlay.source,
        },
    });
    defer snapshot.deinit(std.testing.allocator);
    var publication = try presentation.build(std.testing.allocator, &snapshot);
    defer publication.deinit();

    try std.testing.expectEqualStrings(
        unsaved_broken,
        snapshot.sources.sourceForPath(broken_path).?.text,
    );
    try std.testing.expectEqual(@as(usize, 1), publication.documents.items.len);
    try std.testing.expectEqualStrings(broken_path, publication.documents.items[0].path);
    const diagnostic = publication.documents.items[0].diagnostics.items[0];
    try std.testing.expectEqual(@as(usize, 2), diagnostic.range.start.line);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "expected expression") != null);
}

test "lsp file URIs percent-encode paths" {
    const uri = try presentation.pathToUriAlloc(std.testing.allocator, "/workspace/my file.cy");
    defer std.testing.allocator.free(uri);
    try std.testing.expectEqualStrings("file:///workspace/my%20file.cy", uri);
}

test "lsp diagnostic JSON carries code severity UTF-16 range and related information" {
    var snapshot = try makeStructuredSnapshot(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    var publication = try presentation.build(std.testing.allocator, &snapshot);
    defer publication.deinit();

    const payload = try presentation.documentPayloadAlloc(
        std.testing.allocator,
        "file:///workspace/main.cy",
        publication.documents.items[0].diagnostics.items,
    );
    defer std.testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("file:///workspace/main.cy", root.get("uri").?.string);
    const item = root.get("diagnostics").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 2), item.get("severity").?.integer);
    try std.testing.expectEqualStrings("ownership", item.get("code").?.string);
    const range = item.get("range").?.object;
    try std.testing.expectEqual(@as(i64, 3), range.get("start").?.object.get("character").?.integer);
    try std.testing.expectEqual(@as(i64, 6), range.get("end").?.object.get("character").?.integer);
    const related = item.get("relatedInformation").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), related.len);
    try std.testing.expectEqualStrings(
        "file:///workspace/lib.cy",
        related[0].object.get("location").?.object.get("uri").?.string,
    );

    const capability = for (publication.workspace.items) |workspace_item| {
        if (workspace_item.code == .capability) break workspace_item;
    } else return error.TestUnexpectedResult;
    const workspace_payload = try presentation.workspacePayloadAlloc(std.testing.allocator, capability);
    defer std.testing.allocator.free(workspace_payload);
    try std.testing.expect(std.mem.indexOf(u8, workspace_payload, "capability") != null);
    try std.testing.expect(std.mem.indexOf(u8, workspace_payload, "cyna.toml") != null);
}

fn buildPublicationForAllocationTest(allocator: std.mem.Allocator) !void {
    var snapshot = try makeStructuredSnapshot(allocator);
    defer snapshot.deinit(allocator);
    var publication = try presentation.build(allocator, &snapshot);
    defer publication.deinit();
}

test "lsp publication releases every partial allocation on failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        buildPublicationForAllocationTest,
        .{},
    );
}

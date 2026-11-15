const std = @import("std");
const compat = @import("cyna").compat;
const diagnostics = @import("cyna").compiler.diagnostics;
const session_mod = @import("cyna").lsp.session;

test "lsp session tracks and replaces multi-document diagnostic publications" {
    var session = session_mod.Session.init(std.testing.allocator);
    defer session.deinit();
    const uri = "file:///workspace/main.cy";

    try session.setPublishedDiagnosticPaths(uri, &.{ "/workspace/main.cy", "/workspace/lib.cy" });
    var paths = session.publishedDiagnosticPaths(uri);
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("/workspace/lib.cy", paths[1]);

    try session.setPublishedDiagnosticPaths(uri, &.{"/workspace/main.cy"});
    paths = session.publishedDiagnosticPaths(uri);
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings("/workspace/main.cy", paths[0]);

    session.clearPublishedDiagnosticPaths(uri);
    try std.testing.expectEqual(@as(usize, 0), session.publishedDiagnosticPaths(uri).len);
}
const symbols = @import("cyna").lsp.symbols;

test "lsp document revisions change only when content changes" {
    var session = session_mod.Session.init(std.testing.allocator);
    defer session.deinit();

    const uri = "file:///workspace/main.cy";
    const initial_text = "fn main(): i32 { return 0; }\n";

    try std.testing.expectEqual(
        session_mod.PutResult.opened,
        try session.putDocument(uri, 1, initial_text),
    );
    const initial = session.getDocument(uri).?;
    const initial_revision = initial.revision;
    const initial_text_pointer = initial.text.ptr;

    try std.testing.expectEqual(
        session_mod.PutResult.unchanged,
        try session.putDocument(uri, 1, initial_text),
    );
    try std.testing.expectEqual(initial_revision, session.getDocument(uri).?.revision);
    try std.testing.expectEqual(initial_text_pointer, session.getDocument(uri).?.text.ptr);

    try std.testing.expectEqual(
        session_mod.PutResult.version_changed,
        try session.putDocument(uri, 2, initial_text),
    );
    try std.testing.expectEqual(initial_revision, session.getDocument(uri).?.revision);
    try std.testing.expectEqual(@as(i64, 2), session.getDocument(uri).?.version);

    try std.testing.expectEqual(
        session_mod.PutResult.content_changed,
        try session.putDocument(uri, 3, "fn main(): i32 { return 1; }\n"),
    );
    try std.testing.expect(session.getDocument(uri).?.revision != initial_revision);
}

test "lsp document revisions ignore stale changes and advance after reopen" {
    var session = session_mod.Session.init(std.testing.allocator);
    defer session.deinit();

    const uri = "file:///workspace/main.cy";
    _ = try session.putDocument(uri, 5, "const current: i32 = 5;\n");
    const initial_revision = session.getDocument(uri).?.revision;

    try std.testing.expectEqual(
        session_mod.PutResult.stale,
        try session.putDocument(uri, 4, "const stale: i32 = 4;\n"),
    );
    const after_stale = session.getDocument(uri).?;
    try std.testing.expectEqual(initial_revision, after_stale.revision);
    try std.testing.expectEqual(@as(i64, 5), after_stale.version);
    try std.testing.expectEqualStrings("const current: i32 = 5;\n", after_stale.text);

    session.removeDocument(uri);
    try std.testing.expect(session.getDocument(uri) == null);

    try std.testing.expectEqual(
        session_mod.PutResult.opened,
        try session.putDocument(uri, 1, "const reopened: i32 = 1;\n"),
    );
    try std.testing.expect(session.getDocument(uri).?.revision != initial_revision);
}

test "lsp parsed snapshots are reused and invalidated by content revision" {
    var session = session_mod.Session.init(std.testing.allocator);
    defer session.deinit();

    const uri = "file:///workspace/main.cy";
    const path = "/workspace/main.cy";
    const initial_text = "fn main(): i32 { return 0; }\n";
    _ = try session.putDocument(uri, 1, initial_text);

    const first = (try session.parsedDocument(uri, path)).?;
    try std.testing.expectEqual(@as(usize, 1), first.program.functions.len);
    _ = (try session.parsedDocument(uri, path)).?;
    var stats = session.parsedCacheSnapshot();
    try std.testing.expectEqual(@as(u64, 1), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
    try std.testing.expectEqual(@as(u64, 0), stats.invalidations);

    try std.testing.expectEqual(
        session_mod.PutResult.version_changed,
        try session.putDocument(uri, 2, initial_text),
    );
    _ = (try session.parsedDocument(uri, path)).?;
    stats = session.parsedCacheSnapshot();
    try std.testing.expectEqual(@as(u64, 2), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
    try std.testing.expectEqual(@as(u64, 0), stats.invalidations);

    _ = try session.putDocument(uri, 3, "const answer: i32 = 42;\n");
    const changed = (try session.parsedDocument(uri, path)).?;
    try std.testing.expectEqual(@as(usize, 1), changed.program.globals.len);
    stats = session.parsedCacheSnapshot();
    try std.testing.expectEqual(@as(u64, 2), stats.hits);
    try std.testing.expectEqual(@as(u64, 2), stats.misses);
    try std.testing.expectEqual(@as(u64, 1), stats.invalidations);
}

test "lsp syntax queries share one parsed document snapshot" {
    var session = session_mod.Session.init(std.testing.allocator);
    defer session.deinit();

    const uri = "file:///workspace/main.cy";
    const path = "/workspace/main.cy";
    const text =
        \\const answer: i32 = 42;
        \\fn main(): i32 { return answer; }
        \\
    ;
    _ = try session.putDocument(uri, 1, text);

    const symbols_snapshot = (try session.parsedDocument(uri, path)).?;
    const symbols_json = try symbols.documentSymbolsFromProgramJson(std.testing.allocator, symbols_snapshot.program);
    defer std.testing.allocator.free(symbols_json);
    try std.testing.expect(std.mem.indexOf(u8, symbols_json, "\"name\":\"answer\"") != null);

    const hover_snapshot = (try session.parsedDocument(uri, path)).?;
    const hover_json = try symbols.hoverFromProgramJson(std.testing.allocator, text, hover_snapshot.program, 1, 25);
    defer std.testing.allocator.free(hover_json);
    try std.testing.expect(!std.mem.eql(u8, hover_json, "null"));

    const definition_snapshot = (try session.parsedDocument(uri, path)).?;
    const definition_json = try symbols.definitionFromProgramJson(std.testing.allocator, path, text, definition_snapshot.program, 1, 25);
    defer std.testing.allocator.free(definition_json);
    try std.testing.expect(!std.mem.eql(u8, definition_json, "null"));

    const stats = session.parsedCacheSnapshot();
    try std.testing.expectEqual(@as(u64, 2), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
    try std.testing.expectEqual(@as(u64, 0), stats.invalidations);
}

test "lsp parsed snapshots cache malformed revision failures" {
    var session = session_mod.Session.init(std.testing.allocator);
    defer session.deinit();

    const uri = "file:///workspace/broken.cy";
    const path = "/workspace/broken.cy";
    _ = try session.putDocument(uri, 1, "fn broken(: i32 {\n");

    try std.testing.expectError(error.ParseFailed, session.parsedDocument(uri, path));
    try std.testing.expectError(error.ParseFailed, session.parsedDocument(uri, path));
    const stats = session.parsedCacheSnapshot();
    try std.testing.expectEqual(@as(u64, 1), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
    try std.testing.expectEqual(@as(u64, 0), stats.invalidations);
}

test "lsp semantic snapshot is shared by diagnostics hover and definition" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text =
        \\const answer: i32 = 42;
        \\fn main(): i32 { return answer; }
        \\
    ;
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = text });
    const path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(path);

    var session = session_mod.Session.init(std.testing.allocator);
    defer session.deinit();
    const uri = "file:///workspace/semantic-main.cy";
    _ = try session.putDocument(uri, 1, text);

    const diagnostic_snapshot = (try session.semanticDocument(uri, path, false)).?;
    try std.testing.expectEqual(@as(usize, 0), diagnostic_snapshot.diagnostics.len);

    const parsed = (try session.parsedDocument(uri, path)).?;
    const hover_snapshot = (try session.semanticDocument(uri, path, false)).?;
    const hover_json = try symbols.hoverFromSemanticSnapshotJson(
        std.testing.allocator,
        text,
        hover_snapshot,
        parsed.program,
        1,
        25,
    );
    defer std.testing.allocator.free(hover_json);
    try std.testing.expect(!std.mem.eql(u8, hover_json, "null"));

    const definition_snapshot = (try session.semanticDocument(uri, path, false)).?;
    const definition_json = try symbols.definitionFromSemanticSnapshotJson(
        std.testing.allocator,
        path,
        text,
        definition_snapshot,
        parsed.program,
        1,
        25,
    );
    defer std.testing.allocator.free(definition_json);
    try std.testing.expect(!std.mem.eql(u8, definition_json, "null"));

    const stats = session.semanticCacheSnapshot();
    try std.testing.expectEqual(@as(u64, 2), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
    try std.testing.expectEqual(@as(u64, 0), stats.invalidations);
}

test "lsp hover reports narrowed optional types at uses and captures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text =
        \\fn truth(value: ?i32): i32 {
        \\    if value {
        \\        const result = value + 1;
        \\        return result;
        \\    }
        \\    return 0;
        \\}
        \\fn capture(value: ?i32): i32 {
        \\    if value is payload {
        \\        return payload + 1;
        \\    }
        \\    return 0;
        \\}
        \\fn guard(value: ?i32): i32 {
        \\    if value is none { return 0; }
        \\    const result = value + 1;
        \\    return result;
        \\}
        \\fn main(): i32 { return 0; }
        \\
    ;
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "hover_narrowing.cy", .data = text });
    const path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "hover_narrowing.cy");
    defer std.testing.allocator.free(path);

    var session = session_mod.Session.init(std.testing.allocator);
    defer session.deinit();
    const uri = "file:///workspace/hover-narrowing.cy";
    _ = try session.putDocument(uri, 1, text);
    const snapshot = (try session.semanticDocument(uri, path, false)).?;
    try std.testing.expectEqual(@as(usize, 0), snapshot.diagnostics.len);

    const truth_use = try hoverAtOccurrence(std.testing.allocator, text, snapshot, "value + 1", 0);
    defer std.testing.allocator.free(truth_use);
    try std.testing.expect(std.mem.indexOf(u8, truth_use, "value: i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, truth_use, "?i32") == null);

    const capture_decl = try hoverAtOccurrence(std.testing.allocator, text, snapshot, "payload", 0);
    defer std.testing.allocator.free(capture_decl);
    try std.testing.expect(std.mem.indexOf(u8, capture_decl, "payload: i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture_decl, "?i32") == null);

    const capture_use = try hoverAtOccurrence(std.testing.allocator, text, snapshot, "payload + 1", 0);
    defer std.testing.allocator.free(capture_use);
    try std.testing.expect(std.mem.indexOf(u8, capture_use, "payload: i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture_use, "?i32") == null);

    const guard_use = try hoverAtOccurrence(std.testing.allocator, text, snapshot, "value + 1", 1);
    defer std.testing.allocator.free(guard_use);
    try std.testing.expect(std.mem.indexOf(u8, guard_use, "value: i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, guard_use, "?i32") == null);
}

test "lsp semantic snapshot caches failures and recovers on content change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const initial_text = "fn main(): i32 { return missing_name; }\n";
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = initial_text });
    const path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(path);

    var session = session_mod.Session.init(std.testing.allocator);
    defer session.deinit();
    const uri = "file:///workspace/recovery-main.cy";
    _ = try session.putDocument(uri, 1, initial_text);

    const failed = (try session.semanticDocument(uri, path, false)).?;
    try std.testing.expect(failed.diagnostics.len != 0);
    _ = (try session.semanticDocument(uri, path, false)).?;

    const recovered_text = "fn main(): i32 { return 0; }\n";
    _ = try session.putDocument(uri, 2, recovered_text);
    const recovered = (try session.semanticDocument(uri, path, false)).?;
    try std.testing.expectEqual(@as(usize, 0), recovered.diagnostics.len);

    const stats = session.semanticCacheSnapshot();
    try std.testing.expectEqual(@as(u64, 1), stats.hits);
    try std.testing.expectEqual(@as(u64, 2), stats.misses);
    try std.testing.expectEqual(@as(u64, 1), stats.invalidations);
}

fn hoverAtOccurrence(
    allocator: std.mem.Allocator,
    text: []const u8,
    snapshot: anytype,
    needle: []const u8,
    occurrence: usize,
) ![]u8 {
    var offset: usize = 0;
    var seen: usize = 0;
    while (true) {
        const index = std.mem.indexOfPos(u8, text, offset, needle) orelse return error.TestExpectedEqual;
        if (seen == occurrence) {
            var line: usize = 0;
            for (text[0..index]) |byte| if (byte == '\n') {
                line += 1;
            };
            const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..index], '\n')) |newline| newline + 1 else 0;
            return symbols.hoverFromSemanticSnapshotJson(allocator, text, snapshot, null, line, index - line_start + 1);
        }
        offset = index + needle.len;
        seen += 1;
    }
}

test "lsp semantic snapshot preserves project-aware hover and definition" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "lsp-semantic-project"
        \\src = "."
        \\entry = "main.cy"
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "util.cy",
        .data =
        \\pub fn answer(): i32 { return 42; }
        \\
        ,
    });
    const text =
        \\import .util;
        \\fn main(): i32 { return util.answer(); }
        \\
    ;
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = text });
    const path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(path);

    var session = session_mod.Session.init(std.testing.allocator);
    defer session.deinit();
    const uri = "file:///workspace/project-main.cy";
    _ = try session.putDocument(uri, 1, text);

    const diagnostic_snapshot = (try session.semanticDocument(uri, path, true)).?;
    try std.testing.expectEqual(@as(usize, 0), diagnostic_snapshot.diagnostics.len);
    try std.testing.expect(diagnostic_snapshot.loaded != null);

    const parsed = (try session.parsedDocument(uri, path)).?;
    const hover_snapshot = (try session.semanticDocument(uri, path, true)).?;
    const hover_json = try symbols.hoverFromSemanticSnapshotJson(
        std.testing.allocator,
        text,
        hover_snapshot,
        parsed.program,
        1,
        30,
    );
    defer std.testing.allocator.free(hover_json);
    try std.testing.expect(!std.mem.eql(u8, hover_json, "null"));

    const definition_snapshot = (try session.semanticDocument(uri, path, true)).?;
    const definition_json = try symbols.definitionFromSemanticSnapshotJson(
        std.testing.allocator,
        path,
        text,
        definition_snapshot,
        parsed.program,
        1,
        30,
    );
    defer std.testing.allocator.free(definition_json);
    try std.testing.expect(std.mem.indexOf(u8, definition_json, "util.cy") != null);

    const stats = session.semanticCacheSnapshot();
    try std.testing.expectEqual(@as(u64, 2), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
    try std.testing.expectEqual(@as(u64, 0), stats.invalidations);
}

test "lsp dependency graph selectively invalidates transitive dependents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "lsp-dependency-project"
        \\src = "."
        \\entry = "c.cy"
        \\
        ,
    });
    const shared_text = "pub fn value(): i32 { return 1; }\n";
    const a_text =
        \\import .shared;
        \\pub fn from_a(): i32 { return shared.value(); }
        \\
    ;
    const c_text =
        \\import .a;
        \\fn main(): i32 { return a.from_a(); }
        \\
    ;
    const b_text = "fn independent(): i32 { return 7; }\n";
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "shared.cy", .data = shared_text });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "a.cy", .data = a_text });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "c.cy", .data = c_text });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "b.cy", .data = b_text });

    const shared_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "shared.cy");
    defer std.testing.allocator.free(shared_path);
    const a_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "a.cy");
    defer std.testing.allocator.free(a_path);
    const c_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "c.cy");
    defer std.testing.allocator.free(c_path);
    const b_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "b.cy");
    defer std.testing.allocator.free(b_path);

    var session = session_mod.Session.init(std.testing.allocator);
    defer session.deinit();
    const shared_uri = "file:///workspace/deps/shared.cy";
    const a_uri = "file:///workspace/deps/a.cy";
    const c_uri = "file:///workspace/deps/c.cy";
    const b_uri = "file:///workspace/deps/b.cy";
    _ = try session.putDocument(shared_uri, 1, shared_text);
    _ = try session.putDocument(a_uri, 1, a_text);
    _ = try session.putDocument(c_uri, 1, c_text);
    _ = try session.putDocument(b_uri, 1, b_text);

    _ = (try session.semanticDocument(shared_uri, shared_path, true)).?;
    _ = (try session.semanticDocument(a_uri, a_path, true)).?;
    _ = (try session.semanticDocument(c_uri, c_path, true)).?;
    _ = (try session.semanticDocument(b_uri, b_path, true)).?;
    const graph = session.dependencyGraphSnapshot();
    try std.testing.expect(graph.nodes >= 4);
    try std.testing.expect(graph.edges >= 4);

    const broken_shared = "pub fn value(): i32 { return missing_dependency_value; }\n";
    _ = try session.putDocument(shared_uri, 2, broken_shared);
    var stats = session.semanticCacheSnapshot();
    try std.testing.expectEqual(@as(u64, 2), stats.dependency_invalidations);
    try std.testing.expectEqual(@as(u64, 3), stats.invalidations);

    const unaffected = (try session.semanticDocument(b_uri, b_path, true)).?;
    try std.testing.expectEqual(@as(usize, 0), unaffected.diagnostics.len);
    const broken_a = (try session.semanticDocument(a_uri, a_path, true)).?;
    try std.testing.expect(broken_a.diagnostics.len != 0);
    const broken_c = (try session.semanticDocument(c_uri, c_path, true)).?;
    try std.testing.expect(broken_c.diagnostics.len != 0);

    _ = try session.putDocument(shared_uri, 3, shared_text);
    stats = session.semanticCacheSnapshot();
    try std.testing.expectEqual(@as(u64, 4), stats.dependency_invalidations);
    const recovered_a = (try session.semanticDocument(a_uri, a_path, true)).?;
    try std.testing.expectEqual(@as(usize, 0), recovered_a.diagnostics.len);
    const recovered_c = (try session.semanticDocument(c_uri, c_path, true)).?;
    try std.testing.expectEqual(@as(usize, 0), recovered_c.diagnostics.len);

    const final_stats = session.semanticCacheSnapshot();
    try std.testing.expect(final_stats.hits >= 1);
}

test "lsp dependency graph recovers missing removed and renamed imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "lsp-import-recovery"
        \\src = "."
        \\entry = "main.cy"
        \\
        ,
    });
    const missing_import_text =
        \\import .missing;
        \\fn main(): i32 { return missing.value(); }
        \\
    ;
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = missing_import_text });
    const main_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(main_path);
    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root_path);
    const missing_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "missing.cy" });
    defer std.testing.allocator.free(missing_path);
    const renamed_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "renamed.cy" });
    defer std.testing.allocator.free(renamed_path);

    var session = session_mod.Session.init(std.testing.allocator);
    defer session.deinit();
    const main_uri = "file:///workspace/imports/main.cy";
    const missing_uri = "file:///workspace/imports/missing.cy";
    const renamed_uri = "file:///workspace/imports/renamed.cy";
    _ = try session.putDocument(main_uri, 1, missing_import_text);

    const missing = (try session.semanticDocument(main_uri, main_path, true)).?;
    try std.testing.expect(missing.diagnostics.len != 0);

    const dependency_text = "pub fn value(): i32 { return 42; }\n";
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "missing.cy", .data = dependency_text });
    _ = try session.putDocument(missing_uri, 1, dependency_text);
    _ = (try session.semanticDocument(missing_uri, missing_path, true)).?;
    var recovered = (try session.semanticDocument(main_uri, main_path, true)).?;
    try std.testing.expectEqual(@as(usize, 0), recovered.diagnostics.len);

    try tmp.dir.rename("missing.cy", tmp.dir, "renamed.cy", compat.io());
    session.removeDocument(missing_uri);
    const removed = (try session.semanticDocument(main_uri, main_path, true)).?;
    try std.testing.expect(removed.diagnostics.len != 0);

    const renamed_import_text =
        \\import .renamed;
        \\fn main(): i32 { return renamed.value(); }
        \\
    ;
    _ = try session.putDocument(main_uri, 2, renamed_import_text);
    _ = try session.putDocument(renamed_uri, 1, dependency_text);
    _ = (try session.semanticDocument(renamed_uri, renamed_path, true)).?;
    recovered = (try session.semanticDocument(main_uri, main_path, false)).?;
    try std.testing.expectEqual(@as(usize, 0), recovered.diagnostics.len);

    const stats = session.semanticCacheSnapshot();
    try std.testing.expect(stats.dependency_invalidations >= 2);
}

test "lsp dependency invalidation terminates across import cycles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "lsp-cycle-project"
        \\src = "."
        \\entry = "a.cy"
        \\
        ,
    });
    const a_text =
        \\import .b;
        \\pub fn from_a(): i32 { return 1; }
        \\
    ;
    const b_text =
        \\import .a;
        \\pub fn from_b(): i32 { return 2; }
        \\
    ;
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "a.cy", .data = a_text });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "b.cy", .data = b_text });
    const a_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "a.cy");
    defer std.testing.allocator.free(a_path);
    const b_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "b.cy");
    defer std.testing.allocator.free(b_path);

    var session = session_mod.Session.init(std.testing.allocator);
    defer session.deinit();
    const a_uri = "file:///workspace/cycle/a.cy";
    const b_uri = "file:///workspace/cycle/b.cy";
    _ = try session.putDocument(a_uri, 1, a_text);
    _ = try session.putDocument(b_uri, 1, b_text);
    _ = (try session.parsedDocument(a_uri, a_path)).?;
    _ = (try session.parsedDocument(b_uri, b_path)).?;
    _ = (try session.semanticDocument(a_uri, a_path, true)).?;
    _ = (try session.semanticDocument(b_uri, b_path, true)).?;

    _ = try session.putDocument(a_uri, 2, a_text ++ "\n");
    const stats = session.semanticCacheSnapshot();
    try std.testing.expectEqual(@as(u64, 1), stats.dependency_invalidations);
}

test "lsp semantic batch single-flights duplicate revision requests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text = "fn main(): i32 { return 0; }\n";
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = text });
    const path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(path);

    var session = session_mod.Session.init(std.testing.allocator);
    defer session.deinit();
    const uri = "file:///workspace/single-flight/main.cy";
    _ = try session.putDocument(uri, 1, text);
    const request = session_mod.SemanticRequest{
        .uri = uri,
        .path = path,
        .matches_disk = true,
    };
    const requests = [_]session_mod.SemanticRequest{ request, request, request, request };

    const first = try session.prepareSemanticDocuments(std.testing.allocator, &requests, 4);
    defer std.testing.allocator.free(first);
    for (first[1..]) |snapshot| try std.testing.expectEqual(first[0], snapshot);

    var cache_stats = session.semanticCacheSnapshot();
    try std.testing.expectEqual(@as(u64, 1), cache_stats.misses);
    try std.testing.expectEqual(@as(u64, 3), cache_stats.hits);
    var scheduler_stats = session.schedulerSnapshot();
    try std.testing.expectEqual(@as(u64, 1), scheduler_stats.batches);
    try std.testing.expectEqual(@as(u64, 1), scheduler_stats.jobs);
    try std.testing.expectEqual(@as(u64, 3), scheduler_stats.coalesced_requests);
    try std.testing.expectEqual(@as(usize, 1), scheduler_stats.max_scheduled_parallelism);

    const second = try session.prepareSemanticDocuments(std.testing.allocator, &requests, 4);
    defer std.testing.allocator.free(second);
    for (second) |snapshot| try std.testing.expectEqual(first[0], snapshot);
    cache_stats = session.semanticCacheSnapshot();
    try std.testing.expectEqual(@as(u64, 1), cache_stats.misses);
    try std.testing.expectEqual(@as(u64, 7), cache_stats.hits);
    scheduler_stats = session.schedulerSnapshot();
    try std.testing.expectEqual(@as(u64, 1), scheduler_stats.batches);
    try std.testing.expectEqual(@as(u64, 1), scheduler_stats.jobs);
}

test "lsp semantic batch rebuilds independent revisions with bounded parallelism" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a_text = "fn a(): i32 { return 1; }\n";
    const b_text = "fn b(): i32 { return missing_parallel_b; }\n";
    const c_text = "fn c(): i32 { return 3; }\n";
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "a.cy", .data = a_text });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "b.cy", .data = b_text });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "c.cy", .data = c_text });
    const a_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "a.cy");
    defer std.testing.allocator.free(a_path);
    const b_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "b.cy");
    defer std.testing.allocator.free(b_path);
    const c_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "c.cy");
    defer std.testing.allocator.free(c_path);

    var session = session_mod.Session.init(std.testing.allocator);
    defer session.deinit();
    const a_uri = "file:///workspace/parallel/a.cy";
    const b_uri = "file:///workspace/parallel/b.cy";
    const c_uri = "file:///workspace/parallel/c.cy";
    _ = try session.putDocument(a_uri, 1, a_text);
    _ = try session.putDocument(b_uri, 1, b_text);
    _ = try session.putDocument(c_uri, 1, c_text);

    const requests = [_]session_mod.SemanticRequest{
        .{ .uri = c_uri, .path = c_path, .matches_disk = true },
        .{ .uri = a_uri, .path = a_path, .matches_disk = true },
        .{ .uri = b_uri, .path = b_path, .matches_disk = true },
    };
    const first = try session.prepareSemanticDocuments(std.testing.allocator, &requests, 2);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqual(@as(usize, 0), first[0].diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), first[1].diagnostics.len);
    try std.testing.expect(first[2].diagnostics.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, first[2].diagnostics[0].message, "missing_parallel_b") != null);

    var scheduler_stats = session.schedulerSnapshot();
    try std.testing.expectEqual(@as(u64, 1), scheduler_stats.batches);
    try std.testing.expectEqual(@as(u64, 3), scheduler_stats.jobs);
    try std.testing.expectEqual(@as(usize, 2), scheduler_stats.max_scheduled_parallelism);

    _ = try session.putDocument(a_uri, 2, a_text ++ "\n");
    _ = try session.putDocument(b_uri, 2, b_text ++ "\n");
    _ = try session.putDocument(c_uri, 2, c_text ++ "\n");
    const rebuilt = try session.prepareSemanticDocuments(std.testing.allocator, &requests, 2);
    defer std.testing.allocator.free(rebuilt);
    try std.testing.expectEqual(@as(usize, 0), rebuilt[0].diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), rebuilt[1].diagnostics.len);
    try std.testing.expect(rebuilt[2].diagnostics.len != 0);

    scheduler_stats = session.schedulerSnapshot();
    try std.testing.expectEqual(@as(u64, 2), scheduler_stats.batches);
    try std.testing.expectEqual(@as(u64, 6), scheduler_stats.jobs);
    try std.testing.expectEqual(@as(usize, 2), scheduler_stats.max_scheduled_parallelism);
}

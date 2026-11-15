const std = @import("std");
const compat = @import("cyna").compat;
const compiler = @import("cyna").compiler;
const lsp_diagnostics = @import("cyna").lsp.diagnostics;

test "lsp accepts TaskGroup without mandatory settlement diagnostics" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (problem) { return 1; };
        \\    return 0;
        \\}
    ;
    for (0..3) |_| {
        const items = try lsp_diagnostics.collect(std.testing.allocator, "late_settlement.cy", source, false);
        defer lsp_diagnostics.deinit(std.testing.allocator, items);
        try std.testing.expectEqual(@as(usize, 0), items.len);
    }
}

const ConcurrentDiagnosticJob = struct {
    path: []const u8,
    source: []const u8,
    expected: []const u8,
    unexpected: []const u8,
    is_test_root: bool = false,
    found_expected: bool = false,
    found_unexpected: bool = false,
    item_count: usize = 0,
    failure: ?anyerror = null,

    fn run(self: *ConcurrentDiagnosticJob) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const items = lsp_diagnostics.collect(arena.allocator(), self.path, self.source, self.is_test_root) catch |err| {
            self.failure = err;
            return;
        };
        self.item_count = items.len;
        for (items) |item| {
            if (std.mem.indexOf(u8, item.message, self.expected) != null) self.found_expected = true;
            if (std.mem.indexOf(u8, item.message, self.unexpected) != null) self.found_unexpected = true;
        }
    }
};

fn collectExplicitSemanticFailure(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    sink: *compiler.diagnostics.Sink,
) !void {
    var diagnostic_context = compiler.diagnostics.Context.structured(sink);
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    var program = try compiler.parser.parseWithDiagnostics(allocator, path, source, tokens, &diagnostic_context);
    defer program.deinit(allocator);
    try std.testing.expectError(error.SemanticFailed, compiler.sema.buildSirWithOptions(allocator, path, program, .{
        .diagnostic_context = diagnostic_context,
    }));
}

test "lsp diagnostics run compiler checks for unsaved document text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\fn main(): i32 {
        \\    return 0;
        \\}
        \\
        ,
    });

    const path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(path);
    const cwd_path = try compat.currentPathAlloc(std.testing.allocator);
    defer std.testing.allocator.free(cwd_path);
    const relative_path = if (std.mem.startsWith(u8, path, cwd_path))
        path[cwd_path.len + 1 ..]
    else
        path;

    const dirty_source =
        \\fn main(): i32 {
        \\    const value = ;
        \\    return 0;
        \\}
        \\
    ;

    const items = lsp_diagnostics.collect(std.testing.allocator, relative_path, dirty_source, false) catch |err| {
        std.debug.print("LSP diagnostics collect failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer lsp_diagnostics.deinit(std.testing.allocator, items);

    if (items.len == 0) {
        std.debug.print("expected at least one LSP diagnostic\n", .{});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, items[0].message, "expected expression") == null) {
        std.debug.print("unexpected LSP diagnostic: {s}\n", .{items[0].message});
        return error.TestUnexpectedResult;
    }
}

test "lsp publishes ordered independent parser errors" {
    const source =
        \\broken_one
        \\fn valid(): i32 { return 1; }
        \\broken_two
        \\fn main(): i32 { return valid(); }
        \\
    ;
    const items = try lsp_diagnostics.collect(std.testing.allocator, "lsp_multi_error.cy", source, false);
    defer lsp_diagnostics.deinit(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(compiler.diagnostics.DiagnosticCode.parse_syntax, items[0].code);
    try std.testing.expectEqual(compiler.diagnostics.DiagnosticCode.parse_syntax, items[1].code);
    try std.testing.expect(items[0].primary.?.start < items[1].primary.?.start);
}

test "lsp explains the capturing callable refactor boundary" {
    const source =
        \\fn apply(value: i32, callback: fn(i32): i32): i32 {
        \\    return callback(value);
        \\}
        \\
        \\fn main(): i32 {
        \\    const bias = 1;
        \\    return apply(41, |value| {
        \\        return value + bias;
        \\    });
        \\}
        \\
    ;

    const items = try lsp_diagnostics.collect(std.testing.allocator, "lsp_callable_refactor.cy", source, false);
    defer lsp_diagnostics.deinit(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(compiler.diagnostics.DiagnosticCode.ownership_capture, items[0].code);
    try std.testing.expect(std.mem.indexOf(
        u8,
        items[0].message,
        "pass the lambda directly to a `(...) => R` parameter, or store explicit context beside the function pointer",
    ) != null);
}

test "lsp keeps collection bound and ownership failures on the user operation" {
    const cases = [_]struct {
        path: []const u8,
        source: []const u8,
        expected: []const u8,
        expected_line: usize,
        expects_definition_diagnostic: bool,
    }{
        .{
            .path = "collection_missing_eq.cy",
            .source =
            \\struct Missing {
            \\    value: i32;
            \\}
            \\fn main(): i32 {
            \\    var values: Set<Missing> = set<Missing>();
            \\    return values.len() as i32;
            \\}
            ,
            .expected = "does not implement protocol `std.prelude.Eq`",
            .expected_line = 5,
            .expects_definition_diagnostic = false,
        },
        .{
            .path = "collection_resource_snapshot.cy",
            .source =
            \\struct Key {
            \\    id: i32;
            \\    values: List<i32>;
            \\}
            \\impl Key: Eq {
            \\    fn eq(self: &const Key, other: &const Key): bool {
            \\        return self.id == other.id;
            \\    }
            \\}
            \\fn main(): i32 {
            \\    var values: Map<Key, i32> = map<Key, i32>();
            \\    const keys = values.keys();
            \\    return keys.len() as i32;
            \\}
            ,
            .expected = "method `keys` is unavailable for receiver",
            .expected_line = 12,
            .expects_definition_diagnostic = true,
        },
    };

    for (cases) |case| {
        const items = try lsp_diagnostics.collect(std.testing.allocator, case.path, case.source, false);
        defer lsp_diagnostics.deinit(std.testing.allocator, items);

        var found_user_diagnostic = false;
        var found_definition_diagnostic = false;
        for (items) |item| {
            if (std.mem.indexOf(u8, item.message, case.expected) != null) {
                try std.testing.expect(std.mem.endsWith(u8, item.path, case.path));
                try std.testing.expect(item.primary != null);
                try std.testing.expectEqual(case.expected_line, item.primary.?.line);
                found_user_diagnostic = true;
            }
            if (std.mem.indexOf(u8, item.message, "cannot hand off a projected owned value") != null) {
                try std.testing.expect(std.mem.endsWith(u8, item.path, "packages/std/src/std_prelude.cy"));
                found_definition_diagnostic = true;
            }
        }
        try std.testing.expect(found_user_diagnostic);
        try std.testing.expectEqual(case.expects_definition_diagnostic, found_definition_diagnostic);
    }
}

test "lsp diagnostics allow test roots to access private friend declarations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "math.cy",
        .data =
        \\const answer: i32 = 42;
        \\fn add_private(a: i32, b: i32): i32 { return a + b; }
        \\
        ,
    });
    const test_source =
        \\import { answer, add_private } from .math;
        \\test "friend access" {
        \\    assert(add_private(20, 22) == answer);
        \\}
        \\
    ;
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "math.test.cy",
        .data = test_source,
    });

    const path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "math.test.cy");
    defer std.testing.allocator.free(path);
    const items = try lsp_diagnostics.collect(std.testing.allocator, path, test_source, true);
    defer lsp_diagnostics.deinit(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "concurrent lsp diagnostic requests keep structured sinks isolated" {
    var first = ConcurrentDiagnosticJob{
        .path = "parallel_diagnostic_first.cy",
        .source =
        \\fn main(): i32 {
        \\    return missing_parallel_name;
        \\}
        ,
        .expected = "missing_parallel_name",
        .unexpected = "expected expression",
    };
    var second = ConcurrentDiagnosticJob{
        .path = "parallel_diagnostic_second.cy",
        .source =
        \\fn main(): i32 {
        \\    const value = ;
        \\    return 0;
        \\}
        ,
        .expected = "expected expression",
        .unexpected = "missing_parallel_name",
    };

    const first_thread = try std.Thread.spawn(.{}, ConcurrentDiagnosticJob.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, ConcurrentDiagnosticJob.run, .{&second});
    first_thread.join();
    second_thread.join();

    if (first.failure) |err| return err;
    if (second.failure) |err| return err;
    try std.testing.expect(first.item_count != 0);
    try std.testing.expect(second.item_count != 0);
    try std.testing.expect(first.found_expected);
    try std.testing.expect(!first.found_unexpected);
    try std.testing.expect(second.found_expected);
    try std.testing.expect(!second.found_unexpected);
}

test "concurrent semantic requests keep test-friend access request-local" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "math.cy",
        .data = "const answer: i32 = 42;\n",
    });
    const friend_source =
        \\import { answer } from .math;
        \\test "friend access" {
        \\    assert(answer == 42);
        \\}
        \\
    ;
    const ordinary_source =
        \\import { answer } from .math;
        \\fn main(): i32 {
        \\    return answer;
        \\}
        \\
    ;
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "math.test.cy", .data = friend_source });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "consumer.cy", .data = ordinary_source });

    const friend_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "math.test.cy");
    defer std.testing.allocator.free(friend_path);
    const ordinary_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "consumer.cy");
    defer std.testing.allocator.free(ordinary_path);

    var friend = ConcurrentDiagnosticJob{
        .path = friend_path,
        .source = friend_source,
        .expected = "",
        .unexpected = "not public",
        .is_test_root = true,
    };
    var ordinary = ConcurrentDiagnosticJob{
        .path = ordinary_path,
        .source = ordinary_source,
        .expected = "",
        .unexpected = "expected expression",
    };

    const friend_thread = try std.Thread.spawn(.{}, ConcurrentDiagnosticJob.run, .{&friend});
    const ordinary_thread = try std.Thread.spawn(.{}, ConcurrentDiagnosticJob.run, .{&ordinary});
    friend_thread.join();
    ordinary_thread.join();

    if (friend.failure) |err| {
        std.debug.print("friend request failed: {s}\n", .{@errorName(err)});
        return err;
    }
    if (ordinary.failure) |err| {
        std.debug.print("ordinary request failed: {s}\n", .{@errorName(err)});
        return err;
    }
    if (friend.item_count != 0 or friend.found_unexpected or ordinary.item_count == 0 or !ordinary.found_expected) {
        std.debug.print(
            "friend diagnostics={d} unexpected={} ordinary diagnostics={d} found_expected={}\n",
            .{ friend.item_count, friend.found_unexpected, ordinary.item_count, ordinary.found_expected },
        );
        return error.TestUnexpectedResult;
    }
}

test "overlapping compiler requests retain independent diagnostic ownership" {
    var outer_sink = compiler.diagnostics.Sink.init(std.testing.allocator);
    defer outer_sink.deinit();
    try collectExplicitSemanticFailure(
        std.testing.allocator,
        "outer_request.cy",
        "fn outer(): i32 { return missing_outer; }",
        &outer_sink,
    );

    var inner_sink = compiler.diagnostics.Sink.init(std.testing.allocator);
    defer inner_sink.deinit();
    try collectExplicitSemanticFailure(
        std.testing.allocator,
        "inner_request.cy",
        "fn inner(): i32 { return missing_inner; }",
        &inner_sink,
    );

    try std.testing.expectEqual(@as(usize, 1), outer_sink.records.items.len);
    try std.testing.expectEqualStrings("outer_request.cy", outer_sink.records.items[0].path);
    try std.testing.expect(std.mem.indexOf(u8, outer_sink.records.items[0].message, "missing_outer") != null);
    try std.testing.expectEqual(@as(usize, 1), inner_sink.records.items.len);
    try std.testing.expectEqualStrings("inner_request.cy", inner_sink.records.items[0].path);
    try std.testing.expect(std.mem.indexOf(u8, inner_sink.records.items[0].message, "missing_inner") != null);
}

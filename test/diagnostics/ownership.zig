const std = @import("std");
const compiler = @import("cyna").compiler;

const diagnostics = compiler.diagnostics;

const Expected = struct {
    code: diagnostics.DiagnosticCode,
    message: []const u8,
    min_labels: usize = 0,
    min_notes: usize = 1,
    expect_help: bool = true,
};

fn expectOwnershipDiagnostic(name: []const u8, source: []const u8, expected: Expected) !void {
    const allocator = std.testing.allocator;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, name, source, tokens);
    defer program.deinit(allocator);

    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    try std.testing.expectError(error.SemanticFailed, compiler.sema.buildSirWithOptions(allocator, name, program, .{
        .diagnostic_context = diagnostics.Context.structured(&sink),
    }));
    try std.testing.expect(sink.records.items.len != 0);

    const record = for (sink.records.items) |candidate| {
        if (std.mem.indexOf(u8, candidate.message, expected.message) != null) break candidate;
    } else return error.ExpectedOwnershipDiagnostic;
    try std.testing.expectEqual(expected.code, record.code);
    try std.testing.expect(record.primary != null);
    try std.testing.expectEqual(expected.min_labels, @min(record.labels.len, expected.min_labels));
    try std.testing.expectEqual(expected.min_notes, @min(record.notes.len, expected.min_notes));
    try std.testing.expectEqual(expected.expect_help, record.help != null);
}

test "ownership diagnostics explain generic projected borrow escape" {
    const source =
        \\struct User { age: i32; }
        \\struct Box<T> { value: T; }
        \\fn bad(): Box<&User> {
        \\    var user = User { age: 0 };
        \\    return Box<&User> { value: &user };
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try expectOwnershipDiagnostic("ownership_generic_projection", source, .{
        .code = .ownership_borrow_escape,
        .message = "cannot escape the function via return",
        .min_labels = 1,
    });
}

test "ownership diagnostics link projected mutation to borrow creation" {
    const source =
        \\struct User { age: i32; }
        \\struct UserView { user: &User; }
        \\fn main(): i32 {
        \\    var user = User { age: 0 };
        \\    const view = UserView { user: &user };
        \\    user.age = 42;
        \\    return view.user.age;
        \\}
    ;
    try expectOwnershipDiagnostic("ownership_projection_conflict", source, .{
        .code = .ownership_live_borrow_conflict,
        .message = "overlapping borrow `view` is live",
        .min_labels = 1,
    });
}

test "ownership diagnostics explain source invalidation" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: [:]i32;
        \\}
        \\fn main(): i32 {
        \\    var user = User { age: 1, scores: [:]i32 [] };
        \\    const alias: &User = &user;
        \\    drop user;
        \\    return alias.age;
        \\}
    ;
    try expectOwnershipDiagnostic("ownership_source_invalidation", source, .{
        .code = .ownership_invalidation,
        .message = "while borrow `alias` is live",
        .min_labels = 1,
    });
}

test "ownership diagnostics explain interprocedural side-effect escape" {
    const source =
        \\struct Holder { view: []i32; }
        \\fn store(xs: []i32, holder: &Holder): void {
        \\    holder.view = xs;
        \\}
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [0];
        \\    var holder = Holder { view: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [1, 2];
        \\        store(fixed[..], &holder);
        \\    }
        \\    return 0;
        \\}
    ;
    try expectOwnershipDiagnostic("ownership_call_summary", source, .{
        .code = .ownership_borrow_escape,
        .message = "function call side effects",
        .min_labels = 1,
    });
}

test "ownership diagnostics retain handoff location across a branch join" {
    const source =
        \\fn main(): i32 {
        \\    var values = [:]i32 [1];
        \\    if true {
        \\        drop values;
        \\    }
        \\    return values.len();
        \\}
    ;
    try expectOwnershipDiagnostic("ownership_branch_handoff", source, .{
        .code = .ownership_use_after_transfer,
        .message = "was handed off or dropped",
        .min_labels = 1,
    });
}

test "ownership diagnostics classify double cleanup" {
    const source =
        \\fn main(): i32 {
        \\    var values = [:]i32 [1];
        \\    drop values;
        \\    drop values;
        \\    return 0;
        \\}
    ;
    try expectOwnershipDiagnostic("ownership_double_cleanup", source, .{
        .code = .ownership_cleanup,
        .message = "was already handed off or dropped",
        .min_labels = 1,
    });
}

test "ownership diagnostics classify forbidden capture" {
    const source =
        \\fn apply(value: i32, f: fn(i32): i32): i32 {
        \\    return f(value);
        \\}
        \\fn main(): i32 {
        \\    const bias = 1;
        \\    return apply(41, fn(x) {
        \\        return x + bias;
        \\    });
        \\}
    ;
    try expectOwnershipDiagnostic("ownership_capture", source, .{
        .code = .ownership_capture,
        .message = "cannot capture local `bias` as a stored `fn(...)` callback",
        .min_labels = 1,
    });
}

test "ownership diagnostics classify scoped allocator escape" {
    const source =
        \\fn main(): i32 {
        \\    var values = [:]string [];
        \\    using scoped alloc = 0 {
        \\        values.push("temporary");
        \\    }
        \\    return 0;
        \\}
    ;
    try expectOwnershipDiagnostic("ownership_scoped_escape", source, .{
        .code = .ownership_scoped_escape,
        .message = "scoped allocator values cannot escape",
    });
}

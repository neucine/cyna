const std = @import("std");
const cyna = @import("cyna");

const compiler = cyna.compiler;
const compat = cyna.compat;
const diagnostics = compiler.diagnostics;

const Expected = struct {
    code: diagnostics.DiagnosticCode,
    message: []const u8,
    min_labels: usize = 0,
    min_notes: usize = 1,
    help_contains: ?[]const u8 = null,
};

fn findExpected(sink: *const diagnostics.Sink, expected: Expected) !diagnostics.Record {
    const record = for (sink.records.items) |candidate| {
        if (std.mem.indexOf(u8, candidate.message, expected.message) != null) break candidate;
    } else return error.ExpectedStructuredDiagnostic;
    try std.testing.expectEqual(expected.code, record.code);
    try std.testing.expect(record.primary != null);
    try std.testing.expectEqual(expected.min_labels, @min(record.labels.len, expected.min_labels));
    try std.testing.expectEqual(expected.min_notes, @min(record.notes.len, expected.min_notes));
    if (expected.help_contains) |needle| {
        try std.testing.expect(record.help != null);
        try std.testing.expect(std.mem.indexOf(u8, record.help.?, needle) != null);
    }
    return record;
}

fn expectInline(name: []const u8, source: []const u8, expected: Expected) !void {
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
    _ = try findExpected(&sink, expected);
}

test "type mismatch links a return expression to its declared expectation" {
    const source =
        \\fn bad(): i32 {
        \\    return "wrong";
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try expectInline("diagnostic_return_origin", source, .{
        .code = .type_mismatch,
        .message = "type mismatch: expected i32, got string",
        .min_labels = 1,
        .help_contains = "expression type",
    });
}

test "type mismatch links a call argument to its parameter declaration" {
    const source =
        \\fn take(value: i32): i32 { return value; }
        \\fn main(): i32 { return take("wrong"); }
    ;
    try expectInline("diagnostic_parameter_origin", source, .{
        .code = .type_mismatch,
        .message = "type mismatch: expected i32, got string",
        .min_labels = 1,
    });
}

test "generic constraint reports concrete substitution and declarations" {
    const source =
        \\protocol Writer {
        \\    fn write(self: &Self, text: string): i32;
        \\}
        \\struct Blob {}
        \\fn take<T: Writer>(value: T): i32 { return 42; }
        \\fn main(): i32 { return take(Blob {}); }
    ;
    try expectInline("diagnostic_generic_constraint", source, .{
        .code = .generic_constraint,
        .message = "does not implement protocol",
        .min_labels = 2,
        .min_notes = 2,
        .help_contains = "matching impl",
    });
}

test "failed inferred generic equality is reported at the call site" {
    const source =
        \\struct Box { value: i32; }
        \\fn compare<T>(value: T): bool {
        \\    return value == value;
        \\}
        \\fn main(): i32 {
        \\    const equal = compare<Box>(Box { value: 0 });
        \\    if equal { return 1; }
        \\    return 0;
        \\}
    ;
    try expectInline("diagnostic_inferred_generic_requirement", source, .{
        .code = .generic_inference,
        .message = "generic function `compare` is unavailable for these type arguments",
        .min_labels = 1,
        .min_notes = 1,
        .help_contains = "inferred operations",
    });
}

test "generic arity and argument kind have distinct identities" {
    const arity_source =
        \\fn identity<T>(value: T): T { return value; }
        \\fn main(): i32 { return identity<i32, i64>(42); }
    ;
    try expectInline("diagnostic_generic_arity", arity_source, .{
        .code = .generic_arity,
        .message = "expects 1 generic arguments, got 2",
        .min_labels = 1,
    });

    const kind_source =
        \\struct Pool<T, const N: usize> { storage: [N]T; }
        \\fn main(): i32 {
        \\    const value: Pool<i32, i32> = Pool<i32, i32> { storage: [1]i32 [0] };
        \\    return 0;
        \\}
    ;
    try expectInline("diagnostic_generic_argument_kind", kind_source, .{
        .code = .generic_argument_kind,
        .message = "expects a compile-time `usize` value",
    });
}

test "lookup diagnostics distinguish values callables types and modules" {
    const value_source =
        \\fn main(): i32 {
        \\    const total = 42;
        \\    return totla;
        \\}
    ;
    try expectInline("diagnostic_unknown_value", value_source, .{
        .code = .name_unknown_value,
        .message = "unknown value `totla`",
        .help_contains = "total",
    });

    const callable_source =
        \\fn compute(): i32 { return 42; }
        \\fn main(): i32 { return comupte(); }
    ;
    try expectInline("diagnostic_unknown_callable", callable_source, .{
        .code = .name_unknown_callable,
        .message = "unknown function `comupte`",
        .help_contains = "compute",
    });

    const type_source =
        \\struct Widget {}
        \\fn use(value: Widgte): i32 { return 0; }
        \\fn main(): i32 { return 0; }
    ;
    try expectInline("diagnostic_unknown_type", type_source, .{
        .code = .name_unknown_type,
        .message = "unknown type `Widgte`",
        .help_contains = "Widget",
    });

    const module_source =
        \\fn use(value: missing.Widget): i32 { return 0; }
        \\fn main(): i32 { return 0; }
    ;
    try expectInline("diagnostic_unknown_module", module_source, .{
        .code = .name_unknown_module,
        .message = "unknown imported module `missing`",
        .help_contains = "import",
    });
}

test "duplicate generic parameter links the first declaration" {
    const source =
        \\fn pair<T, T>(left: T, right: T): T { return left; }
        \\fn main(): i32 { return 0; }
    ;
    try expectInline("diagnostic_duplicate_generic", source, .{
        .code = .duplicate_declaration,
        .message = "duplicate generic parameter `T`",
        .min_labels = 1,
    });
}

test "private and ambiguous imported types carry declaration locations" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "diagnostic-imports"
        \\src = "."
        \\entry = "main.cy"
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "model.cy",
        .data =
        \\struct Hidden {}
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\import .model;
        \\fn use(value: model.Hidden): i32 { return 0; }
        \\fn main(): i32 { return 0; }
        \\
        ,
    });

    const root_path = try compat.tmpDirRealpathAlloc(allocator, &tmp, "main.cy");
    defer allocator.free(root_path);
    var loaded = try compiler.loader.loadProgram(allocator, root_path);
    defer loaded.deinit(allocator);
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    try std.testing.expectError(error.SemanticFailed, compiler.sema.buildSirWithOptions(allocator, root_path, loaded.program, .{
        .diagnostic_context = diagnostics.Context.structured(&sink),
    }));
    const private_record = try findExpected(&sink, .{
        .code = .visibility_private,
        .message = "not public in imported module",
        .min_labels = 1,
    });
    try std.testing.expect(std.mem.endsWith(u8, private_record.labels[0].span.path, "model.cy"));
}

test "ambiguous imported type reports both candidate declarations" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "diagnostic-ambiguity"
        \\src = "."
        \\entry = "main.cy"
        \\
        ,
    });
    try compat.dirMakePath(tmp.dir, "left");
    try compat.dirMakePath(tmp.dir, "right");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "left/model.cy", .data = "pub union Result { ok; }\n" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "right/model.cy", .data = "pub union Result { ok; }\n" });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\import .left.model;
        \\import .right.model as right_model;
        \\struct Holder { result: Result; }
        \\fn main(): i32 { return 0; }
        \\
        ,
    });

    const root_path = try compat.tmpDirRealpathAlloc(allocator, &tmp, "main.cy");
    defer allocator.free(root_path);
    var loaded = try compiler.loader.loadProgram(allocator, root_path);
    defer loaded.deinit(allocator);
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    try std.testing.expectError(error.SemanticFailed, compiler.sema.buildSirWithOptions(allocator, root_path, loaded.program, .{
        .diagnostic_context = diagnostics.Context.structured(&sink),
    }));
    _ = try findExpected(&sink, .{
        .code = .name_ambiguous,
        .message = "ambiguous type name `Result`",
        .min_labels = 2,
        .help_contains = "qualified",
    });
}

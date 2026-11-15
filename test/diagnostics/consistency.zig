const std = @import("std");
const cyna = @import("cyna");

const compat = cyna.compat;
const compiler = cyna.compiler;
const diagnostics = compiler.diagnostics;

const forbidden_product_vocabulary = [_][]const u8{
    "scaffold",
    "not supported yet",
    "in this implementation",
    "currently",
    "in v1",
};

fn expectProductVocabulary(record: diagnostics.Record) !void {
    var lower_buffer: [2048]u8 = undefined;
    const message = record.message[0..@min(record.message.len, lower_buffer.len)];
    const lower = std.ascii.lowerString(lower_buffer[0..message.len], message);
    for (forbidden_product_vocabulary) |phrase| {
        try std.testing.expect(std.mem.indexOf(u8, lower, phrase) == null);
    }
}

fn findRecord(sink: *const diagnostics.Sink, message: []const u8) !diagnostics.Record {
    return for (sink.records.items) |record| {
        try expectProductVocabulary(record);
        if (std.mem.indexOf(u8, record.message, message) != null) break record;
    } else error.ExpectedJourneyDiagnostic;
}

fn expectInlineFailure(
    name: []const u8,
    source: []const u8,
    options: compiler.sema.BuildOptions,
    code: diagnostics.DiagnosticCode,
    message: []const u8,
    help: ?[]const u8,
) !void {
    const allocator = std.testing.allocator;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, name, source, tokens);
    defer program.deinit(allocator);

    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    var build_options = options;
    build_options.diagnostic_context = diagnostics.Context.structured(&sink);
    try std.testing.expectError(
        error.SemanticFailed,
        compiler.sema.buildSirWithOptions(allocator, name, program, build_options),
    );
    const record = try findRecord(&sink, message);
    try std.testing.expectEqual(code, record.code);
    if (help) |expected_help| {
        try std.testing.expect(record.help != null);
        try std.testing.expect(std.mem.indexOf(u8, record.help.?, expected_help) != null);
    }
}

test "ownership and storage journey uses ownership vocabulary" {
    const source =
        \\struct User { values: [:]i32; }
        \\fn main(): i32 {
        \\    var user = User { values: [:]i32 [1] };
        \\    const alias: &User = &user;
        \\    drop user;
        \\    return alias.values.len();
        \\}
    ;
    try expectInlineFailure(
        "consistency_ownership",
        source,
        .{},
        .ownership_invalidation,
        "while borrow `alias` is live",
        "end the borrow",
    );
}

test "container and view journey names detachable places and repair" {
    const source =
        \\fn main(): i32 {
        \\    var values: [:]i32 = [:]i32 [1];
        \\    var view: []i32 = values[..];
        \\    const value = take view[0];
        \\    return value;
        \\}
    ;
    try expectInlineFailure(
        "consistency_container",
        source,
        .{},
        .container_operation,
        "`take` requires an optional place or sparse-array slot",
        "copy or borrow",
    );
}

test "sum-type journey distinguishes nested empty states" {
    const source =
        \\type MaybeInt = ?i32;
        \\fn main(): i32 {
        \\    const value: ?MaybeInt = none;
        \\    return 0;
        \\}
    ;
    try expectInlineFailure(
        "consistency_sum_type",
        source,
        .{},
        .sum_type_shape,
        "nested optional types are not supported",
        "named union",
    );
}

test "module and visibility journey links a private declaration" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "model.cy", .data = "struct Hidden {}\n" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import .model;
        \\fn use(value: model.Hidden): i32 { return 0; }
        \\fn main(): i32 { return 0; }
        \\
    });

    const root_path = try compat.tmpDirRealpathAlloc(allocator, &tmp, "main.cy");
    defer allocator.free(root_path);
    var loaded = try compiler.loader.loadProgram(allocator, root_path);
    defer loaded.deinit(allocator);
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    try std.testing.expectError(error.SemanticFailed, compiler.sema.buildSirWithOptions(
        allocator,
        root_path,
        loaded.program,
        .{ .diagnostic_context = diagnostics.Context.structured(&sink) },
    ));
    const record = try findRecord(&sink, "not public in imported module");
    try std.testing.expectEqual(diagnostics.DiagnosticCode.visibility_private, record.code);
    try std.testing.expect(record.labels.len != 0);
    try std.testing.expect(std.mem.endsWith(u8, record.labels[0].span.path, "model.cy"));
}

test "ABI and target journeys separate boundary rules from capabilities" {
    const abi_source =
        \\struct Payload { value: i32; }
        \\extern {
        \\    c fn send(payload: Payload): c_int;
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try expectInlineFailure(
        "consistency_abi",
        abi_source,
        .{},
        .abi_boundary,
        "not allowed at a callable C boundary",
        "C-layout ABI type",
    );

    const target_source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        asm {
        \\            "nop";
        \\            clobber x0;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;
    try expectInlineFailure(
        "consistency_target",
        target_source,
        .{ .target = "x86_64-none-elf" },
        .capability,
        "register asm clobbers are unavailable for this target",
        "memory",
    );
}

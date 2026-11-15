const std = @import("std");

const compiler = @import("cyna").compiler;
const compat = @import("cyna").compat;
const diagnostics = compiler.diagnostics;
const lexer = compiler.lexer;
const loader = compiler.loader;
const parser = compiler.parser;
const sema = compiler.sema;
pub const test_exec = @import("support.zig");

pub fn expectNativeSourceExitCode(allocator: std.mem.Allocator, path: []const u8, source: []const u8, expected: i64) !void {
    _ = allocator;
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    try std.testing.expectEqual(expected, try test_exec.runNativeSourceExitCode(scratch.allocator(), path, source));
}

pub fn expectNativeNamedSourceExitCode(
    allocator: std.mem.Allocator,
    _: []const u8,
    native_path: []const u8,
    source: []const u8,
    expected: i64,
) !void {
    try expectNativeSourceExitCode(allocator, native_path, source, expected);
}

pub fn expectNativeFailure(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    _ = allocator;
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const outcome = try test_exec.runNativeSourceOutcome(scratch.allocator(), path, source);
    try std.testing.expect(!outcome.succeeded());
}

pub fn expectNativeFileExitCode(allocator: std.mem.Allocator, path: []const u8, expected: i64) !void {
    _ = allocator;
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    try std.testing.expectEqual(expected, try test_exec.runNativeFileExitCode(scratch.allocator(), path));
}

pub fn expectSemanticFailed(allocator: std.mem.Allocator, name: []const u8, source: []const u8) !void {
    try expectSemanticFailedWithOptions(allocator, name, source, .{});
}

pub fn expectSemanticFailedWithOptions(allocator: std.mem.Allocator, name: []const u8, source: []const u8, options: sema.BuildOptions) !void {
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, name, source, tokens);
    defer program.deinit(allocator);
    try std.testing.expectError(error.SemanticFailed, sema.buildSirWithOptions(allocator, name, program, options));
}

pub fn expectSemanticSuccess(allocator: std.mem.Allocator, name: []const u8, source: []const u8) !void {
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, name, source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, name, program);
    defer module.deinit(allocator);
}

pub fn expectLoadedSemanticSuccess(allocator: std.mem.Allocator, name: []const u8, source: []const u8) !void {
    try expectLoadedSemanticSuccessWithOptions(allocator, name, source, .{});
}

pub fn expectLoadedSemanticSuccessWithOptions(allocator: std.mem.Allocator, name: []const u8, source: []const u8, options: sema.BuildOptions) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const root_path = try compat.tmpDirRealpathAlloc(allocator, &tmp, "main.cy");
    defer allocator.free(root_path);

    var loaded = try loader.loadProgram(allocator, root_path);
    defer loaded.deinit(allocator);
    const module = try sema.buildSirWithOptions(allocator, name, loaded.program, options);
    defer module.deinit(allocator);
}

pub fn expectLoadedSemanticFailed(allocator: std.mem.Allocator, name: []const u8, source: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const root_path = try compat.tmpDirRealpathAlloc(allocator, &tmp, "main.cy");
    defer allocator.free(root_path);

    var loaded = try loader.loadProgram(allocator, root_path);
    defer loaded.deinit(allocator);
    try std.testing.expectError(error.SemanticFailed, sema.buildSirWithOptions(allocator, name, loaded.program, .{}));
}

pub fn expectLoadedSemanticFailedMessage(allocator: std.mem.Allocator, name: []const u8, source: []const u8, expected_substring: []const u8) !void {
    try expectLoadedSemanticFailedMessages(allocator, name, source, &.{expected_substring});
}

pub fn expectDiagnosticContains(sink: *const diagnostics.Sink, expected_substring: []const u8) !void {
    var rendered: std.ArrayListUnmanaged(u8) = .empty;
    defer rendered.deinit(sink.allocator);
    for (sink.records.items) |record| {
        if (std.mem.indexOf(u8, record.message, expected_substring) != null) return;
        rendered.clearRetainingCapacity();
        try diagnostics.renderCompactText(.{
            .allocator = sink.allocator,
            .buffer = &rendered,
        }, record.asSpec());
        if (std.mem.indexOf(u8, rendered.items, expected_substring) != null) return;
    }
    return error.TestExpectedEqual;
}

pub fn expectDiagnosticNotContains(sink: *const diagnostics.Sink, unexpected_substring: []const u8) !void {
    var rendered: std.ArrayListUnmanaged(u8) = .empty;
    defer rendered.deinit(sink.allocator);
    for (sink.records.items) |record| {
        if (std.mem.indexOf(u8, record.message, unexpected_substring) != null) {
            return error.TestUnexpectedResult;
        }
        rendered.clearRetainingCapacity();
        try diagnostics.renderCompactText(.{
            .allocator = sink.allocator,
            .buffer = &rendered,
        }, record.asSpec());
        if (std.mem.indexOf(u8, rendered.items, unexpected_substring) != null) {
            return error.TestUnexpectedResult;
        }
    }
}

pub fn expectLoadedSemanticFailedMessages(allocator: std.mem.Allocator, name: []const u8, source: []const u8, expected_substrings: []const []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const root_path = try compat.tmpDirRealpathAlloc(allocator, &tmp, "main.cy");
    defer allocator.free(root_path);

    var loaded = try loader.loadProgram(allocator, root_path);
    defer loaded.deinit(allocator);

    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    const diagnostic_context = diagnostics.Context.structured(&sink);
    try std.testing.expectError(error.SemanticFailed, sema.buildSirWithOptions(allocator, name, loaded.program, .{
        .diagnostic_context = diagnostic_context,
    }));
    for (expected_substrings) |expected_substring| {
        try expectDiagnosticContains(&sink, expected_substring);
    }
}

pub fn expectSemanticFailedMessage(allocator: std.mem.Allocator, name: []const u8, source: []const u8, expected_substring: []const u8) !void {
    try expectSemanticFailedMessageWithOptions(allocator, name, source, .{}, expected_substring);
}

pub fn expectSemanticFailedCode(
    allocator: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    expected_code: diagnostics.DiagnosticCode,
) !void {
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, name, source, tokens);
    defer program.deinit(allocator);
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    try std.testing.expectError(error.SemanticFailed, sema.buildSirWithOptions(allocator, name, program, .{
        .diagnostic_context = diagnostics.Context.structured(&sink),
    }));
    try sink.normalize(.{});
    for (sink.records.items) |record| {
        if (record.code == expected_code) return;
    }
    return error.ExpectedStructuredDiagnosticCode;
}

pub fn expectSemanticFailedDiagnostic(
    allocator: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    expected_code: diagnostics.DiagnosticCode,
    expected_substring: []const u8,
) !void {
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, name, source, tokens);
    defer program.deinit(allocator);
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    try std.testing.expectError(error.SemanticFailed, sema.buildSirWithOptions(allocator, name, program, .{
        .diagnostic_context = diagnostics.Context.structured(&sink),
    }));
    try sink.normalize(.{});
    for (sink.records.items) |record| {
        if (record.code == expected_code and std.mem.indexOf(u8, record.message, expected_substring) != null) return;
    }
    return error.ExpectedStructuredDiagnostic;
}

pub fn expectSemanticFailedHelp(
    allocator: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    expected_help: []const u8,
) !void {
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, name, source, tokens);
    defer program.deinit(allocator);
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    try std.testing.expectError(error.SemanticFailed, sema.buildSirWithOptions(allocator, name, program, .{
        .diagnostic_context = diagnostics.Context.structured(&sink),
    }));
    for (sink.records.items) |record| {
        const help = record.help orelse continue;
        if (std.mem.indexOf(u8, help, expected_help) != null) return;
    }
    return error.ExpectedStructuredDiagnosticHelp;
}

pub fn expectSemanticFailedMessageWithOptions(
    allocator: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    options: sema.BuildOptions,
    expected_substring: []const u8,
) !void {
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, name, source, tokens);
    defer program.deinit(allocator);

    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    var build_options = options;
    build_options.diagnostic_context = diagnostics.Context.structured(&sink);
    try std.testing.expectError(error.SemanticFailed, sema.buildSirWithOptions(allocator, name, program, build_options));
    try expectDiagnosticContains(&sink, expected_substring);
}

pub fn expectParseFailed(allocator: std.mem.Allocator, name: []const u8, source: []const u8) !void {
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    try std.testing.expectError(error.ParseFailed, parser.parse(allocator, name, source, tokens));
}

pub fn expectParseFailedMessage(allocator: std.mem.Allocator, name: []const u8, source: []const u8, expected_substring: []const u8) !void {
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    var diagnostic_context = diagnostics.Context.structured(&sink);
    try std.testing.expectError(error.ParseFailed, parser.parseWithDiagnostics(allocator, name, source, tokens, &diagnostic_context));
    try expectDiagnosticContains(&sink, expected_substring);
}

pub fn expectModuleParseFailed(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    try std.testing.expectError(error.ParseFailed, loader.loadProgram(scratch.allocator(), path));
}

pub fn expectModuleSemanticFailed(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const scratch_allocator = scratch.allocator();
    var loaded = try loader.loadProgram(scratch_allocator, path);
    defer loaded.deinit(scratch_allocator);
    try std.testing.expectError(error.SemanticFailed, sema.buildSir(scratch_allocator, path, loaded.program));
}

pub fn expectModuleSemanticFailedMessage(allocator: std.mem.Allocator, path: []const u8, expected_substring: []const u8) !void {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const scratch_allocator = scratch.allocator();
    var loaded = try loader.loadProgram(scratch_allocator, path);
    defer loaded.deinit(scratch_allocator);

    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    const diagnostic_context = diagnostics.Context.structured(&sink);
    try std.testing.expectError(error.SemanticFailed, sema.buildSirWithOptions(scratch_allocator, path, loaded.program, .{
        .diagnostic_context = diagnostic_context,
    }));
    try expectDiagnosticContains(&sink, expected_substring);
}

pub fn expectStderrContains(stderr: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, stderr, needle) != null);
}

pub fn expectStderrNotContains(stderr: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, stderr, needle) == null);
}

pub fn expectTestSummary(stderr: []const u8, passed: usize, failed: usize) !void {
    const passed_needle = try std.fmt.allocPrint(std.testing.allocator, "tests passed: {d}", .{passed});
    defer std.testing.allocator.free(passed_needle);
    try expectStderrContains(stderr, passed_needle);

    const failed_needle = try std.fmt.allocPrint(std.testing.allocator, "tests failed: {d}", .{failed});
    defer std.testing.allocator.free(failed_needle);
    try expectStderrContains(stderr, failed_needle);
}

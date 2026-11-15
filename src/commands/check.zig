const std = @import("std");
const build_pkg = @import("../build.zig");
const diagnostic_renderer = @import("../compiler/diagnostic/renderer.zig");
const diagnostic_sources = @import("../compiler/diagnostic/source_registry.zig");
const diagnostics = @import("../compiler/diagnostics.zig");
const loader = @import("../compiler/loader.zig");
const sema = @import("../compiler/sema/sema.zig");

const build_model = build_pkg.model;

pub const CheckOptions = struct {
    build_config: ?[]const u8 = null,
    diagnostic_format: diagnostic_renderer.Mode = .human,
    progress: bool = false,
};

pub const CheckSuccess = struct {
    display_path: []u8,
    function_count: usize,
};

pub const CheckOutcome = union(enum) {
    success: CheckSuccess,
    reported_failure: []u8,

    pub fn deinit(self: *CheckOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => |value| allocator.free(value.display_path),
            .reported_failure => |text| allocator.free(text),
        }
    }
};

pub fn checkCommand(allocator: std.mem.Allocator, input_path: ?[]const u8, options: CheckOptions) !CheckOutcome {
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    var diagnostic_context = diagnostics.Context.structured(&sink);

    var target = build_model.resolveBuildTargetForConfigWithDiagnostics(allocator, input_path, options.build_config, &diagnostic_context) catch |err| switch (err) {
        error.ProjectNotFound,
        error.FileNotFound,
        error.InvalidManifest,
        error.UnsupportedTarget,
        error.PermissionDenied,
        error.AccessDenied,
        => return captureFailure(
            allocator,
            &sink,
            &diagnostic_context,
            input_path orelse ".",
            switch (err) {
                error.PermissionDenied, error.AccessDenied => "access denied while resolving build target",
                else => @errorName(err),
            },
            options.diagnostic_format,
        ),
        else => return err,
    };
    defer target.deinit(allocator);
    if (options.progress) std.debug.print("Checking {s}\n", .{target.display_path});

    var loaded = loader.loadProgramWithOptions(allocator, target.source_path, .{
        .diagnostic_context = diagnostic_context,
    }) catch |err| switch (err) {
        error.ParseFailed => return captureFailure(allocator, &sink, &diagnostic_context, target.source_path, "parse failed", options.diagnostic_format),
        error.PermissionDenied => return captureFailure(allocator, &sink, &diagnostic_context, target.source_path, "access denied while loading source", options.diagnostic_format),
        error.AccessDenied => return captureFailure(allocator, &sink, &diagnostic_context, target.source_path, "access denied while loading source", options.diagnostic_format),
        else => return err,
    };
    defer loaded.deinit(allocator);
    if (options.progress) std.debug.print("Analyzing {d} source module{s}\n", .{ loaded.source_paths.len, if (loaded.source_paths.len == 1) "" else "s" });

    const module = sema.buildSirWithOptions(allocator, target.source_path, loaded.program, .{
        .target = target.target,
        .diagnostic_context = diagnostic_context,
    }) catch |err| switch (err) {
        error.SemanticFailed => return captureFailure(allocator, &sink, &diagnostic_context, target.source_path, "semantic analysis failed", options.diagnostic_format),
        else => return err,
    };
    defer module.deinit(allocator);

    return .{ .success = .{
        .display_path = try allocator.dupe(u8, target.display_path),
        .function_count = module.functions.len,
    } };
}

fn captureFailure(
    allocator: std.mem.Allocator,
    sink: *diagnostics.Sink,
    diagnostic_context: *diagnostics.Context,
    path: []const u8,
    fallback_message: []const u8,
    mode: diagnostic_renderer.Mode,
) !CheckOutcome {
    if (sink.records.items.len == 0) {
        try diagnostic_context.emitPath(path, fallback_message);
    }
    try sink.normalize(.{});
    var registry = diagnostic_sources.Registry.init(allocator);
    defer registry.deinit();
    diagnostic_renderer.hydrateFromDisk(&registry, sink.records.items);
    return .{ .reported_failure = try diagnostic_renderer.renderAlloc(
        allocator,
        &registry,
        sink.records.items,
        .{ .mode = mode },
    ) };
}

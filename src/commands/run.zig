const std = @import("std");
const build_pkg = @import("../build.zig");
const install = @import("install.zig");
const llvm_backend = @import("../compiler/backend/llvm.zig");
const internal_error = @import("../compiler/internal_error.zig");
const diagnostics = @import("../compiler/diagnostics.zig");
const loader = @import("../compiler/loader.zig");
const lower = @import("../compiler/lower/lower.zig");
const sema = @import("../compiler/sema/sema.zig");
const build_model = build_pkg.model;

const ArtifactDeps = llvm_backend.ArtifactDeps;

pub const RunOptions = struct {
    argv: []const []const u8 = &.{},
    diagnostic_context: diagnostics.Context = .{ .destination = .discard },
};

pub const Callbacks = struct {
    compileAndRunNativeExecutable: *const fn (
        allocator: std.mem.Allocator,
        llvm_ir: []const u8,
        artifact_deps: ArtifactDeps,
        target: build_model.BuildTarget,
        argv: []const []const u8,
        diagnostic_context: diagnostics.Context,
    ) anyerror!i64,
};

pub fn runCommand(allocator: std.mem.Allocator, input_path: ?[]const u8, options: RunOptions, callbacks: Callbacks) !u8 {
    var diagnostic_context = options.diagnostic_context;
    try install.ensureInstalledWithDiagnostics(allocator, input_path, diagnostic_context);

    var target = try build_model.resolveBuildTargetForConfigWithDiagnostics(allocator, input_path, null, &diagnostic_context);
    defer target.deinit(allocator);

    var loaded = try loader.loadProgramWithOptions(allocator, target.source_path, .{
        .diagnostic_context = diagnostic_context,
    });
    defer loaded.deinit(allocator);

    const module = try sema.buildSirWithOptions(allocator, target.source_path, loaded.program, .{
        .target = target.target,
        .diagnostic_context = diagnostic_context,
    });
    defer module.deinit(allocator);

    if (target.output_kind != .exe) {
        try diagnostic_context.emitPath(target.display_path, "cyna run only supports executable targets");
        return error.UnsupportedRunTarget;
    }
    if (target.target) |build_target| {
        if (!std.mem.eql(u8, build_target, "native")) {
            try diagnostic_context.emitPath(target.display_path, "cyna run only supports native executable targets");
            return error.UnsupportedRunTarget;
        }
    }

    const debug_source_map = try buildDebugSourceMap(allocator, loaded.module_names, loaded.source_paths);
    defer allocator.free(debug_source_map);

    const lir_module = lower.lowerModuleWithOptions(allocator, module, .{
        .debug_source_map = debug_source_map,
        .fallback_source_path = target.source_path,
        .target = target.target,
    }) catch |err| {
        if (!try internal_error.emitSirIdentityFailure(diagnostic_context, module, debug_source_map, target.source_path, err))
            try internal_error.emitFailure(diagnostic_context, target.source_path, .sir_to_lir, err);
        return err;
    };
    defer lir_module.deinit(allocator);

    const artifact_deps = llvm_backend.moduleArtifactDeps(allocator, lir_module);
    const llvm_ir = llvm_backend.emitModule(allocator, lir_module) catch |err| {
        try internal_error.emitFailure(diagnostic_context, target.source_path, .lir_to_llvm, err);
        return err;
    };
    defer allocator.free(llvm_ir);

    const code = try callbacks.compileAndRunNativeExecutable(
        allocator,
        llvm_ir,
        artifact_deps,
        target,
        options.argv,
        diagnostic_context,
    );
    std.debug.print("program exited with {d}\n", .{code});
    if (code < 0 or code > std.math.maxInt(u8)) {
        try diagnostic_context.emitPath(target.source_path, "program exit code must be between 0 and 255");
        return error.InvalidExitCode;
    }
    return @intCast(code);
}

fn buildDebugSourceMap(
    allocator: std.mem.Allocator,
    module_names: [][]const u8,
    source_paths: [][]const u8,
) ![]lower.DebugSourceMapEntry {
    const map = try allocator.alloc(lower.DebugSourceMapEntry, module_names.len);
    for (module_names, source_paths, 0..) |module_name, source_path, i| {
        map[i] = .{
            .module_name = module_name,
            .source_path = source_path,
        };
    }
    return map;
}

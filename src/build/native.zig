const std = @import("std");
const build_options = @import("build_options");
const compat = @import("../compat.zig");
const llvm_backend = @import("../compiler/backend/llvm.zig");
const diagnostics = @import("../compiler/diagnostics.zig");
const compilation = @import("../compiler/session.zig");
const lir = @import("../compiler/lower/lir.zig");
const build_model = @import("model.zig");
const toolchain = @import("toolchain.zig");
const cache_bundle = @import("cache_bundle.zig");

const ArtifactDeps = llvm_backend.ArtifactDeps;
const StaticLibraryDependency = toolchain.StaticLibraryDependency;
const ResolvedDistributionTools = toolchain.ResolvedDistributionTools;
const staticlib_link_metadata_suffix = ".cyna-link.toml";
const inline_test_object_cache_dir = ".zig-cache/cyna-inline-test-objects";
var inline_test_object_cache_mutexes: [16]std.Io.Mutex = @splat(.init);
var native_object_cache_mutex: std.Io.Mutex = .init;

pub const CompileNativeOptions = struct {
    verbose: bool = false,
    progress: bool = false,
    jobs: usize = 0,
    diagnostic_context: diagnostics.Context = .{ .destination = .discard },
    session: ?*compilation.CompilationSession = null,
    /// Optional module labels matching `llvm_modules` by index. Source module
    /// names make object progress lines identify what is being compiled.
    llvm_module_names: []const []const u8 = &.{},
};

fn startTiming(options: CompileNativeOptions, name: []const u8) compilation.Scope {
    const session = options.session orelse return .{};
    return session.start(name, &.{});
}

fn reportProgress(verbose: bool, comptime format: []const u8, args: anytype) void {
    if (verbose) std.debug.print(format, args);
}

const heartbeat_interval_ms: i64 = 10_000;
/// Modules above this size make clang's optimizer run for minutes on a single
/// translation unit. The progress line already names the module; this warning
/// makes the expected delay explicit.
const large_module_ir_warning_bytes: usize = 8 * 1024 * 1024;

fn reportsActivity(verbose: bool, progress: bool) bool {
    return verbose or progress;
}

fn monotonicNowNs() i128 {
    return std.Io.Clock.Timestamp.now(compat.io(), .awake).raw.nanoseconds;
}

fn elapsedSeconds(started_ns: i128) f64 {
    return @as(f64, @floatFromInt(monotonicNowNs() - started_ns)) / @as(f64, std.time.ns_per_s);
}

/// Prints periodic progress for an external tool that can run for minutes
/// (clang on LLVM IR, linking, archiving). Without this a long tool run is
/// indistinguishable from a hang.
const ToolHeartbeat = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    done: bool = false,
    label: []const u8,
    started_ns: i128,

    fn run(self: *ToolHeartbeat) void {
        const io = compat.io();
        const interval = std.Io.Clock.Duration{
            .raw = std.Io.Duration.fromMilliseconds(heartbeat_interval_ms),
            .clock = .awake,
        };
        self.mutex.lockUncancelable(io);
        while (!self.done) {
            self.cond.waitTimeout(io, &self.mutex, .{ .duration = interval }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => break,
            };
            if (self.done) break;
            std.debug.print("  ... still running: {s} ({d:.1}s elapsed)\n", .{ self.label, elapsedSeconds(self.started_ns) });
        }
        self.mutex.unlock(io);
    }

    fn finish(self: *ToolHeartbeat) void {
        const io = compat.io();
        self.mutex.lockUncancelable(io);
        self.done = true;
        self.mutex.unlock(io);
        self.cond.signal(io);
    }
};

fn printToolCommand(argv: []const []const u8) void {
    std.debug.print("running:", .{});
    for (argv) |arg| std.debug.print(" {s}", .{arg});
    std.debug.print("\n", .{});
}

/// Describes progress for one object/source compile.
const ToolActivity = struct {
    label: ?[]const u8 = null,
    verbose: bool = false,
};

const runtime_leak_check_source =
    \\#include <stdlib.h>
    \\
    \\extern void cyna_runtime_assert_no_leaks(void);
    \\
    \\static void cyna_runtime_check_at_exit(void) {
    \\    cyna_runtime_assert_no_leaks();
    \\}
    \\
    \\__attribute__((constructor))
    \\static void cyna_runtime_register_leak_check(void) {
    \\    atexit(cyna_runtime_check_at_exit);
    \\}
;

const CompileObjectJob = struct {
    ir_path: []u8,
    object_path: []u8,
    label: []const u8 = "",
    ir_bytes: usize = 0,
    reused: bool = false,
    failure: ?anyerror = null,
};

const CompileObjectWorkerContext = struct {
    allocator: std.mem.Allocator,
    tools: ResolvedDistributionTools,
    target: build_model.BuildTarget,
    activity: bool,
    verbose: bool,
    jobs: []CompileObjectJob,
    next_index: std.atomic.Value(usize),
};

pub fn compileNativeArtifact(
    allocator: std.mem.Allocator,
    llvm_ir: []const u8,
    artifact_deps: ArtifactDeps,
    target: build_model.BuildTarget,
    emit_obj: bool,
    link_native_artifact: bool,
    artifact_base_path: []const u8,
    output_path: []const u8,
    options: CompileNativeOptions,
) !bool {
    return compileNativeArtifacts(
        allocator,
        &.{llvm_ir},
        artifact_deps,
        target,
        emit_obj,
        link_native_artifact,
        artifact_base_path,
        output_path,
        options,
    );
}

/// Compile several independently emitted LLVM modules and link their objects
/// into one native artifact. The single-module API above remains the default
/// compatibility path for commands and callers that do not partition builds.
pub fn compileNativeArtifacts(
    allocator: std.mem.Allocator,
    llvm_modules: []const []const u8,
    artifact_deps: ArtifactDeps,
    target: build_model.BuildTarget,
    emit_obj: bool,
    link_native_artifact: bool,
    artifact_base_path: []const u8,
    output_path: []const u8,
    options: CompileNativeOptions,
) !bool {
    if (llvm_modules.len == 0) return error.InvalidNativeModuleSet;
    if (emit_obj and llvm_modules.len != 1) return error.InvalidNativeModuleSet;
    try ensureParentDir(output_path);
    reportProgress(options.verbose, "resolving native toolchain...\n", .{});
    var distribution_tools = try toolchain.resolveDistributionToolsWithDiagnostics(allocator, target, options.diagnostic_context);
    defer distribution_tools.deinit(allocator);

    const tmp = try compat.makeTempWorkspace(allocator, "cyna-native");
    defer tmp.cleanup(allocator);
    const tmp_root = tmp.path;
    var object_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (object_paths.items) |path| allocator.free(path);
        object_paths.deinit(allocator);
    }

    var compile_jobs: std.ArrayListUnmanaged(CompileObjectJob) = .empty;
    defer {
        for (compile_jobs.items) |job| {
            allocator.free(job.ir_path);
            allocator.free(job.object_path);
        }
        compile_jobs.deinit(allocator);
    }

    for (llvm_modules, 0..) |llvm_ir, index| {
        const ir_name = try std.fmt.allocPrint(allocator, "module-{d}.ll", .{index});
        defer allocator.free(ir_name);
        const ir_path = try std.fs.path.join(allocator, &.{ tmp_root, ir_name });
        try compat.writeTextFile(ir_path, llvm_ir);

        const object_name = try std.fmt.allocPrint(allocator, "module-{d}.o", .{index});
        defer allocator.free(object_name);
        const ir_object_path = try std.fs.path.join(allocator, &.{ tmp_root, object_name });
        const label = if (index < options.llvm_module_names.len) options.llvm_module_names[index] else "";
        compile_jobs.append(allocator, .{
            .ir_path = ir_path,
            .object_path = ir_object_path,
            .label = label,
            .ir_bytes = llvm_ir.len,
        }) catch |err| {
            allocator.free(ir_path);
            allocator.free(ir_object_path);
            return err;
        };
    }

    {
        var span = startTiming(options, "native.object_jobs");
        defer span.end();
        try compileObjectJobs(
            allocator,
            distribution_tools,
            target,
            target.opt,
            compile_jobs.items,
            options.jobs,
            reportsActivity(options.verbose, options.progress),
            options.verbose,
        );
    }
    var reused_objects: usize = 0;
    for (compile_jobs.items) |*job| {
        if (job.failure) |err| return err;
        if (job.reused) {
            reused_objects += 1;
        }
        try object_paths.append(allocator, job.object_path);
        job.object_path = &.{};
    }
    if (options.verbose) {
        std.debug.print("native objects ready ({d} compiled, {d} reused)\n", .{
            compile_jobs.items.len - reused_objects,
            reused_objects,
        });
    }
    if (options.session) |session| session.setNativeObjects(reused_objects, compile_jobs.items.len - reused_objects);

    var effective_artifact_deps = artifact_deps;
    if (target.output_kind == .exe and target.leak_check) {
        effective_artifact_deps.runtime = true;
    }

    if (emit_obj) {
        const obj_path = try emittedArtifactPath(allocator, artifact_base_path, ".o");
        defer allocator.free(obj_path);
        try copyFile(object_paths.items[0], obj_path);
        std.debug.print("wrote object file to {s}\n", .{obj_path});
    }

    if (!link_native_artifact) return false;

    if (effective_artifact_deps.any() and target.output_kind == .exe and build_model.isFreestandingTarget(target.target)) {
        // Installed checkout archives are built for the host. Compile the
        // bundled sources for the requested freestanding target instead.
        try appendBundledObjectsFromSource(allocator, distribution_tools, tmp_root, &object_paths, target, effective_artifact_deps);
        effective_artifact_deps = .{};
    }

    if (effective_artifact_deps.any() and target.output_kind == .staticlib) {
        reportProgress(options.verbose, "building bundled dependency objects...\n", .{});
        try appendBundledObjectsFromSource(allocator, distribution_tools, tmp_root, &object_paths, target, effective_artifact_deps);
    }

    if (target.output_kind == .exe and target.leak_check) {
        reportProgress(options.verbose, "building runtime leak-check object...\n", .{});
        try appendRuntimeLeakCheckObject(allocator, distribution_tools, tmp_root, &object_paths, target);
    }

    try appendNativeObjects(
        allocator,
        distribution_tools,
        tmp_root,
        &object_paths,
        target,
        target.c_sources,
        "c",
        target.opt,
        reportsActivity(options.verbose, options.progress),
        options.verbose,
    );
    try appendNativeObjects(
        allocator,
        distribution_tools,
        tmp_root,
        &object_paths,
        target,
        target.asm_sources,
        "asm",
        target.opt,
        reportsActivity(options.verbose, options.progress),
        options.verbose,
    );
    if (target.output_kind == .exe and build_model.isFreestandingTarget(target.target)) {
        reportProgress(options.verbose, "building freestanding memory support object...\n", .{});
        try appendFreestandingMemorySupportObject(allocator, distribution_tools, tmp_root, &object_paths, target);
    }

    var link_span = startTiming(options, "native.link");
    defer link_span.end();
    switch (target.output_kind) {
        .exe => {
            try linkNativeArtifact(options.diagnostic_context, allocator, distribution_tools, output_path, object_paths.items, target, false, effective_artifact_deps, options.verbose, options.progress);
        },
        .sharedlib => {
            try linkNativeArtifact(options.diagnostic_context, allocator, distribution_tools, output_path, object_paths.items, target, true, effective_artifact_deps, options.verbose, options.progress);
        },
        .staticlib => {
            try archiveStaticLibrary(allocator, distribution_tools, output_path, object_paths.items, options.verbose or options.progress);
            try emitStaticLibraryLinkMetadata(allocator, output_path, effective_artifact_deps);
        },
    }
    return true;
}

pub fn compileNativeSourcesToStaticLibrary(
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    output_path: []const u8,
) !void {
    return compileNativeSourcesToStaticLibraryWithDiagnostics(allocator, target, output_path, diagnostics.Context.discarded());
}

pub fn compileNativeSourcesToStaticLibraryWithDiagnostics(
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    output_path: []const u8,
    diagnostic_context: diagnostics.Context,
) !void {
    try ensureParentDir(output_path);
    var distribution_tools = try toolchain.resolveDistributionToolsWithDiagnostics(allocator, target, diagnostic_context);
    defer distribution_tools.deinit(allocator);

    const tmp = try compat.makeTempWorkspace(allocator, "cyna-native");
    defer tmp.cleanup(allocator);
    const tmp_root = tmp.path;

    var object_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (object_paths.items) |path| allocator.free(path);
        object_paths.deinit(allocator);
    }

    try appendNativeObjects(allocator, distribution_tools, tmp_root, &object_paths, target, target.c_sources, "c", target.opt, false, false);
    try appendNativeObjects(allocator, distribution_tools, tmp_root, &object_paths, target, target.asm_sources, "asm", target.opt, false, false);
    if (object_paths.items.len == 0) return;

    try archiveStaticLibrary(allocator, distribution_tools, output_path, object_paths.items, false);
}

pub fn compileAndRunNativeExecutable(
    allocator: std.mem.Allocator,
    llvm_ir: []const u8,
    artifact_deps: ArtifactDeps,
    target: build_model.BuildTarget,
    argv: []const []const u8,
) !i64 {
    return compileAndRunNativeExecutableWithDiagnostics(
        allocator,
        llvm_ir,
        artifact_deps,
        target,
        argv,
        diagnostics.Context.discarded(),
    );
}

pub fn compileAndRunNativeExecutableWithDiagnostics(
    allocator: std.mem.Allocator,
    llvm_ir: []const u8,
    artifact_deps: ArtifactDeps,
    target: build_model.BuildTarget,
    argv: []const []const u8,
    diagnostic_context: diagnostics.Context,
) !i64 {
    return compileAndRunNativeExecutableWithExtraCSources(
        allocator,
        llvm_ir,
        artifact_deps,
        target,
        argv,
        &.{},
        diagnostic_context,
    );
}

pub fn compileAndRunInlineTest(
    allocator: std.mem.Allocator,
    llvm_ir: []const u8,
    artifact_deps: ArtifactDeps,
    target: build_model.BuildTarget,
    function_name: []const u8,
) !void {
    const runner_source = try std.fmt.allocPrint(allocator,
        \\#include <stdint.h>
        \\
        \\typedef struct {{
        \\    uint8_t tag;
        \\    uint8_t ok;
        \\    int64_t err;
        \\    struct {{
        \\        const void *owner;
        \\        uint32_t slot_plus_one;
        \\        uint32_t generation;
        \\    }} trace;
        \\}} CynaInlineTestResult;
        \\
        \\extern CynaInlineTestResult {s}(void);
        \\
        \\int main(void) {{
        \\    CynaInlineTestResult result = {s}();
        \\    if (result.tag != 0) return 1;
        \\    return 0;
        \\}}
        \\
    , .{ function_name, function_name });
    defer allocator.free(runner_source);

    const diagnostic_context = diagnostics.Context.discarded();
    const root_object_path = try cachedInlineTestRootObject(allocator, llvm_ir, target, diagnostic_context);
    defer allocator.free(root_object_path);
    const exit_code = try compileAndRunNativeExecutableWithRootObject(
        allocator,
        root_object_path,
        artifact_deps,
        target,
        &.{},
        &.{
            .{
                .name = "cyna_inline_test_runner.c",
                .source = runner_source,
            },
        },
        diagnostic_context,
    );
    if (exit_code == 101) return error.AssertFailed;
    if (exit_code == 1) return error.TestFailed;
    if (exit_code != 0) return error.NativeRunFailed;
}

pub fn compileAndRunInlineTests(
    allocator: std.mem.Allocator,
    llvm_ir: []const u8,
    artifact_deps: ArtifactDeps,
    target: build_model.BuildTarget,
    function_names: []const []const u8,
    results: []?anyerror,
    durations_ns: []u64,
) !void {
    return compileAndRunInlineTestsWithDiagnostics(
        allocator,
        llvm_ir,
        artifact_deps,
        target,
        function_names,
        results,
        durations_ns,
        diagnostics.Context.discarded(),
    );
}

pub fn compileAndRunInlineTestsWithDiagnostics(
    allocator: std.mem.Allocator,
    llvm_ir: []const u8,
    artifact_deps: ArtifactDeps,
    target: build_model.BuildTarget,
    function_names: []const []const u8,
    results: []?anyerror,
    durations_ns: []u64,
    diagnostic_context: diagnostics.Context,
) !void {
    if (results.len != function_names.len or durations_ns.len != function_names.len) return error.InvalidTestResultBuffer;
    if (function_names.len == 0) return;

    var runner_source: std.ArrayListUnmanaged(u8) = .empty;
    defer runner_source.deinit(allocator);
    var runner_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &runner_source);
    try runner_writer.writer.writeAll(
        \\#include <stdint.h>
        \\#include <stdlib.h>
        \\
        \\typedef struct {
        \\    uint8_t tag;
        \\    uint8_t ok;
        \\    int64_t err;
        \\    struct {
        \\        const void *owner;
        \\        uint32_t slot_plus_one;
        \\        uint32_t generation;
        \\    } trace;
        \\} CynaInlineTestResult;
        \\
        \\typedef CynaInlineTestResult (*CynaInlineTestFn)(void);
        \\
    );
    for (function_names) |function_name| {
        try runner_writer.writer.print("extern CynaInlineTestResult {s}(void);\n", .{function_name});
    }
    try runner_writer.writer.writeAll("\nstatic CynaInlineTestFn cyna_tests[] = {\n");
    for (function_names) |function_name| {
        try runner_writer.writer.print("    {s},\n", .{function_name});
    }
    try runner_writer.writer.print(
        \\}};
        \\
        \\int main(int argc, char **argv) {{
        \\    if (argc != 2) return 2;
        \\    char *end = 0;
        \\    unsigned long index = strtoul(argv[1], &end, 10);
        \\    if (!end || *end != '\0' || index >= {d}) return 2;
        \\    CynaInlineTestResult result = cyna_tests[index]();
        \\    if (result.tag != 0) return 1;
        \\    return 0;
        \\}}
        \\
    , .{function_names.len});
    runner_source = runner_writer.toArrayList();

    const root_object_path = try cachedInlineTestRootObject(allocator, llvm_ir, target, diagnostic_context);
    defer allocator.free(root_object_path);
    const tmp = try compat.makeTempWorkspace(allocator, "cyna-inline-tests");
    defer tmp.cleanup(allocator);
    const exe_path = try std.fs.path.join(allocator, &.{ tmp.path, "tests.native" });
    defer allocator.free(exe_path);
    try buildNativeExecutableWithRootObject(
        allocator,
        root_object_path,
        artifact_deps,
        target,
        tmp.path,
        exe_path,
        &.{.{ .name = "cyna_inline_test_runner.c", .source = runner_source.items }},
        diagnostic_context,
    );

    for (function_names, 0..) |_, index| {
        const index_arg = try std.fmt.allocPrint(allocator, "{d}", .{index});
        defer allocator.free(index_arg);
        const started_ns = monotonicNanoTimestamp();
        const exit_code = runNativeExecutable(allocator, exe_path, &.{index_arg}) catch |err| {
            durations_ns[index] = monotonicNanoTimestamp() -| started_ns;
            results[index] = err;
            continue;
        };
        durations_ns[index] = monotonicNanoTimestamp() -| started_ns;
        results[index] = switch (exit_code) {
            0 => null,
            101 => error.AssertFailed,
            1 => error.TestFailed,
            else => error.NativeRunFailed,
        };
    }
}

fn cachedInlineTestRootObject(
    allocator: std.mem.Allocator,
    llvm_ir: []const u8,
    target: build_model.BuildTarget,
    diagnostic_context: diagnostics.Context,
) ![]u8 {
    var distribution_tools = try toolchain.resolveDistributionToolsWithDiagnostics(allocator, target, diagnostic_context);
    defer distribution_tools.deinit(allocator);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(llvm_ir);
    hasher.update(target.target orelse "native");
    hasher.update(target.cpu orelse "");
    hasher.update(@tagName(target.opt));
    hasher.update(build_options.cyna_version);
    hasher.update(target.compiler_identity);
    hasher.update(&distribution_tools.cache_identity);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    const object_name = try std.fmt.allocPrint(allocator, "{s}.o", .{encoded});
    defer allocator.free(object_name);
    const object_path = try std.fs.path.join(allocator, &.{ inline_test_object_cache_dir, object_name });
    errdefer allocator.free(object_path);

    const cache_mutex = &inline_test_object_cache_mutexes[digest[0] % inline_test_object_cache_mutexes.len];
    cache_mutex.lockUncancelable(compat.io());
    defer cache_mutex.unlock(compat.io());
    if (compat.access(object_path, .{})) |_| return object_path else |_| {}

    try compat.makePath(inline_test_object_cache_dir);
    const tmp = try compat.makeTempWorkspace(allocator, "cyna-inline-object");
    defer tmp.cleanup(allocator);
    const ir_path = try std.fs.path.join(allocator, &.{ tmp.path, "module.ll" });
    defer allocator.free(ir_path);
    const pending_object_path = try std.fs.path.join(allocator, &.{ tmp.path, "module.o" });
    defer allocator.free(pending_object_path);
    try compat.writeTextFile(ir_path, llvm_ir);
    _ = try compileIrObject(allocator, distribution_tools, ir_path, pending_object_path, target, target.opt, .{});
    try compat.renamePath(pending_object_path, object_path);
    return object_path;
}

pub fn stripRootMainFunction(
    allocator: std.mem.Allocator,
    module: *lir.Module,
    root_module_name: []const u8,
) !void {
    var removed_index: ?usize = null;
    for (module.functions, 0..) |function, index| {
        if (std.mem.eql(u8, function.module_name, root_module_name) and
            std.mem.eql(u8, function.name, "main"))
        {
            removed_index = index;
            break;
        }
    }
    const index = removed_index orelse return;

    module.functions[index].deinit(allocator);
    const trimmed = try allocator.alloc(lir.Function, module.functions.len - 1);
    var out_index: usize = 0;
    for (module.functions, 0..) |function, function_index| {
        if (function_index == index) continue;
        trimmed[out_index] = function;
        out_index += 1;
    }
    allocator.free(module.functions);
    module.functions = trimmed;
}

pub fn emitPostLinkArtifacts(
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    emit: build_model.EmitOptions,
    artifact_base_path: []const u8,
    native_output_path: []const u8,
) !void {
    var diagnostic_context = diagnostics.Context.discarded();
    return emitPostLinkArtifactsWithDiagnostics(allocator, target, emit, artifact_base_path, native_output_path, &diagnostic_context);
}

pub fn emitPostLinkArtifactsWithDiagnostics(
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    emit: build_model.EmitOptions,
    artifact_base_path: []const u8,
    native_output_path: []const u8,
    diagnostic_context: *diagnostics.Context,
) !void {
    if (!emit.elf and !emit.bin and !emit.hex) return;
    if (target.output_kind != .exe) {
        try diagnostic_context.emitPath(target.display_path, "post-link elf/bin emission requires an executable target");
        return error.UnsupportedTarget;
    }

    var distribution_tools = try toolchain.resolveDistributionToolsWithDiagnostics(allocator, target, diagnostic_context.*);
    defer distribution_tools.deinit(allocator);

    if (emit.elf) {
        const elf_path = try emittedArtifactPath(allocator, artifact_base_path, ".elf");
        defer allocator.free(elf_path);
        try copyFile(native_output_path, elf_path);
        std.debug.print("wrote ELF artifact to {s}\n", .{elf_path});
    }

    if (emit.bin) {
        const bin_path = try emittedArtifactPath(allocator, artifact_base_path, ".bin");
        defer allocator.free(bin_path);
        try emitObjcopyArtifact(diagnostic_context.*, allocator, distribution_tools, target, native_output_path, bin_path, "binary", "--emit-bin");
        std.debug.print("wrote binary image to {s}\n", .{bin_path});
    }

    if (emit.hex) {
        const hex_path = try emittedArtifactPath(allocator, artifact_base_path, ".hex");
        defer allocator.free(hex_path);
        try emitObjcopyArtifact(diagnostic_context.*, allocator, distribution_tools, target, native_output_path, hex_path, "ihex", "--emit-hex");
        std.debug.print("wrote Intel HEX image to {s}\n", .{hex_path});
    }
}

fn appendBundledObjectsFromSource(
    allocator: std.mem.Allocator,
    resolved_tools: ResolvedDistributionTools,
    tmp_root: []const u8,
    object_paths: *std.ArrayListUnmanaged([]const u8),
    target: build_model.BuildTarget,
    artifact_deps: ArtifactDeps,
) !void {
    const inventory = @import("../runtime/inventory.zig");
    const freestanding = build_model.isFreestandingTarget(target.target);
    const groups = [_][]const []const u8{
        if (artifact_deps.runtime) inventory.runtime else &.{},
        if (artifact_deps.std) inventory.std_base else &.{},
        if (artifact_deps.std and !freestanding) inventory.hosted else &.{},
    };
    for (groups) |sources| {
        for (sources) |source| {
            const source_path = try compilerRepoRelativePath(allocator, source);
            defer allocator.free(source_path);
            const object_name = try std.fmt.allocPrint(allocator, "{s}.o", .{std.fs.path.stem(source)});
            defer allocator.free(object_name);
            const object_path = try std.fs.path.join(allocator, &.{ tmp_root, object_name });
            errdefer allocator.free(object_path);
            try compileCSource(allocator, resolved_tools, source_path, object_path, target, &.{}, bundledRuntimeCompileFlags(target), target.opt, .{});
            try object_paths.append(allocator, object_path);
        }
    }
}

fn appendRuntimeLeakCheckObject(
    allocator: std.mem.Allocator,
    resolved_tools: ResolvedDistributionTools,
    tmp_root: []const u8,
    object_paths: *std.ArrayListUnmanaged([]const u8),
    target: build_model.BuildTarget,
) !void {
    const source_path = try std.fs.path.join(allocator, &.{ tmp_root, "cyna_runtime_leak_check.c" });
    defer allocator.free(source_path);
    try compat.writeTextFile(source_path, runtime_leak_check_source);

    const object_path = try std.fs.path.join(allocator, &.{ tmp_root, "cyna_runtime_leak_check.o" });
    errdefer allocator.free(object_path);
    try compileCSource(allocator, resolved_tools, source_path, object_path, target, &.{}, &.{}, target.opt, .{});
    try object_paths.append(allocator, object_path);
}

fn appendFreestandingMemorySupportObject(
    allocator: std.mem.Allocator,
    resolved_tools: ResolvedDistributionTools,
    tmp_root: []const u8,
    object_paths: *std.ArrayListUnmanaged([]const u8),
    target: build_model.BuildTarget,
) !void {
    const source_path = try compilerRepoRelativePath(allocator, "src/runtime/freestanding_mem.c");
    defer allocator.free(source_path);

    const object_path = try std.fs.path.join(allocator, &.{ tmp_root, "freestanding_mem.o" });
    errdefer allocator.free(object_path);
    try compileCSource(allocator, resolved_tools, source_path, object_path, target, &.{}, bundledRuntimeCompileFlags(target), target.opt, .{});
    try object_paths.append(allocator, object_path);
}

const bundled_runtime_freestanding_flags = [_][]const u8{
    "-DCYNA_FREESTANDING=1",
};

fn bundledRuntimeCompileFlags(target: build_model.BuildTarget) []const []const u8 {
    if (build_model.isFreestandingTarget(target.target)) return &bundled_runtime_freestanding_flags;
    return &.{};
}

fn linkNativeArtifact(
    diagnostic_context: diagnostics.Context,
    allocator: std.mem.Allocator,
    resolved_tools: ResolvedDistributionTools,
    output_path: []const u8,
    object_paths: []const []const u8,
    target: build_model.BuildTarget,
    shared: bool,
    artifact_deps: ArtifactDeps,
    verbose: bool,
    progress: bool,
) !void {
    var archive_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (archive_paths.items) |path| allocator.free(path);
        archive_paths.deinit(allocator);
    }

    appendBundledDependencyArchives(diagnostic_context, allocator, &archive_paths, target, artifact_deps) catch |err| {
        std.debug.print("bundled archive resolution failed for {s}: {s}\n", .{ target.display_path, @errorName(err) });
        return err;
    };

    _ = try appendStaticLibraryDependencyArchives(diagnostic_context, allocator, &archive_paths, target);
    linkExecutableLike(diagnostic_context, allocator, resolved_tools, output_path, object_paths, archive_paths.items, target, shared, verbose, progress) catch |err| {
        std.debug.print("native linker failed for {s}: {s}\n", .{ target.display_path, @errorName(err) });
        return err;
    };
}

fn appendBundledDependencyArchives(
    diagnostic_context: diagnostics.Context,
    allocator: std.mem.Allocator,
    paths: *std.ArrayListUnmanaged([]const u8),
    target: build_model.BuildTarget,
    deps: ArtifactDeps,
) !void {
    if (deps.runtime) try appendBundledArchiveDependency(diagnostic_context, allocator, paths, target, .runtime);
    if (deps.std) try appendBundledArchiveDependency(diagnostic_context, allocator, paths, target, .std);
}

const StaticLibraryLinkMetadata = struct {
    version: u32 = 2,
    dependencies: []const StaticLibraryDependency = &.{},
};

fn emitStaticLibraryLinkMetadata(allocator: std.mem.Allocator, output_path: []const u8, deps: ArtifactDeps) !void {
    const metadata_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ output_path, staticlib_link_metadata_suffix });
    defer allocator.free(metadata_path);
    var dep_buf: [2]StaticLibraryDependency = undefined;
    const dependencies = artifactDependencySlice(&dep_buf, deps);
    const text = try renderStaticLibraryLinkMetadata(allocator, .{
        .dependencies = dependencies,
    });
    defer allocator.free(text);
    try compat.writeTextFile(metadata_path, text);
    std.debug.print("wrote staticlib link metadata to {s}\n", .{metadata_path});
}

fn appendStaticLibraryDependencyArchives(
    diagnostic_context: diagnostics.Context,
    allocator: std.mem.Allocator,
    archive_paths: *std.ArrayListUnmanaged([]const u8),
    target: build_model.BuildTarget,
) !ArtifactDeps {
    var deps: ArtifactDeps = .{};
    for (target.link.libs) |lib_name| {
        const metadata = try resolveStaticLibraryMetadataForLib(allocator, target.link.search_paths, lib_name) orelse continue;
        for (metadata.dependencies) |dependency| {
            switch (dependency) {
                .runtime => deps.runtime = true,
                .std => deps.std = true,
            }
            try appendBundledArchiveDependency(diagnostic_context, allocator, archive_paths, target, dependency);
        }
        allocator.free(metadata.dependencies);
    }
    return deps;
}

fn resolveStaticLibraryMetadataForLib(
    allocator: std.mem.Allocator,
    search_paths: []const []const u8,
    lib_name: []const u8,
) !?StaticLibraryLinkMetadata {
    for (search_paths) |search_path| {
        const file_name = try std.fmt.allocPrint(allocator, "lib{s}.a{s}", .{ lib_name, staticlib_link_metadata_suffix });
        defer allocator.free(file_name);
        const metadata_path = try std.fs.path.join(allocator, &.{ search_path, file_name });
        defer allocator.free(metadata_path);
        const source = compat.readFileAlloc(allocator, metadata_path, 4096) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(source);
        return try parseStaticLibraryLinkMetadata(allocator, source);
    }
    return null;
}

fn parseStaticLibraryLinkMetadata(allocator: std.mem.Allocator, source: []const u8) !StaticLibraryLinkMetadata {
    var metadata: StaticLibraryLinkMetadata = .{};
    var dependencies: std.ArrayListUnmanaged(StaticLibraryDependency) = .empty;
    errdefer dependencies.deinit(allocator);
    var line_it = std.mem.tokenizeScalar(u8, source, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidManifest;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
        if (std.mem.eql(u8, key, "version")) {
            metadata.version = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "dependencies")) {
            try parseStaticLibraryDependencies(allocator, &dependencies, value);
        }
    }
    if (metadata.version != 2) return error.UnsupportedTarget;
    metadata.dependencies = try dependencies.toOwnedSlice(allocator);
    return metadata;
}

fn renderStaticLibraryLinkMetadata(
    allocator: std.mem.Allocator,
    metadata: StaticLibraryLinkMetadata,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var out_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    try out_writer.writer.print("version = {d}\n", .{metadata.version});
    try out_writer.writer.writeAll("dependencies = [");
    for (metadata.dependencies, 0..) |dependency, index| {
        if (index != 0) try out_writer.writer.writeAll(", ");
        try out_writer.writer.print("\"{s}\"", .{dependency.manifestName()});
    }
    try out_writer.writer.writeAll("]\n");
    out = out_writer.toArrayList();
    return out.toOwnedSlice(allocator);
}

fn parseStaticLibraryDependencies(
    allocator: std.mem.Allocator,
    dependencies: *std.ArrayListUnmanaged(StaticLibraryDependency),
    value: []const u8,
) !void {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') return error.InvalidManifest;
    const inner = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    if (inner.len == 0) return;

    var rest = inner;
    while (rest.len != 0) {
        if (rest[0] != '"') return error.InvalidManifest;
        const end_quote = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return error.InvalidManifest;
        const item = rest[1..end_quote];
        const dependency: StaticLibraryDependency = if (std.mem.eql(u8, item, "runtime"))
            .runtime
        else if (std.mem.eql(u8, item, "std"))
            .std
        else
            return error.InvalidManifest;
        try dependencies.append(allocator, dependency);

        rest = std.mem.trimStart(u8, rest[end_quote + 1 ..], " \t");
        if (rest.len == 0) break;
        if (rest[0] != ',') return error.InvalidManifest;
        rest = std.mem.trimStart(u8, rest[1..], " \t");
    }
}

fn appendBundledArchiveDependency(
    diagnostic_context: diagnostics.Context,
    allocator: std.mem.Allocator,
    paths: *std.ArrayListUnmanaged([]const u8),
    target: build_model.BuildTarget,
    dependency: StaticLibraryDependency,
) !void {
    const path = resolveBundledArchivePath(allocator, target, dependency) catch |err| switch (err) {
        error.StaleBundledArchive => {
            const message = try std.fmt.allocPrint(allocator, "bundled archive `{s}` is older than its sources; run `zig build` in the Cyna checkout", .{dependency.archiveName()});
            defer allocator.free(message);
            try diagnostic_context.emitPath(target.display_path, message);
            return err;
        },
        else => return err,
    } orelse {
        const message = try std.fmt.allocPrint(allocator, "missing required bundled archive `{s}` for target `{s}`", .{
            dependency.archiveName(),
            target.target orelse "native",
        });
        defer allocator.free(message);
        try diagnostic_context.emitPath(target.display_path, message);
        return error.MissingBundledArchive;
    };
    defer allocator.free(path);
    try appendUniqueOwnedPath(allocator, paths, path);
}

fn resolveBundledArchivePath(
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    dependency: StaticLibraryDependency,
) !?[]const u8 {
    if (try resolvePackageLocalArchivePath(allocator, target, dependency)) |path| return path;
    // A compiler run from this checkout must link the runtime built with its
    // current ABI, even when an older release is installed in ~/.cyna.
    if (target.target == null or std.mem.eql(u8, target.target.?, "native")) {
        if (try resolveCheckoutBuiltArchivePath(allocator, dependency)) |path| return path;
    }
    if (try toolchain.resolveTargetSupportArchivePath(allocator, target, dependency)) |path| return path;
    if (try resolveCheckoutBuiltArchivePath(allocator, dependency)) |path| return path;
    return null;
}

fn resolveCheckoutBuiltArchivePath(
    allocator: std.mem.Allocator,
    dependency: StaticLibraryDependency,
) !?[]const u8 {
    const relative_path = try std.fs.path.join(allocator, &.{ "zig-out", "lib", dependency.archiveName() });
    defer allocator.free(relative_path);
    const path = try compilerRepoRelativePath(allocator, relative_path);
    defer allocator.free(path);
    compat.access(path, .{}) catch return null;
    if (!try validateArchiveAtPath(allocator, path)) return null;
    if (!try checkoutArchiveIsFresh(allocator, path, dependency)) return error.StaleBundledArchive;
    return try allocator.dupe(u8, path);
}

fn checkoutArchiveIsFresh(allocator: std.mem.Allocator, archive_path: []const u8, dependency: StaticLibraryDependency) !bool {
    // Checkout archives are installed by `zig build`; reject the common case
    // where a source or included header changed after that installation.
    const sources: []const []const u8 = switch (dependency) {
        .runtime => @import("../runtime/inventory.zig").runtime ++ @import("../runtime/inventory.zig").memory ++ [_][]const u8{ "src/runtime/cyna.h", "src/runtime/failure_trace.h" },
        .std => @import("../runtime/inventory.zig").std_base ++ @import("../runtime/inventory.zig").hosted ++ [_][]const u8{ "src/runtime/cyna.h", "src/runtime/failure_trace.h", "packages/std/src/std_task_group.h" },
    };
    var archive = try compat.openFile(archive_path, .{});
    defer compat.closeFile(archive);
    const archive_mtime = (try archive.stat(compat.io())).mtime.nanoseconds;
    for (sources) |source| {
        const source_path = try compilerRepoRelativePath(allocator, source);
        defer allocator.free(source_path);
        if (!try archiveIsAtLeastAsNewAsSource(archive_mtime, source_path)) {
            std.log.err("bundled archive {s} is older than {s} (archive mtime: {d})", .{ archive_path, source_path, archive_mtime });
            return false;
        }
    }
    return true;
}

fn archiveIsAtLeastAsNewAsSource(archive_mtime: i96, source_path: []const u8) !bool {
    var file = compat.openFile(source_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    defer compat.closeFile(file);
    return (try file.stat(compat.io())).mtime.nanoseconds <= archive_mtime;
}

fn validateArchiveAtPath(allocator: std.mem.Allocator, path: []const u8) !bool {
    const result = compat.runProcess(allocator, .{
        .argv = &.{ "ar", "-t", path },
    }) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn resolvePackageLocalArchivePath(
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    dependency: StaticLibraryDependency,
) !?[]const u8 {
    const package_name = bundledDependencyPackageName(dependency) orelse return null;
    const archive_name = dependency.archiveName();
    const target_id = target.target orelse (try build_model.supportedTargetSupport("native")).id;

    const exe_path = compat.executablePathAlloc(allocator) catch return null;
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return null;
    const candidate_roots = [_][]const u8{
        exe_dir,
        std.fs.path.dirname(exe_dir) orelse exe_dir,
        ".",
        "zig-out",
    };

    for (candidate_roots) |root| {
        const maybe_path = try packageArchivePathAtRoot(allocator, root, package_name, target_id, archive_name);
        if (maybe_path) |path| return path;
    }
    return null;
}

fn bundledDependencyPackageName(dependency: StaticLibraryDependency) ?[]const u8 {
    return switch (dependency) {
        .runtime => null,
        .std => "std",
    };
}

fn compilerRepoRelativePath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    return @import("../distribution_paths.zig").sourcePath(allocator, relative_path);
}

pub fn compilerRepoRelativePathFromExe(
    allocator: std.mem.Allocator,
    exe_path: []const u8,
    relative_path: []const u8,
) ![]u8 {
    return @import("../distribution_paths.zig").relativePathFromExe(allocator, exe_path, relative_path);
}

fn packageArchivePathAtRoot(
    allocator: std.mem.Allocator,
    root: []const u8,
    package_name: []const u8,
    target_id: []const u8,
    archive_name: []const u8,
) !?[]const u8 {
    const archive_path = if (std.mem.eql(u8, std.fs.path.basename(root), "bin"))
        try std.fs.path.join(allocator, &.{ std.fs.path.dirname(root) orelse ".", "packages", package_name, "lib", target_id, archive_name })
    else
        try std.fs.path.join(allocator, &.{ root, "packages", package_name, "lib", target_id, archive_name });
    errdefer allocator.free(archive_path);
    compat.access(archive_path, .{}) catch {
        allocator.free(archive_path);
        return null;
    };
    return archive_path;
}

fn appendUniqueOwnedPath(
    allocator: std.mem.Allocator,
    paths: *std.ArrayListUnmanaged([]const u8),
    path: []const u8,
) !void {
    for (paths.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    try paths.append(allocator, try allocator.dupe(u8, path));
}

fn artifactDependencySlice(buf: *[2]StaticLibraryDependency, deps: ArtifactDeps) []const StaticLibraryDependency {
    var len: usize = 0;
    if (deps.runtime) {
        buf[len] = .runtime;
        len += 1;
    }
    if (deps.std) {
        buf[len] = .std;
        len += 1;
    }
    return buf[0..len];
}

const ExtraGeneratedCSource = struct {
    name: []const u8,
    source: []const u8,
};

fn compileAndRunNativeExecutableWithExtraCSources(
    allocator: std.mem.Allocator,
    llvm_ir: []const u8,
    artifact_deps: ArtifactDeps,
    target: build_model.BuildTarget,
    argv: []const []const u8,
    extra_c_sources: []const ExtraGeneratedCSource,
    diagnostic_context: diagnostics.Context,
) !i64 {
    const tmp = try compat.makeTempWorkspace(allocator, "cyna-native");
    defer tmp.cleanup(allocator);
    const tmp_root = tmp.path;
    const exe_path = try std.fs.path.join(allocator, &.{ tmp_root, "run.native" });
    defer allocator.free(exe_path);

    var extra_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (extra_paths.items) |path| allocator.free(path);
        extra_paths.deinit(allocator);
    }
    for (extra_c_sources) |extra| {
        const extra_path = try std.fs.path.join(allocator, &.{ tmp_root, extra.name });
        errdefer allocator.free(extra_path);
        try compat.writeTextFile(extra_path, extra.source);
        try extra_paths.append(allocator, extra_path);
    }

    var run_target = try cloneTargetWithExtraCSources(allocator, target, extra_paths.items);
    defer run_target.c_sources.deinit(allocator);

    _ = try compileNativeArtifact(allocator, llvm_ir, artifact_deps, run_target, false, true, exe_path, exe_path, .{
        .diagnostic_context = diagnostic_context,
    });

    var child_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer child_argv.deinit(allocator);
    try child_argv.append(allocator, exe_path);
    try child_argv.appendSlice(allocator, argv);

    var child = try std.process.spawn(compat.io(), .{
        .argv = child_argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(compat.io());
    const term = try child.wait(compat.io());

    return switch (term) {
        .exited => |code| @as(i64, @intCast(code)),
        else => error.NativeRunFailed,
    };
}

fn compileAndRunNativeExecutableWithRootObject(
    allocator: std.mem.Allocator,
    root_object_path: []const u8,
    artifact_deps: ArtifactDeps,
    target: build_model.BuildTarget,
    argv: []const []const u8,
    extra_c_sources: []const ExtraGeneratedCSource,
    diagnostic_context: diagnostics.Context,
) !i64 {
    const tmp = try compat.makeTempWorkspace(allocator, "cyna-native");
    defer tmp.cleanup(allocator);
    const exe_path = try std.fs.path.join(allocator, &.{ tmp.path, "run.native" });
    defer allocator.free(exe_path);
    try buildNativeExecutableWithRootObject(
        allocator,
        root_object_path,
        artifact_deps,
        target,
        tmp.path,
        exe_path,
        extra_c_sources,
        diagnostic_context,
    );
    return runNativeExecutable(allocator, exe_path, argv);
}

fn buildNativeExecutableWithRootObject(
    allocator: std.mem.Allocator,
    root_object_path: []const u8,
    artifact_deps: ArtifactDeps,
    target: build_model.BuildTarget,
    tmp_root: []const u8,
    exe_path: []const u8,
    extra_c_sources: []const ExtraGeneratedCSource,
    diagnostic_context: diagnostics.Context,
) !void {
    var extra_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (extra_paths.items) |path| allocator.free(path);
        extra_paths.deinit(allocator);
    }
    for (extra_c_sources) |extra| {
        const extra_path = try std.fs.path.join(allocator, &.{ tmp_root, extra.name });
        errdefer allocator.free(extra_path);
        try compat.writeTextFile(extra_path, extra.source);
        try extra_paths.append(allocator, extra_path);
    }

    var run_target = try cloneTargetWithExtraCSources(allocator, target, extra_paths.items);
    defer run_target.c_sources.deinit(allocator);
    var distribution_tools = try toolchain.resolveDistributionToolsWithDiagnostics(allocator, run_target, diagnostic_context);
    defer distribution_tools.deinit(allocator);

    var object_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (object_paths.items) |path| allocator.free(path);
        object_paths.deinit(allocator);
    }
    try object_paths.append(allocator, try allocator.dupe(u8, root_object_path));

    var effective_artifact_deps = artifact_deps;
    if (run_target.leak_check) effective_artifact_deps.runtime = true;
    if (run_target.leak_check) {
        try appendRuntimeLeakCheckObject(allocator, distribution_tools, tmp_root, &object_paths, run_target);
    }
    try appendNativeObjects(allocator, distribution_tools, tmp_root, &object_paths, run_target, run_target.c_sources, "c", run_target.opt, false, false);
    try appendNativeObjects(allocator, distribution_tools, tmp_root, &object_paths, run_target, run_target.asm_sources, "asm", run_target.opt, false, false);
    try linkNativeArtifact(diagnostic_context, allocator, distribution_tools, exe_path, object_paths.items, run_target, false, effective_artifact_deps, false, false);
}

fn runNativeExecutable(allocator: std.mem.Allocator, exe_path: []const u8, argv: []const []const u8) !i64 {
    var child_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer child_argv.deinit(allocator);
    try child_argv.append(allocator, exe_path);
    try child_argv.appendSlice(allocator, argv);
    var child = try std.process.spawn(compat.io(), .{
        .argv = child_argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(compat.io());
    const term = try child.wait(compat.io());
    return switch (term) {
        .exited => |code| @as(i64, @intCast(code)),
        else => error.NativeRunFailed,
    };
}

fn monotonicNanoTimestamp() u64 {
    return @intCast(@max(0, monotonicNowNs()));
}

fn cloneTargetWithExtraCSources(
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    extra_c_source_paths: []const []const u8,
) !build_model.BuildTarget {
    var cloned = target;
    cloned.c_sources = .{
        .sources = try cloneSourceListWithExtra(allocator, target.c_sources.sources, extra_c_source_paths),
        .include_paths = try cloneStringSlice(allocator, target.c_sources.include_paths),
        .flags = try cloneStringSlice(allocator, target.c_sources.flags),
    };
    return cloned;
}

fn cloneSourceListWithExtra(
    allocator: std.mem.Allocator,
    base: []const []const u8,
    extra: []const []const u8,
) ![][]const u8 {
    var out = try allocator.alloc([]const u8, base.len + extra.len);
    errdefer allocator.free(out);
    var written: usize = 0;
    errdefer {
        for (out[0..written]) |item| allocator.free(item);
    }
    for (base) |item| {
        out[written] = try allocator.dupe(u8, item);
        written += 1;
    }
    for (extra) |item| {
        out[written] = try allocator.dupe(u8, item);
        written += 1;
    }
    return out;
}

fn cloneStringSlice(allocator: std.mem.Allocator, items: []const []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(out);
    var written: usize = 0;
    errdefer {
        for (out[0..written]) |item| allocator.free(item);
    }
    for (items) |item| {
        out[written] = try allocator.dupe(u8, item);
        written += 1;
    }
    return out;
}

fn emittedArtifactPath(allocator: std.mem.Allocator, base: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, suffix });
}

fn appendTargetFlags(
    allocator: std.mem.Allocator,
    argv: *std.ArrayListUnmanaged([]const u8),
    target: build_model.BuildTarget,
    include_linker_flags: bool,
) !void {
    const normalized = try build_model.normalizedToolchainTarget(allocator, target.target);
    defer if (normalized) |value| allocator.free(value);
    if (normalized) |value| {
        const flag = try std.fmt.allocPrint(allocator, "--target={s}", .{value});
        try argv.append(allocator, flag);
    }
    try appendHostedDarwinSdkFlags(allocator, argv, target, include_linker_flags);
    if (target.cpu) |cpu| {
        if (cpu.len == 0) {
            if (build_model.isFreestandingTarget(target.target)) {
                try argv.append(allocator, try allocator.dupe(u8, "-ffreestanding"));
                try appendFreestandingTargetCodeModelFlag(allocator, argv, normalized orelse target.target.?);
                try appendFreestandingTargetRegisterFlags(allocator, argv, normalized orelse target.target.?);
            }
            return;
        }
        const flag = try std.fmt.allocPrint(allocator, "-mcpu={s}", .{cpu});
        try argv.append(allocator, flag);
    } else if (normalized) |value| {
        if (std.mem.eql(u8, value, "arm-none-eabi")) {
            try argv.append(allocator, try allocator.dupe(u8, "-mcpu=arm1176jzf-s"));
        }
    }
    if (build_model.isFreestandingTarget(target.target)) {
        try argv.append(allocator, try allocator.dupe(u8, "-ffreestanding"));
        try appendFreestandingTargetCodeModelFlag(allocator, argv, normalized orelse target.target.?);
        try appendFreestandingTargetRegisterFlags(allocator, argv, normalized orelse target.target.?);
    }
}

fn appendFreestandingTargetCodeModelFlag(
    allocator: std.mem.Allocator,
    argv: *std.ArrayListUnmanaged([]const u8),
    normalized_target: []const u8,
) !void {
    if (std.mem.eql(u8, normalized_target, "riscv64-none-elf")) {
        try argv.append(allocator, try allocator.dupe(u8, "-mcmodel=medany"));
    }
}

fn appendFreestandingTargetRegisterFlags(
    allocator: std.mem.Allocator,
    argv: *std.ArrayListUnmanaged([]const u8),
    normalized_target: []const u8,
) !void {
    if (std.mem.eql(u8, normalized_target, "aarch64-none-elf")) {
        try argv.append(allocator, try allocator.dupe(u8, "-mgeneral-regs-only"));
    }
}

fn appendHostedDarwinSdkFlags(
    allocator: std.mem.Allocator,
    argv: *std.ArrayListUnmanaged([]const u8),
    target: build_model.BuildTarget,
    include_linker_flags: bool,
) !void {
    if (build_model.isFreestandingTarget(target.target)) return;
    if (target.target != null and !std.mem.eql(u8, target.target.?, "aarch64-apple-darwin")) return;
    if (@import("builtin").os.tag != .macos) return;

    const sdk_path = try detectDarwinSdkPath(allocator) orelse return;
    defer allocator.free(sdk_path);

    try argv.append(allocator, try allocator.dupe(u8, "-isysroot"));
    const sdk_path_arg = try allocator.dupe(u8, sdk_path);
    errdefer allocator.free(sdk_path_arg);
    try argv.append(allocator, sdk_path_arg);

    if (include_linker_flags) {
        const syslibroot_flag = try std.fmt.allocPrint(allocator, "-Wl,-syslibroot,{s}", .{sdk_path});
        errdefer allocator.free(syslibroot_flag);
        try argv.append(allocator, syslibroot_flag);
    }
}

fn detectDarwinSdkPath(allocator: std.mem.Allocator) !?[]u8 {
    const result = compat.runProcess(allocator, .{
        .argv = &.{ "xcrun", "--show-sdk-path" },
    }) catch |err| switch (err) {
        error.FileNotFound => return fallbackDarwinSdkPath(allocator),
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0) {
            const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
            if (trimmed.len != 0) {
                const owned = try allocator.dupe(u8, trimmed);
                return owned;
            }
        },
        else => {},
    }

    return fallbackDarwinSdkPath(allocator);
}

fn fallbackDarwinSdkPath(allocator: std.mem.Allocator) !?[]u8 {
    const candidates = [_][]const u8{
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
    };
    for (candidates) |candidate| {
        compat.access(candidate, .{}) catch continue;
        const owned = try allocator.dupe(u8, candidate);
        return owned;
    }
    return null;
}

fn isAllocatedCompileFlag(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "--target=") or
        std.mem.startsWith(u8, arg, "-mcpu=") or
        std.mem.startsWith(u8, arg, "-mcmodel=") or
        std.mem.startsWith(u8, arg, "-I") or
        std.mem.startsWith(u8, arg, "-isystem") or
        std.mem.eql(u8, arg, "-isysroot") or
        std.mem.eql(u8, arg, "-ffreestanding") or
        std.mem.eql(u8, arg, "-mgeneral-regs-only") or
        std.mem.eql(u8, arg, "-nostdlib") or
        std.mem.startsWith(u8, arg, "-fuse-ld=") or
        std.mem.startsWith(u8, arg, "-Wl,-syslibroot,");
}

fn freeOwnedCompileFlags(allocator: std.mem.Allocator, argv: []const []const u8) void {
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const is_isysroot = std.mem.eql(u8, arg, "-isysroot");
        if (isAllocatedCompileFlag(arg)) {
            allocator.free(arg);
            if (is_isysroot and i + 1 < argv.len) {
                allocator.free(argv[i + 1]);
                i += 1;
            }
        }
    }
}

fn compileObjectJobs(
    allocator: std.mem.Allocator,
    tools: ResolvedDistributionTools,
    target: build_model.BuildTarget,
    opt: build_model.OptMode,
    jobs: []CompileObjectJob,
    requested_workers: usize,
    activity: bool,
    verbose: bool,
) !void {
    if (jobs.len == 0) return;
    const worker_count = if (requested_workers != 0)
        @min(requested_workers, jobs.len)
    else
        @min(@min(std.Thread.getCpuCount() catch 1, 8), jobs.len);
    var context = CompileObjectWorkerContext{
        .allocator = allocator,
        .tools = tools,
        .target = target,
        .activity = activity,
        .verbose = verbose,
        .jobs = jobs,
        .next_index = .init(0),
    };
    if (worker_count == 1) {
        compileObjectWorker(&context, opt);
        return;
    }
    const workers = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(workers);
    var spawned: usize = 0;
    errdefer for (workers[0..spawned]) |worker| worker.join();
    while (spawned < worker_count) : (spawned += 1) {
        workers[spawned] = try std.Thread.spawn(.{}, compileObjectWorker, .{ &context, opt });
    }
    for (workers) |worker| worker.join();
}

fn compileObjectWorker(context: *CompileObjectWorkerContext, opt: build_model.OptMode) void {
    while (true) {
        const index = context.next_index.fetchAdd(1, .monotonic);
        if (index >= context.jobs.len) return;
        const job = &context.jobs[index];
        job.reused = compileIrObject(context.allocator, context.tools, job.ir_path, job.object_path, context.target, opt, .{
            .index = index + 1,
            .total = context.jobs.len,
            .label = job.label,
            .ir_bytes = job.ir_bytes,
            .enabled = context.activity,
            .verbose = context.verbose,
        }) catch |err| {
            job.failure = err;
            return;
        };
    }
}

const ObjectActivity = struct {
    index: usize = 1,
    total: usize = 1,
    label: []const u8 = "",
    ir_bytes: usize = 0,
    enabled: bool = false,
    verbose: bool = false,
};

fn compileIrObject(
    allocator: std.mem.Allocator,
    resolved_tools: ResolvedDistributionTools,
    ir_path: []const u8,
    object_path: []const u8,
    target: build_model.BuildTarget,
    opt: build_model.OptMode,
    activity: ObjectActivity,
) !bool {
    const section_flags: []const []const u8 = if (build_model.isFreestandingTarget(target.target))
        &.{ "-ffunction-sections", "-fdata-sections" }
    else
        &.{};
    const cache_path = try nativeObjectCachePath(allocator, target, "llvm", ir_path, &resolved_tools.cache_identity, section_flags, opt, &.{});
    defer allocator.free(cache_path);
    if (try restoreCachedObject(allocator, cache_path, object_path)) return true;

    var heartbeat_buf: [512]u8 = undefined;
    const heartbeat_label: ?[]const u8 = if (activity.enabled)
        objectHeartbeatLabel(&heartbeat_buf, activity)
    else
        null;
    if (activity.enabled) std.debug.print("compiling LLVM IR object {d}/{d} ({s}, {d} bytes of IR)...\n", .{
        activity.index,
        activity.total,
        if (activity.label.len != 0) activity.label else ir_path,
        activity.ir_bytes,
    });
    if (activity.enabled and activity.ir_bytes > large_module_ir_warning_bytes) {
        std.debug.print(
            "warning: module {s} lowers to {d:.1} MB of LLVM IR; clang optimization may take minutes (split this module or use opt = \"debug\" for iteration)\n",
            .{
                if (activity.label.len != 0) activity.label else ir_path,
                @as(f64, @floatFromInt(activity.ir_bytes)) / (1024.0 * 1024.0),
            },
        );
    }

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ resolved_tools.cc.path, "-c", "-x", "ir", ir_path, "-o", object_path });
    try appendTargetFlags(allocator, &argv, target, false);
    if (build_model.isFreestandingTarget(target.target)) {
        try argv.appendSlice(allocator, &.{ "-ffunction-sections", "-fdata-sections" });
    }
    if (opt == .release) try argv.append(allocator, "-O2");
    if (opt == .debug) try argv.append(allocator, "-g");
    defer {
        freeOwnedCompileFlags(allocator, argv.items);
    }
    const started_ns = monotonicNowNs();
    try runToolInherited(argv.items, heartbeat_label, activity.verbose);
    if (activity.verbose) std.debug.print("  compiled {s} in {d:.1}s\n", .{
        if (activity.label.len != 0) activity.label else ir_path,
        elapsedSeconds(started_ns),
    });
    try storeCachedObject(allocator, cache_path, object_path);
    return false;
}

fn objectHeartbeatLabel(buf: []u8, activity: ObjectActivity) ?[]const u8 {
    if (activity.label.len == 0) {
        return std.fmt.bufPrint(buf, "LLVM IR object {d}/{d}", .{ activity.index, activity.total }) catch null;
    }
    return std.fmt.bufPrint(buf, "LLVM IR object {d}/{d} ({s})", .{
        activity.index,
        activity.total,
        activity.label,
    }) catch null;
}

fn compileCSource(
    allocator: std.mem.Allocator,
    resolved_tools: ResolvedDistributionTools,
    source_path: []const u8,
    object_path: []const u8,
    target: build_model.BuildTarget,
    include_paths: []const []const u8,
    flags: []const []const u8,
    opt: build_model.OptMode,
    activity: ToolActivity,
) !void {
    // A translation unit can include local or transitive headers even without
    // explicit include paths. Until compiler dependency files participate in
    // the key, user and bundled C translation units must be rebuilt rather
    // than risking a stale native object.
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ resolved_tools.cc.path, "-c", source_path, "-o", object_path });
    try appendTargetFlags(allocator, &argv, target, false);
    if (build_model.isFreestandingTarget(target.target)) {
        try argv.appendSlice(allocator, &.{ "-ffunction-sections", "-fdata-sections" });
    }
    if (opt == .release) try argv.append(allocator, "-O2");
    if (opt == .debug) try argv.append(allocator, "-g");
    for (include_paths) |include_path| {
        const flag = try std.fmt.allocPrint(allocator, "-I{s}", .{include_path});
        defer allocator.free(flag);
        try argv.append(allocator, try allocator.dupe(u8, flag));
    }
    // Manifest flags are owned by the build target. The generated argv
    // entries that freeOwnedCompileFlags releases must be copies, and the
    // value after an explicit -isysroot flag is released as well.
    for (flags, 0..) |flag, index| {
        const will_be_freed = isAllocatedCompileFlag(flag) or
            (index > 0 and std.mem.eql(u8, flags[index - 1], "-isysroot"));
        try argv.append(allocator, if (will_be_freed) try allocator.dupe(u8, flag) else flag);
    }
    defer {
        freeOwnedCompileFlags(allocator, argv.items);
    }
    const started_ns = monotonicNowNs();
    try runToolInherited(argv.items, activity.label, activity.verbose);
    if (activity.verbose) {
        if (activity.label) |label| {
            std.debug.print("  compiled {s} in {d:.1}s\n", .{ label, elapsedSeconds(started_ns) });
        }
    }
}

fn compileAsmSource(
    allocator: std.mem.Allocator,
    resolved_tools: ResolvedDistributionTools,
    source_path: []const u8,
    object_path: []const u8,
    target: build_model.BuildTarget,
    include_paths: []const []const u8,
    flags: []const []const u8,
    opt: build_model.OptMode,
    activity: ToolActivity,
) !void {
    try compileCSource(allocator, resolved_tools, source_path, object_path, target, include_paths, flags, opt, activity);
}

fn nativeObjectCachePath(
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    kind: []const u8,
    source_path: []const u8,
    tool_identity: []const u8,
    include_paths: []const []const u8,
    opt: build_model.OptMode,
    flags: []const []const u8,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("cyna-native-object-v1\x00");
    hasher.update(kind);
    hasher.update("\x00");
    try hashFileInto(&hasher, source_path);
    hasher.update("\x00");
    hasher.update(tool_identity);
    hasher.update("\x00");
    hasher.update(target.target orelse "native");
    hasher.update("\x00");
    hasher.update(target.cpu orelse "");
    hasher.update("\x00");
    hasher.update(@tagName(opt));
    hasher.update("\x00");
    hasher.update(build_options.cyna_version);
    hasher.update(target.compiler_identity);
    for (include_paths) |path| {
        hasher.update("\x00-I");
        hasher.update(path);
    }
    for (flags) |flag| {
        hasher.update("\x00-F");
        hasher.update(flag);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const cache_dir = try std.fs.path.join(allocator, &.{ target.root_dir, ".cyna-cache", "native-objects" });
    defer allocator.free(cache_dir);
    try compat.makePath(cache_dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}-{s}.o", .{ cache_dir, kind, hex });
}

fn hashFileInto(hasher: *std.crypto.hash.sha2.Sha256, path: []const u8) !void {
    var file = try compat.openFile(path, .{});
    defer compat.closeFile(file);
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(compat.io(), &.{});
    while (true) {
        const count = reader.interface.readSliceShort(&read_buffer) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
        };
        if (count == 0) break;
        hasher.update(read_buffer[0..count]);
    }
}

fn restoreCachedObject(allocator: std.mem.Allocator, cache_path: []const u8, object_path: []const u8) !bool {
    native_object_cache_mutex.lockUncancelable(compat.io());
    defer native_object_cache_mutex.unlock(compat.io());
    const entry = (try cache_bundle.load(allocator, cache_path)) orelse return false;
    defer entry.deinit(allocator);
    if (entry.artifacts.len != 1 or !std.mem.eql(u8, entry.metadata, "native-artifact-v2")) return false;
    const artifact = entry.artifact("primary") orelse return false;
    try cache_bundle.restoreArtifact(artifact, object_path);
    return true;
}

fn storeCachedObject(allocator: std.mem.Allocator, cache_path: []const u8, object_path: []const u8) !void {
    native_object_cache_mutex.lockUncancelable(compat.io());
    defer native_object_cache_mutex.unlock(compat.io());
    const file = try compat.openFile(object_path, .{});
    defer compat.closeFile(file);
    const mode: u32 = if (@import("builtin").os.tag == .windows) 0 else (try file.stat(compat.io())).permissions.toMode();
    const bytes = try compat.readFileAlloc(allocator, object_path, 256 * 1024 * 1024);
    defer allocator.free(bytes);
    try cache_bundle.publish(allocator, cache_path, "native-artifact-v2", &.{.{ .name = "primary", .contents = bytes, .mode = @intCast(mode & 0o7777) }});
}

fn appendNativeObjects(
    allocator: std.mem.Allocator,
    resolved_tools: ResolvedDistributionTools,
    tmp_root: []const u8,
    object_paths: *std.ArrayListUnmanaged([]const u8),
    target: build_model.BuildTarget,
    native: build_model.NativeSourceOptions,
    prefix: []const u8,
    opt: build_model.OptMode,
    activity: bool,
    verbose: bool,
) !void {
    for (native.sources, 0..) |source_path, index| {
        const object_name = try std.fmt.allocPrint(allocator, "{s}-{d}.o", .{ prefix, index });
        defer allocator.free(object_name);
        const object_path = try std.fs.path.join(allocator, &.{ tmp_root, object_name });
        errdefer allocator.free(object_path);
        const kind = if (std.mem.eql(u8, prefix, "asm")) "ASM" else "C";
        var label_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "{s} source {d}/{d} ({s})", .{
            kind,
            index + 1,
            native.sources.len,
            source_path,
        }) catch source_path;
        const tool_activity: ToolActivity = if (activity) .{ .label = label, .verbose = verbose } else .{};
        if (activity) std.debug.print("compiling {s}...\n", .{label});
        if (std.mem.eql(u8, prefix, "asm")) {
            try compileAsmSource(allocator, resolved_tools, source_path, object_path, target, native.include_paths, native.flags, opt, tool_activity);
        } else {
            try compileCSource(allocator, resolved_tools, source_path, object_path, target, native.include_paths, native.flags, opt, tool_activity);
        }
        try object_paths.append(allocator, object_path);
    }
}

fn linkExecutableLike(
    diagnostic_context: diagnostics.Context,
    allocator: std.mem.Allocator,
    resolved_tools: ResolvedDistributionTools,
    output_path: []const u8,
    object_paths: []const []const u8,
    archive_paths: []const []const u8,
    target: build_model.BuildTarget,
    shared: bool,
    verbose: bool,
    progress: bool,
) !void {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, resolved_tools.cc.path);
    try appendTargetFlags(allocator, &argv, target, true);
    if (shared) try argv.append(allocator, "-shared");
    if (build_model.isFreestandingTarget(target.target) and !shared) {
        try argv.append(allocator, try allocator.dupe(u8, "-nostdlib"));
        try argv.append(allocator, try allocator.dupe(u8, "-Wl,--gc-sections"));
        const lld = resolved_tools.lld orelse {
            try diagnostic_context.emitPath(target.display_path, "freestanding target requires ld.lld in the LLVM toolchain bundle");
            return error.NativeCompileFailed;
        };
        const fuse_ld_flag = try std.fmt.allocPrint(allocator, "-fuse-ld={s}", .{lld.path});
        defer allocator.free(fuse_ld_flag);
        try argv.append(allocator, try allocator.dupe(u8, fuse_ld_flag));
    }
    try argv.appendSlice(allocator, object_paths);
    try argv.appendSlice(allocator, archive_paths);
    if (@import("builtin").os.tag == .linux and !build_model.isFreestandingTarget(target.target)) {
        // The hosted std.math companion calls libm functions such as log2.
        try argv.append(allocator, try allocator.dupe(u8, "-lm"));
    }
    if (target.link.script) |script| {
        const flag = try std.fmt.allocPrint(allocator, "-Wl,-T,{s}", .{script});
        defer allocator.free(flag);
        try argv.append(allocator, try allocator.dupe(u8, flag));
    }
    if (target.link.entry_symbol) |entry_symbol| {
        const flag = try std.fmt.allocPrint(allocator, "-Wl,-e,{s}", .{entry_symbol});
        defer allocator.free(flag);
        try argv.append(allocator, try allocator.dupe(u8, flag));
    }
    for (target.link.search_paths) |search_path| {
        const flag = try std.fmt.allocPrint(allocator, "-L{s}", .{search_path});
        defer allocator.free(flag);
        try argv.append(allocator, try allocator.dupe(u8, flag));
    }
    for (target.link.libs) |lib| {
        const flag = try std.fmt.allocPrint(allocator, "-l{s}", .{lib});
        defer allocator.free(flag);
        try argv.append(allocator, try allocator.dupe(u8, flag));
    }
    const needs_compiler_rt_builtins = build_model.isFreestandingTarget(target.target) and !shared;
    const compiler_rt_builtins = if (needs_compiler_rt_builtins)
        try resolveCompilerRtBuiltinsArchive(allocator, resolved_tools, target)
    else
        null;
    defer if (compiler_rt_builtins) |path| allocator.free(path);
    // Keep the borrowed compiler-rt path alive while the flag cleanup scans
    // argv. Cache hits take this same exit path.
    defer freeOwnedLinkerFlags(allocator, argv.items);
    if (needs_compiler_rt_builtins) {
        const path = compiler_rt_builtins orelse {
            try diagnostic_context.emitPath(target.display_path, "freestanding target requires compiler-rt builtins archive in the LLVM toolchain bundle");
            return error.NativeCompileFailed;
        };
        try argv.append(allocator, path);
    }

    const link_cache_path = try nativeLinkCachePath(
        allocator,
        target,
        resolved_tools,
        object_paths,
        archive_paths,
        compiler_rt_builtins,
        shared,
    );
    defer if (link_cache_path) |path| allocator.free(path);
    if (link_cache_path) |path| {
        if (try restoreCachedObject(allocator, path, output_path)) {
            reportProgress(verbose, "reusing cached native artifact\n", .{});
            return;
        }
    }

    const link_label = if (shared) "native shared library" else "native executable";
    if (reportsActivity(verbose, progress)) std.debug.print("linking {s}...\n", .{link_label});
    try argv.appendSlice(allocator, &.{ "-o", output_path });
    const started_ns = monotonicNowNs();
    try runToolInherited(argv.items, if (reportsActivity(verbose, progress)) link_label else null, verbose);
    if (verbose) std.debug.print("  linked {s} in {d:.1}s\n", .{ link_label, elapsedSeconds(started_ns) });
    if (link_cache_path) |path| try storeCachedObject(allocator, path, output_path);
}

fn nativeLinkCachePath(
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    resolved_tools: ResolvedDistributionTools,
    object_paths: []const []const u8,
    archive_paths: []const []const u8,
    compiler_rt_builtins: ?[]const u8,
    shared: bool,
) !?[]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("cyna-native-link-v1\x00");
    hasher.update(build_options.cyna_version);
    hasher.update(target.compiler_identity);
    hashLinkString(&hasher, resolved_tools.cc.path);
    hasher.update(&resolved_tools.cache_identity);
    if (!(try updateHostedLinkCacheIdentity(allocator, &hasher, resolved_tools, target))) return null;
    hashLinkString(&hasher, target.target orelse "native");
    hashLinkString(&hasher, target.cpu orelse "");
    hashLinkString(&hasher, @tagName(target.output_kind));
    hashLinkString(&hasher, if (shared) "shared" else "executable");
    hashLinkString(&hasher, if (target.leak_check) "leak-check" else "no-leak-check");
    for (object_paths) |path| try hashLinkFile(&hasher, allocator, path);
    for (archive_paths) |path| try hashLinkFile(&hasher, allocator, path);
    if (compiler_rt_builtins) |path| try hashLinkFile(&hasher, allocator, path);
    if (target.link.script) |path| try hashLinkFile(&hasher, allocator, path);
    hashLinkStringSlice(&hasher, target.link.search_paths);
    hashLinkStringSlice(&hasher, target.link.libs);
    hashLinkString(&hasher, target.link.entry_symbol orelse "");

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const dir = try std.fs.path.join(allocator, &.{ target.root_dir, ".cyna-cache", "native-artifacts" });
    defer allocator.free(dir);
    try compat.makePath(dir);
    return @as(?[]u8, try std.fmt.allocPrint(allocator, "{s}/{s}.native", .{ dir, hex }));
}

/// Hosted Clang can invoke a system linker rather than the bundled lld. Its
/// selected executable and SDK link inputs belong to the link cache contract.
pub fn updateHostedLinkCacheIdentity(
    allocator: std.mem.Allocator,
    hasher: *std.crypto.hash.sha2.Sha256,
    tools: ResolvedDistributionTools,
    target: build_model.BuildTarget,
) !bool {
    if (build_model.isFreestandingTarget(target.target)) return true;
    // Zig's Windows clang driver resolves its bundled linker internally.
    // Until those inputs are inventoried, disable persistent link reuse.
    if (@import("builtin").os.tag == .windows) return false;
    // Inventoring the default Linux linker search trees hashes whole system
    // libraries for every link. On release runners this takes minutes for a
    // tiny program. A fresh link is cheaper and keeps the cache correct.
    if (@import("builtin").os.tag == .linux) return false;
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ tools.cc.path, "-print-prog-name=ld" });
    try appendTargetFlags(allocator, &argv, target, false);
    defer freeOwnedCompileFlags(allocator, argv.items);
    const query = try compat.runProcess(allocator, .{ .argv = argv.items });
    defer allocator.free(query.stdout);
    defer allocator.free(query.stderr);
    if (query.term != .exited or query.term.exited != 0) return error.NativeCompileFailed;
    const selected = std.mem.trim(u8, query.stdout, " \t\r\n");
    if (selected.len == 0) return error.NativeCompileFailed;
    const linker = if (std.fs.path.isAbsolute(selected))
        try allocator.dupe(u8, selected)
    else blk: {
        const search_argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
            &.{ "where", selected }
        else
            &.{ "/usr/bin/env", "which", selected };
        const result = try compat.runProcess(allocator, .{ .argv = search_argv });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) return error.NativeCompileFailed;
        break :blk try allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
    };
    defer allocator.free(linker);
    hashLinkString(hasher, "hosted-linker");
    hashLinkString(hasher, linker);
    try hashLinkFile(hasher, allocator, linker);
    // Explicit search trees affect both library contents and which candidate
    // wins. Include names as well as contents, including newly added files.
    for (target.link.search_paths) |root| try hashLinkInputTree(allocator, hasher, root);
    if (@import("builtin").os.tag == .linux and
        !(try hashLinuxImplicitLinkInputs(allocator, hasher, tools.cc.path, linker, target))) return false;
    if (@import("builtin").os.tag == .macos and
        (target.target == null or std.mem.eql(u8, target.target.?, "aarch64-apple-darwin")))
    {
        const sdk = try detectDarwinSdkPath(allocator) orelse return false;
        defer allocator.free(sdk);
        hashLinkString(hasher, "darwin-sdk");
        try hashLinkInputTree(allocator, hasher, sdk);
    }
    for ([_][]const u8{ "PATH", "LIBRARY_PATH", "LD_LIBRARY_PATH", "LDEMULATION", "LD_RUN_PATH", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET" }) |name| {
        if (@import("builtin").os.tag != .linux and
            (std.mem.eql(u8, name, "LD_LIBRARY_PATH") or std.mem.eql(u8, name, "LDEMULATION") or std.mem.eql(u8, name, "LD_RUN_PATH"))) continue;
        hashLinkString(hasher, name);
        const value = compat.getEnvVarOwned(allocator, name) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => continue,
            else => return err,
        };
        defer allocator.free(value);
        hashLinkString(hasher, value);
        if (std.mem.eql(u8, name, "LIBRARY_PATH") or std.mem.eql(u8, name, "LD_LIBRARY_PATH")) try hashLibrarySearchEnvironment(allocator, hasher, value);
    }
    return true;
}

/// Native Linux links search directories supplied by both the compiler driver
/// and the linker's default script. If either inventory cannot be read, the
/// caller must bypass persistent native and whole-build cache reuse.
fn hashLinuxImplicitLinkInputs(
    allocator: std.mem.Allocator,
    hasher: *std.crypto.hash.sha2.Sha256,
    compiler: []const u8,
    linker: []const u8,
    target: build_model.BuildTarget,
) !bool {
    // An explicit target may select a different sysroot or linker emulation.
    // Until those driver arguments are inventoried, do not reuse its link.
    if (target.target != null) return false;
    const driver = compat.runProcess(allocator, .{ .argv = &.{ compiler, "-print-search-dirs" } }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer allocator.free(driver.stdout);
    defer allocator.free(driver.stderr);
    if (driver.term != .exited or driver.term.exited != 0) return false;
    const linker_args: []const []const u8 = if (target.output_kind == .sharedlib)
        &.{ linker, "-shared", "--verbose" }
    else
        &.{ linker, "--verbose" };
    const linker_script = compat.runProcess(allocator, .{ .argv = linker_args }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer allocator.free(linker_script.stdout);
    defer allocator.free(linker_script.stderr);
    if (linker_script.term != .exited or linker_script.term.exited != 0) return false;
    hashLinkString(hasher, "linux-clang-search-dirs");
    hashLinkString(hasher, driver.stdout);
    hashLinkString(hasher, "linux-linker-default-script");
    hashLinkString(hasher, linker_script.stdout);
    if (!(hashClangLibrarySearchDirs(allocator, hasher, driver.stdout) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    })) return false;
    if (!(hashLinkerScriptSearchDirs(allocator, hasher, linker_script.stdout) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    })) return false;
    return true;
}

fn hashClangLibrarySearchDirs(allocator: std.mem.Allocator, hasher: *std.crypto.hash.sha2.Sha256, output: []const u8) !bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "libraries:")) continue;
        var value = std.mem.trim(u8, trimmed["libraries:".len..], " \t");
        if (std.mem.startsWith(u8, value, "=")) value = value[1..];
        var count: usize = 0;
        var paths = std.mem.splitScalar(u8, value, std.fs.path.delimiter);
        const cwd = try compat.cwdRealpathAlloc(allocator, ".");
        defer allocator.free(cwd);
        while (paths.next()) |path| {
            const candidate = if (path.len == 0) "." else path;
            const absolute = if (std.fs.path.isAbsolute(candidate))
                try allocator.dupe(u8, candidate)
            else
                try std.fs.path.resolve(allocator, &.{ cwd, candidate });
            defer allocator.free(absolute);
            try hashLinkInputTree(allocator, hasher, absolute);
            count += 1;
        }
        return count != 0;
    }
    return false;
}

fn hashLinkerScriptSearchDirs(allocator: std.mem.Allocator, hasher: *std.crypto.hash.sha2.Sha256, script: []const u8) !bool {
    var offset: usize = 0;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, script, offset, "SEARCH_DIR(\"")) |start| {
        const path_start = start + "SEARCH_DIR(\"".len;
        const end = std.mem.indexOfPos(u8, script, path_start, "\")") orelse return false;
        const raw = script[path_start..end];
        // `=` and `$SYSROOT` use the linker's configured root, which may not
        // be the host root even when the compiler target is implicit.
        if (std.mem.startsWith(u8, raw, "=") or std.mem.startsWith(u8, raw, "$SYSROOT")) return false;
        if (!std.fs.path.isAbsolute(raw)) return false;
        try hashLinkInputTree(allocator, hasher, raw);
        count += 1;
        offset = end + 2;
    }
    return count != 0;
}

fn hashLibrarySearchEnvironment(allocator: std.mem.Allocator, hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) !void {
    var paths = std.mem.splitScalar(u8, value, std.fs.path.delimiter);
    while (paths.next()) |path| {
        // Empty search components denote the working directory, not absence.
        const candidate = if (path.len == 0) "." else path;
        const absolute = try compat.cwdRealpathAlloc(allocator, candidate);
        defer allocator.free(absolute);
        try hashLinkInputTree(allocator, hasher, absolute);
    }
}

fn hashLinkInputTree(allocator: std.mem.Allocator, hasher: *std.crypto.hash.sha2.Sha256, root: []const u8) !void {
    hashLinkString(hasher, root);
    var dir = compat.openDirAbsolute(root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            hashLinkString(hasher, "missing-library-directory");
            return;
        },
        else => return err,
    };
    defer compat.closeDir(dir);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    while (try compat.walkerNext(&walker)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const extension = std.fs.path.extension(entry.path);
        if (!std.mem.eql(u8, extension, ".tbd") and !std.mem.eql(u8, extension, ".dylib") and
            !std.mem.eql(u8, extension, ".a") and !std.mem.eql(u8, extension, ".so") and std.mem.indexOf(u8, entry.path, ".so.") == null and
            !std.mem.eql(u8, extension, ".o") and !std.mem.startsWith(u8, std.fs.path.basename(entry.path), "SDKSettings")) continue;
        const owned = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(owned);
        try paths.append(allocator, owned);
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (paths.items) |relative| {
        hashLinkString(hasher, relative);
        const absolute = try std.fs.path.join(allocator, &.{ root, relative });
        defer allocator.free(absolute);
        hashLinkFile(hasher, allocator, absolute) catch |err| switch (err) {
            // Search directories may contain an unrelated dangling soname.
            // Record its negative state; do not make a valid link fail merely
            // because the linker would never select that candidate.
            error.FileNotFound => hashLinkString(hasher, "missing-library-file"),
            else => return err,
        };
    }
}

fn hashLinkFile(hasher: *std.crypto.hash.sha2.Sha256, allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    var file = try compat.openFile(path, .{});
    defer compat.closeFile(file);
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(compat.io(), &.{});
    // Temporary object paths are not link inputs. Ordered content digests are;
    // fixed-size framing also prevents adjacent file contents from aliasing.
    var file_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const count = reader.interface.readSliceShort(&read_buffer) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
        };
        if (count == 0) break;
        file_hasher.update(read_buffer[0..count]);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    file_hasher.final(&digest);
    hasher.update(&digest);
}

fn hashLinkString(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hasher.update(value);
    hasher.update("\x00");
}

fn hashLinkStringSlice(hasher: *std.crypto.hash.sha2.Sha256, values: []const []const u8) void {
    for (values) |value| hashLinkString(hasher, value);
    hasher.update("\x01");
}

fn resolveCompilerRtBuiltinsArchive(
    allocator: std.mem.Allocator,
    resolved_tools: ResolvedDistributionTools,
    target: build_model.BuildTarget,
) !?[]const u8 {
    const normalized = try build_model.normalizedToolchainTarget(allocator, target.target);
    defer if (normalized) |value| allocator.free(value);
    const target_name = normalized orelse target.target orelse return null;
    const target_flag = try std.fmt.allocPrint(allocator, "--target={s}", .{target_name});
    defer allocator.free(target_flag);

    const result = compat.runProcess(allocator, .{
        .argv = &.{ resolved_tools.cc.path, target_flag, "-rtlib=compiler-rt", "-print-libgcc-file-name" },
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    const path = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (path.len == 0) return null;
    if (compat.openFileAbsolute(path, .{})) |file| {
        compat.closeFile(file);
        return @as(?[]const u8, try allocator.dupe(u8, path));
    } else |_| {}
    const relative_path = compilerRtBuiltinsRelativePath(path) orelse return null;
    const bundled_path = try bundledCompilerRtBuiltinsPath(allocator, resolved_tools.cc.path, relative_path);
    errdefer allocator.free(bundled_path);
    const bundled_file = compat.openFileAbsolute(bundled_path, .{}) catch return null;
    compat.closeFile(bundled_file);
    return bundled_path;
}

fn bundledCompilerRtBuiltinsPath(
    allocator: std.mem.Allocator,
    clang_path: []const u8,
    relative_path: []const u8,
) ![]const u8 {
    const bin_dir = std.fs.path.dirname(clang_path) orelse return error.InvalidPath;
    const root_dir = std.fs.path.dirname(bin_dir) orelse return error.InvalidPath;
    return std.fs.path.join(allocator, &.{ root_dir, relative_path });
}

fn compilerRtBuiltinsRelativePath(absolute_path: []const u8) ?[]const u8 {
    const marker = std.mem.indexOf(u8, absolute_path, "/lib/clang/") orelse return null;
    return absolute_path[marker + 1 ..];
}

fn archiveStaticLibrary(
    allocator: std.mem.Allocator,
    resolved_tools: ResolvedDistributionTools,
    output_path: []const u8,
    object_paths: []const []const u8,
    activity: bool,
) !void {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ resolved_tools.ar.path, "rcs", output_path });
    try argv.appendSlice(allocator, object_paths);
    if (activity) std.debug.print("archiving static library ({d} objects)...\n", .{object_paths.len});
    try runToolInherited(argv.items, if (activity) "static library archive" else null, false);
}

fn emitObjcopyArtifact(
    diagnostic_context: diagnostics.Context,
    allocator: std.mem.Allocator,
    resolved_tools: ResolvedDistributionTools,
    target: build_model.BuildTarget,
    input_path: []const u8,
    output_path: []const u8,
    format: []const u8,
    flag_name: []const u8,
) !void {
    try ensureParentDir(output_path);
    const objcopy = try toolchain.requireObjcopyWithDiagnostics(allocator, resolved_tools, target, flag_name, diagnostic_context);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ objcopy, "-O", format, input_path, output_path });
    try runTool(allocator, argv.items, error.NativeCompileFailed);
}

fn runTool(allocator: std.mem.Allocator, argv: []const []const u8, comptime failure: anyerror) !void {
    const result = try compat.runProcess(allocator, .{
        .argv = argv,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| {
            if (code == 0) return;
        },
        else => {},
    }
    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
    if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
    return failure;
}

fn runToolInherited(argv: []const []const u8, activity_label: ?[]const u8, verbose: bool) !void {
    if (verbose) printToolCommand(argv);
    var child = try std.process.spawn(compat.io(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(compat.io());
    var heartbeat: ToolHeartbeat = .{
        .label = activity_label orelse "",
        .started_ns = monotonicNowNs(),
    };
    var ticker: ?std.Thread = null;
    if (activity_label != null) {
        ticker = std.Thread.spawn(.{}, ToolHeartbeat.run, .{&heartbeat}) catch null;
    }
    const term = child.wait(compat.io()) catch |err| {
        if (ticker) |thread| {
            heartbeat.finish();
            thread.join();
        }
        return err;
    };
    if (ticker) |thread| {
        heartbeat.finish();
        thread.join();
    }
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.NativeCompileFailed;
}

fn freeOwnedPrefixedFlags(allocator: std.mem.Allocator, argv: []const []const u8, prefix: []const u8) void {
    for (argv) |arg| {
        if (std.mem.startsWith(u8, arg, prefix)) allocator.free(arg);
    }
}

fn freeOwnedLinkerFlags(allocator: std.mem.Allocator, argv: []const []const u8) void {
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const is_isysroot = std.mem.eql(u8, arg, "-isysroot");
        if (std.mem.startsWith(u8, arg, "--target=") or
            std.mem.startsWith(u8, arg, "-mcpu=") or
            std.mem.startsWith(u8, arg, "-mcmodel=") or
            std.mem.startsWith(u8, arg, "-I") or
            is_isysroot or
            std.mem.eql(u8, arg, "-ffreestanding") or
            std.mem.eql(u8, arg, "-mgeneral-regs-only") or
            std.mem.eql(u8, arg, "-nostdlib") or
            std.mem.startsWith(u8, arg, "-fuse-ld=") or
            std.mem.startsWith(u8, arg, "-Wl,") or
            std.mem.startsWith(u8, arg, "-L") or
            std.mem.startsWith(u8, arg, "-l"))
        {
            allocator.free(arg);
            if (is_isysroot and i + 1 < argv.len) {
                allocator.free(argv[i + 1]);
                i += 1;
            }
        }
    }
}

fn copyFile(from_path: []const u8, to_path: []const u8) !void {
    try ensureParentDir(to_path);
    var src = try compat.openFile(from_path, .{});
    defer compat.closeFile(src);
    var dst = try compat.createFile(to_path, .{ .truncate = true });
    defer compat.closeFile(dst);
    const src_stat = try src.stat(compat.io());
    const limit: usize = if (src_stat.size == std.math.maxInt(usize)) @intCast(src_stat.size) else @intCast(src_stat.size + 1);
    const bytes = try compat.readFileAlloc(std.heap.page_allocator, from_path, limit);
    defer std.heap.page_allocator.free(bytes);
    try compat.fileWriteAll(dst, bytes);
    try dst.setPermissions(compat.io(), src_stat.permissions);
}

fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try compat.makePath(parent);
}

test "link input tree identity follows SDK stubs and new shadowing libraries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "usr/lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "usr/lib/libSystem.tbd", .data = "stub-a" });
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    var before = std.crypto.hash.sha2.Sha256.init(.{});
    try hashLinkInputTree(allocator, &before, root);
    var original: [32]u8 = undefined;
    before.final(&original);
    for ([_]bool{ false, true }) |new_library| {
        const relative = if (new_library) "usr/lib/libShadow.a" else "usr/lib/libSystem.tbd";
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = relative, .data = "changed" });
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        try hashLinkInputTree(allocator, &hasher, root);
        var changed: [32]u8 = undefined;
        hasher.final(&changed);
        try std.testing.expect(!std.mem.eql(u8, &original, &changed));
        if (!new_library) try compat.dirWriteFile(tmp.dir, .{ .sub_path = relative, .data = "stub-a" });
    }
}

test "link file identity streams content across read chunks" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "library.a" });
    defer allocator.free(path);
    const bytes = try allocator.alloc(u8, 130 * 1024 + 7);
    defer allocator.free(bytes);
    for (bytes, 0..) |*byte, index| byte.* = @truncate(index);
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "library.a", .data = bytes });
    var actual = std.crypto.hash.sha2.Sha256.init(.{});
    try hashLinkFile(&actual, allocator, path);
    var actual_digest: [32]u8 = undefined;
    actual.final(&actual_digest);
    var file_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &file_digest, .{});
    var expected = std.crypto.hash.sha2.Sha256.init(.{});
    expected.update(&file_digest);
    var expected_digest: [32]u8 = undefined;
    expected.final(&expected_digest);
    try std.testing.expectEqualSlices(u8, &expected_digest, &actual_digest);
}

test "native object source identity streams content across read chunks" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "module.ll" });
    defer allocator.free(path);
    const bytes = try allocator.alloc(u8, 130 * 1024 + 7);
    defer allocator.free(bytes);
    for (bytes, 0..) |*byte, index| byte.* = @truncate(index);
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "module.ll", .data = bytes });
    var actual = std.crypto.hash.sha2.Sha256.init(.{});
    try hashFileInto(&actual, path);
    var actual_digest: [32]u8 = undefined;
    actual.final(&actual_digest);
    var expected_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &expected_digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_digest, &actual_digest);
}

test "Linux implicit link search inventory follows driver and linker roots" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "driver");
    try compat.dirMakePath(tmp.dir, "linker");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "driver/libdriver.a", .data = "driver-a" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "linker/libsystem.so", .data = "system-a" });
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    const driver_path = try std.fs.path.join(allocator, &.{ root, "driver" });
    defer allocator.free(driver_path);
    const linker_path = try std.fs.path.join(allocator, &.{ root, "linker" });
    defer allocator.free(linker_path);
    const driver_output = try std.fmt.allocPrint(allocator, "programs: =/usr/bin\nlibraries: ={s}\n", .{driver_path});
    defer allocator.free(driver_output);
    const linker_output = try std.fmt.allocPrint(allocator, "SEARCH_DIR(\"{s}\");\n", .{linker_path});
    defer allocator.free(linker_output);
    var original = std.crypto.hash.sha2.Sha256.init(.{});
    try std.testing.expect(try hashClangLibrarySearchDirs(allocator, &original, driver_output));
    try std.testing.expect(try hashLinkerScriptSearchDirs(allocator, &original, linker_output));
    var original_digest: [32]u8 = undefined;
    original.final(&original_digest);
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "linker/libsystem.so", .data = "system-b" });
    var changed = std.crypto.hash.sha2.Sha256.init(.{});
    try std.testing.expect(try hashClangLibrarySearchDirs(allocator, &changed, driver_output));
    try std.testing.expect(try hashLinkerScriptSearchDirs(allocator, &changed, linker_output));
    var changed_digest: [32]u8 = undefined;
    changed.final(&changed_digest);
    try std.testing.expect(!std.mem.eql(u8, &original_digest, &changed_digest));
    var missing = std.crypto.hash.sha2.Sha256.init(.{});
    try std.testing.expect(!(try hashClangLibrarySearchDirs(allocator, &missing, "programs: =/usr/bin\n")));
    try std.testing.expect(!(try hashLinkerScriptSearchDirs(allocator, &missing, "GNU ld compatible\n")));
    try std.testing.expect(!(try hashLinkerScriptSearchDirs(allocator, &missing, "SEARCH_DIR(\"=/lib\");\n")));
    try std.testing.expect(!(try hashLinkerScriptSearchDirs(allocator, &missing, "SEARCH_DIR(\"$SYSROOT/usr/lib\");\n")));
    var unsupported = std.crypto.hash.sha2.Sha256.init(.{});
    const cross_target: build_model.BuildTarget = .{
        .is_project = false,
        .display_path = "probe",
        .root_dir = root,
        .source_path = "probe.cy",
        .name = "probe",
        .target = "x86_64-linux-gnu",
    };
    try std.testing.expect(!(try hashLinuxImplicitLinkInputs(allocator, &unsupported, "missing-compiler", "missing-linker", cross_target)));
}

test "Linux implicit link inventory queries tools and bypasses unsupported output" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "libraries");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "libraries/libsystem.so", .data = "first" });
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    const libraries = try std.fs.path.join(allocator, &.{ root, "libraries" });
    defer allocator.free(libraries);
    const driver = try std.fs.path.join(allocator, &.{ root, "driver" });
    defer allocator.free(driver);
    const linker = try std.fs.path.join(allocator, &.{ root, "linker" });
    defer allocator.free(linker);
    const driver_script = try std.fmt.allocPrint(allocator, "#!/bin/sh\nprintf 'libraries: ={s}\\n'\n", .{libraries});
    defer allocator.free(driver_script);
    const linker_script = try std.fmt.allocPrint(allocator, "#!/bin/sh\nprintf 'SEARCH_DIR(\"{s}\");\\n'\n", .{libraries});
    defer allocator.free(linker_script);
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "driver", .data = driver_script });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "linker", .data = linker_script });
    if (@import("builtin").os.tag != .windows) {
        for ([_][]const u8{ driver, linker }) |path| {
            var file = try compat.openFileAbsolute(path, .{});
            defer compat.closeFile(file);
            try file.setPermissions(compat.io(), std.Io.File.Permissions.fromMode(0o755));
        }
    }
    const target: build_model.BuildTarget = .{
        .is_project = false,
        .display_path = "probe",
        .root_dir = root,
        .source_path = "probe.cy",
        .name = "probe",
    };
    var before = std.crypto.hash.sha2.Sha256.init(.{});
    try std.testing.expect(try hashLinuxImplicitLinkInputs(allocator, &before, driver, linker, target));
    var before_digest: [32]u8 = undefined;
    before.final(&before_digest);
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "libraries/libsystem.so", .data = "second" });
    var after = std.crypto.hash.sha2.Sha256.init(.{});
    try std.testing.expect(try hashLinuxImplicitLinkInputs(allocator, &after, driver, linker, target));
    var after_digest: [32]u8 = undefined;
    after.final(&after_digest);
    try std.testing.expect(!std.mem.eql(u8, &before_digest, &after_digest));
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "linker", .data = "#!/bin/sh\nprintf 'unsupported\\n'\n" });
    var unsupported = std.crypto.hash.sha2.Sha256.init(.{});
    try std.testing.expect(!(try hashLinuxImplicitLinkInputs(allocator, &unsupported, driver, linker, target)));
}

test "library search environment identity tracks missing roots and versioned libraries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    const libraries = try std.fs.path.join(allocator, &.{ root, "libraries" });
    defer allocator.free(libraries);
    var initial = std.crypto.hash.sha2.Sha256.init(.{});
    try hashLibrarySearchEnvironment(allocator, &initial, libraries);
    var missing: [32]u8 = undefined;
    initial.final(&missing);
    try compat.dirMakePath(tmp.dir, "libraries");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "libraries/libexample.so.1", .data = "library-a" });
    var first = std.crypto.hash.sha2.Sha256.init(.{});
    try hashLibrarySearchEnvironment(allocator, &first, libraries);
    var present: [32]u8 = undefined;
    first.final(&present);
    try std.testing.expect(!std.mem.eql(u8, &missing, &present));
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "libraries/libexample.so.1", .data = "library-b" });
    var second = std.crypto.hash.sha2.Sha256.init(.{});
    try hashLibrarySearchEnvironment(allocator, &second, libraries);
    var changed: [32]u8 = undefined;
    second.final(&changed);
    try std.testing.expect(!std.mem.eql(u8, &present, &changed));
}

test "link tree identity records dangling library becoming available" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    const link = try std.fs.path.join(allocator, &.{ root, "libexample.so.1" });
    defer allocator.free(link);
    try compat.symLink("available", link, .{});
    var before = std.crypto.hash.sha2.Sha256.init(.{});
    try hashLinkInputTree(allocator, &before, root);
    var missing: [32]u8 = undefined;
    before.final(&missing);
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "available", .data = "library" });
    var after = std.crypto.hash.sha2.Sha256.init(.{});
    try hashLinkInputTree(allocator, &after, root);
    var present: [32]u8 = undefined;
    after.final(&present);
    try std.testing.expect(!std.mem.eql(u8, &missing, &present));
}

test "compiler repo relative path resolves from executable location" {
    const path = try compilerRepoRelativePathFromExe(
        std.testing.allocator,
        "/tmp/cyna/zig-out/bin/cyna",
        "src/runtime/runtime.c",
    );
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/tmp/cyna/src/runtime/runtime.c", path);
}

test "multi-module native compilation validates module set shape" {
    const target = build_model.BuildTarget{
        .is_project = false,
        .display_path = "multi.cy",
        .root_dir = ".",
        .source_path = "multi.cy",
        .name = "multi",
    };
    try std.testing.expectError(
        error.InvalidNativeModuleSet,
        compileNativeArtifacts(std.testing.allocator, &.{}, .{}, target, false, true, "multi", "multi.native", .{}),
    );
    try std.testing.expectError(
        error.InvalidNativeModuleSet,
        compileNativeArtifacts(std.testing.allocator, &.{ "one", "two" }, .{}, target, true, false, "multi", "multi.native", .{}),
    );
}

test "validate archive path rejects malformed archive files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "libbad.a",
        .data = "not an archive",
    });

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);

    const archive_path = try std.fs.path.join(std.testing.allocator, &.{ root, "libbad.a" });
    defer std.testing.allocator.free(archive_path);

    try std.testing.expect(!(try validateArchiveAtPath(std.testing.allocator, archive_path)));
}

test "checkout archive freshness rejects newer runtime source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "runtime.c", .data = "void runtime(void) {}" });
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "runtime.c" });
    defer std.testing.allocator.free(path);
    var file = try compat.openFile(path, .{});
    defer compat.closeFile(file);
    const mtime = (try file.stat(compat.io())).mtime.nanoseconds;
    try std.testing.expect(try archiveIsAtLeastAsNewAsSource(mtime, path));
    try std.testing.expect(!(try archiveIsAtLeastAsNewAsSource(mtime - 1, path)));
}

test "parse staticlib link metadata" {
    const metadata = try parseStaticLibraryLinkMetadata(std.testing.allocator,
        \\version = 2
        \\dependencies = ["runtime", "std"]
    );
    defer std.testing.allocator.free(metadata.dependencies);
    try std.testing.expectEqual(@as(u32, 2), metadata.version);
    try std.testing.expectEqual(@as(usize, 2), metadata.dependencies.len);
    try std.testing.expectEqual(StaticLibraryDependency.runtime, metadata.dependencies[0]);
    try std.testing.expectEqual(StaticLibraryDependency.std, metadata.dependencies[1]);
}

test "resolve staticlib metadata from search path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "libdemo.a.cyna-link.toml",
        .data =
        \\version = 2
        \\dependencies = ["runtime", "std"]
        ,
    });

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);

    const metadata = (try resolveStaticLibraryMetadataForLib(std.testing.allocator, &.{root}, "demo")).?;
    defer std.testing.allocator.free(metadata.dependencies);
    try std.testing.expectEqual(@as(usize, 2), metadata.dependencies.len);
}

test "append target flags adds freestanding toolchain options" {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);

    var target = build_model.BuildTarget{
        .is_project = false,
        .display_path = try std.testing.allocator.dupe(u8, "/tmp/app.cy"),
        .root_dir = try std.testing.allocator.dupe(u8, "/tmp"),
        .source_path = try std.testing.allocator.dupe(u8, "/tmp/app.cy"),
        .name = try std.testing.allocator.dupe(u8, "app"),
        .target = try std.testing.allocator.dupe(u8, "thumbv7em-none-eabi"),
        .cpu = try std.testing.allocator.dupe(u8, "cortex-m4"),
    };
    defer target.deinit(std.testing.allocator);

    try appendTargetFlags(std.testing.allocator, &argv, target, false);
    defer {
        freeOwnedCompileFlags(std.testing.allocator, argv.items);
    }

    try std.testing.expectEqual(@as(usize, 3), argv.items.len);
    try std.testing.expectEqualStrings("--target=thumbv7em-none-eabi", argv.items[0]);
    try std.testing.expectEqualStrings("-mcpu=cortex-m4", argv.items[1]);
    try std.testing.expectEqualStrings("-ffreestanding", argv.items[2]);
}

test "append target flags skips empty cpu strings" {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);

    var target = build_model.BuildTarget{
        .is_project = false,
        .display_path = try std.testing.allocator.dupe(u8, "/tmp/app.cy"),
        .root_dir = try std.testing.allocator.dupe(u8, "/tmp"),
        .source_path = try std.testing.allocator.dupe(u8, "/tmp/app.cy"),
        .name = try std.testing.allocator.dupe(u8, "app"),
        .target = try std.testing.allocator.dupe(u8, "riscv64-none-elf"),
        .cpu = try std.testing.allocator.dupe(u8, ""),
    };
    defer target.deinit(std.testing.allocator);

    try appendTargetFlags(std.testing.allocator, &argv, target, false);
    defer {
        freeOwnedCompileFlags(std.testing.allocator, argv.items);
    }

    try std.testing.expectEqual(@as(usize, 3), argv.items.len);
    try std.testing.expectEqualStrings("--target=riscv64-none-elf", argv.items[0]);
    try std.testing.expectEqualStrings("-ffreestanding", argv.items[1]);
    try std.testing.expectEqualStrings("-mcmodel=medany", argv.items[2]);
}

test "append target flags applies the generic ARM atomic baseline" {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);

    var target = build_model.BuildTarget{
        .is_project = false,
        .display_path = try std.testing.allocator.dupe(u8, "/tmp/app.cy"),
        .root_dir = try std.testing.allocator.dupe(u8, "/tmp"),
        .source_path = try std.testing.allocator.dupe(u8, "/tmp/app.cy"),
        .name = try std.testing.allocator.dupe(u8, "app"),
        .target = try std.testing.allocator.dupe(u8, "arm-none-eabi"),
    };
    defer target.deinit(std.testing.allocator);

    try appendTargetFlags(std.testing.allocator, &argv, target, false);
    defer {
        freeOwnedCompileFlags(std.testing.allocator, argv.items);
    }

    try std.testing.expectEqual(@as(usize, 3), argv.items.len);
    try std.testing.expectEqualStrings("--target=arm-none-eabi", argv.items[0]);
    try std.testing.expectEqualStrings("-mcpu=arm1176jzf-s", argv.items[1]);
    try std.testing.expectEqualStrings("-ffreestanding", argv.items[2]);
}

test "append target flags disables AArch64 freestanding SIMD register allocation" {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);

    var target = build_model.BuildTarget{
        .is_project = false,
        .display_path = try std.testing.allocator.dupe(u8, "/tmp/app.cy"),
        .root_dir = try std.testing.allocator.dupe(u8, "/tmp"),
        .source_path = try std.testing.allocator.dupe(u8, "/tmp/app.cy"),
        .name = try std.testing.allocator.dupe(u8, "app"),
        .target = try std.testing.allocator.dupe(u8, "aarch64-none-elf"),
    };
    defer target.deinit(std.testing.allocator);

    try appendTargetFlags(std.testing.allocator, &argv, target, false);
    defer {
        freeOwnedCompileFlags(std.testing.allocator, argv.items);
    }

    try std.testing.expectEqual(@as(usize, 3), argv.items.len);
    try std.testing.expectEqualStrings("--target=aarch64-none-elf", argv.items[0]);
    try std.testing.expectEqualStrings("-ffreestanding", argv.items[1]);
    try std.testing.expectEqualStrings("-mgeneral-regs-only", argv.items[2]);
}

const std = @import("std");
const compilation = @import("../compiler/session.zig");
const build_pkg = @import("../build.zig");
const diagnostics = @import("../compiler/diagnostics.zig");
const internal_error = @import("../compiler/internal_error.zig");
const loader = @import("../compiler/loader.zig");
const lower = @import("../compiler/lower/lower.zig");
const lir = @import("../compiler/lower/lir.zig");
const sir = @import("../compiler/sema/sir.zig");

const llvm_backend = @import("../compiler/backend/llvm.zig");
const build_model = build_pkg.model;
const module_cache = build_pkg.module_cache;
const modules = build_pkg.modules;
const native = build_pkg.native;

pub const Options = struct {
    verbose: bool = false,
    progress: bool = false,
    jobs: usize = 0,
    diagnostic_context: diagnostics.Context = .{ .destination = .discard },
    cache_emit: ?build_model.EmitOptions = null,
    session: ?*compilation.CompilationSession = null,
};

fn startTiming(options: Options, name: []const u8) compilation.Scope {
    const session = options.session orelse return .{};
    return session.start(name, &.{});
}

pub fn buildNativeModules(
    allocator: std.mem.Allocator,
    loaded: loader.LoadedProgram,
    semantic_module: sir.Module,
    target: build_model.BuildTarget,
    artifact_base_path: []const u8,
    output_path: []const u8,
    options: Options,
) !bool {
    var artifacts = blk: {
        var span = startTiming(options, "modules.prepare");
        defer span.end();
        break :blk try collectModuleArtifacts(allocator, loaded, semantic_module, target, options);
    };
    defer artifacts.deinit(allocator);
    // The current graph and semantic checks must precede whole-build reuse.
    // C and bundled runtime dependencies need header tracking before admission.
    var cacheable = options.cache_emit != null and !artifacts.artifact_deps.any() and
        !target.leak_check and !build_model.isFreestandingTarget(target.target) and
        target.c_sources.sources.len == 0 and target.dependency_c_sources.len == 0 and
        target.asm_sources.sources.len == 0 and
        target.link.libs.len == 0 and target.link.search_paths.len == 0;
    var plan = try modules.Plan.init(allocator, loaded);
    defer plan.deinit();
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    plan.updateHash(&hasher);
    if (cacheable) {
        var tools = try @import("../build/toolchain.zig").resolveDistributionToolsWithDiagnostics(allocator, target, options.diagnostic_context);
        defer tools.deinit(allocator);
        hasher.update(&tools.cache_identity);
        cacheable = try native.updateHostedLinkCacheIdentity(allocator, &hasher, tools, target);
    }
    var graph_hash: [32]u8 = undefined;
    hasher.final(&graph_hash);
    const cache_hit = blk: {
        var span = startTiming(options, "build_cache.lookup");
        defer span.end();
        break :blk cacheable and try build_pkg.build_cache.restore(allocator, target, output_path, artifact_base_path, options.cache_emit.?, &graph_hash);
    };
    if (cache_hit) {
        reportProgress(options.verbose, "reusing cached native build\n", .{});
        return true;
    }
    var module_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer module_names.deinit(allocator);
    for (plan.modules) |module| try module_names.append(allocator, module.name);
    const wrote = blk: {
        var span = startTiming(options, "native.artifacts");
        defer span.end();
        break :blk try native.compileNativeArtifacts(
            allocator,
            artifacts.llvm_modules.items,
            artifacts.artifact_deps,
            target,
            false,
            true,
            artifact_base_path,
            output_path,
            .{
                .verbose = options.verbose,
                .progress = options.progress,
                .jobs = options.jobs,
                .diagnostic_context = options.diagnostic_context,
                .session = options.session,
                .llvm_module_names = module_names.items,
            },
        );
    };
    if (wrote and cacheable) try build_pkg.build_cache.store(allocator, target, output_path, artifact_base_path, options.cache_emit.?, loaded.source_paths, &graph_hash);
    return wrote;
}

const ModuleArtifacts = struct {
    llvm_modules: std.ArrayListUnmanaged([]const u8),
    artifact_deps: llvm_backend.ArtifactDeps,

    fn deinit(self: *ModuleArtifacts, allocator: std.mem.Allocator) void {
        for (self.llvm_modules.items) |llvm_ir| allocator.free(llvm_ir);
        self.llvm_modules.deinit(allocator);
        self.* = undefined;
    }
};

const FailureStage = enum { lower, emit, cache };

const ModuleFailure = struct {
    err: anyerror,
    stage: FailureStage,
};

const ModuleResult = struct {
    llvm_ir: ?[]const u8 = null,
    artifact_deps: llvm_backend.ArtifactDeps = .{},
    failure: ?ModuleFailure = null,
};

const ModuleWorkerContext = struct {
    allocator: std.mem.Allocator,
    semantic_module: sir.Module,
    target: build_model.BuildTarget,
    plan: *const modules.Plan,
    debug_source_map: []const lower.DebugSourceMapEntry,
    module_indices: []const usize,
    results: []ModuleResult,
    next_index: std.atomic.Value(usize),
};

fn collectModuleArtifacts(
    allocator: std.mem.Allocator,
    loaded: loader.LoadedProgram,
    semantic_module: sir.Module,
    target: build_model.BuildTarget,
    options: Options,
) !ModuleArtifacts {
    var plan = try modules.Plan.init(allocator, loaded);
    defer plan.deinit();

    const debug_source_map = try buildDebugSourceMap(allocator, plan);
    defer allocator.free(debug_source_map);

    const results = try allocator.alloc(ModuleResult, plan.modules.len);
    defer allocator.free(results);
    errdefer freeModuleResults(allocator, results);
    @memset(results, .{});

    var misses: std.ArrayListUnmanaged(usize) = .empty;
    defer misses.deinit(allocator);
    var cache_hits: usize = 0;

    {
        var lookup_span = startTiming(options, "modules.cache_lookup");
        defer lookup_span.end();
        for (plan.modules, 0..) |module, module_index| {
            if (try module_cache.load(allocator, target, plan, module_index)) |cached_value| {
                var cached = cached_value;
                results[module_index] = .{
                    .llvm_ir = cached.llvm_ir,
                    .artifact_deps = cached.artifact_deps,
                };
                cached.llvm_ir = &.{};
                cached.deinit(allocator);
                cache_hits += 1;
                reportProgress(options.verbose, "reusing cached module {s}\n", .{module.name});
                continue;
            }
            try misses.append(allocator, module_index);
            reportProgress(options.verbose, "lowering module {s}\n", .{module.name});
        }
    }

    var worker_context = ModuleWorkerContext{
        .allocator = allocator,
        .semantic_module = semantic_module,
        .target = target,
        .plan = &plan,
        .debug_source_map = debug_source_map,
        .module_indices = misses.items,
        .results = results,
        .next_index = .init(0),
    };
    const worker_count = moduleWorkerCount(options.jobs, misses.items.len);
    {
        var worker_span = startTiming(options, "modules.compile_misses");
        defer worker_span.end();
        if (worker_count == 1) {
            compileModuleWorker(&worker_context);
        } else if (worker_count > 1) {
            const workers = try allocator.alloc(std.Thread, worker_count);
            defer allocator.free(workers);
            var spawned: usize = 0;
            errdefer {
                for (workers[0..spawned]) |worker| worker.join();
            }
            while (spawned < worker_count) : (spawned += 1) {
                workers[spawned] = try std.Thread.spawn(.{}, compileModuleWorker, .{&worker_context});
            }
            for (workers) |worker| worker.join();
        }
    }

    var llvm_modules: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (llvm_modules.items) |llvm_ir| allocator.free(llvm_ir);
        llvm_modules.deinit(allocator);
    }
    var artifact_deps: llvm_backend.ArtifactDeps = .{};

    for (0..plan.modules.len) |module_index| {
        const result = results[module_index];
        if (result.failure) |failure| {
            if (failure.stage != .lower or
                !try internal_error.emitSirIdentityFailure(options.diagnostic_context, semantic_module, debug_source_map, plan.modules[module_index].source_path, failure.err))
            {
                try emitModuleFailure(options, plan.modules[module_index].source_path, failure);
            }
            return failure.err;
        }
        const llvm_ir = result.llvm_ir orelse return error.ModuleCompilationFailed;
        try llvm_modules.append(allocator, llvm_ir);
        results[module_index].llvm_ir = null;
        artifact_deps.runtime = artifact_deps.runtime or result.artifact_deps.runtime;
        artifact_deps.std = artifact_deps.std or result.artifact_deps.std;
    }

    if (options.session) |session| session.setModuleCache(cache_hits, misses.items.len, worker_count);
    reportProgress(options.verbose, "module cache: {d} hit, {d} miss, {d} workers\n", .{
        cache_hits,
        misses.items.len,
        worker_count,
    });
    return .{
        .llvm_modules = llvm_modules,
        .artifact_deps = artifact_deps,
    };
}

fn compileModuleWorker(context: *ModuleWorkerContext) void {
    while (true) {
        const job_index = context.next_index.fetchAdd(1, .monotonic);
        if (job_index >= context.module_indices.len) return;
        const module_index = context.module_indices[job_index];
        context.results[module_index] = compileModule(context, module_index);
    }
}

fn compileModule(context: *ModuleWorkerContext, module_index: usize) ModuleResult {
    const module = context.plan.modules[module_index];
    var lir_module = lower.lowerModuleWithOptions(context.allocator, context.semantic_module, .{
        .debug_source_map = context.debug_source_map,
        .fallback_source_path = context.target.source_path,
        .target = context.target.target,
        .module_name = module.name,
    }) catch |err| return .{ .failure = .{ .err = err, .stage = .lower } };
    defer lir_module.deinit(context.allocator);

    const module_deps = llvm_backend.moduleArtifactDepsForObject(context.allocator, lir_module);
    const llvm_ir = llvm_backend.emitModuleWithOptions(context.allocator, lir_module, .{
        .emit_all_functions = true,
        .partitioned = true,
        .coff_comdat = if (context.target.target) |target_name|
            std.mem.indexOf(u8, target_name, "windows") != null or
                (std.mem.eql(u8, target_name, "native") and @import("builtin").os.tag == .windows)
        else
            @import("builtin").os.tag == .windows,
    }) catch |err| {
        return .{ .failure = .{ .err = err, .stage = .emit } };
    };
    module_cache.store(context.allocator, context.target, context.plan.*, module_index, llvm_ir, module_deps) catch |err| {
        context.allocator.free(llvm_ir);
        return .{ .failure = .{ .err = err, .stage = .cache } };
    };
    return .{ .llvm_ir = llvm_ir, .artifact_deps = module_deps };
}

fn moduleWorkerCount(requested: usize, job_count: usize) usize {
    if (job_count == 0) return 0;
    if (requested != 0) return @min(requested, job_count);
    return @min(@min(std.Thread.getCpuCount() catch 1, 8), job_count);
}

fn freeModuleResults(allocator: std.mem.Allocator, results: []ModuleResult) void {
    for (results) |*result| {
        if (result.llvm_ir) |llvm_ir| allocator.free(llvm_ir);
        result.llvm_ir = null;
    }
}

fn emitModuleFailure(options: Options, diagnostic_path: []const u8, failure: ModuleFailure) !void {
    switch (failure.stage) {
        .lower => try internal_error.emitFailure(options.diagnostic_context, diagnostic_path, .sir_to_lir, failure.err),
        .emit => try internal_error.emitFailure(options.diagnostic_context, diagnostic_path, .lir_to_llvm, failure.err),
        .cache => {
            var buffer: [256]u8 = undefined;
            const message = try std.fmt.bufPrint(&buffer, "module cache publication failed: {s}", .{@errorName(failure.err)});
            try options.diagnostic_context.emitPath(diagnostic_path, message);
        },
    }
}

test "module worker failures preserve source and diagnostic allocation errors" {
    var sink = diagnostics.Sink.init(std.testing.allocator);
    defer sink.deinit();
    const options: Options = .{ .diagnostic_context = diagnostics.Context.structured(&sink) };
    for ([_]FailureStage{ .lower, .emit, .cache }) |stage| {
        try emitModuleFailure(options, "dependency/worker.cy", .{ .err = error.InvalidSir, .stage = stage });
    }
    try std.testing.expectEqual(@as(usize, 3), sink.records.items.len);
    for (sink.records.items) |diagnostic| {
        try std.testing.expectEqualStrings("dependency/worker.cy", diagnostic.path);
    }
    try std.testing.expectEqual(diagnostics.DiagnosticCode.internal_invariant, sink.records.items[0].code);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.internal_invariant, sink.records.items[1].code);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.legacy_unclassified, sink.records.items[2].code);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var failing_sink = diagnostics.Sink.init(failing.allocator());
    defer failing_sink.deinit();
    try std.testing.expectError(error.OutOfMemory, emitModuleFailure(
        .{ .diagnostic_context = diagnostics.Context.structured(&failing_sink) },
        "dependency/worker.cy",
        .{ .err = error.InvalidSir, .stage = .lower },
    ));
}

test "module worker allocation failure reaches a structured dependency diagnostic" {
    const compat = @import("../compat.zig");
    const sema = @import("../compiler/sema/sema.zig");
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = "import .dependency; fn main(): i32 { return dependency.answer(); }" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "dependency.cy", .data = "pub fn answer(): i32 { return 42; }" });
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "main.cy" });
    defer allocator.free(path);
    var loaded = try loader.loadProgram(allocator, path);
    defer loaded.deinit(allocator);
    const semantic_module = try sema.buildSir(allocator, path, loaded.program);
    defer semantic_module.deinit(allocator);
    var plan = try modules.Plan.init(allocator, loaded);
    defer plan.deinit();
    const debug_map = try buildDebugSourceMap(allocator, plan);
    defer allocator.free(debug_map);
    const index = for (plan.modules, 0..) |module, index| {
        if (std.mem.endsWith(u8, module.source_path, "/dependency.cy")) break index;
    } else return error.MissingDependencyFixture;
    const results = try allocator.alloc(ModuleResult, plan.modules.len);
    defer allocator.free(results);
    @memset(results, .{});
    defer freeModuleResults(allocator, results);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var target = build_model.BuildTarget{
        .is_project = false,
        .display_path = try allocator.dupe(u8, path),
        .root_dir = try allocator.dupe(u8, root),
        .source_path = try allocator.dupe(u8, path),
        .name = try allocator.dupe(u8, "main"),
    };
    defer target.deinit(allocator);
    var worker = ModuleWorkerContext{
        .allocator = failing.allocator(),
        .semantic_module = semantic_module,
        .target = target,
        .plan = &plan,
        .debug_source_map = debug_map,
        .module_indices = &.{index},
        .results = results,
        .next_index = .init(0),
    };
    compileModuleWorker(&worker);
    const failure = results[index].failure orelse return error.ExpectedWorkerFailure;
    try std.testing.expectEqual(error.OutOfMemory, failure.err);
    var sink = diagnostics.Sink.init(allocator);
    defer sink.deinit();
    try emitModuleFailure(.{ .diagnostic_context = diagnostics.Context.structured(&sink) }, plan.modules[index].source_path, failure);
    try std.testing.expectEqual(@as(usize, 1), sink.records.items.len);
    try std.testing.expectEqualStrings(plan.modules[index].source_path, sink.records.items[0].path);
    try std.testing.expectEqualStrings("OutOfMemory", sink.records.items[0].message);
}

fn reportProgress(verbose: bool, comptime format: []const u8, args: anytype) void {
    if (verbose) std.debug.print(format, args);
}

fn buildDebugSourceMap(allocator: std.mem.Allocator, plan: modules.Plan) ![]lower.DebugSourceMapEntry {
    const map = try allocator.alloc(lower.DebugSourceMapEntry, plan.modules.len);
    for (map, plan.modules) |*entry, module| {
        entry.* = .{ .module_name = module.name, .source_path = module.source_path };
    }
    return map;
}

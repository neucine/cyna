const std = @import("std");
const build_pkg = @import("../build.zig");
const install = @import("install.zig");
const llvm_backend = @import("../compiler/backend/llvm.zig");
const internal_error = @import("../compiler/internal_error.zig");
const diagnostics = @import("../compiler/diagnostics.zig");
const loader = @import("../compiler/loader.zig");
const lower = @import("../compiler/lower/lower.zig");
const lir = @import("../compiler/lower/lir.zig");
const sema = @import("../compiler/sema/sema.zig");
const sir = @import("../compiler/sema/sir.zig");
const compilation = @import("../compiler/session.zig");
const build_model = build_pkg.model;

const ArtifactDeps = llvm_backend.ArtifactDeps;

pub const TestOptions = struct {
    diagnostic_context: diagnostics.Context = .{ .destination = .discard },
    filter: ?[]const u8 = null,
    jobs: usize = 0,
    timings: bool = false,
};

pub const Callbacks = struct {
    compileAndRunInlineTests: *const fn (
        allocator: std.mem.Allocator,
        llvm_ir: []const u8,
        artifact_deps: ArtifactDeps,
        target: build_model.BuildTarget,
        function_names: []const []const u8,
        results: []?anyerror,
        durations_ns: []u64,
        diagnostic_context: diagnostics.Context,
    ) anyerror!void,
    stripRootMainFunction: *const fn (
        allocator: std.mem.Allocator,
        module: *lir.Module,
        root_module_name: []const u8,
    ) anyerror!void,
};

const TestExecutionSummary = struct {
    matched: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
};

const TestFailure = struct {
    source_path: []u8,
    name: []u8,
    error_name: []u8,

    fn deinit(self: TestFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.source_path);
        allocator.free(self.name);
        allocator.free(self.error_name);
    }
};

const MatchedInlineTest = struct {
    source_path: []const u8,
    name: []const u8,
    function_name: []const u8,
};

const RootOutcome = struct {
    summary: TestExecutionSummary = .{},
    failures: std.ArrayListUnmanaged(TestFailure) = .empty,
    root_error: ?anyerror = null,

    fn deinit(self: *RootOutcome, allocator: std.mem.Allocator) void {
        for (self.failures.items) |failure| failure.deinit(allocator);
        self.failures.deinit(allocator);
    }
};

const RootWorkerContext = struct {
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    files: []const []const u8,
    filter_source_root: []const u8,
    filter: ?[]const u8,
    callbacks: Callbacks,
    next_index: std.atomic.Value(usize),
    outcomes: []RootOutcome,
    session: *compilation.CompilationSession,
    diagnostic_context: diagnostics.Context,
};

pub fn testCommand(allocator: std.mem.Allocator, input_path: ?[]const u8, options: TestOptions, callbacks: Callbacks) !void {
    var diagnostic_context = options.diagnostic_context;
    var session = try compilation.CompilationSession.init(allocator, options.timings);
    defer session.deinit();
    defer session.report() catch {};

    try install.ensureInstalledWithDiagnostics(allocator, input_path, diagnostic_context);

    var target = try build_model.resolveBuildTargetForConfigWithDiagnostics(allocator, input_path, null, &diagnostic_context);
    defer target.deinit(allocator);

    var discovered = try build_model.discoverTestFilesWithDiagnostics(allocator, target, &diagnostic_context);
    defer discovered.deinit(allocator);

    if (target.target) |build_target| {
        if (!std.mem.eql(u8, build_target, "native")) {
            try diagnostic_context.emitPath(target.display_path, "cyna test only supports native targets");
            return error.UnsupportedRunTarget;
        }
    }

    std.debug.print("package entry: {s}\n", .{target.source_path});
    std.debug.print("test dir: {s}\n", .{discovered.dir_path});
    if (options.filter) |filter| {
        std.debug.print("filter: {s}\n", .{filter});
    }
    std.debug.print("test root files discovered: {d}\n", .{discovered.files.len});
    for (discovered.files) |file| {
        std.debug.print("  {s}\n", .{file});
    }

    var test_summary: TestExecutionSummary = .{};
    const outcomes = try allocator.alloc(RootOutcome, discovered.files.len);
    defer allocator.free(outcomes);
    for (outcomes) |*outcome| outcome.* = .{};
    defer for (outcomes) |*outcome| outcome.deinit(allocator);

    // Keep the default deterministic until the root-parallel path has coverage
    // across every compiler backend and diagnostic mode. Users can opt in now,
    // and the default can become CPU-count based without changing the scheduler.
    const requested_jobs = if (options.jobs != 0) options.jobs else 1;
    const worker_count = @min(@max(requested_jobs, 1), @max(discovered.files.len, 1));
    var worker_context = RootWorkerContext{
        .allocator = allocator,
        .target = target,
        .files = discovered.files,
        .filter_source_root = discovered.dir_path,
        .filter = options.filter,
        .callbacks = callbacks,
        .next_index = .init(0),
        .outcomes = outcomes,
        .session = &session,
        .diagnostic_context = diagnostic_context,
    };
    if (worker_count == 1) {
        runRootWorker(&worker_context);
    } else {
        const workers = try allocator.alloc(std.Thread, worker_count);
        defer allocator.free(workers);
        for (workers) |*worker| worker.* = try std.Thread.spawn(.{}, runRootWorker, .{&worker_context});
        for (workers) |*worker| worker.join();
    }

    for (outcomes) |outcome| {
        if (outcome.root_error) |err| {
            if (err == error.OutOfMemory) return err;
        }
        test_summary.matched += outcome.summary.matched;
        test_summary.passed += outcome.summary.passed;
        test_summary.failed += outcome.summary.failed;
        if (outcome.root_error != null) test_summary.failed += 1;
    }

    std.debug.print("test blocks discovered: {d}\n", .{test_summary.matched});
    std.debug.print("tests passed: {d}\n", .{test_summary.passed});
    std.debug.print("tests failed: {d}\n", .{test_summary.failed});
    var failure_count: usize = 0;
    for (outcomes) |outcome| failure_count += outcome.failures.items.len;
    if (failure_count != 0) {
        std.debug.print("failed tests:\n", .{});
        for (outcomes) |outcome| {
            for (outcome.failures.items) |failure| {
                std.debug.print("  {s}: {s} ({s})\n", .{ failure.source_path, failure.name, failure.error_name });
            }
        }
    }
    if (test_summary.failed != 0) return error.TestFailed;
}

fn runRootWorker(context: *RootWorkerContext) void {
    while (true) {
        const index = context.next_index.fetchAdd(1, .monotonic);
        if (index >= context.files.len) return;
        const file = context.files[index];
        const outcome = &context.outcomes[index];
        outcome.summary = runTestRoot(
            context.allocator,
            context.target,
            file,
            context.filter,
            context.filter_source_root,
            true,
            file,
            context.callbacks,
            &outcome.failures,
            context.session,
            context.diagnostic_context,
        ) catch |err| {
            outcome.root_error = err;
            recordRootFailure(context.allocator, &outcome.failures, file, @errorName(err)) catch {};
            continue;
        };
    }
}

fn runTestRoot(
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    root_path: []const u8,
    filter: ?[]const u8,
    filter_source_root: []const u8,
    only_root_module_tests: bool,
    display_root_path: ?[]const u8,
    callbacks: Callbacks,
    failures: *std.ArrayListUnmanaged(TestFailure),
    session: *compilation.CompilationSession,
    diagnostic_context: diagnostics.Context,
) !TestExecutionSummary {
    var root_span = session.start("test.root", &.{
        .{ .key = "root", .value = .{ .string = root_path } },
    });
    defer root_span.end();
    var load_span = root_span.child(session, "load", &.{});
    var loaded = loader.loadProgramWithOptions(allocator, root_path, .{
        .allow_test_root = true,
        .diagnostic_context = diagnostic_context,
        .session = session,
    }) catch |err| {
        try diagnostic_context.emitPath(root_path, @errorName(err));
        return err;
    };
    load_span.end();
    defer loaded.deinit(allocator);

    const friend_module = try loaded.testFriendModule(allocator, root_path);
    var sema_span = root_span.child(session, "sema", &.{});
    const module = sema.buildSirWithOptions(allocator, root_path, loaded.program, .{
        .target = target.target,
        .diagnostic_context = diagnostic_context,
        .test_friend = if (friend_module) |production_module| .{
            .test_module = loaded.root_module_name,
            .production_module = production_module,
        } else null,
    }) catch |err| {
        if (err == error.SemanticFailed) return err;
        return err;
    };
    sema_span.end();
    defer module.deinit(allocator);

    const debug_source_map = try buildDebugSourceMap(allocator, loaded.module_names, loaded.source_paths);
    defer allocator.free(debug_source_map);

    var lower_span = root_span.child(session, "lower", &.{});
    var lir_module = lower.lowerModuleWithOptions(allocator, module, .{
        .debug_source_map = debug_source_map,
        .fallback_source_path = root_path,
        .target = target.target,
    }) catch |err| {
        if (!try internal_error.emitSirIdentityFailure(diagnostic_context, module, debug_source_map, root_path, err))
            try internal_error.emitFailure(diagnostic_context, root_path, .sir_to_lir, err);
        return err;
    };
    lower_span.end();
    defer lir_module.deinit(allocator);
    try callbacks.stripRootMainFunction(allocator, &lir_module, loaded.root_module_name);

    // Inline-test entry points are invoked by a generated C runner. Include
    // dependencies used by any emitted function, even if reachability from a
    // source-level main does not discover the test call edge.
    const artifact_deps = llvm_backend.moduleArtifactDepsForObject(allocator, lir_module);
    var emit_span = root_span.child(session, "emit.llvm", &.{});
    const llvm_ir = llvm_backend.emitModule(allocator, lir_module) catch |err| {
        try internal_error.emitFailure(diagnostic_context, root_path, .lir_to_llvm, err);
        return err;
    };
    emit_span.end();
    defer allocator.free(llvm_ir);

    var matched_tests = try collectMatchedInlineTests(
        allocator,
        loaded,
        module.tests,
        root_path,
        filter,
        filter_source_root,
        only_root_module_tests,
        display_root_path,
    );
    defer matched_tests.deinit(allocator);

    var summary: TestExecutionSummary = .{ .matched = matched_tests.items.len };
    const function_names = try allocator.alloc([]const u8, matched_tests.items.len);
    defer allocator.free(function_names);
    for (function_names, matched_tests.items) |*function_name, matched_test| {
        function_name.* = matched_test.function_name;
    }
    const test_results = try allocator.alloc(?anyerror, matched_tests.items.len);
    defer allocator.free(test_results);
    @memset(test_results, null);
    const durations_ns = try allocator.alloc(u64, matched_tests.items.len);
    defer allocator.free(durations_ns);
    @memset(durations_ns, 0);
    try callbacks.compileAndRunInlineTests(
        allocator,
        llvm_ir,
        artifact_deps,
        target,
        function_names,
        test_results,
        durations_ns,
        diagnostic_context,
    );

    for (matched_tests.items, test_results, durations_ns) |matched_test, result, elapsed_ns| {
        std.debug.print("  {s}: {s}\n", .{ matched_test.source_path, matched_test.name });
        if (result) |err| {
            summary.failed += 1;
            try recordTestFailure(allocator, failures, matched_test, @errorName(err));
            std.debug.print("    FAIL ({s}) [", .{@errorName(err)});
            printDuration(elapsed_ns);
            std.debug.print("]\n", .{});
            continue;
        }
        summary.passed += 1;
        std.debug.print("    PASS [", .{});
        printDuration(elapsed_ns);
        std.debug.print("]\n", .{});
    }

    return summary;
}

fn printDuration(ns: u64) void {
    if (ns < std.time.ns_per_us) {
        std.debug.print("{d} ns", .{ns});
    } else if (ns < std.time.ns_per_ms) {
        printScaledDuration(ns, std.time.ns_per_us, "us");
    } else if (ns < std.time.ns_per_s) {
        printScaledDuration(ns, std.time.ns_per_ms, "ms");
    } else {
        printScaledDuration(ns, std.time.ns_per_s, "s");
    }
}

fn printScaledDuration(ns: u64, unit_ns: u64, unit: []const u8) void {
    var whole = ns / unit_ns;
    var hundredths = ((ns % unit_ns) * 100 + unit_ns / 2) / unit_ns;
    if (hundredths == 100) {
        whole += 1;
        hundredths = 0;
    }
    if (hundredths == 0) {
        std.debug.print("{d} {s}", .{ whole, unit });
    } else {
        std.debug.print("{d}.{d:0>2} {s}", .{ whole, hundredths, unit });
    }
}

fn recordTestFailure(
    allocator: std.mem.Allocator,
    failures: *std.ArrayListUnmanaged(TestFailure),
    matched_test: MatchedInlineTest,
    error_name: []const u8,
) !void {
    const source_path = try allocator.dupe(u8, matched_test.source_path);
    errdefer allocator.free(source_path);
    const name = try allocator.dupe(u8, matched_test.name);
    errdefer allocator.free(name);
    const owned_error_name = try allocator.dupe(u8, error_name);
    errdefer allocator.free(owned_error_name);
    try failures.append(allocator, .{
        .source_path = source_path,
        .name = name,
        .error_name = owned_error_name,
    });
}

fn recordRootFailure(
    allocator: std.mem.Allocator,
    failures: *std.ArrayListUnmanaged(TestFailure),
    source_path: []const u8,
    error_name: []const u8,
) !void {
    const owned_source_path = try allocator.dupe(u8, source_path);
    errdefer allocator.free(owned_source_path);
    const name = try allocator.dupe(u8, "<compile>");
    errdefer allocator.free(name);
    const owned_error_name = try allocator.dupe(u8, error_name);
    errdefer allocator.free(owned_error_name);
    try failures.append(allocator, .{
        .source_path = owned_source_path,
        .name = name,
        .error_name = owned_error_name,
    });
}

fn collectMatchedInlineTests(
    allocator: std.mem.Allocator,
    loaded: loader.LoadedProgram,
    tests: []const sir.InlineTest,
    root_path: []const u8,
    filter: ?[]const u8,
    filter_source_root: []const u8,
    only_root_module_tests: bool,
    display_root_path: ?[]const u8,
) !std.ArrayListUnmanaged(MatchedInlineTest) {
    var matched_tests: std.ArrayListUnmanaged(MatchedInlineTest) = .empty;
    errdefer matched_tests.deinit(allocator);

    for (tests) |inline_test| {
        if (only_root_module_tests and !std.mem.eql(u8, inline_test.module_name, loaded.root_module_name)) continue;
        const source_path = displayTestSourcePath(loaded, inline_test.module_name, root_path, display_root_path);
        const filter_path = projectRelativeTestPath(source_path, filter_source_root);
        if (!testMatchesFilter(filter, filter_path, inline_test.module_name, inline_test.name)) continue;
        try matched_tests.append(allocator, .{
            .source_path = source_path,
            .name = inline_test.name,
            .function_name = inline_test.function_name,
        });
    }

    return matched_tests;
}

fn projectRelativeTestPath(source_path: []const u8, source_root: []const u8) []const u8 {
    if (std.mem.startsWith(u8, source_path, source_root) and
        source_path.len > source_root.len and
        std.fs.path.isSep(source_path[source_root.len]))
    {
        return source_path[source_root.len + 1 ..];
    }
    return std.fs.path.basename(source_path);
}

fn testMatchesFilter(filter: ?[]const u8, source_path: []const u8, module_name: []const u8, test_name: []const u8) bool {
    const needle = filter orelse return true;
    return std.mem.indexOf(u8, source_path, needle) != null or
        std.mem.indexOf(u8, module_name, needle) != null or
        std.mem.indexOf(u8, test_name, needle) != null;
}

fn findModuleSourcePath(loaded: loader.LoadedProgram, module_name: []const u8) ?[]const u8 {
    for (loaded.module_names, loaded.source_paths) |candidate_module_name, source_path| {
        if (std.mem.eql(u8, candidate_module_name, module_name)) return source_path;
    }
    return null;
}

fn displayTestSourcePath(
    loaded: loader.LoadedProgram,
    module_name: []const u8,
    root_path: []const u8,
    display_root_path: ?[]const u8,
) []const u8 {
    if (display_root_path) |path| {
        if (std.mem.eql(u8, module_name, loaded.root_module_name)) return path;
    }
    return findModuleSourcePath(loaded, module_name) orelse root_path;
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

const std = @import("std");
const compat = @import("cyna").compat;
const runtime_inventory = @import("cyna").runtime_inventory;
const compiler = @import("cyna").compiler;
const emitter = compiler.emitter;
const lexer = compiler.lexer;
const loader = compiler.loader;
const lower = compiler.lower;
const parser = compiler.parser;
const backend_support = compiler.backend_support;
const sema = compiler.sema;

const c = struct {
    extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern fn unsetenv(name: [*:0]const u8) c_int;
    extern fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;
};

pub const ExtraCSource = struct {
    name: []const u8,
    source: []const u8,
};

pub const NativeRunOutcome = union(enum) {
    exited: i64,
    signal: u32,
    stopped: u32,
    unknown,

    pub fn succeeded(self: NativeRunOutcome) bool {
        return switch (self) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

var cyna_executable_mode: ?bool = null;

pub fn runCommand(argv: []const []const u8) !std.process.RunResult {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const scratch_allocator = scratch.allocator();

    const prev = compat.getEnvVarOwned(scratch_allocator, "CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE") catch null;
    const had_prev = prev != null;
    try setEnvVar("CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE", "1");
    defer if (had_prev) {
        setEnvVar("CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE", prev.?) catch {};
    } else {
        unsetEnvVar("CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE") catch {};
    };

    // Zig 0.17 reports nonzero child exit codes as build failures. Run Cyna
    // directly so CLI tests can inspect the child's actual status and output.
    var command = argv;
    if (argv.len >= 4 and std.mem.eql(u8, argv[0], "zig") and
        std.mem.eql(u8, argv[1], "build") and std.mem.eql(u8, argv[2], "run"))
    {
        var separator: ?usize = null;
        var debug_mode = false;
        for (argv[3..], 3..) |arg, index| {
            if (std.mem.eql(u8, arg, "--")) {
                separator = index;
                break;
            }
            if (std.mem.eql(u8, arg, "-Doptimize=debug")) debug_mode = true;
        }
        if (separator) |split| {
            if (cyna_executable_mode == null or cyna_executable_mode.? != debug_mode) {
                const build_argv: []const []const u8 = if (debug_mode)
                    &.{ "zig", "build", "-Doptimize=debug" }
                else
                    &.{ "zig", "build" };
                const install = try compat.runProcess(scratch_allocator, .{ .argv = build_argv });
                if (install.term != .exited or install.term.exited != 0) return error.CynaBuildFailed;
                cyna_executable_mode = debug_mode;
            }
            const direct = try scratch_allocator.alloc([]const u8, argv.len - split);
            direct[0] = "zig-out/bin/cyna";
            @memcpy(direct[1..], argv[split + 1 ..]);
            command = direct;
        }
    }
    const result = try compat.runProcess(scratch_allocator, .{
        .argv = command,
    });
    return .{
        .term = result.term,
        .stdout = try std.testing.allocator.dupe(u8, result.stdout),
        .stderr = try std.testing.allocator.dupe(u8, result.stderr),
    };
}

pub fn expectCommandExitedCode(argv: []const []const u8, expected: u8) !void {
    const result = try runCommand(argv);
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    if (result.term.exited != expected and result.stderr.len != 0) {
        std.debug.print("{s}", .{result.stderr});
    }
    try std.testing.expectEqual(expected, result.term.exited);
}

pub fn expectCommandExitedZero(argv: []const []const u8) !void {
    return expectCommandExitedCode(argv, 0);
}

pub fn expectCommandReportedProgramExit(argv: []const []const u8, expected_program_exit: u8) !void {
    const result = try runCommand(argv);
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    const needle = try std.fmt.allocPrint(std.testing.allocator, "program exited with {d}", .{expected_program_exit});
    defer std.testing.allocator.free(needle);
    if (result.term.exited != expected_program_exit or std.mem.indexOf(u8, result.stderr, needle) == null) {
        std.debug.print("{s}", .{result.stderr});
    }
    try std.testing.expectEqual(expected_program_exit, result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, needle) != null);
}

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

const native_object_cache_dir = ".zig-cache/cyna-test-native-objects";
const native_executable_cache_dir = ".zig-cache/cyna-test-native-executables";
const cyna_binary_path = "zig-out/bin/cyna";
var native_object_cache_mutex: std.Io.Mutex = .init;
var native_executable_cache_mutex: std.Io.Mutex = .init;
var cyna_binary_mutex: std.Io.Mutex = .init;
var cyna_binary_ready = false;
var cyna_binary_failed = false;

const LlvmSymbolCheckError = error{MissingGeneratedLlvmSymbol};

const LoadedSourceProgram = struct {
    loaded: loader.LoadedProgram,
    root_path: []const u8,
    tmp: std.testing.TmpDir,

    fn deinit(self: *LoadedSourceProgram, allocator: std.mem.Allocator) void {
        self.loaded.deinit(allocator);
        allocator.free(self.root_path);
        self.tmp.cleanup();
    }
};

fn loadSourceProgram(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !LoadedSourceProgram {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "tmp"
        \\src = "."
        \\
        ,
    });

    if (std.fs.path.dirname(path)) |dir_name| {
        try compat.dirMakePath(tmp.dir, dir_name);
    }
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = path, .data = source });

    const tmp_root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(tmp_root);
    const root_path = try std.fs.path.join(allocator, &.{ tmp_root, path });
    errdefer allocator.free(root_path);

    var loaded = try loader.loadProgram(allocator, root_path);
    errdefer loaded.deinit(allocator);

    return .{
        .loaded = loaded,
        .root_path = root_path,
        .tmp = tmp,
    };
}

fn setEnvVar(key: []const u8, value: []const u8) !void {
    const key_z = try std.testing.allocator.dupeSentinel(u8, key, 0);
    defer std.testing.allocator.free(key_z);
    const value_z = try std.testing.allocator.dupeSentinel(u8, value, 0);
    defer std.testing.allocator.free(value_z);
    if (@import("builtin").os.tag == .windows) {
        if (c._putenv_s(key_z, value_z) != 0) return error.Unexpected;
    } else if (c.setenv(key_z, value_z, 1) != 0) return error.Unexpected;
}

fn unsetEnvVar(key: []const u8) !void {
    const key_z = try std.testing.allocator.dupeSentinel(u8, key, 0);
    defer std.testing.allocator.free(key_z);
    if (@import("builtin").os.tag == .windows) {
        if (c._putenv_s(key_z, "") != 0) return error.Unexpected;
    } else if (c.unsetenv(key_z) != 0) return error.Unexpected;
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

pub fn emitLlvmSource(allocator: std.mem.Allocator, path: []const u8, source: []const u8) ![]u8 {
    return emitLlvmSourceWithTarget(allocator, path, source, null);
}

pub fn emitLlvmSourceWithTarget(allocator: std.mem.Allocator, path: []const u8, source: []const u8, target: ?[]const u8) ![]u8 {
    return emitLlvmSourceWithOptions(allocator, path, source, target, .{});
}

pub fn emitLlvmSourceWithOptions(allocator: std.mem.Allocator, path: []const u8, source: []const u8, target: ?[]const u8, emit_options: emitter.EmitOptions) ![]u8 {
    var loaded = try loadSourceProgram(allocator, path, source);
    defer loaded.deinit(allocator);

    const debug_source_map = try buildDebugSourceMap(allocator, loaded.loaded.module_names, loaded.loaded.source_paths);
    defer allocator.free(debug_source_map);

    const module = try sema.buildSirWithOptions(allocator, loaded.root_path, loaded.loaded.program, .{
        .target = target,
    });
    defer module.deinit(allocator);

    const lir_module = try lower.lowerModuleWithOptions(allocator, module, .{
        .debug_source_map = debug_source_map,
        .fallback_source_path = loaded.root_path,
        .target = target,
    });
    defer lir_module.deinit(allocator);

    return emitter.emitModuleWithOptions(allocator, lir_module, emit_options);
}

pub fn artifactDepsForSource(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !backend_support.ArtifactDeps {
    var loaded = try loadSourceProgram(allocator, path, source);
    defer loaded.deinit(allocator);

    const debug_source_map = try buildDebugSourceMap(allocator, loaded.loaded.module_names, loaded.loaded.source_paths);
    defer allocator.free(debug_source_map);

    const module = try sema.buildSirWithOptions(allocator, loaded.root_path, loaded.loaded.program, .{});
    defer module.deinit(allocator);

    const lir_module = try lower.lowerModuleWithOptions(allocator, module, .{
        .debug_source_map = debug_source_map,
        .fallback_source_path = loaded.root_path,
    });
    defer lir_module.deinit(allocator);

    return backend_support.moduleArtifactDeps(allocator, lir_module);
}

pub fn emitLlvmFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var loaded = try loader.loadProgram(allocator, path);
    defer loaded.deinit(allocator);

    const debug_source_map = try buildDebugSourceMap(allocator, loaded.module_names, loaded.source_paths);
    defer allocator.free(debug_source_map);

    const module = try sema.buildSirWithOptions(allocator, path, loaded.program, .{});
    defer module.deinit(allocator);

    const lir_module = try lower.lowerModuleWithOptions(allocator, module, .{
        .debug_source_map = debug_source_map,
        .fallback_source_path = path,
    });
    defer lir_module.deinit(allocator);

    return emitter.emitModule(allocator, lir_module);
}

fn ensureInstalledCynaBinary() !void {
    try cyna_binary_mutex.lock(compat.io());
    defer cyna_binary_mutex.unlock(compat.io());

    if (cyna_binary_ready) return;
    if (cyna_binary_failed) return error.CynaBuildFailed;

    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const scratch_allocator = scratch.allocator();

    const prev = compat.getEnvVarOwned(scratch_allocator, "CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE") catch null;
    const had_prev = prev != null;
    try setEnvVar("CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE", "1");
    defer if (had_prev) {
        setEnvVar("CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE", prev.?) catch {};
    } else {
        unsetEnvVar("CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE") catch {};
    };

    const result = try compat.runProcess(scratch_allocator, .{
        .argv = &.{ "zig", "build", "-Doptimize=debug" },
    });
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                cyna_binary_failed = true;
                if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
                return error.CynaBuildFailed;
            }
        },
        else => {
            cyna_binary_failed = true;
            if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
            return error.CynaBuildFailed;
        },
    }

    cyna_binary_ready = true;
}

pub fn runInstalledCynaCommand(argv_tail: []const []const u8) !std.process.RunResult {
    try ensureInstalledCynaBinary();

    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const scratch_allocator = scratch.allocator();

    const argv = try scratch_allocator.alloc([]const u8, argv_tail.len + 1);
    argv[0] = cyna_binary_path;
    @memcpy(argv[1..], argv_tail);

    const prev = compat.getEnvVarOwned(scratch_allocator, "CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE") catch null;
    const had_prev = prev != null;
    try setEnvVar("CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE", "1");
    defer if (had_prev) {
        setEnvVar("CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE", prev.?) catch {};
    } else {
        unsetEnvVar("CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE") catch {};
    };

    const result = try compat.runProcess(scratch_allocator, .{
        .argv = argv,
    });
    return .{
        .term = result.term,
        .stdout = try std.testing.allocator.dupe(u8, result.stdout),
        .stderr = try std.testing.allocator.dupe(u8, result.stderr),
    };
}

pub fn runNativeSourceExitCode(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !i64 {
    const outcome = try runNativeSourceOutcome(allocator, path, source);
    return switch (outcome) {
        .exited => |code| code,
        else => error.TestUnexpectedResult,
    };
}

pub fn runNativeSourceOutcome(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !NativeRunOutcome {
    var loaded = try loadSourceProgram(allocator, path, source);
    defer loaded.deinit(allocator);

    const debug_source_map = try buildDebugSourceMap(allocator, loaded.loaded.module_names, loaded.loaded.source_paths);
    defer allocator.free(debug_source_map);

    const module = try sema.buildSirWithOptions(allocator, loaded.root_path, loaded.loaded.program, .{});
    defer module.deinit(allocator);

    const lir_module = try lower.lowerModuleWithOptions(allocator, module, .{
        .debug_source_map = debug_source_map,
        .fallback_source_path = loaded.root_path,
    });
    defer lir_module.deinit(allocator);

    const artifact_deps = backend_support.moduleArtifactDeps(allocator, lir_module);
    const llvm_ir = try emitter.emitModule(allocator, lir_module);
    defer allocator.free(llvm_ir);

    return compileAndRunNativeIrOutcomeWithCSources(allocator, llvm_ir, artifact_deps, &.{});
}

pub fn expectNativeSourceFailureMessage(allocator: std.mem.Allocator, path: []const u8, source: []const u8, message: []const u8) !void {
    var loaded = try loadSourceProgram(allocator, path, source);
    defer loaded.deinit(allocator);
    const debug_source_map = try buildDebugSourceMap(allocator, loaded.loaded.module_names, loaded.loaded.source_paths);
    defer allocator.free(debug_source_map);
    const module = try sema.buildSirWithOptions(allocator, loaded.root_path, loaded.loaded.program, .{});
    defer module.deinit(allocator);
    const lir_module = try lower.lowerModuleWithOptions(allocator, module, .{
        .debug_source_map = debug_source_map,
        .fallback_source_path = loaded.root_path,
    });
    defer lir_module.deinit(allocator);
    const artifact_deps = backend_support.moduleArtifactDeps(allocator, lir_module);
    const llvm_ir = try emitter.emitModule(allocator, lir_module);
    defer allocator.free(llvm_ir);
    const exe_path = try ensureCachedNativeExecutablePath(allocator, llvm_ir, artifact_deps, &.{});
    defer allocator.free(exe_path);
    const run_result = try compat.runProcess(allocator, .{ .argv = &.{exe_path} });
    try std.testing.expectEqual(@as(u8, 101), run_result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, run_result.stderr, message) != null);
}

pub fn runNativeFileExitCode(allocator: std.mem.Allocator, path: []const u8) !i64 {
    const outcome = try runNativeFileOutcome(allocator, path);
    return switch (outcome) {
        .exited => |code| code,
        else => error.TestUnexpectedResult,
    };
}

pub fn runNativeFileExitCodeWithArgv(allocator: std.mem.Allocator, path: []const u8, argv: []const []const u8) !i64 {
    const outcome = try runNativeFileOutcomeWithArgv(allocator, path, argv);
    return switch (outcome) {
        .exited => |code| code,
        else => error.TestUnexpectedResult,
    };
}

pub fn runNativeFileExitCodeFast(path: []const u8) !i64 {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    return runNativeFileExitCode(scratch.allocator(), path);
}

pub fn runNativeFileOutcome(allocator: std.mem.Allocator, path: []const u8) !NativeRunOutcome {
    return runNativeFileOutcomeWithArgv(allocator, path, &.{});
}

pub fn runNativeFileOutcomeWithArgv(allocator: std.mem.Allocator, path: []const u8, argv: []const []const u8) !NativeRunOutcome {
    var loaded = try loader.loadProgram(allocator, path);
    defer loaded.deinit(allocator);

    const debug_source_map = try buildDebugSourceMap(allocator, loaded.module_names, loaded.source_paths);
    defer allocator.free(debug_source_map);

    const module = try sema.buildSirWithOptions(allocator, path, loaded.program, .{
        .diagnostic_context = .{ .destination = .stderr },
    });
    defer module.deinit(allocator);

    const lir_module = try lower.lowerModuleWithOptions(allocator, module, .{
        .debug_source_map = debug_source_map,
        .fallback_source_path = path,
    });
    defer lir_module.deinit(allocator);

    const artifact_deps = backend_support.moduleArtifactDeps(allocator, lir_module);
    const llvm_ir = try emitter.emitModule(allocator, lir_module);
    defer allocator.free(llvm_ir);

    return compileAndRunNativeIrOutcomeWithCSourcesAndArgv(allocator, llvm_ir, artifact_deps, &.{}, argv);
}

pub fn compileAndRunNativeIr(allocator: std.mem.Allocator, llvm_ir: []const u8, artifact_deps: backend_support.ArtifactDeps) !i64 {
    const outcome = try compileAndRunNativeIrOutcomeWithCSources(allocator, llvm_ir, artifact_deps, &.{});
    return switch (outcome) {
        .exited => |code| code,
        else => error.TestUnexpectedResult,
    };
}

pub fn runNativeSourceExitCodeWithCSources(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    extra_c_sources: []const ExtraCSource,
) !i64 {
    const outcome = try runNativeSourceOutcomeWithCSources(allocator, path, source, extra_c_sources);
    return switch (outcome) {
        .exited => |code| code,
        else => error.TestUnexpectedResult,
    };
}

pub fn runNativeSourceOutcomeWithCSources(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    extra_c_sources: []const ExtraCSource,
) !NativeRunOutcome {
    var loaded = try loadSourceProgram(allocator, path, source);
    defer loaded.deinit(allocator);

    const debug_source_map = try buildDebugSourceMap(allocator, loaded.loaded.module_names, loaded.loaded.source_paths);
    defer allocator.free(debug_source_map);

    const module = try sema.buildSirWithOptions(allocator, loaded.root_path, loaded.loaded.program, .{});
    defer module.deinit(allocator);

    const lir_module = try lower.lowerModuleWithOptions(allocator, module, .{
        .debug_source_map = debug_source_map,
        .fallback_source_path = loaded.root_path,
    });
    defer lir_module.deinit(allocator);

    const artifact_deps = backend_support.moduleArtifactDeps(allocator, lir_module);
    const llvm_ir = try emitter.emitModule(allocator, lir_module);
    defer allocator.free(llvm_ir);

    return compileAndRunNativeIrOutcomeWithCSources(allocator, llvm_ir, artifact_deps, extra_c_sources);
}

pub fn compileAndRunNativeIrWithCSources(
    allocator: std.mem.Allocator,
    llvm_ir: []const u8,
    artifact_deps: backend_support.ArtifactDeps,
    extra_c_sources: []const ExtraCSource,
) !i64 {
    const outcome = try compileAndRunNativeIrOutcomeWithCSources(allocator, llvm_ir, artifact_deps, extra_c_sources);
    return switch (outcome) {
        .exited => |code| code,
        else => error.TestUnexpectedResult,
    };
}

pub fn compileAndRunNativeIrOutcomeWithCSources(
    allocator: std.mem.Allocator,
    llvm_ir: []const u8,
    artifact_deps: backend_support.ArtifactDeps,
    extra_c_sources: []const ExtraCSource,
) !NativeRunOutcome {
    return compileAndRunNativeIrOutcomeWithCSourcesAndArgv(allocator, llvm_ir, artifact_deps, extra_c_sources, &.{});
}

pub fn compileAndRunNativeIrOutcomeWithCSourcesAndArgv(
    allocator: std.mem.Allocator,
    llvm_ir: []const u8,
    artifact_deps: backend_support.ArtifactDeps,
    extra_c_sources: []const ExtraCSource,
    argv: []const []const u8,
) !NativeRunOutcome {
    const exe_path = try ensureCachedNativeExecutablePath(allocator, llvm_ir, artifact_deps, extra_c_sources);
    defer allocator.free(exe_path);

    var run_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer run_argv.deinit(allocator);
    try run_argv.append(allocator, exe_path);
    try run_argv.appendSlice(allocator, argv);

    var run_scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer run_scratch.deinit();
    const run_result = try compat.runProcess(run_scratch.allocator(), .{
        .argv = run_argv.items,
    });
    return switch (run_result.term) {
        .exited => |code| .{ .exited = @as(i64, @intCast(code)) },
        .signal => |signal| .{ .signal = @backingInt(signal) },
        .stopped => |signal| .{ .stopped = @backingInt(signal) },
        else => .unknown,
    };
}

fn ensureCachedNativeExecutablePath(
    allocator: std.mem.Allocator,
    llvm_ir: []const u8,
    artifact_deps: backend_support.ArtifactDeps,
    extra_c_sources: []const ExtraCSource,
) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(llvm_ir);
    hasher.update(&.{ @intFromBool(artifact_deps.runtime), @intFromBool(artifact_deps.std) });
    if (artifact_deps.runtime) {
        for (runtime_inventory.runtime) |source| try updateHasherWithFile(allocator, &hasher, source);
        try updateHasherWithFile(allocator, &hasher, "src/runtime/cyna.h");
    }
    if (artifact_deps.std) {
        for (runtime_inventory.std_base ++ runtime_inventory.hosted ++ runtime_inventory.headers) |source| {
            try updateHasherWithFile(allocator, &hasher, source);
        }
    }
    for (extra_c_sources) |extra| {
        hasher.update(extra.name);
        hasher.update(extra.source);
    }
    const cache_dir_name = try std.fmt.allocPrint(allocator, "{x}", .{hasher.final()});
    defer allocator.free(cache_dir_name);

    const cache_root = try compat.cwdRealpathAlloc(allocator, ".");
    defer allocator.free(cache_root);
    const relative_exe_dir = try std.fs.path.join(allocator, &.{ native_executable_cache_dir, cache_dir_name });
    defer allocator.free(relative_exe_dir);
    const exe_dir = try std.fs.path.join(allocator, &.{ cache_root, relative_exe_dir });
    defer allocator.free(exe_dir);
    const exe_path = try std.fs.path.join(allocator, &.{ exe_dir, "test.native" });
    errdefer allocator.free(exe_path);

    native_executable_cache_mutex.lockUncancelable(compat.io());
    defer native_executable_cache_mutex.unlock(compat.io());

    compat.makePath(relative_exe_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    if (!fileExistsAtPath(exe_path)) {
        try buildCachedNativeExecutable(allocator, llvm_ir, artifact_deps, extra_c_sources, exe_path);
    }

    return exe_path;
}

fn updateHasherWithFile(allocator: std.mem.Allocator, hasher: *std.hash.Wyhash, path: []const u8) !void {
    hasher.update(path);
    const source = try compat.readFileAlloc(allocator, path, 1 << 20);
    defer allocator.free(source);
    hasher.update(source);
}

fn buildCachedNativeExecutable(
    allocator: std.mem.Allocator,
    llvm_ir: []const u8,
    artifact_deps: backend_support.ArtifactDeps,
    extra_c_sources: []const ExtraCSource,
    exe_path: []const u8,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(tmp_root);

    const ir_path = try std.fs.path.join(allocator, &.{ tmp_root, "test.ll" });
    defer allocator.free(ir_path);
    const ir_object_path = try std.fs.path.join(allocator, &.{ tmp_root, "test.o" });
    defer allocator.free(ir_object_path);
    try verifyGeneratedLlvmSymbolsDefined(allocator, llvm_ir);
    {
        const file = try compat.dirCreateFile(tmp.dir, "test.ll", .{ .truncate = true });
        defer compat.closeFile(file);
        try compat.fileWriteAll(file, llvm_ir);
    }

    var extra_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (extra_paths.items) |item| allocator.free(item);
        extra_paths.deinit(allocator);
    }
    for (extra_c_sources) |extra| {
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = extra.name, .data = extra.source });
        try extra_paths.append(allocator, try std.fs.path.join(allocator, &.{ tmp_root, extra.name }));
    }
    if (artifact_deps.runtime or artifact_deps.std) {
        const leak_check_name = "cyna_runtime_leak_check.c";
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = leak_check_name, .data = runtime_leak_check_source });
        try extra_paths.append(allocator, try std.fs.path.join(allocator, &.{ tmp_root, leak_check_name }));
    }

    var compile_ir_scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer compile_ir_scratch.deinit();
    const compile_ir_result = try compat.runProcess(compile_ir_scratch.allocator(), .{
        .argv = &.{ "clang", "-c", "-x", "ir", ir_path, "-o", ir_object_path },
    });
    if (compile_ir_result.term.exited != 0 and compile_ir_result.stderr.len != 0) {
        std.debug.print("{s}", .{compile_ir_result.stderr});
    }
    try std.testing.expectEqual(@as(u8, 0), compile_ir_result.term.exited);

    var object_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (object_paths.items) |item| allocator.free(item);
        object_paths.deinit(allocator);
    }
    try object_paths.append(allocator, try allocator.dupe(u8, ir_object_path));

    if (artifact_deps.runtime) {
        for (runtime_inventory.runtime) |source| {
            const object_name = try std.fmt.allocPrint(allocator, "{s}.o", .{std.fs.path.stem(source)});
            defer allocator.free(object_name);
            const object_path = try getCachedNativeObjectPath(allocator, object_name, source, null);
            errdefer allocator.free(object_path);
            try object_paths.append(allocator, object_path);
        }
    }
    if (artifact_deps.std) {
        for (runtime_inventory.std_base ++ runtime_inventory.hosted) |source| {
            const object_name = try std.fmt.allocPrint(allocator, "{s}.o", .{std.fs.path.stem(source)});
            defer allocator.free(object_name);
            const object_path = try getCachedNativeObjectPath(allocator, object_name, source, null);
            errdefer allocator.free(object_path);
            try object_paths.append(allocator, object_path);
        }
    }
    for (extra_paths.items) |extra_path| {
        const base_name = std.fs.path.basename(extra_path);
        const object_name = try std.fmt.allocPrint(allocator, "{s}.o", .{base_name});
        defer allocator.free(object_name);
        const object_path = try std.fs.path.join(allocator, &.{ tmp_root, object_name });
        defer allocator.free(object_path);
        try compileNativeCObject(allocator, object_path, extra_path);
        try object_paths.append(allocator, try allocator.dupe(u8, object_path));
    }

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "clang");
    try argv.appendSlice(allocator, object_paths.items);
    try argv.appendSlice(allocator, &.{ "-o", exe_path });
    if (@import("builtin").os.tag == .linux) try argv.append(allocator, "-lm");

    var link_scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer link_scratch.deinit();
    const link_result = try compat.runProcess(link_scratch.allocator(), .{
        .argv = argv.items,
    });
    if (link_result.term.exited != 0 and link_result.stderr.len != 0) {
        std.debug.print("{s}", .{link_result.stderr});
    }
    try std.testing.expectEqual(@as(u8, 0), link_result.term.exited);
}

fn compileNativeCObject(
    allocator: std.mem.Allocator,
    object_path: []const u8,
    source_path: []const u8,
) !void {
    _ = allocator;
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const compile_result = try compat.runProcess(scratch.allocator(), .{
        .argv = &.{ "clang", "-c", source_path, "-o", object_path },
    });
    try std.testing.expectEqual(@as(u8, 0), compile_result.term.exited);
}

fn getCachedNativeObjectPath(
    allocator: std.mem.Allocator,
    object_name: []const u8,
    source_rel_path: []const u8,
    source_override: ?[]const u8,
) ![]u8 {
    const source_path = try compat.cwdRealpathAlloc(allocator, source_rel_path);
    defer allocator.free(source_path);

    const source_bytes = source_override orelse try compat.readFileAlloc(allocator, source_rel_path, 1 << 20);
    defer if (source_override == null) allocator.free(source_bytes);

    var hasher = std.hash.Wyhash.init(0);
    const host = @import("builtin");
    hasher.update(@tagName(host.os.tag));
    hasher.update(@tagName(host.cpu.arch));
    hasher.update(source_rel_path);
    hasher.update(source_bytes);
    if (source_override == null and std.mem.endsWith(u8, source_rel_path, ".c")) {
        const cyna_header_bytes = try compat.readFileAlloc(allocator, "src/runtime/cyna.h", 1 << 20);
        defer allocator.free(cyna_header_bytes);
        hasher.update(cyna_header_bytes);
        if (std.mem.endsWith(u8, source_rel_path, "std_task_group.c")) {
            const task_header_bytes = try compat.readFileAlloc(allocator, "packages/std/src/std_task_group.h", 1 << 20);
            defer allocator.free(task_header_bytes);
            hasher.update(task_header_bytes);
        }
    }
    const cache_key = hasher.final();
    const cache_dir_name = try std.fmt.allocPrint(allocator, "{x}", .{cache_key});
    defer allocator.free(cache_dir_name);

    const cache_root = try compat.cwdRealpathAlloc(allocator, ".");
    defer allocator.free(cache_root);
    const relative_object_dir = try std.fs.path.join(allocator, &.{ native_object_cache_dir, cache_dir_name });
    defer allocator.free(relative_object_dir);
    const object_dir = try std.fs.path.join(allocator, &.{ cache_root, relative_object_dir });
    defer allocator.free(object_dir);
    const object_path = try std.fs.path.join(allocator, &.{ object_dir, object_name });
    defer allocator.free(object_path);

    native_object_cache_mutex.lockUncancelable(compat.io());
    defer native_object_cache_mutex.unlock(compat.io());

    compat.makePath(relative_object_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    if (!fileExistsAtPath(object_path)) {
        if (source_override) |override| {
            const source_name = try std.fmt.allocPrint(allocator, "{s}.c", .{object_name});
            defer allocator.free(source_name);
            const relative_source_path = try std.fs.path.join(allocator, &.{ relative_object_dir, source_name });
            defer allocator.free(relative_source_path);
            const cached_source_path = try std.fs.path.join(allocator, &.{ object_dir, source_name });
            defer allocator.free(cached_source_path);
            try compat.writeFile(.{ .sub_path = relative_source_path, .data = override });
            try compileNativeCObject(allocator, object_path, cached_source_path);
        } else {
            try compileNativeCObject(allocator, object_path, source_path);
        }
    }

    return try allocator.dupe(u8, object_path);
}

fn fileExistsAtPath(path: []const u8) bool {
    compat.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn verifyGeneratedLlvmSymbolsDefined(allocator: std.mem.Allocator, llvm_ir: []const u8) !void {
    return verifyGeneratedLlvmSymbolsDefinedInner(allocator, llvm_ir, true);
}

fn verifyGeneratedLlvmSymbolsDefinedInner(
    allocator: std.mem.Allocator,
    llvm_ir: []const u8,
    diagnose: bool,
) !void {
    var defined: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = defined.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        defined.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, llvm_ir, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "@")) {
            const name = extractLlvmSymbol(trimmed[1..]);
            if (isGeneratedLlvmSymbol(name)) {
                try putGeneratedLlvmSymbol(allocator, &defined, name);
            }
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "define ") or std.mem.startsWith(u8, trimmed, "declare ")) {
            if (std.mem.indexOf(u8, trimmed, " @")) |at_index| {
                const name = extractLlvmSymbol(trimmed[at_index + 2 ..]);
                if (isGeneratedLlvmSymbol(name)) {
                    try putGeneratedLlvmSymbol(allocator, &defined, name);
                }
            }
        }
    }

    var offset: usize = 0;
    while (std.mem.indexOfScalarPos(u8, llvm_ir, offset, '@')) |at_index| {
        const name = extractLlvmSymbol(llvm_ir[at_index + 1 ..]);
        offset = at_index + 1 + name.len;
        if (!isGeneratedLlvmSymbol(name)) continue;
        if (!defined.contains(name)) {
            if (diagnose) {
                std.debug.print("generated LLVM symbol referenced without definition or declaration: @{s}\n", .{name});
            }
            return LlvmSymbolCheckError.MissingGeneratedLlvmSymbol;
        }
    }
}

fn putGeneratedLlvmSymbol(
    allocator: std.mem.Allocator,
    defined: *std.StringHashMapUnmanaged(void),
    name: []const u8,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const gop = try defined.getOrPut(allocator, owned_name);
    if (gop.found_existing) {
        allocator.free(owned_name);
        return;
    }
    gop.key_ptr.* = owned_name;
}

fn extractLlvmSymbol(text: []const u8) []const u8 {
    var end: usize = 0;
    while (end < text.len and isLlvmSymbolChar(text[end])) : (end += 1) {}
    return text[0..end];
}

fn isLlvmSymbolChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte == '$' or byte == '-';
}

fn isGeneratedLlvmSymbol(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "cyna_desc_") or
        std.mem.startsWith(u8, name, "cyna_copy_") or
        std.mem.startsWith(u8, name, "cyna_drop_");
}

test "native helper rejects undefined generated LLVM descriptor symbols" {
    const llvm_ir =
        \\@cyna_desc_i32 = external global { i64, i64, i32, ptr, ptr, ptr, ptr, ptr }
        \\
        \\define i32 @main() {
        \\entry:
        \\  call void @cyna_drop_missing(ptr null, ptr @cyna_desc_i32)
        \\  ret i32 0
        \\}
    ;

    try std.testing.expectError(
        LlvmSymbolCheckError.MissingGeneratedLlvmSymbol,
        verifyGeneratedLlvmSymbolsDefinedInner(std.testing.allocator, llvm_ir, false),
    );
}

test "native helper accepts declared and defined generated LLVM descriptor symbols" {
    const llvm_ir =
        \\@cyna_desc_i32 = external global { i64, i64, i32, ptr, ptr, ptr, ptr, ptr }
        \\@cyna_desc_abc = internal global { i64, i64, i32, ptr, ptr, ptr, ptr, ptr } zeroinitializer
        \\
        \\define void @cyna_drop_abc(ptr %value, ptr %desc) {
        \\entry:
        \\  ret void
        \\}
        \\
        \\define i32 @main() {
        \\entry:
        \\  call void @cyna_drop_abc(ptr null, ptr @cyna_desc_abc)
        \\  ret i32 0
        \\}
    ;

    try verifyGeneratedLlvmSymbolsDefined(std.testing.allocator, llvm_ir);
}

test "native runtime leak checker fails leaked runtime allocations" {
    const llvm_ir =
        \\declare ptr @cyna_runtime_tracked_alloc(i64)
        \\
        \\define i64 @main() {
        \\entry:
        \\  %list = call ptr @cyna_runtime_tracked_alloc(i64 8)
        \\  ret i64 0
        \\}
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(tmp_root);

    const ir_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "leak.ll" });
    defer std.testing.allocator.free(ir_path);
    const ir_object_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "leak.o" });
    defer std.testing.allocator.free(ir_object_path);
    const exe_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "leak.native" });
    defer std.testing.allocator.free(exe_path);
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "leak.ll", .data = llvm_ir });

    const runtime_object = try getCachedNativeObjectPath(std.testing.allocator, "runtime.o", "src/runtime/runtime.c", null);
    defer std.testing.allocator.free(runtime_object);
    const trace_object = try getCachedNativeObjectPath(std.testing.allocator, "failure_trace.o", "src/runtime/failure_trace.c", null);
    defer std.testing.allocator.free(trace_object);
    const std_alloc_object = try getCachedNativeObjectPath(std.testing.allocator, "std_alloc.o", "packages/std/src/std_alloc.c", null);
    defer std.testing.allocator.free(std_alloc_object);
    const std_prelude_object = try getCachedNativeObjectPath(std.testing.allocator, "std_prelude.o", "packages/std/src/std_prelude.c", null);
    defer std.testing.allocator.free(std_prelude_object);
    const std_fs_object = try getCachedNativeObjectPath(std.testing.allocator, "std_fs.o", "packages/std/src/std_fs.c", null);
    defer std.testing.allocator.free(std_fs_object);
    const std_path_object = try getCachedNativeObjectPath(std.testing.allocator, "std_path.o", "packages/std/src/std_path.c", null);
    defer std.testing.allocator.free(std_path_object);
    const std_time_object = try getCachedNativeObjectPath(std.testing.allocator, "std_time.o", "packages/std/src/std_time.c", null);
    defer std.testing.allocator.free(std_time_object);
    const std_thread_object = try getCachedNativeObjectPath(std.testing.allocator, "std_thread.o", "packages/std/src/std_thread.c", null);
    defer std.testing.allocator.free(std_thread_object);
    const std_sync_object = try getCachedNativeObjectPath(std.testing.allocator, "std_sync.o", "packages/std/src/std_sync.c", null);
    defer std.testing.allocator.free(std_sync_object);
    const leak_check_object = try getCachedNativeObjectPath(std.testing.allocator, "cyna_runtime_leak_check.o", "test/support.zig", runtime_leak_check_source);
    defer std.testing.allocator.free(leak_check_object);

    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();

    const compile_ir_result = try compat.runProcess(scratch.allocator(), .{
        .argv = &.{ "clang", "-c", "-x", "ir", ir_path, "-o", ir_object_path },
    });
    try std.testing.expectEqual(@as(u8, 0), compile_ir_result.term.exited);

    const link_result = try compat.runProcess(scratch.allocator(), .{
        .argv = &.{ "clang", ir_object_path, runtime_object, trace_object, std_alloc_object, std_prelude_object, std_fs_object, std_path_object, std_time_object, std_thread_object, std_sync_object, leak_check_object, "-o", exe_path },
    });
    try std.testing.expectEqual(@as(u8, 0), link_result.term.exited);

    var child_env = std.process.Environ.Map.init(scratch.allocator());
    try child_env.put("CYNA_LEAK_DIAGNOSTICS", "1");

    const run_result = try compat.runProcess(scratch.allocator(), .{
        .argv = &.{exe_path},
        .environ_map = &child_env,
    });
    switch (run_result.term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    try std.testing.expect(std.mem.indexOf(u8, run_result.stderr, "leak groups by allocation site") != null);
    try std.testing.expect(std.mem.indexOf(u8, run_result.stderr, "caller=") != null);
    try std.testing.expect(std.mem.indexOf(u8, run_result.stderr, "leaked allocation samples") != null);
}

test "native runtime leak checker ignores assertion abort cleanup gaps" {
    const llvm_ir =
        \\declare ptr @cyna_runtime_tracked_alloc(i64)
        \\declare void @cyna_assert_fail()
        \\
        \\define i64 @main() {
        \\entry:
        \\  %list = call ptr @cyna_runtime_tracked_alloc(i64 8)
        \\  call void @cyna_assert_fail()
        \\  ret i64 0
        \\}
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(tmp_root);

    const ir_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "assert_leak.ll" });
    defer std.testing.allocator.free(ir_path);
    const ir_object_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "assert_leak.o" });
    defer std.testing.allocator.free(ir_object_path);
    const exe_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "assert_leak.native" });
    defer std.testing.allocator.free(exe_path);
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "assert_leak.ll", .data = llvm_ir });

    const runtime_object = try getCachedNativeObjectPath(std.testing.allocator, "runtime.o", "src/runtime/runtime.c", null);
    defer std.testing.allocator.free(runtime_object);
    const trace_object = try getCachedNativeObjectPath(std.testing.allocator, "failure_trace.o", "src/runtime/failure_trace.c", null);
    defer std.testing.allocator.free(trace_object);
    const std_alloc_object = try getCachedNativeObjectPath(std.testing.allocator, "std_alloc.o", "packages/std/src/std_alloc.c", null);
    defer std.testing.allocator.free(std_alloc_object);
    const std_prelude_object = try getCachedNativeObjectPath(std.testing.allocator, "std_prelude.o", "packages/std/src/std_prelude.c", null);
    defer std.testing.allocator.free(std_prelude_object);
    const std_fs_object = try getCachedNativeObjectPath(std.testing.allocator, "std_fs.o", "packages/std/src/std_fs.c", null);
    defer std.testing.allocator.free(std_fs_object);
    const std_path_object = try getCachedNativeObjectPath(std.testing.allocator, "std_path.o", "packages/std/src/std_path.c", null);
    defer std.testing.allocator.free(std_path_object);
    const std_time_object = try getCachedNativeObjectPath(std.testing.allocator, "std_time.o", "packages/std/src/std_time.c", null);
    defer std.testing.allocator.free(std_time_object);
    const std_thread_object = try getCachedNativeObjectPath(std.testing.allocator, "std_thread.o", "packages/std/src/std_thread.c", null);
    defer std.testing.allocator.free(std_thread_object);
    const std_sync_object = try getCachedNativeObjectPath(std.testing.allocator, "std_sync.o", "packages/std/src/std_sync.c", null);
    defer std.testing.allocator.free(std_sync_object);
    const leak_check_object = try getCachedNativeObjectPath(std.testing.allocator, "cyna_runtime_leak_check.o", "test/support.zig", runtime_leak_check_source);
    defer std.testing.allocator.free(leak_check_object);

    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();

    const compile_ir_result = try compat.runProcess(scratch.allocator(), .{
        .argv = &.{ "clang", "-c", "-x", "ir", ir_path, "-o", ir_object_path },
    });
    try std.testing.expectEqual(@as(u8, 0), compile_ir_result.term.exited);

    const link_result = try compat.runProcess(scratch.allocator(), .{
        .argv = &.{ "clang", ir_object_path, runtime_object, trace_object, std_alloc_object, std_prelude_object, std_fs_object, std_path_object, std_time_object, std_thread_object, std_sync_object, leak_check_object, "-o", exe_path },
    });
    try std.testing.expectEqual(@as(u8, 0), link_result.term.exited);

    const run_result = try compat.runProcess(scratch.allocator(), .{
        .argv = &.{exe_path},
    });
    try std.testing.expectEqual(@as(u8, 101), run_result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, run_result.stderr, "cyna runtime leak check failed") == null);
}

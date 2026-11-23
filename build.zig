const std = @import("std");
const runtime_inventory = @import("src/runtime/inventory.zig");

pub fn build(b: *std.Build) void {
    const required = comptime std.mem.trim(u8, @embedFile(".zig-version"), " \r\n");
    if (comptime std.mem.eql(u8, @import("builtin").zig_version_string, required)) {
        buildSupported(b);
    } else {
        @compileError("Cyna requires Zig " ++ required ++ "; run python3 scripts/setup_zig.py and put .tools/zig/" ++ required ++ " first on PATH (see README.md)");
    }
}

fn buildSupported(b: *std.Build) void {
    const cyna_version = "0.5.4";
    const target = b.standardTargetOptions(.{});
    const optimize = defaultOptimizeOption(b);
    const zig_libs = b.dependency("zig_libs", .{
        .target = target,
        .optimize = optimize,
    });
    const build_options = compilerBuildOptions(b, zig_libs, target, optimize, cyna_version);

    const runtime_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .sanitize_c = .off,
        .link_libc = true,
    });
    for (runtime_inventory.runtime ++ runtime_inventory.memory) |source| {
        runtime_module.addCSourceFile(.{ .file = b.path(source) });
    }
    const runtime = b.addLibrary(.{
        .name = "cyna",
        .linkage = .static,
        .root_module = runtime_module,
    });
    runtime.installHeader(b.path("src/runtime/cyna.h"), "cyna.h");
    runtime.installHeader(b.path("src/runtime/failure_trace.h"), "failure_trace.h");
    const install_runtime = b.addInstallArtifact(runtime, .{});
    b.getInstallStep().dependOn(&install_runtime.step);

    const std_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .sanitize_c = .off,
        .link_libc = true,
    });
    for (runtime_inventory.std_base ++ runtime_inventory.hosted) |source| {
        std_module.addCSourceFile(.{ .file = b.path(source) });
    }
    const std_lib = b.addLibrary(.{
        .name = "cyna_std",
        .linkage = .static,
        .root_module = std_module,
    });
    std_lib.installHeader(b.path("src/runtime/cyna.h"), "cyna.h");
    const install_std = b.addInstallArtifact(std_lib, .{});
    b.getInstallStep().dependOn(&install_std.step);
    if (target.result.os.tag == .macos) {
        const normalize_archives = b.addSystemCommand(&.{
            "python3",
            b.root.joinString(b.allocator, "scripts/normalize_darwin_archive.py") catch @panic("OOM"),
        });
        normalize_archives.addFileArg(b.graph.path(.install_prefix, "lib/libcyna.a"));
        normalize_archives.addFileArg(b.graph.path(.install_prefix, "lib/libcyna_std.a"));
        normalize_archives.step.dependOn(&install_runtime.step);
        normalize_archives.step.dependOn(&install_std.step);
        b.getInstallStep().dependOn(&normalize_archives.step);
    }

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .error_tracing = true,
        .link_libc = true,
    });
    module.addOptions("build_options", build_options);
    module.addImport("zig_libs", zig_libs.module("zig_libs"));

    const exe = b.addExecutable(.{
        .name = "cyna",
        .root_module = module,
    });
    // Nested semantic specialization needs more than the default main stack.
    // Keep serial CLI compilation viable for deeply nested application types.
    exe.stack_size = 64 * 1024 * 1024;

    const cyna_module = b.createModule(.{
        .root_source_file = b.path("src/cyna.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cyna_module.addOptions("build_options", build_options);
    cyna_module.addImport("zig_libs", zig_libs.module("zig_libs"));

    const check_test_api_module = b.createModule(.{
        .root_source_file = b.path("src/check_test_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    check_test_api_module.addOptions("build_options", build_options);
    check_test_api_module.addImport("zig_libs", zig_libs.module("zig_libs"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run cyna");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("test/test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addOptions("build_options", build_options);
    test_module.addImport("cyna", cyna_module);
    const test_filters: []const []const u8 = if (b.option([]const u8, "test-filter", "Filter tests by name")) |filter| &.{filter} else &.{};
    const tests = b.addTest(.{
        .root_module = test_module,
        .filters = test_filters,
    });

    const test_cmd = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_cmd.step);

    const build_contract_module = b.createModule(.{
        .root_source_file = b.path("src/test_build_contracts.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    build_contract_module.addOptions("build_options", build_options);
    build_contract_module.addImport("zig_libs", zig_libs.module("zig_libs"));
    const build_contract_tests = b.addTest(.{ .root_module = build_contract_module, .filters = test_filters });
    const build_contract_run = b.addRunArtifact(build_contract_tests);
    test_step.dependOn(&build_contract_run.step);
    const build_contract_step = b.step("test-build-contracts", "Run internal cache, toolchain, and module-worker contracts");
    build_contract_step.dependOn(&build_contract_run.step);

    const lower_lir_test_roots = [_][]const u8{
        "test/lower/lir_core.zig",
        "test/lower/lir_containers.zig",
        "test/lower/lir_ownership.zig",
        "test/lower/lir_projections.zig",
        "test/lower/lir_aliases.zig",
        "test/lower/lir_cleanup.zig",
        "test/lower/lir_platform.zig",
    };
    for (lower_lir_test_roots) |root_source| {
        const lower_lir_test_module = b.createModule(.{
            .root_source_file = b.path(root_source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        lower_lir_test_module.addOptions("build_options", build_options);
        lower_lir_test_module.addImport("cyna", cyna_module);
        const lower_lir_tests = b.addTest(.{
            .root_module = lower_lir_test_module,
            .filters = test_filters,
        });
        const lower_lir_test_cmd = b.addRunArtifact(lower_lir_tests);
        test_step.dependOn(&lower_lir_test_cmd.step);
    }

    const sema_test_module = b.createModule(.{
        .root_source_file = b.path("test/test_sema.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sema_test_module.addOptions("build_options", build_options);
    sema_test_module.addImport("cyna", cyna_module);
    const sema_tests = b.addTest(.{
        .root_module = sema_test_module,
        .filters = test_filters,
    });
    const sema_test_cmd = b.addRunArtifact(sema_tests);
    test_step.dependOn(&sema_test_cmd.step);
    const sema_test_step = b.step("test-sema", "Run the sema lane only");
    sema_test_step.dependOn(&sema_test_cmd.step);

    const sema_oom_module = b.createModule(.{
        .root_source_file = b.path("test/test_sema_oom.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sema_oom_module.addOptions("build_options", build_options);
    sema_oom_module.addImport("cyna", cyna_module);
    const sema_oom_tests = b.addTest(.{
        .root_module = sema_oom_module,
        .filters = test_filters,
    });
    const sema_oom_run = b.addRunArtifact(sema_oom_tests);
    const sema_oom_step = b.step("test-sema-oom", "Run exhaustive sema allocation-failure tests");
    sema_oom_step.dependOn(&sema_oom_run.step);
    test_step.dependOn(&sema_oom_run.step);

    const lower_lir_test_step = b.step("test-lower-lir", "Run the lowering lanes only");
    for (lower_lir_test_roots) |root_source| {
        const step_module = b.createModule(.{
            .root_source_file = b.path(root_source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        step_module.addOptions("build_options", build_options);
        step_module.addImport("cyna", cyna_module);
        const step_tests = b.addTest(.{
            .root_module = step_module,
            .filters = test_filters,
        });
        lower_lir_test_step.dependOn(&b.addRunArtifact(step_tests).step);
    }

    const task_group_test_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    task_group_test_module.addCSourceFile(.{ .file = b.path("test/runtime/task_group_native.c") });
    task_group_test_module.addCSourceFile(.{ .file = b.path("packages/std/src/std_task_group.c") });
    task_group_test_module.addCSourceFile(.{ .file = b.path("src/runtime/failure_trace.c") });
    const task_group_tests = b.addExecutable(.{
        .name = "cyna-task-group-native-test",
        .root_module = task_group_test_module,
    });
    const task_group_test_cmd = b.addRunArtifact(task_group_tests);
    test_step.dependOn(&task_group_test_cmd.step);

    const failure_trace_test_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    failure_trace_test_module.addCSourceFile(.{ .file = b.path("test/runtime/failure_trace_native.c") });
    failure_trace_test_module.addCSourceFile(.{ .file = b.path("src/runtime/failure_trace.c") });
    const failure_trace_tests = b.addExecutable(.{
        .name = "cyna-failure-trace-native-test",
        .root_module = failure_trace_test_module,
    });
    test_step.dependOn(&b.addRunArtifact(failure_trace_tests).step);

    const thread_bridge_test_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    thread_bridge_test_module.addCSourceFile(.{ .file = b.path("test/runtime/thread_bridge_native.c") });
    thread_bridge_test_module.addCSourceFile(.{ .file = b.path("packages/std/src/std_thread.c") });
    for (runtime_inventory.runtime ++ runtime_inventory.memory) |source| {
        thread_bridge_test_module.addCSourceFile(.{ .file = b.path(source) });
    }
    const thread_bridge_tests = b.addExecutable(.{
        .name = "cyna-thread-bridge-native-test",
        .root_module = thread_bridge_test_module,
    });
    const thread_bridge_test_cmd = b.addRunArtifact(thread_bridge_tests);
    test_step.dependOn(&thread_bridge_test_cmd.step);

    const backend_test_module = b.createModule(.{
        .root_source_file = b.path("test/test_backend.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    backend_test_module.addOptions("build_options", build_options);
    backend_test_module.addImport("cyna", cyna_module);
    const backend_tests = b.addTest(.{
        .root_module = backend_test_module,
        .filters = if (test_filters.len != 0) test_filters else &.{ "LLVM", "AArch64" },
    });
    const backend_test_cmd = b.addRunArtifact(backend_tests);
    test_step.dependOn(&backend_test_cmd.step);

    const tier_tests = [_]struct {
        name: []const u8,
        description: []const u8,
        root_source: []const u8,
        optimize_override: ?std.builtin.OptimizeMode = null,
        import_profile: enum { cyna, check_direct } = .cyna,
        filters_override: []const []const u8 = &.{},
    }{
        .{
            .name = "test-fast",
            .description = "Run fast compiler tests",
            .root_source = "test/test_fast.zig",
        },
        .{
            .name = "test-native",
            .description = "Run native execution tests",
            .root_source = "test/test_native.zig",
        },
        .{
            .name = "test-native-inline-cache",
            .description = "Run native inline-test object cache tests",
            .root_source = "test/native/inline_cache.zig",
            .optimize_override = .debug,
        },
        .{
            .name = "test-targets",
            .description = "Run target matrix tests",
            .root_source = "test/test_targets.zig",
        },
        .{
            .name = "test-tooling",
            .description = "Run all tooling and command tests",
            .root_source = "test/test_tooling.zig",
        },
        .{
            .name = "test-tooling-fmt",
            .description = "Run formatter and fmt command tests",
            .root_source = "test/test_tooling_fmt.zig",
            .optimize_override = .debug,
        },
        .{
            .name = "test-tooling-smoke",
            .description = "Run quick tooling smoke tests",
            .root_source = "test/test_tooling_smoke.zig",
            .optimize_override = .debug,
        },
        .{
            .name = "test-tooling-cli",
            .description = "Run CLI tooling integration tests",
            .root_source = "test/test_tooling_cli.zig",
        },
        .{
            .name = "test-tooling-cli-build",
            .description = "Run CLI build-command integration tests",
            .root_source = "test/test_tooling_cli_build.zig",
        },
        .{
            .name = "test-tooling-cli-build-project",
            .description = "Run CLI build-command project and native interop integration tests",
            .root_source = "test/test_tooling_cli_build_project.zig",
            .optimize_override = .debug,
            .filters_override = &.{
                "generated header",
                "project directory build",
                "companion C source",
                "companion C symbol imports",
                "static library",
                "assembly source",
                "lowers unqualified",
            },
        },
        .{
            .name = "test-tooling-cli-build-freestanding",
            .description = "Run CLI build-command freestanding and cross-target integration tests",
            .root_source = "test/test_tooling_cli_build_freestanding.zig",
            .optimize_override = .debug,
            .filters_override = &.{
                "freestanding staticlib",
                "riscv64",
            },
        },
        .{
            .name = "test-tooling-cli-build-clean",
            .description = "Run CLI build-command cleanup integration tests",
            .root_source = "test/test_tooling_cli_build_clean.zig",
            .optimize_override = .debug,
            .filters_override = &.{
                "clean removes",
            },
        },
        .{
            .name = "test-tooling-cli-build-emit",
            .description = "Run CLI build-command artifact emission integration tests",
            .root_source = "test/test_tooling_cli_build_emit.zig",
            .optimize_override = .debug,
            .filters_override = &.{
                "build emits",
                "emit-obj",
                "emit-c-header",
            },
        },
        .{
            .name = "test-tooling-cli-build-emit-stage",
            .description = "Run CLI build-command stage artifact emission tests",
            .root_source = "test/test_tooling_cli_build_emit_stage.zig",
            .optimize_override = .debug,
            .filters_override = &.{
                "build emits compiler stage artifacts",
            },
        },
        .{
            .name = "test-tooling-cli-build-emit-asm",
            .description = "Run CLI build-command asm include emission tests",
            .root_source = "test/test_tooling_cli_build_emit_asm.zig",
            .optimize_override = .debug,
            .filters_override = &.{
                "build emits exported asm constants",
            },
        },
        .{
            .name = "test-tooling-cli-build-emit-module-ll",
            .description = "Run CLI build-command module resolution LLVM emission tests",
            .root_source = "test/test_tooling_cli_build_emit_module_ll.zig",
            .optimize_override = .debug,
            .filters_override = &.{
                "build lowers unqualified calls in their resolved module",
            },
        },
        .{
            .name = "test-tooling-cli-build-emit-obj",
            .description = "Run CLI build-command object/header dual emission tests",
            .root_source = "test/test_tooling_cli_build_emit_obj.zig",
            .optimize_override = .debug,
            .filters_override = &.{
                "build emit-obj does not require main or link a native artifact",
            },
        },
        .{
            .name = "test-tooling-cli-build-emit-header",
            .description = "Run CLI build-command ABI header emission tests",
            .root_source = "test/test_tooling_cli_build_emit_header.zig",
            .optimize_override = .debug,
            .filters_override = &.{
                "build emit-c-header surfaces compiler-owned ABI helpers for string and storage exports",
            },
        },
        .{
            .name = "test-tooling-cli-help",
            .description = "Run CLI help-command integration tests",
            .root_source = "test/test_tooling_cli_help.zig",
            .optimize_override = .debug,
        },
        .{
            .name = "test-tooling-cli-test-command",
            .description = "Run CLI test-command integration tests",
            .root_source = "test/test_tooling_cli_test_command.zig",
        },
        .{
            .name = "test-tooling-check",
            .description = "Run focused check-command tests",
            .root_source = "test/test_tooling_check.zig",
            .optimize_override = .debug,
            .import_profile = .check_direct,
        },
        .{
            .name = "test-tooling-cli-check",
            .description = "Run compatibility alias for focused check-command tests",
            .root_source = "test/test_tooling_cli_check.zig",
            .optimize_override = .debug,
            .import_profile = .check_direct,
        },
        .{
            .name = "test-tooling-check-smoke",
            .description = "Run core check-command smoke tests",
            .root_source = "test/test_tooling_check_smoke.zig",
            .optimize_override = .debug,
            .import_profile = .check_direct,
        },
        .{
            .name = "test-tooling-check-extended",
            .description = "Run extended legacy check-command regressions",
            .root_source = "test/test_tooling_check_extended.zig",
        },
        .{
            .name = "test-tooling-check-extended-core",
            .description = "Run legacy check command acceptance/rejection regressions",
            .root_source = "test/test_tooling_check_extended_core.zig",
            .optimize_override = .debug,
        },
        .{
            .name = "test-tooling-check-extended-core-basic",
            .description = "Run legacy check command basic acceptance/diagnostic regressions",
            .root_source = "test/test_tooling_check_extended_core_basic.zig",
            .optimize_override = .debug,
            .import_profile = .check_direct,
        },
        .{
            .name = "test-tooling-check-extended-core-hosted-std",
            .description = "Run legacy check command hosted std import regressions",
            .root_source = "test/test_tooling_check_extended_core_hosted_std.zig",
            .optimize_override = .debug,
            .import_profile = .check_direct,
        },
        .{
            .name = "test-tooling-check-extended-core-hosted-std-fs",
            .description = "Run legacy check command hosted std.fs regressions",
            .root_source = "test/test_tooling_check_extended_core_hosted_std_fs.zig",
            .optimize_override = .debug,
            .import_profile = .check_direct,
        },
        .{
            .name = "test-tooling-check-extended-core-hosted-std-thread",
            .description = "Run legacy check command hosted std.thread regressions",
            .root_source = "test/test_tooling_check_extended_core_hosted_std_thread.zig",
            .optimize_override = .debug,
            .import_profile = .check_direct,
        },
        .{
            .name = "test-tooling-check-extended-core-hosted-std-thread-accept",
            .description = "Run legacy check command hosted std.thread acceptance regressions",
            .root_source = "test/test_tooling_check_extended_core_hosted_std_thread_accept.zig",
            .optimize_override = .debug,
            .import_profile = .check_direct,
        },
        .{
            .name = "test-tooling-check-extended-core-hosted-std-thread-bridge",
            .description = "Run legacy check command hosted std.thread bridge import regressions",
            .root_source = "test/test_tooling_check_extended_core_hosted_std_thread_bridge.zig",
            .optimize_override = .debug,
            .import_profile = .check_direct,
        },
        .{
            .name = "test-tooling-check-extended-core-hosted-std-thread-raw",
            .description = "Run legacy check command hosted std.thread raw field regressions",
            .root_source = "test/test_tooling_check_extended_core_hosted_std_thread_raw.zig",
            .optimize_override = .debug,
            .import_profile = .check_direct,
        },
        .{
            .name = "test-tooling-check-extended-core-hosted-std-sync",
            .description = "Run legacy check command hosted std.sync regressions",
            .root_source = "test/test_tooling_check_extended_core_hosted_std_sync.zig",
            .optimize_override = .debug,
            .import_profile = .check_direct,
        },
        .{
            .name = "test-tooling-check-extended-core-hosted-std-sync-accept",
            .description = "Run legacy check command hosted std.sync acceptance regressions",
            .root_source = "test/test_tooling_check_extended_core_hosted_std_sync_accept.zig",
            .optimize_override = .debug,
            .import_profile = .check_direct,
        },
        .{
            .name = "test-tooling-check-extended-core-hosted-std-sync-bridge",
            .description = "Run legacy check command hosted std.sync bridge import regressions",
            .root_source = "test/test_tooling_check_extended_core_hosted_std_sync_bridge.zig",
            .optimize_override = .debug,
            .import_profile = .check_direct,
        },
        .{
            .name = "test-tooling-check-extended-core-hosted-std-sync-raw",
            .description = "Run legacy check command hosted std.sync raw field regressions",
            .root_source = "test/test_tooling_check_extended_core_hosted_std_sync_raw.zig",
            .optimize_override = .debug,
            .import_profile = .check_direct,
        },
        .{
            .name = "test-tooling-check-extended-core-prelude",
            .description = "Run legacy check command prelude regressions",
            .root_source = "test/test_tooling_check_extended_core_prelude.zig",
            .optimize_override = .debug,
            .import_profile = .check_direct,
        },
        .{
            .name = "test-tooling-check-extended-core-emit-alias",
            .description = "Run legacy emitted import and alias regressions",
            .root_source = "test/test_tooling_check_extended_core_emit_alias.zig",
            .optimize_override = .debug,
        },
        .{
            .name = "test-tooling-check-extended-prelude",
            .description = "Run legacy check prelude regressions",
            .root_source = "test/test_tooling_check_extended.zig",
            .optimize_override = .debug,
            .filters_override = &.{"prelude"},
        },
        .{
            .name = "test-tooling-check-extended-build",
            .description = "Run legacy hosted-std build rejection regressions",
            .root_source = "test/test_tooling_check_extended_build.zig",
            .optimize_override = .debug,
        },
        .{
            .name = "test-tooling-check-extended-native-run",
            .description = "Run legacy native run hosted-std regressions",
            .root_source = "test/test_tooling_check_extended.zig",
            .optimize_override = .debug,
            .filters_override = &.{"native run"},
        },
        .{
            .name = "test-tooling-check-extended-native-std",
            .description = "Run legacy native std hosted surface regressions",
            .root_source = "test/test_tooling_check_extended_native_std.zig",
            .optimize_override = .debug,
        },
        .{
            .name = "test-tooling-check-extended-native-std-fs",
            .description = "Run legacy native std.fs hosted regressions",
            .root_source = "test/test_tooling_check_extended_native_std_fs.zig",
            .optimize_override = .debug,
        },
        .{
            .name = "test-tooling-check-extended-native-std-process",
            .description = "Run legacy native std.process hosted regressions",
            .root_source = "test/test_tooling_check_extended_native_std_process.zig",
            .optimize_override = .debug,
        },
        .{
            .name = "test-tooling-check-extended-native-std-path-time",
            .description = "Run legacy native std.path/std.time hosted regressions",
            .root_source = "test/test_tooling_check_extended_native_std_path_time.zig",
            .optimize_override = .debug,
        },
        .{
            .name = "test-tooling-check-extended-native-std-thread-sync",
            .description = "Run legacy native std.thread/std.sync hosted regressions",
            .root_source = "test/test_tooling_check_extended_native_std_thread_sync.zig",
            .optimize_override = .debug,
        },
        .{
            .name = "test-tooling-check-extended-emit",
            .description = "Run legacy emitted hosted-std/compiler import regressions",
            .root_source = "test/test_tooling_check_extended.zig",
            .optimize_override = .debug,
            .filters_override = &.{"emit-sir"},
        },
        .{
            .name = "test-tooling-lsp",
            .description = "Run LSP tooling tests",
            .root_source = "test/test_tooling_lsp.zig",
        },
        .{
            .name = "test-llvm-emission",
            .description = "Run extracted LLVM backend emission tests",
            .root_source = "test/test_llvm_emission.zig",
        },
        .{
            .name = "test-extended",
            .description = "Run extended tests",
            .root_source = "test/test_extended.zig",
        },
        .{
            .name = "test-profile",
            .description = "Run profile-ready test suite",
            .root_source = "test/test_profile.zig",
        },
        .{
            .name = "test-native-c-abi",
            .description = "Run native C ABI execution tests",
            .root_source = "test/test_native_c_abi.zig",
        },
        .{
            .name = "test-native-core",
            .description = "Run native core execution tests",
            .root_source = "test/test_native_core.zig",
        },
        .{
            .name = "test-native-examples",
            .description = "Run native example execution tests",
            .root_source = "test/test_native_examples.zig",
        },
        .{
            .name = "test-native-language",
            .description = "Run carried-forward native language tests",
            .root_source = "test/test_native_language.zig",
        },
        .{
            .name = "test-native-allocator-contexts",
            .description = "Run native allocator context tests",
            .root_source = "test/test_native_allocator_contexts.zig",
        },
        .{
            .name = "test-native-casts",
            .description = "Run native cast tests",
            .root_source = "test/test_native_casts.zig",
        },
        .{
            .name = "test-native-generics",
            .description = "Run native generics tests",
            .root_source = "test/test_native_generics.zig",
        },
        .{
            .name = "test-native-globals",
            .description = "Run native globals tests",
            .root_source = "test/test_native_globals.zig",
        },
        .{
            .name = "test-native-ownership",
            .description = "Run native ownership tests",
            .root_source = "test/test_native_ownership.zig",
        },
        .{
            .name = "test-native-unions",
            .description = "Run native unions/result tests",
            .root_source = "test/test_native_unions.zig",
        },
        .{
            .name = "test-native-numeric",
            .description = "Run native numeric execution tests",
            .root_source = "test/test_native_numeric.zig",
        },
        .{
            .name = "test-native-packed",
            .description = "Run native packed execution tests",
            .root_source = "test/test_native_packed.zig",
        },
        .{
            .name = "test-native-refs",
            .description = "Run native refs/projection execution tests",
            .root_source = "test/test_native_refs.zig",
        },
        .{
            .name = "test-native-storage",
            .description = "Run native storage execution tests",
            .root_source = "test/test_native_storage.zig",
        },
        .{
            .name = "test-native-strings",
            .description = "Run native string/equality/io/slice execution tests",
            .root_source = "test/test_native_strings.zig",
        },
    };
    const architecture_check = b.addSystemCommand(&.{ "python3", "scripts/check_compiler_architecture.py" });
    const architecture_tests = b.addSystemCommand(&.{ "python3", "scripts/test_compiler_architecture.py" });
    const architecture_step = b.step("check-architecture", "Check compiler phase imports and guard tests");
    architecture_step.dependOn(&architecture_check.step);
    architecture_step.dependOn(&architecture_tests.step);
    test_step.dependOn(architecture_step);

    const debug_zig_libs = if (optimize == .debug) zig_libs else b.dependency("zig_libs", .{ .target = target, .optimize = .debug });
    const debug_build_options = if (optimize == .debug) build_options else compilerBuildOptions(b, debug_zig_libs, target, .debug, cyna_version);
    inline for (tier_tests) |tier| {
        const tier_optimize = tier.optimize_override orelse optimize;
        const tier_build_options = if (tier_optimize == optimize) build_options else debug_build_options;
        const tier_zig_libs = if (tier_optimize == optimize) zig_libs else debug_zig_libs;

        const tier_module = b.createModule(.{
            .root_source_file = b.path(tier.root_source),
            .target = target,
            .optimize = tier_optimize,
            .link_libc = true,
        });
        tier_module.addOptions("build_options", tier_build_options);
        switch (tier.import_profile) {
            .cyna => {
                const tier_cyna_module = b.createModule(.{
                    .root_source_file = b.path("src/cyna.zig"),
                    .target = target,
                    .optimize = tier_optimize,
                    .link_libc = true,
                });
                tier_cyna_module.addOptions("build_options", tier_build_options);
                tier_cyna_module.addImport("zig_libs", tier_zig_libs.module("zig_libs"));
                tier_module.addImport("cyna", tier_cyna_module);
            },
            .check_direct => {
                const tier_check_test_api_module = b.createModule(.{
                    .root_source_file = b.path("src/check_test_api.zig"),
                    .target = target,
                    .optimize = tier_optimize,
                    .link_libc = true,
                });
                tier_check_test_api_module.addOptions("build_options", tier_build_options);
                tier_check_test_api_module.addImport("zig_libs", tier_zig_libs.module("zig_libs"));
                tier_module.addImport("check_api", tier_check_test_api_module);
            },
        }
        const tier_artifact = b.addTest(.{
            .root_module = tier_module,
            .filters = if (tier.filters_override.len != 0) tier.filters_override else test_filters,
        });
        const tier_cmd = b.addRunArtifact(tier_artifact);
        const tier_step = b.step(tier.name, tier.description);
        tier_step.dependOn(&tier_cmd.step);
        if (comptime std.mem.eql(u8, tier.name, "test-fast")) {
            tier_step.dependOn(architecture_step);
        }

        if (comptime std.mem.eql(u8, tier.name, "test-native")) {
            const backend_native_module = b.createModule(.{
                .root_source_file = b.path("test/test_backend.zig"),
                .target = target,
                .optimize = tier_optimize,
                .link_libc = true,
            });
            backend_native_module.addOptions("build_options", tier_build_options);
            const backend_native_cyna_module = b.createModule(.{
                .root_source_file = b.path("src/cyna.zig"),
                .target = target,
                .optimize = tier_optimize,
                .link_libc = true,
            });
            backend_native_cyna_module.addOptions("build_options", tier_build_options);
            backend_native_cyna_module.addImport("zig_libs", tier_zig_libs.module("zig_libs"));
            backend_native_module.addImport("cyna", backend_native_cyna_module);
            const backend_native_tests = b.addTest(.{
                .root_module = backend_native_module,
                .filters = if (test_filters.len != 0) test_filters else &.{"native"},
            });
            const backend_native_cmd = b.addRunArtifact(backend_native_tests);
            tier_step.dependOn(&backend_native_cmd.step);
        }
    }
}

fn compilerBuildOptions(b: *std.Build, dependency: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, version: []const u8) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption([]const u8, "source_root", b.root.toString(b.allocator) catch @panic("OOM"));
    options.addOption([]const u8, "cyna_version", version);
    const target_identity = b.fmt("{s}/{s}/{s}", .{
        target.query.zigTriple(b.allocator) catch @panic("cannot identify compiler target"),
        target.result.cpu.model.name,
        target.query.serializeCpuAlloc(b.allocator) catch @panic("cannot identify compiler CPU features"),
    });
    const identity = b.run(&.{ "python3", b.root.joinString(b.allocator, "scripts/compiler_identity.py") catch @panic("OOM"), b.root.toString(b.allocator) catch @panic("OOM"), dependency.builder.root.toString(b.allocator) catch @panic("OOM"), @import("builtin").zig_version_string, @tagName(optimize), target_identity });
    options.addOption([]const u8, "compiler_identity", std.mem.trim(u8, identity, "\r\n "));
    return options;
}

fn defaultOptimizeOption(b: *std.Build) std.builtin.OptimizeMode {
    if (b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    )) |mode| {
        return mode;
    }

    return switch (b.graph.release_mode) {
        .off, .any, .fast => .fast,
        .safe => .safe,
        .small => .small,
    };
}

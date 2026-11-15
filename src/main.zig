const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const compat = @import("compat.zig");
const commands = @import("commands.zig");
const help = @import("help.zig");
const build_pkg = @import("build.zig");
const diagnostic_renderer = @import("compiler/diagnostic/renderer.zig");
const diagnostic_sources = @import("compiler/diagnostic/source_registry.zig");
const diagnostics = @import("compiler/diagnostics.zig");
const lsp = @import("lsp/server.zig");
const build_mod = commands.build;
const check_mod = commands.check;
const clean = commands.clean;
const install = commands.install;
const package_mod = commands.package;
const run_mod = commands.run;
const test_mod = commands.@"test";
const native_mod = build_pkg.native;
const CheckOptions = cli.CheckOptions;
const RunOptions = cli.RunOptions;
const TestOptions = cli.TestOptions;

fn isHelpCommand(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn argsRequestHelp(args: []const []const u8) bool {
    return args.len == 1 and isHelpCommand(args[0]);
}

const InstallDependency = install.InstallDependency;
const InstallLockDependency = install.InstallLockDependency;
const ResolvedInstallPackage = install.ResolvedInstallPackage;
const PackageManifest = install.PackageManifest;
const ManifestDependencySpec = install.ManifestDependencySpec;
const loadPackageManifest = install.loadPackageManifest;
const resolveManifestPathFromRoot = install.resolveManifestPathFromRoot;
const collectInstallPackages = install.collectInstallPackages;
const collectInstallPackagesWithHome = install.collectInstallPackagesWithHome;
const parseInstallDependencies = install.parseInstallDependencies;
const parseManifestDependencySpec = install.parseManifestDependencySpec;
const collectInstallLockDependencies = install.collectInstallLockDependencies;
const writeProjectLockfile = install.writeProjectLockfile;
const installPackageAtHome = install.installPackageAtHome;
const installedPackageRootPath = install.installedPackageRootPath;

pub fn main(init: std.process.Init) !void {
    var process_exit_code: ?u8 = null;
    defer if (process_exit_code) |code| std.process.exit(code);

    const allocator = init.gpa;
    compat.initRuntimeIo(init.io);
    var diagnostic_sink = diagnostics.Sink.init(allocator);
    defer diagnostic_sink.deinit();
    var diagnostics_rendered = false;
    defer if (!diagnostics_rendered) renderCollectedDiagnostics(allocator, &diagnostic_sink);
    var diagnostic_context = diagnostics.Context.structured(&diagnostic_sink);
    var args_list = std.array_list.Managed([]const u8).init(allocator);
    defer args_list.deinit();

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_it.deinit();
    while (args_it.next()) |arg| {
        try args_list.append(arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        std.debug.print("{s}", .{help.usage});
        return;
    }

    const command = args[1];
    if (isHelpCommand(command)) {
        std.debug.print("{s}", .{help.usage});
        return;
    }

    if (std.mem.eql(u8, command, "version")) {
        std.debug.print("cyna {s}\n", .{build_options.cyna_version});
        for (args[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--verbose")) std.debug.print("compiler-build: {s}\n", .{build_options.compiler_identity});
        }
        return;
    }

    if (std.mem.eql(u8, command, "lsp")) {
        process_exit_code = try lsp.run(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "fmt")) {
        if (argsRequestHelp(args[2..])) {
            std.debug.print("{s}", .{help.fmt_usage});
            return;
        }
        var paths: std.ArrayListUnmanaged([]const u8) = .empty;
        defer paths.deinit(allocator);
        var options: commands.fmt.Options = .{};
        var positional_only = false;
        for (args[2..]) |arg| {
            if (!positional_only and std.mem.eql(u8, arg, "--")) {
                positional_only = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--check")) {
                options.check = true;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "-")) {
                try diagnostic_context.emitPath(arg, "unknown fmt option");
                process_exit_code = 1;
                return;
            } else try paths.append(allocator, arg);
        }
        const outcome = try commands.fmt.formatPaths(allocator, paths.items, options, &diagnostic_context);
        if (outcome.failed != 0 or (options.check and outcome.changed != 0)) process_exit_code = 1;
        return;
    }

    if (std.mem.eql(u8, command, "build")) {
        const split = cli.splitPathAndArgs(args[2..]);
        if (argsRequestHelp(split.rest)) {
            std.debug.print("{s}", .{help.build_usage});
            return;
        }
        var options = build_mod.parseBuildOptions(split.rest) catch |err| {
            try diagnostic_context.emitPath(split.path orelse ".", @errorName(err));
            return err;
        };
        options.diagnostic_context = diagnostic_context;
        options.progress = true;
        std.debug.print("Building {s}\n", .{split.path orelse "."});
        build_mod.buildCommand(allocator, split.path, options) catch |err| {
            if (isReportedCommandFailure(err)) {
                process_exit_code = 1;
                return;
            }
            if (printInternalErrorTrace(allocator, &diagnostic_sink, &diagnostics_rendered, err)) {
                process_exit_code = 1;
                return;
            }
            if (diagnostic_sink.records.items.len != 0) {
                process_exit_code = 1;
                return;
            }
            return err;
        };
        return;
    }

    if (std.mem.eql(u8, command, "run")) {
        const split = cli.splitPathAndArgs(args[2..]);
        if (argsRequestHelp(split.rest)) {
            std.debug.print("{s}", .{help.run_usage});
            return;
        }
        var options = try cli.parseRunOptions(allocator, split.rest);
        defer allocator.free(options.argv);
        options.diagnostic_context = diagnostic_context;
        const exit_code = runCommand(allocator, split.path, options) catch |err| {
            if (isReportedCommandFailure(err)) {
                process_exit_code = 1;
                return;
            }
            if (printInternalErrorTrace(allocator, &diagnostic_sink, &diagnostics_rendered, err)) {
                process_exit_code = 1;
                return;
            }
            if (diagnostic_sink.records.items.len != 0) {
                process_exit_code = 1;
                return;
            }
            return err;
        };
        process_exit_code = exit_code;
        return;
    }

    if (std.mem.eql(u8, command, "install")) {
        const split = cli.splitPathAndArgs(args[2..]);
        if (argsRequestHelp(split.rest)) {
            std.debug.print("usage: cyna install [path]\n", .{});
            return;
        }
        if (split.rest.len != 0) {
            try diagnostic_context.emitPath(split.path orelse ".", "install does not accept extra options yet");
            return error.UnknownOption;
        }
        try installCommand(allocator, split.path, diagnostic_context);
        return;
    }

    if (std.mem.eql(u8, command, "clean")) {
        const split = cli.splitPathAndArgs(args[2..]);
        if (argsRequestHelp(split.rest)) {
            std.debug.print("usage: cyna clean [path]\n", .{});
            return;
        }
        if (split.rest.len != 0) {
            try diagnostic_context.emitPath(split.path orelse ".", "clean does not accept extra options yet");
            return error.UnknownOption;
        }
        try cleanCommand(allocator, split.path);
        return;
    }

    if (std.mem.eql(u8, command, "test")) {
        const split = cli.splitPathAndArgs(args[2..]);
        if (argsRequestHelp(split.rest)) {
            std.debug.print("{s}", .{help.test_usage});
            return;
        }
        var options = cli.parseTestOptions(split.rest) catch |err| {
            try diagnostic_context.emitPath(split.path orelse ".", @errorName(err));
            return err;
        };
        options.diagnostic_context = diagnostic_context;
        testCommand(allocator, split.path, options) catch |err| {
            if (printInternalErrorTrace(allocator, &diagnostic_sink, &diagnostics_rendered, err)) {
                process_exit_code = 1;
                return;
            }
            if (diagnostic_sink.records.items.len != 0) {
                process_exit_code = 1;
                return;
            }
            return err;
        };
        return;
    }

    if (std.mem.eql(u8, command, "package")) {
        if (args.len == 3 and isHelpCommand(args[2])) {
            std.debug.print("{s}", .{help.package_usage});
            return;
        }
        if (args.len < 3) {
            try diagnostic_context.emitPath(".", "package requires a subcommand");
            return error.UnknownOption;
        }
        if (std.mem.eql(u8, args[2], "build")) {
            const split = cli.splitPathAndArgs(args[3..]);
            if (argsRequestHelp(split.rest)) {
                std.debug.print("usage: cyna package build [path]\n", .{});
                return;
            }
            if (split.rest.len != 0) {
                try diagnostic_context.emitPath(split.path orelse ".", "package build does not accept extra options yet");
                return error.UnknownOption;
            }
            try package_mod.packageBuildCommandWithDiagnostics(allocator, split.path, diagnostic_context);
            return;
        }
        if (std.mem.eql(u8, args[2], "pack")) {
            const split = cli.splitPathAndArgs(args[3..]);
            if (argsRequestHelp(split.rest)) {
                std.debug.print("usage: cyna package pack [path]\n", .{});
                return;
            }
            if (split.rest.len != 0) {
                try diagnostic_context.emitPath(split.path orelse ".", "package pack does not accept extra options yet");
                return error.UnknownOption;
            }
            try packagePackCommand(allocator, split.path, diagnostic_context);
            return;
        }
        if (std.mem.eql(u8, args[2], "publish")) {
            const split = cli.splitPathAndArgs(args[3..]);
            if (argsRequestHelp(split.rest)) {
                std.debug.print("usage: cyna package publish [path]\n", .{});
                return;
            }
            if (split.rest.len != 0) {
                try diagnostic_context.emitPath(split.path orelse ".", "package publish does not accept extra options yet");
                return error.UnknownOption;
            }
            try package_mod.packagePublishCommandWithDiagnostics(allocator, split.path, diagnostic_context);
            return;
        }
        try diagnostic_context.emitPath(args[2], "unknown package subcommand");
        return error.UnknownOption;
    }

    if (std.mem.eql(u8, command, "check")) {
        const split = cli.splitPathAndArgs(args[2..]);
        if (argsRequestHelp(split.rest)) {
            std.debug.print("{s}", .{help.check_usage});
            return;
        }
        var options: CheckOptions = cli.parseCheckOptions(split.rest) catch |err| {
            try diagnostic_context.emitPath(split.path orelse ".", @errorName(err));
            return err;
        };
        options.progress = true;
        std.debug.print("Resolving check target...\n", .{});
        var outcome = try check_mod.checkCommand(allocator, split.path, options);
        defer outcome.deinit(allocator);
        switch (outcome) {
            .success => |success| {
                std.debug.print("{s}: ok ({d} functions)\n", .{ success.display_path, success.function_count });
            },
            .reported_failure => |text| {
                process_exit_code = 1;
                std.debug.print("{s}", .{text});
            },
        }
        return;
    }

    if (args.len < 3) {
        std.debug.print("{s}", .{help.usage});
        return;
    }

    std.debug.print("unknown command: {s}\n{s}", .{ command, help.usage });
}

fn renderCollectedDiagnostics(allocator: std.mem.Allocator, sink: *diagnostics.Sink) void {
    if (sink.records.items.len == 0) return;
    sink.normalize(.{}) catch {};
    var registry = diagnostic_sources.Registry.init(allocator);
    defer registry.deinit();
    diagnostic_renderer.hydrateFromDisk(&registry, sink.records.items);
    const rendered = diagnostic_renderer.renderAlloc(
        allocator,
        &registry,
        sink.records.items,
        .{ .mode = .human },
    ) catch {
        for (sink.records.items) |record| diagnostics.renderCompactStderr(record.asSpec());
        return;
    };
    defer allocator.free(rendered);
    std.debug.print("{s}", .{rendered});
}

fn isReportedCommandFailure(err: anyerror) bool {
    return switch (err) {
        error.NativeCompileFailed, error.NativeRunFailed, error.ProjectNotFound, error.InvalidManifest, error.UnsupportedTarget, error.ParseFailed, error.SemanticFailed, error.UnsupportedRunTarget => true,
        else => false,
    };
}

fn printInternalErrorTrace(allocator: std.mem.Allocator, sink: *diagnostics.Sink, rendered: *bool, err: anyerror) bool {
    for (sink.records.items) |record| {
        if (record.code != .internal_invariant) continue;
        renderCollectedDiagnostics(allocator, sink);
        rendered.* = true;
        std.debug.print("Zig error return trace [{s}]:\n", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpErrorReturnTrace(trace);
        } else {
            std.debug.print("  source trace unavailable in this compiler build\n", .{});
        }
        return true;
    }
    return false;
}

fn runCommand(allocator: std.mem.Allocator, input_path: ?[]const u8, options: RunOptions) !u8 {
    return run_mod.runCommand(allocator, input_path, options, .{
        .compileAndRunNativeExecutable = native_mod.compileAndRunNativeExecutableWithDiagnostics,
    });
}

fn cleanCommand(allocator: std.mem.Allocator, input_path: ?[]const u8) !void {
    return clean.cleanCommand(allocator, input_path);
}

fn installCommand(allocator: std.mem.Allocator, input_path: ?[]const u8, diagnostic_context: diagnostics.Context) !void {
    return install.installCommandWithDiagnostics(allocator, input_path, diagnostic_context);
}

fn testCommand(allocator: std.mem.Allocator, input_path: ?[]const u8, options: TestOptions) !void {
    return test_mod.testCommand(allocator, input_path, options, .{
        .compileAndRunInlineTests = native_mod.compileAndRunInlineTestsWithDiagnostics,
        .stripRootMainFunction = native_mod.stripRootMainFunction,
    });
}

fn packagePackCommand(allocator: std.mem.Allocator, input_path: ?[]const u8, diagnostic_context: diagnostics.Context) !void {
    return package_mod.packagePackCommandWithDiagnostics(allocator, input_path, diagnostic_context);
}

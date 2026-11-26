const std = @import("std");
const compat = @import("../compat.zig");
const distribution_paths = @import("../distribution_paths.zig");
const build_pkg = @import("../build.zig");
const install = @import("install.zig");
const llvm_backend = @import("../compiler/backend/llvm.zig");
const internal_error = @import("../compiler/internal_error.zig");
const diagnostics = @import("../compiler/diagnostics.zig");
const lexer = @import("../compiler/lexer/lexer.zig");
const loader = @import("../compiler/loader.zig");
const lower = @import("../compiler/lower/lower.zig");
const lir = @import("../compiler/lower/lir.zig");
const ast = @import("../compiler/parser/ast.zig");
const parser = @import("../compiler/parser/parser.zig");
const sir = @import("../compiler/sema/sir.zig");
const sema = @import("../compiler/sema/sema.zig");
const compilation = @import("../compiler/session.zig");
const module_build = @import("module_build.zig");

const native_mod = build_pkg.native;
const header_mod = build_pkg.header;
const build_model = build_pkg.model;
const ir_cache = build_pkg.ir_cache;

pub const BuildOptions = struct {
    diagnostic_context: diagnostics.Context = .{ .destination = .discard },
    emit_tok: bool = false,
    emit_ast: bool = false,
    emit_sir: bool = false,
    emit_lir: bool = false,
    emit_llvm: bool = false,
    emit_c_header: bool = false,
    emit_asm_include: bool = false,
    emit_obj: bool = false,
    emit_elf: bool = false,
    emit_bin: bool = false,
    emit_hex: bool = false,
    verbose: bool = false,
    progress: bool = false,
    timings: bool = false,
    jobs: usize = 0,
    output_path: ?[]const u8 = null,
    build_config: ?[]const u8 = null,
};

fn reportProgress(verbose: bool, comptime format: []const u8, args: anytype) void {
    if (verbose) std.debug.print(format, args);
}

pub fn buildCommand(allocator: std.mem.Allocator, input_path: ?[]const u8, options: BuildOptions) !void {
    var diagnostic_context = options.diagnostic_context;
    var session = try compilation.CompilationSession.init(allocator, options.timings);
    defer session.deinit();
    defer session.report() catch {};
    var invocation_span = session.start("compile", &.{});
    defer invocation_span.end();

    var install_span = invocation_span.child(&session, "install", &.{});
    try install.ensureInstalledWithDiagnostics(allocator, input_path, diagnostic_context);
    install_span.end();

    var resolve_span = invocation_span.child(&session, "resolve", &.{});
    defer resolve_span.end();
    reportProgress(options.verbose, "resolving build target...\n", .{});
    var target = try build_model.resolveBuildTargetForConfigWithDiagnostics(allocator, input_path, options.build_config, &diagnostic_context);
    defer target.deinit(allocator);
    resolve_span.end();
    if (options.progress) std.debug.print("Compiling {s}\n", .{target.display_path});
    reportProgress(options.verbose, "building {s}\n", .{target.display_path});

    const emit = mergedEmitOptions(target.emit, options);
    try build_model.validateEmitOptionsForTargetWithDiagnostics(target.display_path, target.target, emit, &diagnostic_context);
    const artifact_base_path = try target.artifactBasePath(allocator, options.output_path);
    defer allocator.free(artifact_base_path);

    if (emit.tok) {
        reportProgress(options.verbose, "lexing tokens...\n", .{});
        const source = compat.readFileAlloc(allocator, target.source_path, 16 * 1024 * 1024) catch |err| {
            try diagnostic_context.emitPath(target.source_path, @errorName(err));
            return err;
        };
        defer allocator.free(source);

        const token_text = try renderTokensText(allocator, target.source_path, source);
        defer allocator.free(token_text);
        try emitStageText(allocator, artifact_base_path, ".tok", "TOK", token_text);
    }

    reportProgress(options.verbose, "loading source modules...\n", .{});
    if (options.progress) std.debug.print("Loading source modules...\n", .{});
    var load_span = invocation_span.child(&session, "load", &.{});
    var loaded = try loader.loadProgramWithOptions(allocator, target.source_path, .{
        .progress = options.verbose,
        .diagnostic_context = diagnostic_context,
        .session = &session,
    });
    load_span.end();
    defer loaded.deinit(allocator);
    try attachDependencyCSources(allocator, &target, loaded, &diagnostic_context);
    reportProgress(options.verbose, "loaded {d} source modules\n", .{loaded.source_paths.len});

    if (emit.ast) {
        reportProgress(options.verbose, "rendering AST...\n", .{});
        const ast_text = try renderAstText(allocator, loaded.program);
        defer allocator.free(ast_text);
        try emitStageText(allocator, artifact_base_path, ".ast", "AST", ast_text);
    }

    reportProgress(options.verbose, "building SIR...\n", .{});
    if (options.progress) std.debug.print("Analyzing source...\n", .{});
    var sema_span = invocation_span.child(&session, "sema", &.{});
    const module = try sema.buildSirWithOptions(allocator, target.source_path, loaded.program, .{
        .target = target.target,
        .diagnostic_context = diagnostic_context,
        .timing_session = &session,
    });
    sema_span.end();
    defer module.deinit(allocator);
    reportProgress(options.verbose, "built SIR ({d} functions, {d} globals, {d} structs)\n", .{
        module.functions.len,
        module.globals.len,
        module.structs.len,
    });

    // Even a matching IR cache entry must not bypass current semantic checks.
    const can_use_llvm_cache = emit.llvm and !emit.tok and !emit.ast and !emit.sir and !emit.lir and
        !emit.c_header and !emit.asm_include and target.asm_sources.sources.len == 0;
    if (can_use_llvm_cache) {
        if (try ir_cache.load(allocator, target, loaded)) |cached_value| {
            var cached = cached_value;
            defer cached.deinit(allocator);
            reportProgress(options.verbose, "reusing cached LLVM module\n", .{});
            if (emit.llvm) try emitStageText(allocator, artifact_base_path, ".ll", "LLVM IR", cached.llvm_ir);
            if (!emitWritesNativeArtifact(emit)) return;

            const native_output_path = try target.nativeOutputPath(allocator, options.output_path);
            defer allocator.free(native_output_path);
            if (options.progress) std.debug.print("Generating native artifact...\n", .{});
            const link_native_artifact = !emit.obj or emit.elf or emit.bin or emit.hex;
            const wrote_native_artifact = try native_mod.compileNativeArtifact(
                allocator,
                cached.llvm_ir,
                cached.artifact_deps,
                target,
                emit.obj,
                link_native_artifact,
                artifact_base_path,
                native_output_path,
                .{ .verbose = options.verbose, .progress = options.progress, .jobs = options.jobs, .diagnostic_context = diagnostic_context },
            );
            if (wrote_native_artifact) {
                try native_mod.emitPostLinkArtifactsWithDiagnostics(allocator, target, emit, artifact_base_path, native_output_path, &diagnostic_context);
                std.debug.print("wrote native artifact to {s}\n", .{native_output_path});
            }
            return;
        }
    }

    const header_with_staticlib = target.output_kind == .staticlib and emit.c_header and
        !emit.tok and !emit.ast and !emit.sir and !emit.lir and !emit.llvm and
        !emit.asm_include and !emit.obj and !emit.elf and !emit.bin and !emit.hex;
    if (header_with_staticlib) {
        reportProgress(options.verbose, "rendering C header...\n", .{});
        const header_text = try header_mod.renderHeaderWithDiagnostics(allocator, target.source_path, loaded, &diagnostic_context);
        defer allocator.free(header_text);
        try emitStageText(allocator, artifact_base_path, ".h", "C HEADER", header_text);
        try emitRuntimeHeaderBundle(allocator, artifact_base_path);
    }
    const can_use_module_build = (header_with_staticlib or
        (emitWritesNativeArtifact(emit) and !emitHasTextStages(emit))) and
        target.asm_sources.sources.len == 0 and !emit.obj;
    if (can_use_module_build) {
        if (options.progress) std.debug.print("Generating native modules...\n", .{});
        const native_output_path = try target.nativeOutputPath(allocator, options.output_path);
        defer allocator.free(native_output_path);
        const wrote_native_artifact = try module_build.buildNativeModules(
            allocator,
            loaded,
            module,
            target,
            artifact_base_path,
            native_output_path,
            .{ .verbose = options.verbose, .progress = options.progress, .jobs = options.jobs, .diagnostic_context = diagnostic_context, .cache_emit = emit, .session = &session },
        );
        if (wrote_native_artifact) {
            try native_mod.emitPostLinkArtifactsWithDiagnostics(allocator, target, emit, artifact_base_path, native_output_path, &diagnostic_context);
            std.debug.print("wrote native artifact to {s}\n", .{native_output_path});
        }
        return;
    }

    if (emit.c_header and !header_with_staticlib) {
        reportProgress(options.verbose, "rendering C header...\n", .{});
        const header_text = try header_mod.renderHeaderWithDiagnostics(allocator, target.source_path, loaded, &diagnostic_context);
        defer allocator.free(header_text);
        try emitStageText(allocator, artifact_base_path, ".h", "C HEADER", header_text);
        try emitRuntimeHeaderBundle(allocator, artifact_base_path);
    }

    const should_emit_asm_include = emit.asm_include or (module.asm_consts.len != 0 and target.asm_sources.sources.len != 0 and emitWritesNativeArtifact(emit));
    var asm_include_path: ?[]u8 = null;
    defer if (asm_include_path) |path| allocator.free(path);
    if (should_emit_asm_include) {
        reportProgress(options.verbose, "rendering ASM include...\n", .{});
        const asm_include_text = try renderAsmIncludeText(allocator, module);
        defer allocator.free(asm_include_text);
        const path = try emittedArtifactPath(allocator, artifact_base_path, ".asm.inc");
        try writeTextFile(path, asm_include_text);
        std.debug.print("wrote ASM INCLUDE to {s}\n", .{path});
        asm_include_path = path;
    }

    if (emit.sir) {
        reportProgress(options.verbose, "rendering SIR...\n", .{});
        const sir_text = try renderSirText(allocator, module);
        defer allocator.free(sir_text);
        try emitStageText(allocator, artifact_base_path, ".sir", "SIR", sir_text);
    }

    if (!emitNeedsLir(emit)) return;

    const debug_source_map = try buildDebugSourceMap(allocator, loaded.module_names, loaded.source_paths);
    defer allocator.free(debug_source_map);

    reportProgress(options.verbose, "lowering to LIR...\n", .{});
    if (options.progress) std.debug.print("Lowering to LIR...\n", .{});
    var lower_span = invocation_span.child(&session, "lower", &.{});
    const lir_module = lower.lowerModuleWithOptions(allocator, module, .{
        .debug_source_map = debug_source_map,
        .fallback_source_path = target.source_path,
        .target = target.target,
    }) catch |err| {
        if (!try internal_error.emitSirIdentityFailure(diagnostic_context, module, debug_source_map, target.source_path, err))
            try internal_error.emitFailure(diagnostic_context, target.source_path, .sir_to_lir, err);
        return err;
    };
    lower_span.end();
    defer lir_module.deinit(allocator);
    reportProgress(options.verbose, "lowered LIR ({d} functions, {d} globals, {d} types)\n", .{
        lir_module.functions.len,
        lir_module.globals.len,
        lir_module.types.len,
    });

    if (emit.lir) {
        reportProgress(options.verbose, "rendering LIR...\n", .{});
        const lir_text = try renderLirText(allocator, lir_module);
        defer allocator.free(lir_text);
        try emitStageText(allocator, artifact_base_path, ".lir", "LIR", lir_text);
    }

    if (!emitNeedsLlvm(emit)) return;

    const artifact_deps = llvm_backend.moduleArtifactDeps(allocator, lir_module);
    reportProgress(options.verbose, "emitting LLVM IR...\n", .{});
    if (options.progress) std.debug.print("Emitting LLVM IR...\n", .{});
    var llvm_span = invocation_span.child(&session, "emit.llvm", &.{});
    const llvm_ir = llvm_backend.emitModule(allocator, lir_module) catch |err| {
        try internal_error.emitFailure(diagnostic_context, target.source_path, .lir_to_llvm, err);
        return err;
    };
    llvm_span.end();
    defer allocator.free(llvm_ir);
    reportProgress(options.verbose, "emitted LLVM IR ({d} bytes)\n", .{llvm_ir.len});

    if (can_use_llvm_cache) try ir_cache.store(allocator, target, loaded, llvm_ir, artifact_deps);

    if (emit.llvm) {
        try emitStageText(allocator, artifact_base_path, ".ll", "LLVM IR", llvm_ir);
    }

    if (!emitWritesNativeArtifact(emit)) return;

    if (asm_include_path) |path| {
        reportProgress(options.verbose, "configuring ASM include flags...\n", .{});
        try appendAsmIncludeFlags(allocator, &target, path);
    }

    const link_native_artifact = !emit.obj or emit.elf or emit.bin or emit.hex;
    const native_output_path = try target.nativeOutputPath(allocator, options.output_path);
    defer allocator.free(native_output_path);

    reportProgress(options.verbose, "building native artifact...\n", .{});
    if (options.progress) std.debug.print("Generating native artifact...\n", .{});
    var native_span = invocation_span.child(&session, "native", &.{});
    const wrote_native_artifact = try native_mod.compileNativeArtifact(
        allocator,
        llvm_ir,
        artifact_deps,
        target,
        emit.obj,
        link_native_artifact,
        artifact_base_path,
        native_output_path,
        .{ .verbose = options.verbose, .progress = options.progress, .jobs = options.jobs, .diagnostic_context = diagnostic_context },
    );
    native_span.end();
    if (wrote_native_artifact) {
        try native_mod.emitPostLinkArtifactsWithDiagnostics(allocator, target, emit, artifact_base_path, native_output_path, &diagnostic_context);
        std.debug.print("wrote native artifact to {s}\n", .{native_output_path});
    }
}

pub fn attachDependencyCSources(
    allocator: std.mem.Allocator,
    target: *build_model.BuildTarget,
    loaded: loader.LoadedProgram,
    diagnostic_context: *diagnostics.Context,
) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit(allocator);
    }
    var groups: std.ArrayListUnmanaged(build_model.NativeSourceOptions) = .empty;
    errdefer {
        for (groups.items) |*group| group.deinit(allocator);
        groups.deinit(allocator);
    }

    for (loaded.source_paths, loaded.module_names) |source_path, module_name| {
        if (std.mem.startsWith(u8, module_name, "std.")) continue;
        if (std.mem.startsWith(u8, source_path, target.root_dir) and
            source_path.len > target.root_dir.len and
            std.fs.path.isSep(source_path[target.root_dir.len])) continue;

        var directory = std.fs.path.dirname(source_path) orelse continue;
        while (true) {
            const manifest_path = try std.fs.path.join(allocator, &.{ directory, "cyna.toml" });
            defer allocator.free(manifest_path);
            const installed_manifest_path = try std.fs.path.join(allocator, &.{ directory, "manifest.toml" });
            defer allocator.free(installed_manifest_path);
            const selected_manifest = if (dependencyManifestExists(manifest_path))
                manifest_path
            else if (dependencyManifestExists(installed_manifest_path))
                installed_manifest_path
            else
                null;
            if (selected_manifest) |package_manifest| {
                if (!seen.contains(directory)) {
                    try seen.put(allocator, try allocator.dupe(u8, directory), {});
                    var dependency = try build_model.resolveBuildTargetForConfigWithDiagnostics(
                        allocator,
                        package_manifest,
                        null,
                        diagnostic_context,
                    );
                    defer dependency.deinit(allocator);
                    if (dependency.c_sources.sources.len != 0) {
                        try groups.append(allocator, dependency.c_sources);
                        dependency.c_sources = .{};
                    }
                }
                break;
            }
            const parent = std.fs.path.dirname(directory) orelse break;
            if (std.mem.eql(u8, parent, directory)) break;
            directory = parent;
        }
    }
    target.dependency_c_sources = try groups.toOwnedSlice(allocator);
}

fn dependencyManifestExists(path: []const u8) bool {
    compat.access(path, .{}) catch return false;
    return true;
}

pub fn parseBuildOptions(args: []const []const u8) !BuildOptions {
    var options: BuildOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--emit-tok")) {
            options.emit_tok = true;
        } else if (std.mem.eql(u8, arg, "--emit-ast")) {
            options.emit_ast = true;
        } else if (std.mem.eql(u8, arg, "--emit-sir")) {
            options.emit_sir = true;
        } else if (std.mem.eql(u8, arg, "--emit-lir")) {
            options.emit_lir = true;
        } else if (std.mem.eql(u8, arg, "--emit-ll") or std.mem.eql(u8, arg, "--emit-llvm")) {
            options.emit_llvm = true;
        } else if (std.mem.eql(u8, arg, "--emit-c-header")) {
            options.emit_c_header = true;
        } else if (std.mem.eql(u8, arg, "--emit-asm-include")) {
            options.emit_asm_include = true;
        } else if (std.mem.eql(u8, arg, "--emit-obj")) {
            options.emit_obj = true;
        } else if (std.mem.eql(u8, arg, "--emit-elf")) {
            options.emit_elf = true;
        } else if (std.mem.eql(u8, arg, "--emit-bin")) {
            options.emit_bin = true;
        } else if (std.mem.eql(u8, arg, "--emit-hex")) {
            options.emit_hex = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
        } else if (std.mem.eql(u8, arg, "--timings")) {
            options.timings = true;
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            options.jobs = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidOptionValue;
            if (options.jobs == 0) return error.InvalidOptionValue;
        } else if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            options.output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--build")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            options.build_config = args[i];
        } else {
            return error.UnknownOption;
        }
    }
    return options;
}

fn writeTypeName(writer: anytype, type_name: ast.TypeName) !void {
    if (type_name.is_ref) try writer.writeAll("&");
    if (type_name.is_optional) try writer.writeAll("?");
    if (type_name.is_slice) try writer.writeAll("[]");
    if (type_name.array_len) |len| try writer.print("[{d}]", .{len});
    if (type_name.slice_flags.item_is_optional) try writer.writeAll("?");
    if (std.mem.eql(u8, type_name.name, "[:]")) {
        try writer.writeAll("[:]");
        try writeTypeName(writer, type_name.args[0]);
        return;
    }
    try writer.print("{s}", .{type_name.name});
    if (type_name.args.len > 0) {
        try writer.writeAll("<");
        for (type_name.args, 0..) |arg, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeTypeName(writer, arg);
        }
        try writer.writeAll(">");
    }
}

fn mergedEmitOptions(base: build_model.EmitOptions, overrides: BuildOptions) build_model.EmitOptions {
    return .{
        .tok = base.tok or overrides.emit_tok,
        .ast = base.ast or overrides.emit_ast,
        .sir = base.sir or overrides.emit_sir,
        .lir = base.lir or overrides.emit_lir,
        .llvm = base.llvm or overrides.emit_llvm,
        .c_header = base.c_header or overrides.emit_c_header,
        .asm_include = base.asm_include or overrides.emit_asm_include,
        .obj = base.obj or overrides.emit_obj,
        .elf = base.elf or overrides.emit_elf,
        .bin = base.bin or overrides.emit_bin,
        .hex = base.hex or overrides.emit_hex,
    };
}

fn emitHasTextStages(emit: build_model.EmitOptions) bool {
    return emit.tok or emit.ast or emit.sir or emit.lir or emit.llvm or emit.c_header or emit.asm_include;
}

fn emitWritesNativeArtifact(emit: build_model.EmitOptions) bool {
    if (emit.obj or emit.elf or emit.bin or emit.hex) return true;
    return !emitHasTextStages(emit);
}

fn emitNeedsLlvm(emit: build_model.EmitOptions) bool {
    return emit.llvm or emitWritesNativeArtifact(emit);
}

fn emitNeedsLir(emit: build_model.EmitOptions) bool {
    return emit.lir or emitNeedsLlvm(emit);
}

fn appendAsmIncludeFlags(allocator: std.mem.Allocator, target: *build_model.BuildTarget, include_path: []const u8) !void {
    const old_flags = target.asm_sources.flags;
    var new_flags = try allocator.alloc([]const u8, old_flags.len + 2);
    errdefer allocator.free(new_flags);
    @memcpy(new_flags[0..old_flags.len], old_flags);
    new_flags[old_flags.len] = try allocator.dupe(u8, "-include");
    errdefer allocator.free(new_flags[old_flags.len]);
    new_flags[old_flags.len + 1] = try allocator.dupe(u8, include_path);
    allocator.free(old_flags);
    target.asm_sources.flags = new_flags;
}

fn emittedArtifactPath(allocator: std.mem.Allocator, base: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, suffix });
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

fn emitStageText(
    allocator: std.mem.Allocator,
    artifact_base_path: []const u8,
    suffix: []const u8,
    label: []const u8,
    text: []const u8,
) !void {
    const path = try emittedArtifactPath(allocator, artifact_base_path, suffix);
    defer allocator.free(path);
    try writeTextFile(path, text);
    std.debug.print("wrote {s} to {s}\n", .{ label, path });
}

fn emitRuntimeHeaderBundle(allocator: std.mem.Allocator, artifact_base_path: []const u8) !void {
    const source_path = try distribution_paths.sourcePath(allocator, "src/runtime/cyna.h");
    defer allocator.free(source_path);
    const runtime_header_text = try compat.readFileAlloc(allocator, source_path, 1 << 20);
    defer allocator.free(runtime_header_text);

    const artifact_dir = std.fs.path.dirname(artifact_base_path) orelse ".";
    const runtime_header_path = try std.fs.path.join(allocator, &.{ artifact_dir, "cyna.h" });
    defer allocator.free(runtime_header_path);

    try writeTextFile(runtime_header_path, runtime_header_text);
    std.debug.print("wrote C HEADER RUNTIME to {s}\n", .{runtime_header_path});
}

fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try compat.makePath(parent);
}

fn writeTextFile(path: []const u8, text: []const u8) !void {
    try ensureParentDir(path);
    const file = try compat.createFile(path, .{ .truncate = true });
    defer compat.closeFile(file);
    try compat.fileWriteAll(file, text);
}

fn renderTokensText(allocator: std.mem.Allocator, path: []const u8, source: []const u8) ![]u8 {
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var out_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    for (tokens) |token| {
        try out_writer.writer.print("{s}:{d}:{d}: {s} `{s}`\n", .{
            path,
            token.line,
            token.column,
            @tagName(token.tag),
            token.lexeme,
        });
    }
    out = out_writer.toArrayList();
    return out.toOwnedSlice(allocator);
}

pub fn renderAstText(allocator: std.mem.Allocator, program: ast.Program) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var out_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);

    try out_writer.writer.writeAll("ast-summary-v1\n");
    for (program.imports) |decl| {
        try out_writer.writer.print("import {s}", .{decl.path});
        if (decl.local_name) |local_name| try out_writer.writer.print(" as {s}", .{local_name});
        if (decl.items.len != 0) try out_writer.writer.print(" ({d} selected)", .{decl.items.len});
        try out_writer.writer.writeAll("\n");
    }
    for (program.globals) |global| {
        try out_writer.writer.print("{s}{s} {s}", .{
            if (global.is_pub) "pub " else "",
            if (global.is_mutable) "var" else "const",
            global.name,
        });
        if (global.type_name) |type_name| {
            try out_writer.writer.writeAll(": ");
            try writeTypeName(&out_writer.writer, type_name);
        }
        try out_writer.writer.writeAll("\n");
    }
    for (program.asm_consts) |decl| {
        try out_writer.writer.print("asm const {s}: ", .{decl.name});
        try writeTypeName(&out_writer.writer, decl.type_name);
        try out_writer.writer.writeAll("\n");
    }
    for (program.aliases) |alias| {
        try out_writer.writer.print("{s}type {s} = {s}", .{
            if (alias.is_pub) "pub " else "",
            alias.name,
            if (alias.is_distinct) "distinct " else "",
        });
        try writeTypeName(&out_writer.writer, alias.target);
        try out_writer.writer.writeAll("\n");
    }
    for (program.enums) |decl| {
        const kind = switch (decl.layout) {
            .normal => "enum",
            .c => "c enum",
            .flags => "flags",
        };
        try out_writer.writer.print("{s}{s} {s} ({d} cases)\n", .{
            if (decl.is_pub) "pub " else "",
            kind,
            decl.name,
            decl.cases.len,
        });
    }
    for (program.unions) |decl| {
        const item_count = if (decl.kind == .type_union) decl.variants.len else decl.fields.len;
        try out_writer.writer.print("{s}{s} {s} ({d} {s})\n", .{
            if (decl.is_pub) "pub " else "",
            if (decl.layout == .c) "c union" else "union",
            decl.name,
            item_count,
            if (decl.kind == .type_union) "variants" else "cases",
        });
    }
    for (program.protocols) |decl| {
        try out_writer.writer.print("{s}protocol {s} ({d} associated types, {d} methods)\n", .{
            if (decl.is_pub) "pub " else "",
            decl.name,
            decl.associated_types.len,
            decl.methods.len,
        });
    }
    for (program.impls) |decl| {
        try out_writer.writer.writeAll("impl ");
        if (decl.type_params.len != 0) {
            try out_writer.writer.writeByte('<');
            for (decl.type_params, 0..) |param, i| {
                if (i != 0) try out_writer.writer.writeAll(", ");
                if (param.is_const_value) try out_writer.writer.writeAll("const ");
                try out_writer.writer.writeAll(param.name);
                if (param.constraint) |constraint| {
                    try out_writer.writer.writeAll(": ");
                    try writeTypeName(&out_writer.writer, constraint);
                    for (param.extra_constraints) |extra| {
                        try out_writer.writer.writeAll(" & ");
                        try writeTypeName(&out_writer.writer, extra);
                    }
                }
            }
            try out_writer.writer.writeAll("> ");
        }
        try writeTypeName(&out_writer.writer, decl.type_name);
        try out_writer.writer.writeAll(": ");
        try writeTypeName(&out_writer.writer, decl.protocol_name);
        try out_writer.writer.writeAll("\n");
    }
    for (program.structs) |decl| {
        const kind = switch (decl.layout) {
            .normal => "struct",
            .c => "c struct",
            .@"packed" => "packed struct",
        };
        try out_writer.writer.print("{s}{s} {s} ({d} fields, {d} methods)\n", .{
            if (decl.is_pub) "pub " else "",
            kind,
            decl.name,
            decl.fields.len,
            decl.methods.len,
        });
    }
    for (program.functions) |function| {
        try out_writer.writer.print("{s}fn {s} ({d} params)", .{
            if (function.is_pub) "pub " else "",
            function.name,
            function.params.len,
        });
        if (function.return_type) |ret| {
            try out_writer.writer.writeAll(": ");
            try writeTypeName(&out_writer.writer, ret);
        }
        try out_writer.writer.print(" ({d} statements)\n", .{function.body.len});
    }
    for (program.tests) |inline_test| {
        try out_writer.writer.print("test \"{s}\" ({d} statements)\n", .{
            inline_test.name,
            inline_test.body.len,
        });
    }

    out = out_writer.toArrayList();
    return out.toOwnedSlice(allocator);
}

fn renderSirText(allocator: std.mem.Allocator, module: sir.Module) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var out_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    try module.dump(&out_writer.writer);
    out = out_writer.toArrayList();
    return out.toOwnedSlice(allocator);
}

fn renderAsmIncludeText(allocator: std.mem.Allocator, module: sir.Module) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var out_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    for (module.asm_consts) |asm_include| {
        try out_writer.writer.print(".equ {s}, {d}\n", .{ asm_include.name, asm_include.value });
    }
    out = out_writer.toArrayList();
    return out.toOwnedSlice(allocator);
}

fn renderLirText(allocator: std.mem.Allocator, lir_module: lir.Module) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var out_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    try lir_module.dump(&out_writer.writer);
    out = out_writer.toArrayList();
    return out.toOwnedSlice(allocator);
}

test "parse build options accepts emit flags and output" {
    const options = try parseBuildOptions(&.{
        "--emit-tok",
        "--emit-ast",
        "--emit-sir",
        "--emit-lir",
        "--emit-ll",
        "--emit-c-header",
        "--emit-asm-include",
        "--emit-obj",
        "--emit-elf",
        "--emit-bin",
        "--emit-hex",
        "--verbose",
        "--jobs",
        "3",
        "--output",
        "build/app",
    });
    try std.testing.expect(options.emit_tok);
    try std.testing.expect(options.emit_ast);
    try std.testing.expect(options.emit_sir);
    try std.testing.expect(options.emit_lir);
    try std.testing.expect(options.emit_llvm);
    try std.testing.expect(options.emit_c_header);
    try std.testing.expect(options.emit_asm_include);
    try std.testing.expect(options.emit_obj);
    try std.testing.expect(options.emit_elf);
    try std.testing.expect(options.emit_bin);
    try std.testing.expect(options.emit_hex);
    try std.testing.expect(options.verbose);
    try std.testing.expectEqual(@as(usize, 3), options.jobs);
    try std.testing.expectEqualStrings("build/app", options.output_path.?);
}

test "stage emits stop before later native stages" {
    const sir_only = build_model.EmitOptions{ .sir = true };
    try std.testing.expect(emitNeedsLir(sir_only) == false);
    try std.testing.expect(emitNeedsLlvm(sir_only) == false);
    try std.testing.expect(emitWritesNativeArtifact(sir_only) == false);

    const lir_only = build_model.EmitOptions{ .lir = true };
    try std.testing.expect(emitNeedsLir(lir_only));
    try std.testing.expect(emitNeedsLlvm(lir_only) == false);
    try std.testing.expect(emitWritesNativeArtifact(lir_only) == false);

    const llvm_only = build_model.EmitOptions{ .llvm = true };
    try std.testing.expect(emitNeedsLir(llvm_only));
    try std.testing.expect(emitNeedsLlvm(llvm_only));
    try std.testing.expect(emitWritesNativeArtifact(llvm_only) == false);
}

test "native artifact emits still drive native stages" {
    const no_emit = build_model.EmitOptions{};
    try std.testing.expect(emitNeedsLir(no_emit));
    try std.testing.expect(emitNeedsLlvm(no_emit));
    try std.testing.expect(emitWritesNativeArtifact(no_emit));

    const obj_only = build_model.EmitOptions{ .obj = true };
    try std.testing.expect(emitNeedsLir(obj_only));
    try std.testing.expect(emitNeedsLlvm(obj_only));
    try std.testing.expect(emitWritesNativeArtifact(obj_only));

    const hex_only = build_model.EmitOptions{ .hex = true };
    try std.testing.expect(emitNeedsLir(hex_only));
    try std.testing.expect(emitNeedsLlvm(hex_only));
    try std.testing.expect(emitWritesNativeArtifact(hex_only));
}

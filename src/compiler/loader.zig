const std = @import("std");
const ast = @import("parser/ast.zig");
const build_options = @import("build_options");
const compat = @import("../compat.zig");
const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer/lexer.zig");
const package_manifest = @import("package.zig");
const parser = @import("parser/parser.zig");
const compilation = @import("session.zig");

pub const LoadedProgram = struct {
    program: ast.Program,
    source_paths: [][]const u8,
    sources: [][]const u8,
    tokens: [][]const lexer.Token,
    module_names: [][]const u8,
    root_module_name: []const u8,

    pub fn deinit(self: LoadedProgram, allocator: std.mem.Allocator) void {
        self.program.deinit(allocator);
        for (self.source_paths) |source_path| allocator.free(source_path);
        allocator.free(self.source_paths);
        for (self.sources) |source| allocator.free(source);
        allocator.free(self.sources);
        for (self.tokens) |tokens| allocator.free(tokens);
        allocator.free(self.tokens);
        for (self.module_names) |module_name| allocator.free(module_name);
        allocator.free(self.module_names);
        allocator.free(self.root_module_name);
    }

    pub fn testFriendModule(self: LoadedProgram, allocator: std.mem.Allocator, root_path: []const u8) !?[]const u8 {
        const suffix = ".test.cy";
        if (!std.mem.endsWith(u8, root_path, suffix)) return null;
        const sibling_path = try std.fmt.allocPrint(allocator, "{s}.cy", .{root_path[0 .. root_path.len - suffix.len]});
        defer allocator.free(sibling_path);
        const canonical_sibling = try compat.cwdRealpathAlloc(allocator, sibling_path);
        defer allocator.free(canonical_sibling);

        for (self.source_paths, self.module_names) |source_path, module_name| {
            if (std.mem.eql(u8, source_path, canonical_sibling)) return module_name;
        }
        return null;
    }
};

pub const LoadOptions = struct {
    progress: bool = false,
    allow_test_root: bool = false,
    diagnostic_context: diagnostics.Context = .{ .destination = .discard },
    session: ?*compilation.CompilationSession = null,
    dependency_observer: ?DependencyObserver = null,
    source_overlay: ?SourceOverlay = null,
};

pub const DependencyObserver = struct {
    context: *anyopaque,
    recordFn: *const fn (context: *anyopaque, path: []const u8) anyerror!void,

    pub fn record(self: DependencyObserver, path: []const u8) !void {
        try self.recordFn(self.context, path);
    }
};

pub const SourceOverlay = struct {
    context: *anyopaque,
    getFn: *const fn (context: *anyopaque, canonical_path: []const u8) ?[]const u8,

    pub fn get(self: SourceOverlay, canonical_path: []const u8) ?[]const u8 {
        return self.getFn(self.context, canonical_path);
    }
};

pub fn loadProgram(allocator: std.mem.Allocator, root_path: []const u8) !LoadedProgram {
    return loadProgramWithRootSource(allocator, root_path, null);
}

pub fn loadProgramWithOptions(allocator: std.mem.Allocator, root_path: []const u8, options: LoadOptions) !LoadedProgram {
    return loadProgramWithRootSourceOptions(allocator, root_path, null, options);
}

pub fn loadProgramWithRootSource(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    root_source: ?[]const u8,
) !LoadedProgram {
    return loadProgramWithRootSourceOptions(allocator, root_path, root_source, .{});
}

pub fn loadProgramWithRootSourceOptions(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    root_source: ?[]const u8,
    options: LoadOptions,
) !LoadedProgram {
    var diagnostic_context = options.diagnostic_context;
    if (std.mem.endsWith(u8, root_path, ".test.cy") and !options.allow_test_root) {
        try diagnostic_context.emitPath(root_path, "test files can only be compiled as roots by `cyna test`");
        return error.TestRootRequired;
    }
    const root_dir = std.fs.path.dirname(root_path) orelse ".";
    const canonical_entry_dir = try compat.cwdRealpathAlloc(allocator, root_dir);
    defer allocator.free(canonical_entry_dir);
    const canonical_root_path = try compat.cwdRealpathAlloc(allocator, root_path);
    defer allocator.free(canonical_root_path);
    const manifest_root_dir = try discoverManifestRoot(allocator, canonical_root_path);
    defer if (manifest_root_dir) |dir| allocator.free(dir);
    const root_package_source_root = if (manifest_root_dir) |dir|
        try discoverPackageSourceRoot(allocator, dir, diagnostic_context)
    else
        try allocator.dupe(u8, canonical_entry_dir);
    defer allocator.free(root_package_source_root);
    const root_module_name = try deriveModuleName(allocator, root_package_source_root, canonical_root_path);
    errdefer allocator.free(root_module_name);
    var state = State{
        .allocator = allocator,
        .diagnostic_context = diagnostic_context,
        .root_package = .{
            .name = try allocator.dupe(u8, ""),
            .root_dir = try allocator.dupe(u8, root_package_source_root),
        },
        .manifest_root_dir = if (manifest_root_dir) |dir| try allocator.dupe(u8, dir) else null,
        .bundled_modules = try loadBundledModules(allocator),
        .dependencies = try loadDependencies(allocator, manifest_root_dir, diagnostic_context),
        .source_paths = .empty,
        .sources = .empty,
        .tokens = .empty,
        .module_names = .empty,
        .module_infos = .empty,
        .globals = .empty,
        .asm_consts = .empty,
        .aliases = .empty,
        .enums = .empty,
        .unions = .empty,
        .protocols = .empty,
        .impls = .empty,
        .structs = .empty,
        .functions = .empty,
        .tests = .empty,
        .visited_paths = .empty,
        .root_overlay_path = if (root_source != null) try allocator.dupe(u8, canonical_root_path) else null,
        .root_overlay_source = root_source,
        .progress = options.progress,
        .session = options.session,
        .dependency_observer = options.dependency_observer,
        .source_overlay = options.source_overlay,
    };
    errdefer state.deinit();

    for (state.bundled_modules) |module| {
        if (!module.autoload) continue;
        _ = try state.loadBundledModule(module.module_name);
    }
    if (options.allow_test_root) {
        _ = try state.loadBundledModule("std.testing");
    }

    try state.loadFile(root_path, null);

    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = try allocator.alloc(ast.ImportDecl, 0),
        .module_infos = try state.module_infos.toOwnedSlice(allocator),
        .globals = try state.globals.toOwnedSlice(allocator),
        .asm_consts = try state.asm_consts.toOwnedSlice(allocator),
        .aliases = try state.aliases.toOwnedSlice(allocator),
        .enums = try state.enums.toOwnedSlice(allocator),
        .unions = try state.unions.toOwnedSlice(allocator),
        .protocols = try state.protocols.toOwnedSlice(allocator),
        .impls = try state.impls.toOwnedSlice(allocator),
        .structs = try state.structs.toOwnedSlice(allocator),
        .functions = try state.functions.toOwnedSlice(allocator),
        .tests = try state.tests.toOwnedSlice(allocator),
    };

    for (state.visited_paths.items) |path| allocator.free(path);
    state.visited_paths.deinit(allocator);
    allocator.free(state.root_package.name);
    allocator.free(state.root_package.root_dir);
    if (state.manifest_root_dir) |dir| allocator.free(dir);
    for (state.bundled_modules) |module| module.deinit(allocator);
    allocator.free(state.bundled_modules);
    for (state.dependencies) |dep| dep.deinit(allocator);
    allocator.free(state.dependencies);
    if (state.root_overlay_path) |path| allocator.free(path);

    return .{
        .program = program,
        .source_paths = try state.source_paths.toOwnedSlice(allocator),
        .sources = try state.sources.toOwnedSlice(allocator),
        .tokens = try state.tokens.toOwnedSlice(allocator),
        .module_names = try state.module_names.toOwnedSlice(allocator),
        .root_module_name = root_module_name,
    };
}

const State = struct {
    const Package = struct {
        name: []const u8,
        root_dir: []const u8,
    };

    // Bundled packages are shipped with the compiler distribution rather than
    // discovered through project dependencies.
    const BundledModule = package_manifest.PackageModule;

    const Dependency = struct {
        name: []const u8,
        root_dir: []const u8,
        source_root: []const u8,

        fn deinit(self: Dependency, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.root_dir);
            allocator.free(self.source_root);
        }
    };

    const PackageId = enum {
        root,
        bundled,
        dependency,
    };

    const ResolvedImport = struct {
        package: PackageId,
        source_path: []const u8,
    };

    allocator: std.mem.Allocator,
    diagnostic_context: diagnostics.Context,
    root_package: Package,
    manifest_root_dir: ?[]const u8,
    bundled_modules: []BundledModule,
    dependencies: []Dependency,
    source_paths: std.ArrayListUnmanaged([]const u8),
    sources: std.ArrayListUnmanaged([]const u8),
    tokens: std.ArrayListUnmanaged([]const lexer.Token),
    module_names: std.ArrayListUnmanaged([]const u8),
    module_infos: std.ArrayListUnmanaged(ast.ModuleInfo),
    globals: std.ArrayListUnmanaged(ast.Global),
    asm_consts: std.ArrayListUnmanaged(ast.AsmConst),
    aliases: std.ArrayListUnmanaged(ast.TypeAlias),
    enums: std.ArrayListUnmanaged(ast.EnumDecl),
    unions: std.ArrayListUnmanaged(ast.UnionDecl),
    protocols: std.ArrayListUnmanaged(ast.ProtocolDecl),
    impls: std.ArrayListUnmanaged(ast.ImplDecl),
    structs: std.ArrayListUnmanaged(ast.StructDecl),
    functions: std.ArrayListUnmanaged(ast.Function),
    tests: std.ArrayListUnmanaged(ast.InlineTest),
    visited_paths: std.ArrayListUnmanaged([]const u8),
    root_overlay_path: ?[]const u8,
    root_overlay_source: ?[]const u8,
    progress: bool,
    session: ?*compilation.CompilationSession,
    dependency_observer: ?DependencyObserver,
    source_overlay: ?SourceOverlay,

    fn deinit(self: *State) void {
        for (self.aliases.items) |alias| alias.deinit(self.allocator);
        self.aliases.deinit(self.allocator);
        for (self.enums.items) |decl| decl.deinit(self.allocator);
        self.enums.deinit(self.allocator);
        for (self.unions.items) |decl| decl.deinit(self.allocator);
        self.unions.deinit(self.allocator);
        for (self.protocols.items) |decl| decl.deinit(self.allocator);
        self.protocols.deinit(self.allocator);
        for (self.impls.items) |decl| decl.deinit(self.allocator);
        self.impls.deinit(self.allocator);
        for (self.structs.items) |decl| decl.deinit(self.allocator);
        self.structs.deinit(self.allocator);
        for (self.functions.items) |function| function.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        for (self.tests.items) |inline_test| inline_test.deinit(self.allocator);
        self.tests.deinit(self.allocator);
        for (self.source_paths.items) |source_path| self.allocator.free(source_path);
        self.source_paths.deinit(self.allocator);
        for (self.sources.items) |source| self.allocator.free(source);
        self.sources.deinit(self.allocator);
        for (self.tokens.items) |tokens| self.allocator.free(tokens);
        self.tokens.deinit(self.allocator);
        for (self.module_names.items) |module_name| self.allocator.free(module_name);
        self.module_names.deinit(self.allocator);
        self.allocator.free(self.root_package.name);
        self.allocator.free(self.root_package.root_dir);
        if (self.manifest_root_dir) |dir| self.allocator.free(dir);
        for (self.bundled_modules) |module| module.deinit(self.allocator);
        self.allocator.free(self.bundled_modules);
        for (self.dependencies) |dep| dep.deinit(self.allocator);
        self.allocator.free(self.dependencies);
        for (self.module_infos.items) |info| info.deinit(self.allocator);
        self.module_infos.deinit(self.allocator);
        for (self.globals.items) |global| global.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        for (self.asm_consts.items) |asm_const| asm_const.deinit(self.allocator);
        self.asm_consts.deinit(self.allocator);
        for (self.visited_paths.items) |path| self.allocator.free(path);
        self.visited_paths.deinit(self.allocator);
        if (self.root_overlay_path) |path| self.allocator.free(path);
    }

    fn reportProgress(self: State, comptime format: []const u8, args: anytype) void {
        if (self.progress) std.debug.print(format, args);
    }

    fn loadFile(self: *State, path: []const u8, expected_module_name: ?[]const u8) !void {
        const canonical_path = try compat.cwdRealpathAlloc(self.allocator, path);
        var canonical_owned = false;
        errdefer if (!canonical_owned) self.allocator.free(canonical_path);

        const module_name = if (expected_module_name) |expected|
            try self.allocator.dupe(u8, expected)
        else
            try deriveModuleName(self.allocator, self.root_package.root_dir, canonical_path);
        errdefer self.allocator.free(module_name);

        for (self.visited_paths.items) |visited| {
            if (std.mem.eql(u8, visited, canonical_path)) {
                self.allocator.free(module_name);
                self.allocator.free(canonical_path);
                return;
            }
        }

        if (self.hasModuleInfo(module_name)) {
            if (self.isBundledModuleName(module_name)) {
                self.allocator.free(module_name);
                self.allocator.free(canonical_path);
                return;
            }
            self.allocator.free(module_name);
            try self.diagnostic_context.emitPath(path, "duplicate module name");
            return error.ParseFailed;
        }
        try self.visited_paths.append(self.allocator, canonical_path);
        canonical_owned = true;
        if (self.dependency_observer) |observer| try observer.record(canonical_path);

        self.reportProgress("loading module {s} from {s}\n", .{ module_name, canonical_path });
        const source = if (self.root_overlay_path) |overlay_path| blk: {
            if (std.mem.eql(u8, canonical_path, overlay_path)) {
                break :blk try self.allocator.dupe(u8, self.root_overlay_source.?);
            }
            if (self.source_overlay) |overlay| {
                if (overlay.get(canonical_path)) |overlay_source| {
                    break :blk try self.allocator.dupe(u8, overlay_source);
                }
            }
            break :blk self.readSource(canonical_path) catch |err| {
                try self.diagnostic_context.emitPath(canonical_path, @errorName(err));
                return err;
            };
        } else if (self.source_overlay) |overlay| blk: {
            if (overlay.get(canonical_path)) |overlay_source| {
                break :blk try self.allocator.dupe(u8, overlay_source);
            }
            break :blk self.readSource(canonical_path) catch |err| {
                try self.diagnostic_context.emitPath(canonical_path, @errorName(err));
                return err;
            };
        } else self.readSource(canonical_path) catch |err| {
            try self.diagnostic_context.emitPath(canonical_path, @errorName(err));
            return err;
        };

        try self.loadResolvedSource(module_name, canonical_path, source);
    }

    fn ownModuleName(self: *State, value: []const u8) ![]const u8 {
        return self.allocator.dupe(u8, value);
    }

    fn loadBundledModule(self: *State, module_name: []const u8) !bool {
        const source_path = try self.resolveBundledImport(module_name) orelse return false;
        defer self.allocator.free(source_path);
        if (self.hasModuleInfo(module_name)) return true;
        try self.loadFile(source_path, module_name);
        return true;
    }

    fn loadResolvedSource(
        self: *State,
        module_name: []const u8,
        source_name: []const u8,
        source: []const u8,
    ) anyerror!void {
        var source_owned = false;
        errdefer if (!source_owned) self.allocator.free(source);
        self.reportProgress("lexing module {s}\n", .{module_name});
        const tokens = (if (self.session) |session|
            session.lexSource(source_name, source)
        else
            lexer.lexAll(self.allocator, source)) catch |err| {
            try self.diagnostic_context.emitPath(source_name, @errorName(err));
            return err;
        };
        var tokens_owned = false;
        errdefer if (!tokens_owned) self.allocator.free(tokens);

        self.reportProgress("parsing module {s}\n", .{module_name});
        var program = try parser.parseWithDiagnostics(self.allocator, source_name, source, tokens, &self.diagnostic_context);
        errdefer program.deinit(self.allocator);
        if (program.tests.len != 0 and !std.mem.endsWith(u8, source_name, ".test.cy")) {
            try self.diagnostic_context.emitPath(source_name, "test blocks are only allowed in *.test.cy files");
            return error.TestBlockOutsideTestFile;
        }

        for (program.imports) |decl| {
            const resolved = try self.resolveImport(source_name, decl);
            defer self.allocator.free(resolved.source_path);
            if (self.dependency_observer) |observer| try observer.record(resolved.source_path);
            try self.validateResolvedImport(source_name, decl, resolved);
            switch (resolved.package) {
                .bundled => try self.loadFile(resolved.source_path, decl.path),
                .dependency => try self.loadFile(resolved.source_path, decl.path),
                .root => try self.loadFile(resolved.source_path, decl.path),
            }
        }

        try self.adoptParsedProgram(module_name, source_name, source, tokens, &program);
        self.reportProgress("loaded module {s}\n", .{module_name});
        source_owned = true;
        tokens_owned = true;
    }

    fn readSource(self: *State, canonical_path: []const u8) ![]u8 {
        if (self.session) |session| {
            return session.loadSource(canonical_path, 16 * 1024 * 1024);
        }
        return compat.readFileAlloc(self.allocator, canonical_path, 16 * 1024 * 1024);
    }

    fn adoptParsedProgram(
        self: *State,
        module_name: []const u8,
        source_name: []const u8,
        source: []const u8,
        tokens: []const lexer.Token,
        program: *ast.Program,
    ) !void {
        errdefer self.allocator.free(module_name);
        const owned_source_name = try self.allocator.dupe(u8, source_name);
        errdefer self.allocator.free(owned_source_name);
        var imported_modules: std.ArrayListUnmanaged(ast.ImportDecl) = .empty;
        errdefer {
            for (imported_modules.items) |decl| decl.deinit(self.allocator);
            imported_modules.deinit(self.allocator);
        }
        for (program.imports) |decl| {
            try imported_modules.append(self.allocator, try self.dupImportDecl(decl));
        }
        try self.module_infos.append(self.allocator, .{
            .name = module_name,
            .source_path = owned_source_name,
            .autoload = self.isAutoloadModuleName(module_name),
            .compiler_owned = self.isBundledModuleSource(module_name, source_name),
            .imports = try imported_modules.toOwnedSlice(self.allocator),
        });

        try self.source_paths.append(self.allocator, owned_source_name);
        try self.module_names.append(self.allocator, module_name);
        try self.sources.append(self.allocator, source);
        try self.tokens.append(self.allocator, tokens);

        for (program.aliases) |*alias| alias.module_name = module_name;
        for (program.globals) |*global| global.module_name = module_name;
        for (program.asm_consts) |*asm_const| asm_const.module_name = module_name;
        for (program.enums) |*decl| decl.module_name = module_name;
        for (program.unions) |*decl| decl.module_name = module_name;
        for (program.protocols) |*decl| decl.module_name = module_name;
        for (program.impls) |*decl| {
            decl.module_name = module_name;
            for (decl.methods) |*method| method.module_name = module_name;
        }
        for (program.structs) |*decl| {
            decl.module_name = module_name;
            for (decl.methods) |*method| method.module_name = module_name;
        }
        for (program.functions) |*function| function.module_name = module_name;
        for (program.tests) |*inline_test| inline_test.module_name = module_name;

        try self.globals.appendSlice(self.allocator, program.globals);
        try self.asm_consts.appendSlice(self.allocator, program.asm_consts);
        try self.aliases.appendSlice(self.allocator, program.aliases);
        try self.enums.appendSlice(self.allocator, program.enums);
        try self.unions.appendSlice(self.allocator, program.unions);
        try self.protocols.appendSlice(self.allocator, program.protocols);
        try self.impls.appendSlice(self.allocator, program.impls);
        try self.structs.appendSlice(self.allocator, program.structs);
        try self.functions.appendSlice(self.allocator, program.functions);
        try self.tests.appendSlice(self.allocator, program.tests);

        const global_buf = program.globals;
        const asm_consts_buf = program.asm_consts;
        const alias_buf = program.aliases;
        const enum_buf = program.enums;
        const union_buf = program.unions;
        const protocol_buf = program.protocols;
        const impl_buf = program.impls;
        const struct_buf = program.structs;
        const function_buf = program.functions;
        const test_buf = program.tests;
        const module_info_buf = program.module_infos;
        program.globals = &.{};
        program.asm_consts = &.{};
        program.aliases = &.{};
        program.enums = &.{};
        program.unions = &.{};
        program.protocols = &.{};
        program.impls = &.{};
        program.structs = &.{};
        program.functions = &.{};
        program.tests = &.{};
        program.module_infos = &.{};
        self.allocator.free(global_buf);
        self.allocator.free(asm_consts_buf);
        self.allocator.free(alias_buf);
        self.allocator.free(enum_buf);
        self.allocator.free(union_buf);
        self.allocator.free(protocol_buf);
        self.allocator.free(impl_buf);
        self.allocator.free(struct_buf);
        self.allocator.free(function_buf);
        self.allocator.free(test_buf);
        for (module_info_buf) |info| info.deinit(self.allocator);
        self.allocator.free(module_info_buf);

        for (program.imports) |decl| decl.deinit(self.allocator);
        self.allocator.free(program.imports);
        program.imports = &.{};
    }

    fn hasModuleInfo(self: *State, module_name: []const u8) bool {
        for (self.module_infos.items) |info| {
            if (std.mem.eql(u8, info.name, module_name)) return true;
        }
        return false;
    }

    fn dupImportDecl(self: *State, decl: ast.ImportDecl) !ast.ImportDecl {
        var items = try self.allocator.alloc(ast.ImportItem, decl.items.len);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| {
                item.deinit(self.allocator);
            }
            self.allocator.free(items);
        }
        for (decl.items, 0..) |item, i| {
            items[i] = .{
                .name = item.name,
                .local_name = if (item.local_name) |local_name| try self.allocator.dupe(u8, local_name) else null,
                .name_token = item.name_token,
            };
            initialized = i + 1;
        }
        return .{
            .path = try self.allocator.dupe(u8, decl.path),
            .is_root_package = decl.is_root_package,
            .local_name = if (decl.local_name) |local_name| try self.allocator.dupe(u8, local_name) else null,
            .items = items,
            .path_token = decl.path_token,
        };
    }

    fn resolveImport(self: *State, source_name: []const u8, decl: ast.ImportDecl) !ResolvedImport {
        if (decl.is_root_package) {
            if (try self.dependencyForSource(source_name)) |dep| {
                return .{
                    .package = .dependency,
                    .source_path = try resolveImportPath(self.allocator, dep.source_root, decl.path),
                };
            }
        }
        if (!decl.is_root_package) {
            if (try self.resolveBundledImport(decl.path)) |path| {
                return .{
                    .package = .bundled,
                    .source_path = path,
                };
            }
            if (try self.resolveDependencyImport(decl.path)) |path| {
                return .{
                    .package = .dependency,
                    .source_path = path,
                };
            }
            if (self.manifest_root_dir != null) {
                try self.diagnostic_context.emitToken(source_name, decl.path_token, "manifest-based projects must use `import .foo.bar;` for self-package modules\nnote: current source root is `{s}`\nhelp: write `import .{s};` for a self-package module, or add the package as a dependency", .{
                    self.root_package.root_dir,
                    decl.path,
                });
                return error.ParseFailed;
            }
        }

        return .{
            .package = .root,
            // Compatibility fallback: until dependency manifests exist, bare
            // non-dependency imports still resolve from the root package.
            .source_path = try resolveImportPath(self.allocator, self.root_package.root_dir, decl.path),
        };
    }

    fn dependencyForSource(self: *State, source_name: []const u8) !?Dependency {
        for (self.dependencies) |dep| {
            const canonical_root = try compat.cwdRealpathAlloc(self.allocator, dep.source_root);
            defer self.allocator.free(canonical_root);
            if (std.mem.startsWith(u8, source_name, canonical_root) and
                source_name.len > canonical_root.len and
                std.fs.path.isSep(source_name[canonical_root.len])) return dep;
        }
        return null;
    }

    fn resolveBundledImport(self: *State, module_name: []const u8) !?[]const u8 {
        for (self.bundled_modules) |module| {
            if (std.mem.eql(u8, module.module_name, module_name)) {
                return try self.allocator.dupe(u8, module.path);
            }
        }
        return null;
    }

    fn isBundledModuleName(self: *State, module_name: []const u8) bool {
        for (self.bundled_modules) |module| {
            if (std.mem.eql(u8, module.module_name, module_name)) return true;
        }
        return false;
    }

    fn isBundledModuleSource(self: *State, module_name: []const u8, source_path: []const u8) bool {
        for (self.bundled_modules) |module| {
            if (!std.mem.eql(u8, module.module_name, module_name)) continue;
            const canonical = compat.cwdRealpathAlloc(self.allocator, module.path) catch return false;
            defer self.allocator.free(canonical);
            return std.mem.eql(u8, canonical, source_path);
        }
        return false;
    }

    fn isAutoloadModuleName(self: *State, module_name: []const u8) bool {
        for (self.bundled_modules) |module| {
            if (module.autoload and std.mem.eql(u8, module.module_name, module_name)) return true;
        }
        return false;
    }

    fn resolveDependencyImport(self: *State, import_path: []const u8) !?[]const u8 {
        const dot_index = std.mem.indexOfScalar(u8, import_path, '.') orelse return null;
        const package_name = import_path[0..dot_index];
        const module_path = import_path[dot_index + 1 ..];
        if (module_path.len == 0) return null;

        for (self.dependencies) |dep| {
            if (!std.mem.eql(u8, dep.name, package_name)) continue;
            const path = try resolveImportPath(self.allocator, dep.source_root, module_path);
            return path;
        }
        return null;
    }

    fn validateResolvedImport(self: *State, source_name: []const u8, decl: ast.ImportDecl, resolved: ResolvedImport) !void {
        if (!pathExists(resolved.source_path)) {
            try self.printUnresolvedImport(source_name, decl, resolved.source_path);
            return error.ParseFailed;
        }
        if (isDirectoryPath(resolved.source_path)) {
            try self.diagnostic_context.emitToken(source_name, decl.path_token, "import `{s}` resolved to a directory\nnote: attempted path `{s}`\nhelp: imports must resolve to a `.cy` source file", .{
                decl.path,
                resolved.source_path,
            });
            return error.ParseFailed;
        }
    }

    fn printUnresolvedImport(self: *State, source_name: []const u8, decl: ast.ImportDecl, attempted_path: []const u8) !void {
        if (decl.is_root_package or self.manifest_root_dir != null) {
            try self.diagnostic_context.emitToken(source_name, decl.path_token, "unresolved import `{s}`\nnote: attempted path `{s}`\nnote: current source root is `{s}`", .{
                decl.path,
                attempted_path,
                self.root_package.root_dir,
            });
            return;
        }
        try self.diagnostic_context.emitToken(source_name, decl.path_token, "unresolved import `{s}`\nnote: attempted path `{s}`", .{
            decl.path,
            attempted_path,
        });
    }
};

fn resolveImportPath(allocator: std.mem.Allocator, root_dir: []const u8, import_path: []const u8) ![]const u8 {
    const rel = try dottedPathToFsPath(allocator, import_path);
    defer allocator.free(rel);

    const direct = try std.fs.path.join(allocator, &.{ root_dir, rel });
    defer allocator.free(direct);
    return std.mem.concat(allocator, u8, &.{ direct, ".cy" });
}

fn resolvePathAgainstRoot(allocator: std.mem.Allocator, root_dir: []const u8, value: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(value)) return allocator.dupe(u8, value);
    return std.fs.path.join(allocator, &.{ root_dir, value });
}

fn dottedPathToFsPath(allocator: std.mem.Allocator, dotted: []const u8) ![]const u8 {
    const out = try allocator.dupe(u8, dotted);
    for (out) |*ch| {
        if (ch.* == '.') ch.* = std.fs.path.sep;
    }
    return out;
}

fn deriveModuleName(allocator: std.mem.Allocator, root_dir: []const u8, canonical_path: []const u8) ![]const u8 {
    const relative = compat.relativeAlloc(allocator, root_dir, canonical_path) catch try allocator.dupe(u8, std.fs.path.basename(canonical_path));
    defer allocator.free(relative);

    const without_ext = if (std.mem.endsWith(u8, relative, ".cy"))
        relative[0 .. relative.len - 3]
    else
        relative;

    const out = try allocator.dupe(u8, without_ext);
    for (out) |*ch| {
        if (ch.* == '/' or ch.* == '\\') ch.* = '.';
    }
    return out;
}

fn discoverManifestRoot(allocator: std.mem.Allocator, canonical_root_path: []const u8) !?[]const u8 {
    var current_dir = blk: {
        const parent = std.fs.path.dirname(canonical_root_path) orelse ".";
        break :blk try allocator.dupe(u8, parent);
    };
    errdefer allocator.free(current_dir);

    while (true) {
        const manifest_path = try std.fs.path.join(allocator, &.{ current_dir, "cyna.toml" });
        defer allocator.free(manifest_path);
        if (pathExists(manifest_path)) return current_dir;

        const parent = std.fs.path.dirname(current_dir) orelse break;
        if (std.mem.eql(u8, parent, current_dir)) break;
        const next_dir = try allocator.dupe(u8, parent);
        allocator.free(current_dir);
        current_dir = next_dir;
    }

    allocator.free(current_dir);
    return null;
}

fn loadBundledModules(allocator: std.mem.Allocator) ![]State.BundledModule {
    return package_manifest.loadBundledModules(allocator);
}

fn loadDependencies(
    allocator: std.mem.Allocator,
    manifest_root_dir: ?[]const u8,
    diagnostic_context: diagnostics.Context,
) ![]State.Dependency {
    return loadDependenciesWithHome(allocator, manifest_root_dir, null, diagnostic_context);
}

fn loadDependenciesWithHome(
    allocator: std.mem.Allocator,
    manifest_root_dir: ?[]const u8,
    home_override: ?[]const u8,
    diagnostic_context: diagnostics.Context,
) ![]State.Dependency {
    const root_dir = manifest_root_dir orelse return allocator.alloc(State.Dependency, 0);
    const manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "cyna.toml" });
    defer allocator.free(manifest_path);
    if (!pathExists(manifest_path)) return allocator.alloc(State.Dependency, 0);

    const source = compat.readFileAlloc(allocator, manifest_path, 1024 * 1024) catch |err| {
        try diagnostic_context.emitPath(manifest_path, @errorName(err));
        return err;
    };
    defer allocator.free(source);

    var deps: std.ArrayListUnmanaged(State.Dependency) = .empty;
    errdefer {
        for (deps.items) |dep| dep.deinit(allocator);
        deps.deinit(allocator);
    }

    const lock_entries = try loadLockDependencies(allocator, root_dir, diagnostic_context);
    defer {
        for (lock_entries) |entry| entry.deinit(allocator);
        allocator.free(lock_entries);
    }

    var line_it = std.mem.tokenizeScalar(u8, source, '\n');
    var in_dependencies = false;
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_dependencies = std.mem.eql(u8, line, "[dependencies]");
            continue;
        }
        if (!in_dependencies) continue;

        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
        var spec = try parseDependencySpec(allocator, value);
        defer spec.deinit(allocator);
        if (spec.registry != null or spec.url != null) {
            const home = if (home_override) |override|
                override
            else blk: {
                const owned = compat.getEnvVarOwned(allocator, "HOME") catch {
                    try diagnostic_context.emitPath(manifest_path, "registry/url dependencies require HOME and cyna.lock to resolve installed packages");
                    return error.InvalidManifest;
                };
                defer allocator.free(owned);
                break :blk owned;
            };
            const package_root = try resolveLockedDependencyPackageRoot(allocator, manifest_path, home, lock_entries, key, spec, diagnostic_context);
            errdefer allocator.free(package_root);
            const source_root = try discoverPackageSourceRoot(allocator, package_root, diagnostic_context);
            errdefer allocator.free(source_root);
            try deps.append(allocator, .{
                .name = try allocator.dupe(u8, key),
                .root_dir = package_root,
                .source_root = source_root,
            });
            continue;
        }
        const package_root = try resolveDependencyPackageRoot(allocator, root_dir, key, spec.path, spec.version, diagnostic_context);
        errdefer allocator.free(package_root);
        const source_root = try discoverPackageSourceRoot(allocator, package_root, diagnostic_context);
        errdefer allocator.free(source_root);

        try deps.append(allocator, .{
            .name = try allocator.dupe(u8, key),
            .root_dir = package_root,
            .source_root = source_root,
        });
    }

    return deps.toOwnedSlice(allocator);
}

const PackageIdentity = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,

    fn deinit(self: *PackageIdentity, allocator: std.mem.Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.version) |value| allocator.free(value);
        self.* = .{};
    }
};

const LockedDependency = struct {
    dependency_name: []const u8,
    package_name: []const u8,
    version: []const u8,
    registry: ?[]const u8 = null,
    url: ?[]const u8 = null,

    fn deinit(self: LockedDependency, allocator: std.mem.Allocator) void {
        allocator.free(self.dependency_name);
        allocator.free(self.package_name);
        allocator.free(self.version);
        if (self.registry) |value| allocator.free(value);
        if (self.url) |value| allocator.free(value);
    }
};

const PendingLockedDependency = struct {
    dependency_name: ?[]const u8 = null,
    package_name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    registry: ?[]const u8 = null,
    url: ?[]const u8 = null,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.dependency_name) |value| allocator.free(value);
        if (self.package_name) |value| allocator.free(value);
        if (self.version) |value| allocator.free(value);
        if (self.registry) |value| allocator.free(value);
        if (self.url) |value| allocator.free(value);
        self.* = .{};
    }
};

const DependencySpec = struct {
    path: ?[]const u8 = null,
    version: ?[]const u8 = null,
    registry: ?[]const u8 = null,
    url: ?[]const u8 = null,

    fn deinit(self: *DependencySpec, allocator: std.mem.Allocator) void {
        if (self.path) |value| allocator.free(value);
        if (self.version) |value| allocator.free(value);
        if (self.registry) |value| allocator.free(value);
        if (self.url) |value| allocator.free(value);
        self.* = .{};
    }
};

fn loadLockDependencies(
    allocator: std.mem.Allocator,
    manifest_root_dir: []const u8,
    diagnostic_context: diagnostics.Context,
) ![]LockedDependency {
    const lock_path = try std.fs.path.join(allocator, &.{ manifest_root_dir, "cyna.lock" });
    defer allocator.free(lock_path);
    if (!pathExists(lock_path)) return allocator.alloc(LockedDependency, 0);

    const source = compat.readFileAlloc(allocator, lock_path, 1024 * 1024) catch |err| {
        try diagnostic_context.emitPath(lock_path, @errorName(err));
        return err;
    };
    defer allocator.free(source);

    var entries: std.ArrayListUnmanaged(LockedDependency) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var pending: ?PendingLockedDependency = null;
    defer if (pending) |*entry| entry.deinit(allocator);

    var line_it = std.mem.tokenizeScalar(u8, source, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            if (try parseLockDependencySection(allocator, line)) |dependency_name| {
                if (pending) |*entry| {
                    try appendLockedDependency(allocator, &entries, entry);
                    entry.deinit(allocator);
                }
                pending = .{ .dependency_name = dependency_name };
            } else if (pending) |*entry| {
                try appendLockedDependency(allocator, &entries, entry);
                entry.deinit(allocator);
                pending = null;
            }
            continue;
        }

        if (pending == null) continue;
        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
        const entry = &pending.?;
        if (std.mem.eql(u8, key, "package")) {
            if (entry.package_name) |existing| allocator.free(existing);
            entry.package_name = try parseQuotedString(allocator, value);
        } else if (std.mem.eql(u8, key, "version")) {
            if (entry.version) |existing| allocator.free(existing);
            entry.version = try parseQuotedString(allocator, value);
        } else if (std.mem.eql(u8, key, "registry")) {
            if (entry.registry) |existing| allocator.free(existing);
            entry.registry = try parseQuotedString(allocator, value);
        } else if (std.mem.eql(u8, key, "url")) {
            if (entry.url) |existing| allocator.free(existing);
            entry.url = try parseQuotedString(allocator, value);
        }
    }

    if (pending) |*entry| {
        try appendLockedDependency(allocator, &entries, entry);
        entry.deinit(allocator);
        pending = null;
    }

    return entries.toOwnedSlice(allocator);
}

fn parseLockDependencySection(allocator: std.mem.Allocator, line: []const u8) !?[]const u8 {
    if (line.len < "[dependency.x]".len or line[0] != '[' or line[line.len - 1] != ']') return null;
    const section_name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    if (!std.mem.startsWith(u8, section_name, "dependency.")) return null;
    return @as([]const u8, try allocator.dupe(u8, section_name["dependency.".len..]));
}

fn appendLockedDependency(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(LockedDependency),
    pending: *const PendingLockedDependency,
) !void {
    const dependency_name = pending.dependency_name orelse return error.InvalidManifest;
    const package_name = pending.package_name orelse dependency_name;
    const version = pending.version orelse return error.InvalidManifest;

    try entries.append(allocator, .{
        .dependency_name = try allocator.dupe(u8, dependency_name),
        .package_name = try allocator.dupe(u8, package_name),
        .version = try allocator.dupe(u8, version),
        .registry = if (pending.registry) |value| try allocator.dupe(u8, value) else null,
        .url = if (pending.url) |value| try allocator.dupe(u8, value) else null,
    });
}

fn resolveLockedDependencyPackageRoot(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    home: []const u8,
    lock_entries: []const LockedDependency,
    dependency_name: []const u8,
    spec: DependencySpec,
    diagnostic_context: diagnostics.Context,
) ![]const u8 {
    var matched: ?*const LockedDependency = null;
    for (lock_entries) |*entry| {
        if (!std.mem.eql(u8, entry.dependency_name, dependency_name)) continue;
        if (matched != null) {
            try diagnostic_context.emitPath(manifest_path, "duplicate cyna.lock entry for dependency");
            return error.InvalidManifest;
        }
        matched = entry;
    }

    const entry = matched orelse {
        try diagnostic_context.emitPath(manifest_path, "registry/url dependency requires matching cyna.lock entry");
        return error.InvalidManifest;
    };

    if (spec.version) |version| {
        if (!std.mem.eql(u8, version, entry.version)) {
            try diagnostic_context.emitPath(manifest_path, "dependency version does not match cyna.lock");
            return error.InvalidManifest;
        }
    }
    if (spec.registry) |registry| {
        if (entry.registry == null or !std.mem.eql(u8, registry, entry.registry.?)) {
            try diagnostic_context.emitPath(manifest_path, "dependency registry does not match cyna.lock");
            return error.InvalidManifest;
        }
    }
    if (spec.url) |url| {
        if (entry.url == null or !std.mem.eql(u8, url, entry.url.?)) {
            try diagnostic_context.emitPath(manifest_path, "dependency url does not match cyna.lock");
            return error.InvalidManifest;
        }
    }

    const installed_root = (try resolveInstalledPackageRootExact(allocator, home, entry.package_name, entry.version)) orelse {
        try diagnostic_context.emitPath(manifest_path, "locked dependency is not installed");
        return error.InvalidManifest;
    };
    return installed_root;
}

fn resolveDependencyPackageRoot(
    allocator: std.mem.Allocator,
    manifest_root_dir: []const u8,
    dependency_name: []const u8,
    dependency_path: ?[]const u8,
    dependency_version: ?[]const u8,
    diagnostic_context: diagnostics.Context,
) ![]const u8 {
    const home = compat.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (home) |value| allocator.free(value);
    return resolveDependencyPackageRootWithHome(allocator, home, manifest_root_dir, dependency_name, dependency_path, dependency_version, diagnostic_context);
}

fn resolveDependencyPackageRootWithHome(
    allocator: std.mem.Allocator,
    home: ?[]const u8,
    manifest_root_dir: []const u8,
    dependency_name: []const u8,
    dependency_path: ?[]const u8,
    dependency_version: ?[]const u8,
    diagnostic_context: diagnostics.Context,
) ![]const u8 {
    if (dependency_path) |path| {
        const local_root = try resolvePathAgainstRoot(allocator, manifest_root_dir, path);
        errdefer allocator.free(local_root);

        if (pathExists(local_root)) {
            if (home) |home_dir| {
                if (try resolveInstalledPackageRootForLocalDependency(allocator, home_dir, local_root, dependency_name, dependency_version, diagnostic_context)) |installed_root| {
                    allocator.free(local_root);
                    return installed_root;
                }
            }
            return local_root;
        }

        if (home) |home_dir| {
            if (try resolveInstalledPackageRootByDependencyName(allocator, home_dir, dependency_name, dependency_version)) |installed_root| {
                allocator.free(local_root);
                return installed_root;
            }
        }

        return local_root;
    }

    if (home) |home_dir| {
        if (try resolveInstalledPackageRootByDependencyName(allocator, home_dir, dependency_name, dependency_version)) |installed_root| {
            return installed_root;
        }
    }

    return error.FileNotFound;
}

fn resolveInstalledPackageRootForLocalDependency(
    allocator: std.mem.Allocator,
    home: []const u8,
    local_root: []const u8,
    dependency_name: []const u8,
    dependency_version: ?[]const u8,
    diagnostic_context: diagnostics.Context,
) !?[]const u8 {
    if (dependency_version) |version| {
        return resolveInstalledPackageRootExact(allocator, home, dependency_name, version);
    }

    const manifest_path = (try findPackageManifestPath(allocator, local_root)) orelse return null;
    defer allocator.free(manifest_path);

    var identity = try parsePackageIdentity(allocator, manifest_path, diagnostic_context);
    defer identity.deinit(allocator);
    const name = identity.name orelse return null;
    const version = identity.version orelse return null;

    const installed_root = try installedPackageRootPath(allocator, home, name, version);
    errdefer allocator.free(installed_root);
    if (!pathExists(installed_root)) {
        allocator.free(installed_root);
        return null;
    }
    return installed_root;
}

fn resolveInstalledPackageRootByDependencyName(allocator: std.mem.Allocator, home: []const u8, dependency_name: []const u8, dependency_version: ?[]const u8) !?[]const u8 {
    if (dependency_version) |version| return resolveInstalledPackageRootExact(allocator, home, dependency_name, version);

    const package_dir = try std.fs.path.join(allocator, &.{ home, ".cyna", "packages", dependency_name });
    defer allocator.free(package_dir);

    var dir = compat.openDirAbsolute(package_dir, .{ .iterate = true }) catch return null;
    defer compat.closeDir(dir);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var found_version_root: ?[]const u8 = null;
    while (try walker.next(compat.io())) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.indexOfScalar(u8, entry.path, std.fs.path.sep) != null) continue;

        const version_root = try std.fs.path.join(allocator, &.{ package_dir, entry.path });
        if (found_version_root != null) {
            allocator.free(version_root);
            if (found_version_root) |existing| allocator.free(existing);
            return null;
        }
        found_version_root = version_root;
    }

    if (found_version_root) |root| return root;
    return null;
}

fn resolveInstalledPackageRootExact(allocator: std.mem.Allocator, home: []const u8, name: []const u8, version: []const u8) !?[]const u8 {
    const installed_root = try installedPackageRootPath(allocator, home, name, version);
    errdefer allocator.free(installed_root);
    if (!pathExists(installed_root)) {
        allocator.free(installed_root);
        return null;
    }
    return installed_root;
}

fn installedPackageRootPath(allocator: std.mem.Allocator, home: []const u8, name: []const u8, version: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ home, ".cyna", "packages", name, version });
}

fn parseDependencySpec(allocator: std.mem.Allocator, value: []const u8) !DependencySpec {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return .{ .path = try parseQuotedString(allocator, value) };
    }
    if (value.len < 2 or value[0] != '{' or value[value.len - 1] != '}') return error.InvalidManifest;

    var spec = DependencySpec{};
    errdefer spec.deinit(allocator);

    const inner = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    if (inner.len == 0) return error.InvalidManifest;

    var parts = std.mem.splitScalar(u8, inner, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const eq_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse return error.InvalidManifest;
        const key = std.mem.trim(u8, trimmed[0..eq_index], " \t");
        const field_value = std.mem.trim(u8, trimmed[eq_index + 1 ..], " \t");
        if (std.mem.eql(u8, key, "path")) {
            if (spec.path) |existing| allocator.free(existing);
            spec.path = try parseQuotedString(allocator, field_value);
        } else if (std.mem.eql(u8, key, "version")) {
            if (spec.version) |existing| allocator.free(existing);
            spec.version = try parseQuotedString(allocator, field_value);
        } else if (std.mem.eql(u8, key, "registry")) {
            if (spec.registry) |existing| allocator.free(existing);
            spec.registry = try parseQuotedString(allocator, field_value);
        } else if (std.mem.eql(u8, key, "url")) {
            if (spec.url) |existing| allocator.free(existing);
            spec.url = try parseQuotedString(allocator, field_value);
        } else {
            return error.InvalidManifest;
        }
    }

    if (spec.path == null and spec.version == null and spec.registry == null and spec.url == null) return error.InvalidManifest;
    return spec;
}

fn parseQuotedString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidManifest;
    return allocator.dupe(u8, value[1 .. value.len - 1]);
}

fn discoverPackageSourceRoot(
    allocator: std.mem.Allocator,
    package_root: []const u8,
    diagnostic_context: diagnostics.Context,
) ![]const u8 {
    if (try findPackageManifestPath(allocator, package_root)) |manifest_path| {
        defer allocator.free(manifest_path);
        if (try parseManifestSourceRoot(allocator, manifest_path, package_root, diagnostic_context)) |source_root| return source_root;
    }

    const default_src_dir = try std.fs.path.join(allocator, &.{ package_root, "src" });
    defer allocator.free(default_src_dir);
    if (pathExists(default_src_dir)) return allocator.dupe(u8, default_src_dir);

    return allocator.dupe(u8, package_root);
}

fn parseManifestSourceRoot(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    package_root: []const u8,
    diagnostic_context: diagnostics.Context,
) !?[]const u8 {
    const source = compat.readFileAlloc(allocator, manifest_path, 1024 * 1024) catch |err| {
        try diagnostic_context.emitPath(manifest_path, @errorName(err));
        return err;
    };
    defer allocator.free(source);

    var line_it = std.mem.tokenizeScalar(u8, source, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') break;
        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
        if (std.mem.eql(u8, key, "src")) {
            const src_rel = try parseQuotedString(allocator, value);
            defer allocator.free(src_rel);
            return try resolvePathAgainstRoot(allocator, package_root, src_rel);
        }
        if (std.mem.eql(u8, key, "entry")) {
            const entry_rel = try parseQuotedString(allocator, value);
            defer allocator.free(entry_rel);
            const entry_path = try resolvePathAgainstRoot(allocator, package_root, entry_rel);
            defer allocator.free(entry_path);
            const entry_dir = std.fs.path.dirname(entry_path) orelse package_root;
            return try allocator.dupe(u8, entry_dir);
        }
    }
    return null;
}

fn findPackageManifestPath(allocator: std.mem.Allocator, package_root: []const u8) !?[]const u8 {
    const local_manifest = try std.fs.path.join(allocator, &.{ package_root, "cyna.toml" });
    errdefer allocator.free(local_manifest);
    if (pathExists(local_manifest)) return local_manifest;
    allocator.free(local_manifest);

    const installed_manifest = try std.fs.path.join(allocator, &.{ package_root, "manifest.toml" });
    errdefer allocator.free(installed_manifest);
    if (pathExists(installed_manifest)) return installed_manifest;
    allocator.free(installed_manifest);
    return null;
}

fn parsePackageIdentity(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    diagnostic_context: diagnostics.Context,
) !PackageIdentity {
    const source = compat.readFileAlloc(allocator, manifest_path, 1024 * 1024) catch |err| {
        try diagnostic_context.emitPath(manifest_path, @errorName(err));
        return err;
    };
    defer allocator.free(source);

    var identity = PackageIdentity{};
    errdefer identity.deinit(allocator);

    var line_it = std.mem.tokenizeScalar(u8, source, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') break;
        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
        if (std.mem.eql(u8, key, "name")) {
            if (identity.name) |existing| allocator.free(existing);
            identity.name = try parseQuotedString(allocator, value);
        } else if (std.mem.eql(u8, key, "version")) {
            if (identity.version) |existing| allocator.free(existing);
            identity.version = try parseQuotedString(allocator, value);
        }
    }

    return identity;
}

fn pathExists(path: []const u8) bool {
    compat.access(path, .{}) catch return false;
    return true;
}

fn isDirectoryPath(path: []const u8) bool {
    const dir = compat.openDirAbsolute(path, .{}) catch return false;
    compat.closeDir(dir);
    return true;
}

test "std prelude remains unique when a source path derives to std.prelude" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "std");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "std/prelude.cy",
        .data =
        \\fn sentinel(): i32 {
        \\    return 7;
        \\}
        \\
        ,
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "std/prelude.cy");
    defer std.testing.allocator.free(root_path);

    const root_dir = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root_dir);

    var state = State{
        .allocator = std.testing.allocator,
        .root_package = .{
            .name = try std.testing.allocator.dupe(u8, ""),
            .root_dir = try std.testing.allocator.dupe(u8, root_dir),
        },
        .manifest_root_dir = null,
        .bundled_modules = try loadBundledModules(std.testing.allocator),
        .dependencies = try std.testing.allocator.alloc(State.Dependency, 0),
        .source_paths = .empty,
        .sources = .empty,
        .tokens = .empty,
        .module_names = .empty,
        .module_infos = .empty,
        .globals = .empty,
        .asm_consts = .empty,
        .aliases = .empty,
        .enums = .empty,
        .unions = .empty,
        .protocols = .empty,
        .impls = .empty,
        .structs = .empty,
        .functions = .empty,
        .tests = .empty,
        .visited_paths = .empty,
        .root_overlay_path = null,
        .root_overlay_source = null,
        .progress = false,
        .diagnostic_context = diagnostics.Context.discarded(),
        .session = null,
        .dependency_observer = null,
        .source_overlay = null,
    };
    defer state.deinit();

    try std.testing.expect(try state.loadBundledModule(package_manifest.prelude_module_name));
    try state.loadFile(root_path, package_manifest.prelude_module_name);

    var prelude_count: usize = 0;
    for (state.module_infos.items) |info| {
        if (std.mem.eql(u8, info.name, package_manifest.prelude_module_name)) {
            prelude_count += 1;
            try std.testing.expect(info.compiler_owned);
        }
    }

    try std.testing.expectEqual(@as(usize, 1), prelude_count);
    for (state.functions.items) |function| {
        try std.testing.expect(!std.mem.eql(u8, function.name, "sentinel"));
    }
}

test "bundled manifests declare filesystem-backed modules" {
    const modules = try loadBundledModules(std.testing.allocator);
    defer {
        for (modules) |module| module.deinit(std.testing.allocator);
        std.testing.allocator.free(modules);
    }

    var saw_prelude = false;
    var saw_alloc = false;
    var saw_fs = false;
    var saw_embedded_hal = false;
    var saw_embedded_mmio = false;
    for (modules) |module| {
        if (std.mem.eql(u8, module.module_name, package_manifest.prelude_module_name)) {
            saw_prelude = true;
            try std.testing.expect(module.autoload);
            try std.testing.expect(std.mem.endsWith(u8, module.path, "/packages/std/src/std_prelude.cy") or std.mem.endsWith(u8, module.path, "\\packages\\std\\src\\std_prelude.cy"));
        } else if (std.mem.eql(u8, module.module_name, "std.alloc")) {
            saw_alloc = true;
        } else if (std.mem.eql(u8, module.module_name, "std.fs")) {
            saw_fs = true;
        } else if (std.mem.eql(u8, module.module_name, "embedded.hal")) {
            saw_embedded_hal = true;
            try std.testing.expect(std.mem.endsWith(u8, module.path, "/packages/embedded/src/hal/mod.cy") or std.mem.endsWith(u8, module.path, "\\packages\\embedded\\src\\hal\\mod.cy"));
        } else if (std.mem.eql(u8, module.module_name, "embedded.hal.mmio")) {
            saw_embedded_mmio = true;
        }
    }

    try std.testing.expect(saw_prelude);
    try std.testing.expect(saw_alloc);
    try std.testing.expect(saw_fs);
    try std.testing.expect(saw_embedded_hal);
    try std.testing.expect(saw_embedded_mmio);
}

test "discover package source root reads installed manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "util/pkg");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "util/manifest.toml",
        .data =
        \\name = "util"
        \\version = "0.1.0"
        \\src = "pkg"
        ,
    });

    const package_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "util");
    defer std.testing.allocator.free(package_root);

    const source_root = try discoverPackageSourceRoot(std.testing.allocator, package_root, diagnostics.Context.discarded());
    defer std.testing.allocator.free(source_root);

    try std.testing.expect(std.mem.endsWith(u8, source_root, "/util/pkg") or std.mem.endsWith(u8, source_root, "\\util\\pkg"));
}

test "loader prefers installed package root when local dependency is installed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "home/.cyna/packages/util/0.1.0/src");
    try compat.dirMakePath(tmp.dir, "util/src");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "util/cyna.toml",
        .data =
        \\name = "util"
        \\version = "0.1.0"
        \\src = "src"
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "home/.cyna/packages/util/0.1.0/manifest.toml",
        .data =
        \\name = "util"
        \\version = "0.1.0"
        \\src = "src"
        ,
    });

    const home = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "home");
    defer std.testing.allocator.free(home);
    const local_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "util");
    defer std.testing.allocator.free(local_root);

    const installed_root = (try resolveInstalledPackageRootForLocalDependency(std.testing.allocator, home, local_root, "util", null, diagnostics.Context.discarded())).?;
    defer std.testing.allocator.free(installed_root);

    try std.testing.expect(std.mem.endsWith(u8, installed_root, "/home/.cyna/packages/util/0.1.0") or std.mem.endsWith(u8, installed_root, "\\home\\.cyna\\packages\\util\\0.1.0"));
}

test "loader falls back to uniquely installed package when local dependency path is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app");
    try compat.dirMakePath(tmp.dir, "home/.cyna/packages/util/0.1.0/src");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "home/.cyna/packages/util/0.1.0/manifest.toml",
        .data =
        \\name = "util"
        \\version = "0.1.0"
        \\src = "src"
        ,
    });

    const home = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "home");
    defer std.testing.allocator.free(home);
    const app_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app");
    defer std.testing.allocator.free(app_root);

    const resolved = try resolveDependencyPackageRootWithHome(std.testing.allocator, home, app_root, "util", "../util", null, diagnostics.Context.discarded());
    defer std.testing.allocator.free(resolved);

    try std.testing.expect(std.mem.endsWith(u8, resolved, "/home/.cyna/packages/util/0.1.0") or std.mem.endsWith(u8, resolved, "\\home\\.cyna\\packages\\util\\0.1.0"));
}

test "loader does not guess between multiple installed dependency versions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "home/.cyna/packages/util/0.1.0/src");
    try compat.dirMakePath(tmp.dir, "home/.cyna/packages/util/0.2.0/src");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "home/.cyna/packages/util/0.1.0/manifest.toml",
        .data =
        \\name = "util"
        \\version = "0.1.0"
        \\src = "src"
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "home/.cyna/packages/util/0.2.0/manifest.toml",
        .data =
        \\name = "util"
        \\version = "0.2.0"
        \\src = "src"
        ,
    });

    const home = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "home");
    defer std.testing.allocator.free(home);

    const resolved = try resolveInstalledPackageRootByDependencyName(std.testing.allocator, home, "util", null);
    try std.testing.expect(resolved == null);
}

test "nested relative import in a path dependency uses its own source root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "a/src/inner");
    try compat.dirMakePath(tmp.dir, "b/src");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "a/cyna.toml", .data =
        \\name = "repro_a"
        \\src = "src"
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "b/cyna.toml", .data =
        \\name = "repro_b"
        \\src = "src"
        \\[dependencies]
        \\repro_a = { path = "../a" }
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "a/src/inner/child.cy", .data = "import .inner.other;\n" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "a/src/inner/other.cy", .data = "pub fn value(): i32 { return 1; }\n" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "b/src/lib.cy", .data = "import repro_a.inner.child;\n" });
    const entry = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "b/src/lib.cy");
    defer std.testing.allocator.free(entry);
    const loaded = try loadProgram(std.testing.allocator, entry);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(loaded.source_paths.len >= 3);
}

test "loader parses dependency inline table with path and version" {
    var spec = try parseDependencySpec(std.testing.allocator, "{ path = \"../util\", version = \"0.2.0\" }");
    defer spec.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("../util", spec.path.?);
    try std.testing.expectEqualStrings("0.2.0", spec.version.?);
}

test "loader exact installed version wins from dependency spec" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "home/.cyna/packages/util/0.1.0/src");
    try compat.dirMakePath(tmp.dir, "home/.cyna/packages/util/0.2.0/src");

    const home = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "home");
    defer std.testing.allocator.free(home);
    const app_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(app_root);

    const resolved = try resolveDependencyPackageRootWithHome(std.testing.allocator, home, app_root, "util", null, "0.2.0", diagnostics.Context.discarded());
    defer std.testing.allocator.free(resolved);

    try std.testing.expect(std.mem.endsWith(u8, resolved, "/home/.cyna/packages/util/0.2.0") or std.mem.endsWith(u8, resolved, "\\home\\.cyna\\packages\\util\\0.2.0"));
}

test "loader parses dependency inline table with registry and version" {
    var spec = try parseDependencySpec(std.testing.allocator, "{ registry = \"central\", version = \"0.2.0\" }");
    defer spec.deinit(std.testing.allocator);

    try std.testing.expect(spec.path == null);
    try std.testing.expectEqualStrings("central", spec.registry.?);
    try std.testing.expectEqualStrings("0.2.0", spec.version.?);
}

test "loader resolves registry dependency through cyna.lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app");
    try compat.dirMakePath(tmp.dir, "home/.cyna/packages/util/0.2.0/src");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/cyna.toml",
        .data =
        \\name = "app"
        \\[dependencies]
        \\util = { registry = "central", version = "0.2.0" }
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/cyna.lock",
        .data =
        \\[dependency.util]
        \\package = "util"
        \\version = "0.2.0"
        \\registry = "central"
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "home/.cyna/packages/util/0.2.0/manifest.toml",
        .data =
        \\name = "util"
        \\version = "0.2.0"
        \\src = "src"
        ,
    });

    const app_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app");
    defer std.testing.allocator.free(app_root);
    const home = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "home");
    defer std.testing.allocator.free(home);

    const deps = try loadDependenciesWithHome(std.testing.allocator, app_root, home, diagnostics.Context.discarded());
    defer {
        for (deps) |dep| dep.deinit(std.testing.allocator);
        std.testing.allocator.free(deps);
    }

    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqualStrings("util", deps[0].name);
    try std.testing.expect(std.mem.endsWith(u8, deps[0].root_dir, "/home/.cyna/packages/util/0.2.0") or std.mem.endsWith(u8, deps[0].root_dir, "\\home\\.cyna\\packages\\util\\0.2.0"));
    try std.testing.expect(std.mem.endsWith(u8, deps[0].source_root, "/home/.cyna/packages/util/0.2.0/src") or std.mem.endsWith(u8, deps[0].source_root, "\\home\\.cyna\\packages\\util\\0.2.0\\src"));
}

test "loader rejects registry dependency without matching cyna.lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/cyna.toml",
        .data =
        \\name = "app"
        \\[dependencies]
        \\util = { registry = "central", version = "0.2.0" }
        ,
    });

    const app_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app");
    defer std.testing.allocator.free(app_root);
    const home = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(home);

    const diagnostic_context = diagnostics.Context.discarded();
    try std.testing.expectError(error.InvalidManifest, loadDependenciesWithHome(std.testing.allocator, app_root, home, diagnostic_context));
}

test "loader rejects registry dependency when cyna.lock version mismatches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app");
    try compat.dirMakePath(tmp.dir, "home/.cyna/packages/util/0.1.0/src");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/cyna.toml",
        .data =
        \\name = "app"
        \\[dependencies]
        \\util = { registry = "central", version = "0.2.0" }
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/cyna.lock",
        .data =
        \\[dependency.util]
        \\package = "util"
        \\version = "0.1.0"
        \\registry = "central"
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "home/.cyna/packages/util/0.1.0/manifest.toml",
        .data =
        \\name = "util"
        \\version = "0.1.0"
        \\src = "src"
        ,
    });

    const app_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app");
    defer std.testing.allocator.free(app_root);
    const home = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "home");
    defer std.testing.allocator.free(home);

    const diagnostic_context = diagnostics.Context.discarded();
    try std.testing.expectError(error.InvalidManifest, loadDependenciesWithHome(std.testing.allocator, app_root, home, diagnostic_context));
}

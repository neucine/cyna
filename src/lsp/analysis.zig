const std = @import("std");
const build_pkg = @import("../build.zig");
const compat = @import("../compat.zig");
const diagnostic_sources = @import("../compiler/diagnostic/source_registry.zig");
const compiler_diagnostics = @import("../compiler/diagnostics.zig");
const lexer = @import("../compiler/lexer/lexer.zig");
const loader = @import("../compiler/loader.zig");
const ast = @import("../compiler/parser/ast.zig");
const parser = @import("../compiler/parser/parser.zig");
const sema = @import("../compiler/sema/sema.zig");

const build_model = build_pkg.model;

pub const Diagnostic = compiler_diagnostics.Diagnostic;

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    diagnostics: []Diagnostic,
    hover_facts: []sema.SemanticHoverFact,
    dependencies: [][]const u8,
    sources: diagnostic_sources.Registry,
    loaded: ?loader.LoadedProgram,
    current_module_name: ?[]const u8,
    matches_disk: bool,

    pub fn deinit(self: *Snapshot, _: std.mem.Allocator) void {
        const allocator = self.allocator;
        for (self.diagnostics) |diagnostic| diagnostic.deinit(allocator);
        allocator.free(self.diagnostics);
        for (self.hover_facts) |fact| fact.deinit(allocator);
        allocator.free(self.hover_facts);
        for (self.dependencies) |path| allocator.free(path);
        allocator.free(self.dependencies);
        self.sources.deinit();
        if (self.loaded) |loaded| loaded.deinit(allocator);
        self.* = undefined;
    }
};

pub const BuildOptions = struct {
    matches_disk: bool,
    source_overlay: ?loader.SourceOverlay = null,
};

pub fn build(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    matches_disk: bool,
) !Snapshot {
    return buildWithOptions(allocator, path, text, .{ .matches_disk = matches_disk });
}

pub fn buildWithOptions(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    options: BuildOptions,
) !Snapshot {
    var sink = compiler_diagnostics.Sink.init(allocator);
    defer sink.deinit();
    var diagnostic_context = compiler_diagnostics.Context.structured(&sink);
    var dependencies = DependencyCollector.init(allocator);
    defer dependencies.deinit();

    var target = build_model.resolveBuildTarget(allocator, path) catch |err| switch (err) {
        error.ProjectNotFound, error.FileNotFound, error.PermissionDenied => {
            return buildStandalone(allocator, path, text, options, &sink, &diagnostic_context);
        },
        error.InvalidManifest, error.UnsupportedTarget => {
            try dependencies.record(path);
            if (sink.records.items.len == 0) try diagnostic_context.emitPath(path, @errorName(err));
            return snapshotFromRecords(
                allocator,
                options.matches_disk,
                sink.records.items,
                &.{},
                &dependencies,
                null,
                null,
                path,
                text,
                options.source_overlay,
            );
        },
        else => return err,
    };
    defer target.deinit(allocator);

    var loaded = loader.loadProgramWithRootSourceOptions(
        allocator,
        target.source_path,
        if (options.matches_disk) null else text,
        .{
            .allow_test_root = std.mem.endsWith(u8, target.source_path, ".test.cy"),
            .diagnostic_context = diagnostic_context,
            .dependency_observer = dependencies.observer(),
            .source_overlay = options.source_overlay,
        },
    ) catch |err| switch (err) {
        error.ParseFailed,
        error.SemanticFailed,
        error.TestBlockOutsideTestFile,
        => return snapshotFromRecords(
            allocator,
            options.matches_disk,
            sink.records.items,
            &.{},
            &dependencies,
            null,
            null,
            target.source_path,
            text,
            options.source_overlay,
        ),
        error.PermissionDenied => {
            try diagnostic_context.emitPath(target.source_path, "permission denied while loading source");
            return snapshotFromRecords(
                allocator,
                options.matches_disk,
                sink.records.items,
                &.{},
                &dependencies,
                null,
                null,
                target.source_path,
                text,
                options.source_overlay,
            );
        },
        else => return err,
    };
    errdefer loaded.deinit(allocator);

    const current_module_name = moduleNameForPath(loaded, path) orelse loaded.root_module_name;
    const friend_module = try loaded.testFriendModule(allocator, target.source_path);
    const hover_facts = sema.collectSemanticHoverFactsWithOptions(
        allocator,
        target.source_path,
        loaded.program,
        current_module_name,
        .{
            .target = target.target,
            .diagnostic_context = diagnostic_context,
            .test_friend = if (friend_module) |production_module| .{
                .test_module = loaded.root_module_name,
                .production_module = production_module,
            } else null,
        },
    ) catch |err| switch (err) {
        error.SemanticFailed => try allocator.alloc(sema.SemanticHoverFact, 0),
        else => return err,
    };
    errdefer {
        for (hover_facts) |fact| fact.deinit(allocator);
        allocator.free(hover_facts);
    }

    return snapshotFromRecords(
        allocator,
        options.matches_disk,
        sink.records.items,
        hover_facts,
        &dependencies,
        loaded,
        current_module_name,
        target.source_path,
        text,
        options.source_overlay,
    );
}

fn buildStandalone(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    options: BuildOptions,
    sink: *compiler_diagnostics.Sink,
    diagnostic_context: *compiler_diagnostics.Context,
) !Snapshot {
    var dependencies = DependencyCollector.init(allocator);
    defer dependencies.deinit();
    try dependencies.record(path);

    const tokens = lexer.lexAll(allocator, text) catch |err| {
        try diagnostic_context.emitPath(path, @errorName(err));
        return snapshotFromRecords(
            allocator,
            options.matches_disk,
            sink.records.items,
            &.{},
            &dependencies,
            null,
            null,
            path,
            text,
            options.source_overlay,
        );
    };
    defer allocator.free(tokens);

    const program = parser.parseWithDiagnostics(allocator, path, text, tokens, diagnostic_context) catch |err| switch (err) {
        error.ParseFailed => return snapshotFromRecords(
            allocator,
            options.matches_disk,
            sink.records.items,
            &.{},
            &dependencies,
            null,
            null,
            path,
            text,
            options.source_overlay,
        ),
        else => return err,
    };
    defer program.deinit(allocator);

    const hover_facts = sema.collectSemanticHoverFactsWithOptions(allocator, path, program, "", .{
        .diagnostic_context = diagnostic_context.*,
    }) catch |err| switch (err) {
        error.SemanticFailed => try allocator.alloc(sema.SemanticHoverFact, 0),
        else => return err,
    };
    errdefer {
        for (hover_facts) |fact| fact.deinit(allocator);
        allocator.free(hover_facts);
    }
    return snapshotFromRecords(
        allocator,
        options.matches_disk,
        sink.records.items,
        hover_facts,
        &dependencies,
        null,
        null,
        path,
        text,
        options.source_overlay,
    );
}

fn snapshotFromRecords(
    allocator: std.mem.Allocator,
    matches_disk: bool,
    records: []const compiler_diagnostics.Record,
    hover_facts: []sema.SemanticHoverFact,
    dependencies: *DependencyCollector,
    loaded: ?loader.LoadedProgram,
    current_module_name: ?[]const u8,
    root_path: []const u8,
    root_text: []const u8,
    source_overlay: ?loader.SourceOverlay,
) !Snapshot {
    const owned_dependencies = try dependencies.paths.toOwnedSlice(allocator);
    errdefer {
        for (owned_dependencies) |path| allocator.free(path);
        allocator.free(owned_dependencies);
    }
    var sources = diagnostic_sources.Registry.init(allocator);
    errdefer sources.deinit();
    try populateSources(&sources, root_path, root_text, loaded, records, source_overlay);
    return .{
        .allocator = allocator,
        .diagnostics = try recordsToDiagnostics(allocator, records),
        .hover_facts = hover_facts,
        .dependencies = owned_dependencies,
        .sources = sources,
        .loaded = loaded,
        .current_module_name = current_module_name,
        .matches_disk = matches_disk,
    };
}

const DependencyCollector = struct {
    allocator: std.mem.Allocator,
    paths: std.ArrayListUnmanaged([]const u8) = .empty,

    fn init(allocator: std.mem.Allocator) DependencyCollector {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *DependencyCollector) void {
        for (self.paths.items) |path| self.allocator.free(path);
        self.paths.deinit(self.allocator);
    }

    fn observer(self: *DependencyCollector) loader.DependencyObserver {
        return .{
            .context = self,
            .recordFn = recordObservedDependency,
        };
    }

    fn record(self: *DependencyCollector, path: []const u8) !void {
        for (self.paths.items) |existing| {
            if (std.mem.eql(u8, existing, path)) return;
        }
        try self.paths.append(self.allocator, try self.allocator.dupe(u8, path));
    }

    fn recordObservedDependency(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *DependencyCollector = @ptrCast(@alignCast(context));
        try self.record(path);
    }
};

fn recordsToDiagnostics(
    allocator: std.mem.Allocator,
    records: []const compiler_diagnostics.Record,
) ![]Diagnostic {
    var sink = compiler_diagnostics.Sink.init(allocator);
    defer sink.deinit();
    const context = compiler_diagnostics.Context.structured(&sink);
    for (records) |record| {
        try context.emit(record.asSpec());
    }
    return sink.takeRecords();
}

fn populateSources(
    registry: *diagnostic_sources.Registry,
    root_path: []const u8,
    root_text: []const u8,
    loaded: ?loader.LoadedProgram,
    records: []const compiler_diagnostics.Record,
    source_overlay: ?loader.SourceOverlay,
) !void {
    try registerSourceAliases(registry, root_path, root_text);
    if (loaded) |program| {
        for (program.source_paths, program.sources) |path, text| {
            try registerSourceAliases(registry, path, text);
        }
    }
    for (records) |record| {
        try ensureSource(registry, record.path, source_overlay);
        for (record.labels) |label| try ensureSource(registry, label.span.path, source_overlay);
    }
}

fn registerSourceAliases(
    registry: *diagnostic_sources.Registry,
    path: []const u8,
    text: []const u8,
) !void {
    if (registry.find(path) == null) _ = try registry.register(path, text);
    const canonical = compat.cwdRealpathAlloc(registry.allocator, path) catch return;
    defer registry.allocator.free(canonical);
    if (registry.find(canonical) == null) _ = try registry.register(canonical, text);
}

fn ensureSource(
    registry: *diagnostic_sources.Registry,
    path: []const u8,
    source_overlay: ?loader.SourceOverlay,
) !void {
    if (registry.find(path) != null) return;
    if (source_overlay) |overlay| {
        if (overlay.get(path)) |text| {
            try registerSourceAliases(registry, path, text);
            return;
        }
    }
    const canonical = compat.cwdRealpathAlloc(registry.allocator, path) catch null;
    defer if (canonical) |owned| registry.allocator.free(owned);
    if (canonical) |canonical_path| {
        if (registry.find(canonical_path) != null) return;
        if (source_overlay) |overlay| {
            if (overlay.get(canonical_path)) |text| {
                try registerSourceAliases(registry, canonical_path, text);
                return;
            }
        }
    }
    const text = compat.readFileAlloc(registry.allocator, path, 16 * 1024 * 1024) catch return;
    defer registry.allocator.free(text);
    try registerSourceAliases(registry, path, text);
}

fn moduleNameForPath(loaded: loader.LoadedProgram, path: []const u8) ?[]const u8 {
    const canonical_path = compat.cwdRealpathAlloc(std.heap.page_allocator, path) catch return null;
    defer std.heap.page_allocator.free(canonical_path);
    for (loaded.source_paths, loaded.module_names) |source_path, module_name| {
        if (std.mem.eql(u8, source_path, canonical_path)) return module_name;
    }
    return null;
}

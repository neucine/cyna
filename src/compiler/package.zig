const std = @import("std");
const compat = @import("../compat.zig");
const build_model = @import("../build/model.zig");
const diagnostics = @import("diagnostics.zig");

pub const StdArtifact = enum {
    std,
};

pub const bundled_package_names = @import("../runtime/inventory.zig").paths("package");

pub const AbiDecl = struct {
    name: []const u8,
    return_type: []const u8,
    signature: []const u8,
};

pub const PackageModule = struct {
    module_name: []const u8,
    path: []const u8,
    targets: [][]const u8,
    c_sources: [][]const u8,
    autoload: bool,

    pub fn deinit(self: PackageModule, allocator: std.mem.Allocator) void {
        allocator.free(self.module_name);
        allocator.free(self.path);
        freeStringSlice(allocator, self.targets);
        freeStringSlice(allocator, self.c_sources);
    }
};

pub const prelude_module_name = "std.prelude";

pub const std_prelude_print_decls = [_]AbiDecl{
    .{ .name = "cyna_std_prelude_print_string", .return_type = "void", .signature = "({ ptr, i64 })" },
    .{ .name = "cyna_std_prelude_print_int", .return_type = "void", .signature = "(i64, i1)" },
    .{ .name = "cyna_std_prelude_print_bool", .return_type = "void", .signature = "(i1)" },
    .{ .name = "cyna_std_prelude_print_newline", .return_type = "void", .signature = "()" },
    .{ .name = "cyna_std_prelude_panic", .return_type = "void", .signature = "({ ptr, i64 })" },
};

const PendingModule = struct {
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
    targets: [][]const u8 = &.{},
    c_sources: [][]const u8 = &.{},
    autoload: bool = false,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.path) |value| allocator.free(value);
        freeStringSlice(allocator, self.targets);
        freeStringSlice(allocator, self.c_sources);
        self.* = .{};
    }
};

pub fn loadStdModules(allocator: std.mem.Allocator) ![]PackageModule {
    return loadBundledPackageModules(allocator, "std");
}

pub fn loadBundledModules(allocator: std.mem.Allocator) ![]PackageModule {
    var modules = std.ArrayListUnmanaged(PackageModule).empty;
    errdefer {
        for (modules.items) |module| module.deinit(allocator);
        modules.deinit(allocator);
    }

    for (bundled_package_names) |package_name| {
        const package_modules = try loadBundledPackageModules(allocator, package_name);
        defer allocator.free(package_modules);
        for (package_modules) |module| {
            try modules.append(allocator, module);
        }
    }

    return modules.toOwnedSlice(allocator);
}

fn loadBundledPackageModules(allocator: std.mem.Allocator, package_name: []const u8) ![]PackageModule {
    const relative = try std.fs.path.join(allocator, &.{ "packages", package_name });
    defer allocator.free(relative);
    const package_root = try @import("../distribution_paths.zig").sourcePath(allocator, relative);
    defer allocator.free(package_root);
    return loadPackageModules(allocator, package_root);
}

pub fn stdArtifactForModuleName(allocator: std.mem.Allocator, module_name: []const u8) !?StdArtifact {
    const modules = try loadStdModules(allocator);
    defer {
        for (modules) |module| module.deinit(allocator);
        allocator.free(modules);
    }
    for (modules) |module| {
        if (std.mem.eql(u8, module.module_name, module_name)) {
            return .std;
        }
    }
    return null;
}

pub fn stdModuleSupportsTarget(allocator: std.mem.Allocator, module_name: []const u8, target_id: []const u8) !?bool {
    const modules = try loadStdModules(allocator);
    defer {
        for (modules) |module| module.deinit(allocator);
        allocator.free(modules);
    }
    for (modules) |module| {
        if (std.mem.eql(u8, module.module_name, module_name)) {
            return stringSliceContains(module.targets, target_id);
        }
    }
    return null;
}

pub fn bundledModuleSupportsTarget(allocator: std.mem.Allocator, module_name: []const u8, target_id: []const u8) !?bool {
    const modules = try loadBundledModules(allocator);
    defer {
        for (modules) |module| module.deinit(allocator);
        allocator.free(modules);
    }
    for (modules) |module| {
        if (std.mem.eql(u8, module.module_name, module_name)) {
            return stringSliceContains(module.targets, target_id);
        }
    }
    return null;
}

pub fn loadPackageModules(allocator: std.mem.Allocator, package_root: []const u8) ![]PackageModule {
    var diagnostic_context = diagnostics.Context.discarded();
    return loadPackageModulesWithDiagnostics(allocator, package_root, &diagnostic_context);
}

pub fn loadPackageModulesWithDiagnostics(
    allocator: std.mem.Allocator,
    package_root: []const u8,
    diagnostic_context: *diagnostics.Context,
) ![]PackageModule {
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root, "cyna.toml" });
    defer allocator.free(manifest_path);

    const source = compat.readFileAlloc(allocator, manifest_path, 1024 * 1024) catch |err| {
        try diagnostic_context.emitPath(manifest_path, @errorName(err));
        return err;
    };
    defer allocator.free(source);

    var src_root: []const u8 = try allocator.dupe(u8, package_root);
    defer allocator.free(src_root);

    var modules: std.ArrayListUnmanaged(PackageModule) = .empty;
    errdefer {
        for (modules.items) |module| module.deinit(allocator);
        modules.deinit(allocator);
    }

    var pending: ?PendingModule = null;
    defer if (pending) |*module| module.deinit(allocator);

    var line_it = std.mem.tokenizeScalar(u8, source, '\n');
    var in_module = false;
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.eql(u8, line, "[[module]]")) {
            if (pending) |*module| {
                try appendModule(allocator, &modules, src_root, module);
                module.deinit(allocator);
            }
            pending = .{};
            in_module = true;
            continue;
        }

        if (line[0] == '[') {
            in_module = false;
            continue;
        }

        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");

        if (in_module) {
            if (pending == null) pending = .{};
            const module = &pending.?;
            if (std.mem.eql(u8, key, "name")) {
                if (module.name) |existing| allocator.free(existing);
                module.name = try parseQuotedString(allocator, value);
            } else if (std.mem.eql(u8, key, "path")) {
                if (module.path) |existing| allocator.free(existing);
                module.path = try parseQuotedString(allocator, value);
            } else if (std.mem.eql(u8, key, "targets")) {
                freeStringSlice(allocator, module.targets);
                module.targets = try parseStringList(allocator, value);
            } else if (std.mem.eql(u8, key, "c")) {
                freeStringSlice(allocator, module.c_sources);
                module.c_sources = try parseStringList(allocator, value);
            } else if (std.mem.eql(u8, key, "autoload")) {
                module.autoload = try parseBoolValue(value);
            }
            continue;
        }

        if (std.mem.eql(u8, key, "src")) {
            const rel = try parseQuotedString(allocator, value);
            defer allocator.free(rel);
            allocator.free(src_root);
            src_root = try resolvePathAgainstRoot(allocator, package_root, rel);
        }
    }

    if (pending) |*module| {
        try appendModule(allocator, &modules, src_root, module);
        module.deinit(allocator);
        pending = null;
    }

    return modules.toOwnedSlice(allocator);
}

fn appendModule(
    allocator: std.mem.Allocator,
    modules: *std.ArrayListUnmanaged(PackageModule),
    src_root: []const u8,
    pending: *const PendingModule,
) !void {
    const module_name = pending.name orelse return error.InvalidManifest;
    const relpath = pending.path orelse return error.InvalidManifest;
    if (pending.targets.len == 0) return error.InvalidManifest;
    try validateTargets(pending.targets);
    const joined = try resolvePathAgainstRoot(allocator, src_root, relpath);
    defer allocator.free(joined);
    const canonical_path = try compat.cwdRealpathAlloc(allocator, joined);
    errdefer allocator.free(canonical_path);
    const canonical_c_sources = try resolveSourcesAgainstRoot(allocator, src_root, pending.c_sources);
    errdefer freeStringSlice(allocator, canonical_c_sources);
    try modules.append(allocator, .{
        .module_name = try allocator.dupe(u8, module_name),
        .path = canonical_path,
        .targets = try dupStringSlice(allocator, pending.targets),
        .c_sources = canonical_c_sources,
        .autoload = pending.autoload,
    });
}

fn parseQuotedString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidManifest;
    return allocator.dupe(u8, value[1 .. value.len - 1]);
}

fn parseBoolValue(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidManifest;
}

fn resolvePathAgainstRoot(allocator: std.mem.Allocator, root: []const u8, rel: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(rel)) return allocator.dupe(u8, rel);
    return std.fs.path.join(allocator, &.{ root, rel });
}

fn resolveSourcesAgainstRoot(allocator: std.mem.Allocator, root: []const u8, rel_paths: [][]const u8) ![][]const u8 {
    var resolved = try allocator.alloc([]const u8, rel_paths.len);
    var len: usize = 0;
    errdefer {
        for (resolved[0..len]) |item| allocator.free(item);
        allocator.free(resolved);
    }
    for (rel_paths, 0..) |rel, index| {
        const joined = try resolvePathAgainstRoot(allocator, root, rel);
        defer allocator.free(joined);
        resolved[index] = try compat.cwdRealpathAlloc(allocator, joined);
        len += 1;
    }
    return resolved;
}

fn parseStringList(allocator: std.mem.Allocator, value: []const u8) ![][]const u8 {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') return error.InvalidManifest;
    const inner = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    if (inner.len == 0) return allocator.alloc([]const u8, 0);

    var items = std.ArrayListUnmanaged([]const u8).empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }

    var parts = std.mem.splitScalar(u8, inner, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        try items.append(allocator, try parseQuotedString(allocator, trimmed));
    }
    return items.toOwnedSlice(allocator);
}

fn dupStringSlice(allocator: std.mem.Allocator, values: [][]const u8) ![][]const u8 {
    var copy = try allocator.alloc([]const u8, values.len);
    var len: usize = 0;
    errdefer {
        for (copy[0..len]) |item| allocator.free(item);
        allocator.free(copy);
    }
    for (values, 0..) |value, index| {
        copy[index] = try allocator.dupe(u8, value);
        len += 1;
    }
    return copy;
}

fn freeStringSlice(allocator: std.mem.Allocator, values: [][]const u8) void {
    if (values.len == 0) return;
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn validateTargets(targets: [][]const u8) !void {
    for (targets) |target| {
        if (!isSupportedTargetId(target)) return error.InvalidManifest;
    }
}

fn isSupportedTargetId(target_id: []const u8) bool {
    for (std.meta.tags(build_model.ToolchainHost)) |host| {
        if (std.mem.eql(u8, build_model.toolchainHostTag(host), target_id)) return true;
    }
    for (build_model.supported_targets) |target| {
        if (std.mem.eql(u8, target.target_support.id, target_id)) return true;
    }
    return false;
}

fn moduleSupportsAnyFreestandingTarget(targets: [][]const u8) bool {
    for (targets) |target_id| {
        if (isFreestandingTargetId(target_id)) return true;
    }
    return false;
}

fn isFreestandingTargetId(target_id: []const u8) bool {
    for (build_model.supported_targets) |target| {
        if (std.mem.eql(u8, target.target_support.id, target_id)) return target.freestanding;
    }
    return false;
}

fn stringSliceContains(values: [][]const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

test "load std modules parses target and c metadata" {
    const modules = try loadStdModules(std.testing.allocator);
    defer {
        for (modules) |module| module.deinit(std.testing.allocator);
        std.testing.allocator.free(modules);
    }

    var saw_prelude = false;
    var saw_fs = false;
    for (modules) |module| {
        if (std.mem.eql(u8, module.module_name, "std.prelude")) {
            saw_prelude = true;
            try std.testing.expect(module.autoload);
            try std.testing.expect(stringSliceContains(module.targets, "aarch64-apple-darwin"));
            try std.testing.expect(stringSliceContains(module.targets, "thumbv7em-none-eabi"));
            try std.testing.expectEqual(@as(usize, 1), module.c_sources.len);
        } else if (std.mem.eql(u8, module.module_name, "std.fs")) {
            saw_fs = true;
            try std.testing.expect(!stringSliceContains(module.targets, "thumbv7em-none-eabi"));
            try std.testing.expectEqual(@as(usize, 1), module.c_sources.len);
        }
    }
    try std.testing.expect(saw_prelude);
    try std.testing.expect(saw_fs);
}

test "load bundled modules includes embedded package" {
    const modules = try loadBundledModules(std.testing.allocator);
    defer {
        for (modules) |module| module.deinit(std.testing.allocator);
        std.testing.allocator.free(modules);
    }

    var saw_std_prelude = false;
    var saw_embedded_hal = false;
    var saw_embedded_arch = false;
    for (modules) |module| {
        if (std.mem.eql(u8, module.module_name, prelude_module_name)) {
            saw_std_prelude = true;
        } else if (std.mem.eql(u8, module.module_name, "embedded.hal")) {
            saw_embedded_hal = true;
        } else if (std.mem.eql(u8, module.module_name, "embedded.arch")) {
            saw_embedded_arch = true;
        }
    }

    try std.testing.expect(saw_std_prelude);
    try std.testing.expect(saw_embedded_hal);
    try std.testing.expect(saw_embedded_arch);
}

test "std artifact is derived from supported targets" {
    try std.testing.expectEqual(StdArtifact.std, (try stdArtifactForModuleName(std.testing.allocator, "std.alloc")).?);
    try std.testing.expectEqual(StdArtifact.std, (try stdArtifactForModuleName(std.testing.allocator, "std.fs")).?);
    try std.testing.expectEqual(StdArtifact.std, (try stdArtifactForModuleName(std.testing.allocator, "std.path")).?);
    try std.testing.expectEqual(StdArtifact.std, (try stdArtifactForModuleName(std.testing.allocator, "std.time")).?);
    try std.testing.expectEqual(StdArtifact.std, (try stdArtifactForModuleName(std.testing.allocator, "std.testing")).?);
}

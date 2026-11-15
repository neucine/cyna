const std = @import("std");
const compat = @import("../compat.zig");
const build_pkg = @import("../build.zig");
const diagnostics = @import("../compiler/diagnostics.zig");
const toolchain = @import("../build/toolchain.zig");
const build_model = build_pkg.model;

pub const InstallDependency = struct {
    name: []const u8,
    path: ?[]const u8 = null,
    version: ?[]const u8 = null,
    registry: ?[]const u8 = null,
    url: ?[]const u8 = null,

    pub fn deinit(self: InstallDependency, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.path) |value| allocator.free(value);
        if (self.version) |value| allocator.free(value);
        if (self.registry) |value| allocator.free(value);
        if (self.url) |value| allocator.free(value);
    }
};

pub const InstallLockDependency = struct {
    dependency_name: []const u8,
    package_name: []const u8,
    version: []const u8,
    registry: ?[]const u8 = null,
    url: ?[]const u8 = null,

    pub fn deinit(self: InstallLockDependency, allocator: std.mem.Allocator) void {
        allocator.free(self.dependency_name);
        allocator.free(self.package_name);
        allocator.free(self.version);
        if (self.registry) |value| allocator.free(value);
        if (self.url) |value| allocator.free(value);
    }
};

pub const ResolvedInstallPackage = struct {
    root_dir: []const u8,
    manifest_path: []const u8,
    manifest_source: []const u8,
    name: []const u8,
    version: []const u8,
    src: []const u8,
    installable: bool,

    pub fn deinit(self: ResolvedInstallPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.root_dir);
        allocator.free(self.manifest_path);
        allocator.free(self.manifest_source);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.src);
    }
};

pub const PackageManifest = struct {
    root_dir: []const u8,
    manifest_path: []const u8,
    manifest_source: []const u8,
    name: []const u8,
    version: []const u8,
    src: []const u8,

    pub fn deinit(self: *PackageManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.root_dir);
        allocator.free(self.manifest_path);
        allocator.free(self.manifest_source);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.src);
        self.* = undefined;
    }
};

pub const ManifestDependencySpec = struct {
    path: ?[]const u8 = null,
    version: ?[]const u8 = null,
    registry: ?[]const u8 = null,
    url: ?[]const u8 = null,

    pub fn deinit(self: *ManifestDependencySpec, allocator: std.mem.Allocator) void {
        if (self.path) |value| allocator.free(value);
        if (self.version) |value| allocator.free(value);
        if (self.registry) |value| allocator.free(value);
        if (self.url) |value| allocator.free(value);
        self.* = undefined;
    }
};

const EnsureInstallOptions = struct {
    verbose: bool = false,
    diagnostic_context: diagnostics.Context = .{ .destination = .discard },
};

pub fn installCommand(allocator: std.mem.Allocator, input_path: ?[]const u8) !void {
    try ensureInstalledWithOptions(allocator, input_path, .{ .verbose = true });
}

pub fn installCommandWithDiagnostics(allocator: std.mem.Allocator, input_path: ?[]const u8, diagnostic_context: diagnostics.Context) !void {
    try ensureInstalledWithOptions(allocator, input_path, .{
        .verbose = true,
        .diagnostic_context = diagnostic_context,
    });
}

pub fn ensureInstalled(allocator: std.mem.Allocator, input_path: ?[]const u8) !void {
    try ensureInstalledWithOptions(allocator, input_path, .{});
}

pub fn ensureInstalledWithDiagnostics(allocator: std.mem.Allocator, input_path: ?[]const u8, diagnostic_context: diagnostics.Context) !void {
    try ensureInstalledWithOptions(allocator, input_path, .{ .diagnostic_context = diagnostic_context });
}

fn ensureInstalledWithOptions(allocator: std.mem.Allocator, input_path: ?[]const u8, options: EnsureInstallOptions) !void {
    var diagnostic_context = options.diagnostic_context;
    var target = build_model.resolveBuildTargetForConfigWithDiagnostics(allocator, input_path, null, &diagnostic_context) catch |err| {
        if (err == error.ProjectNotFound or err == error.InvalidManifest or err == error.UnsupportedTarget) return;
        return err;
    };
    defer target.deinit(allocator);

    try toolchain.ensureDistributionInstalledWithDiagnostics(allocator, input_path, diagnostic_context);

    const manifest_path = target.manifest_path orelse {
        if (options.verbose) {
            std.debug.print("distribution ready; no project manifest found\n", .{});
        }
        return;
    };

    const home = try compat.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const packages = try collectInstallPackagesWithHomeAndDiagnostics(allocator, manifest_path, home, diagnostic_context);
    defer {
        for (packages) |pkg| pkg.deinit(allocator);
        allocator.free(packages);
    }

    if (packages.len == 0) {
        if (options.verbose) {
            std.debug.print("distribution ready; no manifest dependencies declared\n", .{});
        }
        return;
    }

    const lock_dependencies = try collectInstallLockDependenciesWithDiagnostics(allocator, manifest_path, home, diagnostic_context);
    defer {
        for (lock_dependencies) |dependency| dependency.deinit(allocator);
        allocator.free(lock_dependencies);
    }
    try writeProjectLockfile(allocator, manifest_path, lock_dependencies);

    var installed_count: usize = 0;
    var verified_count: usize = 0;
    for (packages) |pkg| {
        if (pkg.installable) {
            const install_root = try installPackageAtHome(allocator, home, pkg);
            defer allocator.free(install_root);
            installed_count += 1;
            if (options.verbose) {
                std.debug.print("installed {s}@{s} -> {s}\n", .{ pkg.name, pkg.version, install_root });
            }
        } else {
            verified_count += 1;
            if (options.verbose) {
                std.debug.print("verified installed {s}@{s}\n", .{ pkg.name, pkg.version });
            }
        }
    }
    if (options.verbose) {
        std.debug.print("wrote lockfile for {d} dependencies\n", .{lock_dependencies.len});
        std.debug.print("distribution ready; installed {d}, verified {d}\n", .{ installed_count, verified_count });
    }
}

test "install dependency parser reads local path dependencies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "app"
        \\entry = "src/main.cy"
        \\
        \\[dependencies]
        \\std = "../std"
        \\util = "../util"
        ,
    });

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    const dependencies = try parseInstallDependencies(std.testing.allocator, manifest_path);
    defer {
        for (dependencies) |dependency| dependency.deinit(std.testing.allocator);
        std.testing.allocator.free(dependencies);
    }

    try std.testing.expectEqual(@as(usize, 2), dependencies.len);
    try std.testing.expectEqualStrings("std", dependencies[0].name);
    try std.testing.expectEqualStrings("../std", dependencies[0].path.?);
    try std.testing.expectEqualStrings("util", dependencies[1].name);
    try std.testing.expectEqualStrings("../util", dependencies[1].path.?);
}

test "install dependency parser reads inline table dependencies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "app"
        \\version = "0.1.0"
        \\entry = "src/main.cy"
        \\
        \\[dependencies]
        \\util = { path = "../util", version = "0.2.0" }
        ,
    });

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    const dependencies = try parseInstallDependencies(std.testing.allocator, manifest_path);
    defer {
        for (dependencies) |dependency| dependency.deinit(std.testing.allocator);
        std.testing.allocator.free(dependencies);
    }

    try std.testing.expectEqual(@as(usize, 1), dependencies.len);
    try std.testing.expectEqualStrings("util", dependencies[0].name);
    try std.testing.expectEqualStrings("../util", dependencies[0].path.?);
    try std.testing.expectEqualStrings("0.2.0", dependencies[0].version.?);
}

test "install dependency parser reads version-only dependencies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "app"
        \\version = "0.1.0"
        \\entry = "src/main.cy"
        \\
        \\[dependencies]
        \\util = { version = "0.2.0" }
        ,
    });

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    const dependencies = try parseInstallDependencies(std.testing.allocator, manifest_path);
    defer {
        for (dependencies) |dependency| dependency.deinit(std.testing.allocator);
        std.testing.allocator.free(dependencies);
    }

    try std.testing.expectEqual(@as(usize, 1), dependencies.len);
    try std.testing.expectEqualStrings("util", dependencies[0].name);
    try std.testing.expect(dependencies[0].path == null);
    try std.testing.expectEqualStrings("0.2.0", dependencies[0].version.?);
}

test "install collects recursive local packages once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app/src");
    try compat.dirMakePath(tmp.dir, "util/src");
    try compat.dirMakePath(tmp.dir, "core/src");

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/cyna.toml",
        .data =
        \\name = "app"
        \\version = "0.1.0"
        \\entry = "src/main.cy"
        \\
        \\[dependencies]
        \\util = "../util"
        \\core = "../core"
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "util/cyna.toml",
        .data =
        \\name = "util"
        \\version = "0.2.0"
        \\src = "src"
        \\
        \\[dependencies]
        \\core = "../core"
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "core/cyna.toml",
        .data =
        \\name = "core"
        \\version = "1.0.0"
        \\src = "src"
        ,
    });

    const app_manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app/cyna.toml");
    defer std.testing.allocator.free(app_manifest_path);

    const packages = try collectInstallPackages(std.testing.allocator, app_manifest_path);
    defer {
        for (packages) |pkg| pkg.deinit(std.testing.allocator);
        std.testing.allocator.free(packages);
    }

    try std.testing.expectEqual(@as(usize, 2), packages.len);
    try std.testing.expectEqualStrings("util", packages[0].name);
    try std.testing.expectEqualStrings("0.2.0", packages[0].version);
    try std.testing.expectEqualStrings("core", packages[1].name);
    try std.testing.expectEqualStrings("1.0.0", packages[1].version);
}

test "installed package root path uses compiler-owned package layout" {
    const path = try installedPackageRootPath(std.testing.allocator, "/tmp/home", "std", "0.1.0");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/home/.cyna/packages/std/0.1.0", path);
}

test "install stages source package into compiler-owned package root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "home");
    try compat.dirMakePath(tmp.dir, "pkg/src/lib");
    try compat.dirMakePath(tmp.dir, "core/src");
    try compat.dirMakePath(tmp.dir, "pkg/include");
    try compat.dirMakePath(tmp.dir, "pkg/lib");

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "pkg/cyna.toml",
        .data =
        \\name = "util"
        \\version = "0.1.0"
        \\src = "src"
        \\
        \\[dependencies]
        \\core = "../core"
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "core/cyna.toml",
        .data =
        \\name = "core"
        \\version = "1.0.0"
        \\src = "src"
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "pkg/src/lib/math.cy",
        .data =
        \\pub fn forty_two(): i32 {
        \\    return 42;
        \\}
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "pkg/include/util.h", .data = "/* util */\n" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "pkg/lib/libutil.a", .data = "archive\n" });

    const pkg_manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "pkg/cyna.toml");
    defer std.testing.allocator.free(pkg_manifest_path);
    var manifest = try loadPackageManifest(std.testing.allocator, pkg_manifest_path);
    defer manifest.deinit(std.testing.allocator);

    const pkg = ResolvedInstallPackage{
        .root_dir = try std.testing.allocator.dupe(u8, manifest.root_dir),
        .manifest_path = try std.testing.allocator.dupe(u8, manifest.manifest_path),
        .manifest_source = try std.testing.allocator.dupe(u8, manifest.manifest_source),
        .name = try std.testing.allocator.dupe(u8, manifest.name),
        .version = try std.testing.allocator.dupe(u8, manifest.version),
        .src = try std.testing.allocator.dupe(u8, manifest.src),
        .installable = true,
    };
    defer pkg.deinit(std.testing.allocator);

    const home = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "home");
    defer std.testing.allocator.free(home);

    const install_root = try installPackageAtHome(std.testing.allocator, home, pkg);
    defer std.testing.allocator.free(install_root);

    const staged_manifest = try std.fs.path.join(std.testing.allocator, &.{ install_root, "manifest.toml" });
    defer std.testing.allocator.free(staged_manifest);
    const staged_source = try std.fs.path.join(std.testing.allocator, &.{ install_root, "src", "lib", "math.cy" });
    defer std.testing.allocator.free(staged_source);
    const staged_header = try std.fs.path.join(std.testing.allocator, &.{ install_root, "include", "util.h" });
    defer std.testing.allocator.free(staged_header);
    const staged_library = try std.fs.path.join(std.testing.allocator, &.{ install_root, "lib", "libutil.a" });
    defer std.testing.allocator.free(staged_library);

    try compat.access(staged_manifest, .{});
    try compat.access(staged_source, .{});
    try compat.access(staged_header, .{});
    try compat.access(staged_library, .{});

    const staged_manifest_source = try compat.readFileAlloc(std.testing.allocator, staged_manifest, 1024 * 1024);
    defer std.testing.allocator.free(staged_manifest_source);
    try std.testing.expect(std.mem.indexOf(u8, staged_manifest_source, "../core") == null);
    try std.testing.expect(std.mem.indexOf(u8, staged_manifest_source, "core = { version = \"1.0.0\" }") != null);
}

test "install preserves registry metadata while removing local path references from staged manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "home/.cyna/packages/core/1.2.0/src");
    try compat.dirMakePath(tmp.dir, "pkg/src");

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "pkg/cyna.toml",
        .data =
        \\name = "util"
        \\version = "0.1.0"
        \\src = "src"
        \\
        \\[dependencies]
        \\core = { registry = "central", version = "1.2.0" }
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "home/.cyna/packages/core/1.2.0/manifest.toml",
        .data =
        \\name = "core"
        \\version = "1.2.0"
        \\src = "src"
        ,
    });

    const pkg_manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "pkg/cyna.toml");
    defer std.testing.allocator.free(pkg_manifest_path);
    var manifest = try loadPackageManifest(std.testing.allocator, pkg_manifest_path);
    defer manifest.deinit(std.testing.allocator);

    const pkg = ResolvedInstallPackage{
        .root_dir = try std.testing.allocator.dupe(u8, manifest.root_dir),
        .manifest_path = try std.testing.allocator.dupe(u8, manifest.manifest_path),
        .manifest_source = try std.testing.allocator.dupe(u8, manifest.manifest_source),
        .name = try std.testing.allocator.dupe(u8, manifest.name),
        .version = try std.testing.allocator.dupe(u8, manifest.version),
        .src = try std.testing.allocator.dupe(u8, manifest.src),
        .installable = true,
    };
    defer pkg.deinit(std.testing.allocator);

    const home = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "home");
    defer std.testing.allocator.free(home);

    const install_root = try installPackageAtHome(std.testing.allocator, home, pkg);
    defer std.testing.allocator.free(install_root);
    const staged_manifest = try std.fs.path.join(std.testing.allocator, &.{ install_root, "manifest.toml" });
    defer std.testing.allocator.free(staged_manifest);
    const staged_manifest_source = try compat.readFileAlloc(std.testing.allocator, staged_manifest, 1024 * 1024);
    defer std.testing.allocator.free(staged_manifest_source);

    try std.testing.expect(std.mem.indexOf(u8, staged_manifest_source, "registry = \"central\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, staged_manifest_source, "core = { registry = \"central\", version = \"1.2.0\" }") != null);
}

test "install collects version-only dependencies from installed package store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "home/.cyna/packages/util/0.2.0/src");
    try compat.dirMakePath(tmp.dir, "app/src");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/cyna.toml",
        .data =
        \\name = "app"
        \\version = "0.1.0"
        \\entry = "src/main.cy"
        \\
        \\[dependencies]
        \\util = { version = "0.2.0" }
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

    const app_manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app/cyna.toml");
    defer std.testing.allocator.free(app_manifest_path);

    const packages = try collectInstallPackagesWithHome(std.testing.allocator, app_manifest_path, home);
    defer {
        for (packages) |pkg| pkg.deinit(std.testing.allocator);
        std.testing.allocator.free(packages);
    }

    try std.testing.expectEqual(@as(usize, 1), packages.len);
    try std.testing.expectEqualStrings("util", packages[0].name);
    try std.testing.expectEqualStrings("0.2.0", packages[0].version);
    try std.testing.expect(!packages[0].installable);
}

test "install collects version-only dependencies from published package artifact root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "home");
    try compat.dirMakePath(tmp.dir, "publish/util/0.2.0/src");
    try compat.dirMakePath(tmp.dir, "app/src");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/cyna.toml",
        .data =
        \\name = "app"
        \\version = "0.1.0"
        \\entry = "src/main.cy"
        \\
        \\[dependencies]
        \\util = { version = "0.2.0" }
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "publish/util/0.2.0/manifest.toml",
        .data =
        \\name = "util"
        \\version = "0.2.0"
        \\src = "src"
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "publish/util/0.2.0/src/math.cy",
        .data =
        \\pub fn forty_two(): i32 {
        \\    return 42;
        \\}
        ,
    });

    const home = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "home");
    defer std.testing.allocator.free(home);
    const publish_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "publish");
    defer std.testing.allocator.free(publish_root);
    const app_manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app/cyna.toml");
    defer std.testing.allocator.free(app_manifest_path);

    const packages = try collectInstallPackagesWithArtifactRoot(std.testing.allocator, app_manifest_path, home, publish_root);
    defer {
        for (packages) |pkg| pkg.deinit(std.testing.allocator);
        std.testing.allocator.free(packages);
    }

    try std.testing.expectEqual(@as(usize, 1), packages.len);
    try std.testing.expectEqualStrings("util", packages[0].name);
    try std.testing.expectEqualStrings("0.2.0", packages[0].version);
    try std.testing.expect(!packages[0].installable);

    const installed_manifest = try std.fs.path.join(std.testing.allocator, &.{ home, ".cyna", "packages", "util", "0.2.0", "manifest.toml" });
    defer std.testing.allocator.free(installed_manifest);
    const installed_source = try std.fs.path.join(std.testing.allocator, &.{ home, ".cyna", "packages", "util", "0.2.0", "src", "math.cy" });
    defer std.testing.allocator.free(installed_source);
    try compat.access(installed_manifest, .{});
    try compat.access(installed_source, .{});
}

test "install dependency parser accepts registry dependency metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "app"
        \\version = "0.1.0"
        \\entry = "src/main.cy"
        \\
        \\[dependencies]
        \\util = { registry = "central", version = "0.2.0" }
        ,
    });

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    var dependency = try parseManifestDependencySpec(std.testing.allocator, manifest_path, "{ registry = \"central\", version = \"0.2.0\" }");
    defer dependency.deinit(std.testing.allocator);

    try std.testing.expect(dependency.path == null);
    try std.testing.expectEqualStrings("central", dependency.registry.?);
    try std.testing.expectEqualStrings("0.2.0", dependency.version.?);
}

test "install lock dependencies derive package versions from path and installed deps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app");
    try compat.dirMakePath(tmp.dir, "util/src");
    try compat.dirMakePath(tmp.dir, "home/.cyna/packages/core/1.2.0/src");

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/cyna.toml",
        .data =
        \\name = "app"
        \\version = "0.1.0"
        \\entry = "src/main.cy"
        \\
        \\[dependencies]
        \\util = { path = "../util", version = "0.2.0" }
        \\core = { registry = "central", version = "1.2.0" }
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "util/cyna.toml",
        .data =
        \\name = "util"
        \\version = "0.2.0"
        \\src = "src"
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "home/.cyna/packages/core/1.2.0/manifest.toml",
        .data =
        \\name = "core"
        \\version = "1.2.0"
        \\src = "src"
        ,
    });

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app/cyna.toml");
    defer std.testing.allocator.free(manifest_path);
    const home = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "home");
    defer std.testing.allocator.free(home);

    const dependencies = try collectInstallLockDependencies(std.testing.allocator, manifest_path, home);
    defer {
        for (dependencies) |dependency| dependency.deinit(std.testing.allocator);
        std.testing.allocator.free(dependencies);
    }

    try std.testing.expectEqual(@as(usize, 2), dependencies.len);
    try std.testing.expectEqualStrings("util", dependencies[0].dependency_name);
    try std.testing.expectEqualStrings("util", dependencies[0].package_name);
    try std.testing.expectEqualStrings("0.2.0", dependencies[0].version);
    try std.testing.expect(dependencies[0].registry == null);
    try std.testing.expectEqualStrings("core", dependencies[1].dependency_name);
    try std.testing.expectEqualStrings("core", dependencies[1].package_name);
    try std.testing.expectEqualStrings("1.2.0", dependencies[1].version);
    try std.testing.expectEqualStrings("central", dependencies[1].registry.?);
}

test "install lock dependencies resolve package metadata from published package artifact root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app");
    try compat.dirMakePath(tmp.dir, "home");
    try compat.dirMakePath(tmp.dir, "publish/core/1.2.0/src");

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/cyna.toml",
        .data =
        \\name = "app"
        \\version = "0.1.0"
        \\entry = "src/main.cy"
        \\
        \\[dependencies]
        \\core = { registry = "central", version = "1.2.0" }
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "publish/core/1.2.0/manifest.toml",
        .data =
        \\name = "core"
        \\version = "1.2.0"
        \\src = "src"
        ,
    });

    const home = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "home");
    defer std.testing.allocator.free(home);
    const publish_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "publish");
    defer std.testing.allocator.free(publish_root);
    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app/cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    const dependencies = try collectInstallLockDependenciesWithArtifactRoot(std.testing.allocator, manifest_path, home, publish_root, diagnostics.Context.discarded());
    defer {
        for (dependencies) |dependency| dependency.deinit(std.testing.allocator);
        std.testing.allocator.free(dependencies);
    }

    try std.testing.expectEqual(@as(usize, 1), dependencies.len);
    try std.testing.expectEqualStrings("core", dependencies[0].dependency_name);
    try std.testing.expectEqualStrings("core", dependencies[0].package_name);
    try std.testing.expectEqualStrings("1.2.0", dependencies[0].version);
    try std.testing.expectEqualStrings("central", dependencies[0].registry.?);

    const installed_manifest = try std.fs.path.join(std.testing.allocator, &.{ home, ".cyna", "packages", "core", "1.2.0", "manifest.toml" });
    defer std.testing.allocator.free(installed_manifest);
    try compat.access(installed_manifest, .{});
}

test "install writes cyna.lock for resolved dependencies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app");
    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app");
    defer std.testing.allocator.free(manifest_path);

    const dependencies = try std.testing.allocator.alloc(InstallLockDependency, 2);
    defer {
        for (dependencies) |dependency| dependency.deinit(std.testing.allocator);
        std.testing.allocator.free(dependencies);
    }
    dependencies[0] = .{
        .dependency_name = try std.testing.allocator.dupe(u8, "util"),
        .package_name = try std.testing.allocator.dupe(u8, "util"),
        .version = try std.testing.allocator.dupe(u8, "0.2.0"),
    };
    dependencies[1] = .{
        .dependency_name = try std.testing.allocator.dupe(u8, "core"),
        .package_name = try std.testing.allocator.dupe(u8, "core"),
        .version = try std.testing.allocator.dupe(u8, "1.2.0"),
        .registry = try std.testing.allocator.dupe(u8, "central"),
    };

    const project_manifest_path = try std.fs.path.join(std.testing.allocator, &.{ manifest_path, "cyna.toml" });
    defer std.testing.allocator.free(project_manifest_path);
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/cyna.toml",
        .data =
        \\name = "app"
        ,
    });

    try writeProjectLockfile(std.testing.allocator, project_manifest_path, dependencies);

    const lock_path = try std.fs.path.join(std.testing.allocator, &.{ manifest_path, "cyna.lock" });
    defer std.testing.allocator.free(lock_path);
    const lock_source = try compat.readFileAlloc(std.testing.allocator, lock_path, 1024 * 1024);
    defer std.testing.allocator.free(lock_source);

    try std.testing.expectEqualStrings(
        \\[dependency.util]
        \\package = "util"
        \\version = "0.2.0"
        \\
        \\[dependency.core]
        \\package = "core"
        \\version = "1.2.0"
        \\registry = "central"
        \\
    , lock_source);
}

pub fn loadPackageManifest(allocator: std.mem.Allocator, input_path: ?[]const u8) !PackageManifest {
    return loadPackageManifestWithDiagnostics(allocator, input_path, diagnostics.Context.discarded());
}

pub fn loadPackageManifestWithDiagnostics(allocator: std.mem.Allocator, input_path: ?[]const u8, diagnostic_context: diagnostics.Context) !PackageManifest {
    const requested = input_path orelse ".";
    const manifest_path = if (std.mem.endsWith(u8, requested, ".toml"))
        try compat.cwdRealpathAlloc(allocator, requested)
    else
        try resolveManifestPathFromRootWithDiagnostics(allocator, requested, diagnostic_context);
    errdefer allocator.free(manifest_path);

    const root_dir = blk: {
        const parent = std.fs.path.dirname(manifest_path) orelse ".";
        break :blk try allocator.dupe(u8, parent);
    };
    errdefer allocator.free(root_dir);

    const manifest_source = compat.readFileAlloc(allocator, manifest_path, 1024 * 1024) catch |err| {
        try diagnostic_context.emitPath(manifest_path, @errorName(err));
        return err;
    };
    errdefer allocator.free(manifest_source);

    const parsed = try parsePackageManifestSource(allocator, manifest_path, manifest_source, diagnostic_context);
    errdefer {
        allocator.free(parsed.name);
        allocator.free(parsed.version);
        allocator.free(parsed.src);
    }

    return .{
        .root_dir = root_dir,
        .manifest_path = manifest_path,
        .manifest_source = manifest_source,
        .name = parsed.name,
        .version = parsed.version,
        .src = parsed.src,
    };
}

pub fn resolveManifestPathFromRoot(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
    return resolveManifestPathFromRootWithDiagnostics(allocator, root_path, diagnostics.Context.discarded());
}

pub fn resolveManifestPathFromRootWithDiagnostics(allocator: std.mem.Allocator, root_path: []const u8, diagnostic_context: diagnostics.Context) ![]u8 {
    const root_dir = try compat.cwdRealpathAlloc(allocator, root_path);
    defer allocator.free(root_dir);
    const manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "cyna.toml" });
    errdefer allocator.free(manifest_path);
    if (!pathExists(manifest_path)) {
        try diagnostic_context.emitPath(root_path, "package pack requires cyna.toml");
        return error.FileNotFound;
    }
    return manifest_path;
}

fn parsePackageManifestSource(allocator: std.mem.Allocator, manifest_path: []const u8, source: []const u8, diagnostic_context: diagnostics.Context) !struct {
    name: []const u8,
    version: []const u8,
    src: []const u8,
} {
    var name: ?[]const u8 = null;
    errdefer if (name) |value| allocator.free(value);
    var version: ?[]const u8 = null;
    errdefer if (version) |value| allocator.free(value);
    var src: ?[]const u8 = null;
    errdefer if (src) |value| allocator.free(value);

    var line_it = std.mem.tokenizeScalar(u8, source, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') break;

        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
        if (std.mem.eql(u8, key, "name")) {
            if (name) |existing| allocator.free(existing);
            name = try parseQuotedString(allocator, manifest_path, value, diagnostic_context);
        } else if (std.mem.eql(u8, key, "version")) {
            if (version) |existing| allocator.free(existing);
            version = try parseQuotedString(allocator, manifest_path, value, diagnostic_context);
        } else if (std.mem.eql(u8, key, "src")) {
            if (src) |existing| allocator.free(existing);
            src = try parseQuotedString(allocator, manifest_path, value, diagnostic_context);
        }
    }

    if (name == null) {
        try diagnostic_context.emitPath(manifest_path, "package pack requires manifest `name`");
        return error.InvalidManifest;
    }
    if (version == null) {
        try diagnostic_context.emitPath(manifest_path, "package pack requires manifest `version`");
        return error.InvalidManifest;
    }

    return .{
        .name = name.?,
        .version = version.?,
        .src = src orelse try allocator.dupe(u8, "src"),
    };
}

fn parseQuotedString(allocator: std.mem.Allocator, manifest_path: []const u8, value: []const u8, diagnostic_context: diagnostics.Context) ![]u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') {
        try diagnostic_context.emitPath(manifest_path, "manifest values must be quoted strings");
        return error.InvalidManifest;
    }
    return allocator.dupe(u8, value[1 .. value.len - 1]);
}

pub fn collectInstallPackages(allocator: std.mem.Allocator, manifest_path: []const u8) ![]ResolvedInstallPackage {
    return collectInstallPackagesWithHomeAndDiagnostics(allocator, manifest_path, null, diagnostics.Context.discarded());
}

pub fn collectInstallPackagesWithHome(allocator: std.mem.Allocator, manifest_path: []const u8, home_override: ?[]const u8) ![]ResolvedInstallPackage {
    return collectInstallPackagesWithHomeAndDiagnostics(allocator, manifest_path, home_override, diagnostics.Context.discarded());
}

pub fn collectInstallPackagesWithHomeAndDiagnostics(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    home_override: ?[]const u8,
    diagnostic_context: diagnostics.Context,
) ![]ResolvedInstallPackage {
    return collectInstallPackagesWithArtifactRoot(allocator, manifest_path, home_override, null, diagnostic_context);
}

fn collectInstallPackagesWithArtifactRoot(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    home_override: ?[]const u8,
    artifact_root_override: ?[]const u8,
    diagnostic_context: diagnostics.Context,
) ![]ResolvedInstallPackage {
    var visited: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (visited.items) |value| allocator.free(value);
        visited.deinit(allocator);
    }

    var packages: std.ArrayListUnmanaged(ResolvedInstallPackage) = .empty;
    errdefer {
        for (packages.items) |pkg| pkg.deinit(allocator);
        packages.deinit(allocator);
    }

    try collectInstallPackagesRecursive(allocator, manifest_path, &visited, &packages, false, false, home_override, artifact_root_override, diagnostic_context);
    return packages.toOwnedSlice(allocator);
}

fn collectInstallPackagesRecursive(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    visited: *std.ArrayListUnmanaged([]const u8),
    packages: *std.ArrayListUnmanaged(ResolvedInstallPackage),
    record_self: bool,
    installable: bool,
    home_override: ?[]const u8,
    artifact_root_override: ?[]const u8,
    diagnostic_context: diagnostics.Context,
) !void {
    const canonical_manifest_path = try compat.cwdRealpathAlloc(allocator, manifest_path);
    errdefer allocator.free(canonical_manifest_path);
    if (stringListContains(visited.items, canonical_manifest_path)) {
        allocator.free(canonical_manifest_path);
        return;
    }
    try visited.append(allocator, canonical_manifest_path);

    const root_dir = blk: {
        const parent = std.fs.path.dirname(canonical_manifest_path) orelse ".";
        break :blk try allocator.dupe(u8, parent);
    };
    defer allocator.free(root_dir);

    if (record_self) {
        var manifest = try loadPackageManifestWithDiagnostics(allocator, canonical_manifest_path, diagnostic_context);
        try packages.append(allocator, .{
            .root_dir = manifest.root_dir,
            .manifest_path = manifest.manifest_path,
            .manifest_source = manifest.manifest_source,
            .name = manifest.name,
            .version = manifest.version,
            .src = manifest.src,
            .installable = installable,
        });
        manifest = undefined;
    }

    const dependencies = try parseInstallDependenciesWithDiagnostics(allocator, canonical_manifest_path, diagnostic_context);
    defer {
        for (dependencies) |dependency| dependency.deinit(allocator);
        allocator.free(dependencies);
    }

    for (dependencies) |dependency| {
        const dep_manifest_path = if (dependency.path) |dep_path| blk: {
            const dep_root = try resolvePathAgainstRoot(allocator, root_dir, dep_path);
            defer allocator.free(dep_root);
            break :blk try resolveManifestPathFromRootWithDiagnostics(allocator, dep_root, diagnostic_context);
        } else blk: {
            const version = dependency.version orelse {
                try diagnostic_context.emitPath(canonical_manifest_path, "dependency must declare `path` or `version`");
                return error.InvalidManifest;
            };
            const owned_home = if (home_override == null)
                compat.getEnvVarOwned(allocator, "HOME") catch {
                    try diagnostic_context.emitPath(canonical_manifest_path, "version-only dependencies require HOME to resolve installed packages");
                    return error.InvalidManifest;
                }
            else
                null;
            defer if (owned_home) |value| allocator.free(value);
            const home = home_override orelse owned_home.?;
            _ = try installPublishedPackageFromArtifactRoot(allocator, home, dependency.name, version, artifact_root_override, diagnostic_context);
            const installed_root = try installedPackageRootPath(allocator, home, dependency.name, version);
            defer allocator.free(installed_root);
            break :blk try resolveInstalledManifestPathFromRootWithDiagnostics(allocator, installed_root, diagnostic_context);
        };
        defer allocator.free(dep_manifest_path);

        try collectInstallPackagesRecursive(allocator, dep_manifest_path, visited, packages, true, dependency.path != null, home_override, artifact_root_override, diagnostic_context);
    }
}

pub fn parseInstallDependencies(allocator: std.mem.Allocator, manifest_path: []const u8) ![]InstallDependency {
    return parseInstallDependenciesWithDiagnostics(allocator, manifest_path, diagnostics.Context.discarded());
}

pub fn parseInstallDependenciesWithDiagnostics(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    diagnostic_context: diagnostics.Context,
) ![]InstallDependency {
    const source = compat.readFileAlloc(allocator, manifest_path, 1024 * 1024) catch |err| {
        try diagnostic_context.emitPath(manifest_path, @errorName(err));
        return err;
    };
    defer allocator.free(source);

    var dependencies: std.ArrayListUnmanaged(InstallDependency) = .empty;
    errdefer {
        for (dependencies.items) |dependency| dependency.deinit(allocator);
        dependencies.deinit(allocator);
    }

    var in_dependencies = false;
    var line_it = std.mem.tokenizeScalar(u8, source, '\n');
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
        var spec = try parseManifestDependencySpecWithDiagnostics(allocator, manifest_path, value, diagnostic_context);
        errdefer spec.deinit(allocator);
        const dep_path = spec.path;
        const dep_version = spec.version;
        const dep_registry = spec.registry;
        const dep_url = spec.url;
        spec.path = null;
        spec.version = null;
        spec.registry = null;
        spec.url = null;
        try dependencies.append(allocator, .{
            .name = try allocator.dupe(u8, key),
            .path = dep_path,
            .version = dep_version,
            .registry = dep_registry,
            .url = dep_url,
        });
    }

    return dependencies.toOwnedSlice(allocator);
}

pub fn parseManifestDependencySpec(allocator: std.mem.Allocator, manifest_path: []const u8, value: []const u8) !ManifestDependencySpec {
    return parseManifestDependencySpecWithDiagnostics(allocator, manifest_path, value, diagnostics.Context.discarded());
}

pub fn parseManifestDependencySpecWithDiagnostics(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    value: []const u8,
    diagnostic_context: diagnostics.Context,
) !ManifestDependencySpec {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return .{ .path = try parseQuotedString(allocator, manifest_path, value, diagnostic_context) };
    }
    if (value.len < 2 or value[0] != '{' or value[value.len - 1] != '}') {
        try diagnostic_context.emitPath(manifest_path, "dependency entries must be a quoted path or an inline table");
        return error.InvalidManifest;
    }

    var path: ?[]const u8 = null;
    errdefer if (path) |existing| allocator.free(existing);
    var version: ?[]const u8 = null;
    errdefer if (version) |existing| allocator.free(existing);
    var registry: ?[]const u8 = null;
    errdefer if (registry) |existing| allocator.free(existing);
    var url: ?[]const u8 = null;
    errdefer if (url) |existing| allocator.free(existing);

    const inner = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    if (inner.len == 0) {
        try diagnostic_context.emitPath(manifest_path, "dependency inline table must declare `path` or `version`");
        return error.InvalidManifest;
    }

    var parts = std.mem.splitScalar(u8, inner, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const eq_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
            try diagnostic_context.emitPath(manifest_path, "dependency inline table entries must use key = value");
            return error.InvalidManifest;
        };
        const key = std.mem.trim(u8, trimmed[0..eq_index], " \t");
        const field_value = std.mem.trim(u8, trimmed[eq_index + 1 ..], " \t");
        if (std.mem.eql(u8, key, "path")) {
            if (path) |existing| allocator.free(existing);
            path = try parseQuotedString(allocator, manifest_path, field_value, diagnostic_context);
        } else if (std.mem.eql(u8, key, "version")) {
            if (version) |existing| allocator.free(existing);
            version = try parseQuotedString(allocator, manifest_path, field_value, diagnostic_context);
        } else if (std.mem.eql(u8, key, "registry")) {
            if (registry) |existing| allocator.free(existing);
            registry = try parseQuotedString(allocator, manifest_path, field_value, diagnostic_context);
        } else if (std.mem.eql(u8, key, "url")) {
            if (url) |existing| allocator.free(existing);
            url = try parseQuotedString(allocator, manifest_path, field_value, diagnostic_context);
        } else {
            const message = try std.fmt.allocPrint(allocator, "unsupported dependency key `{s}`", .{key});
            defer allocator.free(message);
            try diagnostic_context.emitPath(manifest_path, message);
            return error.InvalidManifest;
        }
    }

    if (path == null and version == null and registry == null and url == null) {
        try diagnostic_context.emitPath(manifest_path, "dependency inline table must declare `path`, `version`, `registry`, or `url`");
        return error.InvalidManifest;
    }

    return .{ .path = path, .version = version, .registry = registry, .url = url };
}

fn stringListContains(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

pub fn collectInstallLockDependencies(allocator: std.mem.Allocator, manifest_path: []const u8, home: []const u8) ![]InstallLockDependency {
    return collectInstallLockDependenciesWithArtifactRoot(allocator, manifest_path, home, null, diagnostics.Context.discarded());
}

pub fn collectInstallLockDependenciesWithDiagnostics(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    home: []const u8,
    diagnostic_context: diagnostics.Context,
) ![]InstallLockDependency {
    return collectInstallLockDependenciesWithArtifactRoot(allocator, manifest_path, home, null, diagnostic_context);
}

fn collectInstallLockDependenciesWithArtifactRoot(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    home: []const u8,
    artifact_root_override: ?[]const u8,
    diagnostic_context: diagnostics.Context,
) ![]InstallLockDependency {
    const canonical_manifest_path = try compat.cwdRealpathAlloc(allocator, manifest_path);
    defer allocator.free(canonical_manifest_path);
    const root_dir = std.fs.path.dirname(canonical_manifest_path) orelse ".";

    const dependencies = try parseInstallDependenciesWithDiagnostics(allocator, canonical_manifest_path, diagnostic_context);
    defer {
        for (dependencies) |dependency| dependency.deinit(allocator);
        allocator.free(dependencies);
    }

    var lock_dependencies: std.ArrayListUnmanaged(InstallLockDependency) = .empty;
    errdefer {
        for (lock_dependencies.items) |dependency| dependency.deinit(allocator);
        lock_dependencies.deinit(allocator);
    }

    for (dependencies) |dependency| {
        if (dependency.path) |dep_path| {
            const dep_root = try resolvePathAgainstRoot(allocator, root_dir, dep_path);
            defer allocator.free(dep_root);
            const dep_manifest_path = try resolveManifestPathFromRootWithDiagnostics(allocator, dep_root, diagnostic_context);
            defer allocator.free(dep_manifest_path);

            var manifest = try loadPackageManifestWithDiagnostics(allocator, dep_manifest_path, diagnostic_context);
            defer manifest.deinit(allocator);

            try lock_dependencies.append(allocator, .{
                .dependency_name = try allocator.dupe(u8, dependency.name),
                .package_name = try allocator.dupe(u8, manifest.name),
                .version = try allocator.dupe(u8, manifest.version),
                .registry = if (dependency.registry) |value| try allocator.dupe(u8, value) else null,
                .url = if (dependency.url) |value| try allocator.dupe(u8, value) else null,
            });
            continue;
        }

        const version = dependency.version orelse {
            try diagnostic_context.emitPath(canonical_manifest_path, "dependency must declare `path` or `version`");
            return error.InvalidManifest;
        };
        _ = try installPublishedPackageFromArtifactRoot(allocator, home, dependency.name, version, artifact_root_override, diagnostic_context);
        const installed_root = try installedPackageRootPath(allocator, home, dependency.name, version);
        defer allocator.free(installed_root);
        const installed_manifest_path = try resolveInstalledManifestPathFromRootWithDiagnostics(allocator, installed_root, diagnostic_context);
        defer allocator.free(installed_manifest_path);
        var manifest = try loadPackageManifestWithDiagnostics(allocator, installed_manifest_path, diagnostic_context);
        defer manifest.deinit(allocator);

        try lock_dependencies.append(allocator, .{
            .dependency_name = try allocator.dupe(u8, dependency.name),
            .package_name = try allocator.dupe(u8, manifest.name),
            .version = try allocator.dupe(u8, manifest.version),
            .registry = if (dependency.registry) |value| try allocator.dupe(u8, value) else null,
            .url = if (dependency.url) |value| try allocator.dupe(u8, value) else null,
        });
    }

    return lock_dependencies.toOwnedSlice(allocator);
}

pub fn writeProjectLockfile(allocator: std.mem.Allocator, manifest_path: []const u8, dependencies: []const InstallLockDependency) !void {
    const canonical_manifest_path = try compat.cwdRealpathAlloc(allocator, manifest_path);
    defer allocator.free(canonical_manifest_path);
    const root_dir = std.fs.path.dirname(canonical_manifest_path) orelse ".";
    const lock_path = try std.fs.path.join(allocator, &.{ root_dir, "cyna.lock" });
    defer allocator.free(lock_path);

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(allocator);
    var text_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &text);

    for (dependencies, 0..) |dependency, i| {
        if (i != 0) try text_writer.writer.writeAll("\n");
        try text_writer.writer.print("[dependency.{s}]\n", .{dependency.dependency_name});
        try text_writer.writer.print("package = \"{s}\"\n", .{dependency.package_name});
        try text_writer.writer.print("version = \"{s}\"\n", .{dependency.version});
        if (dependency.registry) |value| {
            try text_writer.writer.print("registry = \"{s}\"\n", .{value});
        }
        if (dependency.url) |value| {
            try text_writer.writer.print("url = \"{s}\"\n", .{value});
        }
    }

    text = text_writer.toArrayList();
    try writeTextFile(lock_path, text.items);
}

fn renderInstalledManifestSource(allocator: std.mem.Allocator, pkg: ResolvedInstallPackage, home: []const u8) ![]u8 {
    const dependencies = try parseInstallDependencies(allocator, pkg.manifest_path);
    defer {
        for (dependencies) |dependency| dependency.deinit(allocator);
        allocator.free(dependencies);
    }
    if (dependencies.len == 0) return allocator.dupe(u8, pkg.manifest_source);

    const lock_dependencies = try collectInstallLockDependencies(allocator, pkg.manifest_path, home);
    defer {
        for (lock_dependencies) |dependency| dependency.deinit(allocator);
        allocator.free(lock_dependencies);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var line_it = std.mem.splitScalar(u8, pkg.manifest_source, '\n');
    var in_dependencies = false;
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (in_dependencies) {
            if (line.len > 0 and line[0] == '[') {
                in_dependencies = false;
                try out.appendSlice(allocator, raw_line);
                try out.append(allocator, '\n');
            }
            continue;
        }
        if (std.mem.eql(u8, line, "[dependencies]")) {
            in_dependencies = true;
            try renderInstalledDependencySection(allocator, &out, dependencies, lock_dependencies);
            continue;
        }
        try out.appendSlice(allocator, raw_line);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

fn renderInstalledDependencySection(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    dependencies: []const InstallDependency,
    lock_dependencies: []const InstallLockDependency,
) !void {
    try out.appendSlice(allocator, "[dependencies]\n");
    for (dependencies) |dependency| {
        const lock = findInstallLockDependency(lock_dependencies, dependency.name) orelse return error.InvalidManifest;
        try out.appendSlice(allocator, dependency.name);
        try out.appendSlice(allocator, " = ");
        if (dependency.registry) |registry| {
            const line = try std.fmt.allocPrint(allocator, "{{ registry = \"{s}\", version = \"{s}\" }}\n", .{ registry, lock.version });
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        } else if (dependency.url) |url| {
            const line = try std.fmt.allocPrint(allocator, "{{ url = \"{s}\", version = \"{s}\" }}\n", .{ url, lock.version });
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        } else {
            const line = try std.fmt.allocPrint(allocator, "{{ version = \"{s}\" }}\n", .{lock.version});
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        }
    }
}

fn findInstallLockDependency(lock_dependencies: []const InstallLockDependency, dependency_name: []const u8) ?InstallLockDependency {
    for (lock_dependencies) |dependency| {
        if (std.mem.eql(u8, dependency.dependency_name, dependency_name)) return dependency;
    }
    return null;
}

pub fn installPackageAtHome(allocator: std.mem.Allocator, home: []const u8, pkg: ResolvedInstallPackage) ![]u8 {
    const install_root = try installedPackageRootPath(allocator, home, pkg.name, pkg.version);
    errdefer allocator.free(install_root);

    _ = deleteTreeIfExists(install_root);
    try compat.makePath(install_root);

    const installed_manifest_source = try renderInstalledManifestSource(allocator, pkg, home);
    defer allocator.free(installed_manifest_source);
    const staged_manifest_path = try std.fs.path.join(allocator, &.{ install_root, "manifest.toml" });
    defer allocator.free(staged_manifest_path);
    try writeTextFile(staged_manifest_path, installed_manifest_source);

    const src_root = try resolvePathAgainstRoot(allocator, pkg.root_dir, pkg.src);
    defer allocator.free(src_root);
    const staged_src_root = try std.fs.path.join(allocator, &.{ install_root, pkg.src });
    defer allocator.free(staged_src_root);
    try copyTree(src_root, staged_src_root);

    const include_root = try std.fs.path.join(allocator, &.{ pkg.root_dir, "include" });
    defer allocator.free(include_root);
    if (pathExists(include_root)) {
        const staged_include_root = try std.fs.path.join(allocator, &.{ install_root, "include" });
        defer allocator.free(staged_include_root);
        try copyTree(include_root, staged_include_root);
    }

    const lib_root = try std.fs.path.join(allocator, &.{ pkg.root_dir, "lib" });
    defer allocator.free(lib_root);
    if (pathExists(lib_root)) {
        const staged_lib_root = try std.fs.path.join(allocator, &.{ install_root, "lib" });
        defer allocator.free(staged_lib_root);
        try copyTree(lib_root, staged_lib_root);
    }

    return install_root;
}

pub fn installedPackageRootPath(allocator: std.mem.Allocator, home: []const u8, name: []const u8, version: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ home, ".cyna", "packages", name, version });
}

fn installPublishedPackageFromArtifactRoot(
    allocator: std.mem.Allocator,
    home: []const u8,
    name: []const u8,
    version: []const u8,
    artifact_root_override: ?[]const u8,
    diagnostic_context: diagnostics.Context,
) !bool {
    const install_root = try installedPackageRootPath(allocator, home, name, version);
    defer allocator.free(install_root);
    if (pathExists(install_root)) return false;

    const artifact_root = try resolvePackageArtifactRoot(allocator, artifact_root_override, diagnostic_context);
    defer allocator.free(artifact_root);

    const published_root = try std.fs.path.join(allocator, &.{ artifact_root, name, version });
    defer allocator.free(published_root);
    if (!pathExists(published_root)) return false;

    const published_manifest = try std.fs.path.join(allocator, &.{ published_root, "manifest.toml" });
    defer allocator.free(published_manifest);
    if (!pathExists(published_manifest)) return false;

    _ = deleteTreeIfExists(install_root);
    if (std.fs.path.dirname(install_root)) |parent| {
        try compat.makePath(parent);
    }
    try copyTree(published_root, install_root);
    return true;
}

fn resolvePackageArtifactRoot(allocator: std.mem.Allocator, artifact_root_override: ?[]const u8, diagnostic_context: diagnostics.Context) ![]u8 {
    if (artifact_root_override) |value| return allocator.dupe(u8, value);
    if (compat.getEnvVarOwned(allocator, "CYNA_PACKAGE_ARTIFACT_ROOT")) |value| return value else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = try std.process.executablePath(compat.io(), &exe_buf);
    const exe_path = try allocator.dupe(u8, exe_buf[0..exe_len]);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse {
        try diagnostic_context.emitPath(".", "unable to derive package artifact root; set CYNA_PACKAGE_ARTIFACT_ROOT");
        return error.FileNotFound;
    };
    const prefix = if (std.mem.eql(u8, std.fs.path.basename(exe_dir), "bin"))
        (std.fs.path.dirname(exe_dir) orelse exe_dir)
    else
        exe_dir;
    return std.fs.path.join(allocator, &.{ prefix, "share", "cyna", "packages" });
}

pub fn resolveInstalledManifestPathFromRoot(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
    return resolveInstalledManifestPathFromRootWithDiagnostics(allocator, root_path, diagnostics.Context.discarded());
}

pub fn resolveInstalledManifestPathFromRootWithDiagnostics(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    diagnostic_context: diagnostics.Context,
) ![]u8 {
    const manifest_path = try std.fs.path.join(allocator, &.{ root_path, "manifest.toml" });
    errdefer allocator.free(manifest_path);
    if (!pathExists(manifest_path)) {
        try diagnostic_context.emitPath(root_path, "installed package is missing manifest.toml");
        return error.FileNotFound;
    }
    return manifest_path;
}

fn deleteTreeIfExists(path: []const u8) bool {
    compat.deleteTree(path) catch return false;
    return true;
}

fn pathExists(path: []const u8) bool {
    compat.access(path, .{}) catch return false;
    return true;
}

fn resolvePathAgainstRoot(allocator: std.mem.Allocator, root_dir: []const u8, value: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(value)) return allocator.dupe(u8, value);
    return std.fs.path.join(allocator, &.{ root_dir, value });
}

fn copyTree(from_root: []const u8, to_root: []const u8) !void {
    try compat.makePath(to_root);

    var src_dir = try compat.openDirAbsolute(from_root, .{ .iterate = true });
    defer compat.closeDir(src_dir);
    var walker = try src_dir.walk(std.heap.page_allocator);
    defer walker.deinit();

    while (try compat.walkerNext(&walker)) |entry| {
        const src_path = try std.fs.path.join(std.heap.page_allocator, &.{ from_root, entry.path });
        defer std.heap.page_allocator.free(src_path);
        const dst_path = try std.fs.path.join(std.heap.page_allocator, &.{ to_root, entry.path });
        defer std.heap.page_allocator.free(dst_path);

        switch (entry.kind) {
            .directory => try compat.makePath(dst_path),
            .file => {
                if (std.fs.path.dirname(dst_path)) |parent| {
                    try compat.makePath(parent);
                }
                try std.Io.Dir.copyFileAbsolute(src_path, dst_path, compat.io(), .{});
            },
            else => {},
        }
    }
}

fn writeTextFile(path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try compat.makePath(parent);
    }
    const file = try compat.createFile(path, .{ .truncate = true });
    defer compat.closeFile(file);
    try compat.fileWriteAll(file, text);
}

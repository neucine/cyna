const std = @import("std");
const compat = @import("../compat.zig");
const build_pkg = @import("../build.zig");
const compiler_package = @import("../compiler/package.zig");
const diagnostics = @import("../compiler/diagnostics.zig");
const install = @import("install.zig");

const build_model = build_pkg.model;
const native_mod = build_pkg.native;

const BuiltLibrary = struct {
    target_id: []const u8,
    archive_path: []const u8,

    fn deinit(self: BuiltLibrary, allocator: std.mem.Allocator) void {
        allocator.free(self.target_id);
        allocator.free(self.archive_path);
    }
};

const StagedLibrary = struct {
    target_id: []const u8,
    relative_path: []const u8,
    sha256: []const u8,

    fn deinit(self: StagedLibrary, allocator: std.mem.Allocator) void {
        allocator.free(self.target_id);
        allocator.free(self.relative_path);
        allocator.free(self.sha256);
    }
};

pub fn packageBuildCommand(allocator: std.mem.Allocator, input_path: ?[]const u8) !void {
    return packageBuildCommandWithDiagnostics(allocator, input_path, diagnostics.Context.discarded());
}

pub fn packageBuildCommandWithDiagnostics(allocator: std.mem.Allocator, input_path: ?[]const u8, diagnostic_context: diagnostics.Context) !void {
    var manifest = try install.loadPackageManifestWithDiagnostics(allocator, input_path, diagnostic_context);
    defer manifest.deinit(allocator);

    var mutable_diagnostics = diagnostic_context;
    const modules = try compiler_package.loadPackageModulesWithDiagnostics(allocator, manifest.root_dir, &mutable_diagnostics);
    defer {
        for (modules) |module| module.deinit(allocator);
        allocator.free(modules);
    }

    const built = try buildPackageLibraries(allocator, manifest, modules, diagnostic_context);
    defer {
        for (built) |lib| lib.deinit(allocator);
        allocator.free(built);
    }

    if (built.len == 0) {
        std.debug.print("package build: no package-owned native sources declared for {s}\n", .{manifest.name});
        return;
    }

    std.debug.print("package build: built {d} target libraries for {s}@{s}\n", .{ built.len, manifest.name, manifest.version });
}

pub fn packagePackCommand(allocator: std.mem.Allocator, input_path: ?[]const u8) !void {
    return packagePackCommandWithDiagnostics(allocator, input_path, diagnostics.Context.discarded());
}

pub fn packagePackCommandWithDiagnostics(allocator: std.mem.Allocator, input_path: ?[]const u8, diagnostic_context: diagnostics.Context) !void {
    var manifest = try install.loadPackageManifestWithDiagnostics(allocator, input_path, diagnostic_context);
    defer manifest.deinit(allocator);

    const stage_root = try stageRootPath(allocator, manifest);
    defer allocator.free(stage_root);
    const staged_libraries = try stagePackageAtRoot(allocator, manifest, stage_root);
    defer {
        for (staged_libraries) |library| library.deinit(allocator);
        allocator.free(staged_libraries);
    }

    std.debug.print("packed package to {s}\n", .{stage_root});
}

pub fn packagePublishCommand(allocator: std.mem.Allocator, input_path: ?[]const u8) !void {
    return packagePublishCommandWithDiagnostics(allocator, input_path, diagnostics.Context.discarded());
}

pub fn packagePublishCommandWithDiagnostics(allocator: std.mem.Allocator, input_path: ?[]const u8, diagnostic_context: diagnostics.Context) !void {
    var manifest = try install.loadPackageManifestWithDiagnostics(allocator, input_path, diagnostic_context);
    defer manifest.deinit(allocator);

    const stage_root = try stageRootPath(allocator, manifest);
    defer allocator.free(stage_root);
    const staged_libraries = try stagePackageAtRoot(allocator, manifest, stage_root);
    defer {
        for (staged_libraries) |library| library.deinit(allocator);
        allocator.free(staged_libraries);
    }

    const publish_root = try resolvePackagePublishRoot(allocator, diagnostic_context);
    defer allocator.free(publish_root);
    try publishPackageStageAtRoot(allocator, manifest, stage_root, publish_root, diagnostic_context);
}

fn publishPackageStageAtRoot(
    allocator: std.mem.Allocator,
    manifest: install.PackageManifest,
    stage_root: []const u8,
    publish_root: []const u8,
    diagnostic_context: diagnostics.Context,
) !void {
    const destination = try std.fs.path.join(allocator, &.{ publish_root, manifest.name, manifest.version });
    defer allocator.free(destination);
    if (pathExists(destination)) {
        try diagnostic_context.emitPath(destination, "package version already published");
        return error.PathAlreadyExists;
    }

    if (std.fs.path.dirname(destination)) |parent| {
        try compat.makePath(parent);
    }
    try copyTree(stage_root, destination);

    std.debug.print("published package to {s}\n", .{destination});
}

fn stagePackageAtRoot(
    allocator: std.mem.Allocator,
    manifest: install.PackageManifest,
    stage_root: []const u8,
) ![]StagedLibrary {
    _ = deleteTreeIfExists(stage_root);
    try compat.makePath(stage_root);

    const src_root = try resolvePathAgainstRoot(allocator, manifest.root_dir, manifest.src);
    defer allocator.free(src_root);
    const staged_src_root = try std.fs.path.join(allocator, &.{ stage_root, "src" });
    defer allocator.free(staged_src_root);
    try copyTree(src_root, staged_src_root);

    const include_root = try std.fs.path.join(allocator, &.{ manifest.root_dir, "include" });
    defer allocator.free(include_root);
    if (pathExists(include_root)) {
        const staged_include_root = try std.fs.path.join(allocator, &.{ stage_root, "include" });
        defer allocator.free(staged_include_root);
        try copyTree(include_root, staged_include_root);
    }

    const built_libraries = try collectBuiltLibraries(allocator, manifest.root_dir, manifest.name);
    defer {
        for (built_libraries) |library| library.deinit(allocator);
        allocator.free(built_libraries);
    }

    var staged_libraries = std.ArrayListUnmanaged(StagedLibrary).empty;
    errdefer {
        for (staged_libraries.items) |library| library.deinit(allocator);
        staged_libraries.deinit(allocator);
    }

    for (built_libraries) |library| {
        const archive_name = std.fs.path.basename(library.archive_path);
        const relative_path = try std.fs.path.join(allocator, &.{ "lib", library.target_id, archive_name });
        errdefer allocator.free(relative_path);
        const staged_archive_path = try std.fs.path.join(allocator, &.{ stage_root, relative_path });
        defer allocator.free(staged_archive_path);
        try copyFileAbsolute(library.archive_path, staged_archive_path);
        const sha256 = try hashFileSha256Hex(allocator, staged_archive_path);
        errdefer allocator.free(sha256);
        try staged_libraries.append(allocator, .{
            .target_id = try allocator.dupe(u8, library.target_id),
            .relative_path = relative_path,
            .sha256 = sha256,
        });
    }

    const staged_manifest_source = try renderDistributionManifest(allocator, manifest, staged_libraries.items);
    defer allocator.free(staged_manifest_source);
    const staged_manifest_path = try std.fs.path.join(allocator, &.{ stage_root, "manifest.toml" });
    defer allocator.free(staged_manifest_path);
    try writeTextFile(staged_manifest_path, staged_manifest_source);

    return staged_libraries.toOwnedSlice(allocator);
}

fn stageRootPath(allocator: std.mem.Allocator, manifest: install.PackageManifest) ![]u8 {
    return std.fs.path.join(allocator, &.{ manifest.root_dir, "dist", "packages", manifest.name, manifest.version });
}

fn buildPackageLibraries(
    allocator: std.mem.Allocator,
    manifest: install.PackageManifest,
    modules: []const compiler_package.PackageModule,
    diagnostic_context: diagnostics.Context,
) ![]BuiltLibrary {
    var built = std.ArrayListUnmanaged(BuiltLibrary).empty;
    errdefer {
        for (built.items) |library| library.deinit(allocator);
        built.deinit(allocator);
    }

    const include_root = try std.fs.path.join(allocator, &.{ manifest.root_dir, "include" });
    defer allocator.free(include_root);
    const has_include_root = pathExists(include_root);

    for (build_model.supported_targets) |supported_target| {
        const target_id = supported_target.target_support.id;

        var sources = std.ArrayListUnmanaged([]const u8).empty;
        defer sources.deinit(allocator);
        for (modules) |module| {
            if (!stringSliceContains(module.targets, target_id)) continue;
            try sources.appendSlice(allocator, module.c_sources);
        }
        if (sources.items.len == 0) continue;

        const c_sources = try dupStringSlice(allocator, sources.items);
        errdefer freeStringSlice(allocator, c_sources);

        var include_paths = try allocator.alloc([]const u8, if (has_include_root) 1 else 0);
        errdefer {
            for (include_paths) |item| allocator.free(item);
            allocator.free(include_paths);
        }
        if (has_include_root) include_paths[0] = try allocator.dupe(u8, include_root);

        var target = try buildPackageTarget(allocator, manifest, target_id, c_sources, include_paths);
        defer target.deinit(allocator);

        const archive_name = try std.fmt.allocPrint(allocator, "libcyna_{s}.a", .{manifest.name});
        defer allocator.free(archive_name);
        const output_path = try std.fs.path.join(allocator, &.{ manifest.root_dir, "build", "package", target_id, "lib", archive_name });
        errdefer allocator.free(output_path);

        try native_mod.compileNativeSourcesToStaticLibraryWithDiagnostics(allocator, target, output_path, diagnostic_context);
        try writePackageBuildMetadata(allocator, manifest, target_id, output_path, sources.items);
        try built.append(allocator, .{
            .target_id = try allocator.dupe(u8, target_id),
            .archive_path = output_path,
        });
        std.debug.print("built package library for {s}: {s}\n", .{ target_id, output_path });
    }

    return built.toOwnedSlice(allocator);
}

fn buildPackageTarget(
    allocator: std.mem.Allocator,
    manifest: install.PackageManifest,
    target_id: []const u8,
    c_sources: [][]const u8,
    include_paths: [][]const u8,
) !build_model.BuildTarget {
    const target_value: ?[]const u8 = if (isNativeTargetId(target_id))
        null
    else
        try allocator.dupe(u8, target_id);

    return .{
        .is_project = true,
        .display_path = try allocator.dupe(u8, manifest.manifest_path),
        .root_dir = try allocator.dupe(u8, manifest.root_dir),
        .source_path = try allocator.dupe(u8, manifest.manifest_path),
        .name = try allocator.dupe(u8, manifest.name),
        .target = target_value,
        .output_kind = .staticlib,
        .opt = .release,
        .c_sources = .{
            .sources = c_sources,
            .include_paths = include_paths,
            .flags = try allocator.alloc([]const u8, 0),
        },
        .asm_sources = .{},
        .manifest_path = try allocator.dupe(u8, manifest.manifest_path),
    };
}

fn collectBuiltLibraries(allocator: std.mem.Allocator, package_root: []const u8, package_name: []const u8) ![]BuiltLibrary {
    const build_root = try std.fs.path.join(allocator, &.{ package_root, "build", "package" });
    defer allocator.free(build_root);
    if (!pathExists(build_root)) return allocator.alloc(BuiltLibrary, 0);

    var dir = try compat.openDirAbsolute(build_root, .{ .iterate = true });
    defer compat.closeDir(dir);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    const archive_name = try std.fmt.allocPrint(allocator, "libcyna_{s}.a", .{package_name});
    defer allocator.free(archive_name);

    var built = std.ArrayListUnmanaged(BuiltLibrary).empty;
    errdefer {
        for (built.items) |library| library.deinit(allocator);
        built.deinit(allocator);
    }

    while (try compat.walkerNext(&walker)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(entry.path), archive_name)) continue;
        const target_id = blk: {
            const first_sep = std.mem.indexOfScalar(u8, entry.path, std.fs.path.sep) orelse continue;
            break :blk entry.path[0..first_sep];
        };
        const archive_path = try std.fs.path.join(allocator, &.{ build_root, entry.path });
        errdefer allocator.free(archive_path);
        try built.append(allocator, .{
            .target_id = try allocator.dupe(u8, target_id),
            .archive_path = archive_path,
        });
    }

    return built.toOwnedSlice(allocator);
}

fn renderDistributionManifest(
    allocator: std.mem.Allocator,
    manifest: install.PackageManifest,
    staged_libraries: []const StagedLibrary,
) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, manifest.manifest_source);
    if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }
    if (staged_libraries.len != 0 and (out.items.len == 0 or out.items[out.items.len - 1] != '\n')) {
        try out.append(allocator, '\n');
    }

    for (staged_libraries) |library| {
        const entry = try std.fmt.allocPrint(allocator,
            \\
            \\[[library]]
            \\target = "{s}"
            \\artifact = "{s}"
            \\path = "{s}"
            \\sha256 = "{s}"
            \\
        , .{ library.target_id, manifest.name, library.relative_path, library.sha256 });
        defer allocator.free(entry);
        try out.appendSlice(allocator, entry);
    }
    return out.toOwnedSlice(allocator);
}

fn resolvePackagePublishRoot(allocator: std.mem.Allocator, diagnostic_context: diagnostics.Context) ![]u8 {
    if (compat.getEnvVarOwned(allocator, "CYNA_PACKAGE_ARTIFACT_ROOT")) |value| return value else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const exe_path = try compat.executablePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse {
        try diagnostic_context.emitPath(".", "unable to derive package publish root; set CYNA_PACKAGE_ARTIFACT_ROOT");
        return error.FileNotFound;
    };
    const prefix = if (std.mem.eql(u8, std.fs.path.basename(exe_dir), "bin"))
        (std.fs.path.dirname(exe_dir) orelse exe_dir)
    else
        exe_dir;
    return std.fs.path.join(allocator, &.{ prefix, "share", "cyna", "packages" });
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

fn isNativeTargetId(target_id: []const u8) bool {
    return std.mem.eql(u8, target_id, build_model.supported_targets[0].target_support.id);
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

fn copyFileAbsolute(from_path: []const u8, to_path: []const u8) !void {
    if (std.fs.path.dirname(to_path)) |parent| {
        try compat.makePath(parent);
    }
    try std.Io.Dir.copyFileAbsolute(from_path, to_path, compat.io(), .{});
}

fn writePackageBuildMetadata(
    allocator: std.mem.Allocator,
    manifest: install.PackageManifest,
    target_id: []const u8,
    archive_path: []const u8,
    sources: []const []const u8,
) !void {
    const metadata_path = try std.fs.path.join(allocator, &.{ manifest.root_dir, "build", "package", target_id, "metadata", "build.json" });
    defer allocator.free(metadata_path);

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);
    const header = try std.fmt.allocPrint(
        allocator,
        "{{\n  \"package\": \"{s}\",\n  \"version\": \"{s}\",\n  \"target\": \"{s}\",\n  \"archive\": \"{s}\",\n  \"sources\": [",
        .{ manifest.name, manifest.version, target_id, archive_path },
    );
    defer allocator.free(header);
    try out.appendSlice(allocator, header);
    for (sources, 0..) |source, index| {
        if (index != 0) try out.appendSlice(allocator, ", ");
        const item = try std.fmt.allocPrint(allocator, "\"{s}\"", .{source});
        defer allocator.free(item);
        try out.appendSlice(allocator, item);
    }
    try out.appendSlice(allocator, "]\n}\n");
    try writeTextFile(metadata_path, out.items);
}

fn hashFileSha256Hex(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const bytes = try compat.readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn dupStringSlice(allocator: std.mem.Allocator, values: []const []const u8) ![][]const u8 {
    var copy = try allocator.alloc([]const u8, values.len);
    var len: usize = 0;
    errdefer {
        for (copy[0..len]) |value| allocator.free(value);
        allocator.free(copy);
    }
    for (values, 0..) |value, index| {
        copy[index] = try allocator.dupe(u8, value);
        len += 1;
    }
    return copy;
}

fn freeStringSlice(allocator: std.mem.Allocator, values: [][]const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn stringSliceContains(values: [][]const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn writeTextFile(path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try compat.makePath(parent);
    }
    const file = try compat.createFile(path, .{ .truncate = true });
    defer compat.closeFile(file);
    try compat.fileWriteAll(file, text);
}

test "package pack stages versioned source package" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app/src/lib");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/cyna.toml",
        .data =
        \\name = "util"
        \\version = "0.1.0"
        \\src = "src"
        \\
        \\[dependencies]
        \\std = "../std"
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/src/lib/math.cy",
        .data =
        \\pub fn forty_two(): i32 {
        \\    return 42;
        \\}
        ,
    });

    const app_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app");
    defer std.testing.allocator.free(app_root);

    try packagePackCommand(std.testing.allocator, app_root);

    const staged_manifest = try std.fs.path.join(std.testing.allocator, &.{ app_root, "dist", "packages", "util", "0.1.0", "manifest.toml" });
    defer std.testing.allocator.free(staged_manifest);
    const staged_source = try std.fs.path.join(std.testing.allocator, &.{ app_root, "dist", "packages", "util", "0.1.0", "src", "lib", "math.cy" });
    defer std.testing.allocator.free(staged_source);

    try compat.access(staged_manifest, .{});
    try compat.access(staged_source, .{});
}

test "package pack requires manifest version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app/src");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/cyna.toml",
        .data =
        \\name = "util"
        \\src = "src"
        ,
    });

    const app_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app");
    defer std.testing.allocator.free(app_root);

    try std.testing.expectError(error.InvalidManifest, packagePackCommand(std.testing.allocator, app_root));
}

test "package build stages target library and metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "home");
    try compat.dirMakePath(tmp.dir, "app/src");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/cyna.toml",
        .data =
        \\name = "util"
        \\version = "0.1.0"
        \\src = "src"
        \\
        \\[[module]]
        \\name = "util.core"
        \\path = "util.cy"
        \\targets = ["aarch64-apple-darwin"]
        \\c = ["util.c"]
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/src/util.cy",
        .data =
        \\pub fn forty_two(): i32 {
        \\    return 42;
        \\}
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/src/util.c",
        .data =
        \\int cyna_util_value(void) {
        \\    return 42;
        \\}
        ,
    });

    const app_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app");
    defer std.testing.allocator.free(app_root);
    const home_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "home");
    defer std.testing.allocator.free(home_root);

    try installTestDistribution(std.testing.allocator, home_root, "aarch64-apple-darwin");
    var home_guard = try TestHomeGuard.set(std.testing.allocator, home_root);
    defer home_guard.deinit();

    try packageBuildCommand(std.testing.allocator, app_root);

    const archive_path = try std.fs.path.join(std.testing.allocator, &.{ app_root, "build", "package", "aarch64-apple-darwin", "lib", "libcyna_util.a" });
    defer std.testing.allocator.free(archive_path);
    const metadata_path = try std.fs.path.join(std.testing.allocator, &.{ app_root, "build", "package", "aarch64-apple-darwin", "metadata", "build.json" });
    defer std.testing.allocator.free(metadata_path);

    try compat.access(archive_path, .{});
    try compat.access(metadata_path, .{});
}

test "package pack stages built libraries into distribution manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "home");
    try compat.dirMakePath(tmp.dir, "app/src");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/cyna.toml",
        .data =
        \\name = "util"
        \\version = "0.1.0"
        \\src = "src"
        \\
        \\[[module]]
        \\name = "util.core"
        \\path = "util.cy"
        \\targets = ["aarch64-apple-darwin"]
        \\c = ["util.c"]
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/src/util.cy",
        .data =
        \\pub fn forty_two(): i32 {
        \\    return 42;
        \\}
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/src/util.c",
        .data =
        \\int cyna_util_value(void) {
        \\    return 42;
        \\}
        ,
    });

    const app_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app");
    defer std.testing.allocator.free(app_root);
    const home_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "home");
    defer std.testing.allocator.free(home_root);

    try installTestDistribution(std.testing.allocator, home_root, "aarch64-apple-darwin");
    var home_guard = try TestHomeGuard.set(std.testing.allocator, home_root);
    defer home_guard.deinit();

    try packageBuildCommand(std.testing.allocator, app_root);
    try packagePackCommand(std.testing.allocator, app_root);

    const staged_archive = try std.fs.path.join(std.testing.allocator, &.{ app_root, "dist", "packages", "util", "0.1.0", "lib", "aarch64-apple-darwin", "libcyna_util.a" });
    defer std.testing.allocator.free(staged_archive);
    const staged_manifest = try std.fs.path.join(std.testing.allocator, &.{ app_root, "dist", "packages", "util", "0.1.0", "manifest.toml" });
    defer std.testing.allocator.free(staged_manifest);
    const manifest_source = try compat.readFileAlloc(std.testing.allocator, staged_manifest, 1024 * 1024);
    defer std.testing.allocator.free(manifest_source);

    try compat.access(staged_archive, .{});
    try std.testing.expect(std.mem.indexOf(u8, manifest_source, "[[library]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_source, "path = \"lib/aarch64-apple-darwin/libcyna_util.a\"") != null);
}

test "package publish copies packed package into package artifact root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "home");
    try compat.dirMakePath(tmp.dir, "app/src");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/cyna.toml",
        .data =
        \\name = "util"
        \\version = "0.1.0"
        \\src = "src"
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "app/src/util.cy",
        .data =
        \\pub fn forty_two(): i32 {
        \\    return 42;
        \\}
        ,
    });

    const app_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app");
    defer std.testing.allocator.free(app_root);
    var manifest = try install.loadPackageManifest(std.testing.allocator, app_root);
    defer manifest.deinit(std.testing.allocator);
    const stage_root = try stageRootPath(std.testing.allocator, manifest);
    defer std.testing.allocator.free(stage_root);

    try packagePackCommand(std.testing.allocator, app_root);

    const home_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "home");
    defer std.testing.allocator.free(home_root);
    const publish_root = try std.fs.path.join(std.testing.allocator, &.{ home_root, "packages" });
    defer std.testing.allocator.free(publish_root);
    try publishPackageStageAtRoot(std.testing.allocator, manifest, stage_root, publish_root, diagnostics.Context.discarded());

    const published_manifest = try std.fs.path.join(std.testing.allocator, &.{ publish_root, "util", "0.1.0", "manifest.toml" });
    defer std.testing.allocator.free(published_manifest);
    try compat.access(published_manifest, .{});
}

const TestHomeGuard = struct {
    previous: ?[]u8,

    fn set(allocator: std.mem.Allocator, home: []const u8) !TestHomeGuard {
        const previous = compat.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        try setEnvVar("HOME", home);
        return .{ .previous = previous };
    }

    fn deinit(self: *TestHomeGuard) void {
        if (self.previous) |value| {
            setEnvVar("HOME", value) catch {};
            std.testing.allocator.free(value);
        } else {
            unsetEnvVar("HOME") catch {};
        }
        self.* = undefined;
    }
};

fn installTestDistribution(allocator: std.mem.Allocator, home: []const u8, target_id: []const u8) !void {
    const bundle = try build_model.supportedLlvmToolBundle(null);
    const clang_source = pickFirstExistingAbsolutePath(&.{
        "/opt/homebrew/opt/llvm/bin/clang",
        "/usr/local/opt/llvm/bin/clang",
        "/usr/bin/clang",
    }) orelse return error.FileNotFound;
    const ar_source = pickFirstExistingAbsolutePath(&.{
        "/opt/homebrew/opt/llvm/bin/llvm-ar",
        "/usr/local/opt/llvm/bin/llvm-ar",
        "/usr/bin/llvm-ar",
    }) orelse return error.FileNotFound;
    const version_root = try std.fs.path.join(allocator, &.{ home, ".cyna", build_model.cyna_version });
    defer allocator.free(version_root);
    try compat.makePath(version_root);

    const llvm_bin_dir = try std.fs.path.join(allocator, &.{ version_root, "llvm", "bin" });
    defer allocator.free(llvm_bin_dir);
    try compat.makePath(llvm_bin_dir);

    const clang_path = try std.fs.path.join(allocator, &.{ llvm_bin_dir, "clang" });
    defer allocator.free(clang_path);
    try createOrReplaceSymlink(clang_source, clang_path);

    const ar_path = try std.fs.path.join(allocator, &.{ llvm_bin_dir, "llvm-ar" });
    defer allocator.free(ar_path);
    try createOrReplaceSymlink(ar_source, ar_path);

    const clang_sha = try hashFileSha256Hex(allocator, clang_path);
    defer allocator.free(clang_sha);
    const ar_sha = try hashFileSha256Hex(allocator, ar_path);
    defer allocator.free(ar_sha);

    const bundle_manifest = try std.fmt.allocPrint(
        allocator,
        \\id = "llvm"
        \\version = "{s}"
        \\family = "llvm"
        \\host = "{s}"
        \\compiler = "bin/clang"
        \\compiler_sha256 = "{s}"
        \\archiver = "bin/llvm-ar"
        \\archiver_sha256 = "{s}"
        \\linker = ""
        \\linker_sha256 = ""
        \\objcopy = ""
        \\objcopy_sha256 = ""
        \\libllvm = ""
        \\libllvm_sha256 = ""
        \\libclang_cpp = ""
        \\libclang_cpp_sha256 = ""
        \\provisioned_from = "artifact"
        \\
    ,
        .{
            bundle.version,
            build_model.toolchainHostTag(build_model.supportedHost()),
            clang_sha,
            ar_sha,
        },
    );
    defer allocator.free(bundle_manifest);

    const bundle_manifest_path = try std.fs.path.join(allocator, &.{ version_root, "llvm", "bundle.toml" });
    defer allocator.free(bundle_manifest_path);
    try writeTextFile(bundle_manifest_path, bundle_manifest);

    const target_root = try std.fs.path.join(allocator, &.{ version_root, "lib", target_id });
    defer allocator.free(target_root);
    try compat.makePath(target_root);

    const include_dir = try std.fs.path.join(allocator, &.{ target_root, "include" });
    defer allocator.free(include_dir);
    try compat.makePath(include_dir);

    const payload_lib_dir = try std.fs.path.join(allocator, &.{ target_root, "lib" });
    defer allocator.free(payload_lib_dir);
    try compat.makePath(payload_lib_dir);

    const runtime_header_path = try std.fs.path.join(allocator, &.{ include_dir, "cyna.h" });
    defer allocator.free(runtime_header_path);
    try writeTextFile(runtime_header_path, "/* test runtime */\n");

    const runtime_archive_path = try std.fs.path.join(allocator, &.{ payload_lib_dir, "libcyna.a" });
    defer allocator.free(runtime_archive_path);
    try writeTextFile(runtime_archive_path, "runtime\n");

    const std_archive_path = try std.fs.path.join(allocator, &.{ payload_lib_dir, "libcyna_std.a" });
    defer allocator.free(std_archive_path);
    try writeTextFile(std_archive_path, "std\n");

    const runtime_header_sha = try hashFileSha256Hex(allocator, runtime_header_path);
    defer allocator.free(runtime_header_sha);
    const runtime_archive_sha = try hashFileSha256Hex(allocator, runtime_archive_path);
    defer allocator.free(runtime_archive_sha);
    const std_archive_sha = try hashFileSha256Hex(allocator, std_archive_path);
    defer allocator.free(std_archive_sha);

    const support_manifest = try std.fmt.allocPrint(
        allocator,
        \\kind = "target-support"
        \\target = "{s}"
        \\revision = 1
        \\provisioned_from = "compiler"
        \\runtime_header = "include/cyna.h"
        \\runtime_header_sha256 = "{s}"
        \\runtime_archive = "lib/libcyna.a"
        \\runtime_archive_sha256 = "{s}"
        \\std_archive = "lib/libcyna_std.a"
        \\std_archive_sha256 = "{s}"
        \\
    ,
        .{
            target_id,
            runtime_header_sha,
            runtime_archive_sha,
            std_archive_sha,
        },
    );
    defer allocator.free(support_manifest);

    const support_manifest_path = try std.fs.path.join(allocator, &.{ target_root, "manifest.toml" });
    defer allocator.free(support_manifest_path);
    try writeTextFile(support_manifest_path, support_manifest);
}

fn createOrReplaceSymlink(target: []const u8, link_path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(compat.io(), link_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.Io.Dir.symLinkAbsolute(compat.io(), target, link_path, .{});
}

fn pickFirstExistingAbsolutePath(candidates: []const []const u8) ?[]const u8 {
    for (candidates) |candidate| {
        if (compat.accessAbsolute(candidate, .{})) |_| return candidate else |_| {}
    }
    return null;
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

const c = struct {
    extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern fn unsetenv(name: [*:0]const u8) c_int;
    extern fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;
};

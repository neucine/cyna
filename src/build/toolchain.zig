const std = @import("std");
const compat = @import("../compat.zig");
const build_pkg = @import("../build.zig");
const diagnostics = @import("../compiler/diagnostics.zig");
const build_model = build_pkg.model;

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const runtime_archive_name = "libcyna.a";
pub const std_archive_name = "libcyna_std.a";

pub const StaticLibraryDependency = enum {
    runtime,
    std,

    pub fn archiveName(self: StaticLibraryDependency) []const u8 {
        return switch (self) {
            .runtime => runtime_archive_name,
            .std => std_archive_name,
        };
    }

    pub fn manifestName(self: StaticLibraryDependency) []const u8 {
        return switch (self) {
            .runtime => "runtime",
            .std => "std",
        };
    }
};

pub const ResolvedExecutable = struct {
    path: []const u8,
    owned: bool = false,
    source: enum {
        bundle,
        system,
    } = .system,

    pub fn deinit(self: ResolvedExecutable, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.path);
    }
};

pub const DistributionProbe = struct {
    llvm_bundle: build_model.ToolchainBundleSpec,
    target_support: build_model.TargetSupportSpec,
    family: build_model.ToolchainFamily,
    provisioned_bin_dir: ?[]const u8,
    cc: ?ResolvedExecutable,
    ar: ?ResolvedExecutable,
    lld: ?ResolvedExecutable,
    objcopy: ?ResolvedExecutable,

    pub fn deinit(self: *DistributionProbe, allocator: std.mem.Allocator) void {
        if (self.provisioned_bin_dir) |value| allocator.free(value);
        if (self.cc) |value| value.deinit(allocator);
        if (self.ar) |value| value.deinit(allocator);
        if (self.lld) |value| value.deinit(allocator);
        if (self.objcopy) |value| value.deinit(allocator);
        self.* = undefined;
    }

    fn readyForBuild(self: DistributionProbe) bool {
        return self.cc != null and self.ar != null;
    }

    fn readyForTarget(self: DistributionProbe, target: build_model.BuildTarget) bool {
        if (!self.readyForBuild()) return false;
        if (build_model.isFreestandingTarget(target.target)) {
            return self.lld != null;
        }
        return true;
    }

    fn readyForImageEmit(self: DistributionProbe) bool {
        return self.objcopy != null;
    }
};

pub const ResolvedDistributionTools = struct {
    cc: ResolvedExecutable,
    ar: ResolvedExecutable,
    lld: ?ResolvedExecutable,
    objcopy: ?ResolvedExecutable,
    cache_identity: [Sha256.digest_length]u8 = @splat(0),

    pub fn deinit(self: *ResolvedDistributionTools, allocator: std.mem.Allocator) void {
        self.cc.deinit(allocator);
        self.ar.deinit(allocator);
        if (self.lld) |value| value.deinit(allocator);
        if (self.objcopy) |value| value.deinit(allocator);
        self.* = undefined;
    }
};

const ToolchainArtifactRootUse = enum {
    fetch,
    approve,
};

const ToolchainArtifactSource = union(enum) {
    local_root: []const u8,
    remote_base_url: []const u8,

    fn deinit(self: *ToolchainArtifactSource, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .local_root => |value| allocator.free(value),
            .remote_base_url => |value| allocator.free(value),
        }
        self.* = undefined;
    }
};

const ToolchainFetchResult = struct {
    source: ToolchainArtifactSource,
    cache_dir: []const u8,
};

const ToolchainFetchReport = enum {
    detailed,
    quiet,
};

pub const ToolchainArtifactManifest = struct {
    id: []const u8 = "",
    version: []const u8 = "",
    family: []const u8 = "",
    host: []const u8 = "",
    compiler: []const u8 = "",
    compiler_sha256: []const u8 = "",
    archiver: []const u8 = "",
    archiver_sha256: []const u8 = "",
    linker: []const u8 = "",
    linker_sha256: []const u8 = "",
    objcopy: []const u8 = "",
    objcopy_sha256: []const u8 = "",
    libllvm: []const u8 = "",
    libllvm_sha256: []const u8 = "",
    libclang_cpp: []const u8 = "",
    libclang_cpp_sha256: []const u8 = "",
    compiler_rt_builtins: []const u8 = "",
    compiler_rt_builtins_sha256: []const u8 = "",
    resource_headers: []const u8 = "",
    resource_headers_sha256: []const u8 = "",
    provisioned_from: []const u8 = "",
};

const CompilerRtBuiltinsManifest = struct {
    paths: []const u8,
    hashes: []const u8,

    fn deinit(self: CompilerRtBuiltinsManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.paths);
        allocator.free(self.hashes);
    }
};

pub const TargetSupportManifest = struct {
    kind: []const u8 = "",
    target: []const u8 = "",
    revision: u32 = 0,
    provisioned_from: []const u8 = "",
    runtime_header: []const u8 = "",
    runtime_header_sha256: []const u8 = "",
    runtime_archive: []const u8 = "",
    runtime_archive_sha256: []const u8 = "",
    std_archive: []const u8 = "",
    std_archive_sha256: []const u8 = "",
};

pub fn ensureDistributionInstalled(allocator: std.mem.Allocator, input_path: ?[]const u8) !void {
    return ensureDistributionInstalledWithDiagnostics(allocator, input_path, diagnostics.Context.discarded());
}

pub fn ensureDistributionInstalledWithDiagnostics(
    allocator: std.mem.Allocator,
    input_path: ?[]const u8,
    diagnostic_context: diagnostics.Context,
) !void {
    try ensureSupportedCompilerHost(diagnostic_context, input_path orelse "<distribution>");
    var mutable_diagnostics = diagnostic_context;
    var target = build_model.resolveBuildTargetForConfigWithDiagnostics(allocator, input_path, null, &mutable_diagnostics) catch |err| {
        if (err == error.ProjectNotFound or err == error.InvalidManifest or err == error.UnsupportedTarget) return;
        return err;
    };
    defer target.deinit(allocator);

    try installToolchainBundleForTarget(diagnostic_context, allocator, target, true);
}

pub fn resolveDistributionTools(allocator: std.mem.Allocator, target: build_model.BuildTarget) !ResolvedDistributionTools {
    return resolveDistributionToolsWithDiagnostics(allocator, target, diagnostics.Context.discarded());
}

pub fn resolveDistributionToolsWithDiagnostics(
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    diagnostic_context: diagnostics.Context,
) !ResolvedDistributionTools {
    try ensureSupportedCompilerHost(diagnostic_context, target.root_dir);
    if (target.target != null) {
        try ensureTargetSupportForTarget(diagnostic_context, allocator, target, false);
    }

    var probe = try probeDistribution(allocator, target);
    if (probe.provisioned_bin_dir == null or !probe.readyForTarget(target)) {
        probe.deinit(allocator);
        std.debug.print("auto-provisioning toolchain bundle for target `{s}`\n", .{target.target orelse "native"});
        try installToolchainBundleForTarget(diagnostic_context, allocator, target, false);
        probe = try probeDistribution(allocator, target);
    }
    defer probe.deinit(allocator);

    const cc = try requireTool(diagnostic_context, probe.cc, target, "clang");
    probe.cc = null;
    const ar = try requireTool(diagnostic_context, probe.ar, target, "llvm-ar or ar");
    probe.ar = null;
    const lld = probe.lld;
    probe.lld = null;
    const objcopy = probe.objcopy;
    probe.objcopy = null;

    var resolved: ResolvedDistributionTools = .{
        .cc = cc,
        .ar = ar,
        .lld = lld,
        .objcopy = objcopy,
    };
    errdefer resolved.deinit(allocator);
    resolved.cache_identity = try distributionCacheIdentity(allocator, resolved, probe.provisioned_bin_dir.?);
    return resolved;
}

fn ensureSupportedCompilerHost(diagnostic_context: diagnostics.Context, display_path: []const u8) !void {
    const builtin = @import("builtin");
    if (build_model.isSupportedCompilerHost(builtin.os.tag, builtin.cpu.arch)) return;
    try diagnostic_context.emitPath(display_path, "unsupported compiler host: this distribution supports aarch64-apple-darwin and x86_64-unknown-linux-gnu");
    return error.UnsupportedHost;
}

// Fingerprint actual installed inputs, not the release label or the expected
// digests in a manifest. Resolve once per tool set, before worker fan-out.
fn distributionCacheIdentity(allocator: std.mem.Allocator, tools: ResolvedDistributionTools, bin_dir: []const u8) ![Sha256.digest_length]u8 {
    var hash = Sha256.init(.{});
    hash.update("cyna-resolved-tools-v1\x00");
    try hashCacheFile(allocator, &hash, "compiler", tools.cc.path);
    try hashCacheFile(allocator, &hash, "archiver", tools.ar.path);
    if (tools.lld) |tool| try hashCacheFile(allocator, &hash, "linker", tool.path);
    if (tools.objcopy) |tool| try hashCacheFile(allocator, &hash, "objcopy", tool.path);
    const root = std.fs.path.dirname(bin_dir) orelse return error.InvalidPath;
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "bundle.toml" });
    defer allocator.free(manifest_path);
    const source = try compat.readFileAlloc(allocator, manifest_path, 512 * 1024);
    defer allocator.free(source);
    hash.update(source);
    const manifest = try parseToolchainArtifactManifest(source);
    for ([_][]const u8{ manifest.libllvm, manifest.libclang_cpp, manifest.compiler_rt_builtins, manifest.resource_headers }) |paths| {
        var items = std.mem.splitScalar(u8, paths, ',');
        while (items.next()) |item| {
            const relative = std.mem.trim(u8, item, " \t");
            if (relative.len == 0) continue;
            const path = try std.fs.path.join(allocator, &.{ root, relative });
            defer allocator.free(path);
            try hashCacheFile(allocator, &hash, relative, path);
        }
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn hashCacheFile(allocator: std.mem.Allocator, hash: *Sha256, role: []const u8, path: []const u8) !void {
    const digest = try hashFileSha256Hex(allocator, path);
    defer allocator.free(digest);
    hash.update(role);
    hash.update("\x00");
    hash.update(digest);
    hash.update("\x00");
}

pub fn requireObjcopy(
    allocator: std.mem.Allocator,
    resolved_tools: ResolvedDistributionTools,
    target: build_model.BuildTarget,
    flag_name: []const u8,
) ![]const u8 {
    return requireObjcopyWithDiagnostics(allocator, resolved_tools, target, flag_name, diagnostics.Context.discarded());
}

pub fn requireObjcopyWithDiagnostics(
    allocator: std.mem.Allocator,
    resolved_tools: ResolvedDistributionTools,
    target: build_model.BuildTarget,
    flag_name: []const u8,
    diagnostic_context: diagnostics.Context,
) ![]const u8 {
    _ = allocator;
    return if (resolved_tools.objcopy) |value|
        value.path
    else {
        var buf: [192]u8 = undefined;
        const target_name = target.target orelse "native";
        const message = std.fmt.bufPrint(&buf, "{s} requires llvm-objcopy or objcopy for target `{s}`", .{ flag_name, target_name }) catch "requested artifact requires llvm-objcopy or objcopy";
        try diagnostic_context.emitPath(target.display_path, message);
        return error.NativeCompileFailed;
    };
}

pub fn toolchainBundleRootPath(allocator: std.mem.Allocator, home: []const u8, bundle: build_model.ToolchainBundleSpec) ![]u8 {
    _ = bundle;
    return std.fs.path.join(allocator, &.{ home, ".cyna", build_model.cyna_version, "llvm" });
}

pub fn cachedToolchainBundleRootPath(allocator: std.mem.Allocator, home: []const u8, bundle: build_model.ToolchainBundleSpec) ![]u8 {
    _ = bundle;
    return std.fs.path.join(allocator, &.{ home, ".cyna", "cache", build_model.cyna_version, build_model.toolchainHostTag(build_model.supportedHost()), "llvm" });
}

pub fn targetSupportRootPath(allocator: std.mem.Allocator, home: []const u8, support: build_model.TargetSupportSpec) ![]u8 {
    _ = support.revision;
    return std.fs.path.join(allocator, &.{ home, ".cyna", build_model.cyna_version, "targets", support.id });
}

pub fn cachedTargetSupportRootPath(allocator: std.mem.Allocator, home: []const u8, support: build_model.TargetSupportSpec) ![]u8 {
    _ = support.revision;
    return std.fs.path.join(allocator, &.{ home, ".cyna", "cache", build_model.cyna_version, build_model.toolchainHostTag(build_model.supportedHost()), "targets", support.id });
}

fn legacyCachedToolchainBundleRootPath(allocator: std.mem.Allocator, home: []const u8, bundle: build_model.ToolchainBundleSpec) ![]u8 {
    _ = bundle;
    return std.fs.path.join(allocator, &.{ home, ".cyna", "cache", "distributions", build_model.cyna_version, build_model.toolchainHostTag(build_model.supportedHost()), "llvm" });
}

fn legacyCachedTargetSupportRootPath(allocator: std.mem.Allocator, home: []const u8, support: build_model.TargetSupportSpec) ![]u8 {
    _ = support.revision;
    return std.fs.path.join(allocator, &.{ home, ".cyna", "cache", "distributions", build_model.cyna_version, build_model.toolchainHostTag(build_model.supportedHost()), "targets", support.id });
}

pub fn toolchainArtifactFileUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    bundle: build_model.ToolchainBundleSpec,
    host: build_model.ToolchainHost,
    relative_path: []const u8,
) ![]u8 {
    _ = bundle;
    _ = host;
    const trimmed_base = std.mem.trimEnd(u8, base_url, "/");
    return std.fmt.allocPrint(allocator, "{s}/llvm/{s}", .{ trimmed_base, relative_path });
}

pub fn parseToolchainArtifactManifest(source: []const u8) !ToolchainArtifactManifest {
    var manifest: ToolchainArtifactManifest = .{};
    var line_it = std.mem.tokenizeScalar(u8, source, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidManifest;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        const value = try parseQuotedManifestValue(std.mem.trim(u8, line[eq_index + 1 ..], " \t"));
        if (std.mem.eql(u8, key, "resource_headers")) {
            manifest.resource_headers = value;
            continue;
        }
        if (std.mem.eql(u8, key, "resource_headers_sha256")) {
            manifest.resource_headers_sha256 = value;
            continue;
        }
        if (std.mem.eql(u8, key, "id")) manifest.id = value else if (std.mem.eql(u8, key, "version")) manifest.version = value else if (std.mem.eql(u8, key, "family")) manifest.family = value else if (std.mem.eql(u8, key, "host")) manifest.host = value else if (std.mem.eql(u8, key, "compiler")) manifest.compiler = value else if (std.mem.eql(u8, key, "compiler_sha256")) manifest.compiler_sha256 = value else if (std.mem.eql(u8, key, "archiver")) manifest.archiver = value else if (std.mem.eql(u8, key, "archiver_sha256")) manifest.archiver_sha256 = value else if (std.mem.eql(u8, key, "linker")) manifest.linker = value else if (std.mem.eql(u8, key, "linker_sha256")) manifest.linker_sha256 = value else if (std.mem.eql(u8, key, "objcopy")) manifest.objcopy = value else if (std.mem.eql(u8, key, "objcopy_sha256")) manifest.objcopy_sha256 = value else if (std.mem.eql(u8, key, "libllvm")) manifest.libllvm = value else if (std.mem.eql(u8, key, "libllvm_sha256")) manifest.libllvm_sha256 = value else if (std.mem.eql(u8, key, "libclang_cpp")) manifest.libclang_cpp = value else if (std.mem.eql(u8, key, "libclang_cpp_sha256")) manifest.libclang_cpp_sha256 = value else if (std.mem.eql(u8, key, "compiler_rt_builtins")) manifest.compiler_rt_builtins = value else if (std.mem.eql(u8, key, "compiler_rt_builtins_sha256")) manifest.compiler_rt_builtins_sha256 = value else if (std.mem.eql(u8, key, "provisioned_from")) manifest.provisioned_from = value;
    }
    return manifest;
}

pub fn parseTargetSupportManifest(source: []const u8) !TargetSupportManifest {
    var manifest: TargetSupportManifest = .{};
    var line_it = std.mem.tokenizeScalar(u8, source, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidManifest;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        const raw_value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
        if (std.mem.eql(u8, key, "revision")) {
            manifest.revision = std.fmt.parseInt(u32, raw_value, 10) catch return error.InvalidManifest;
            continue;
        }
        const value = try parseQuotedManifestValue(raw_value);
        if (std.mem.eql(u8, key, "kind")) manifest.kind = value else if (std.mem.eql(u8, key, "target")) manifest.target = value else if (std.mem.eql(u8, key, "provisioned_from")) manifest.provisioned_from = value else if (std.mem.eql(u8, key, "runtime_header")) manifest.runtime_header = value else if (std.mem.eql(u8, key, "runtime_header_sha256")) manifest.runtime_header_sha256 = value else if (std.mem.eql(u8, key, "runtime_archive")) manifest.runtime_archive = value else if (std.mem.eql(u8, key, "runtime_archive_sha256")) manifest.runtime_archive_sha256 = value else if (std.mem.eql(u8, key, "std_archive")) manifest.std_archive = value else if (std.mem.eql(u8, key, "std_archive_sha256")) manifest.std_archive_sha256 = value;
    }
    return manifest;
}

pub fn validateTargetSupportManifest(support: build_model.TargetSupportSpec, manifest: TargetSupportManifest, allow_compiler_manifest: bool) !void {
    if (!std.mem.eql(u8, manifest.kind, "target-support")) return error.InvalidManifest;
    if (!std.mem.eql(u8, manifest.target, support.id)) return error.InvalidManifest;
    if (manifest.revision != support.revision) return error.InvalidManifest;
    if (std.mem.eql(u8, manifest.provisioned_from, "artifact")) return;
    if (allow_compiler_manifest and std.mem.eql(u8, manifest.provisioned_from, "compiler")) return;
    return error.InvalidManifest;
}

pub fn validateArtifactManifestApproval(
    allocator: std.mem.Allocator,
    manifest_source: []const u8,
    bundle: build_model.ToolchainBundleSpec,
    host: build_model.ToolchainHost,
    artifact_id: []const u8,
    require_pinned: bool,
) !void {
    if (!require_pinned) return;
    const pinned = build_model.approvedToolchainArtifactForId(bundle, artifact_id, host) orelse return error.InvalidManifest;
    const actual = try hashBytesSha256Hex(allocator, manifest_source);
    defer allocator.free(actual);
    if (!std.mem.eql(u8, actual, pinned.manifest_sha256)) return error.InvalidManifest;
}

pub fn resolveTargetSupportArchivePath(
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    dependency: StaticLibraryDependency,
) !?[]const u8 {
    const support = build_model.supportedTargetSupport(target.target) catch return null;
    const root_dir = try provisionedTargetSupportDir(allocator, support) orelse return null;
    defer allocator.free(root_dir);

    return resolveTargetSupportArchivePathAtRoot(allocator, root_dir, support, dependency);
}

pub fn resolveTargetSupportArchivePathAtRoot(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    support: build_model.TargetSupportSpec,
    dependency: StaticLibraryDependency,
) !?[]const u8 {
    const manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "manifest.toml" });
    defer allocator.free(manifest_path);
    const manifest_source = compat.readFileAlloc(allocator, manifest_path, 8 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(manifest_source);

    const manifest = try parseTargetSupportManifest(manifest_source);
    try validateTargetSupportManifest(support, manifest, true);
    const relative_path, const expected_sha256_hex = switch (dependency) {
        .runtime => .{ manifest.runtime_archive, manifest.runtime_archive_sha256 },
        .std => .{ manifest.std_archive, manifest.std_archive_sha256 },
    };
    if (relative_path.len == 0) return null;
    try validateTargetSupportPayloadDigest(allocator, root_dir, relative_path, expected_sha256_hex);

    const archive_path = try std.fs.path.join(allocator, &.{ root_dir, relative_path });
    errdefer allocator.free(archive_path);
    compat.access(archive_path, .{}) catch return null;
    return archive_path;
}

pub fn hashBytesSha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return hashDigestHex(allocator, digest);
}

pub fn parseEnvBool(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

fn allowUnpinnedToolchainArtifacts() bool {
    const value = compat.getEnvVarOwned(std.heap.page_allocator, "CYNA_ALLOW_UNPINNED_TOOLCHAIN_ARTIFACT") catch return false;
    defer std.heap.page_allocator.free(value);
    return parseEnvBool(value);
}

fn allowHostToolchainCapture() bool {
    const value = compat.getEnvVarOwned(std.heap.page_allocator, "CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE") catch return false;
    defer std.heap.page_allocator.free(value);
    return parseEnvBool(value);
}

fn printOwnedToolchainRequired(diagnostic_context: diagnostics.Context, display_path: []const u8, after_cache_reset: bool) !void {
    const message = if (after_cache_reset)
        "distribution auto-provision failed after cache reset: trusted fetch unavailable. Reinstall Cyna when the distribution is available, or set CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE=1 for development bootstrap"
    else
        "distribution auto-provision failed: trusted fetch unavailable. Reinstall Cyna when the distribution is available, or set CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE=1 for development bootstrap";
    try diagnostic_context.emitPath(display_path, message);
}

fn allowInternalToolchainCommands() bool {
    const value = compat.getEnvVarOwned(std.heap.page_allocator, "CYNA_INTERNAL") catch return false;
    defer std.heap.page_allocator.free(value);
    return parseEnvBool(value);
}

fn printToolchainApprovalEntryForBundle(
    diagnostic_context: diagnostics.Context,
    allocator: std.mem.Allocator,
    bundle: build_model.ToolchainBundleSpec,
    display_path: []const u8,
) !void {
    const host = build_model.supportedHost();
    var source = try resolveToolchainArtifactSource(allocator, display_path, .approve);
    defer source.deinit(allocator);

    const manifest_source = switch (source) {
        .local_root => |source_root| blk: {
            const source_dir = try toolchainArtifactSourceDir(allocator, source_root, bundle, host);
            defer allocator.free(source_dir);
            const manifest_path = try std.fs.path.join(allocator, &.{ source_dir, "bundle.toml" });
            defer allocator.free(manifest_path);
            const source_bytes = compat.readFileAlloc(allocator, manifest_path, 512 * 1024) catch |err| {
                if (err == error.FileNotFound) {
                    try diagnostic_context.emitPath(display_path, "published artifact manifest not found for bundle and host");
                    return error.NativeCompileFailed;
                }
                return err;
            };
            break :blk source_bytes;
        },
        .remote_base_url => |base_url| try fetchRemoteManifestSource(allocator, base_url, bundle, host),
    };
    defer allocator.free(manifest_source);
    const manifest_sha256 = try hashBytesSha256Hex(allocator, manifest_source);
    defer allocator.free(manifest_sha256);

    const manifest = try parseToolchainArtifactManifest(manifest_source);

    std.debug.print(
        \\.{{
        \\    .bundle_id = "{s}",
        \\    .artifact_id = "{s}",
        \\    .host = .{s},
        \\    .manifest_sha256 = "{s}",
        \\}},
        \\
    ,
        .{
            bundle.id,
            manifest.id,
            @tagName(host),
            manifest_sha256,
        },
    );
}

fn printTargetSupportApprovalEntryForSupport(
    diagnostic_context: diagnostics.Context,
    allocator: std.mem.Allocator,
    support: build_model.TargetSupportSpec,
    display_path: []const u8,
) !void {
    var source = try resolveToolchainArtifactSource(allocator, display_path, .approve);
    defer source.deinit(allocator);

    const manifest_source = switch (source) {
        .local_root => |source_root| blk: {
            const source_dir = try targetSupportArtifactSourceDir(allocator, source_root, support);
            defer allocator.free(source_dir);
            const manifest_path = try std.fs.path.join(allocator, &.{ source_dir, "manifest.toml" });
            defer allocator.free(manifest_path);
            const source_bytes = compat.readFileAlloc(allocator, manifest_path, 8 * 1024) catch |err| {
                if (err == error.FileNotFound) {
                    try diagnostic_context.emitPath(display_path, "published target support manifest not found");
                    return error.NativeCompileFailed;
                }
                return err;
            };
            break :blk source_bytes;
        },
        .remote_base_url => |base_url| blk: {
            const manifest_url = try targetSupportArtifactFileUrl(allocator, base_url, support, "manifest.toml");
            defer allocator.free(manifest_url);
            break :blk downloadBytesViaCurl(allocator, manifest_url) catch |err| {
                try diagnostic_context.emitPath(display_path, "published target support manifest not found");
                return if (err == error.NativeCompileFailed) error.NativeCompileFailed else err;
            };
        },
    };
    defer allocator.free(manifest_source);

    const manifest = try parseTargetSupportManifest(manifest_source);
    try validateTargetSupportManifest(support, manifest, false);

    const manifest_sha256 = try hashBytesSha256Hex(allocator, manifest_source);
    defer allocator.free(manifest_sha256);
    std.debug.print(
        \\.{{
        \\    .target_id = "{s}",
        \\    .revision = {d},
        \\    .manifest_sha256 = "{s}",
        \\}},
        \\
    ,
        .{
            support.id,
            support.revision,
            manifest_sha256,
        },
    );
}

fn installToolchainBundleForTarget(
    diagnostic_context: diagnostics.Context,
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    verbose: bool,
) !void {
    const bundle = try build_model.supportedLlvmToolBundle(target.target);
    const host = build_model.supportedHost();
    const pinned_available = build_model.hasApprovedToolchainArtifact(bundle, host);
    const allow_unpinned = allowUnpinnedToolchainArtifacts();
    const require_pinned = pinned_available and !allow_unpinned;
    var fetched_source: ?ToolchainArtifactSource = null;
    defer if (fetched_source) |*source| source.deinit(allocator);

    if (try provisionedToolchainBinDir(allocator, bundle)) |bin_dir| {
        defer allocator.free(bin_dir);
        const root_dir = std.fs.path.dirname(bin_dir) orelse return error.InvalidPath;
        const manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "bundle.toml" });
        defer allocator.free(manifest_path);
        if (compat.accessAbsolute(manifest_path, .{})) |_| {
            if (compat.accessAbsolute(bin_dir, .{})) |_| {
                const installed_valid = blk: {
                    validateProvisionedToolchainForTarget(allocator, root_dir, bundle, target) catch {
                        break :blk false;
                    };
                    break :blk true;
                };
                if (!installed_valid) {
                    compat.deleteTreeAbsolute(root_dir) catch {};
                } else {
                    try ensureTargetSupportForTarget(diagnostic_context, allocator, target, verbose);
                    if (verbose) {
                        std.debug.print("installed llvm tools bundle: {s}@{s}\n", .{ bundle.id, bundle.version });
                        std.debug.print("bundle bin dir: {s}\n", .{bin_dir});
                    }
                    return;
                }
            } else |_| {}
        } else |_| {}
    }

    var cached_dir: ?[]const u8 = try cachedToolchainBundleDir(allocator, bundle);
    if (cached_dir == null) {
        if (pinned_available or allow_unpinned) {
            const fetched: ?ToolchainFetchResult = fetchToolchainBundleToCache(diagnostic_context, allocator, target.display_path, bundle, host, require_pinned, if (verbose) .detailed else .quiet) catch |err| blk: {
                switch (err) {
                    error.NativeCompileFailed => {
                        if (allowHostToolchainCapture()) {
                            if (verbose) {
                                std.debug.print("remote toolchain fetch unavailable; falling back to host-tool capture\n", .{});
                            } else {
                                std.debug.print("toolchain auto-provision: trusted fetch unavailable, using host-tool capture\n", .{});
                            }
                            break :blk null;
                        }
                        if (verbose) {
                            try diagnostic_context.emitPath(
                                target.display_path,
                                "trusted distribution fetch failed. Reinstall Cyna when the distribution is available, or set CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE=1 for development bootstrap",
                            );
                        } else {
                            try printOwnedToolchainRequired(diagnostic_context, target.display_path, false);
                        }
                        return error.NativeCompileFailed;
                    },
                    else => return err,
                }
            };
            if (fetched) |value| {
                fetched_source = value.source;
                cached_dir = value.cache_dir;
            }
        }
    }

    if (cached_dir) |cache_dir| {
        if (!pinned_available and !allow_unpinned) {
            try diagnostic_context.emitPath(
                target.display_path,
                "toolchain install requires a compiler-pinned cached artifact; set CYNA_ALLOW_UNPINNED_TOOLCHAIN_ARTIFACT=1 for development-only installs",
            );
            return error.NativeCompileFailed;
        }
        validateArtifactBundleDir(allocator, cache_dir, bundle, host, require_pinned) catch |err| {
            compat.deleteTreeAbsolute(cache_dir) catch {};
            try diagnostic_context.emitPath(target.display_path, "cached toolchain bundle was stale or invalid; clearing cache and retrying");
            allocator.free(cache_dir);
            cached_dir = null;
            if (pinned_available or allow_unpinned) {
                const fetched: ?ToolchainFetchResult = fetchToolchainBundleToCache(diagnostic_context, allocator, target.display_path, bundle, host, require_pinned, if (verbose) .detailed else .quiet) catch |fetch_err| blk: {
                    switch (fetch_err) {
                        error.NativeCompileFailed => {
                            if (allowHostToolchainCapture()) {
                                if (verbose) {
                                    std.debug.print("remote toolchain fetch unavailable after cache reset; falling back to host-tool capture\n", .{});
                                } else {
                                    std.debug.print("toolchain auto-provision: cache reset, trusted fetch unavailable, using host-tool capture\n", .{});
                                }
                                break :blk null;
                            }
                            if (verbose) {
                                try diagnostic_context.emitPath(
                                    target.display_path,
                                    "trusted distribution fetch failed after cache reset. Reinstall Cyna when the distribution is available, or set CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE=1 for development bootstrap",
                                );
                            } else {
                                try printOwnedToolchainRequired(diagnostic_context, target.display_path, true);
                            }
                            return error.NativeCompileFailed;
                        },
                        else => return fetch_err,
                    }
                };
                if (fetched) |value| {
                    fetched_source = value.source;
                    cached_dir = value.cache_dir;
                }
            } else {
                return err;
            }
        };
    }

    if (cached_dir) |cache_dir| {
        defer allocator.free(cache_dir);
        const bin_dir = try ensureProvisionedToolchainBinDir(allocator, bundle);
        defer allocator.free(bin_dir);
        try replaceDirectoryTree(allocator, cache_dir, std.fs.path.dirname(bin_dir) orelse return error.InvalidPath);
        try ensureTargetSupportForTarget(diagnostic_context, allocator, target, verbose);
        if (verbose) {
            std.debug.print("installed toolchain bundle from cache: {s}@{s}\n", .{ bundle.id, bundle.version });
            if (fetched_source) |source| {
                switch (source) {
                    .local_root => |source_root| std.debug.print("cache refreshed from local root: {s}\n", .{source_root}),
                    .remote_base_url => |base_url| std.debug.print("cache refreshed from remote url: {s}\n", .{base_url}),
                }
            }
            std.debug.print("bundle bin dir: {s}\n", .{bin_dir});
        }
        return;
    }

    if (!allowHostToolchainCapture()) {
        try printOwnedToolchainRequired(diagnostic_context, target.display_path, false);
        return error.NativeCompileFailed;
    }

    var probe = try probeHostToolchain(allocator, target);
    defer probe.deinit(allocator);

    if (!probe.readyForBuild()) {
        try diagnostic_context.emitPath(target.display_path, "cannot provision toolchain bundle because required host tools are missing");
        return error.NativeCompileFailed;
    }

    const bin_dir = try ensureProvisionedToolchainBinDir(allocator, probe.llvm_bundle);
    defer allocator.free(bin_dir);

    try installResolvedExecutable(allocator, bin_dir, probe.cc.?);
    const resource_headers = try installClangResourceHeaders(allocator, bin_dir, probe.cc.?.path);
    defer resource_headers.deinit(allocator);
    try installResolvedExecutable(allocator, bin_dir, probe.ar.?);
    if (probe.lld) |lld| {
        try installResolvedExecutable(allocator, bin_dir, lld);
    }
    if (probe.objcopy) |objcopy| {
        try installResolvedExecutable(allocator, bin_dir, objcopy);
    }
    const compiler_rt_builtins = try installCompilerRtBuiltinsArchives(diagnostic_context, allocator, bin_dir, probe.llvm_bundle, target, probe.cc.?);
    defer compiler_rt_builtins.deinit(allocator);
    try writeProvisionedToolchainManifest(allocator, probe.llvm_bundle, bin_dir, probe, compiler_rt_builtins, resource_headers);
    try ensureTargetSupportForTarget(diagnostic_context, allocator, target, verbose);

    if (verbose) {
        std.debug.print("installed llvm tools bundle: {s}@{s}\n", .{ probe.llvm_bundle.id, probe.llvm_bundle.version });
        std.debug.print("target support: {s}@{d}\n", .{ probe.target_support.id, probe.target_support.revision });
        std.debug.print("bundle bin dir: {s}\n", .{bin_dir});
    }
}

fn probeDistribution(allocator: std.mem.Allocator, target: build_model.BuildTarget) !DistributionProbe {
    const spec = (try build_model.supportedTarget(target.target)).?;
    const llvm_bundle = try build_model.supportedLlvmToolBundle(target.target);
    const target_support = try build_model.supportedTargetSupport(target.target);
    const provisioned_bin_dir = try provisionedToolchainBinDir(allocator, llvm_bundle);
    return probeDistributionWithPreference(allocator, spec, llvm_bundle, target_support, provisioned_bin_dir);
}

fn probeHostToolchain(allocator: std.mem.Allocator, target: build_model.BuildTarget) !DistributionProbe {
    const spec = (try build_model.supportedTarget(target.target)).?;
    const llvm_bundle = try build_model.supportedLlvmToolBundle(target.target);
    const target_support = try build_model.supportedTargetSupport(target.target);
    return probeDistributionWithPreference(allocator, spec, llvm_bundle, target_support, null);
}

fn probeDistributionWithPreference(
    allocator: std.mem.Allocator,
    spec: build_model.SupportedTarget,
    llvm_bundle: build_model.ToolchainBundleSpec,
    target_support: build_model.TargetSupportSpec,
    provisioned_bin_dir: ?[]const u8,
) !DistributionProbe {
    return switch (spec.toolchain_family) {
        .llvm => .{
            .llvm_bundle = llvm_bundle,
            .target_support = target_support,
            .family = .llvm,
            .provisioned_bin_dir = provisioned_bin_dir,
            .cc = try findLlvmTool(allocator, provisioned_bin_dir, "clang", &.{
                "/opt/homebrew/opt/llvm/bin/clang",
                "/usr/local/opt/llvm/bin/clang",
                "/usr/lib/llvm-22/bin/clang",
                "/usr/bin/clang",
            }, null),
            .ar = try findLlvmTool(allocator, provisioned_bin_dir, "llvm-ar", &.{
                "/opt/homebrew/opt/llvm/bin/llvm-ar",
                "/usr/local/opt/llvm/bin/llvm-ar",
                "/usr/lib/llvm-22/bin/llvm-ar",
                "/usr/bin/llvm-ar",
                "/usr/bin/ar",
            }, "ar"),
            .lld = try findLlvmTool(allocator, provisioned_bin_dir, "ld.lld", &.{
                "/opt/homebrew/bin/ld.lld",
                "/usr/local/bin/ld.lld",
                "/opt/homebrew/opt/lld/bin/ld.lld",
                "/usr/local/opt/lld/bin/ld.lld",
                "/usr/lib/llvm-22/bin/ld.lld",
                "/usr/bin/ld.lld",
            }, "ld.lld"),
            .objcopy = try findLlvmTool(allocator, provisioned_bin_dir, "llvm-objcopy", &.{
                "/opt/homebrew/opt/llvm/bin/llvm-objcopy",
                "/usr/local/opt/llvm/bin/llvm-objcopy",
                "/usr/lib/llvm-22/bin/llvm-objcopy",
                "/usr/bin/llvm-objcopy",
                "/usr/bin/objcopy",
            }, "objcopy"),
        },
    };
}

fn validateProvisionedToolchainForTarget(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    bundle: build_model.ToolchainBundleSpec,
    target: build_model.BuildTarget,
) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "bundle.toml" });
    defer allocator.free(manifest_path);
    const manifest_source = try compat.readFileAlloc(allocator, manifest_path, 512 * 1024);
    defer allocator.free(manifest_source);
    const manifest = try parseToolchainArtifactManifest(manifest_source);

    if (!build_model.toolchainArtifactBelongsToBundle(bundle, manifest.id)) return error.InvalidManifest;
    if (!std.mem.eql(u8, manifest.version, bundle.version)) return error.InvalidManifest;
    if (!std.mem.eql(u8, manifest.family, @tagName(bundle.family))) return error.InvalidManifest;
    if (build_model.isFreestandingTarget(target.target) and
        (manifest.compiler_rt_builtins.len == 0 or manifest.compiler_rt_builtins_sha256.len == 0))
    {
        return error.InvalidManifest;
    }
    if (manifest.compiler_rt_builtins.len != 0 or manifest.compiler_rt_builtins_sha256.len != 0) {
        try validateArtifactToolDigestList(allocator, root_dir, manifest.compiler_rt_builtins, manifest.compiler_rt_builtins_sha256);
    }
    if (manifest.resource_headers.len != 0 or manifest.resource_headers_sha256.len != 0) {
        try validateArtifactToolDigestList(allocator, root_dir, manifest.resource_headers, manifest.resource_headers_sha256);
    }
}

fn requireTool(diagnostic_context: diagnostics.Context, candidate: ?ResolvedExecutable, target: build_model.BuildTarget, display_name: []const u8) !ResolvedExecutable {
    return candidate orelse {
        var buf: [224]u8 = undefined;
        const target_name = target.target orelse "native";
        const message = std.fmt.bufPrint(&buf, "missing toolchain component {s} for target `{s}`", .{ display_name, target_name }) catch "missing toolchain component";
        try diagnostic_context.emitPath(target.display_path, message);
        return error.NativeCompileFailed;
    };
}

fn printToolStatus(kind: []const u8, fallback_name: []const u8, tool: ?ResolvedExecutable) void {
    if (tool) |value| {
        std.debug.print("{s}: {s} ({s})\n", .{ kind, value.path, @tagName(value.source) });
        return;
    }
    std.debug.print("{s}: missing ({s})\n", .{ kind, fallback_name });
}

fn printToolchainFetchPolicy(bundle: build_model.ToolchainBundleSpec, host: build_model.ToolchainHost) void {
    if (build_model.hasApprovedToolchainArtifact(bundle, host)) {
        std.debug.print("fetch policy: compiler-pinned manifest\n", .{});
    } else {
        std.debug.print("fetch policy: development override required (set CYNA_ALLOW_UNPINNED_TOOLCHAIN_ARTIFACT=1)\n", .{});
    }
}

fn provisionedToolchainBinDir(allocator: std.mem.Allocator, bundle: build_model.ToolchainBundleSpec) !?[]u8 {
    const home = compat.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);

    const root_dir = try toolchainBundleRootPath(allocator, home, bundle);
    defer allocator.free(root_dir);
    const bin_dir = try std.fs.path.join(allocator, &.{ root_dir, "bin" });
    errdefer allocator.free(bin_dir);

    const dir = compat.openDirAbsolute(bin_dir, .{}) catch {
        allocator.free(bin_dir);
        const legacy_root_dir = try std.fs.path.join(allocator, &.{ home, ".cyna", "toolchains", bundle.id, bundle.version });
        defer allocator.free(legacy_root_dir);
        const legacy_bin_dir = try std.fs.path.join(allocator, &.{ legacy_root_dir, "bin" });
        errdefer allocator.free(legacy_bin_dir);
        const legacy_dir = compat.openDirAbsolute(legacy_bin_dir, .{}) catch {
            allocator.free(legacy_bin_dir);
            return null;
        };
        compat.closeDir(legacy_dir);
        return legacy_bin_dir;
    };
    compat.closeDir(dir);
    return bin_dir;
}

fn ensureProvisionedToolchainBinDir(allocator: std.mem.Allocator, bundle: build_model.ToolchainBundleSpec) ![]u8 {
    const home = try compat.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const root_dir = try toolchainBundleRootPath(allocator, home, bundle);
    defer allocator.free(root_dir);
    const bin_dir = try std.fs.path.join(allocator, &.{ root_dir, "bin" });
    errdefer allocator.free(bin_dir);
    try compat.makePath(bin_dir);
    return bin_dir;
}

fn cachedToolchainBundleDir(allocator: std.mem.Allocator, bundle: build_model.ToolchainBundleSpec) !?[]u8 {
    const home = compat.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);

    const root_dir = try cachedToolchainBundleRootPath(allocator, home, bundle);
    errdefer allocator.free(root_dir);

    const dir = compat.openDirAbsolute(root_dir, .{}) catch {
        allocator.free(root_dir);
        const legacy_root_dir = try legacyCachedToolchainBundleRootPath(allocator, home, bundle);
        errdefer allocator.free(legacy_root_dir);

        const legacy_dir = compat.openDirAbsolute(legacy_root_dir, .{}) catch {
            allocator.free(legacy_root_dir);
            return null;
        };
        compat.closeDir(legacy_dir);
        return legacy_root_dir;
    };
    compat.closeDir(dir);
    return root_dir;
}

fn ensureCachedToolchainBundleDir(allocator: std.mem.Allocator, bundle: build_model.ToolchainBundleSpec) ![]u8 {
    const home = try compat.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const root_dir = try cachedToolchainBundleRootPath(allocator, home, bundle);
    errdefer allocator.free(root_dir);
    try compat.makePath(root_dir);
    return root_dir;
}

fn provisionedTargetSupportDir(allocator: std.mem.Allocator, support: build_model.TargetSupportSpec) !?[]u8 {
    const home = compat.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);

    const root_dir = try targetSupportRootPath(allocator, home, support);
    errdefer allocator.free(root_dir);

    const dir = compat.openDirAbsolute(root_dir, .{}) catch {
        allocator.free(root_dir);
        return null;
    };
    compat.closeDir(dir);
    return root_dir;
}

fn ensureProvisionedTargetSupportDir(allocator: std.mem.Allocator, support: build_model.TargetSupportSpec) ![]u8 {
    const home = try compat.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const root_dir = try targetSupportRootPath(allocator, home, support);
    errdefer allocator.free(root_dir);
    try compat.makePath(root_dir);
    return root_dir;
}

fn cachedTargetSupportDir(allocator: std.mem.Allocator, support: build_model.TargetSupportSpec) !?[]u8 {
    const home = compat.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);

    const root_dir = try cachedTargetSupportRootPath(allocator, home, support);
    errdefer allocator.free(root_dir);

    const dir = compat.openDirAbsolute(root_dir, .{}) catch {
        allocator.free(root_dir);
        const legacy_root_dir = try legacyCachedTargetSupportRootPath(allocator, home, support);
        errdefer allocator.free(legacy_root_dir);

        const legacy_dir = compat.openDirAbsolute(legacy_root_dir, .{}) catch {
            allocator.free(legacy_root_dir);
            return null;
        };
        compat.closeDir(legacy_dir);
        return legacy_root_dir;
    };
    compat.closeDir(dir);
    return root_dir;
}

fn ensureCachedTargetSupportDir(allocator: std.mem.Allocator, support: build_model.TargetSupportSpec) ![]u8 {
    const home = try compat.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const root_dir = try cachedTargetSupportRootPath(allocator, home, support);
    errdefer allocator.free(root_dir);
    try compat.makePath(root_dir);
    return root_dir;
}

fn targetSupportArtifactSourceDir(allocator: std.mem.Allocator, artifact_root: []const u8, support: build_model.TargetSupportSpec) ![]u8 {
    _ = support.revision;
    return std.fs.path.join(allocator, &.{ artifact_root, "targets", support.id });
}

fn targetSupportArtifactFileUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    support: build_model.TargetSupportSpec,
    relative_path: []const u8,
) ![]u8 {
    const trimmed_base = std.mem.trimEnd(u8, base_url, "/");
    _ = support.revision;
    return std.fmt.allocPrint(allocator, "{s}/targets/{s}/{s}", .{ trimmed_base, support.id, relative_path });
}

fn toolchainArtifactSourceDir(
    allocator: std.mem.Allocator,
    artifact_root: []const u8,
    bundle: build_model.ToolchainBundleSpec,
    host: build_model.ToolchainHost,
) ![]u8 {
    _ = bundle;
    _ = host;
    const dir = try std.fs.path.join(allocator, &.{ artifact_root, "llvm" });
    errdefer allocator.free(dir);
    compat.access(dir, .{}) catch return error.FileNotFound;
    return dir;
}

fn toolchainArtifactRelativeDir(
    allocator: std.mem.Allocator,
    bundle: build_model.ToolchainBundleSpec,
    host: build_model.ToolchainHost,
) ![]u8 {
    _ = bundle;
    _ = host;
    return allocator.dupe(u8, "llvm");
}

fn toolchainArtifactFileUrlWithHostTag(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    artifact_id: []const u8,
    version: []const u8,
    host_tag: []const u8,
    relative_path: []const u8,
) ![]u8 {
    const trimmed_base = std.mem.trimEnd(u8, base_url, "/");
    _ = artifact_id;
    _ = version;
    _ = host_tag;
    return std.fmt.allocPrint(allocator, "{s}/llvm/{s}", .{ trimmed_base, relative_path });
}

fn fetchToolchainBundleToCache(
    diagnostic_context: diagnostics.Context,
    allocator: std.mem.Allocator,
    display_path: []const u8,
    bundle: build_model.ToolchainBundleSpec,
    host: build_model.ToolchainHost,
    require_pinned: bool,
    report: ToolchainFetchReport,
) !ToolchainFetchResult {
    var source = try resolveToolchainArtifactSource(allocator, display_path, .fetch);
    errdefer source.deinit(allocator);

    const cache_dir = try ensureCachedToolchainBundleDir(allocator, bundle);
    errdefer allocator.free(cache_dir);

    switch (source) {
        .local_root => |source_root| {
            const source_dir = try toolchainArtifactSourceDir(allocator, source_root, bundle, host);
            defer allocator.free(source_dir);
            validateArtifactBundleDir(allocator, source_dir, bundle, host, require_pinned) catch |err| {
                if (report == .detailed) try printToolchainFetchFailure(diagnostic_context, display_path, source, err);
                return error.NativeCompileFailed;
            };
            try replaceDirectoryTree(allocator, source_dir, cache_dir);
        },
        .remote_base_url => |base_url| {
            fetchRemoteToolchainArtifact(allocator, base_url, cache_dir, bundle, host, require_pinned) catch |err| {
                if (report == .detailed) try printToolchainFetchFailure(diagnostic_context, display_path, source, err);
                return error.NativeCompileFailed;
            };
        },
    }

    return .{
        .source = source,
        .cache_dir = cache_dir,
    };
}

fn resolveToolchainArtifactSource(
    allocator: std.mem.Allocator,
    display_path: []const u8,
    use_case: ToolchainArtifactRootUse,
) !ToolchainArtifactSource {
    if (compat.getEnvVarOwned(allocator, "CYNA_TOOLCHAIN_ARTIFACT_ROOT")) |value| {
        return .{ .local_root = value };
    } else |_| {}

    if (compat.getEnvVarOwned(allocator, "CYNA_TOOLCHAIN_ARTIFACT_BASE_URL")) |value| {
        return .{ .remote_base_url = value };
    } else |_| {}

    _ = display_path;
    _ = use_case;
    return .{ .remote_base_url = try build_model.officialDistributionBaseUrl(allocator) };
}

fn printToolchainFetchFailure(diagnostic_context: diagnostics.Context, display_path: []const u8, source: ToolchainArtifactSource, err: anyerror) !void {
    const source_label = switch (source) {
        .local_root => |value| value,
        .remote_base_url => |value| value,
    };
    const message = switch (err) {
        error.InvalidManifest => "downloaded toolchain bundle failed manifest or digest validation",
        error.FileNotFound => "published toolchain bundle not found for bundle and host",
        else => switch (source) {
            .remote_base_url => "failed to download toolchain bundle from trusted source",
            .local_root => "failed to load toolchain bundle from local artifact root",
        },
    };
    try diagnostic_context.emitPath(display_path, message);
    std.debug.print("toolchain source: {s}\n", .{source_label});
}

fn fetchRemoteManifestSource(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    bundle: build_model.ToolchainBundleSpec,
    host: build_model.ToolchainHost,
) ![]u8 {
    const canonical_host_tag = build_model.toolchainHostTag(host);
    const legacy_host_tag = build_model.toolchainLegacyHostTag(host);

    const canonical_url = try toolchainArtifactFileUrlWithHostTag(allocator, base_url, bundle.id, bundle.version, canonical_host_tag, "bundle.toml");
    defer allocator.free(canonical_url);
    if (downloadBytesViaCurl(allocator, canonical_url)) |bytes| return bytes else |_| {}

    if (legacy_host_tag) |tag| {
        const legacy_host_url = try toolchainArtifactFileUrlWithHostTag(allocator, base_url, bundle.id, bundle.version, tag, "bundle.toml");
        defer allocator.free(legacy_host_url);
        if (downloadBytesViaCurl(allocator, legacy_host_url)) |bytes| return bytes else |_| {}
    }

    for (bundle.legacy_artifact_ids) |legacy_id| {
        const legacy_url = try toolchainArtifactFileUrlWithHostTag(allocator, base_url, legacy_id, bundle.version, canonical_host_tag, "bundle.toml");
        defer allocator.free(legacy_url);
        if (downloadBytesViaCurl(allocator, legacy_url)) |bytes| return bytes else |_| {}

        if (legacy_host_tag) |tag| {
            const legacy_both_url = try toolchainArtifactFileUrlWithHostTag(allocator, base_url, legacy_id, bundle.version, tag, "bundle.toml");
            defer allocator.free(legacy_both_url);
            if (downloadBytesViaCurl(allocator, legacy_both_url)) |bytes| return bytes else |_| {}
        }
    }

    return error.NativeCompileFailed;
}

fn fetchRemoteToolchainArtifact(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    cache_dir: []const u8,
    bundle: build_model.ToolchainBundleSpec,
    host: build_model.ToolchainHost,
    require_pinned: bool,
) !void {
    const staging_dir = try std.fmt.allocPrint(allocator, "{s}.download", .{cache_dir});
    defer allocator.free(staging_dir);
    const staging_exists = blk: {
        compat.accessAbsolute(staging_dir, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    if (staging_exists) {
        try compat.deleteTreeAbsolute(staging_dir);
    }
    try compat.makePath(staging_dir);
    errdefer compat.deleteTreeAbsolute(staging_dir) catch {};

    var artifact_id = bundle.id;
    var host_tag = build_model.toolchainHostTag(host);
    const manifest_path = try std.fs.path.join(allocator, &.{ staging_dir, "bundle.toml" });
    defer allocator.free(manifest_path);
    var downloaded = false;

    {
        const manifest_url = try toolchainArtifactFileUrlWithHostTag(allocator, base_url, bundle.id, bundle.version, host_tag, "bundle.toml");
        defer allocator.free(manifest_url);
        if (downloadFileViaCurl(allocator, manifest_url, manifest_path)) |_| {
            downloaded = true;
        } else |_| {}
    }

    if (!downloaded) {
        if (build_model.toolchainLegacyHostTag(host)) |legacy_host_tag| {
            const legacy_host_url = try toolchainArtifactFileUrlWithHostTag(allocator, base_url, bundle.id, bundle.version, legacy_host_tag, "bundle.toml");
            defer allocator.free(legacy_host_url);
            if (downloadFileViaCurl(allocator, legacy_host_url, manifest_path)) |_| {
                downloaded = true;
                host_tag = legacy_host_tag;
            } else |_| {}
        }
    }

    if (!downloaded) {
        for (bundle.legacy_artifact_ids) |legacy_id| {
            const legacy_url = try toolchainArtifactFileUrlWithHostTag(allocator, base_url, legacy_id, bundle.version, build_model.toolchainHostTag(host), "bundle.toml");
            defer allocator.free(legacy_url);
            if (downloadFileViaCurl(allocator, legacy_url, manifest_path)) |_| {
                downloaded = true;
                artifact_id = legacy_id;
                host_tag = build_model.toolchainHostTag(host);
                break;
            } else |_| {}

            if (build_model.toolchainLegacyHostTag(host)) |legacy_host_tag| {
                const legacy_both_url = try toolchainArtifactFileUrlWithHostTag(allocator, base_url, legacy_id, bundle.version, legacy_host_tag, "bundle.toml");
                defer allocator.free(legacy_both_url);
                if (downloadFileViaCurl(allocator, legacy_both_url, manifest_path)) |_| {
                    downloaded = true;
                    artifact_id = legacy_id;
                    host_tag = legacy_host_tag;
                    break;
                } else |_| {}
            }
        }
    }

    if (!downloaded) return error.NativeCompileFailed;

    const manifest_source = try compat.readFileAlloc(allocator, manifest_path, 512 * 1024);
    defer allocator.free(manifest_source);
    const manifest = try parseToolchainArtifactManifest(manifest_source);
    try validateArtifactManifestApproval(allocator, manifest_source, bundle, host, manifest.id, require_pinned);

    try downloadManifestToolIfPresent(allocator, base_url, staging_dir, artifact_id, bundle.version, host_tag, manifest.compiler);
    try downloadManifestToolIfPresent(allocator, base_url, staging_dir, artifact_id, bundle.version, host_tag, manifest.archiver);
    if (manifest.linker.len != 0) {
        try downloadManifestToolIfPresent(allocator, base_url, staging_dir, artifact_id, bundle.version, host_tag, manifest.linker);
    }
    if (manifest.objcopy.len != 0) {
        try downloadManifestToolIfPresent(allocator, base_url, staging_dir, artifact_id, bundle.version, host_tag, manifest.objcopy);
    }
    if (manifest.libllvm.len != 0) {
        try downloadManifestToolIfPresent(allocator, base_url, staging_dir, artifact_id, bundle.version, host_tag, manifest.libllvm);
    }
    if (manifest.libclang_cpp.len != 0) {
        try downloadManifestToolIfPresent(allocator, base_url, staging_dir, artifact_id, bundle.version, host_tag, manifest.libclang_cpp);
    }
    if (manifest.compiler_rt_builtins.len != 0) {
        try downloadManifestToolListIfPresent(allocator, base_url, staging_dir, artifact_id, bundle.version, host_tag, manifest.compiler_rt_builtins);
    }
    if (manifest.resource_headers.len != 0) {
        try downloadManifestToolListIfPresent(allocator, base_url, staging_dir, artifact_id, bundle.version, host_tag, manifest.resource_headers);
    }

    try validateToolchainArtifactManifest(allocator, staging_dir, bundle, host, manifest);
    try replaceDirectoryTree(allocator, staging_dir, cache_dir);
}

fn downloadManifestToolIfPresent(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    staging_dir: []const u8,
    artifact_id: []const u8,
    version: []const u8,
    host_tag: []const u8,
    relative_path: []const u8,
) !void {
    if (relative_path.len == 0) return;
    const url = try toolchainArtifactFileUrlWithHostTag(allocator, base_url, artifact_id, version, host_tag, relative_path);
    defer allocator.free(url);
    const local_path = try std.fs.path.join(allocator, &.{ staging_dir, relative_path });
    defer allocator.free(local_path);
    if (std.fs.path.dirname(local_path)) |parent| {
        try compat.makePath(parent);
    }
    try downloadFileViaCurl(allocator, url, local_path);
    try markExecutable(local_path);
}

fn downloadManifestToolListIfPresent(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    staging_dir: []const u8,
    artifact_id: []const u8,
    version: []const u8,
    host_tag: []const u8,
    relative_paths_csv: []const u8,
) !void {
    var it = std.mem.splitScalar(u8, relative_paths_csv, ',');
    while (it.next()) |raw_path| {
        const relative_path = std.mem.trim(u8, raw_path, " \t\r\n");
        if (relative_path.len == 0) return error.InvalidManifest;
        try downloadManifestToolIfPresent(allocator, base_url, staging_dir, artifact_id, version, host_tag, relative_path);
    }
}

fn downloadFileViaCurl(allocator: std.mem.Allocator, url: []const u8, output_path: []const u8) !void {
    const result = try compat.runProcess(allocator, .{
        .argv = &.{
            "curl",
            "--fail",
            "--location",
            "--silent",
            "--show-error",
            "--output",
            output_path,
            url,
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| {
            if (code == 0) return;
        },
        else => {},
    }
    return error.NativeCompileFailed;
}

fn markExecutable(path: []const u8) !void {
    if (@import("builtin").os.tag == .windows) return;
    var file = try compat.openFileAbsolute(path, .{});
    defer compat.closeFile(file);
    const stat = try file.stat(compat.io());
    try file.setPermissions(compat.io(), std.Io.File.Permissions.fromMode(stat.permissions.toMode() | 0o111));
}

fn downloadBytesViaCurl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const result = try compat.runProcess(allocator, .{
        .argv = &.{
            "curl",
            "--fail",
            "--location",
            "--silent",
            "--show-error",
            url,
        },
        .max_output_bytes = 16 * 1024 * 1024,
    });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| {
            if (code == 0) return result.stdout;
        },
        else => {},
    }
    allocator.free(result.stdout);
    return error.NativeCompileFailed;
}

fn validateArtifactBundleDir(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    bundle: build_model.ToolchainBundleSpec,
    host: build_model.ToolchainHost,
    require_pinned: bool,
) !void {
    const dir = compat.openDirAbsolute(root_dir, .{}) catch return error.FileNotFound;
    defer compat.closeDir(dir);
    try compat.dirAccess(dir, "bundle.toml", .{});
    try compat.dirAccess(dir, "bin", .{});

    const manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "bundle.toml" });
    defer allocator.free(manifest_path);
    const manifest_source = try compat.readFileAlloc(allocator, manifest_path, 512 * 1024);
    defer allocator.free(manifest_source);
    const manifest = try parseToolchainArtifactManifest(manifest_source);
    try validateArtifactManifestApproval(allocator, manifest_source, bundle, host, manifest.id, require_pinned);
    try validateToolchainArtifactManifest(allocator, root_dir, bundle, host, manifest);
}

fn parseQuotedManifestValue(value: []const u8) ![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidManifest;
    return value[1 .. value.len - 1];
}

pub fn validateTargetSupportBundleDir(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    support: build_model.TargetSupportSpec,
    allow_compiler_manifest: bool,
) !void {
    const dir = compat.openDirAbsolute(root_dir, .{}) catch return error.FileNotFound;
    defer compat.closeDir(dir);
    try compat.dirAccess(dir, "manifest.toml", .{});

    const manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "manifest.toml" });
    defer allocator.free(manifest_path);
    const manifest_source = try compat.readFileAlloc(allocator, manifest_path, 8 * 1024);
    defer allocator.free(manifest_source);
    const manifest = try parseTargetSupportManifest(manifest_source);
    try validateTargetSupportManifest(support, manifest, allow_compiler_manifest);
    try validateTargetSupportPayloadDigest(allocator, root_dir, manifest.runtime_header, manifest.runtime_header_sha256);
    try validateTargetSupportPayloadDigest(allocator, root_dir, manifest.runtime_archive, manifest.runtime_archive_sha256);
    try validateTargetSupportPayloadDigest(allocator, root_dir, manifest.std_archive, manifest.std_archive_sha256);
}

fn validateTargetSupportPayloadDigest(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    relative_path: []const u8,
    expected_sha256_hex: []const u8,
) !void {
    if (relative_path.len == 0 and expected_sha256_hex.len == 0) return;
    if (relative_path.len == 0 or expected_sha256_hex.len != Sha256.digest_length * 2) return error.InvalidManifest;
    const path = try std.fs.path.join(allocator, &.{ root_dir, relative_path });
    defer allocator.free(path);
    const actual = try hashFileSha256Hex(allocator, path);
    defer allocator.free(actual);
    if (!std.mem.eql(u8, actual, expected_sha256_hex)) return error.InvalidManifest;
}

fn writeTargetSupportManifest(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    support: build_model.TargetSupportSpec,
    provisioned_from: []const u8,
) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "manifest.toml" });
    defer allocator.free(manifest_path);
    const text = try std.fmt.allocPrint(
        allocator,
        \\kind = "target-support"
        \\target = "{s}"
        \\revision = {d}
        \\provisioned_from = "{s}"
        \\
    ,
        .{ support.id, support.revision, provisioned_from },
    );
    defer allocator.free(text);
    try writeTextFile(manifest_path, text);
}

fn installCompilerOwnedTargetSupport(
    allocator: std.mem.Allocator,
    support: build_model.TargetSupportSpec,
    verbose: bool,
) !void {
    const install_dir = try ensureProvisionedTargetSupportDir(allocator, support);
    defer allocator.free(install_dir);
    try writeTargetSupportManifest(allocator, install_dir, support, "compiler");
    if (verbose) {
        std.debug.print("installed target support bundle: {s}@{d}\n", .{ support.id, support.revision });
        std.debug.print("target support source: compiler-owned synthesized manifest\n", .{});
    }
}

fn fetchTargetSupportToCache(
    diagnostic_context: diagnostics.Context,
    allocator: std.mem.Allocator,
    display_path: []const u8,
    support: build_model.TargetSupportSpec,
    require_pinned: bool,
    report: ToolchainFetchReport,
) !?ToolchainFetchResult {
    var source = try resolveToolchainArtifactSource(allocator, display_path, .fetch);
    errdefer source.deinit(allocator);

    const cache_dir = try ensureCachedTargetSupportDir(allocator, support);
    errdefer allocator.free(cache_dir);

    switch (source) {
        .local_root => |source_root| {
            const source_dir = targetSupportArtifactSourceDir(allocator, source_root, support) catch {
                source.deinit(allocator);
                allocator.free(cache_dir);
                return null;
            };
            defer allocator.free(source_dir);
            validateTargetSupportBundleDir(allocator, source_dir, support, false) catch |err| switch (err) {
                error.FileNotFound => {
                    source.deinit(allocator);
                    allocator.free(cache_dir);
                    return null;
                },
                else => {
                    if (report == .detailed) {
                        try diagnostic_context.emitPath(display_path, "target support bundle failed manifest validation");
                        std.debug.print("toolchain source: {s}\n", .{source_root});
                    }
                    return error.NativeCompileFailed;
                },
            };
            try replaceDirectoryTree(allocator, source_dir, cache_dir);
            if (require_pinned) {
                const manifest_path = try std.fs.path.join(allocator, &.{ cache_dir, "manifest.toml" });
                defer allocator.free(manifest_path);
                const manifest_source = try compat.readFileAlloc(allocator, manifest_path, 8 * 1024);
                defer allocator.free(manifest_source);
                const actual = try hashBytesSha256Hex(allocator, manifest_source);
                defer allocator.free(actual);
                const approval = build_model.approvedTargetSupportArtifact(support) orelse return error.InvalidManifest;
                if (!std.mem.eql(u8, actual, approval.manifest_sha256)) return error.InvalidManifest;
            }
        },
        .remote_base_url => |base_url| {
            const manifest_url = try targetSupportArtifactFileUrl(allocator, base_url, support, "manifest.toml");
            defer allocator.free(manifest_url);
            const staging_dir = try std.fmt.allocPrint(allocator, "{s}.download", .{cache_dir});
            defer allocator.free(staging_dir);
            const staging_exists = blk: {
                compat.accessAbsolute(staging_dir, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return err,
                };
                break :blk true;
            };
            if (staging_exists) {
                try compat.deleteTreeAbsolute(staging_dir);
            }
            try compat.makePath(staging_dir);
            errdefer compat.deleteTreeAbsolute(staging_dir) catch {};

            const manifest_path = try std.fs.path.join(allocator, &.{ staging_dir, "manifest.toml" });
            defer allocator.free(manifest_path);
            downloadFileViaCurl(allocator, manifest_url, manifest_path) catch |err| switch (err) {
                error.NativeCompileFailed => {
                    compat.deleteTreeAbsolute(staging_dir) catch {};
                    source.deinit(allocator);
                    allocator.free(cache_dir);
                    return null;
                },
                else => return err,
            };
            const manifest_source = try compat.readFileAlloc(allocator, manifest_path, 8 * 1024);
            defer allocator.free(manifest_source);
            const manifest = try parseTargetSupportManifest(manifest_source);
            try validateTargetSupportManifest(support, manifest, false);
            if (require_pinned) {
                const actual = try hashBytesSha256Hex(allocator, manifest_source);
                defer allocator.free(actual);
                const approval = build_model.approvedTargetSupportArtifact(support) orelse return error.InvalidManifest;
                if (!std.mem.eql(u8, actual, approval.manifest_sha256)) return error.InvalidManifest;
            }
            try downloadTargetSupportPayloadIfPresent(allocator, base_url, staging_dir, support, manifest.runtime_header);
            try downloadTargetSupportPayloadIfPresent(allocator, base_url, staging_dir, support, manifest.runtime_archive);
            try downloadTargetSupportPayloadIfPresent(allocator, base_url, staging_dir, support, manifest.std_archive);
            try validateTargetSupportBundleDir(allocator, staging_dir, support, false);
            try replaceDirectoryTree(allocator, staging_dir, cache_dir);
        },
    }

    return .{
        .source = source,
        .cache_dir = cache_dir,
    };
}

fn downloadTargetSupportPayloadIfPresent(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    staging_dir: []const u8,
    support: build_model.TargetSupportSpec,
    relative_path: []const u8,
) !void {
    if (relative_path.len == 0) return;
    const url = try targetSupportArtifactFileUrl(allocator, base_url, support, relative_path);
    defer allocator.free(url);
    const local_path = try std.fs.path.join(allocator, &.{ staging_dir, relative_path });
    defer allocator.free(local_path);
    if (std.fs.path.dirname(local_path)) |parent| {
        try compat.makePath(parent);
    }
    try downloadFileViaCurl(allocator, url, local_path);
}

fn ensureTargetSupportForTarget(
    diagnostic_context: diagnostics.Context,
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    verbose: bool,
) !void {
    const support = try build_model.supportedTargetSupport(target.target);

    if (try provisionedTargetSupportDir(allocator, support)) |installed_dir| {
        defer allocator.free(installed_dir);
        validateTargetSupportBundleDir(allocator, installed_dir, support, true) catch {
            compat.deleteTreeAbsolute(installed_dir) catch {};
        };
        if (compat.accessAbsolute(installed_dir, .{})) |_| return else |_| {}
    }

    var fetched_source: ?ToolchainArtifactSource = null;
    defer if (fetched_source) |*source| source.deinit(allocator);

    var cache_dir: ?[]const u8 = try cachedTargetSupportDir(allocator, support);
    if (cache_dir) |existing_cache_dir| {
        validateTargetSupportBundleDir(allocator, existing_cache_dir, support, false) catch {
            compat.deleteTreeAbsolute(existing_cache_dir) catch {};
            allocator.free(existing_cache_dir);
            cache_dir = null;
        };
    }

    if (cache_dir == null) {
        const pinned_available = build_model.hasApprovedTargetSupportArtifact(support);
        const allow_unpinned = allowUnpinnedToolchainArtifacts();
        const require_pinned = pinned_available and !allow_unpinned;
        if (!pinned_available and !allow_unpinned) {
            try installCompilerOwnedTargetSupport(allocator, support, verbose);
            return;
        }
        const fetched = fetchTargetSupportToCache(diagnostic_context, allocator, target.display_path, support, require_pinned, if (verbose) .detailed else .quiet) catch |err| {
            if (allowHostToolchainCapture() and (err == error.InvalidManifest or err == error.NativeCompileFailed)) {
                if (verbose) {
                    std.debug.print("remote target support fetch unavailable; falling back to compiler-owned target support\n", .{});
                }
                try installCompilerOwnedTargetSupport(allocator, support, verbose);
                return;
            }
            return err;
        };
        if (fetched) |value| {
            fetched_source = value.source;
            cache_dir = value.cache_dir;
        }
    }

    const install_dir = try ensureProvisionedTargetSupportDir(allocator, support);
    defer allocator.free(install_dir);

    if (cache_dir) |value| {
        defer allocator.free(value);
        try replaceDirectoryTree(allocator, value, install_dir);
        if (verbose) {
            std.debug.print("installed target support bundle: {s}@{d}\n", .{ support.id, support.revision });
            if (fetched_source) |source| {
                switch (source) {
                    .local_root => |source_root| std.debug.print("target support source: local root ({s})\n", .{source_root}),
                    .remote_base_url => |base_url| std.debug.print("target support source: remote url ({s})\n", .{base_url}),
                }
            }
        }
        return;
    }

    try writeTargetSupportManifest(allocator, install_dir, support, "compiler");
    if (verbose) {
        std.debug.print("installed target support bundle: {s}@{d}\n", .{ support.id, support.revision });
        std.debug.print("target support source: compiler-owned synthesized manifest\n", .{});
    }
}

pub fn validateToolchainArtifactManifest(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    bundle: build_model.ToolchainBundleSpec,
    host: build_model.ToolchainHost,
    manifest: ToolchainArtifactManifest,
) !void {
    if (!build_model.toolchainArtifactBelongsToBundle(bundle, manifest.id)) return error.InvalidManifest;
    if (!std.mem.eql(u8, manifest.version, bundle.version)) return error.InvalidManifest;
    if (!std.mem.eql(u8, manifest.family, @tagName(bundle.family))) return error.InvalidManifest;
    const matches_canonical_host = std.mem.eql(u8, manifest.host, build_model.toolchainHostTag(host));
    const matches_legacy_host = if (build_model.toolchainLegacyHostTag(host)) |legacy_host_tag|
        std.mem.eql(u8, manifest.host, legacy_host_tag)
    else
        false;
    if (!matches_canonical_host and !matches_legacy_host) return error.InvalidManifest;
    if (!std.mem.eql(u8, manifest.provisioned_from, "artifact")) return error.InvalidManifest;
    try validateArtifactToolDigest(allocator, root_dir, manifest.compiler, manifest.compiler_sha256);
    try validateArtifactToolDigest(allocator, root_dir, manifest.archiver, manifest.archiver_sha256);
    if (manifest.linker.len != 0 or manifest.linker_sha256.len != 0) {
        if (manifest.linker.len == 0 or manifest.linker_sha256.len == 0) return error.InvalidManifest;
        try validateArtifactToolDigest(allocator, root_dir, manifest.linker, manifest.linker_sha256);
    }
    if (manifest.objcopy.len != 0 or manifest.objcopy_sha256.len != 0) {
        if (manifest.objcopy.len == 0 or manifest.objcopy_sha256.len == 0) return error.InvalidManifest;
        try validateArtifactToolDigest(allocator, root_dir, manifest.objcopy, manifest.objcopy_sha256);
    }
    if (manifest.libllvm.len != 0 or manifest.libllvm_sha256.len != 0) {
        if (manifest.libllvm.len == 0 or manifest.libllvm_sha256.len == 0) return error.InvalidManifest;
        try validateArtifactToolDigest(allocator, root_dir, manifest.libllvm, manifest.libllvm_sha256);
    }
    if (manifest.libclang_cpp.len != 0 or manifest.libclang_cpp_sha256.len != 0) {
        if (manifest.libclang_cpp.len == 0 or manifest.libclang_cpp_sha256.len == 0) return error.InvalidManifest;
        try validateArtifactToolDigest(allocator, root_dir, manifest.libclang_cpp, manifest.libclang_cpp_sha256);
    }
    if (manifest.compiler_rt_builtins.len != 0 or manifest.compiler_rt_builtins_sha256.len != 0) {
        try validateArtifactToolDigestList(allocator, root_dir, manifest.compiler_rt_builtins, manifest.compiler_rt_builtins_sha256);
    }
    if (manifest.resource_headers.len != 0 or manifest.resource_headers_sha256.len != 0) {
        try validateArtifactToolDigestList(allocator, root_dir, manifest.resource_headers, manifest.resource_headers_sha256);
    }
}

fn validateArtifactToolDigestList(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    relative_paths_csv: []const u8,
    expected_sha256_csv: []const u8,
) !void {
    if (relative_paths_csv.len == 0 or expected_sha256_csv.len == 0) return error.InvalidManifest;
    var path_it = std.mem.splitScalar(u8, relative_paths_csv, ',');
    var hash_it = std.mem.splitScalar(u8, expected_sha256_csv, ',');
    var count: usize = 0;
    while (path_it.next()) |raw_path| {
        const relative_path = std.mem.trim(u8, raw_path, " \t\r\n");
        const expected_hash = std.mem.trim(u8, hash_it.next() orelse return error.InvalidManifest, " \t\r\n");
        if (relative_path.len == 0 or expected_hash.len == 0) return error.InvalidManifest;
        try validateArtifactToolDigest(allocator, root_dir, relative_path, expected_hash);
        count += 1;
    }
    if (count == 0 or hash_it.next() != null) return error.InvalidManifest;
}

fn validateArtifactToolDigest(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    relative_path: []const u8,
    expected_sha256_hex: []const u8,
) !void {
    if (relative_path.len == 0 or expected_sha256_hex.len != Sha256.digest_length * 2) return error.InvalidManifest;
    const path = try std.fs.path.join(allocator, &.{ root_dir, relative_path });
    defer allocator.free(path);
    const actual = try hashFileSha256Hex(allocator, path);
    defer allocator.free(actual);
    if (!std.mem.eql(u8, actual, expected_sha256_hex)) return error.InvalidManifest;
}

pub fn hashFileSha256Hex(allocator: std.mem.Allocator, absolute_path: []const u8) ![]u8 {
    var file = try compat.openFileAbsolute(absolute_path, .{});
    defer compat.closeFile(file);
    const stat = try file.stat(compat.io());
    const limit: usize = if (stat.size == std.math.maxInt(usize)) @intCast(stat.size) else @intCast(stat.size + 1);
    const bytes = try compat.readFileAlloc(allocator, absolute_path, limit);
    defer allocator.free(bytes);

    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return hashDigestHex(allocator, digest);
}

fn hashDigestHex(allocator: std.mem.Allocator, digest: [Sha256.digest_length]u8) ![]u8 {
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

fn replaceDirectoryTree(allocator: std.mem.Allocator, source_root: []const u8, dest_root: []const u8) !void {
    compat.accessAbsolute(dest_root, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try compat.makePath(dest_root);
            return copyDirectoryTreeInto(allocator, source_root, dest_root);
        },
        else => return err,
    };
    {
        try compat.deleteTreeAbsolute(dest_root);
    }
    try compat.makePath(dest_root);

    return copyDirectoryTreeInto(allocator, source_root, dest_root);
}

fn copyDirectoryTreeInto(allocator: std.mem.Allocator, source_root: []const u8, dest_root: []const u8) !void {
    var source_dir = try compat.openDirAbsolute(source_root, .{ .iterate = true });
    defer compat.closeDir(source_dir);
    var walker = try source_dir.walk(allocator);
    defer walker.deinit();

    while (try compat.walkerNext(&walker)) |entry| {
        const dest_path = try std.fs.path.join(allocator, &.{ dest_root, entry.path });
        defer allocator.free(dest_path);
        switch (entry.kind) {
            .directory => try compat.makePath(dest_path),
            .file => {
                const parent = std.fs.path.dirname(dest_path) orelse dest_root;
                try compat.makePath(parent);
                const src_path = try std.fs.path.join(allocator, &.{ source_root, entry.path });
                defer allocator.free(src_path);
                try copyFile(src_path, dest_path);
            },
            .sym_link => {
                const parent = std.fs.path.dirname(dest_path) orelse dest_root;
                try compat.makePath(parent);
                const src_path = try std.fs.path.join(allocator, &.{ source_root, entry.path });
                defer allocator.free(src_path);
                var link_buf: [std.fs.max_path_bytes]u8 = undefined;
                const link_len = try std.Io.Dir.readLinkAbsolute(compat.io(), src_path, &link_buf);
                const link_target = link_buf[0..link_len];
                try compat.symLink(link_target, dest_path, .{});
            },
            else => {},
        }
    }
}

fn installResolvedExecutable(allocator: std.mem.Allocator, bin_dir: []const u8, tool: ResolvedExecutable) !void {
    const name = std.fs.path.basename(tool.path);
    const link_path = try std.fs.path.join(allocator, &.{ bin_dir, name });
    defer allocator.free(link_path);

    compat.deleteFile(link_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const absolute_target = if (std.fs.path.isAbsolute(tool.path))
        tool.path
    else blk: {
        break :blk try compat.cwdRealpathAlloc(allocator, tool.path);
    };
    defer if (!std.fs.path.isAbsolute(tool.path)) allocator.free(absolute_target);

    try compat.symLink(absolute_target, link_path, .{});
}

fn installClangResourceHeaders(allocator: std.mem.Allocator, bin_dir: []const u8, clang_path: []const u8) !CompilerRtBuiltinsManifest {
    const result = try compat.runProcess(allocator, .{ .argv = &.{ clang_path, "-print-resource-dir" } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.NativeCompileFailed,
        else => return error.NativeCompileFailed,
    }
    const resource_dir = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!std.fs.path.isAbsolute(resource_dir)) return error.InvalidPath;
    const source = try std.fs.path.join(allocator, &.{ resource_dir, "include" });
    defer allocator.free(source);
    for ([_][]const u8{ "stdbool.h", "stdint.h", "stdatomic.h" }) |header| {
        const path = try std.fs.path.join(allocator, &.{ source, header });
        defer allocator.free(path);
        try compat.accessAbsolute(path, .{});
    }
    const root = std.fs.path.dirname(bin_dir) orelse return error.InvalidPath;
    const destination = try std.fs.path.join(allocator, &.{ root, "lib", "clang", std.fs.path.basename(resource_dir), "include" });
    defer allocator.free(destination);
    try compat.makePath(destination);
    try copyDirectoryTreeInto(allocator, source, destination);
    var dir = try compat.openDirAbsolute(destination, .{ .iterate = true });
    defer compat.closeDir(dir);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var paths: std.ArrayListUnmanaged(u8) = .empty;
    defer paths.deinit(allocator);
    var hashes: std.ArrayListUnmanaged(u8) = .empty;
    defer hashes.deinit(allocator);
    while (try compat.walkerNext(&walker)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const absolute = try std.fs.path.join(allocator, &.{ destination, entry.path });
        defer allocator.free(absolute);
        const relative = absolute[root.len + 1 ..];
        const hash = try hashFileSha256Hex(allocator, absolute);
        defer allocator.free(hash);
        try appendManifestCsvItem(allocator, &paths, relative);
        try appendManifestCsvItem(allocator, &hashes, hash);
    }
    const owned_paths = try paths.toOwnedSlice(allocator);
    errdefer allocator.free(owned_paths);
    return .{ .paths = owned_paths, .hashes = try hashes.toOwnedSlice(allocator) };
}

fn installCompilerRtBuiltinsArchives(
    diagnostic_context: diagnostics.Context,
    allocator: std.mem.Allocator,
    bin_dir: []const u8,
    bundle: build_model.ToolchainBundleSpec,
    required_target: build_model.BuildTarget,
    clang: ResolvedExecutable,
) !CompilerRtBuiltinsManifest {
    var paths: std.ArrayListUnmanaged(u8) = .empty;
    errdefer paths.deinit(allocator);
    var hashes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer hashes.deinit(allocator);

    const root_dir = std.fs.path.dirname(bin_dir) orelse return error.InvalidPath;
    for (build_model.supported_targets) |supported| {
        if (!supported.freestanding) continue;
        if (!std.mem.eql(u8, supported.llvm_tool_bundle, bundle.id)) continue;
        const toolchain_target = supported.toolchain_target orelse continue;
        const normalized = try build_model.normalizedToolchainTarget(allocator, toolchain_target);
        defer if (normalized) |value| allocator.free(value);
        const clang_target = normalized orelse toolchain_target;
        const source_path = try resolveCompilerRtBuiltinsArchivePath(allocator, clang.path, clang_target) orelse
            try resolveStagedCompilerRtBuiltinsArchivePath(allocator, bundle, clang.path, clang_target) orelse {
            const is_required = if (required_target.target) |required_name|
                std.mem.eql(u8, supported.name, required_name)
            else
                false;
            if (is_required) {
                try diagnostic_context.emitPath(
                    supported.name,
                    "host LLVM toolchain cannot provide compiler-rt builtins for this freestanding target",
                );
                return error.NativeCompileFailed;
            }
            continue;
        };
        defer allocator.free(source_path);
        const relative_path = compilerRtBuiltinsRelativePath(source_path) orelse continue;

        const dest_path = try std.fs.path.join(allocator, &.{ root_dir, relative_path });
        defer allocator.free(dest_path);
        if (std.fs.path.dirname(dest_path)) |parent| try compat.makePath(parent);
        try copyFile(source_path, dest_path);

        const hash = try hashFileSha256Hex(allocator, dest_path);
        defer allocator.free(hash);
        try appendManifestCsvItem(allocator, &paths, relative_path);
        try appendManifestCsvItem(allocator, &hashes, hash);
    }

    return .{
        .paths = try paths.toOwnedSlice(allocator),
        .hashes = try hashes.toOwnedSlice(allocator),
    };
}

fn resolveCompilerRtBuiltinsArchivePath(
    allocator: std.mem.Allocator,
    clang_path: []const u8,
    toolchain_target: []const u8,
) !?[]const u8 {
    const target_flag = try std.fmt.allocPrint(allocator, "--target={s}", .{toolchain_target});
    defer allocator.free(target_flag);
    const result = compat.runProcess(allocator, .{
        .argv = &.{ clang_path, target_flag, "-rtlib=compiler-rt", "-print-libgcc-file-name" },
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const path = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (path.len == 0) return null;
    const file = compat.openFileAbsolute(path, .{}) catch return null;
    compat.closeFile(file);
    return @as(?[]const u8, try allocator.dupe(u8, path));
}

fn resolveStagedCompilerRtBuiltinsArchivePath(
    allocator: std.mem.Allocator,
    bundle: build_model.ToolchainBundleSpec,
    clang_path: []const u8,
    toolchain_target: []const u8,
) !?[]const u8 {
    const target_flag = try std.fmt.allocPrint(allocator, "--target={s}", .{toolchain_target});
    defer allocator.free(target_flag);
    const result = compat.runProcess(allocator, .{
        .argv = &.{ clang_path, target_flag, "-rtlib=compiler-rt", "-print-libgcc-file-name" },
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const reported_path = std.mem.trim(u8, result.stdout, " \t\r\n");
    const relative_path = compilerRtBuiltinsRelativePath(reported_path) orelse return null;
    const compiler_rt_root = try std.fmt.allocPrint(allocator, "dist/compiler-rt/llvm-{s}", .{bundle.version});
    defer allocator.free(compiler_rt_root);
    const staged_relative_path = try std.fs.path.join(allocator, &.{ compiler_rt_root, relative_path });
    defer allocator.free(staged_relative_path);
    const staged_path = try compat.cwdRealpathAlloc(allocator, staged_relative_path);
    errdefer allocator.free(staged_path);
    const file = compat.openFileAbsolute(staged_path, .{}) catch {
        allocator.free(staged_path);
        return null;
    };
    compat.closeFile(file);
    return staged_path;
}

fn compilerRtBuiltinsRelativePath(absolute_path: []const u8) ?[]const u8 {
    const marker = std.mem.indexOf(u8, absolute_path, "/lib/clang/") orelse return null;
    return absolute_path[marker + 1 ..];
}

fn appendManifestCsvItem(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    item: []const u8,
) !void {
    if (item.len == 0 or std.mem.indexOfScalar(u8, item, ',') != null) return error.InvalidManifest;
    if (out.items.len != 0) try out.append(allocator, ',');
    try out.appendSlice(allocator, item);
}

fn writeProvisionedToolchainManifest(
    allocator: std.mem.Allocator,
    bundle: build_model.ToolchainBundleSpec,
    bin_dir: []const u8,
    probe: DistributionProbe,
    compiler_rt_builtins: CompilerRtBuiltinsManifest,
    resource_headers: CompilerRtBuiltinsManifest,
) !void {
    const root_dir = std.fs.path.dirname(bin_dir) orelse return error.InvalidPath;
    const manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "bundle.toml" });
    defer allocator.free(manifest_path);

    const cc_path = probe.cc.?.path;
    const ar_path = probe.ar.?.path;
    const lld_path = if (probe.lld) |value| value.path else "";
    const objcopy_path = if (probe.objcopy) |value| value.path else "";
    const text = try std.fmt.allocPrint(
        allocator,
        \\id = "{s}"
        \\version = "{s}"
        \\family = "{s}"
        \\compiler = "{s}"
        \\archiver = "{s}"
        \\linker = "{s}"
        \\objcopy = "{s}"
        \\compiler_rt_builtins = "{s}"
        \\compiler_rt_builtins_sha256 = "{s}"
        \\resource_headers = "{s}"
        \\resource_headers_sha256 = "{s}"
        \\provisioned_from = "host"
        \\
    ,
        .{
            bundle.id,
            bundle.version,
            @tagName(bundle.family),
            cc_path,
            ar_path,
            lld_path,
            objcopy_path,
            compiler_rt_builtins.paths,
            compiler_rt_builtins.hashes,
            resource_headers.paths,
            resource_headers.hashes,
        },
    );
    defer allocator.free(text);
    try writeTextFile(manifest_path, text);
}

fn findLlvmTool(
    allocator: std.mem.Allocator,
    provisioned_bin_dir: ?[]const u8,
    primary_name: []const u8,
    absolute_candidates: []const []const u8,
    fallback_name: ?[]const u8,
) !?ResolvedExecutable {
    if (provisioned_bin_dir) |bin_dir| {
        if (try findBundledTool(allocator, bin_dir, primary_name)) |tool| return tool;
        if (fallback_name) |name| {
            if (try findBundledTool(allocator, bin_dir, name)) |tool| return tool;
        }
    }
    return findSystemTool(allocator, absolute_candidates, primary_name, fallback_name);
}

fn findBundledTool(allocator: std.mem.Allocator, bin_dir: []const u8, name: []const u8) !?ResolvedExecutable {
    const executable_name = if (@import("builtin").os.tag == .windows and !std.mem.endsWith(u8, name, ".exe"))
        try std.fmt.allocPrint(allocator, "{s}.exe", .{name})
    else
        try allocator.dupe(u8, name);
    defer allocator.free(executable_name);
    const path = try std.fs.path.join(allocator, &.{ bin_dir, executable_name });
    errdefer allocator.free(path);
    if (compat.accessAbsolute(path, .{})) |_| {
        return .{ .path = path, .owned = true, .source = .bundle };
    } else |_| {
        allocator.free(path);
        return null;
    }
}

fn findSystemTool(
    allocator: std.mem.Allocator,
    absolute_candidates: []const []const u8,
    primary_name: []const u8,
    fallback_name: ?[]const u8,
) ?ResolvedExecutable {
    for (absolute_candidates) |candidate| {
        if (std.fs.path.isAbsolute(candidate)) {
            if (compat.access(candidate, .{})) |_| return .{ .path = candidate, .source = .system } else |_| {}
            continue;
        }
    }
    if (findExecutableOnPath(allocator, primary_name)) |path| return path;
    if (fallback_name) |name| {
        if (findExecutableOnPath(allocator, name)) |path| return path;
    }
    return null;
}

fn findExecutableOnPath(allocator: std.mem.Allocator, name: []const u8) ?ResolvedExecutable {
    const search_argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "where", name }
    else
        &.{ "/usr/bin/env", "which", name };
    const result = compat.runProcess(allocator, .{
        .argv = search_argv,
    }) catch return null;
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| {
            if (code != 0 or result.stdout.len == 0) {
                allocator.free(result.stdout);
                return null;
            }
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }
    const first_line = std.mem.sliceTo(result.stdout, '\n');
    const trimmed = std.mem.trim(u8, first_line, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(result.stdout);
        return null;
    }
    const path = allocator.dupe(u8, trimmed) catch {
        allocator.free(result.stdout);
        return null;
    };
    allocator.free(result.stdout);
    return .{ .path = path, .owned = true, .source = .system };
}

fn copyFile(from_path: []const u8, to_path: []const u8) !void {
    try ensureParentDir(to_path);
    try std.Io.Dir.copyFileAbsolute(from_path, to_path, compat.io(), .{});
}

fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try compat.makePath(parent);
}

test "toolchain bundle root path uses compiler-owned install layout" {
    const bundle = try build_model.supportedLlvmToolBundle("native");
    const path = try toolchainBundleRootPath(std.testing.allocator, "/tmp/home", bundle);
    defer std.testing.allocator.free(path);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "/tmp/home/.cyna/{s}/llvm", .{build_model.cyna_version});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "cached toolchain bundle root path uses compiler-owned cache layout" {
    const bundle = try build_model.supportedLlvmToolBundle("native");
    const path = try cachedToolchainBundleRootPath(std.testing.allocator, "/tmp/home", bundle);
    defer std.testing.allocator.free(path);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/home/.cyna/cache/{s}/{s}/llvm",
        .{ build_model.cyna_version, build_model.toolchainHostTag(build_model.supportedHost()) },
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "target support root path uses compiler-owned install layout" {
    const support = try build_model.supportedTargetSupport("thumbv7em-none-eabi");
    const path = try targetSupportRootPath(std.testing.allocator, "/tmp/home", support);
    defer std.testing.allocator.free(path);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/home/.cyna/{s}/targets/thumbv7em-none-eabi",
        .{build_model.cyna_version},
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "cached target support root path uses compiler-owned cache layout" {
    const support = try build_model.supportedTargetSupport("thumbv7em-none-eabi");
    const path = try cachedTargetSupportRootPath(std.testing.allocator, "/tmp/home", support);
    defer std.testing.allocator.free(path);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/home/.cyna/cache/{s}/{s}/targets/thumbv7em-none-eabi",
        .{ build_model.cyna_version, build_model.toolchainHostTag(build_model.supportedHost()) },
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "toolchain artifact file url uses canonical remote layout" {
    const bundle = try build_model.supportedLlvmToolBundle("native");
    const url = try toolchainArtifactFileUrl(std.testing.allocator, "https://downloads.cyna.dev/distributions/0.1.0/aarch64-apple-darwin/", bundle, .aarch64_apple_darwin, "bundle.toml");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://downloads.cyna.dev/distributions/0.1.0/aarch64-apple-darwin/llvm/bundle.toml", url);
}

test "parse toolchain artifact manifest and validate tool digests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "bin");
    try compat.dirMakePath(tmp.dir, "lib/clang/22/lib/riscv64-unknown-none-elf");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "bin/tool", .data = "hello\n" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/clang/22/lib/riscv64-unknown-none-elf/libclang_rt.builtins.a", .data = "builtins\n" });

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);

    const tool_path = try std.fs.path.join(std.testing.allocator, &.{ root, "bin", "tool" });
    defer std.testing.allocator.free(tool_path);
    const hash = try hashFileSha256Hex(std.testing.allocator, tool_path);
    defer std.testing.allocator.free(hash);
    const builtins_path = try std.fs.path.join(std.testing.allocator, &.{ root, "lib", "clang", "22", "lib", "riscv64-unknown-none-elf", "libclang_rt.builtins.a" });
    defer std.testing.allocator.free(builtins_path);
    const builtins_hash = try hashFileSha256Hex(std.testing.allocator, builtins_path);
    defer std.testing.allocator.free(builtins_hash);

    const manifest_text = try std.fmt.allocPrint(
        std.testing.allocator,
        \\id = "llvm-host"
        \\version = "22.1.2"
        \\family = "llvm"
        \\host = "{s}"
        \\compiler = "bin/tool"
        \\compiler_sha256 = "{s}"
        \\archiver = "bin/tool"
        \\archiver_sha256 = "{s}"
        \\linker = ""
        \\linker_sha256 = ""
        \\objcopy = ""
        \\objcopy_sha256 = ""
        \\compiler_rt_builtins = "lib/clang/22/lib/riscv64-unknown-none-elf/libclang_rt.builtins.a"
        \\compiler_rt_builtins_sha256 = "{s}"
        \\provisioned_from = "artifact"
        \\
    ,
        .{ build_model.toolchainHostTag(build_model.supportedHost()), hash, hash, builtins_hash },
    );
    defer std.testing.allocator.free(manifest_text);

    const manifest = try parseToolchainArtifactManifest(manifest_text);
    try validateToolchainArtifactManifest(
        std.testing.allocator,
        root,
        try build_model.supportedLlvmToolBundle("native"),
        build_model.supportedHost(),
        manifest,
    );
}

test "parse target support manifest and validate shape" {
    const manifest = try parseTargetSupportManifest(
        \\kind = "target-support"
        \\target = "thumbv7em-none-eabi"
        \\revision = 1
        \\provisioned_from = "artifact"
        \\
    );
    try validateTargetSupportManifest(
        try build_model.supportedTargetSupport("thumbv7em-none-eabi"),
        manifest,
        false,
    );
}

test "target support bundle validates declared payload digests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "include");
    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "include/cyna.h", .data = "/* runtime */\n" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/libcyna.a", .data = "runtime\n" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/libcyna_std.a", .data = "std\n" });

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);

    const runtime_header_path = try std.fs.path.join(std.testing.allocator, &.{ root, "include", "cyna.h" });
    defer std.testing.allocator.free(runtime_header_path);
    const runtime_archive_path = try std.fs.path.join(std.testing.allocator, &.{ root, "lib", runtime_archive_name });
    defer std.testing.allocator.free(runtime_archive_path);
    const std_archive_path = try std.fs.path.join(std.testing.allocator, &.{ root, "lib", std_archive_name });
    defer std.testing.allocator.free(std_archive_path);

    const runtime_header_hash = try hashFileSha256Hex(std.testing.allocator, runtime_header_path);
    defer std.testing.allocator.free(runtime_header_hash);
    const runtime_archive_hash = try hashFileSha256Hex(std.testing.allocator, runtime_archive_path);
    defer std.testing.allocator.free(runtime_archive_hash);
    const std_archive_hash = try hashFileSha256Hex(std.testing.allocator, std_archive_path);
    defer std.testing.allocator.free(std_archive_hash);

    const manifest_text = try std.fmt.allocPrint(
        std.testing.allocator,
        \\kind = "target-support"
        \\target = "{s}"
        \\revision = 1
        \\provisioned_from = "artifact"
        \\runtime_header = "include/cyna.h"
        \\runtime_header_sha256 = "{s}"
        \\runtime_archive = "lib/{s}"
        \\runtime_archive_sha256 = "{s}"
        \\std_archive = "lib/{s}"
        \\std_archive_sha256 = "{s}"
        \\
    ,
        .{
            build_model.toolchainHostTag(build_model.supportedHost()),
            runtime_header_hash,
            runtime_archive_name,
            runtime_archive_hash,
            std_archive_name,
            std_archive_hash,
        },
    );
    defer std.testing.allocator.free(manifest_text);

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "manifest.toml", .data = manifest_text });
    try validateTargetSupportBundleDir(
        std.testing.allocator,
        root,
        try build_model.supportedTargetSupport("native"),
        false,
    );
}

test "target support archive resolution uses installed manifest payload path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/libcyna_std.a", .data = "std\n" });

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);

    const std_archive_path = try std.fs.path.join(std.testing.allocator, &.{ root, "lib", std_archive_name });
    defer std.testing.allocator.free(std_archive_path);
    const std_archive_hash = try hashFileSha256Hex(std.testing.allocator, std_archive_path);
    defer std.testing.allocator.free(std_archive_hash);

    const manifest_text = try std.fmt.allocPrint(
        std.testing.allocator,
        \\kind = "target-support"
        \\target = "{s}"
        \\revision = 1
        \\provisioned_from = "artifact"
        \\std_archive = "lib/{s}"
        \\std_archive_sha256 = "{s}"
        \\
    ,
        .{
            build_model.toolchainHostTag(build_model.supportedHost()),
            std_archive_name,
            std_archive_hash,
        },
    );
    defer std.testing.allocator.free(manifest_text);

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "manifest.toml", .data = manifest_text });

    const resolved = try resolveTargetSupportArchivePathAtRoot(
        std.testing.allocator,
        root,
        try build_model.supportedTargetSupport("native"),
        .std,
    );
    defer if (resolved) |path| std.testing.allocator.free(path);

    try std.testing.expect(resolved != null);
    try std.testing.expectEqualStrings(std_archive_path, resolved.?);
}

test "target support archive resolution rejects mismatched archive digest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/libcyna_std.a", .data = "std\n" });

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);

    const manifest_text =
        \\kind = "target-support"
        \\target = "aarch64-apple-darwin"
        \\revision = 1
        \\provisioned_from = "artifact"
        \\std_archive = "lib/libcyna_std.a"
        \\std_archive_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
        \\
    ;

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "manifest.toml", .data = manifest_text });

    try std.testing.expectError(
        error.InvalidManifest,
        resolveTargetSupportArchivePathAtRoot(
            std.testing.allocator,
            root,
            try build_model.supportedTargetSupport("native"),
            .std,
        ),
    );
}

test "artifact manifest approval rejects mismatched pinned digest" {
    const bundle = try build_model.supportedLlvmToolBundle("native");
    try std.testing.expectError(
        error.InvalidManifest,
        validateArtifactManifestApproval(std.testing.allocator, "id = \"llvm-host\"\n", bundle, .aarch64_apple_darwin, "llvm-host", true),
    );
}

test "resource header manifests preserve file identities and reject corruption" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "lib/clang/22/include");
    const relative = "lib/clang/22/include/stdbool.h";
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = relative, .data = "#define bool _Bool\n" });
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, relative });
    defer allocator.free(path);
    const hash = try hashFileSha256Hex(allocator, path);
    defer allocator.free(hash);
    const source = try std.fmt.allocPrint(
        allocator,
        "resource_headers = \"{s}\"\nresource_headers_sha256 = \"{s}\"\n",
        .{ relative, hash },
    );
    defer allocator.free(source);
    const manifest = try parseToolchainArtifactManifest(source);
    try std.testing.expectEqualStrings(relative, manifest.resource_headers);
    try validateArtifactToolDigestList(allocator, root, manifest.resource_headers, manifest.resource_headers_sha256);
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = relative, .data = "changed\n" });
    try std.testing.expectError(error.InvalidManifest, validateArtifactToolDigestList(allocator, root, manifest.resource_headers, manifest.resource_headers_sha256));
    try compat.deleteFile(path);
    try std.testing.expectError(error.FileNotFound, validateArtifactToolDigestList(allocator, root, manifest.resource_headers, manifest.resource_headers_sha256));
}

test "legacy host tag remains valid for published artifact manifests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "bin");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "bin/tool", .data = "hello\n" });

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);

    const tool_path = try std.fs.path.join(std.testing.allocator, &.{ root, "bin", "tool" });
    defer std.testing.allocator.free(tool_path);
    const hash = try hashFileSha256Hex(std.testing.allocator, tool_path);
    defer std.testing.allocator.free(hash);

    const manifest_text = try std.fmt.allocPrint(
        std.testing.allocator,
        \\id = "llvm-host"
        \\version = "22.1.2"
        \\family = "llvm"
        \\host = "macos-aarch64"
        \\compiler = "bin/tool"
        \\compiler_sha256 = "{s}"
        \\archiver = "bin/tool"
        \\archiver_sha256 = "{s}"
        \\linker = ""
        \\linker_sha256 = ""
        \\objcopy = ""
        \\objcopy_sha256 = ""
        \\provisioned_from = "artifact"
        \\
    ,
        .{ hash, hash },
    );
    defer std.testing.allocator.free(manifest_text);

    const manifest = try parseToolchainArtifactManifest(manifest_text);
    try validateToolchainArtifactManifest(
        std.testing.allocator,
        root,
        try build_model.supportedLlvmToolBundle("native"),
        .aarch64_apple_darwin,
        manifest,
    );
}

test "resolved tool cache identity follows actual binaries libraries headers and manifest" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "bin");
    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "bin/clang", .data = "compiler-a" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/llvm", .data = "library-a" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/header.h", .data = "header-a" });
    const manifest = "libllvm = \"lib/llvm\"\nresource_headers = \"lib/header.h\"\n";
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "bundle.toml", .data = manifest });
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    const bin = try std.fs.path.join(allocator, &.{ root, "bin" });
    defer allocator.free(bin);
    const compiler = try std.fs.path.join(allocator, &.{ bin, "clang" });
    defer allocator.free(compiler);
    const tools: ResolvedDistributionTools = .{
        .cc = .{ .path = compiler, .owned = false },
        .ar = .{ .path = compiler, .owned = false },
        .lld = null,
        .objcopy = null,
    };
    const original = try distributionCacheIdentity(allocator, tools, bin);
    const changes = [_]struct { path: []const u8, before: []const u8, after: []const u8 }{
        .{ .path = "bin/clang", .before = "compiler-a", .after = "compiler-b" },
        .{ .path = "lib/llvm", .before = "library-a", .after = "library-b" },
        .{ .path = "lib/header.h", .before = "header-a", .after = "header-b" },
        .{ .path = "bundle.toml", .before = manifest, .after = manifest ++ "version = \"changed\"\n" },
    };
    for (changes) |change| {
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = change.path, .data = change.after });
        const changed = try distributionCacheIdentity(allocator, tools, bin);
        try std.testing.expect(!std.mem.eql(u8, &original, &changed));
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = change.path, .data = change.before });
        try std.testing.expectEqualSlices(u8, &original, &(try distributionCacheIdentity(allocator, tools, bin)));
    }
}

test "hash bytes sha256 hex is stable" {
    const digest = try hashBytesSha256Hex(std.testing.allocator, "abc");
    defer std.testing.allocator.free(digest);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", digest);
}

test "parse env bool accepts common truthy forms" {
    try std.testing.expect(parseEnvBool("1"));
    try std.testing.expect(parseEnvBool("true"));
    try std.testing.expect(parseEnvBool("YES"));
    try std.testing.expect(!parseEnvBool("0"));
    try std.testing.expect(!parseEnvBool("false"));
}

fn writeTextFile(path: []const u8, text: []const u8) !void {
    try ensureParentDir(path);
    try compat.writeFile(.{
        .sub_path = path,
        .data = text,
        .flags = .{ .truncate = true },
    });
}

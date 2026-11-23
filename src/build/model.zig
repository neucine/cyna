const std = @import("std");
const build_options = @import("build_options");
const compat = @import("../compat.zig");
const diagnostics = @import("../compiler/diagnostics.zig");

pub const OutputKind = enum {
    exe,
    staticlib,
    sharedlib,
};

pub const OptMode = enum {
    debug,
    release,
};

pub const EmitOptions = struct {
    tok: bool = false,
    ast: bool = false,
    sir: bool = false,
    lir: bool = false,
    llvm: bool = false,
    c_header: bool = false,
    asm_include: bool = false,
    obj: bool = false,
    elf: bool = false,
    bin: bool = false,
    hex: bool = false,
};

pub const ToolchainFamily = enum {
    llvm,
};

pub const ToolchainBundleSpec = struct {
    id: []const u8,
    version: []const u8,
    family: ToolchainFamily,
    legacy_artifact_ids: []const []const u8 = &.{},
};

pub const TargetSupportSpec = struct {
    id: []const u8,
    revision: u32,
};

pub const ToolchainArtifactApproval = struct {
    bundle_id: []const u8,
    artifact_id: []const u8,
    host: ToolchainHost,
    manifest_sha256: []const u8,
};

pub const TargetSupportArtifactApproval = struct {
    target_id: []const u8,
    revision: u32,
    manifest_sha256: []const u8,
};

pub const ToolchainHost = enum {
    aarch64_apple_darwin,
    x86_64_unknown_linux_gnu,
    x86_64_pc_windows_gnu,
};

pub const toolchain_bundles = [_]ToolchainBundleSpec{
    .{
        .id = "llvm",
        .version = "22.1.2",
        .family = .llvm,
        .legacy_artifact_ids = &.{"llvm-host"},
    },
};

pub const toolchain_artifact_approvals = [_]ToolchainArtifactApproval{
    .{
        .bundle_id = "llvm",
        .artifact_id = "llvm",
        .host = .aarch64_apple_darwin,
        .manifest_sha256 = "ef3b8e8aa743fa18eec1774cd7f57a538215e270fa42e86ad553a516e0b39c62",
    },
    .{
        .bundle_id = "llvm",
        .artifact_id = "llvm-host",
        .host = .aarch64_apple_darwin,
        .manifest_sha256 = "f1ae107d9d6c15235c7eab83a16aa13cb63e4c7273cd88acd19afffadd26f1ba",
    },
};

pub const target_support_artifact_approvals = [_]TargetSupportArtifactApproval{
    .{
        .target_id = "aarch64-apple-darwin",
        .revision = 1,
        .manifest_sha256 = "9fd67d0f7c11a9ad50b3db4eca2e475b8d113c570a9b26efba65c707b0b19042",
    },
    .{
        .target_id = "aarch64-none-elf",
        .revision = 1,
        .manifest_sha256 = "e652d9d65789393507b74f8ca26ee96220fb272111bbf319c971c487d2a22f05",
    },
    .{
        .target_id = "x86_64-none-elf",
        .revision = 1,
        .manifest_sha256 = "7db51ad503d61131fb2ef45ab646d72b251e4a05d5b4663c4dd8cd9745aa3d0f",
    },
    .{
        .target_id = "riscv64-none-elf",
        .revision = 1,
        .manifest_sha256 = "3eff233314e5311423a126e821b8f769771c0a02df7d09a0dce32cca420d0273",
    },
    .{
        .target_id = "riscv32-none-elf",
        .revision = 1,
        .manifest_sha256 = "78d2882ed6b11ab8e08f5b6e0f3837964f45c6ae24cfb30edc39107f67e03779",
    },
    .{
        .target_id = "arm-none-eabi",
        .revision = 1,
        .manifest_sha256 = "fecd25d0a72d7757e01d7c790aae763d9bf90baadfc7194f7794f4d18a664db1",
    },
    .{
        .target_id = "thumbv7em-none-eabi",
        .revision = 1,
        .manifest_sha256 = "140b80458594977c4291470e7b2475a290c468649f0d4de0e0d6b6b1c741d4f4",
    },
};

pub const cyna_version = build_options.cyna_version;
pub const official_distribution_base_url = "https://downloads.cyna.dev/distributions";

pub fn officialDistributionRoot(allocator: std.mem.Allocator) !?[]u8 {
    const exe_path = compat.executablePathAlloc(allocator) catch return null;
    defer allocator.free(exe_path);

    const exe_dir = std.fs.path.dirname(exe_path) orelse return null;
    const prefix = installPrefixForExeDir(exe_dir);
    const distribution_root = try officialDistributionRootAtPrefix(allocator, prefix);
    errdefer allocator.free(distribution_root);
    compat.access(distribution_root, .{}) catch {
        allocator.free(distribution_root);
        return null;
    };
    return distribution_root;
}

fn installPrefixForExeDir(exe_dir: []const u8) []const u8 {
    if (std.mem.eql(u8, std.fs.path.basename(exe_dir), "bin")) {
        return std.fs.path.dirname(exe_dir) orelse exe_dir;
    }
    return exe_dir;
}

fn officialDistributionRootAtPrefix(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    return allocator.dupe(u8, prefix);
}

pub fn officialDistributionBaseUrl(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{
        official_distribution_base_url,
        cyna_version,
        toolchainHostTag(supportedHost()),
    });
}

pub fn supportedHost() ToolchainHost {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .macos => .aarch64_apple_darwin,
        .linux => .x86_64_unknown_linux_gnu,
        .windows => .x86_64_pc_windows_gnu,
        else => .aarch64_apple_darwin,
    };
}

pub fn isSupportedCompilerHost(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) bool {
    return (os == .macos and arch == .aarch64) or
        (os == .linux and arch == .x86_64) or
        (os == .windows and arch == .x86_64);
}

test "compiler distribution host support is explicit" {
    try std.testing.expect(isSupportedCompilerHost(.macos, .aarch64));
    try std.testing.expect(isSupportedCompilerHost(.linux, .x86_64));
    try std.testing.expect(isSupportedCompilerHost(.windows, .x86_64));
    try std.testing.expect(!isSupportedCompilerHost(.linux, .aarch64));
    try std.testing.expect(!isSupportedCompilerHost(.macos, .x86_64));
}

pub fn toolchainHostTag(host: ToolchainHost) []const u8 {
    return switch (host) {
        .aarch64_apple_darwin => "aarch64-apple-darwin",
        .x86_64_unknown_linux_gnu => "x86_64-unknown-linux-gnu",
        .x86_64_pc_windows_gnu => "x86_64-pc-windows-gnu",
    };
}

pub fn toolchainLegacyHostTag(host: ToolchainHost) ?[]const u8 {
    return switch (host) {
        .aarch64_apple_darwin => "macos-aarch64",
        .x86_64_unknown_linux_gnu => null,
        .x86_64_pc_windows_gnu => null,
    };
}

pub fn hasApprovedToolchainArtifact(bundle: ToolchainBundleSpec, host: ToolchainHost) bool {
    for (toolchain_artifact_approvals) |approval| {
        if (std.mem.eql(u8, approval.bundle_id, bundle.id) and approval.host == host) return true;
    }
    return false;
}

pub fn approvedToolchainArtifactForId(bundle: ToolchainBundleSpec, artifact_id: []const u8, host: ToolchainHost) ?ToolchainArtifactApproval {
    for (toolchain_artifact_approvals) |approval| {
        if (std.mem.eql(u8, approval.bundle_id, bundle.id) and
            std.mem.eql(u8, approval.artifact_id, artifact_id) and
            approval.host == host) return approval;
    }
    return null;
}

pub fn hasApprovedTargetSupportArtifact(support: TargetSupportSpec) bool {
    for (target_support_artifact_approvals) |approval| {
        if (std.mem.eql(u8, approval.target_id, support.id) and approval.revision == support.revision) return true;
    }
    return false;
}

pub fn approvedTargetSupportArtifact(support: TargetSupportSpec) ?TargetSupportArtifactApproval {
    for (target_support_artifact_approvals) |approval| {
        if (std.mem.eql(u8, approval.target_id, support.id) and approval.revision == support.revision) return approval;
    }
    return null;
}

pub fn toolchainArtifactBelongsToBundle(bundle: ToolchainBundleSpec, artifact_id: []const u8) bool {
    if (std.mem.eql(u8, bundle.id, artifact_id)) return true;
    for (bundle.legacy_artifact_ids) |legacy_id| {
        if (std.mem.eql(u8, legacy_id, artifact_id)) return true;
    }
    return false;
}

pub fn llvmBundleSupportsTarget(bundle: ToolchainBundleSpec, target: SupportedTarget) bool {
    return std.mem.eql(u8, bundle.id, target.llvm_tool_bundle);
}

pub const SupportedTarget = struct {
    name: []const u8,
    toolchain_target: ?[]const u8,
    llvm_tool_bundle: []const u8,
    target_support: TargetSupportSpec,
    toolchain_family: ToolchainFamily,
    freestanding: bool,
    supports_emit: EmitOptions,
};

pub const supported_targets = [_]SupportedTarget{
    .{
        .name = "native",
        .toolchain_target = null,
        .llvm_tool_bundle = "llvm",
        .target_support = .{ .id = "aarch64-apple-darwin", .revision = 1 },
        .toolchain_family = .llvm,
        .freestanding = false,
        .supports_emit = .{ .obj = true },
    },
    .{
        .name = "x86_64-unknown-linux-gnu",
        .toolchain_target = "x86_64-unknown-linux-gnu",
        .llvm_tool_bundle = "llvm",
        .target_support = .{ .id = "x86_64-unknown-linux-gnu", .revision = 1 },
        .toolchain_family = .llvm,
        .freestanding = false,
        .supports_emit = .{ .obj = true },
    },
    .{
        .name = "x86_64-pc-windows-gnu",
        .toolchain_target = "x86_64-pc-windows-gnu",
        .llvm_tool_bundle = "llvm",
        .target_support = .{ .id = "x86_64-pc-windows-gnu", .revision = 1 },
        .toolchain_family = .llvm,
        .freestanding = false,
        .supports_emit = .{ .obj = true },
    },
    .{
        .name = "aarch64-none-elf",
        .toolchain_target = "aarch64-none-elf",
        .llvm_tool_bundle = "llvm",
        .target_support = .{ .id = "aarch64-none-elf", .revision = 1 },
        .toolchain_family = .llvm,
        .freestanding = true,
        .supports_emit = .{ .obj = true, .elf = true, .bin = true, .hex = true },
    },
    .{
        .name = "x86_64-none-elf",
        .toolchain_target = "x86_64-none-elf",
        .llvm_tool_bundle = "llvm",
        .target_support = .{ .id = "x86_64-none-elf", .revision = 1 },
        .toolchain_family = .llvm,
        .freestanding = true,
        .supports_emit = .{ .obj = true, .elf = true, .bin = true, .hex = true },
    },
    .{
        .name = "riscv64-none-elf",
        .toolchain_target = "riscv64-none-elf",
        .llvm_tool_bundle = "llvm",
        .target_support = .{ .id = "riscv64-none-elf", .revision = 1 },
        .toolchain_family = .llvm,
        .freestanding = true,
        .supports_emit = .{ .obj = true, .elf = true, .bin = true, .hex = true },
    },
    .{
        .name = "riscv32-none-elf",
        .toolchain_target = "riscv32-none-elf",
        .llvm_tool_bundle = "llvm",
        .target_support = .{ .id = "riscv32-none-elf", .revision = 1 },
        .toolchain_family = .llvm,
        .freestanding = true,
        .supports_emit = .{ .obj = true, .elf = true, .bin = true, .hex = true },
    },
    .{
        .name = "arm-none-eabi",
        .toolchain_target = "arm-none-eabi",
        .llvm_tool_bundle = "llvm",
        .target_support = .{ .id = "arm-none-eabi", .revision = 1 },
        .toolchain_family = .llvm,
        .freestanding = true,
        .supports_emit = .{ .obj = true, .elf = true, .bin = true, .hex = true },
    },
    .{
        .name = "thumbv7em-none-eabi",
        .toolchain_target = "thumbv7em-none-eabi",
        .llvm_tool_bundle = "llvm",
        .target_support = .{ .id = "thumbv7em-none-eabi", .revision = 1 },
        .toolchain_family = .llvm,
        .freestanding = true,
        .supports_emit = .{ .obj = true, .elf = true, .bin = true, .hex = true },
    },
};

pub const LinkOptions = struct {
    libs: [][]const u8 = &.{},
    search_paths: [][]const u8 = &.{},
    script: ?[]const u8 = null,
    entry_symbol: ?[]const u8 = null,

    pub fn deinit(self: *LinkOptions, allocator: std.mem.Allocator) void {
        freeStringSlice(allocator, self.libs);
        freeStringSlice(allocator, self.search_paths);
        if (self.script) |value| allocator.free(value);
        if (self.entry_symbol) |value| allocator.free(value);
        self.* = .{};
    }
};

pub const NativeSourceOptions = struct {
    sources: [][]const u8 = &.{},
    include_paths: [][]const u8 = &.{},
    flags: [][]const u8 = &.{},

    pub fn deinit(self: *NativeSourceOptions, allocator: std.mem.Allocator) void {
        freeStringSlice(allocator, self.sources);
        freeStringSlice(allocator, self.include_paths);
        freeStringSlice(allocator, self.flags);
        self.* = .{};
    }
};

pub const TestOptions = struct {
    dir: []const u8,
    explicit: bool = false,

    pub fn deinit(self: *TestOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.dir);
        self.* = undefined;
    }
};

pub const DiscoveredTests = struct {
    dir_path: []const u8,
    files: [][]const u8,
    explicit: bool,

    pub fn deinit(self: *DiscoveredTests, allocator: std.mem.Allocator) void {
        allocator.free(self.dir_path);
        freeStringSlice(allocator, self.files);
        self.* = undefined;
    }
};

const BuildSection = struct {
    kind: ?OutputKind = null,
    entry: ?[]const u8 = null,
    target: ?[]const u8 = null,
    cpu: ?[]const u8 = null,
    opt: ?OptMode = null,
    emit: EmitOptions = .{},
    leak_check: bool = false,
    features: [][]const u8 = &.{},

    fn deinit(self: *BuildSection, allocator: std.mem.Allocator) void {
        if (self.entry) |value| allocator.free(value);
        if (self.target) |value| allocator.free(value);
        if (self.cpu) |value| allocator.free(value);
        freeStringSlice(allocator, self.features);
        self.* = .{};
    }
};

const NamedBuildConfig = struct {
    name: []const u8,
    build: BuildSection = .{},
    link: LinkOptions = .{},
    c_sources: NativeSourceOptions = .{},
    asm_sources: NativeSourceOptions = .{},

    fn deinit(self: *NamedBuildConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.build.deinit(allocator);
        self.link.deinit(allocator);
        self.c_sources.deinit(allocator);
        self.asm_sources.deinit(allocator);
        self.* = undefined;
    }
};

const Manifest = struct {
    name: ?[]const u8 = null,
    src: ?[]const u8 = null,
    output_kind: OutputKind = .exe,
    entry: ?[]const u8 = null,
    version: ?[]const u8 = null,
    default_build: ?[]const u8 = null,
    build: BuildSection = .{},
    test_options: ?TestOptions = null,
    link: LinkOptions = .{},
    c_sources: NativeSourceOptions = .{},
    asm_sources: NativeSourceOptions = .{},
    named_builds: []NamedBuildConfig = &.{},

    fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.src) |value| allocator.free(value);
        if (self.entry) |value| allocator.free(value);
        if (self.version) |value| allocator.free(value);
        if (self.default_build) |value| allocator.free(value);
        self.build.deinit(allocator);
        if (self.test_options) |*test_options| test_options.deinit(allocator);
        self.link.deinit(allocator);
        self.c_sources.deinit(allocator);
        self.asm_sources.deinit(allocator);
        for (self.named_builds) |*config| config.deinit(allocator);
        allocator.free(self.named_builds);
        self.* = .{};
    }
};

pub const BuildTarget = struct {
    /// Borrowed compiler/build ABI identity; callers transporting an artifact
    /// between compiler processes must name the producing compiler explicitly.
    compiler_identity: []const u8 = build_options.compiler_identity,
    is_project: bool,
    display_path: []const u8,
    root_dir: []const u8,
    source_path: []const u8,
    name: []const u8,
    target: ?[]const u8 = null,
    cpu: ?[]const u8 = null,
    output_kind: OutputKind = .exe,
    opt: OptMode = .debug,
    emit: EmitOptions = .{},
    leak_check: bool = false,
    test_options: ?TestOptions = null,
    link: LinkOptions = .{},
    c_sources: NativeSourceOptions = .{},
    asm_sources: NativeSourceOptions = .{},
    manifest_path: ?[]const u8 = null,

    pub fn deinit(self: *BuildTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.display_path);
        allocator.free(self.root_dir);
        allocator.free(self.source_path);
        allocator.free(self.name);
        if (self.target) |value| allocator.free(value);
        if (self.cpu) |value| allocator.free(value);
        if (self.test_options) |*test_options| test_options.deinit(allocator);
        self.link.deinit(allocator);
        self.c_sources.deinit(allocator);
        self.asm_sources.deinit(allocator);
        if (self.manifest_path) |value| allocator.free(value);
        self.* = undefined;
    }

    pub fn artifactBasePath(self: BuildTarget, allocator: std.mem.Allocator, override_output: ?[]const u8) ![]u8 {
        if (override_output) |value| return allocator.dupe(u8, value);
        if (!self.is_project) {
            const stem = std.fs.path.stem(self.source_path);
            const dir = std.fs.path.dirname(self.source_path) orelse ".";
            return std.fs.path.join(allocator, &.{ dir, stem });
        }
        return std.fs.path.join(allocator, &.{ self.root_dir, "build", self.name });
    }

    pub fn nativeOutputPath(self: BuildTarget, allocator: std.mem.Allocator, override_output: ?[]const u8) ![]u8 {
        if (override_output) |value| return allocator.dupe(u8, value);
        if (!self.is_project) {
            const base = try self.artifactBasePath(allocator, null);
            defer allocator.free(base);
            return std.fmt.allocPrint(allocator, "{s}.native", .{base});
        }

        const build_dir = try std.fs.path.join(allocator, &.{ self.root_dir, "build" });
        defer allocator.free(build_dir);
        return switch (self.output_kind) {
            .exe => std.fs.path.join(allocator, &.{ build_dir, self.name }),
            .staticlib => std.fmt.allocPrint(allocator, "{s}/lib{s}.a", .{ build_dir, self.name }),
            .sharedlib => std.fmt.allocPrint(allocator, "{s}/lib{s}{s}", .{ build_dir, self.name, sharedLibrarySuffix() }),
        };
    }

    pub fn testDirPath(self: BuildTarget, allocator: std.mem.Allocator) ![]u8 {
        const rel = if (self.test_options) |test_options| test_options.dir else {
            const conventional_source_root = try std.fs.path.join(allocator, &.{ self.root_dir, "src" });
            if (pathExists(conventional_source_root)) return conventional_source_root;
            allocator.free(conventional_source_root);
            return allocator.dupe(u8, std.fs.path.dirname(self.source_path) orelse ".");
        };
        if (std.fs.path.isAbsolute(rel)) return allocator.dupe(u8, rel);
        return std.fs.path.join(allocator, &.{ self.root_dir, rel });
    }
};

pub fn discoverTestFiles(allocator: std.mem.Allocator, target: BuildTarget) !DiscoveredTests {
    var diagnostic_context = diagnostics.Context.discarded();
    return discoverTestFilesWithDiagnostics(allocator, target, &diagnostic_context);
}

pub fn discoverTestFilesWithDiagnostics(
    allocator: std.mem.Allocator,
    target: BuildTarget,
    diagnostic_context: *diagnostics.Context,
) !DiscoveredTests {
    const dir_path = try target.testDirPath(allocator);
    errdefer allocator.free(dir_path);
    const explicit = if (target.test_options) |test_options| test_options.explicit else false;

    var dir = compat.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            if (explicit) {
                try diagnostic_context.emitPath(target.display_path, "configured test directory does not exist");
                return error.TestDirNotFound;
            }
            return .{
                .dir_path = dir_path,
                .files = try allocator.alloc([]const u8, 0),
                .explicit = false,
            };
        },
        else => return err,
    };
    defer compat.closeDir(dir);

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try compat.walkerNext(&walker)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".test.cy")) continue;
        try files.append(allocator, try std.fs.path.join(allocator, &.{ dir_path, entry.path }));
    }

    std.mem.sort([]const u8, files.items, {}, lessThanString);

    return .{
        .dir_path = dir_path,
        .files = try files.toOwnedSlice(allocator),
        .explicit = explicit,
    };
}

pub fn resolveBuildTarget(allocator: std.mem.Allocator, input_path: ?[]const u8) !BuildTarget {
    var diagnostic_context = diagnostics.Context.discarded();
    return resolveBuildTargetForConfigWithDiagnostics(allocator, input_path, null, &diagnostic_context);
}

pub fn resolveBuildTargetForConfig(allocator: std.mem.Allocator, input_path: ?[]const u8, requested_config: ?[]const u8) !BuildTarget {
    var diagnostic_context = diagnostics.Context.discarded();
    return resolveBuildTargetForConfigWithDiagnostics(allocator, input_path, requested_config, &diagnostic_context);
}

pub fn resolveBuildTargetForConfigWithDiagnostics(
    allocator: std.mem.Allocator,
    input_path: ?[]const u8,
    requested_config: ?[]const u8,
    diagnostic_context: *diagnostics.Context,
) !BuildTarget {
    if (input_path) |path| {
        if (std.mem.endsWith(u8, path, ".toml")) {
            return resolveManifestFileForConfig(allocator, path, requested_config, diagnostic_context);
        }
        if (std.mem.endsWith(u8, path, ".cy")) {
            return resolveSourceFile(diagnostic_context, allocator, path, requested_config);
        }
        if (try isDirectoryPath(path)) {
            const root_dir = try compat.cwdRealpathAlloc(allocator, path);
            defer allocator.free(root_dir);
            return resolveProjectDirectory(allocator, root_dir, requested_config, diagnostic_context);
        }
        return resolveSourceFile(diagnostic_context, allocator, path, requested_config);
    }

    const root_dir = try compat.cwdRealpathAlloc(allocator, ".");
    defer allocator.free(root_dir);
    return resolveProjectDirectory(allocator, root_dir, requested_config, diagnostic_context);
}

pub fn normalizedToolchainTarget(allocator: std.mem.Allocator, target: ?[]const u8) !?[]const u8 {
    const spec = try supportedTarget(target) orelse return null;
    return if (spec.toolchain_target) |value|
        @as(?[]const u8, try allocator.dupe(u8, value))
    else
        null;
}

pub fn isFreestandingTarget(target: ?[]const u8) bool {
    const spec = supportedTarget(target) catch return false;
    return if (spec) |value| value.freestanding else false;
}

pub fn supportedTarget(target: ?[]const u8) !?SupportedTarget {
    return supportedTargetForHost(target, supportedHost());
}

fn supportedTargetForHost(target: ?[]const u8, host: ToolchainHost) !?SupportedTarget {
    const value = target orelse "native";
    const resolved_host: ToolchainHost = if (std.mem.eql(u8, value, "aarch64-apple-darwin")) .aarch64_apple_darwin else host;
    var spec = supportedTargetByName(value) orelse return error.UnsupportedTarget;
    if (std.mem.eql(u8, spec.name, "native")) {
        spec.target_support.id = toolchainHostTag(resolved_host);
        // Darwin uses the SDK selected by the driver; GNU hosts must override Clang's
        // default, which can otherwise select the MSVC ABI on Windows.
        spec.toolchain_target = switch (resolved_host) {
            .aarch64_apple_darwin => null,
            .x86_64_unknown_linux_gnu, .x86_64_pc_windows_gnu => toolchainHostTag(resolved_host),
        };
    }
    return spec;
}

pub fn validateEmitOptionsForTarget(display_path: []const u8, target: ?[]const u8, emit: EmitOptions) !void {
    var diagnostic_context = diagnostics.Context.discarded();
    return validateEmitOptionsForTargetWithDiagnostics(display_path, target, emit, &diagnostic_context);
}

pub fn validateEmitOptionsForTargetWithDiagnostics(
    display_path: []const u8,
    target: ?[]const u8,
    emit: EmitOptions,
    diagnostic_context: *diagnostics.Context,
) !void {
    const spec = (try supportedTarget(target)) orelse return;
    if (emit.obj and !spec.supports_emit.obj) return printUnsupportedEmit(diagnostic_context, display_path, spec.name, "obj");
    if (emit.elf and !spec.supports_emit.elf) return printUnsupportedEmit(diagnostic_context, display_path, spec.name, "elf");
    if (emit.bin and !spec.supports_emit.bin) return printUnsupportedEmit(diagnostic_context, display_path, spec.name, "bin");
    if (emit.hex and !spec.supports_emit.hex) return printUnsupportedEmit(diagnostic_context, display_path, spec.name, "hex");
}

pub fn supportedLlvmToolBundle(target: ?[]const u8) !ToolchainBundleSpec {
    const spec = (try supportedTarget(target)).?;
    return toolchainBundleById(spec.llvm_tool_bundle) orelse unreachable;
}

pub fn supportedTargetSupport(target: ?[]const u8) !TargetSupportSpec {
    const spec = (try supportedTarget(target)).?;
    return spec.target_support;
}

// Darwin names the native SDK toolchain explicitly without requiring a triple.
const target_name_aliases = [_]struct { alias: []const u8, canonical: []const u8 }{
    .{ .alias = "aarch64-apple-darwin", .canonical = "native" },
};

fn supportedTargetByName(name: []const u8) ?SupportedTarget {
    for (supported_targets) |target| {
        if (std.mem.eql(u8, target.name, name)) return target;
    }
    for (target_name_aliases) |alias| {
        if (!std.mem.eql(u8, alias.alias, name)) continue;
        for (supported_targets) |target| {
            if (std.mem.eql(u8, target.name, alias.canonical)) return target;
        }
    }
    return null;
}

fn validateLinkContract(
    diagnostic_context: *diagnostics.Context,
    display_path: []const u8,
    target_name: ?[]const u8,
    output_kind: OutputKind,
    emit: EmitOptions,
    link: LinkOptions,
) !void {
    if ((link.script != null or link.entry_symbol != null) and output_kind != .exe) {
        try diagnostic_context.emitPath(display_path, "link.script and link.entry_symbol require executable output");
        return error.UnsupportedTarget;
    }

    if (!isFreestandingTarget(target_name)) return;
    if (output_kind != .exe) return;

    if (emit.bin or emit.hex) {
        if (link.script == null) {
            try diagnostic_context.emitPath(display_path, "freestanding --emit-bin/--emit-hex builds require [link].script");
            return error.UnsupportedTarget;
        }
        if (link.entry_symbol == null) {
            try diagnostic_context.emitPath(display_path, "freestanding --emit-bin/--emit-hex builds require [link].entry_symbol");
            return error.UnsupportedTarget;
        }
    }
}

fn toolchainBundleById(id: []const u8) ?ToolchainBundleSpec {
    for (toolchain_bundles) |bundle| {
        if (std.mem.eql(u8, bundle.id, id)) return bundle;
    }
    return null;
}

fn printUnsupportedEmit(diagnostic_context: *diagnostics.Context, display_path: []const u8, target_name: []const u8, emit_name: []const u8) !void {
    var buf: [160]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "target `{s}` does not support --emit-{s}", .{ target_name, emit_name }) catch "target does not support requested emit";
    try diagnostic_context.emitPath(display_path, message);
    return error.UnsupportedTarget;
}

fn resolveProjectDirectory(allocator: std.mem.Allocator, root_dir: []const u8, requested_config: ?[]const u8, diagnostic_context: *diagnostics.Context) !BuildTarget {
    const manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "cyna.toml" });
    defer allocator.free(manifest_path);
    if (pathExists(manifest_path)) {
        return resolveManifestFileForConfig(allocator, manifest_path, requested_config, diagnostic_context);
    }

    const entry_path = try std.fs.path.join(allocator, &.{ root_dir, "src", "main.cy" });
    defer allocator.free(entry_path);
    if (!pathExists(entry_path)) {
        try diagnostic_context.emitPath(root_dir, "no cyna.toml or src/main.cy found");
        return error.ProjectNotFound;
    }

    return .{
        .is_project = true,
        .display_path = try allocator.dupe(u8, root_dir),
        .root_dir = try allocator.dupe(u8, root_dir),
        .source_path = try compat.cwdRealpathAlloc(allocator, entry_path),
        .name = try allocator.dupe(u8, std.fs.path.basename(root_dir)),
        .test_options = null,
    };
}

fn resolveManifestFile(allocator: std.mem.Allocator, manifest_input_path: []const u8) !BuildTarget {
    var diagnostic_context = diagnostics.Context.discarded();
    return resolveManifestFileForConfig(allocator, manifest_input_path, null, &diagnostic_context);
}

fn resolveManifestFileForConfig(allocator: std.mem.Allocator, manifest_input_path: []const u8, requested_config: ?[]const u8, diagnostic_context: *diagnostics.Context) !BuildTarget {
    const manifest_path = try compat.cwdRealpathAlloc(allocator, manifest_input_path);
    errdefer allocator.free(manifest_path);

    const root_dir = blk: {
        const parent = std.fs.path.dirname(manifest_path) orelse ".";
        break :blk try allocator.dupe(u8, parent);
    };
    errdefer allocator.free(root_dir);

    var manifest = try parseManifestFile(allocator, manifest_path, diagnostic_context);
    defer manifest.deinit(allocator);

    const selected_config = try selectBuildConfig(manifest_path, manifest, requested_config, diagnostic_context);
    var resolved_build = try resolvedBuildSection(allocator, manifest, selected_config);
    defer {
        if (resolved_build.entry) |value| allocator.free(value);
        if (resolved_build.target) |value| allocator.free(value);
        if (resolved_build.cpu) |value| allocator.free(value);
        freeStringSlice(allocator, resolved_build.features);
    }
    var link = try resolvedLinkOptions(allocator, manifest, selected_config);
    errdefer link.deinit(allocator);
    var c_sources = try resolvedNativeSourceOptions(allocator, manifest.c_sources, if (selected_config) |config| config.c_sources else null);
    errdefer c_sources.deinit(allocator);
    var asm_sources = try resolvedNativeSourceOptions(allocator, manifest.asm_sources, if (selected_config) |config| config.asm_sources else null);
    errdefer asm_sources.deinit(allocator);

    if (resolved_build.target) |target| {
        const normalized = normalizedToolchainTarget(allocator, target) catch {
            try diagnostic_context.emitPath(manifest_path, "unsupported build.target; use \"native\" or a supported canonical target triple");
            return error.UnsupportedTarget;
        };
        if (normalized) |value| allocator.free(value);
    }
    if (resolved_build.features.len != 0) {
        try diagnostic_context.emitPath(manifest_path, "build.features is not a recognized manifest field; remove it");
        return error.UnsupportedTarget;
    }

    const output_kind = resolved_build.kind orelse manifest.output_kind;
    const default_entry_rel = switch (output_kind) {
        .exe => "main.cy",
        .staticlib, .sharedlib => "lib.cy",
    };
    const entry_rel = if (resolved_build.entry) |value|
        value
    else if (manifest.entry) |value|
        value
    else if (manifest.src) |src_root|
        try std.fs.path.join(allocator, &.{ src_root, default_entry_rel })
    else switch (output_kind) {
        .exe => "src/main.cy",
        .staticlib, .sharedlib => "src/lib.cy",
    };
    defer if (resolved_build.entry == null and manifest.entry == null and manifest.src != null) allocator.free(entry_rel);
    const entry_path = try resolvePathAgainstRoot(allocator, root_dir, entry_rel);
    errdefer allocator.free(entry_path);
    if (!pathExists(entry_path)) {
        try diagnostic_context.emitPath(manifest_path, "manifest entry file does not exist");
        return error.FileNotFound;
    }

    const name = if (manifest.name) |value|
        try allocator.dupe(u8, value)
    else
        try allocator.dupe(u8, std.fs.path.basename(root_dir));
    errdefer allocator.free(name);

    try absolutizeLinkOptions(allocator, root_dir, &link);
    try absolutizeNativeSourceOptions(allocator, root_dir, &c_sources);
    try absolutizeNativeSourceOptions(allocator, root_dir, &asm_sources);
    try validateLinkContract(diagnostic_context, manifest_path, resolved_build.target, output_kind, resolved_build.emit, link);

    var target = BuildTarget{
        .is_project = true,
        .display_path = try allocator.dupe(u8, manifest_path),
        .root_dir = root_dir,
        .source_path = entry_path,
        .name = try buildTargetName(allocator, name, if (selected_config) |config| config.name else null),
        .target = resolved_build.target,
        .cpu = resolved_build.cpu,
        .output_kind = output_kind,
        .opt = resolved_build.opt orelse .debug,
        .emit = resolved_build.emit,
        .leak_check = resolved_build.leak_check,
        .test_options = manifest.test_options,
        .link = link,
        .c_sources = c_sources,
        .asm_sources = asm_sources,
        .manifest_path = manifest_path,
    };
    errdefer target.deinit(allocator);

    allocator.free(name);
    manifest.test_options = null;
    if (resolved_build.target != null) resolved_build.target = null;
    if (resolved_build.cpu != null) resolved_build.cpu = null;
    link = .{};
    c_sources = .{};
    asm_sources = .{};

    return target;
}

fn resolveSourceFile(diagnostic_context: *diagnostics.Context, allocator: std.mem.Allocator, source_input_path: []const u8, requested_config: ?[]const u8) !BuildTarget {
    const source_path = try compat.cwdRealpathAlloc(allocator, source_input_path);
    errdefer allocator.free(source_path);

    if (resolveManifestTargetForEntrySource(diagnostic_context, allocator, source_path, requested_config) catch |err| switch (err) {
        error.PermissionDenied, error.AccessDenied => null,
        else => return err,
    }) |target| {
        allocator.free(source_path);
        return target;
    }

    const root_dir = blk: {
        const parent = std.fs.path.dirname(source_path) orelse ".";
        break :blk try allocator.dupe(u8, parent);
    };
    errdefer allocator.free(root_dir);

    return .{
        .is_project = false,
        .display_path = try allocator.dupe(u8, source_path),
        .root_dir = root_dir,
        .source_path = source_path,
        .name = try allocator.dupe(u8, std.fs.path.stem(source_path)),
    };
}

fn resolveManifestTargetForEntrySource(diagnostic_context: *diagnostics.Context, allocator: std.mem.Allocator, source_path: []const u8, requested_config: ?[]const u8) !?BuildTarget {
    var current_dir = blk: {
        const parent = std.fs.path.dirname(source_path) orelse ".";
        break :blk try allocator.dupe(u8, parent);
    };
    defer allocator.free(current_dir);

    while (true) {
        const manifest_path = try std.fs.path.join(allocator, &.{ current_dir, "cyna.toml" });
        if (try resolveManifestTargetForEntrySourceAtPath(diagnostic_context, allocator, manifest_path, source_path, requested_config)) |target| {
            allocator.free(manifest_path);
            return target;
        }
        allocator.free(manifest_path);

        if (try resolveSiblingManifestTargetForEntrySource(diagnostic_context, allocator, current_dir, source_path, requested_config)) |target| return target;

        const parent = std.fs.path.dirname(current_dir) orelse return null;
        if (std.mem.eql(u8, parent, current_dir)) return null;

        const next_dir = try allocator.dupe(u8, parent);
        allocator.free(current_dir);
        current_dir = next_dir;
    }
}

fn resolveSiblingManifestTargetForEntrySource(diagnostic_context: *diagnostics.Context, allocator: std.mem.Allocator, dir_path: []const u8, source_path: []const u8, requested_config: ?[]const u8) !?BuildTarget {
    var dir = compat.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.PermissionDenied => return null,
        else => return err,
    };
    defer compat.closeDir(dir);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var iterator = dir.iterateAssumeFirstIteration();
    while (compat.dirIteratorNext(&iterator) catch |err| switch (err) {
        error.PermissionDenied => return null,
        else => return err,
    }) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
        if (std.mem.eql(u8, entry.name, "cyna.toml")) continue;
        if (entry.name.len != 0 and entry.name[0] == '.') continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    for (names.items) |name| {
        const manifest_path = try std.fs.path.join(allocator, &.{ dir_path, name });
        defer allocator.free(manifest_path);
        if (try resolveManifestTargetForEntrySourceAtPath(diagnostic_context, allocator, manifest_path, source_path, requested_config)) |target| return target;
    }
    return null;
}

fn resolveManifestTargetForEntrySourceAtPath(diagnostic_context: *diagnostics.Context, allocator: std.mem.Allocator, manifest_path: []const u8, source_path: []const u8, requested_config: ?[]const u8) !?BuildTarget {
    if (!pathExists(manifest_path)) return null;

    var matched_config = try manifestEntryConfigForSource(allocator, manifest_path, source_path);
    defer matched_config.deinit(allocator);
    if (!matched_config.matched) return null;

    const config_name = requested_config orelse matched_config.config_name;
    var target = try resolveManifestFileForConfig(allocator, manifest_path, config_name, diagnostic_context);
    errdefer target.deinit(allocator);
    if (std.mem.eql(u8, target.source_path, source_path)) return target;
    target.deinit(allocator);
    return null;
}

const ManifestEntryMatch = struct {
    matched: bool = false,
    config_name: ?[]const u8 = null,

    fn deinit(self: *ManifestEntryMatch, allocator: std.mem.Allocator) void {
        if (self.config_name) |name| allocator.free(name);
        self.* = .{};
    }
};

fn manifestEntryConfigForSource(allocator: std.mem.Allocator, manifest_path: []const u8, source_path: []const u8) !ManifestEntryMatch {
    const root_dir = std.fs.path.dirname(manifest_path) orelse ".";
    const source = compat.readFileAlloc(allocator, manifest_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(source);

    var current_build_config: ?[]const u8 = null;
    var in_build = false;
    var in_root = true;

    var line_it = std.mem.tokenizeScalar(u8, source, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            in_root = false;
            in_build = false;
            current_build_config = null;
            if (line.len >= "[build]".len and std.mem.eql(u8, line, "[build]")) {
                in_build = true;
            } else if (std.mem.startsWith(u8, line, "[build.") and line[line.len - 1] == ']') {
                const name = line["[build.".len .. line.len - 1];
                if (name.len != 0 and std.mem.indexOfScalar(u8, name, '.') == null) {
                    in_build = true;
                    current_build_config = name;
                }
            }
            continue;
        }

        if (!in_root and !in_build) continue;
        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        if (!std.mem.eql(u8, key, "entry")) continue;
        const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
        const entry_rel = parseManifestQuotedString(value) orelse continue;
        const entry_path = try resolvePathAgainstRoot(allocator, root_dir, entry_rel);
        defer allocator.free(entry_path);
        if (!std.mem.eql(u8, entry_path, source_path)) continue;
        return .{
            .matched = true,
            .config_name = if (current_build_config) |name| try allocator.dupe(u8, name) else null,
        };
    }
    return .{};
}

fn selectBuildConfig(manifest_path: []const u8, manifest: Manifest, requested_config: ?[]const u8, diagnostic_context: *diagnostics.Context) !?*const NamedBuildConfig {
    const name = requested_config orelse manifest.default_build orelse {
        if (manifest.named_builds.len == 0) return null;
        return &manifest.named_builds[0];
    };
    for (manifest.named_builds) |*config| {
        if (std.mem.eql(u8, config.name, name)) return config;
    }
    try diagnostic_context.emitPath(manifest_path, "unknown build config");
    return error.InvalidManifest;
}

fn resolvedBuildSection(allocator: std.mem.Allocator, manifest: Manifest, selected_config: ?*const NamedBuildConfig) !BuildSection {
    const overlay = if (selected_config) |config| config.build else BuildSection{};
    return .{
        .kind = overlay.kind orelse manifest.build.kind,
        .entry = if (overlay.entry) |value| try allocator.dupe(u8, value) else if (manifest.build.entry) |value| try allocator.dupe(u8, value) else null,
        .target = if (overlay.target) |value| try allocator.dupe(u8, value) else if (manifest.build.target) |value| try allocator.dupe(u8, value) else null,
        .cpu = if (overlay.cpu) |value| try allocator.dupe(u8, value) else if (manifest.build.cpu) |value| try allocator.dupe(u8, value) else null,
        .opt = overlay.opt orelse manifest.build.opt,
        .emit = mergeEmitOptions(manifest.build.emit, overlay.emit),
        .leak_check = manifest.build.leak_check or overlay.leak_check,
        .features = if (overlay.features.len != 0) try dupStringSliceConst(allocator, overlay.features) else try dupStringSliceConst(allocator, manifest.build.features),
    };
}

fn resolvedLinkOptions(allocator: std.mem.Allocator, manifest: Manifest, selected_config: ?*const NamedBuildConfig) !LinkOptions {
    const overlay = if (selected_config) |config| config.link else LinkOptions{};
    return .{
        .libs = if (overlay.libs.len != 0) try dupStringSliceConst(allocator, overlay.libs) else try dupStringSliceConst(allocator, manifest.link.libs),
        .search_paths = if (overlay.search_paths.len != 0) try dupStringSliceConst(allocator, overlay.search_paths) else try dupStringSliceConst(allocator, manifest.link.search_paths),
        .script = if (overlay.script) |value| try allocator.dupe(u8, value) else if (manifest.link.script) |value| try allocator.dupe(u8, value) else null,
        .entry_symbol = if (overlay.entry_symbol) |value| try allocator.dupe(u8, value) else if (manifest.link.entry_symbol) |value| try allocator.dupe(u8, value) else null,
    };
}

fn resolvedNativeSourceOptions(allocator: std.mem.Allocator, base: NativeSourceOptions, overlay: ?NativeSourceOptions) !NativeSourceOptions {
    const actual = overlay orelse NativeSourceOptions{};
    return .{
        .sources = if (actual.sources.len != 0) try dupStringSliceConst(allocator, actual.sources) else try dupStringSliceConst(allocator, base.sources),
        .include_paths = if (actual.include_paths.len != 0) try dupStringSliceConst(allocator, actual.include_paths) else try dupStringSliceConst(allocator, base.include_paths),
        .flags = if (actual.flags.len != 0) try dupStringSliceConst(allocator, actual.flags) else try dupStringSliceConst(allocator, base.flags),
    };
}

fn mergeEmitOptions(base: EmitOptions, overlay: EmitOptions) EmitOptions {
    return .{
        .tok = base.tok or overlay.tok,
        .ast = base.ast or overlay.ast,
        .sir = base.sir or overlay.sir,
        .lir = base.lir or overlay.lir,
        .llvm = base.llvm or overlay.llvm,
        .c_header = base.c_header or overlay.c_header,
        .asm_include = base.asm_include or overlay.asm_include,
        .obj = base.obj or overlay.obj,
        .elf = base.elf or overlay.elf,
        .bin = base.bin or overlay.bin,
        .hex = base.hex or overlay.hex,
    };
}

fn buildTargetName(allocator: std.mem.Allocator, package_name: []const u8, config_name: ?[]const u8) ![]u8 {
    if (config_name) |name| return std.fmt.allocPrint(allocator, "{s}-{s}", .{ package_name, name });
    return allocator.dupe(u8, package_name);
}

fn parseManifestFile(allocator: std.mem.Allocator, manifest_path: []const u8, diagnostic_context: *diagnostics.Context) !Manifest {
    const source = compat.readFileAlloc(allocator, manifest_path, 1024 * 1024) catch |err| {
        try diagnostic_context.emitPath(manifest_path, @errorName(err));
        return err;
    };
    defer allocator.free(source);

    var manifest: Manifest = .{};
    errdefer manifest.deinit(allocator);

    var line_it = std.mem.tokenizeScalar(u8, source, '\n');
    var line_no: usize = 0;
    var section = Section{ .kind = .root };
    while (line_it.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            section = parseSection(diagnostic_context, manifest_path, line, line_no) catch return error.InvalidManifest;
            continue;
        }

        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse {
            try printManifestError(diagnostic_context, manifest_path, line_no, "expected key = value");
            return error.InvalidManifest;
        };
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");

        if (section.kind == .root) {
            try assignRootKey(diagnostic_context, allocator, manifest_path, &manifest, key, value, line_no);
        } else if (section.kind == .dependencies) {
            try assignDependencyKey(diagnostic_context, allocator, manifest_path, key, value, line_no);
        } else if (section.kind == .build) {
            const build = try sectionBuild(allocator, &manifest, section.name);
            try assignBuildKey(diagnostic_context, allocator, manifest_path, &manifest, build, key, value, line_no);
        } else if (section.kind == .test_section) {
            try assignTestKey(diagnostic_context, allocator, manifest_path, &manifest, key, value, line_no);
        } else if (section.kind == .link) {
            const link = try sectionLink(allocator, &manifest, section.name);
            try assignLinkKey(diagnostic_context, allocator, manifest_path, link, key, value, line_no);
        } else if (section.kind == .c_section) {
            const c_sources = try sectionNativeSources(allocator, &manifest, section.name, .c_section);
            try assignNativeKey(diagnostic_context, allocator, manifest_path, c_sources, key, value, line_no);
        } else {
            const asm_sources = try sectionNativeSources(allocator, &manifest, section.name, .asm_section);
            try assignNativeKey(diagnostic_context, allocator, manifest_path, asm_sources, key, value, line_no);
        }
    }

    return manifest;
}

const SectionKind = enum {
    root,
    build,
    dependencies,
    test_section,
    link,
    c_section,
    asm_section,
};

const Section = struct {
    kind: SectionKind,
    name: ?[]const u8 = null,
};

fn parseSection(diagnostic_context: *diagnostics.Context, manifest_path: []const u8, line: []const u8, line_no: usize) !Section {
    if (line.len < 3 or line[line.len - 1] != ']') {
        try printManifestError(diagnostic_context, manifest_path, line_no, "malformed section header");
        return error.InvalidManifest;
    }
    const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    if (std.mem.eql(u8, name, "build")) return .{ .kind = .build };
    if (std.mem.eql(u8, name, "dependencies")) return .{ .kind = .dependencies };
    if (std.mem.eql(u8, name, "test")) return .{ .kind = .test_section };
    if (std.mem.eql(u8, name, "link")) return .{ .kind = .link };
    if (std.mem.eql(u8, name, "c")) return .{ .kind = .c_section };
    if (std.mem.eql(u8, name, "asm")) return .{ .kind = .asm_section };

    if (sectionNameSuffix(name, "build.")) |suffix| return .{ .kind = .build, .name = suffix };
    if (sectionNameSuffix(name, "link.")) |suffix| return .{ .kind = .link, .name = suffix };
    if (sectionNameSuffix(name, "c.")) |suffix| return .{ .kind = .c_section, .name = suffix };
    if (sectionNameSuffix(name, "asm.")) |suffix| return .{ .kind = .asm_section, .name = suffix };
    try printManifestError(diagnostic_context, manifest_path, line_no, "unknown manifest section");
    return error.InvalidManifest;
}

fn sectionNameSuffix(name: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const suffix = name[prefix.len..];
    return if (suffix.len == 0 or std.mem.indexOfScalar(u8, suffix, '.') != null) null else suffix;
}

fn sectionBuild(allocator: std.mem.Allocator, manifest: *Manifest, name: ?[]const u8) !*BuildSection {
    if (name == null) return &manifest.build;
    return &(try getOrCreateNamedBuild(allocator, manifest, name.?)).build;
}

fn sectionLink(allocator: std.mem.Allocator, manifest: *Manifest, name: ?[]const u8) !*LinkOptions {
    if (name == null) return &manifest.link;
    return &(try getOrCreateNamedBuild(allocator, manifest, name.?)).link;
}

fn sectionNativeSources(allocator: std.mem.Allocator, manifest: *Manifest, name: ?[]const u8, kind: SectionKind) !*NativeSourceOptions {
    if (name == null) {
        return switch (kind) {
            .c_section => &manifest.c_sources,
            .asm_section => &manifest.asm_sources,
            else => unreachable,
        };
    }
    const config = try getOrCreateNamedBuild(allocator, manifest, name.?);
    return switch (kind) {
        .c_section => &config.c_sources,
        .asm_section => &config.asm_sources,
        else => unreachable,
    };
}

fn getOrCreateNamedBuild(allocator: std.mem.Allocator, manifest: *Manifest, name: []const u8) !*NamedBuildConfig {
    for (manifest.named_builds) |*config| {
        if (std.mem.eql(u8, config.name, name)) return config;
    }
    const old = manifest.named_builds;
    const updated = try allocator.alloc(NamedBuildConfig, old.len + 1);
    @memcpy(updated[0..old.len], old);
    updated[old.len] = .{ .name = try allocator.dupe(u8, name) };
    allocator.free(old);
    manifest.named_builds = updated;
    return &manifest.named_builds[old.len];
}

fn assignRootKey(diagnostic_context: *diagnostics.Context, allocator: std.mem.Allocator, manifest_path: []const u8, manifest: *Manifest, key: []const u8, value: []const u8, line_no: usize) !void {
    if (std.mem.eql(u8, key, "name")) {
        try replaceOptionalString(allocator, &manifest.name, try parseStringValue(diagnostic_context, allocator, manifest_path, value, line_no));
        return;
    }
    if (std.mem.eql(u8, key, "src")) {
        try replaceOptionalString(allocator, &manifest.src, try parseStringValue(diagnostic_context, allocator, manifest_path, value, line_no));
        return;
    }
    if (std.mem.eql(u8, key, "type")) {
        const kind = try parseStringValue(diagnostic_context, allocator, manifest_path, value, line_no);
        defer allocator.free(kind);
        manifest.output_kind = try parseOutputKind(diagnostic_context, manifest_path, kind, line_no);
        return;
    }
    if (std.mem.eql(u8, key, "entry")) {
        try replaceOptionalString(allocator, &manifest.entry, try parseStringValue(diagnostic_context, allocator, manifest_path, value, line_no));
        return;
    }
    if (std.mem.eql(u8, key, "version")) {
        try replaceOptionalString(allocator, &manifest.version, try parseStringValue(diagnostic_context, allocator, manifest_path, value, line_no));
        return;
    }
    if (isUnsupportedRootKey(key)) {
        try printManifestError(diagnostic_context, manifest_path, line_no, "unsupported manifest key: build hooks, scripts, tasks, workspaces, and plugins are out of scope");
        return error.InvalidManifest;
    }
    try printManifestError(diagnostic_context, manifest_path, line_no, "unknown root manifest key");
    return error.InvalidManifest;
}

fn assignDependencyKey(diagnostic_context: *diagnostics.Context, allocator: std.mem.Allocator, manifest_path: []const u8, key: []const u8, value: []const u8, line_no: usize) !void {
    _ = key;
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        const dep_path = try parseStringValue(diagnostic_context, allocator, manifest_path, value, line_no);
        allocator.free(dep_path);
        return;
    }
    if (value.len < 2 or value[0] != '{' or value[value.len - 1] != '}') {
        try printManifestError(diagnostic_context, manifest_path, line_no, "dependency entries must be a quoted path or an inline table");
        return error.InvalidManifest;
    }

    const inner = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    if (inner.len == 0) {
        try printManifestError(diagnostic_context, manifest_path, line_no, "dependency inline table must declare `path`, `version`, `registry`, or `url`");
        return error.InvalidManifest;
    }

    var saw_path = false;
    var saw_version = false;
    var saw_registry = false;
    var saw_url = false;
    var parts = std.mem.splitScalar(u8, inner, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const eq_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
            try printManifestError(diagnostic_context, manifest_path, line_no, "dependency inline table entries must use key = value");
            return error.InvalidManifest;
        };
        const dep_key = std.mem.trim(u8, trimmed[0..eq_index], " \t");
        const dep_value = std.mem.trim(u8, trimmed[eq_index + 1 ..], " \t");
        if (std.mem.eql(u8, dep_key, "path")) {
            const dep_path = try parseStringValue(diagnostic_context, allocator, manifest_path, dep_value, line_no);
            allocator.free(dep_path);
            saw_path = true;
        } else if (std.mem.eql(u8, dep_key, "version")) {
            const dep_version = try parseStringValue(diagnostic_context, allocator, manifest_path, dep_value, line_no);
            allocator.free(dep_version);
            saw_version = true;
        } else if (std.mem.eql(u8, dep_key, "registry")) {
            const dep_registry = try parseStringValue(diagnostic_context, allocator, manifest_path, dep_value, line_no);
            allocator.free(dep_registry);
            saw_registry = true;
        } else if (std.mem.eql(u8, dep_key, "url")) {
            const dep_url = try parseStringValue(diagnostic_context, allocator, manifest_path, dep_value, line_no);
            allocator.free(dep_url);
            saw_url = true;
        } else {
            try printManifestError(diagnostic_context, manifest_path, line_no, "dependency inline table supports only `path`, `version`, `registry`, and `url`");
            return error.InvalidManifest;
        }
    }

    if (!saw_path and !saw_version and !saw_registry and !saw_url) {
        try printManifestError(diagnostic_context, manifest_path, line_no, "dependency inline table must declare `path`, `version`, `registry`, or `url`");
        return error.InvalidManifest;
    }
}

fn assignTestKey(diagnostic_context: *diagnostics.Context, allocator: std.mem.Allocator, manifest_path: []const u8, manifest: *Manifest, key: []const u8, value: []const u8, line_no: usize) !void {
    if (std.mem.eql(u8, key, "dir")) {
        const dir = try parseStringValue(diagnostic_context, allocator, manifest_path, value, line_no);
        if (manifest.test_options) |*test_options| {
            allocator.free(test_options.dir);
            test_options.dir = dir;
            test_options.explicit = true;
        } else {
            manifest.test_options = .{ .dir = dir, .explicit = true };
        }
        return;
    }
    try printManifestError(diagnostic_context, manifest_path, line_no, "unknown [test] key");
    return error.InvalidManifest;
}

fn assignBuildKey(diagnostic_context: *diagnostics.Context, allocator: std.mem.Allocator, manifest_path: []const u8, manifest: *Manifest, build: *BuildSection, key: []const u8, value: []const u8, line_no: usize) !void {
    if (std.mem.eql(u8, key, "kind")) {
        const kind = try parseStringValue(diagnostic_context, allocator, manifest_path, value, line_no);
        defer allocator.free(kind);
        build.kind = try parseOutputKind(diagnostic_context, manifest_path, kind, line_no);
        return;
    }
    if (std.mem.eql(u8, key, "entry")) {
        try replaceOptionalString(allocator, &build.entry, try parseStringValue(diagnostic_context, allocator, manifest_path, value, line_no));
        return;
    }
    if (std.mem.eql(u8, key, "default")) {
        if (build != &manifest.build) {
            try printManifestError(diagnostic_context, manifest_path, line_no, "build.default is only supported in [build]");
            return error.InvalidManifest;
        }
        try replaceOptionalString(allocator, &manifest.default_build, try parseStringValue(diagnostic_context, allocator, manifest_path, value, line_no));
        return;
    }
    if (std.mem.eql(u8, key, "target")) {
        try replaceOptionalString(allocator, &build.target, try parseStringValue(diagnostic_context, allocator, manifest_path, value, line_no));
        return;
    }
    if (std.mem.eql(u8, key, "cpu")) {
        try replaceOptionalString(allocator, &build.cpu, try parseStringValue(diagnostic_context, allocator, manifest_path, value, line_no));
        return;
    }
    if (std.mem.eql(u8, key, "opt")) {
        const opt = try parseStringValue(diagnostic_context, allocator, manifest_path, value, line_no);
        defer allocator.free(opt);
        if (std.mem.eql(u8, opt, "debug")) build.opt = .debug else if (std.mem.eql(u8, opt, "release")) build.opt = .release else {
            try printManifestError(diagnostic_context, manifest_path, line_no, "build.opt must be \"debug\" or \"release\"");
            return error.InvalidManifest;
        }
        return;
    }
    if (std.mem.eql(u8, key, "emit")) {
        const emits = try parseStringArray(diagnostic_context, allocator, manifest_path, value, line_no);
        defer freeStringSlice(allocator, emits);
        build.emit = .{};
        for (emits) |item| {
            if (std.mem.eql(u8, item, "tok")) build.emit.tok = true else if (std.mem.eql(u8, item, "ast")) build.emit.ast = true else if (std.mem.eql(u8, item, "sir")) build.emit.sir = true else if (std.mem.eql(u8, item, "lir")) build.emit.lir = true else if (std.mem.eql(u8, item, "ll") or std.mem.eql(u8, item, "llvm")) build.emit.llvm = true else if (std.mem.eql(u8, item, "c-header")) build.emit.c_header = true else if (std.mem.eql(u8, item, "asm-include")) build.emit.asm_include = true else if (std.mem.eql(u8, item, "obj")) build.emit.obj = true else if (std.mem.eql(u8, item, "elf")) build.emit.elf = true else if (std.mem.eql(u8, item, "bin")) build.emit.bin = true else if (std.mem.eql(u8, item, "hex")) build.emit.hex = true else {
                try printManifestError(diagnostic_context, manifest_path, line_no, "build.emit values must be \"tok\", \"ast\", \"sir\", \"lir\", \"ll\", \"c-header\", \"asm-include\", \"obj\", \"elf\", \"bin\", or \"hex\"");
                return error.InvalidManifest;
            }
        }
        return;
    }
    if (std.mem.eql(u8, key, "leak_check")) {
        build.leak_check = try parseBoolValue(diagnostic_context, manifest_path, value, line_no);
        return;
    }
    if (std.mem.eql(u8, key, "features")) {
        freeStringSlice(allocator, build.features);
        build.features = try parseStringArray(diagnostic_context, allocator, manifest_path, value, line_no);
        return;
    }
    if (std.mem.eql(u8, key, "pic") or std.mem.eql(u8, key, "strip")) {
        try printManifestError(diagnostic_context, manifest_path, line_no, "reserved future [build] key: not part of the stable manifest surface yet");
        return error.InvalidManifest;
    }
    if (std.mem.eql(u8, key, "code_model") or std.mem.eql(u8, key, "relocation_model") or std.mem.eql(u8, key, "tls_model")) {
        try printManifestError(diagnostic_context, manifest_path, line_no, "unsupported [build] key: toolchain internals do not belong in the normal manifest surface");
        return error.InvalidManifest;
    }
    try printManifestError(diagnostic_context, manifest_path, line_no, "unknown [build] key");
    return error.InvalidManifest;
}

fn assignLinkKey(diagnostic_context: *diagnostics.Context, allocator: std.mem.Allocator, manifest_path: []const u8, link: *LinkOptions, key: []const u8, value: []const u8, line_no: usize) !void {
    if (std.mem.eql(u8, key, "libs")) {
        freeStringSlice(allocator, link.libs);
        link.libs = try parseStringArray(diagnostic_context, allocator, manifest_path, value, line_no);
        return;
    }
    if (std.mem.eql(u8, key, "search_paths")) {
        freeStringSlice(allocator, link.search_paths);
        link.search_paths = try parseStringArray(diagnostic_context, allocator, manifest_path, value, line_no);
        return;
    }
    if (std.mem.eql(u8, key, "script")) {
        try replaceOptionalString(allocator, &link.script, try parseStringValue(diagnostic_context, allocator, manifest_path, value, line_no));
        return;
    }
    if (std.mem.eql(u8, key, "entry_symbol")) {
        try replaceOptionalString(allocator, &link.entry_symbol, try parseStringValue(diagnostic_context, allocator, manifest_path, value, line_no));
        return;
    }
    if (std.mem.eql(u8, key, "frameworks")) {
        try printManifestError(diagnostic_context, manifest_path, line_no, "reserved future [link] key: not part of the stable manifest surface yet");
        return error.InvalidManifest;
    }
    try printManifestError(diagnostic_context, manifest_path, line_no, "unknown [link] key");
    return error.InvalidManifest;
}

fn assignNativeKey(diagnostic_context: *diagnostics.Context, allocator: std.mem.Allocator, manifest_path: []const u8, native: *NativeSourceOptions, key: []const u8, value: []const u8, line_no: usize) !void {
    if (std.mem.eql(u8, key, "sources")) {
        freeStringSlice(allocator, native.sources);
        native.sources = try parseStringArray(diagnostic_context, allocator, manifest_path, value, line_no);
        return;
    }
    if (std.mem.eql(u8, key, "include_paths")) {
        freeStringSlice(allocator, native.include_paths);
        native.include_paths = try parseStringArray(diagnostic_context, allocator, manifest_path, value, line_no);
        return;
    }
    if (std.mem.eql(u8, key, "flags")) {
        freeStringSlice(allocator, native.flags);
        native.flags = try parseStringArray(diagnostic_context, allocator, manifest_path, value, line_no);
        return;
    }
    try printManifestError(diagnostic_context, manifest_path, line_no, "unknown native source key");
    return error.InvalidManifest;
}

fn parseStringValue(diagnostic_context: *diagnostics.Context, allocator: std.mem.Allocator, manifest_path: []const u8, value: []const u8, line_no: usize) ![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') {
        try printManifestError(diagnostic_context, manifest_path, line_no, "expected a quoted string");
        return error.InvalidManifest;
    }
    return allocator.dupe(u8, value[1 .. value.len - 1]);
}

fn parseManifestQuotedString(value: []const u8) ?[]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return null;
    return value[1 .. value.len - 1];
}

fn parseOutputKind(diagnostic_context: *diagnostics.Context, manifest_path: []const u8, value: []const u8, line_no: usize) !OutputKind {
    if (std.mem.eql(u8, value, "exe")) return .exe;
    if (std.mem.eql(u8, value, "staticlib")) return .staticlib;
    if (std.mem.eql(u8, value, "sharedlib")) return .sharedlib;
    try printManifestError(diagnostic_context, manifest_path, line_no, "build kind must be \"exe\", \"staticlib\", or \"sharedlib\"");
    return error.InvalidManifest;
}

fn parseBoolValue(diagnostic_context: *diagnostics.Context, manifest_path: []const u8, value: []const u8, line_no: usize) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    try printManifestError(diagnostic_context, manifest_path, line_no, "expected true or false");
    return error.InvalidManifest;
}

fn parseStringArray(diagnostic_context: *diagnostics.Context, allocator: std.mem.Allocator, manifest_path: []const u8, value: []const u8, line_no: usize) ![][]const u8 {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') {
        try printManifestError(diagnostic_context, manifest_path, line_no, "expected an array");
        return error.InvalidManifest;
    }

    const inner = value[1 .. value.len - 1];
    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }

    var i: usize = 0;
    while (i < inner.len) {
        while (i < inner.len and isWhitespace(inner[i])) : (i += 1) {}
        if (i >= inner.len) break;
        if (inner[i] != '"') {
            try printManifestError(diagnostic_context, manifest_path, line_no, "array items must be quoted strings");
            return error.InvalidManifest;
        }
        i += 1;
        const start = i;
        while (i < inner.len and inner[i] != '"') : (i += 1) {}
        if (i >= inner.len) {
            try printManifestError(diagnostic_context, manifest_path, line_no, "unterminated string in array");
            return error.InvalidManifest;
        }
        try items.append(allocator, try allocator.dupe(u8, inner[start..i]));
        i += 1;
        while (i < inner.len and isWhitespace(inner[i])) : (i += 1) {}
        if (i >= inner.len) break;
        if (inner[i] != ',') {
            try printManifestError(diagnostic_context, manifest_path, line_no, "expected a comma between array items");
            return error.InvalidManifest;
        }
        i += 1;
    }

    return items.toOwnedSlice(allocator);
}

fn replaceOptionalString(allocator: std.mem.Allocator, target: *?[]const u8, value: []const u8) !void {
    if (target.*) |existing| allocator.free(existing);
    target.* = try allocator.dupe(u8, value);
    allocator.free(value);
}

fn absolutizeLinkOptions(allocator: std.mem.Allocator, root_dir: []const u8, link: *LinkOptions) !void {
    link.search_paths = try absolutizePathSlice(allocator, root_dir, link.search_paths);
    if (link.script) |script| {
        const abs = try resolvePathAgainstRoot(allocator, root_dir, script);
        allocator.free(script);
        link.script = abs;
    }
}

fn absolutizeNativeSourceOptions(allocator: std.mem.Allocator, root_dir: []const u8, native: *NativeSourceOptions) !void {
    native.sources = try absolutizePathSlice(allocator, root_dir, native.sources);
    native.include_paths = try absolutizePathSlice(allocator, root_dir, native.include_paths);
}

fn absolutizePathSlice(allocator: std.mem.Allocator, root_dir: []const u8, values: [][]const u8) ![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }
    for (values) |value| {
        try out.append(allocator, try resolvePathAgainstRoot(allocator, root_dir, value));
    }
    freeStringSlice(allocator, values);
    return out.toOwnedSlice(allocator);
}

fn resolvePathAgainstRoot(allocator: std.mem.Allocator, root_dir: []const u8, value: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(value)) return allocator.dupe(u8, value);
    return std.fs.path.join(allocator, &.{ root_dir, value });
}

fn pathExists(path: []const u8) bool {
    compat.access(path, .{}) catch return false;
    return true;
}

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn isDirectoryPath(path: []const u8) !bool {
    const dir = compat.openDir(path, .{}) catch |err| switch (err) {
        error.NotDir, error.FileNotFound => return false,
        error.PermissionDenied, error.AccessDenied => {
            const file = compat.openFile(path, .{}) catch |file_err| switch (file_err) {
                error.FileNotFound => return false,
                else => return err,
            };
            compat.closeFile(file);
            return false;
        },
        else => return err,
    };
    compat.closeDir(dir);
    return true;
}

fn sharedLibrarySuffix() []const u8 {
    return switch (@import("builtin").os.tag) {
        .macos => ".dylib",
        .windows => ".dll",
        else => ".so",
    };
}

fn isUnsupportedRootKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "pre_build") or
        std.mem.eql(u8, key, "post_build") or
        std.mem.eql(u8, key, "scripts") or
        std.mem.eql(u8, key, "tasks") or
        std.mem.eql(u8, key, "workspace") or
        std.mem.eql(u8, key, "workspaces") or
        std.mem.eql(u8, key, "plugins") or
        std.mem.eql(u8, key, "generators");
}

fn printManifestError(diagnostic_context: *diagnostics.Context, manifest_path: []const u8, line_no: usize, message: []const u8) !void {
    var buffer: [256]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buffer, "line {d}: {s}", .{ line_no, message }) catch message;
    try diagnostic_context.emitPath(manifest_path, rendered);
}

fn freeStringSlice(allocator: std.mem.Allocator, values: [][]const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn dupStringSliceConst(allocator: std.mem.Allocator, values: []const []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, values.len);
    var len: usize = 0;
    errdefer {
        for (out[0..len]) |item| allocator.free(item);
        allocator.free(out);
    }
    for (values, 0..) |value, index| {
        out[index] = try allocator.dupe(u8, value);
        len += 1;
    }
    return out;
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r';
}

test "resolve project directory falls back to src/main.cy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const file = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file, "fn main(): i32 { return 0; }\n");
    }

    const root_dir = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root_dir);

    var target = try resolveBuildTarget(std.testing.allocator, root_dir);
    defer target.deinit(std.testing.allocator);

    try std.testing.expect(target.is_project);
    try std.testing.expectEqualStrings("main.cy", std.fs.path.basename(target.source_path));
    try std.testing.expectEqual(OutputKind.exe, target.output_kind);
    const test_dir = try target.testDirPath(std.testing.allocator);
    defer std.testing.allocator.free(test_dir);
    const expected_test_dir = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "src");
    defer std.testing.allocator.free(expected_test_dir);
    try std.testing.expectEqualStrings(expected_test_dir, test_dir);
}

test "resolve manifest file parses native settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirMakePath(tmp.dir, "native");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/lib.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "export c(\"value\") fn value(): i32 { return 42; }\n");
    }
    {
        const native = try compat.dirCreateFile(tmp.dir, "native/shim.c", .{});
        defer compat.closeFile(native);
        try compat.fileWriteAll(native, "int shim(void) { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "mathlib"
            \\type = "staticlib"
            \\entry = "src/lib.cy"
            \\
            \\[build]
            \\opt = "release"
            \\emit = ["c-header", "llvm", "obj"]
            \\leak_check = true
            \\
            \\[test]
            \\dir = "pkgtest"
            \\
            \\[link]
            \\libs = ["m"]
            \\search_paths = ["native/lib"]
            \\
            \\[c]
            \\sources = ["native/shim.c"]
            \\include_paths = ["native/include"]
            \\flags = ["-DSHIM=1"]
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    var target = try resolveBuildTarget(std.testing.allocator, manifest_path);
    defer target.deinit(std.testing.allocator);

    try std.testing.expect(target.is_project);
    try std.testing.expectEqualStrings("mathlib", target.name);
    try std.testing.expect(target.target == null);
    try std.testing.expect(target.cpu == null);
    try std.testing.expectEqual(OutputKind.staticlib, target.output_kind);
    try std.testing.expectEqual(OptMode.release, target.opt);
    try std.testing.expect(target.emit.c_header);
    try std.testing.expect(target.emit.llvm);
    try std.testing.expect(target.emit.obj);
    try std.testing.expect(target.leak_check);
    try std.testing.expectEqual(@as(usize, 1), target.c_sources.sources.len);
    try std.testing.expect(std.fs.path.isAbsolute(target.c_sources.sources[0]));
    try std.testing.expectEqual(@as(usize, 1), target.link.libs.len);
    try std.testing.expect(target.test_options != null);
    try std.testing.expectEqualStrings("pkgtest", target.test_options.?.dir);
    try std.testing.expect(target.test_options.?.explicit);
}

test "manifest accepts build-local kind and entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/lib.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "export c(\"value\") fn value(): i32 { return 42; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "math"
            \\src = "src"
            \\
            \\[build]
            \\kind = "staticlib"
            \\entry = "src/lib.cy"
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    var target = try resolveBuildTarget(std.testing.allocator, manifest_path);
    defer target.deinit(std.testing.allocator);

    try std.testing.expectEqual(OutputKind.staticlib, target.output_kind);
    try std.testing.expect(std.mem.endsWith(u8, target.source_path, "/src/lib.cy") or std.mem.endsWith(u8, target.source_path, "\\src\\lib.cy"));
}

test "manifest named build config selects matching link and asm overlays" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src/arch/aarch64");
    try compat.dirMakePath(tmp.dir, "src/arch/riscv64");
    try compat.dirMakePath(tmp.dir, "src/platform/aarch64");
    try compat.dirMakePath(tmp.dir, "src/platform/riscv64");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.aarch64.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.riscv64.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const script = try compat.dirCreateFile(tmp.dir, "src/platform/aarch64/link.ld", .{});
        defer compat.closeFile(script);
        try compat.fileWriteAll(script, "SECTIONS { .text : { *(.text*) } }\n");
    }
    {
        const script = try compat.dirCreateFile(tmp.dir, "src/platform/riscv64/link.ld", .{});
        defer compat.closeFile(script);
        try compat.fileWriteAll(script, "SECTIONS { .text : { *(.text*) } }\n");
    }
    {
        const asm_source = try compat.dirCreateFile(tmp.dir, "src/arch/aarch64/start.S", .{});
        defer compat.closeFile(asm_source);
        try compat.fileWriteAll(asm_source, ".text\n");
    }
    {
        const asm_source = try compat.dirCreateFile(tmp.dir, "src/arch/riscv64/start.S", .{});
        defer compat.closeFile(asm_source);
        try compat.fileWriteAll(asm_source, ".text\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "kernel"
            \\src = "src"
            \\
            \\[build]
            \\default = "aarch64"
            \\kind = "exe"
            \\emit = ["elf", "bin"]
            \\
            \\[build.aarch64]
            \\entry = "src/main.aarch64.cy"
            \\target = "aarch64-none-elf"
            \\
            \\[link.aarch64]
            \\script = "src/platform/aarch64/link.ld"
            \\entry_symbol = "_start"
            \\
            \\[asm.aarch64]
            \\sources = ["src/arch/aarch64/start.S"]
            \\
            \\[build.riscv64]
            \\entry = "src/main.riscv64.cy"
            \\target = "riscv64-none-elf"
            \\
            \\[link.riscv64]
            \\script = "src/platform/riscv64/link.ld"
            \\entry_symbol = "_start"
            \\
            \\[asm.riscv64]
            \\sources = ["src/arch/riscv64/start.S"]
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    var default_target = try resolveBuildTarget(std.testing.allocator, manifest_path);
    defer default_target.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("kernel-aarch64", default_target.name);
    try std.testing.expectEqualStrings("aarch64-none-elf", default_target.target.?);
    try std.testing.expect(default_target.emit.elf);
    try std.testing.expect(default_target.emit.bin);
    try std.testing.expect(default_target.link.script != null);
    try std.testing.expect(std.mem.endsWith(u8, default_target.asm_sources.sources[0], "/src/arch/aarch64/start.S") or std.mem.endsWith(u8, default_target.asm_sources.sources[0], "\\src\\arch\\aarch64\\start.S"));

    var riscv_target = try resolveBuildTargetForConfig(std.testing.allocator, manifest_path, "riscv64");
    defer riscv_target.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("kernel-riscv64", riscv_target.name);
    try std.testing.expectEqualStrings("riscv64-none-elf", riscv_target.target.?);
    try std.testing.expect(std.mem.endsWith(u8, riscv_target.source_path, "/src/main.riscv64.cy") or std.mem.endsWith(u8, riscv_target.source_path, "\\src\\main.riscv64.cy"));
    try std.testing.expect(std.mem.endsWith(u8, riscv_target.asm_sources.sources[0], "/src/arch/riscv64/start.S") or std.mem.endsWith(u8, riscv_target.asm_sources.sources[0], "\\src\\arch\\riscv64\\start.S"));
}

test "source file resolves sibling non-default manifest by build entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/init.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "init.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "user-init"
            \\
            \\[build]
            \\kind = "exe"
            \\entry = "src/init.cy"
            \\target = "aarch64-none-elf"
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "src/init.cy");
    defer std.testing.allocator.free(source_path);

    var target = try resolveBuildTarget(std.testing.allocator, source_path);
    defer target.deinit(std.testing.allocator);

    try std.testing.expect(target.is_project);
    try std.testing.expectEqualStrings("user-init", target.name);
    try std.testing.expectEqualStrings("aarch64-none-elf", target.target.?);
    try std.testing.expect(std.mem.endsWith(u8, target.manifest_path.?, "/init.toml") or std.mem.endsWith(u8, target.manifest_path.?, "\\init.toml"));
}

test "source file resolves named manifest config by matching entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.aarch64.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.riscv64.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "kernel"
            \\
            \\[build]
            \\default = "aarch64"
            \\kind = "exe"
            \\
            \\[build.aarch64]
            \\entry = "src/main.aarch64.cy"
            \\target = "aarch64-none-elf"
            \\
            \\[build.riscv64]
            \\entry = "src/main.riscv64.cy"
            \\target = "riscv64-none-elf"
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "src/main.riscv64.cy");
    defer std.testing.allocator.free(source_path);

    var target = try resolveBuildTarget(std.testing.allocator, source_path);
    defer target.deinit(std.testing.allocator);

    try std.testing.expect(target.is_project);
    try std.testing.expectEqualStrings("kernel-riscv64", target.name);
    try std.testing.expectEqualStrings("riscv64-none-elf", target.target.?);
    try std.testing.expectEqualStrings(source_path, target.source_path);
}

test "manifest build target and cpu are preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "firmware"
            \\entry = "src/main.cy"
            \\
            \\[build]
            \\target = "thumbv7em-none-eabi"
            \\cpu = "cortex-m4"
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    var target = try resolveBuildTarget(std.testing.allocator, manifest_path);
    defer target.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("thumbv7em-none-eabi", target.target.?);
    try std.testing.expectEqualStrings("cortex-m4", target.cpu.?);
}

test "freestanding bin emit requires linker script and entry symbol" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "firmware"
            \\entry = "src/main.cy"
            \\
            \\[build]
            \\target = "thumbv7em-none-eabi"
            \\emit = ["bin"]
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    try std.testing.expectError(error.UnsupportedTarget, resolveBuildTarget(std.testing.allocator, manifest_path));
}

test "freestanding bin emit accepts explicit linker script and entry symbol" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirMakePath(tmp.dir, "board");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const script = try compat.dirCreateFile(tmp.dir, "board/link.ld", .{});
        defer compat.closeFile(script);
        try compat.fileWriteAll(script, "SECTIONS { .text : { *(.text*) } }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "firmware"
            \\entry = "src/main.cy"
            \\
            \\[build]
            \\target = "thumbv7em-none-eabi"
            \\emit = ["bin"]
            \\
            \\[link]
            \\script = "board/link.ld"
            \\entry_symbol = "_start"
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    var target = try resolveBuildTarget(std.testing.allocator, manifest_path);
    defer target.deinit(std.testing.allocator);

    try std.testing.expect(target.link.script != null);
    try std.testing.expect(target.link.entry_symbol != null);
    try std.testing.expect(std.fs.path.isAbsolute(target.link.script.?));
    try std.testing.expectEqualStrings("_start", target.link.entry_symbol.?);
}

test "linker script and entry symbol are rejected for static libraries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirMakePath(tmp.dir, "board");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/lib.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "export c(\"value\") fn value(): i32 { return 0; }\n");
    }
    {
        const script = try compat.dirCreateFile(tmp.dir, "board/link.ld", .{});
        defer compat.closeFile(script);
        try compat.fileWriteAll(script, "SECTIONS { .text : { *(.text*) } }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "fwlib"
            \\type = "staticlib"
            \\entry = "src/lib.cy"
            \\
            \\[link]
            \\script = "board/link.ld"
            \\entry_symbol = "_start"
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    try std.testing.expectError(error.UnsupportedTarget, resolveBuildTarget(std.testing.allocator, manifest_path));
}

test "explicit manifest entry source path resolves through manifest target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirMakePath(tmp.dir, "native");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/lib.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "export c(\"value\") fn value(): i32 { return 42; }\n");
    }
    {
        const native = try compat.dirCreateFile(tmp.dir, "native/shim.c", .{});
        defer compat.closeFile(native);
        try compat.fileWriteAll(native, "int shim(void) { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "firmware"
            \\type = "staticlib"
            \\entry = "src/lib.cy"
            \\
            \\[build]
            \\target = "aarch64-none-elf"
            \\
            \\[c]
            \\sources = ["native/shim.c"]
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "src/lib.cy");
    defer std.testing.allocator.free(source_path);

    var target = try resolveBuildTarget(std.testing.allocator, source_path);
    defer target.deinit(std.testing.allocator);

    try std.testing.expect(target.is_project);
    try std.testing.expectEqual(OutputKind.staticlib, target.output_kind);
    try std.testing.expectEqualStrings("firmware", target.name);
    try std.testing.expectEqualStrings("aarch64-none-elf", target.target.?);
    try std.testing.expectEqual(@as(usize, 1), target.c_sources.sources.len);
    try std.testing.expect(std.fs.path.isAbsolute(target.c_sources.sources[0]));
}

test "non-entry source path still resolves as a standalone file target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const source = try compat.dirCreateFile(tmp.dir, "src/tool.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "app"
            \\entry = "src/main.cy"
            \\
            \\[build]
            \\target = "thumbv7em-none-eabi"
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "src/tool.cy");
    defer std.testing.allocator.free(source_path);

    var target = try resolveBuildTarget(std.testing.allocator, source_path);
    defer target.deinit(std.testing.allocator);

    try std.testing.expect(!target.is_project);
    try std.testing.expect(target.target == null);
    try std.testing.expectEqualStrings("tool", target.name);
    try std.testing.expectEqualStrings(source_path, target.source_path);
}

test "supported targets normalize for toolchain use" {
    const thumb = (try normalizedToolchainTarget(std.testing.allocator, "thumbv7em-none-eabi")).?;
    defer std.testing.allocator.free(thumb);
    try std.testing.expectEqualStrings("thumbv7em-none-eabi", thumb);

    const aarch64 = (try normalizedToolchainTarget(std.testing.allocator, "aarch64-none-elf")).?;
    defer std.testing.allocator.free(aarch64);
    try std.testing.expectEqualStrings("aarch64-none-elf", aarch64);

    const native = try normalizedToolchainTarget(std.testing.allocator, "native");
    defer if (native) |value| std.testing.allocator.free(value);
    if (supportedHost() == .aarch64_apple_darwin) {
        try std.testing.expect(native == null);
    } else {
        try std.testing.expectEqualStrings(toolchainHostTag(supportedHost()), native.?);
    }
}

test "supported targets map to internal llvm tool bundles" {
    const native_bundle = try supportedLlvmToolBundle("native");
    try std.testing.expectEqualStrings("llvm", native_bundle.id);
    try std.testing.expectEqualStrings("22.1.2", native_bundle.version);

    const thumb_bundle = try supportedLlvmToolBundle("thumbv7em-none-eabi");
    try std.testing.expectEqualStrings("llvm", thumb_bundle.id);
    try std.testing.expectEqualStrings("22.1.2", thumb_bundle.version);
}

test "compiler can pin approved artifact manifests by bundle and host" {
    const bundle = try supportedLlvmToolBundle("native");
    try std.testing.expect(hasApprovedToolchainArtifact(bundle, .aarch64_apple_darwin));
    const approval = approvedToolchainArtifactForId(bundle, "llvm", .aarch64_apple_darwin).?;
    try std.testing.expectEqualStrings("llvm", approval.bundle_id);
    try std.testing.expectEqualStrings("llvm", approval.artifact_id);
    try std.testing.expectEqualStrings(
        "ef3b8e8aa743fa18eec1774cd7f57a538215e270fa42e86ad553a516e0b39c62",
        approval.manifest_sha256,
    );
    const legacy_approval = approvedToolchainArtifactForId(bundle, "llvm-host", .aarch64_apple_darwin).?;
    try std.testing.expectEqualStrings("llvm-host", legacy_approval.artifact_id);
}

test "legacy published artifact ids still belong to canonical llvm bundle" {
    const bundle = try supportedLlvmToolBundle("native");
    try std.testing.expect(toolchainArtifactBelongsToBundle(bundle, "llvm"));
    try std.testing.expect(toolchainArtifactBelongsToBundle(bundle, "llvm-host"));
    try std.testing.expect(!toolchainArtifactBelongsToBundle(bundle, "llvm-baremetal"));
}

test "supported targets expose separate target support identity" {
    const native_support = try supportedTargetSupport("native");
    try std.testing.expectEqualStrings(toolchainHostTag(supportedHost()), native_support.id);
    try std.testing.expectEqual(@as(u32, 1), native_support.revision);

    const thumb_support = try supportedTargetSupport("thumbv7em-none-eabi");
    try std.testing.expectEqualStrings("thumbv7em-none-eabi", thumb_support.id);
    try std.testing.expectEqual(@as(u32, 1), thumb_support.revision);
}

test "hosted darwin triple keeps its target support without a toolchain triple" {
    const darwin = try supportedTarget("aarch64-apple-darwin");
    try std.testing.expectEqualStrings("native", darwin.?.name);
    try std.testing.expectEqualStrings("aarch64-apple-darwin", darwin.?.target_support.id);
    try std.testing.expect(!darwin.?.freestanding);
    try std.testing.expectEqual(@as(?[]const u8, null), try normalizedToolchainTarget(std.testing.allocator, "aarch64-apple-darwin"));
    try std.testing.expect(!isFreestandingTarget("aarch64-apple-darwin"));
}

test "target support approvals are explicit and pinned when published" {
    const darwin_support = TargetSupportSpec{ .id = "aarch64-apple-darwin", .revision = 1 };
    try std.testing.expect(hasApprovedTargetSupportArtifact(darwin_support));
    const native_approval = approvedTargetSupportArtifact(darwin_support).?;
    try std.testing.expectEqualStrings("aarch64-apple-darwin", native_approval.target_id);
    try std.testing.expectEqual(@as(u32, 1), native_approval.revision);
    try std.testing.expectEqualStrings("9fd67d0f7c11a9ad50b3db4eca2e475b8d113c570a9b26efba65c707b0b19042", native_approval.manifest_sha256);
}

test "official distribution root uses install prefix directly" {
    const path = try officialDistributionRootAtPrefix(std.testing.allocator, "/tmp/cyna");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/cyna", path);
}

test "unsupported target triple is rejected" {
    try std.testing.expectError(error.UnsupportedTarget, normalizedToolchainTarget(std.testing.allocator, "x86_64-linux-gnu"));
}

test "native target rejects elf bin and hex emits" {
    try std.testing.expectError(
        error.UnsupportedTarget,
        validateEmitOptionsForTarget("/tmp/app.cy", "native", .{ .elf = true }),
    );
    try std.testing.expectError(
        error.UnsupportedTarget,
        validateEmitOptionsForTarget("/tmp/app.cy", "native", .{ .bin = true }),
    );
    try std.testing.expectError(
        error.UnsupportedTarget,
        validateEmitOptionsForTarget("/tmp/app.cy", "native", .{ .hex = true }),
    );
}

test "manifest build emit accepts tok ast ll c-header asm-include elf bin and hex names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "emitapp"
            \\entry = "src/main.cy"
            \\
            \\[build]
            \\emit = ["tok", "ast", "sir", "lir", "ll", "c-header", "asm-include", "obj", "elf", "bin", "hex"]
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    var target = try resolveBuildTarget(std.testing.allocator, manifest_path);
    defer target.deinit(std.testing.allocator);

    try std.testing.expect(target.emit.tok);
    try std.testing.expect(target.emit.ast);
    try std.testing.expect(target.emit.sir);
    try std.testing.expect(target.emit.lir);
    try std.testing.expect(target.emit.llvm);
    try std.testing.expect(target.emit.c_header);
    try std.testing.expect(target.emit.asm_include);
    try std.testing.expect(target.emit.obj);
    try std.testing.expect(target.emit.elf);
    try std.testing.expect(target.emit.bin);
    try std.testing.expect(target.emit.hex);
}

test "manifest src key changes the default entry root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "pkg");

    {
        const source = try compat.dirCreateFile(tmp.dir, "pkg/main.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "app"
            \\src = "pkg"
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    var target = try resolveBuildTarget(std.testing.allocator, manifest_path);
    defer target.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.endsWith(u8, target.source_path, "/pkg/main.cy") or std.mem.endsWith(u8, target.source_path, "\\pkg\\main.cy"));
}

test "manifest dependencies section is accepted by build parser" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "app"
            \\entry = "src/main.cy"
            \\
            \\[dependencies]
            \\std = "../std"
            \\util = "../util"
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    var target = try resolveBuildTarget(std.testing.allocator, manifest_path);
    defer target.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("app", target.name);
}

test "manifest dependency inline table is accepted by build parser" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "app"
            \\entry = "src/main.cy"
            \\
            \\[dependencies]
            \\util = { path = "../util", version = "0.2.0" }
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    var target = try resolveBuildTarget(std.testing.allocator, manifest_path);
    defer target.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("app", target.name);
}

test "manifest version-only dependency inline table is accepted by build parser" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "app"
            \\entry = "src/main.cy"
            \\
            \\[dependencies]
            \\util = { version = "0.2.0" }
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    var target = try resolveBuildTarget(std.testing.allocator, manifest_path);
    defer target.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("app", target.name);
}

test "manifest registry dependency inline table is accepted by build parser" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "app"
            \\entry = "src/main.cy"
            \\
            \\[dependencies]
            \\util = { registry = "central", version = "0.2.0" }
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    var target = try resolveBuildTarget(std.testing.allocator, manifest_path);
    defer target.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("app", target.name);
}

test "build target resolves configured test directory path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "app"
            \\entry = "src/main.cy"
            \\
            \\[test]
            \\dir = "qa"
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    var target = try resolveBuildTarget(std.testing.allocator, manifest_path);
    defer target.deinit(std.testing.allocator);

    const test_dir = try target.testDirPath(std.testing.allocator);
    defer std.testing.allocator.free(test_dir);
    try std.testing.expect(std.mem.endsWith(u8, test_dir, "/qa") or std.mem.endsWith(u8, test_dir, "\\qa"));
}

test "discover test files scans test roots under the source tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirMakePath(tmp.dir, "src/nested");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const test_a = try compat.dirCreateFile(tmp.dir, "src/a.test.cy", .{});
        defer compat.closeFile(test_a);
        try compat.fileWriteAll(test_a, "fn helper(): i32 { return 1; }\n");
    }
    {
        const test_b = try compat.dirCreateFile(tmp.dir, "src/nested/b.test.cy", .{});
        defer compat.closeFile(test_b);
        try compat.fileWriteAll(test_b, "fn helper(): i32 { return 2; }\n");
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    var target = try resolveBuildTarget(std.testing.allocator, root);
    defer target.deinit(std.testing.allocator);

    var discovered = try discoverTestFiles(std.testing.allocator, target);
    defer discovered.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), discovered.files.len);
    try std.testing.expect(std.mem.endsWith(u8, discovered.files[0], "a.test.cy"));
    try std.testing.expect(std.mem.endsWith(u8, discovered.files[1], "b.test.cy"));
}

test "discover test files allows a source tree without test roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    var target = try resolveBuildTarget(std.testing.allocator, root);
    defer target.deinit(std.testing.allocator);

    var discovered = try discoverTestFiles(std.testing.allocator, target);
    defer discovered.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), discovered.files.len);
}

test "discover test files rejects missing explicit test directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "app"
            \\entry = "src/main.cy"
            \\
            \\[test]
            \\dir = "qa"
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);
    var target = try resolveBuildTarget(std.testing.allocator, manifest_path);
    defer target.deinit(std.testing.allocator);

    var captured: std.ArrayListUnmanaged(u8) = .empty;
    defer captured.deinit(std.testing.allocator);
    var diagnostic_context = diagnostics.Context.capturing(std.testing.allocator, &captured);

    try std.testing.expectError(error.TestDirNotFound, discoverTestFilesWithDiagnostics(std.testing.allocator, target, &diagnostic_context));
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "configured test directory does not exist") != null);
}

test "reserved future manifest keys report intentional diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "future"
            \\entry = "src/main.cy"
            \\
            \\[build]
            \\pic = true
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    var captured: std.ArrayListUnmanaged(u8) = .empty;
    defer captured.deinit(std.testing.allocator);
    var diagnostic_context = diagnostics.Context.capturing(std.testing.allocator, &captured);

    try std.testing.expectError(error.InvalidManifest, resolveBuildTargetForConfigWithDiagnostics(std.testing.allocator, manifest_path, null, &diagnostic_context));
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "reserved future [build] key") != null);
}

test "unsupported manifest categories report policy diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const source = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source, "fn main(): i32 { return 0; }\n");
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "unsupported"
            \\entry = "src/main.cy"
            \\scripts = ["echo hi"]
            \\
        );
    }

    const manifest_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cyna.toml");
    defer std.testing.allocator.free(manifest_path);

    var captured: std.ArrayListUnmanaged(u8) = .empty;
    defer captured.deinit(std.testing.allocator);
    var diagnostic_context = diagnostics.Context.capturing(std.testing.allocator, &captured);

    try std.testing.expectError(error.InvalidManifest, resolveBuildTargetForConfigWithDiagnostics(std.testing.allocator, manifest_path, null, &diagnostic_context));
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "unsupported manifest key") != null);
}

test "hosted GNU targets and native hosts select a consistent ABI" {
    for ([_]ToolchainHost{ .x86_64_unknown_linux_gnu, .x86_64_pc_windows_gnu }) |host| {
        const triple = toolchainHostTag(host);
        const explicit = (try supportedTarget(triple)).?;
        try std.testing.expectEqualStrings(triple, explicit.toolchain_target.?);
        try std.testing.expectEqualStrings(triple, explicit.target_support.id);
        try std.testing.expect(!explicit.freestanding);
        for ([_]?[]const u8{ null, "native" }) |name| {
            const native = (try supportedTargetForHost(name, host)).?;
            try std.testing.expectEqualStrings(triple, native.toolchain_target.?);
            try std.testing.expectEqualStrings(triple, native.target_support.id);
        }
    }
    try std.testing.expectError(error.UnsupportedTarget, supportedTarget("x86_64-pc-windows-msvc"));
}

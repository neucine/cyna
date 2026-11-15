const std = @import("std");
const build_options = @import("build_options");
const compat = @import("../compat.zig");
const loader = @import("../compiler/loader.zig");
const llvm_backend = @import("../compiler/backend/llvm.zig");
const build_model = @import("model.zig");
const modules = @import("modules.zig");

const llvm_entry = @import("llvm_cache_entry.zig");

pub const Entry = llvm_entry.Entry;

pub fn load(
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    loaded: loader.LoadedProgram,
) !?Entry {
    const paths = try cachePaths(allocator, target, loaded);
    defer allocator.free(paths.data);

    return llvm_entry.load(allocator, paths.data);
}

pub fn store(
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    loaded: loader.LoadedProgram,
    llvm_ir: []const u8,
    artifact_deps: llvm_backend.ArtifactDeps,
) !void {
    const paths = try cachePaths(allocator, target, loaded);
    defer allocator.free(paths.data);

    try llvm_entry.store(allocator, paths.data, llvm_ir, artifact_deps);
}

const CachePaths = struct { data: []u8 };

fn cachePaths(
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    loaded: loader.LoadedProgram,
) !CachePaths {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // Reject artifacts emitted before the nullable C-pointer ABI correction.
    hasher.update("cyna-llvm-input-v3\x00");
    hasher.update(build_options.cyna_version);
    hasher.update(target.compiler_identity);
    hashString(&hasher, target.target orelse "native");
    hashString(&hasher, target.cpu orelse "");
    hashString(&hasher, @tagName(target.opt));
    hashString(&hasher, @tagName(target.output_kind));
    hashString(&hasher, if (target.leak_check) "leak-check" else "no-leak-check");
    hashStringSlice(&hasher, target.c_sources.sources);
    hashStringSlice(&hasher, target.c_sources.include_paths);
    hashStringSlice(&hasher, target.c_sources.flags);
    hashStringSlice(&hasher, target.asm_sources.sources);
    hashStringSlice(&hasher, target.asm_sources.include_paths);
    hashStringSlice(&hasher, target.asm_sources.flags);
    hashStringSlice(&hasher, target.link.libs);
    hashStringSlice(&hasher, target.link.search_paths);
    hashOptionalString(&hasher, target.link.script);
    hashOptionalString(&hasher, target.link.entry_symbol);
    var module_plan = try modules.Plan.init(allocator, loaded);
    defer module_plan.deinit();
    module_plan.updateHash(&hasher);
    for (target.c_sources.sources) |path| try hashFile(&hasher, allocator, path);
    for (target.asm_sources.sources) |path| try hashFile(&hasher, allocator, path);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const dir = try std.fs.path.join(allocator, &.{ target.root_dir, ".cyna-cache", "llvm-modules" });
    defer allocator.free(dir);
    try compat.makePath(dir);
    return .{
        .data = try std.fmt.allocPrint(allocator, "{s}/{s}.entry", .{ dir, hex }),
    };
}

fn hashFile(hasher: *std.crypto.hash.sha2.Sha256, allocator: std.mem.Allocator, path: []const u8) !void {
    const contents = try compat.readFileAlloc(allocator, path, 128 * 1024 * 1024);
    defer allocator.free(contents);
    hashString(hasher, path);
    hasher.update(contents);
}

fn hashString(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hasher.update(value);
    hasher.update("\x00");
}

fn hashOptionalString(hasher: *std.crypto.hash.sha2.Sha256, value: ?[]const u8) void {
    hashString(hasher, value orelse "");
}

fn hashStringSlice(hasher: *std.crypto.hash.sha2.Sha256, values: []const []const u8) void {
    for (values) |value| hashString(hasher, value);
    hasher.update("\x01");
}

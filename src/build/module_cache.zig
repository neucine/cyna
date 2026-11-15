const std = @import("std");
const build_options = @import("build_options");
const compat = @import("../compat.zig");
const llvm_backend = @import("../compiler/backend/llvm.zig");
const build_model = @import("model.zig");
const modules = @import("modules.zig");

const llvm_entry = @import("llvm_cache_entry.zig");

pub const Entry = llvm_entry.Entry;

pub fn load(allocator: std.mem.Allocator, target: build_model.BuildTarget, plan: modules.Plan, module_index: usize) !?Entry {
    const paths = try cachePaths(allocator, target, plan, module_index);
    defer freePaths(allocator, paths);

    return llvm_entry.load(allocator, paths.data);
}

pub fn store(
    allocator: std.mem.Allocator,
    target: build_model.BuildTarget,
    plan: modules.Plan,
    module_index: usize,
    llvm_ir: []const u8,
    artifact_deps: llvm_backend.ArtifactDeps,
) !void {
    const paths = try cachePaths(allocator, target, plan, module_index);
    defer freePaths(allocator, paths);
    try llvm_entry.store(allocator, paths.data, llvm_ir, artifact_deps);
}

const CachePaths = struct { data: []u8 };

fn cachePaths(allocator: std.mem.Allocator, target: build_model.BuildTarget, plan: modules.Plan, module_index: usize) !CachePaths {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // Reject artifacts emitted before the nullable C-pointer ABI correction.
    hasher.update("cyna-module-input-v4\x00");
    hasher.update(build_options.cyna_version);
    hasher.update(target.compiler_identity);
    hashString(&hasher, target.target orelse "native");
    hashString(&hasher, target.cpu orelse "");
    hashString(&hasher, @tagName(target.opt));
    hashString(&hasher, plan.modules[module_index].name);
    try plan.updateModuleHash(allocator, &hasher, module_index);
    if (plan.modules[module_index].has_generic_declarations) plan.updateHash(&hasher);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const dir = try std.fs.path.join(allocator, &.{ target.root_dir, ".cyna-cache", "modules" });
    defer allocator.free(dir);
    try compat.makePath(dir);
    return .{
        .data = try std.fmt.allocPrint(allocator, "{s}/{s}.entry", .{ dir, hex }),
    };
}

fn freePaths(allocator: std.mem.Allocator, paths: CachePaths) void {
    allocator.free(paths.data);
}

fn hashString(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hasher.update(value);
    hasher.update("\x00");
}

test "generic module cache tracks importer changes without invalidating unrelated modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const target = build_model.BuildTarget{ .is_project = true, .display_path = root, .root_dir = root, .source_path = "main.cy", .name = "generic-cache" };
    var entries = [_]modules.Module{
        .{ .name = "main", .source_path = "main.cy", .source = "fn main(): i32 { return identity<i32>(42); }", .imports = &.{}, .autoload = false },
        .{ .name = "generic", .source_path = "generic.cy", .source = "pub fn identity<T>(value: T): T { return value; }", .imports = &.{}, .autoload = false, .has_generic_declarations = true },
        .{ .name = "unrelated", .source_path = "unrelated.cy", .source = "pub fn value(): i32 { return 1; }", .imports = &.{}, .autoload = false },
    };
    const plan = modules.Plan{ .allocator = std.testing.allocator, .modules = &entries };
    const generic_before = try cachePaths(std.testing.allocator, target, plan, 1);
    defer freePaths(std.testing.allocator, generic_before);
    const unrelated_before = try cachePaths(std.testing.allocator, target, plan, 2);
    defer freePaths(std.testing.allocator, unrelated_before);
    entries[0].source = "fn main(): i32 { return identity<i64>(42) as i32; }";
    const generic_after = try cachePaths(std.testing.allocator, target, plan, 1);
    defer freePaths(std.testing.allocator, generic_after);
    const unrelated_after = try cachePaths(std.testing.allocator, target, plan, 2);
    defer freePaths(std.testing.allocator, unrelated_after);
    try std.testing.expect(!std.mem.eql(u8, generic_before.data, generic_after.data));
    try std.testing.expectEqualStrings(unrelated_before.data, unrelated_after.data);
}

const std = @import("std");
const backend = @import("../compiler/backend/llvm.zig");
const bundle = @import("cache_bundle.zig");

const magic = "cyna-llvm-artifact-v2\n";

pub const Entry = struct {
    llvm_ir: []u8,
    artifact_deps: backend.ArtifactDeps,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.llvm_ir);
        self.* = undefined;
    }
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !?Entry {
    const entry = (try bundle.load(allocator, path)) orelse return null;
    defer entry.deinit(allocator);
    if (!std.mem.startsWith(u8, entry.metadata, magic) or entry.artifacts.len != 1) return null;
    const llvm = entry.artifact("llvm") orelse return null;
    var lines = std.mem.tokenizeScalar(u8, entry.metadata[magic.len..], '\n');
    const runtime = lines.next() orelse return null;
    const std_dep = lines.next() orelse return null;
    if (lines.next() != null) return null;
    const runtime_required = if (std.mem.eql(u8, runtime, "runtime=1")) true else if (std.mem.eql(u8, runtime, "runtime=0")) false else return null;
    const std_required = if (std.mem.eql(u8, std_dep, "std=1")) true else if (std.mem.eql(u8, std_dep, "std=0")) false else return null;
    return .{ .llvm_ir = try allocator.dupe(u8, llvm.contents), .artifact_deps = .{ .runtime = runtime_required, .std = std_required } };
}

pub fn store(allocator: std.mem.Allocator, path: []const u8, llvm_ir: []const u8, deps: backend.ArtifactDeps) !void {
    var buffer: [128]u8 = undefined;
    const metadata = try std.fmt.bufPrint(&buffer, "{s}runtime={d}\nstd={d}\n", .{ magic, @intFromBool(deps.runtime), @intFromBool(deps.std) });
    try bundle.publish(allocator, path, metadata, &.{.{ .name = "llvm", .contents = llvm_ir }});
}

test "LLVM cache entries preserve the IR and dependency flags as one publication" {
    const allocator = std.testing.allocator;
    const compat = @import("../compat.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "module.entry" });
    defer allocator.free(path);
    try store(allocator, path, "first", .{ .runtime = true });
    var first = (try load(allocator, path)).?;
    defer first.deinit(allocator);
    try store(allocator, path, "second", .{ .std = true });
    var second = (try load(allocator, path)).?;
    defer second.deinit(allocator);
    try std.testing.expectEqualStrings("first", first.llvm_ir);
    try std.testing.expect(first.artifact_deps.runtime and !first.artifact_deps.std);
    try std.testing.expectEqualStrings("second", second.llvm_ir);
    try std.testing.expect(second.artifact_deps.std and !second.artifact_deps.runtime);
}

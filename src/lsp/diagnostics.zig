const std = @import("std");
const analysis = @import("analysis.zig");

pub const Diagnostic = analysis.Diagnostic;

pub fn collect(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    matches_disk: bool,
) ![]Diagnostic {
    var snapshot = try analysis.build(allocator, path, text, matches_disk);
    defer snapshot.deinit(allocator);
    const diagnostics = snapshot.diagnostics;
    snapshot.diagnostics = &.{};
    return diagnostics;
}

pub fn deinit(allocator: std.mem.Allocator, diagnostics: []Diagnostic) void {
    for (diagnostics) |diagnostic| diagnostic.deinit(allocator);
    allocator.free(diagnostics);
}

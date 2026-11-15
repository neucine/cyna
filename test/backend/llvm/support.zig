const std = @import("std");

pub const test_exec = @import("../../support.zig");
pub const ExtraCSource = test_exec.ExtraCSource;

pub fn lowerLlvmText(allocator: std.mem.Allocator, path: []const u8, source: []const u8) ![]u8 {
    return test_exec.emitLlvmSource(allocator, path, source);
}

pub fn lowerLlvmTextWithTarget(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    target: []const u8,
) ![]u8 {
    return test_exec.emitLlvmSourceWithTarget(allocator, path, source, target);
}

pub fn lowerLlvmFileText(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return test_exec.emitLlvmFile(allocator, path);
}

pub fn runNativeSourceExitCode(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !i64 {
    return test_exec.runNativeSourceExitCode(allocator, path, source);
}

pub fn runNativeSourceExitCodeWithCSources(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    extra_c_sources: []const ExtraCSource,
) !i64 {
    return test_exec.runNativeSourceExitCodeWithCSources(allocator, path, source, extra_c_sources);
}

pub fn runNativeFileExitCode(allocator: std.mem.Allocator, path: []const u8) !i64 {
    return test_exec.runNativeFileExitCode(allocator, path);
}

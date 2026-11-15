const std = @import("std");

const test_exec = @import("../support.zig");

pub const Target = struct {
    name: []const u8,
    triple: []const u8,
};

pub const freestanding_64 = [_]Target{
    .{ .name = "aarch64", .triple = "aarch64-none-elf" },
    .{ .name = "x86_64", .triple = "x86_64-none-elf" },
    .{ .name = "riscv64", .triple = "riscv64-none-elf" },
};

pub const pointer_width = [_]Target{
    .{ .name = "riscv32", .triple = "riscv32-none-elf" },
    .{ .name = "riscv64", .triple = "riscv64-none-elf" },
};

pub const aarch64 = [_]Target{
    .{ .name = "aarch64", .triple = "aarch64-none-elf" },
};

pub const LlvmCheck = struct {
    target: Target,
    contains: []const []const u8 = &.{},
    excludes: []const []const u8 = &.{},
};

pub fn emitLlvm(
    allocator: std.mem.Allocator,
    source_name: []const u8,
    source: []const u8,
    target: Target,
) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}_{s}.cy", .{ source_name, target.name });
    defer allocator.free(path);
    return test_exec.emitLlvmSourceWithTarget(allocator, path, source, target.triple);
}

pub fn expectLlvmContains(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("missing LLVM fragment:\n{s}\n", .{needle});
        return error.TestExpectedEqual;
    }
}

pub fn expectLlvmExcludes(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) != null) {
        std.debug.print("unexpected LLVM fragment:\n{s}\n", .{needle});
        return error.TestExpectedEqual;
    }
}

pub fn expectLlvmChecks(source_name: []const u8, source: []const u8, checks: []const LlvmCheck) !void {
    for (checks) |check| {
        const text = try emitLlvm(std.testing.allocator, source_name, source, check.target);
        defer std.testing.allocator.free(text);

        for (check.contains) |needle| {
            try expectLlvmContains(text, needle);
        }
        for (check.excludes) |needle| {
            try expectLlvmExcludes(text, needle);
        }
    }
}

test "parity target groups name supported freestanding targets" {
    try std.testing.expectEqualStrings("aarch64-none-elf", freestanding_64[0].triple);
    try std.testing.expectEqualStrings("x86_64-none-elf", freestanding_64[1].triple);
    try std.testing.expectEqualStrings("riscv64-none-elf", freestanding_64[2].triple);
    try std.testing.expectEqualStrings("riscv32-none-elf", pointer_width[0].triple);
}

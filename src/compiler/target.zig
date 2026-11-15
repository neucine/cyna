const std = @import("std");
const builtin = @import("builtin");

pub const AbiLayout = struct {
    ptr_bits: u16,
    char_bits: u16 = 8,
    char_signed: bool = true,
    short_bits: u16 = 16,
    int_bits: u16 = 32,
    long_bits: u16,
    longlong_bits: u16 = 64,
    long_align: usize,
    longlong_align: usize,
    double_align: usize,
    is_aarch64: bool = false,
    is_aarch64_darwin: bool = false,
    is_x86_64_sysv: bool = false,
    is_x86_64_windows: bool = false,

    pub fn ptrSize(self: AbiLayout) usize {
        return @as(usize, self.ptr_bits) / 8;
    }
};

pub fn abiLayout(target: ?[]const u8) AbiLayout {
    const name = target orelse return hostAbiLayout();
    if (std.mem.eql(u8, name, "aarch64-apple-darwin")) {
        return .{
            .ptr_bits = 64,
            .long_bits = 64,
            .long_align = 8,
            .longlong_align = 8,
            .double_align = 8,
            .is_aarch64 = true,
            .is_aarch64_darwin = true,
        };
    }
    if (std.mem.eql(u8, name, "aarch64-none-elf")) {
        return .{
            .ptr_bits = 64,
            .long_bits = 64,
            .long_align = 8,
            .longlong_align = 8,
            .double_align = 8,
            .is_aarch64 = true,
        };
    }
    if (std.mem.eql(u8, name, "x86_64-unknown-linux-gnu")) {
        return .{
            .ptr_bits = 64,
            .long_bits = 64,
            .long_align = 8,
            .longlong_align = 8,
            .double_align = 8,
            .is_x86_64_sysv = true,
        };
    }
    if (std.mem.eql(u8, name, "x86_64-pc-windows-gnu") or
        std.mem.eql(u8, name, "x86_64-windows-gnu") or
        std.mem.eql(u8, name, "x86_64-pc-windows-msvc") or
        std.mem.eql(u8, name, "x86_64-windows-msvc"))
    {
        return .{
            .ptr_bits = 64,
            .long_bits = 32,
            .long_align = 4,
            .longlong_align = 8,
            .double_align = 8,
            .is_x86_64_windows = true,
        };
    }
    if (std.mem.eql(u8, name, "x86_64-none-elf") or
        std.mem.eql(u8, name, "riscv64-none-elf"))
    {
        return .{
            .ptr_bits = 64,
            .long_bits = 64,
            .long_align = 8,
            .longlong_align = 8,
            .double_align = 8,
        };
    }
    if (std.mem.eql(u8, name, "riscv32-none-elf") or
        std.mem.eql(u8, name, "arm-none-eabi") or
        std.mem.eql(u8, name, "thumbv7em-none-eabi"))
    {
        return .{
            .ptr_bits = 32,
            .long_bits = 32,
            .long_align = 4,
            .longlong_align = 8,
            .double_align = 8,
            .char_signed = !(std.mem.eql(u8, name, "arm-none-eabi") or std.mem.eql(u8, name, "thumbv7em-none-eabi")),
        };
    }
    if (std.mem.eql(u8, name, "wasm32-wasi")) {
        return .{
            .ptr_bits = 32,
            .long_bits = 32,
            .long_align = 4,
            .longlong_align = 8,
            .double_align = 8,
        };
    }
    return hostAbiLayout();
}

fn hostAbiLayout() AbiLayout {
    return .{
        .ptr_bits = @intCast(@min(builtin.target.ptrBitWidth(), std.math.maxInt(u16))),
        .char_bits = @intCast(std.Target.cTypeBitSize(&builtin.target, .char).?),
        .char_signed = std.Target.cCharSignedness(&builtin.target) == .signed,
        .short_bits = @intCast(std.Target.cTypeBitSize(&builtin.target, .short).?),
        .int_bits = @intCast(std.Target.cTypeBitSize(&builtin.target, .int).?),
        .long_bits = @intCast(std.Target.cTypeBitSize(&builtin.target, .long).?),
        .longlong_bits = @intCast(std.Target.cTypeBitSize(&builtin.target, .longlong).?),
        .long_align = @alignOf(c_long),
        .longlong_align = @alignOf(c_longlong),
        .double_align = 8,
        .is_aarch64 = builtin.target.cpu.arch == .aarch64,
        .is_aarch64_darwin = builtin.target.cpu.arch == .aarch64 and builtin.target.os.tag.isDarwin(),
        .is_x86_64_sysv = builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag == .linux,
        .is_x86_64_windows = builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag == .windows,
    };
}

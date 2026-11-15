const std = @import("std");
const lir = @import("lir.zig");
const target_info = @import("../target.zig");
const errors = @import("errors.zig");

pub const IntCastBounds = struct {
    min: i64,
    max: i64,
    min_float: f64,
    upper_exclusive_float: f64,
};

pub const FloatFiniteBounds = struct {
    min_float: f64,
    max_float: f64,
};

pub fn namedIntInfo(type_name: []const u8, target: ?[]const u8) ?lir.IntType {
    const layout = target_info.abiLayout(target);
    if (std.mem.eql(u8, type_name, "isize")) return .{ .bits = layout.ptr_bits, .signed = true };
    if (std.mem.eql(u8, type_name, "usize") or std.mem.eql(u8, type_name, "c_size_t")) return .{ .bits = layout.ptr_bits, .signed = false };
    if (std.mem.eql(u8, type_name, "c_ptrdiff_t")) return .{ .bits = layout.ptr_bits, .signed = true };
    if (std.mem.eql(u8, type_name, "c_char")) return .{ .bits = layout.char_bits, .signed = layout.char_signed };
    if (std.mem.eql(u8, type_name, "c_schar")) return .{ .bits = 8, .signed = true };
    if (std.mem.eql(u8, type_name, "c_uchar")) return .{ .bits = 8, .signed = false };
    if (std.mem.eql(u8, type_name, "c_short")) return .{ .bits = layout.short_bits, .signed = true };
    if (std.mem.eql(u8, type_name, "c_ushort")) return .{ .bits = layout.short_bits, .signed = false };
    if (std.mem.eql(u8, type_name, "c_int")) return .{ .bits = layout.int_bits, .signed = true };
    if (std.mem.eql(u8, type_name, "c_uint")) return .{ .bits = layout.int_bits, .signed = false };
    if (std.mem.eql(u8, type_name, "c_long")) return .{ .bits = layout.long_bits, .signed = true };
    if (std.mem.eql(u8, type_name, "c_ulong")) return .{ .bits = layout.long_bits, .signed = false };
    if (std.mem.eql(u8, type_name, "c_llong")) return .{ .bits = layout.longlong_bits, .signed = true };
    if (std.mem.eql(u8, type_name, "c_ullong")) return .{ .bits = layout.longlong_bits, .signed = false };
    if (type_name.len < 2) return null;
    const signed = type_name[0] == 'i';
    const unsigned = type_name[0] == 'u';
    if (!signed and !unsigned) return null;
    const bits = std.fmt.parseInt(u16, type_name[1..], 10) catch return null;
    if (bits == 0 or bits > 64) return null;
    return .{ .bits = bits, .signed = signed };
}

pub fn isAbiIntTypeName(type_name: []const u8) bool {
    return std.mem.startsWith(u8, type_name, "c_");
}

pub fn intCastBounds(type_name: []const u8, target: ?[]const u8) errors.Error!IntCastBounds {
    const info = namedIntInfo(type_name, target) orelse return error.LowerInvariantViolation;
    return intCastBoundsForInfo(info);
}

pub fn intCastBoundsForInfo(info: lir.IntType) IntCastBounds {
    if (!info.signed) {
        const bits = info.bits;
        const max = if (bits == 64) std.math.maxInt(i64) else (@as(i64, 1) << @as(u6, @intCast(bits))) - 1;
        return .{
            .min = 0,
            .max = max,
            .min_float = 0.0,
            .upper_exclusive_float = if (bits == 64) 18446744073709551616.0 else @as(f64, @floatFromInt(@as(u64, 1) << @as(u6, @intCast(bits)))),
        };
    }
    const bits = info.bits;
    const min = if (bits == 64) std.math.minInt(i64) else -(@as(i64, 1) << @as(u6, @intCast(bits - 1)));
    const max = if (bits == 64) std.math.maxInt(i64) else (@as(i64, 1) << @as(u6, @intCast(bits - 1))) - 1;
    return .{
        .min = min,
        .max = max,
        .min_float = @as(f64, @floatFromInt(min)),
        .upper_exclusive_float = if (bits == 64) 9223372036854775808.0 else @as(f64, @floatFromInt(@as(u64, 1) << @as(u6, @intCast(bits - 1)))),
    };
}

pub fn intTypeAlwaysFits(src: lir.IntType, dst: lir.IntType) bool {
    if (src.signed == dst.signed) return dst.bits >= src.bits;
    if (!src.signed and dst.signed) return dst.bits > src.bits;
    return false;
}

pub fn floatFiniteBounds(bits: u16) errors.Error!FloatFiniteBounds {
    return switch (bits) {
        32 => .{ .min_float = -std.math.floatMax(f32), .max_float = std.math.floatMax(f32) },
        64 => .{ .min_float = -std.math.floatMax(f64), .max_float = std.math.floatMax(f64) },
        else => error.LowerInvariantViolation,
    };
}

const std = @import("std");
const common = @import("common.zig");
const lir = @import("../../lower/lir.zig");
const runtime_symbols = @import("../../../runtime/symbols.zig");

pub const Error = common.Error;

pub const string_eq_symbol = runtime_symbols.string_eq_symbol;
pub const type_desc_llvm_type = runtime_symbols.type_desc_llvm_type;
pub const desc_i64_symbol = runtime_symbols.desc_i64_symbol;
pub const desc_bool_symbol = runtime_symbols.desc_bool_symbol;
pub const desc_string_symbol = runtime_symbols.desc_string_symbol;

pub const StringLiteral = struct {
    name: []const u8,
    value: []const u8,
};

pub fn collectStringLiterals(allocator: std.mem.Allocator, module: lir.Module) Error![]StringLiteral {
    var out: std.ArrayListUnmanaged(StringLiteral) = .empty;
    errdefer {
        for (out.items) |lit| allocator.free(lit.name);
        out.deinit(allocator);
    }

    var next_index: usize = 0;
    for (module.globals) |global| {
        if (global.init) |init| try collectGlobalInitStrings(allocator, &out, &next_index, init);
    }
    for (module.functions) |function| {
        if (function.debug_source_path) |path| {
            var has_trace_site = false;
            for (function.blocks) |block| {
                for (block.instructions) |inst| {
                    if (inst.data != .make_result) continue;
                    switch (inst.data.make_result.trace) {
                        .create => has_trace_site = true,
                        .transfer => |transfer| if (transfer.append_site != null) {
                            has_trace_site = true;
                        },
                        .none => {},
                    }
                }
            }
            if (has_trace_site and findStringLiteralName(out.items, path) == null) {
                const name = try std.fmt.allocPrint(allocator, ".str.{}", .{next_index});
                next_index += 1;
                try out.append(allocator, .{ .name = name, .value = path });
            }
        }
        for (function.blocks) |block| {
            for (block.instructions) |inst| {
                switch (inst.data) {
                    .const_string, .const_c_str => |value| {
                        if (findStringLiteralName(out.items, value) != null) continue;
                        const name = try std.fmt.allocPrint(allocator, ".str.{}", .{next_index});
                        next_index += 1;
                        try out.append(allocator, .{ .name = name, .value = value });
                    },
                    else => {},
                }
            }
        }
    }

    return out.toOwnedSlice(allocator);
}

fn collectGlobalInitStrings(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(StringLiteral),
    next_index: *usize,
    init: lir.GlobalInit,
) Error!void {
    switch (init) {
        .string => |value| {
            if (findStringLiteralName(out.items, value) != null) return;
            const name = try std.fmt.allocPrint(allocator, ".str.{}", .{next_index.*});
            errdefer allocator.free(name);
            next_index.* += 1;
            try out.append(allocator, .{ .name = name, .value = value });
        },
        .some => |value| try collectGlobalInitStrings(allocator, out, next_index, value.*),
        .@"union" => |value| if (value.payload) |payload| try collectGlobalInitStrings(allocator, out, next_index, payload.*),
        .array => |items| for (items) |item| try collectGlobalInitStrings(allocator, out, next_index, item),
        .@"struct" => |fields| for (fields) |field| try collectGlobalInitStrings(allocator, out, next_index, field),
        else => {},
    }
}

pub fn findStringLiteralName(literals: []const StringLiteral, value: []const u8) ?[]const u8 {
    for (literals) |lit| {
        if (std.mem.eql(u8, lit.value, value)) return lit.name;
    }
    return null;
}

pub fn escapeBytes(allocator: std.mem.Allocator, value: []const u8) Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |byte| {
        if (byte >= 0x20 and byte <= 0x7e and byte != '\\' and byte != '"') {
            try out.append(allocator, byte);
        } else {
            try out.append(allocator, '\\');
            try out.append(allocator, hexDigit(byte >> 4));
            try out.append(allocator, hexDigit(byte & 0x0f));
        }
    }
    return out.toOwnedSlice(allocator);
}

fn hexDigit(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'A' + (nibble - 10);
}

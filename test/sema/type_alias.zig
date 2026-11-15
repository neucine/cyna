const std = @import("std");
const helpers = @import("../helpers.zig");

test "type aliases cannot shadow built-in types" {
    for ([_][]const u8{ "char", "bool", "u16", "c_int", "string" }) |name| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "type {s} = u16;\n", .{name});
        defer std.testing.allocator.free(source);
        const expected = try std.fmt.allocPrint(std.testing.allocator, "type alias `{s}` conflicts with a built-in type", .{name});
        defer std.testing.allocator.free(expected);
        try helpers.expectSemanticFailedMessage(std.testing.allocator, "builtin_type_alias.cy", source, expected);
    }
}

test "generic type aliases lower through explicit type arguments" {
    const source =
        \\struct Box<T> {
        \\    value: T;
        \\}
        \\
        \\type BoxAlias<T> = Box<T>;
        \\type U32Box = BoxAlias<u32>;
        \\
        \\const item: U32Box = { value: 42 };
        \\
        \\fn main(): i32 {
        \\    return item.value as i32;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "generic_type_alias_explicit_args", source);
}

test "embedded mmio width aliases are usable in declarative globals" {
    const source =
        \\import embedded.hal.mmio;
        \\
        \\packed struct Status {
        \\    raw: u32;
        \\}
        \\
        \\const status: mmio.Reg32<Status> = { addr: 0x1000 };
        \\const status_ro: mmio.Reg32RO<Status> = { addr: 0x1004 };
        \\const status_wo: mmio.Reg32WO<Status> = { addr: 0x1008 };
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticSuccessWithOptions(std.testing.allocator, "embedded_mmio_width_aliases", source, .{ .target = "riscv32-none-elf" });
}

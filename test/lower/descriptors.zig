const std = @import("std");
const compiler = @import("cyna").compiler;
const lir = compiler.lir;
const descriptors = compiler.backend_support;

test "nominal descriptor names distinguish equal layouts and compose stable module identities" {
    const fields = &[_]lir.StructField{.{ .name = "value", .ty = 0 }};
    const types = [_]lir.TypeDecl{
        .string,
        .{ .@"struct" = .{ .name = "Visit", .qualified_name = "a.Visit", .is_c_layout = false, .is_packed = false, .packed_bits = 0, .fields = fields } },
        .{ .@"struct" = .{ .name = "Visit", .qualified_name = "b.Visit", .is_c_layout = false, .is_packed = false, .packed_bits = 0, .fields = fields } },
        .{ .@"struct" = .{ .name = "Visit", .qualified_name = "a.Visit", .is_c_layout = false, .is_packed = false, .packed_bits = 0, .fields = fields } },
        .{ .@"union" = .{ .name = "Token", .qualified_name = "a.Token", .payloads = &.{0} } },
        .{ .@"union" = .{ .name = "Token", .qualified_name = "b.Token", .payloads = &.{0} } },
        .{ .optional = 1 },
        .{ .optional = 2 },
        .{ .dense_array = 6 },
        .{ .dense_array = 7 },
        .{ .dense_array = 4 },
        .{ .dense_array = 5 },
        .{ .@"struct" = .{ .name = "a.Visit", .is_c_layout = false, .is_packed = false, .packed_bits = 0, .fields = fields } },
    };
    const module = lir.Module{ .types = &types, .globals = &.{}, .functions = &.{} };
    const allocator = std.testing.allocator;
    inline for (.{ descriptors.descriptorGlobalName, descriptors.descriptorCopyName, descriptors.descriptorDropName }) |nameFor| {
        for ([_][2]lir.TypeId{ .{ 1, 2 }, .{ 4, 5 }, .{ 6, 7 }, .{ 8, 9 }, .{ 10, 11 }, .{ 1, 12 } }) |pair| {
            const left = try nameFor(allocator, module, pair[0]);
            defer allocator.free(left);
            const right = try nameFor(allocator, module, pair[1]);
            defer allocator.free(right);
            try std.testing.expect(!std.mem.eql(u8, left, right));
        }
        const first = try nameFor(allocator, module, 1);
        defer allocator.free(first);
        const repeated = try nameFor(allocator, module, 3);
        defer allocator.free(repeated);
        try std.testing.expectEqualStrings(first, repeated);
    }
}

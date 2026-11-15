const std = @import("std");
const compiler = @import("cyna").compiler;
const sir = compiler.sir;

test "definition-site body check records a gap when a protocol use cannot be checked" {
    const allocator = std.testing.allocator;
    var interner = compiler.semantic_types.TypeInterner.init(allocator);
    defer interner.deinit();
    const void_type = try interner.intern(.{ .primitive = .void });
    const source_id: compiler.identity.DeclId = @fromBackingInt(@intCast(1));
    const protocol_id: compiler.identity.DeclId = @fromBackingInt(@intCast(2));
    var call: sir.Expr = .{ .call = .{
        .module_name = "example",
        .owner = null,
        .callee = "method",
        .args = &.{},
        .checked_method_use = .{
            .use_id = 7,
            .source_declaration_id = source_id,
            .source_offset = 0,
        },
    } };
    const body = [_]sir.Stmt{.{ .expr = &call }};
    const function: sir.Function = .{
        .owner = null,
        .name = "example",
        .params = &.{},
        .return_type_id = void_type,
        .body = &body,
    };
    var scratch: [256]u8 = undefined;
    try std.testing.expect((try compiler.definition_body_check.firstGap(allocator, &interner, &.{}, function, &.{}, &.{}, &.{}, &scratch)) == null);

    call.call.checked_method_use.?.protocol_id = protocol_id;
    const gap = try compiler.definition_body_check.firstGap(allocator, &interner, &.{}, function, &.{}, &.{}, &.{}, &scratch);
    try std.testing.expect(gap != null);
}

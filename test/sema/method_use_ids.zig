const std = @import("std");
const compiler = @import("cyna").compiler;
const sir = compiler.sir;

test "SIR method-use collector includes protocol uses and ignores concrete calls" {
    const allocator = std.testing.allocator;
    const source_id: compiler.identity.DeclId = @fromBackingInt(@intCast(1));
    const protocol_id: compiler.identity.DeclId = @fromBackingInt(@intCast(2));
    var protocol_call: sir.Expr = .{ .call = .{
        .module_name = "example",
        .owner = null,
        .callee = "protocol_method",
        .args = &.{},
        .checked_method_use = .{
            .use_id = 7,
            .source_declaration_id = source_id,
            .source_offset = 0,
            .protocol_id = protocol_id,
        },
    } };
    var concrete_call: sir.Expr = .{ .call = .{
        .module_name = "example",
        .owner = null,
        .callee = "concrete_method",
        .args = &.{},
        .checked_method_use = .{
            .use_id = 8,
            .source_declaration_id = source_id,
            .source_offset = 1,
        },
    } };
    const body = [_]sir.Stmt{ .{ .expr = &protocol_call }, .{ .expr = &concrete_call } };
    const function: sir.Function = .{
        .owner = null,
        .name = "example",
        .params = &.{},
        .body = &body,
    };
    var ids: std.ArrayListUnmanaged(u32) = .empty;
    defer ids.deinit(allocator);
    try compiler.method_use.collect(allocator, &function, &ids);
    try std.testing.expectEqualSlices(u32, &.{7}, ids.items);
}

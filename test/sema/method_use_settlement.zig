const std = @import("std");
const compiler = @import("cyna").compiler;
const generic_origins = compiler.generic_origins;
const settlement = compiler.method_use;

fn observed(use_id: u32) generic_origins.MethodUse {
    return .{
        .expr = undefined,
        .use_id = use_id,
        .receiver = undefined,
        .callee_declaration_id = @fromBackingInt(@intCast(1)),
        .result_type_id = @fromBackingInt(@intCast(1)),
        .substitution = &.{},
    };
}

test "method-use settlement reports count identity and return mismatches" {
    const allocator = std.testing.allocator;
    const uses = [_]generic_origins.MethodUse{observed(7)};
    const report: generic_origins.BodyReport = .{
        .returned_type = null,
        .did_return = false,
        .reachable = true,
        .method_uses = 1,
    };

    try std.testing.expect((try settlement.firstIssue(allocator, &.{7}, &uses, report, null)) == null);
    const count = (try settlement.firstIssue(allocator, &.{ 7, 8 }, &uses, report, null)).?;
    try std.testing.expectEqual(@as(usize, 1), count.count_mismatch.observed);
    try std.testing.expectEqual(@as(usize, 2), count.count_mismatch.recorded);

    const missing = [_]generic_origins.MethodUse{observed(0)};
    try std.testing.expect((try settlement.firstIssue(allocator, &.{7}, &missing, report, null)).? == .missing_use_id);

    const duplicate = [_]generic_origins.MethodUse{ observed(7), observed(7) };
    const twice = (try settlement.firstIssue(allocator, &.{7}, &duplicate, report, null)).?;
    try std.testing.expectEqual(@as(u32, 7), twice.not_once.use_id);
    try std.testing.expectEqual(@as(usize, 2), twice.not_once.count);

    var returned = report;
    returned.returned_type = @fromBackingInt(@intCast(2));
    try std.testing.expect((try settlement.firstIssue(allocator, &.{7}, &uses, returned, @fromBackingInt(@intCast(3)))).? == .return_type_mismatch);
}

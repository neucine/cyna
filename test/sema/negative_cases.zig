const std = @import("std");
const helpers = @import("../helpers.zig");
const negative_allocator_ownership = @import("negative/allocator_ownership.zig");
const negative_generics_protocols = @import("negative/generics_protocols.zig");
const negative_layout_abi = @import("negative/layout_abi.zig");
const negative_surface_misc = @import("negative/surface_misc.zig");
const negative_unions_result = @import("negative/unions_result.zig");

const Negative = struct {
    name: []const u8,
    source: []const u8,
};

fn runNegativeCases(cases: anytype) !void {
    for (cases) |negative| {
        try helpers.expectSemanticFailed(std.testing.allocator, negative.name, negative.source);
    }
}

test "semantic failures are rejected" {
    try runNegativeCases(negative_allocator_ownership.negatives);
    try runNegativeCases(negative_generics_protocols.negatives);
    try runNegativeCases(negative_layout_abi.negatives);
    try runNegativeCases(negative_surface_misc.negatives);
    try runNegativeCases(negative_unions_result.negatives);
}

test "public result carrier syntax is rejected" {
    const cases = [_]struct { name: []const u8, source: []const u8, message: []const u8, parse: bool = false }{
        .{ .name = "explicit_result_type", .source = "enum Failure { bad; } fn main(): result<i32, Failure> { return .ok(1); }", .message = "explicit `result<T, E>` is unavailable", .parse = true },
        .{ .name = "explicit_result_ok", .source = "enum Failure { bad; } fn main(): i32!Failure { return .ok(1); }", .message = "result cases `.ok` are unavailable" },
        .{ .name = "explicit_result_err", .source = "enum Failure { bad; } fn main(): i32!Failure { return .err(Failure.bad); }", .message = "result cases `.err` are unavailable" },
        .{ .name = "result_switch", .source = "enum Failure { bad; } fn source(): i32!Failure { return 1; } fn main(): i32 { return switch source() { .ok(value) => value; .err(code) => 0; }; }", .message = "switch on an error return is unavailable" },
        .{ .name = "result_switch_statement", .source = "enum Failure { bad; } fn source(): i32!Failure { return 1; } fn main(): i32 { switch source() { .ok(value) => { return value; } .err(code) => { return 0; } } }", .message = "switch on an error return is unavailable" },
        .{ .name = "result_is_pattern", .source = "enum Failure { bad; } fn source(): i32!Failure { return 1; } fn main(): i32 { const value = source(); if value is .ok(payload) { return payload; } return 0; }", .message = "result case patterns are unavailable" },
        .{ .name = "legacy_catch_fallback", .source = "enum Failure { bad; } fn source(): i32!Failure { return 1; } fn main(): i32 { return source() catch 0; }", .message = "expected `catch (code)", .parse = true },
        .{ .name = "legacy_catch_arms", .source = "enum Failure { bad; } fn source(): i32!Failure { return 1; } fn main(): i32 { return source() catch { Failure.bad => 0; }; }", .message = "expected `catch (code)", .parse = true },
    };
    for (cases) |case| {
        if (case.parse) {
            try helpers.expectParseFailedMessage(std.testing.allocator, case.name, case.source, case.message);
        } else {
            try helpers.expectSemanticFailedMessage(std.testing.allocator, case.name, case.source, case.message);
        }
    }
}

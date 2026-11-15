const std = @import("std");
const helpers = @import("../helpers.zig");

test "concise switch arms can throw or return" {
    const source =
        \\enum Failure { bad; }
        \\fn choose(value: i32): i32!Failure {
        \\    const result: i32 = switch value {
        \\        0 => throw Failure.bad;
        \\        1 => return 7;
        \\        _ => 9;
        \\    };
        \\    return result;
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticSuccess(std.testing.allocator, "concise_switch_exit", source);
}

test "concise switch arms accept terminal calls" {
    const source =
        \\fn choose(value: i32): i32 {
        \\    return switch value {
        \\        0 => panic("unreachable");
        \\        1 => assert(false);
        \\        _ => 9;
        \\    };
        \\}
        \\fn main(): i32 { return choose(2); }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "concise_switch_terminal", source);
}

test "unreachable ends a concise switch arm" {
    const source =
        \\fn choose(value: i32): i32 {
        \\    return switch value {
        \\        0 => unreachable;
        \\        _ => 7;
        \\    };
        \\}
        \\fn main(): i32 { return choose(1); }
    ;
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "unreachable_switch_arm", source, 7);
}

test "reaching unreachable traps" {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const outcome = try helpers.test_exec.runNativeSourceOutcome(scratch.allocator(), "unreachable_trap.cy",
        \\fn main(): i32 { unreachable; }
    );
    try std.testing.expectEqual(helpers.test_exec.NativeRunOutcome{ .exited = 101 }, outcome);
}

test "inline test owned catch return has a checked return identity" {
    const source =
        \\enum TestError { failed; }
        \\enum Failure { bad; }
        \\fn get(): string!Failure { return "hi"; }
        \\test "owned catch" {
        \\    const value = get() catch (problem) { return; };
        \\    assert(value == "hi");
        \\}
    ;
    try helpers.expectSemanticSuccess(std.testing.allocator, "owned_catch.test.cy", source);
}

test "anonymous function owned return uses its generated declaration" {
    const source =
        \\struct Item { name: string; }
        \\fn main(): i32 {
        \\    const make: fn(): ?Item = fn (): ?Item {
        \\        return Item { name: "hi" };
        \\    };
        \\    const value = make();
        \\    if value is item {
        \\        if item.name == "hi" { return 7; }
        \\    }
        \\    return 0;
        \\}
    ;
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "anonymous_owned_return", source, 7);
}

test "bang return accepts a named type union of error enums" {
    const source =
        \\enum First { failed = 7; }
        \\enum Second { failed = 7; }
        \\union Errors = First | Second;
        \\fn fail(): i32!Errors { throw First.failed; }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticSuccess(std.testing.allocator, "named_result_error_union", source);
}

test "bang return rejects a non-enum member in an error union" {
    const source =
        \\enum First { failed; }
        \\union Errors = First | i32;
        \\fn fail(): i32!Errors { return 1; }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "invalid_result_error_union", source, "result error union member must be an enum");
}

test "inline bang error unions reject invalid and duplicate members" {
    const invalid =
        \\enum First { failed; }
        \\fn fail(): i32!First | i32 { return 1; }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "inline_error_union_non_enum", invalid, "result error union member must be an enum");

    const duplicate =
        \\enum First { failed; }
        \\fn fail(): i32!First | First { return 1; }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "inline_error_union_duplicate", duplicate, "result error union members must be distinct enums");
}

test "named and inline bang error unions remain distinct" {
    const source =
        \\enum First { failed; }
        \\enum Second { failed; }
        \\union Errors = First | Second;
        \\fn named(): i32!Errors { throw First.failed; }
        \\fn inline(): i32!First | Second { return named(); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "named_inline_result_distinct", source, "type mismatch");
}

test "try rejects an error enum missing from the destination union" {
    const statement =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\enum Third { bad; }
        \\union Errors = First | Second;
        \\fn fail(): void!Third { throw Third.bad; }
        \\fn run(): void!Errors { try fail(); return; }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "try_missing_named_member", statement, "`try` error type mismatch: expected Errors, got Third");

    const expression =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\enum Third { bad; }
        \\fn fail(): i32!Third { throw Third.bad; }
        \\fn run(): i32!First | Second { const value = try fail(); return value; }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "try_missing_inline_member", expression, "`try` error type mismatch: expected First | Second, got Third");
}

test "bang result spelling is confined to return types" {
    const source =
        \\enum Failure { bad; }
        \\fn invalid(value: i32!Failure): i32 { return value; }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectParseFailedMessage(std.testing.allocator, "bang_parameter_type", source, "expected `)` after parameters");
}

test "throw requires a result return type" {
    const source =
        \\enum Failure { bad; }
        \\fn fail(): i32 { throw Failure.bad; }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "throw_plain_return", source, "`throw` requires a result return type");
}

test "exported bang return requires an explicit error type" {
    const source =
        \\export c fn value(): c_int! { return 6; }
        \\fn main(): i32 { return value(); }
    ;
    try helpers.expectParseFailedMessage(std.testing.allocator, "export_inferred_bang_return", source, "exported and bodyless functions require an explicit error type after `!`");
}

test "recursive bang inference requires an explicit error type" {
    const source =
        \\fn recursive(): i32! { const value = try recursive(); return value; }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "recursive_bang_inference", source, "recursive `T!` error inference requires an explicit error type");

    const generic =
        \\fn recursive<T>(value: T): T! { return try recursive<T>(value); }
        \\fn main(): i32 { const value = recursive<i32>(1) catch (code) { const ignored = code; return 1; }; const ignored = value; return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "recursive_generic_bang_inference", generic, "recursive `T!` error inference requires an explicit error type");

    const mutual =
        \\fn first<T>(value: T): T! { return try second<T>(value); }
        \\fn second<T>(value: T): T! { return try first<T>(value); }
        \\fn main(): i32 { const value = first<i32>(1) catch (code) { const ignored = code; return 1; }; const ignored = value; return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "mutual_generic_bang_inference", mutual, "recursive `T!` error inference requires an explicit error type");
}

test "bang inference rejects unresolved error sources" {
    const unqualified =
        \\enum Failure { bad; }
        \\fn fail(): i32! { throw .bad; }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "inferred_unqualified_throw", unqualified, "inferred `T!` throw requires a qualified `Enum.case` error");

    const operand =
        \\enum Failure { bad; }
        \\fn fail<T>(value: T): T!Failure { throw Failure.bad; }
        \\fn pass(): i32! { const value = fail(1 + 2); return try value; }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "inferred_local_try", operand, "cannot infer `T!` error type from this `try` operand");
}

test "bang inference merges propagated union carriers" {
    const distinct =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\enum Third { bad; }
        \\union One = First | Second;
        \\union Two = First | Third;
        \\fn first(): i32!One { throw First.bad; }
        \\fn second(): i32!Two { throw Third.bad; }
        \\fn combined(): i32! { const a = try first(); const b = try second(); return a + b; }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "inferred_distinct_union_carriers", distinct);

    const outside =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\enum Third { bad; }
        \\union Errors = First | Second;
        \\fn source(): i32!Errors { throw Second.bad; }
        \\fn combined(): i32! { if false { throw Third.bad; } return try source(); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "inferred_outside_union_member", outside);
}

test "try rejects a union with a member missing from the destination" {
    const source =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\enum Third { bad; }
        \\fn source(): i32!First | Third { throw Third.bad; }
        \\fn outer(): i32!First | Second { return try source(); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "try_union_missing_member", source, "`try` error type mismatch");
}

test "terminal panic branch does not carry a moved local into the continuing branch" {
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "terminal_panic_join",
        \\fn choose(stop: bool): i32 {
        \\    var values: List<i32> = list<i32>();
        \\    values.push(42);
        \\    if stop {
        \\        const moved = values;
        \\        panic("stopped");
        \\    }
        \\    return values[0];
        \\}
        \\fn main(): i32 { return choose(false); }
    );
}

test "return without value reports the return token location" {
    const source =
        \\fn main(): i32 {
        \\    return;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "return_without_value_location",
        source,
        "return_without_value_location:2:5:11: error: type mismatch: expected void, got i32",
    );
}

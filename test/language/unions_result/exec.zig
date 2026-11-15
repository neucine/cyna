const std = @import("std");
const compat = @import("cyna").compat;
const compiler = @import("cyna").compiler;

const helpers = @import("../../helpers.zig");

fn expectNamedNative(comptime name: []const u8, source: []const u8, expected: i64) !void {
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, name, "native_" ++ name ++ ".cy", source, expected);
}

fn parseCatchForAllocationFailures(allocator: std.mem.Allocator, source: []const u8) !void {
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "catch_parse_oom.cy", source, tokens);
    defer program.deinit(allocator);
}

test "named error union preserves distinct enum identities" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\union Errors = First | Second;
        \\fn first(): i32!Errors { throw First.bad; }
        \\fn second(): i32!Errors { throw Second.bad; }
        \\fn classify_first(): i32 { return first() catch (code) { yield switch code { First(value) => 1; Second(value) => 2; }; }; }
        \\fn classify_second(): i32 { return second() catch (code) { yield switch code { First(value) => 1; Second(value) => 2; }; }; }
        \\fn main(): i32 { return classify_first() * 10 + classify_second(); }
    ;
    try expectNamedNative("result_named_error_union", source, 12);
}

test "nested catches retire simultaneous trace records across repeated calls" {
    const source =
        \\enum Fault { outer; inner; }
        \\fn fail(outer: bool): i32!Fault {
        \\    if outer { throw Fault.outer; }
        \\    throw Fault.inner;
        \\}
        \\fn main(): i32 {
        \\    var i: i32 = 0;
        \\    var sum: i32 = 0;
        \\    while i < 32 {
        \\        const value = fail(true) catch (outer_code) {
        \\            const nested = fail(false) catch (inner_code) { yield 2; };
        \\            yield nested + 3;
        \\        };
        \\        sum = sum + value;
        \\        i = i + 1;
        \\    }
        \\    return sum;
        \\}
    ;
    try expectNamedNative("nested_trace_record_retirement", source, 160);
}

test "inline error union canonicalizes member order and preserves enum identity" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\fn first(): i32!First | Second { throw First.bad; }
        \\fn second(): i32!Second | First { throw Second.bad; }
        \\fn classify_first(): i32 { return first() catch (code) { yield switch code { First(value) => 1; Second(value) => 2; }; }; }
        \\fn classify_second(): i32 { return second() catch (code) { yield switch code { First(value) => 1; Second(value) => 2; }; }; }
        \\fn main(): i32 { return classify_first() * 10 + classify_second(); }
    ;
    try expectNamedNative("result_inline_error_union", source, 12);
}

test "inline error union switch inside loop keeps its member tag" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\fn fail(): i32!First | Second { throw Second.bad; }
        \\fn run(): i32 {
        \\    var step: i32 = 0;
        \\    while step < 1 {
        \\        step = step + 1;
        \\        return fail() catch (code) { yield switch code { First(reason) => 2; Second(reason) => 3; }; };
        \\    }
        \\    return 4;
        \\}
        \\fn main(): i32 { return run(); }
    ;
    try expectNamedNative("result_inline_error_union_loop_switch", source, 3);
}

test "try widens enum errors into named and inline result unions" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\union Errors = First | Second;
        \\fn fail(): i32!Second { throw Second.bad; }
        \\fn fail_void(): void!First { throw First.bad; }
        \\fn named(): i32!Errors {
        \\    var owned: List<i32> = list<i32>();
        \\    owned.push(1);
        \\    const value = try fail();
        \\    return value;
        \\}
        \\fn inline(): i32!First | Second { try fail_void(); return 0; }
        \\fn classify_named(): i32 {
        \\    return named() catch (code) { yield switch code { First(value) => 1; Second(value) => 2; }; };
        \\}
        \\fn classify_inline(): i32 {
        \\    return inline() catch (code) { yield switch code { First(value) => 3; Second(value) => 4; }; };
        \\}
        \\fn main(): i32 { return classify_named() * 10 + classify_inline(); }
    ;
    try expectNamedNative("try_error_union_widen", source, 23);
}

test "generic try widening propagates through nested calls" {
    const source =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\union Errors = First | Second;
        \\fn inner<T>(value: T): T!First { throw First.bad; }
        \\fn pass<T>(value: T): T!Errors { return try inner<T>(value); }
        \\fn outer(): i32!Errors { return pass<i32>(1); }
        \\fn main(): i32 {
        \\    return outer() catch (code) { yield switch code { First(value) => 5; Second(value) => 6; }; };
        \\}
    ;
    try expectNamedNative("generic_try_error_union_widen", source, 5);
}

test "explicit bang return spelling matches callback and forwarding calls" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\fn compact(): i32!First { throw First.bad; }
        \\fn expanded(): i32!First { return compact(); }
        \\fn multiple(): i32!First | Second { throw Second.bad; }
        \\fn verify_callback(): bool {
        \\    const callback: fn(): i32!First = compact;
        \\    const value = callback() catch (callback_code) { return true; };
        \\    return false;
        \\}
        \\fn verify_forward(): bool { const value = expanded() catch (forward_code) { return true; }; return false; }
        \\fn main(): i32 {
        \\    if not verify_callback() { return 1; }
        \\    if not verify_forward() { return 2; }
        \\    return multiple() catch (code) { yield switch code { First(value) => 2; Second(value) => 7; }; };
        \\}
    ;
    try expectNamedNative("explicit_bang_return_equivalence", source, 7);
}

test "throw and plain return construct result cases" {
    const source =
        \\enum Failure { bad = 7; }
        \\fn fail(): i32!Failure { throw Failure.bad; }
        \\fn succeed(): i32!Failure { return 9; }
        \\fn forward(): i32!Failure { return succeed(); }
        \\fn main(): i32 {
        \\    const value = fail() catch (caught_code_152) {
        \\        const value = forward() catch (caught_other_153) {
        \\            return 1;
        \\        };
        \\        return value + 1;
        \\    };
        \\    return 0;
        \\}
    ;
    try expectNamedNative("throw_and_plain_result_return", source, 10);
}

test "plain result return transfers an owned success payload" {
    const source =
        \\enum Failure { bad; }
        \\fn make(): List<i32>!Failure {
        \\    var values: List<i32> = list<i32>();
        \\    values.push(4);
        \\    return values;
        \\}
        \\fn main(): i32 {
        \\    const values = make() catch (caught_code_173) {
        \\        return 0;
        \\    };
        \\    return values[0];
        \\}
    ;
    try expectNamedNative("plain_result_owned_success", source, 4);
}

test "error free bang return normalizes to its success type" {
    const source =
        \\fn value(): i32! { return 6; }
        \\fn identity<T>(item: T): T! { return item; }
        \\fn main(): i32 { return identity<i32>(value()); }
    ;
    try expectNamedNative("error_free_bang_return", source, 6);
}

test "bare bang infers direct throw and try enum errors" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\fn fail(): i32! { throw First.bad; }
        \\fn first(): i32!First { return 3; }
        \\fn second(): i32!Second { throw Second.bad; }
        \\fn combined(): i32! { const a = try first(); const b = try second(); return a + b; }
        \\fn main(): i32 {
        \\    const left: i32 = fail() catch (code) { yield 3; };
        \\    return combined() catch (code) { yield switch code { First(value) => 10 + left; Second(value) => 20 + left; }; };
        \\}
    ;
    try expectNamedNative("inferred_bang_enum_errors", source, 23);
}

test "bare bang infers error after concrete generic specialization" {
    const source =
        \\enum Failure { bad; }
        \\fn fail<T>(value: T): T! { throw Failure.bad; }
        \\fn main(): i32 {
        \\    const value = fail<i32>(3) catch (caught_code_218) {
        \\        return 5;
        \\    };
        \\    return 0;
        \\}
    ;
    try expectNamedNative("inferred_bang_generic_error", source, 5);
}

test "bare bang resolves a later inferred callee" {
    const source =
        \\enum Failure { bad; }
        \\fn outer(): i32! { return try inner(); }
        \\fn inner(): i32! { throw Failure.bad; }
        \\fn main(): i32 {
        \\    const value = outer() catch (caught_code_233) {
        \\        return 4;
        \\    };
        \\    return 0;
        \\}
    ;
    try expectNamedNative("inferred_bang_forward_callee", source, 4);
}

test "bare bang infers error from result parameter in generic specialization" {
    const source =
        \\enum Failure { bad; }
        \\fn fail<T>(value: T): T!Failure { throw Failure.bad; }
        \\fn pass<T>(value: T): T! { return try fail<T>(value); }
        \\fn main(): i32 {
        \\    const value = pass<i32>(3) catch (caught_code_248) {
        \\        return 6;
        \\    };
        \\    return 0;
        \\}
    ;
    try expectNamedNative("inferred_bang_parameter_error", source, 6);
}

test "bare bang infers error from local in branch" {
    const source =
        \\enum Failure { bad; }
        \\fn fail(): i32!Failure { throw Failure.bad; }
        \\fn pass(enabled: bool): i32! {
        \\    if enabled {
        \\        const value = fail();
        \\        return try value;
        \\    }
        \\    return 1;
        \\}
        \\fn main(): i32 {
        \\    const value = pass(true) catch (caught_code_269) {
        \\        return 8;
        \\    };
        \\    return 0;
        \\}
    ;
    try expectNamedNative("inferred_bang_annotated_local", source, 8);
}

test "bare bang infers error from unannotated direct call local" {
    const source =
        \\enum Failure { bad; }
        \\fn pass(): i32! { const value = fail(); return try value; }
        \\fn fail(): i32!Failure { throw Failure.bad; }
        \\fn main(): i32 {
        \\    const value = pass() catch (caught_code_284) {
        \\        return 9;
        \\    };
        \\    return 0;
        \\}
    ;
    try expectNamedNative("inferred_bang_unannotated_local", source, 9);
}

test "bare bang infers nested try in return expressions" {
    const source =
        \\enum Failure { bad; }
        \\fn fail(): i32!Failure { throw Failure.bad; }
        \\fn add(value: i32, extra: i32): i32 { return value + extra; }
        \\fn binary(): i32! { return (try fail()) + 1; }
        \\fn argument(): i32! { return add(try fail(), 2); }
        \\fn main(): i32 {
        \\    const a: i32 = binary() catch (code) { yield 1; };
        \\    const b: i32 = argument() catch (code) { yield 2; };
        \\    return a + b;
        \\}
    ;
    try expectNamedNative("inferred_bang_nested_try", source, 3);
}

test "bare bang infers explicitly specialized generic try callee" {
    const source =
        \\enum Failure { bad; }
        \\fn fail<T>(value: T): T! { throw Failure.bad; }
        \\fn direct(): i32! { return try fail<i32>(1); }
        \\fn through_local(): i32! { const value = fail<i32>(2); return try value; }
        \\fn forward<T>(value: T): T! { return try fail<T>(value); }
        \\fn main(): i32 {
        \\    const a: i32 = direct() catch (code) { yield 1; };
        \\    const b: i32 = through_local() catch (code) { yield 2; };
        \\    const c: i32 = forward<i32>(3) catch (code) { yield 4; };
        \\    return a + b + c;
        \\}
    ;
    try expectNamedNative("inferred_bang_generic_try_callee", source, 7);
}

test "bare bang preserves propagated enum union carriers" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\union Errors = First | Second;
        \\fn inline_source(): i32!First | Second { throw Second.bad; }
        \\fn named_source(): i32!Errors { throw Second.bad; }
        \\fn from_inline(): i32! { return try inline_source(); }
        \\fn from_named(): i32! { if false { throw First.bad; } const value = named_source(); return try value; }
        \\fn from_value(): i32! { return try named_source(); }
        \\fn classify_inline(): i32 {
        \\    return from_inline() catch (code) { yield switch code { First(value) => 1; Second(value) => 2; }; };
        \\}
        \\fn classify_named(): i32 {
        \\    return from_named() catch (code) { yield switch code { First(value) => 3; Second(value) => 4; }; };
        \\}
        \\fn main(): i32 {
        \\    const third: i32 = from_value() catch (code) { yield 8; };
        \\    return classify_inline() * 10 + classify_named() + third;
        \\}
    ;
    try expectNamedNative("inferred_bang_union_carrier", source, 32);
}

test "bare bang infers generic try callee from value arguments" {
    const source =
        \\enum Failure { bad; }
        \\fn fail<T>(value: T): T! { throw Failure.bad; }
        \\fn direct(): i32! { return try fail(1 as i32); }
        \\fn through_local(): i32! { const input: i32 = 2; const value = fail(input); return try value; }
        \\fn forward<T>(value: T): T! { return try fail(value); }
        \\fn main(): i32 {
        \\    const a: i32 = direct() catch (code) { yield 1; };
        \\    const b: i32 = through_local() catch (code) { yield 2; };
        \\    const c: i32 = forward<i32>(3) catch (code) { yield 4; };
        \\    return a + b + c;
        \\}
    ;
    try expectNamedNative("inferred_bang_value_generic_callee", source, 7);
}

test "bare bang remaps propagated union members into a larger union" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\enum Third { bad = 7; }
        \\union Pair = Second | Third;
        \\fn inline_source(): i32!Second | Third { throw Second.bad; }
        \\fn named_source(): i32!Pair { throw Second.bad; }
        \\fn void_source(): void!Second | Third { throw Second.bad; }
        \\fn inline_outer(): i32! { if false { throw First.bad; } return try inline_source(); }
        \\fn named_outer(): i32! { if false { throw First.bad; } return try named_source(); }
        \\fn statement_outer(): i32! { if false { throw First.bad; } try void_source(); return 0; }
        \\fn generic_source<T>(value: T): T!Second | Third { throw Second.bad; }
        \\fn forward<T>(value: T): T! { if false { throw First.bad; } return try generic_source<T>(value); }
        \\fn explicit_outer(): i32!First | Second | Third { return try named_source(); }
        \\fn classify_inline(): i32 { return inline_outer() catch (code) { yield switch code { First(item) => 1; Second(item) => 2; Third(item) => 3; }; }; }
        \\fn classify_named(): i32 { return named_outer() catch (code) { yield switch code { First(item) => 1; Second(item) => 2; Third(item) => 3; }; }; }
        \\fn classify_statement(): i32 { return statement_outer() catch (code) { yield switch code { First(item) => 1; Second(item) => 2; Third(item) => 3; }; }; }
        \\fn classify_generic(): i32 { return forward<i32>(0) catch (code) { yield switch code { First(item) => 1; Second(item) => 2; Third(item) => 3; }; }; }
        \\fn classify_explicit(): i32 { return explicit_outer() catch (code) { yield switch code { First(item) => 1; Second(item) => 2; Third(item) => 3; }; }; }
        \\fn main(): i32 {
        \\    return classify_inline() * 50 + classify_named() * 25 + classify_statement() * 10 + classify_generic() + classify_explicit();
        \\}
    ;
    try expectNamedNative("inferred_bang_union_remap", source, 174);
}

test "bare bang merges two propagated union carriers" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\enum Third { bad = 7; }
        \\union Left = First | Second;
        \\union Right = Second | Third;
        \\fn left(): i32!Left { throw First.bad; }
        \\fn right(): i32!Right { throw Third.bad; }
        \\fn choose(use_left: bool): i32! { if use_left { return try left(); } return try right(); }
        \\fn classify_left(): i32 { return choose(true) catch (code) { yield switch code { First(item) => 1; Second(item) => 2; Third(item) => 3; }; }; }
        \\fn classify_right(): i32 { return choose(false) catch (code) { yield switch code { First(item) => 1; Second(item) => 2; Third(item) => 3; }; }; }
        \\fn main(): i32 { return classify_left() * 10 + classify_right(); }
    ;
    try expectNamedNative("inferred_bang_two_union_remaps", source, 13);
}

test "bare bang finds try in conditions and switch expressions" {
    const source =
        \\enum Failure { bad; }
        \\fn flag(): bool!Failure { throw Failure.bad; }
        \\fn number(): i32!Failure { throw Failure.bad; }
        \\fn condition(): i32! { if try flag() { return 1; } return 2; }
        \\fn switch_subject(): i32! { return switch try number() { 1 => 1; _ => 2; }; }
        \\fn switch_arm(): i32! { return switch 1 { 1 => { yield try number(); } _ => 2; }; }
        \\fn main(): i32 {
        \\    const a: i32 = condition() catch (code) { yield 1; };
        \\    const b: i32 = switch_subject() catch (code) { yield 2; };
        \\    const c: i32 = switch_arm() catch (code) { yield 4; };
        \\    return a + b + c;
        \\}
    ;
    try expectNamedNative("inferred_bang_nested_control_expr", source, 7);
}

test "catch fallback evaluates source once and fallback only on error" {
    const source =
        \\enum Failure { bad; }
        \\var trace: i32 = 0;
        \\fn success(): i32!Failure { trace = trace * 10 + 1; return 4; }
        \\fn failure(): i32!Failure { trace = trace * 10 + 2; throw Failure.bad; }
        \\fn fallback(): i32 { trace = trace * 10 + 3; return 7; }
        \\fn main(): i32 {
        \\    const first: i32 = success() catch (code) { yield fallback(); };
        \\    const second: i32 = failure() catch (code) { yield fallback(); };
        \\    if trace != 123 { return 99; }
        \\    return first * 10 + second;
        \\}
    ;
    try expectNamedNative("catch_fallback_once", source, 47);
}

test "short catch arm yields a fallback and can read the error code" {
    const source =
        \\enum Failure { bad; }
        \\fn source(ok: bool): i32!Failure {
        \\    if ok { return 4; }
        \\    throw Failure.bad;
        \\}
        \\fn fallback(code: Failure): i32 {
        \\    if code == Failure.bad { return 7; }
        \\    return 99;
        \\}
        \\fn main(): i32 {
        \\    const first = source(true) catch (code) => fallback(code);
        \\    const second = source(false) catch (code) => fallback(code);
        \\    return first * 10 + second;
        \\}
    ;
    try expectNamedNative("catch_short_arm", source, 47);
}

test "catch fallback checks success payload type" {
    const source =
        \\enum Failure { bad; }
        \\fn source(): i32!Failure { throw Failure.bad; }
        \\fn main(): i32 { return source() catch (code) { yield true; }; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "catch_fallback_type", source, "type mismatch");
}

test "catch fallback transfers owned success and fallback values" {
    const source =
        \\enum Failure { bad; }
        \\fn source(use_ok: bool): List<i32>!Failure {
        \\    var values: List<i32> = list<i32>();
        \\    values.push(5);
        \\    if use_ok { return values; }
        \\    throw Failure.bad;
        \\}
        \\fn fallback(): List<i32> { var values: List<i32> = list<i32>(); values.push(7); return values; }
        \\fn main(): i32 {
        \\    const first: List<i32> = source(true) catch (code) { yield fallback(); };
        \\    const second: List<i32> = source(false) catch (code) { yield fallback(); };
        \\    return first[0] * 10 + second[0];
        \\}
    ;
    try expectNamedNative("catch_fallback_owned", source, 57);
}

test "catch block parser releases partial syntax trees" {
    const sources = [_][]const u8{
        "fn main(): i32 { return source() catch (code) { yield 7; }; }",
        "fn main(): i32 { return source() catch (code, failure) { yield 7; }; }",
        "fn main(): i32 { return source() catch (code) => 7; }",
        "fn main(): i32 { return source() catch (code, failure) => 7; }",
        "fn main(): i32 { throw Fault.bad, \"detail\\n\"; }",
        "fn main(): i32 { return source() catch (failure) { yield 7; }; }",
        "fn main(): i32 { return source() catch (code, failure) { yield 7; }; }",
    };
    for (sources) |source| {
        var baseline = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        try parseCatchForAllocationFailures(baseline.allocator(), source);
        for (0..baseline.alloc_index) |index| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
            if (parseCatchForAllocationFailures(failing.allocator(), source)) |_| {
                if (failing.has_induced_failure) return error.SwallowedOutOfMemoryError;
            } else |err| {
                if (!failing.has_induced_failure) return err;
            }
            if (failing.allocated_bytes != failing.freed_bytes) {
                std.debug.print("catch parser leaked at allocation {d}/{d}\n", .{ index, baseline.alloc_index });
                return error.MemoryLeakDetected;
            }
        }
    }
}

test "explicit catch view syntax preserves yield and enclosing return" {
    const source =
        \\enum Failure { bad; }
        \\fn source(): i32!Failure { throw Failure.bad; }
        \\fn recovered(): i32 { return source() catch (code) { yield 7; }; }
        \\fn early(): i32 {
        \\    const unused: i32 = source() catch (code, failure) { return 5; };
        \\    return 0;
        \\}
        \\fn main(): i32 { return recovered() * 10 + early(); }
    ;
    try expectNamedNative("catch_explicit_view_control_flow", source, 75);
}

test "ordinary catch block binds the enum error code" {
    const source =
        \\enum Failure { bad; worse; }
        \\fn source(): i32!Failure { throw Failure.bad; }
        \\fn main(): i32 {
        \\    return source() catch (code) {
        \\        yield switch code { Failure.bad => 7; Failure.worse => 8; };
        \\    };
        \\}
    ;
    try expectNamedNative("catch_block_code_binding", source, 7);
}

test "ordinary catch handles void success and failure paths" {
    const source =
        \\enum Failure { bad; }
        \\fn source(fail: bool): void!Failure { if fail { throw Failure.bad; } return; }
        \\fn handle(fail: bool): i32 {
        \\    source(fail) catch (code) {
        \\        if code == Failure.bad { return 4; }
        \\        return 5;
        \\    };
        \\    return 2;
        \\}
        \\fn main(): i32 { return handle(false) * 10 + handle(true); }
    ;
    try expectNamedNative("catch_void_success_and_failure", source, 24);
}

test "ordinary catch block infers outward errors" {
    const source =
        \\enum SourceError { bad; }
        \\enum NextError { bad; }
        \\fn source(): i32!SourceError { throw SourceError.bad; }
        \\fn forward(): i32! {
        \\    return source() catch (code) {
        \\        if code == SourceError.bad { throw NextError.bad; }
        \\        yield 1;
        \\    };
        \\}
        \\fn main(): i32 {
        \\    const value = forward();
        \\    return value catch (code) { yield 9; };
        \\}
    ;
    try expectNamedNative("catch_block_inferred_outward_error", source, 9);
}

test "ordinary catch block matches cases across error enum union" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\fn source(first: bool): i32!First | Second { if first { throw First.bad; } throw Second.bad; }
        \\fn run(first: bool): i32 {
        \\    return source(first) catch (code) {
        \\        yield switch code { First.bad => 1; Second.bad => 2; };
        \\    };
        \\}
        \\fn main(): i32 {
        \\    return run(true) * 10 + run(false);
        \\}
    ;
    try expectNamedNative("catch_block_union_code_cases", source, 12);
}

test "ordinary catch block matches named error enum union" {
    const source =
        \\enum First { bad; other; }
        \\enum Second { bad; }
        \\union Errors = First | Second;
        \\fn source(): i32!Errors { throw Second.bad; }
        \\fn main(): i32 {
        \\    return source() catch (code) {
        \\        yield switch code { First.bad => 1; Second.bad => 2; _ => 3; };
        \\    };
        \\}
    ;
    try expectNamedNative("catch_block_named_union_code_cases", source, 2);
}

test "ordinary catch union switch rejects missing and payload cases" {
    const missing =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\fn source(): i32!First | Second { throw Second.bad; }
        \\fn main(): i32 { return source() catch (code) { yield switch code { First.bad => 1; }; }; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "catch_union_missing_enum_case", missing, "non-exhaustive switch");

    const payload =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\fn source(): i32!First | Second { throw Second.bad; }
        \\fn main(): i32 { return source() catch (code) { yield switch code { First.bad(value) => 1; Second.bad => 2; }; }; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "catch_union_payload_case", payload, "error code cases cannot bind payloads");
}

test "explicit catch block requires distinct binding names" {
    const source =
        \\enum Failure { bad; }
        \\fn source(): i32!Failure { throw Failure.bad; }
        \\fn main(): i32 { return source() catch (code, code) { yield 7; }; }
    ;
    try helpers.expectParseFailedMessage(std.testing.allocator, "catch_distinct_bindings", source, "failure detail needs a distinct name");
}

test "failure view rejects ordinary value and mutation operations" {
    const cases = [_]struct { name: []const u8, body: []const u8, diagnostic: []const u8 }{
        .{ .name = "failure_view_copy", .body = "const copy = failure; yield 1;", .diagnostic = "failure view cannot be used as a value" },
        .{ .name = "failure_view_return", .body = "return failure;", .diagnostic = "failure view cannot be used as a value" },
        .{ .name = "failure_view_pass", .body = "consume(failure); yield 1;", .diagnostic = "failure view cannot be used as a value" },
        .{ .name = "failure_view_assign", .body = "failure = 1; yield 1;", .diagnostic = "cannot assign to a failure view" },
        .{ .name = "failure_view_drop", .body = "drop failure; yield 1;", .diagnostic = "cannot drop a failure view" },
        .{ .name = "failure_view_mutate", .body = "failure.message = 1; yield 1;", .diagnostic = "cannot mutate a failure view" },
        .{ .name = "failure_view_field", .body = "const message = failure.unknown; yield 1;", .diagnostic = "unknown failure detail `unknown`" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "enum Failure {{ bad; }} fn source(): i32!Failure {{ throw Failure.bad; }} fn consume(value: i32): void {{}} fn main(): i32 {{ return source() catch (code, failure) {{ {s} }}; }}",
            .{case.body},
        );
        defer std.testing.allocator.free(source);
        try helpers.expectSemanticFailedMessage(std.testing.allocator, case.name, source, case.diagnostic);
    }
}

test "failure view cannot escape its catch scope" {
    const outside =
        \\enum Failure { bad; }
        \\fn source(): i32!Failure { throw Failure.bad; }
        \\fn main(): i32 {
        \\    const value = source() catch (code, failure) { yield 1; };
        \\    const escaped = failure;
        \\    return value;
        \\}
    ;
    try helpers.expectSemanticFailed(std.testing.allocator, "failure_view_outside_catch", outside);

    const captured =
        \\enum Failure { bad; }
        \\fn source(): i32!Failure { throw Failure.bad; }
        \\fn main(): i32 {
        \\    return source() catch (code, failure) {
        \\        const action = fn() { return failure; };
        \\        yield 1;
        \\    };
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "failure_view_closure_capture", captured, "failure view cannot be captured");
}

test "catch failure scalar details survive try propagation" {
    const source =
        \\enum Fault { bad; }
        \\fn fail(): i32!Fault { throw Fault.bad; }
        \\fn pass(): i32!Fault { return try fail(); }
        \\fn main(): i32 {
        \\    return pass() catch (code, failure) {
        \\        if not failure.available { return 1; }
        \\        if failure.origin != 2 { return 2; }
        \\        if not failure.origin_file.ends_with("catch_failure_scalar_details.cy") { return 8; }
        \\        if failure.site_count != 1 { return 3; }
        \\        if failure.site(0) is propagated { if propagated != 3 { return 6; } } else { return 7; }
        \\        if failure.site_file(0) is path { if not path.ends_with("catch_failure_scalar_details.cy") { return 9; } } else { return 10; }
        \\        if failure.omitted != 0 { return 4; }
        \\        if not failure.message.is_empty() { return 5; }
        \\        yield 0;
        \\    };
        \\}
    ;
    try expectNamedNative("catch_failure_scalar_details", source, 0);
}

test "catch failure sites use safe indexed reads" {
    const source =
        \\enum Fault { bad; }
        \\fn fail(): i32!Fault { throw Fault.bad; }
        \\fn pass_one(): i32!Fault { return try fail(); }
        \\fn pass_two(): i32!Fault { return try pass_one(); }
        \\fn main(): i32 {
        \\    return pass_two() catch (code, failure) {
        \\        if failure.site_count != 2 { return 1; }
        \\        if failure.site(0) is first { if first != 3 { return 2; } } else { return 3; }
        \\        if failure.site(1) is second { if second != 4 { return 4; } } else { return 5; }
        \\        if failure.site(2) is value { return 6; }
        \\        if failure.site(-1) is value { return 7; }
        \\        yield 0;
        \\    };
        \\}
    ;
    try expectNamedNative("catch_failure_indexed_sites", source, 0);
}

test "catch failure file locations cross modules and survive catch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/source.cy", .data =
        \\pub enum Fault { bad; }
        \\pub fn fail(): i32!Fault { throw Fault.bad; }
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { Fault, fail } from lib.source;
        \\fn pass(): i32!Fault { return try fail(); }
        \\fn main(): i32 {
        \\    var origin = "";
        \\    const value = pass() catch (code, failure) {
        \\        if failure.site_file(0) is path {
        \\            if not path.ends_with("main.cy") { return 1; }
        \\        } else { return 2; }
        \\        origin = failure.origin_file;
        \\        yield 0;
        \\    };
        \\    if not origin.ends_with("source.cy") { return 3; }
        \\    return 0;
        \\}
    });
    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);
    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 0);
}

test "statement try records its source line" {
    const source =
        \\enum Fault { bad; }
        \\fn fail(): void!Fault { throw Fault.bad; }
        \\fn pass(): void!Fault {
        \\    try fail();
        \\    return;
        \\}
        \\fn main(): i32 {
        \\    pass() catch (code, failure) {
        \\        if failure.origin != 2 { return 1; }
        \\        if failure.site(0) is line { if line != 4 { return 2; } } else { return 3; }
        \\        yield;
        \\    };
        \\    return 0;
        \\}
    ;
    try expectNamedNative("catch_failure_statement_try_line", source, 0);
}

test "nested catches exhaust trace slots without losing the typed error" {
    const source =
        \\enum Fault { bad; }
        \\fn fail(): i32!Fault { throw Fault.bad; }
        \\fn nested(depth: i32): i32!Fault {
        \\    return fail() catch (code, failure) {
        \\        if depth < 16 {
        \\            if not failure.available { return 1; }
        \\            const inner = try nested(depth + 1);
        \\            if inner != 0 { return inner; }
        \\        } else {
        \\            if failure.available { return 2; }
        \\            if failure.origin != 0 { return 3; }
        \\            if failure.site_count != 0 { return 4; }
        \\            if failure.omitted != 0 { return 5; }
        \\            if not failure.message.is_empty() { return 6; }
        \\            if failure.site(0) is value { return 7; }
        \\            if not failure.origin_file.is_empty() { return 8; }
        \\            if failure.site_file(0) is path { return 9; }
        \\        }
        \\        yield 0;
        \\    };
        \\}
        \\fn main(): i32 { return nested(0) catch (code) { yield 99; }; }
    ;
    try expectNamedNative("catch_failure_trace_slot_exhaustion", source, 0);
}

test "propagation site capacity reports omitted sites" {
    const source =
        \\enum Fault { bad; }
        \\fn fail(): i32!Fault { throw Fault.bad; }
        \\fn p1(): i32!Fault { return try fail(); }
        \\fn p2(): i32!Fault { return try p1(); }
        \\fn p3(): i32!Fault { return try p2(); }
        \\fn p4(): i32!Fault { return try p3(); }
        \\fn p5(): i32!Fault { return try p4(); }
        \\fn p6(): i32!Fault { return try p5(); }
        \\fn p7(): i32!Fault { return try p6(); }
        \\fn p8(): i32!Fault { return try p7(); }
        \\fn p9(): i32!Fault { return try p8(); }
        \\fn p10(): i32!Fault { return try p9(); }
        \\fn main(): i32 {
        \\    return p10() catch (code, failure) {
        \\        if failure.site_count != 8 { return 1; }
        \\        if failure.omitted != 2 { return 2; }
        \\        if failure.site(7) is last { if last == 0 { return 3; } } else { return 4; }
        \\        if failure.site(8) is ignored { return 5; }
        \\        yield 0;
        \\    };
        \\}
    ;
    try expectNamedNative("catch_failure_site_capacity", source, 0);
}

test "catch failure message is an owned copy" {
    const source =
        \\enum Fault { bad; }
        \\fn fail(): i32!Fault { throw Fault.bad, "detail"; }
        \\fn main(): i32 {
        \\    var saved: string = "";
        \\    const value = fail() catch (code, failure) {
        \\        if failure.message != "detail" { return 1; }
        \\        saved = failure.message;
        \\        yield 0;
        \\    };
        \\    if saved != "detail" { return 2; }
        \\    return value;
        \\}
    ;
    try expectNamedNative("catch_failure_owned_message", source, 0);
}

test "oversized failure message keeps the typed error with empty diagnostics" {
    const source =
        \\enum Fault { bad; }
        \\fn fail(): i32!Fault { throw Fault.bad, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; }
        \\fn main(): i32 {
        \\    return fail() catch (code, failure) {
        \\        if failure.available { return 1; }
        \\        if not failure.message.is_empty() { return 2; }
        \\        yield 0;
        \\    };
        \\}
    ;
    try expectNamedNative("catch_failure_oversized_message", source, 0);
}

test "rethrow with a new message retires the caught record" {
    const source =
        \\enum Fault { bad; }
        \\fn fail(): i32!Fault { throw Fault.bad, "first"; }
        \\fn replace(): i32!Fault { return fail() catch (code, failure) { throw code, "second"; }; }
        \\fn main(): i32 {
        \\    var i: i32 = 0;
        \\    while i < 20 {
        \\        const value = replace() catch (code, failure) {
        \\            if failure.message != "second" { return 1; }
        \\            yield 0;
        \\        };
        \\        i = i + 1;
        \\    }
        \\    return 0;
        \\}
    ;
    try expectNamedNative("catch_failure_new_rethrow_message", source, 0);
}

test "catch arms evaluate one result and yield only the selected handler" {
    const source =
        \\enum Failure { bad; }
        \\var trace: i32 = 0;
        \\fn source(ok: bool): i32!Failure {
        \\    trace = trace * 10 + 1;
        \\    if ok { return 4; }
        \\    throw Failure.bad;
        \\}
        \\fn main(): i32 {
        \\    const first: i32 = source(true) catch (code) { trace = trace * 10 + 2; yield 7; };
        \\    const second: i32 = source(false) catch (code) { trace = trace * 10 + 3; yield 7; };
        \\    if trace != 113 { return 99; }
        \\    return first * 10 + second;
        \\}
    ;
    try expectNamedNative("catch_total_arms_once", source, 47);
}

test "catch arms preserve enum identity in error unions" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\fn source(): i32!First | Second { throw Second.bad; }
        \\fn main(): i32 {
        \\    const selected: i32 = source() catch (code) { yield switch code { First(value) => 1; Second(value) => 2; }; };
        \\    const wildcard: i32 = source() catch (code) { yield 3; };
        \\    return selected * 10 + wildcard;
        \\}
    ;
    try expectNamedNative("catch_union_identity", source, 23);
}

test "partial catch in a plain function requires a result return" {
    const source =
        \\enum Failure { first; second; }
        \\fn source(): i32!Failure { throw Failure.second; }
        \\fn main(): i32 { return source() catch (code) { if code == Failure.first { yield 1; } throw code; }; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "catch_incomplete_enum", source, "`throw` requires a result return type");
}

test "partial catch propagates unmatched enum errors" {
    const source =
        \\enum Failure { first; second; }
        \\fn source(use_first: bool): i32!Failure { if use_first { throw Failure.first; } throw Failure.second; }
        \\fn partial(use_first: bool): i32!Failure { return source(use_first) catch (code) { if code == Failure.first { yield 7; } throw code; }; }
        \\fn main(): i32 {
        \\    const matched: i32 = partial(true) catch (code) { yield 0; };
        \\    const unmatched: i32 = partial(false) catch (code) { yield 2; };
        \\    return matched * 10 + unmatched;
        \\}
    ;
    try expectNamedNative("catch_partial_enum", source, 72);
}

test "partial catch preserves unmatched union member identity" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\fn source(use_first: bool): i32!First | Second { if use_first { throw First.bad; } throw Second.bad; }
        \\fn partial(use_first: bool): i32!First | Second { return source(use_first) catch (code) { yield switch code { First(value) => 7; Second(value) => { throw Second.bad; } }; }; }
        \\fn main(): i32 {
        \\    const matched: i32 = partial(true) catch (code) { yield 0; };
        \\    const unmatched: i32 = partial(false) catch (code) { yield switch code { First(value) => 1; Second(value) => 2; }; };
        \\    return matched * 10 + unmatched;
        \\}
    ;
    try expectNamedNative("catch_partial_union_identity", source, 72);
}

test "partial catch requires an enclosing result and admitted errors" {
    const plain =
        \\enum Failure { first; second; }
        \\fn source(): i32!Failure { throw Failure.second; }
        \\fn main(): i32 { return source() catch (code) { if code == Failure.first { yield 7; } throw code; }; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "catch_partial_plain_return", plain, "`throw` requires a result return type");

    const missing_member =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\fn source(): i32!First | Second { throw Second.bad; }
        \\fn partial(): i32!First { return source() catch (code) { yield switch code { First(value) => 7; Second(value) => { throw Second.bad; } }; }; }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "catch_partial_missing_member", missing_member, "type mismatch");
}

test "partial catch narrows propagated union to the unmatched member" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\fn source(use_first: bool): i32!First | Second { if use_first { throw First.bad; } throw Second.bad; }
        \\fn partial(use_first: bool): i32!Second { return source(use_first) catch (code) { yield switch code { First(value) => 7; Second(value) => { throw Second.bad; } }; }; }
        \\fn main(): i32 {
        \\    const matched: i32 = partial(true) catch (code) { yield 0; };
        \\    const unmatched: i32 = partial(false) catch (code) { yield 2; };
        \\    return matched * 10 + unmatched;
        \\}
    ;
    try expectNamedNative("catch_partial_narrow_union", source, 72);
}

test "partial catch infers the remaining union members" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\enum Third { bad = 7; }
        \\fn source(): i32!First | Second | Third { throw Third.bad; }
        \\fn partial(): i32! { return source() catch (code) { yield switch code { First(value) => 1; Second(value) => { throw Second.bad; } Third(value) => { throw Third.bad; } }; }; }
        \\fn main(): i32 { return partial() catch (code) { yield switch code { Second(value) => 2; Third(value) => 3; }; }; }
    ;
    try expectNamedNative("catch_partial_inferred_remaining", source, 3);
}

test "partial catch transfers an owned success payload" {
    const source =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\fn source(use_first: bool): List<i32>!First | Second { if use_first { throw First.bad; } throw Second.bad; }
        \\fn recovered(): List<i32> { var values: List<i32> = list<i32>(); values.push(7); return values; }
        \\fn partial(use_first: bool): List<i32>!Second { return source(use_first) catch (code) { yield switch code { First(value) => recovered(); Second(value) => { throw Second.bad; } }; }; }
        \\fn main(): i32 {
        \\    const values = partial(true) catch (code) { yield recovered(); };
        \\    const matched: i32 = values[0];
        \\    const ignored = partial(false) catch (code) { return matched * 10 + 2; };
        \\    const unmatched: i32 = ignored[0];
        \\    return matched * 10 + unmatched;
        \\}
    ;
    try expectNamedNative("catch_partial_owned", source, 72);
}

test "partial catch preserves an optional success payload" {
    const source =
        \\enum First { bad = 5; }
        \\enum Second { bad = 6; }
        \\fn source(mode: i32): ?i32!First | Second {
        \\    if mode == 1 { throw First.bad; }
        \\    if mode == 2 { throw Second.bad; }
        \\    if mode == 3 { return none; }
        \\    const value: ?i32 = 7;
        \\    return value;
        \\}
        \\fn partial(mode: i32): ?i32!Second {
        \\    return source(mode) catch (code) {
        \\        yield switch code {
        \\        First(value) => { const recovered: ?i32 = 7; yield recovered; }
        \\        Second(value) => { throw Second.bad; }
        \\        };
        \\    };
        \\}
        \\fn main(): i32 {
        \\    const first = partial(0) catch (first_error) { return 1; };
        \\    const absent = partial(3) catch (absent_error) { return 2; };
        \\    const recovered = partial(1) catch (recover_error) { return 3; };
        \\    const failed = partial(2) catch (failed_error) {
        \\        if first is first_value { if absent is none { if recovered is recovered_value { return first_value * 10 + 4 + recovered_value + 6; } } }
        \\        return 0;
        \\    };
        \\    return 0;
        \\}
    ;
    try expectNamedNative("catch_partial_nested_result", source, 87);
}

test "bare bang joins errors from conditional returns" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\fn choose(second: bool): i32! {
        \\    if second { throw Second.bad; } else { throw First.bad; }
        \\}
        \\fn main(): i32 {
        \\    return choose(true) catch (code) { yield switch code { First(value) => 1; Second(value) => 2; }; };
        \\}
    ;
    try expectNamedNative("inferred_bang_branch_errors", source, 2);
}

test "switch block arms accept arrow and final wildcard syntax" {
    const source =
        \\enum Error { ready; failed; }
        \\
        \\fn main(): i32 {
        \\    const value = Error.ready;
        \\    switch value {
        \\    Error.ready => { return 42; }
        \\    _ => { return 0; }
        \\    }
        \\}
    ;
    try expectNamedNative("switch_arrow_block_wildcard", source, 42);
}

test "switch arms diagnose removed case and else spellings" {
    const old_case =
        \\enum Status { ready; }
        \\fn main(): i32 { switch Status.ready { case .ready { return 0; } } }
    ;
    try helpers.expectParseFailedMessage(std.testing.allocator, "switch_old_case", old_case, "switch arms use `pattern =>` without `case`");

    const old_else =
        \\fn main(): i32 { switch 1 { 1 => { return 0; } else { return 1; } } }
    ;
    try helpers.expectParseFailedMessage(std.testing.allocator, "switch_old_else", old_else, "switch wildcard arms use `_ =>` instead of `else`");
}

test "switch expressions yield from nested blocks and preserve return and continue" {
    const source =
        \\fn choose(code: i32): i32 {
        \\    return switch code {
        \\    1 => { if true { yield 10; } yield 11; }
        \\    2 => { var n: i32 = 0; while n < 1 { n = n + 1; yield 20; } yield 21; }
        \\    _ => 30;
        \\    };
        \\}
        \\fn nested(code: i32): i32 {
        \\    return switch code {
        \\    1 => { yield switch code { 1 => 4; _ => 5; }; }
        \\    _ => 6;
        \\    };
        \\}
        \\fn direct(code: i32): i32 {
        \\    return switch code { 1 => { return 7; } _ => 8; };
        \\}
        \\fn statement(code: i32): i32 {
        \\    switch code { 1 => { yield; } _ => {} }
        \\    return 9;
        \\}
        \\fn main(): i32 {
        \\    return choose(1) + choose(2) + nested(1) + direct(1) + statement(1) - 50;
        \\}
    ;
    try expectNamedNative("switch_expression_nested_yield", source, 0);
}

test "non-void switch expression arm must yield or return" {
    const source =
        \\fn main(): i32 {
        \\    return switch 1 { 1 => { const unused: i32 = 2; } _ => 3; };
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "switch_expression_fallthrough", source, "non-void switch arm can finish without `yield`");
}

test "switch expression supports string values and void return" {
    const source =
        \\fn finish(): void {
        \\    return switch 1 { 1 => { yield; } _ => {} };
        \\}
        \\fn main(): i32 {
        \\    const text: string = switch 1 { 1 => "hello"; _ => "other"; };
        \\    finish();
        \\    if text == "hello" { return 0; }
        \\    return 1;
        \\}
    ;
    try expectNamedNative("switch_expression_string_void", source, 0);
}

test "void switch expression cannot initialize a local binding" {
    const source =
        \\fn main(): i32 {
        \\    const ignored: void = switch 1 { 1 => { yield; } _ => {} };
        \\    return 0;
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "void_switch_binding", source, "a `void` value cannot be stored in a local binding");
}

test "switch expression rejects borrows that outlive arm or function" {
    const arm_local =
        \\fn bad(): &const i32 {
        \\    return switch 1 {
        \\    1 => { const value: i32 = 1; yield &value; }
        \\    _ => { const value: i32 = 2; yield &value; }
        \\    };
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "switch_arm_borrow_escape", arm_local, "borrowed values cannot escape a switch arm");

    const function_local =
        \\fn bad(): &const i32 {
        \\    const value: i32 = 1;
        \\    return switch 1 { 1 => &value; _ => &value; };
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "switch_return_borrow_escape", function_local, "borrowed values cannot escape the function via return");
}

test "integer and string switches compare scalar patterns and accept wildcard only" {
    const source =
        \\const NotFound: i32 = 404;
        \\fn category(code: i32): i32 {
        \\    const next: i32 = 405;
        \\    switch code {
        \\    0 => { return 1; }
        \\    NotFound => { return 2; }
        \\    next => { return 3; }
        \\    _ => { return 4; }
        \\    }
        \\}
        \\fn command(text: string): i32 {
        \\    switch text {
        \\    "start" => { return 5; }
        \\    "stop" => { return 6; }
        \\    _ => { return 7; }
        \\    }
        \\}
        \\fn any(code: i32): i32 {
        \\    switch code { _ => { return 8; } }
        \\}
        \\fn main(): i32 {
        \\    const prefix = "sta";
        \\    return category(404) + category(405) + command($"{prefix}rt") + any(12) - 18;
        \\}
    ;
    try expectNamedNative("scalar_switch_patterns", source, 0);
}

test "scalar switch diagnoses duplicate integer and string patterns" {
    const integers =
        \\fn main(): i32 {
        \\    switch 1 { 1 => { return 1; } 0x1 => { return 2; } _ => { return 0; } }
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "duplicate_integer_switch", integers, "duplicate integer switch pattern");

    const strings =
        \\fn main(): i32 {
        \\    switch "a" { "a" => { return 1; } "a" => { return 2; } _ => { return 0; } }
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "duplicate_string_switch", strings, "duplicate string switch pattern");
}

test "scalar switches require final wildcard and compile-time patterns" {
    const missing =
        \\fn main(): i32 { switch 1 { 1 => { return 1; } } return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "scalar_switch_missing_wildcard", missing, "require a final `_` arm");

    const runtime_value =
        \\fn main(): i32 {
        \\    const runtime: i32 = dynamic();
        \\    switch 1 { runtime => { return 1; } _ => { return 0; } }
        \\}
        \\fn dynamic(): i32 { return 1; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "runtime_integer_switch", runtime_value, "compile-time integer constant");

    const named_string =
        \\fn main(): i32 {
        \\    const pattern = "start";
        \\    switch "start" { pattern => { return 1; } _ => { return 0; } }
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "named_string_switch", named_string, "string switch pattern must be a string literal");

    const out_of_range =
        \\fn main(): i32 {
        \\    const code: u8 = 1;
        \\    switch code { 256 => { return 1; } _ => { return 0; } }
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "out_of_range_switch", out_of_range, "integer switch pattern does not fit subject type");
}

test "scalar switch inside a loop preserves continue flow" {
    const source =
        \\fn main(): i32 {
        \\    var code: i32 = 0;
        \\    while code < 3 {
        \\        code = code + 1;
        \\        switch code {
        \\        1 => { continue; }
        \\        2 => { continue; }
        \\        _ => { return code - 3; }
        \\        }
        \\    }
        \\    return 4;
        \\}
    ;
    try expectNamedNative("scalar_switch_loop_continue", source, 0);
}

test "integer switch patterns include signed arithmetic and wide unsigned constants" {
    const source =
        \\const Base: i32 = 404;
        \\fn signed(value: i32): i32 {
        \\    switch value {
        \\    -2 => { return 1; }
        \\    Base + 1 => { return 2; }
        \\    _ => { return 3; }
        \\    }
        \\}
        \\fn wide(value: u64): i32 {
        \\    switch value {
        \\    18446744073709551615 => { return 4; }
        \\    _ => { return 5; }
        \\    }
        \\}
        \\fn main(): i32 {
        \\    return signed(-2) + signed(405) + wide(18446744073709551615) - 7;
        \\}
    ;
    try expectNamedNative("integer_switch_constants", source, 0);
}

test "`try` rejects optional values because optional propagation is explicit" {
    const source =
        \\fn maybe(): ?i32 {
        \\    return 42;
        \\}
        \\
        \\fn forward(): ?i32 {
        \\    const value = try maybe();
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "try_optional_rejected",
        source,
        "`try` propagates only result errors, not optional absence; test the optional and `return none` explicitly",
    );
}

test "`try` expressions require a result return type" {
    const source =
        \\enum Failure {
        \\    failed;
        \\}
        \\
        \\fn produce(): i32!Failure {
        \\    return 42;
        \\}
        \\
        \\fn main() {
        \\    const value = try produce();
        \\    const ignored = value;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "try_expression_non_result_return",
        source,
        "`try` expression requires a result return type",
    );
}

test "`try` expressions require the enclosing result error type" {
    const source =
        \\enum FirstError {
        \\    failed;
        \\}
        \\
        \\enum SecondError {
        \\    failed;
        \\}
        \\
        \\fn produce(): i32!FirstError {
        \\    return 42;
        \\}
        \\
        \\fn main(): void!SecondError {
        \\    const value = try produce();
        \\    const ignored = value;
        \\    return;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "try_expression_error_mismatch",
        source,
        "`try` error type mismatch: expected SecondError, got FirstError",
    );
}

test "cunion fields require explicit types" {
    try helpers.expectParseFailed(std.testing.allocator, "cunion_fields_require_types",
        \\c union Raw {
        \\    bits;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    );
}

test "cunion field reads are allowed inside unchecked" {
    const source =
        \\c union Raw {
        \\    int_value: i32;
        \\}
        \\
        \\fn read(value: Raw): i32 {
        \\    unchecked {
        \\        return value.int_value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try expectNamedNative("cunion_field_read_unchecked", source, 0);
}

test "union values switch with payload bindings" {
    const source =
        \\union Token {
        \\    ident: string;
        \\    eof;
        \\}
        \\
        \\fn score(token: Token): i32 {
        \\    switch token {
        \\    .ident(name) => {
        \\        if name == "answer" {
        \\            return 42;
        \\        }
        \\        return 1;
        \\    }
        \\    .eof => {
        \\        return 0;
        \\    }
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return score(.ident("answer"));
        \\}
    ;

    try expectNamedNative("union_switch_payload", source, 42);
}

test "union switches may omit unused payload bindings" {
    const source =
        \\union Token { ident: string; eof; }
        \\fn plain(token: Token): i32 {
        \\    switch token {
        \\    .ident => { return 2; }
        \\    .eof => { return 0; }
        \\    }
        \\}
        \\fn in_loop(token: Token): i32 {
        \\    var total = 0;
        \\    var i = 0;
        \\    while i < 1 {
        \\        switch token {
        \\        .ident => { total = total + 40; }
        \\        .eof => { total = total + 1; }
        \\        }
        \\        i = i + 1;
        \\    }
        \\    return total;
        \\}
        \\fn main(): i32 {
        \\    return plain(.ident("answer")) + in_loop(.ident("answer"));
        \\}
    ;

    try expectNamedNative("union_switch_omits_unused_payload_bindings", source, 42);
}

test "union and result switches accept explicit empty else" {
    const source =
        \\enum LoadError {
        \\    failed = 0,
        \\}
        \\
        \\union Token {
        \\    ident: string;
        \\    eof;
        \\}
        \\
        \\fn load(): i32!LoadError {
        \\    throw LoadError.failed;
        \\}
        \\
        \\fn score(token: Token): i32 {
        \\    var value = 0;
        \\    switch token {
        \\    .ident(name) => {
        \\        if name == "answer" {
        \\            value = 40;
        \\        }
        \\    }
        \\    _ => {}
        \\    }
        \\    const ok = load() catch (code) { yield 0; };
        \\    value = value + ok;
        \\    return value + 2;
        \\}
        \\
        \\fn main(): i32 {
        \\    return score(.ident("answer"));
        \\}
    ;

    try expectNamedNative("switch_explicit_empty_else", source, 42);
}

test "union payload projection returns payload value" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    const token: Token = .number(42);
        \\    return token.number;
        \\}
    ;

    try expectNamedNative("union_projection", source, 42);
}

test "union case constructor infers from function return type" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    eof;
        \\}
        \\
        \\fn answer(): Token {
        \\    return .number(42);
        \\}
        \\
        \\fn main(): i32 {
        \\    return answer().number;
        \\}
    ;

    try expectNamedNative("union_case_infers_from_return_type", source, 42);
}

test "type union wraps contextual payloads and switches by variant type" {
    const source =
        \\struct KeyEvent {
        \\    code: i32;
        \\}
        \\
        \\struct MouseEvent {
        \\    x: i32;
        \\}
        \\
        \\union Event = KeyEvent | MouseEvent;
        \\
        \\fn score(event: Event): i32 {
        \\    switch event {
        \\    KeyEvent(key) => {
        \\        return key.code;
        \\    }
        \\    MouseEvent(mouse) => {
        \\        return mouse.x;
        \\    }
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return score(KeyEvent {
        \\        code: 42,
        \\    });
        \\}
    ;

    try expectNamedNative("type_union_contextual_wrap_switch", source, 42);
}

test "type union checked projection extracts variant payload" {
    const source =
        \\struct KeyEvent {
        \\    code: i32;
        \\}
        \\
        \\struct MouseEvent {
        \\    x: i32;
        \\}
        \\
        \\union Event = KeyEvent | MouseEvent;
        \\
        \\fn main(): i32 {
        \\    const event: Event = KeyEvent {
        \\        code: 42,
        \\    };
        \\    const key = event as KeyEvent;
        \\    return key.code;
        \\}
    ;

    try expectNamedNative("type_union_as_projection", source, 42);
}

test "type union fallible projection returns none on mismatch" {
    const source =
        \\struct KeyEvent {
        \\    code: i32;
        \\}
        \\
        \\struct MouseEvent {
        \\    x: i32;
        \\}
        \\
        \\union Event = KeyEvent | MouseEvent;
        \\
        \\fn main(): i32 {
        \\    const event: Event = MouseEvent {
        \\        x: 7,
        \\    };
        \\    const key = event as? KeyEvent;
        \\    if key is none {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("type_union_as_projection_fallible", source, 42);
}

test "type union rejects duplicate effective variants" {
    const source =
        \\union Bad = i32 | i32;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "type_union_duplicate_variant.cy", source, "duplicate type-union variant `i32`");
}

test "checked return construction preserves success and error paths" {
    const source =
        \\enum Status: i32 {
        \\    ok = 0,
        \\    failed,
        \\}
        \\
        \\fn succeed(): i32!Status {
        \\    return 42;
        \\}
        \\
        \\fn fail(): i32!Status {
        \\    throw Status.failed;
        \\}
        \\
        \\fn main(): i32 {
        \\    const value = succeed() catch (caught_status_1436) {
        \\        const ignored = caught_status_1436;
        \\        return 1;
        \\    };
        \\    const failed = fail() catch (fail_status) {
        \\        if fail_status == Status.failed {
        \\            return value;
        \\        }
        \\        return 1;
        \\    };
        \\    return 0;
        \\}
    ;

    try expectNamedNative("result_case_infers_from_return_type", source, 42);
}

test "catch may leave the error code unused" {
    const source =
        \\enum Status: i32 {
        \\    ok = 0,
        \\    failed,
        \\}
        \\
        \\fn succeed(): i32!Status {
        \\    return 42;
        \\}
        \\
        \\fn fail(): i32!Status {
        \\    throw Status.failed;
        \\}
        \\
        \\fn main(): i32 {
        \\    var total = 0;
        \\    const first = succeed() catch (code) { return 1; };
        \\    total = total + 1;
        \\    const second = fail() catch (code) { total = total + 41; yield 0; };
        \\    return total;
        \\}
    ;

    try expectNamedNative("result_switch_omits_unused_payload_bindings", source, 42);
}

test "result case infers optional string payload from return type" {
    const source =
        \\enum Status: i32 {
        \\    failed = 1;
        \\}
        \\
        \\fn load(): ?string!Status {
        \\    const value: ?string = "answer";
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    const value = load() catch (caught_status_1506) {
        \\        const ignored = caught_status_1506;
        \\        return 99;
        \\    };
        \\    if value is text {
        \\        if text == "answer" {
        \\            return 42;
        \\        }
        \\        return 2;
        \\    }
        \\    return 3;
        \\}
    ;

    try expectNamedNative("result_case_infers_optional_string_payload", source, 42);
}

test "optional is capture narrows in if" {
    const source =
        \\fn main(): i32 {
        \\    const value: ?i32 = 42;
        \\    if value is n {
        \\        return n;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("optional_is_capture", source, 42);
}

test "native optional is capture supports resource payloads" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    const value: ?User = User { age: 42, scores: list<i32>() };
        \\    if value is user {
        \\        return user.age;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_optional_is_capture_resource.cy", source, 42);
}

test "native optional is capture supports runtime string payloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const data = try compat.dirCreateFile(tmp.dir, "input.txt", .{});
        defer compat.closeFile(data);
        try compat.fileWriteAll(data, "answer");
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ root, "input.txt" });
    defer std.testing.allocator.free(input_path);

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\import std.fs;
        \\import {{ FsError }} from std.fs;
        \\
        \\fn load(): ?string!FsError {{
        \\    const value: ?string = try fs.read_file("{s}");
        \\    return value;
        \\}}
        \\
        \\fn main(): i32 {{
        \\    const value = load() catch (problem) {{ return 99; }};
        \\        if value is text {{
        \\            if text == "answer" {{
        \\                return 42;
        \\            }}
        \\        }}
        \\        return 1;
        \\}}
    , .{input_path});
    defer std.testing.allocator.free(source);

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, source_path, 42);
}

test "union is capture narrows in if" {
    const source =
        \\union Token {
        \\    ident: string;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    const token: Token = .ident("answer");
        \\    if token is .ident(name) {
        \\        if name == "answer" {
        \\            return 42;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("union_is_capture", source, 42);
}

test "result error is capture narrows in if" {
    const source =
        \\enum Failure {
        \\    failed;
        \\}
        \\
        \\fn produce(): i32!Failure {
        \\    throw Failure.failed;
        \\}
        \\
        \\fn main(): i32 {
        \\    return produce() catch (problem) {
        \\        if problem == Failure.failed { yield 42; }
        \\        yield 0;
        \\    };
        \\}
    ;

    try expectNamedNative("result_err_is_capture", source, 42);
}

test "result ok is capture narrows in if" {
    const source =
        \\enum Failure {
        \\    failed;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 42;
        \\}
    ;

    try expectNamedNative("result_ok_is_capture", source, 42);
}

test "native union is capture supports resource payloads" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    const token: Token = .user(User { age: 42, scores: list<i32>() });
        \\    if token is .user(user) {
        \\        return user.age;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_union_is_capture_resource.cy", source, 42);
}

test "native union is capture supports runtime string payloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const data = try compat.dirCreateFile(tmp.dir, "input.txt", .{});
        defer compat.closeFile(data);
        try compat.fileWriteAll(data, "answer");
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ root, "input.txt" });
    defer std.testing.allocator.free(input_path);

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\import std.fs;
        \\import {{ FsError }} from std.fs;
        \\
        \\union Token {{
        \\    ident: string;
        \\    eof;
        \\}}
        \\
        \\fn load(): Token!FsError {{
        \\    const token: Token = .ident(try fs.read_file("{s}"));
        \\    return token;
        \\}}
        \\
        \\fn main(): i32 {{
        \\    const token = load() catch (problem) {{ return 99; }};
        \\        if token is .ident(name) {{
        \\            if name == "answer" {{
        \\                return 42;
        \\            }}
        \\        }}
        \\        return 1;
        \\}}
    , .{input_path});
    defer std.testing.allocator.free(source);

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, source_path, 42);
}

test "native union switch supports payload and empty cases" {
    const source =
        \\union Token {
        \\    ident: string;
        \\    eof;
        \\}
        \\
        \\fn score(token: Token): i32 {
        \\    switch token {
        \\    .ident(name) => {
        \\        if name == "answer" {
        \\            return 42;
        \\        }
        \\        return 1;
        \\    }
        \\    .eof => {
        \\        return 0;
        \\    }
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return score(.ident("answer"));
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_union_switch_payload_and_empty.cy", source, 42);
}

test "native union switch supports resource payloads" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\fn produce(): Token {
        \\    return .user(User { age: 42, scores: list<i32>() });
        \\}
        \\
        \\fn main(): i32 {
        \\    switch produce() {
        \\    .user(user) => {
        \\        return user.age;
        \\    }
        \\    .eof => {
        \\        return 0;
        \\    }
        \\    }
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_union_switch_resource_payload.cy", source, 42);
}

test "native union projection supports payload reads" {
    const source =
        \\union Token {
        \\    ident: string;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    const token: Token = .ident("answer");
        \\    const name = token.ident;
        \\    if name == "answer" {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_union_projection_payload_read.cy", source, 42);
}

test "native union projection supports helper returned values" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    eof;
        \\}
        \\
        \\fn produce(): Token {
        \\    return .number(42);
        \\}
        \\
        \\fn main(): i32 {
        \\    const token = produce();
        \\    return token.number;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_union_projection_helper_return.cy", source, 42);
}

test "native union projection supports resource payload reads" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    const token: Token = .user(User { age: 42, scores: list<i32>() });
        \\    return token.user.age;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_union_projection_resource_payload_read.cy", source, 42);
}

test "native union projection supports helper returned resource payloads" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\fn produce(): Token {
        \\    return .user(User { age: 42, scores: list<i32>() });
        \\}
        \\
        \\fn main(): i32 {
        \\    const token = produce();
        \\    return token.user.age;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_union_projection_helper_resource_payload.cy", source, 42);
}

test "native union locals can be reassigned across resource payload and empty cases" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    var token: Token = .user(User { age: 10, scores: list<i32>() });
        \\    token = .eof();
        \\    token = .user(User { age: 42, scores: list<i32>() });
        \\    return token.user.age;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_union_reassign_resource_payload.cy", source, 42);
}

test "native union-containing struct locals survive scope cleanup with resource payloads" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    token: Token;
        \\}
        \\
        \\fn score(holder: Holder): i32 {
        \\    return holder.token.user.age;
        \\}
        \\
        \\fn main(): i32 {
        \\    const holder = Holder { token: .user(User { age: 42, scores: list<i32>() }) };
        \\    return score(holder);
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_struct_union_scope_cleanup_resource_payload.cy", source, 42);
}

test "native union-containing struct locals survive branch scope cleanup with resource payloads" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    token: Token;
        \\}
        \\
        \\fn main(): i32 {
        \\    if true {
        \\        const holder = Holder { token: .user(User { age: 42, scores: list<i32>() }) };
        \\        if holder.token.user.age == 42 {
        \\            return 42;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_struct_union_branch_scope_cleanup_resource_payload.cy", source, 42);
}

test "native union-containing struct locals survive loop scope cleanup with resource payloads" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    token: Token;
        \\}
        \\
        \\fn main(): i32 {
        \\    var i = 0;
        \\    while i < 1 {
        \\        const holder = Holder { token: .user(User { age: 42, scores: list<i32>() }) };
        \\        if holder.token.user.age == 42 {
        \\            i = i + 1;
        \\        }
        \\    }
        \\    return 42;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_struct_union_loop_scope_cleanup_resource_payload.cy", source, 42);
}

test "native union-containing struct locals survive continue with resource payloads" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    token: Token;
        \\}
        \\
        \\fn main(): i32 {
        \\    var i = 0;
        \\    while i < 2 {
        \\        const holder = Holder { token: .user(User { age: 42, scores: list<i32>() }) };
        \\        i = i + 1;
        \\        if holder.token.user.age == 42 {
        \\            continue;
        \\        }
        \\    }
        \\    return 42;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_struct_union_continue_resource_payload.cy", source, 42);
}

test "native union-containing struct locals can be reassigned across resource payload and empty cases" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    token: Token;
        \\}
        \\
        \\fn main(): i32 {
        \\    var holder = Holder { token: .user(User { age: 10, scores: list<i32>() }) };
        \\    holder = Holder { token: .eof() };
        \\    holder = Holder { token: .user(User { age: 42, scores: list<i32>() }) };
        \\    return holder.token.user.age;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_struct_union_reassign_resource_payload.cy", source, 42);
}

test "is none works for optionals" {
    const source =
        \\fn main(): i32 {
        \\    const value: ?i32 = none;
        \\    if value is none {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("optional_is_none", source, 42);
}

test "native result switch supports resource ok payloads" {
    const source =
        \\enum Status: i32 {
        \\    ok = 0,
        \\    failed,
        \\}
        \\
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\fn produce(): User!Status {
        \\    return User { age: 42, scores: list<i32>() };
        \\}
        \\
        \\fn main(): i32 {
        \\    const user = produce() catch (caught_status_2095) {
        \\        const ignored = caught_status_2095;
        \\        return 1;
        \\    };
        \\    return user.age;
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_result_switch_resource_ok.cy", source, 42);
}

test "native try supports resource ok payloads" {
    const source =
        \\enum Status: i32 {
        \\    ok = 0,
        \\    failed,
        \\}
        \\
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\fn produce(): User!Status {
        \\    return User { age: 42, scores: list<i32>() };
        \\}
        \\
        \\fn run(): i32!Status {
        \\    const user = try produce();
        \\    return user.age;
        \\}
        \\
        \\fn main(): i32 {
        \\    const value = run() catch (caught_status_2129) {
        \\        const ignored = caught_status_2129;
        \\        return 1;
        \\    };
        \\    return value;
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_try_resource_ok.cy", source, 42);
}

test "native try supports list ok payloads without leaks" {
    const source =
        \\enum Status: i32 {
        \\    ok = 0,
        \\    failed,
        \\}
        \\
        \\fn produce(): List<i32>!Status {
        \\    var values: List<i32> = list<i32>();
        \\    values.push(42);
        \\    return values;
        \\}
        \\
        \\fn run(): i32!Status {
        \\    const values = try produce();
        \\    const answer = values[0];
        \\    drop values;
        \\    return answer;
        \\}
        \\
        \\fn main(): i32 {
        \\    const value = run() catch (caught_status_2162) {
        \\        const ignored = caught_status_2162;
        \\        return 1;
        \\    };
        \\    return value;
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_try_list_ok_no_leak.cy", source, 42);
}

test "native union return supports list payloads without leaks" {
    const source =
        \\union Box {
        \\    values: List<i32>;
        \\    empty;
        \\}
        \\
        \\fn produce(): Box {
        \\    var values: List<i32> = list<i32>();
        \\    values.push(42);
        \\    return .values(values);
        \\}
        \\
        \\fn main(): i32 {
        \\    const box = produce();
        \\    switch box {
        \\    .values(values) => {
        \\        const answer = values[0];
        \\        drop values;
        \\        return answer;
        \\    }
        \\    .empty => {
        \\        return 1;
        \\    }
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_union_return_list_no_leak.cy", source, 42);
}

test "native try propagates err path" {
    const source =
        \\enum Status: i32 {
        \\    ok = 0,
        \\    failed,
        \\}
        \\
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\fn fail(): User!Status {
        \\    throw Status.failed;
        \\}
        \\
        \\fn run(): i32!Status {
        \\    const user = try fail();
        \\    return user.age;
        \\}
        \\
        \\fn main(): i32 {
        \\    const value = run() catch (caught_status_2228) {
        \\        if caught_status_2228 == Status.failed {
        \\            return 42;
        \\        }
        \\        return 1;
        \\    };
        \\    return value;
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_try_err_path.cy", source, 42);
}

test "optional success returns compose union construction absence and typed errors" {
    try expectNamedNative("optional_success_union",
        \\union Payload { number: i32; }
        \\enum Failure { invalid; }
        \\enum Color { green; }
        \\fn color(): ?Color!Failure { return .green; }
        \\fn classify(mode: i32): ?Payload!Failure {
        \\    if mode < 0 { throw Failure.invalid; }
        \\    if mode == 0 { return none; }
        \\    const value: Payload = .number(42);
        \\    return value;
        \\}
        \\fn literal(): ?Payload!Failure { return .number(42); }
        \\fn direct(): Payload!Failure { return .number(42); }
        \\fn forward(mode: i32): ?Payload!Failure { return classify(mode); }
        \\fn unpack(value: ?Payload): i32 {
        \\    if value is payload { if payload is .number(number) { return number; } }
        \\    return 0;
        \\}
        \\fn main(): i32 {
        \\    if unpack(classify(1) catch (code) => none) != 42 { return 1; }
        \\    const absent = classify(0) catch (code) { return 2; };
        \\    assert(absent is none);
        \\    if unpack(literal() catch (code) => none) != 42 { return 3; }
        \\    if unpack(forward(1) catch (code) => none) != 42 { return 4; }
        \\    var failed = false;
        \\    const recovered = forward(-1) catch (code) { failed = code == Failure.invalid; yield none; };
        \\    assert(failed and recovered is none);
        \\    const raw = direct() catch (code) { return 5; };
        \\    if raw is .number(number) { assert(number == 42); } else { return 6; }
        \\    const selected = color() catch (code) { return 7; };
        \\    if selected is value { assert(value == Color.green); } else { return 8; }
        \\    const contextual: ?Payload = .number(42);
        \\    assert(unpack(contextual) == 42);
        \\    return 42;
        \\}
    , 42);
}

test "optional success returns preserve generic owned and shared payloads" {
    try expectNamedNative("optional_success_resources",
        \\enum Failure { invalid; }
        \\struct Box { value: i32; }
        \\fn wrap<T>(value: T): ?T!Failure { return value; }
        \\fn text(): ?string!Failure { const number: i32 = 42; const value = $"value {number}"; return value; }
        \\fn real(): ?f64!Failure { return 1.5; }
        \\fn main(): i32 {
        \\    const number = wrap<i32>(42) catch (code) { return 1; };
        \\    if number is value { assert(value == 42); } else { return 2; }
        \\    const owner = wrap<^Box>(new Box { value: 7 }) catch (code) { return 3; };
        \\    if owner is box { assert(box.value == 7); } else { return 4; }
        \\    const message = text() catch (code) { return 5; };
        \\    if message is value { assert(value == "value 42"); } else { return 6; }
        \\    const float = real() catch (code) { return 7; };
        \\    if float is value { assert(value == 1.5); } else { return 8; }
        \\    return 42;
        \\}
    , 42);
}

const std = @import("std");

const compiler = @import("cyna").compiler;
const lexer = compiler.lexer;
const parser = compiler.parser;
const sema = compiler.sema;
const helpers = @import("../helpers.zig");

test "late semantic output allocation failures release transferred outputs" {
    const source =
        \\struct Box<T> { value: T; }
        \\fn identity<T>(value: T): T { return value; }
        \\fn main(): i32 { const box = Box<i32> { value: identity<i32>(42) }; return box.value; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "late_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    var baseline = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    const module = try sema.buildSir(baseline.allocator(), "late_oom.cy", program);
    module.deinit(baseline.allocator());
    try std.testing.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    try std.testing.expect(baseline.alloc_index >= 16);
    // Include collection transfer and canonical-type cloning at the end of a
    // real compilation, after both generic functions and structs were emitted.
    for (baseline.alloc_index - 16..baseline.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
            .resize_fail_index = 0,
        });
        try std.testing.expectError(error.OutOfMemory, sema.buildSir(failing.allocator(), "late_oom.cy", program));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

fn expectSemanticHoverContains(source_name: []const u8, source: []const u8, expected: []const []const u8) !void {
    const allocator = std.testing.allocator;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, source_name, source, tokens);
    defer program.deinit(allocator);

    const facts = try sema.collectSemanticHoverFacts(allocator, source_name, program, "");
    defer {
        for (facts) |fact| fact.deinit(allocator);
        allocator.free(facts);
    }

    for (expected) |needle| {
        var found = false;
        for (facts) |fact| {
            if (std.mem.indexOf(u8, fact.markdown, needle) != null) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("missing semantic hover fact containing `{s}`\n", .{needle});
            for (facts) |fact| {
                std.debug.print("  hover[{d}:{d}-{d}]: {s}\n", .{ fact.line, fact.start, fact.end, fact.markdown });
            }
            return error.TestExpectedEqual;
        }
    }
}

test "semantic failure does not poison following compilations" {
    try helpers.expectSemanticFailed(
        std.testing.allocator,
        "context_isolation_failure.cy",
        \\fn main(): i32 {
        \\    return missing_name;
        \\}
        ,
    );

    try helpers.expectSemanticSuccess(
        std.testing.allocator,
        "context_isolation_success.cy",
        \\fn identity<T>(value: T): T {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    return identity<i32>(42);
        \\}
        ,
    );

    try helpers.expectSemanticSuccess(
        std.testing.allocator,
        "context_isolation_plain_success.cy",
        \\fn main(): i32 {
        \\    return 7;
        \\}
        ,
    );
}

test "target layout state is isolated between semantic builds" {
    const source =
        \\pub const kernel_base: usize = 0xffff800000000000;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedWithOptions(
        std.testing.allocator,
        "context_isolation_riscv32_first.cy",
        source,
        .{ .target = "riscv32-none-elf" },
    );

    try helpers.expectSemanticSuccess(
        std.testing.allocator,
        "context_isolation_host.cy",
        source,
    );

    try helpers.expectSemanticFailedWithOptions(
        std.testing.allocator,
        "context_isolation_riscv32_second.cy",
        source,
        .{ .target = "riscv32-none-elf" },
    );
}

test "type-node arena is isolated after a type-heavy semantic failure" {
    try helpers.expectSemanticFailed(
        std.testing.allocator,
        "context_isolation_type_arena_failure.cy",
        \\enum Status { failed }
        \\
        \\fn broken(value: [:]?i32): i32!Status {
        \\    const nested: [:]?i32 = value;
        \\    return nested;
        \\}
        ,
    );

    try helpers.expectSemanticSuccess(
        std.testing.allocator,
        "context_isolation_type_arena_success.cy",
        \\enum Status { failed }
        \\
        \\fn identity<T>(value: T): T {
        \\    return value;
        \\}
        \\
        \\fn preserve(value: [:]?i32): [:]?i32!Status {
        \\    return identity<[:]?i32>(value);
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    );
}

test "borrow-summary caches are isolated after recursive analysis failure" {
    try helpers.expectSemanticFailed(
        std.testing.allocator,
        "context_isolation_borrow_summary_failure.cy",
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\fn store(xs: [:]i32, holder: &Holder, depth: i32): void {
        \\    if depth == 0 {
        \\        holder.view = xs;
        \\        return;
        \\    }
        \\    store(xs, holder, depth - 1);
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        store(fixed[..], &holder, 1);
        \\    }
        \\    return 0;
        \\}
        ,
    );

    try helpers.expectSemanticSuccess(
        std.testing.allocator,
        "context_isolation_borrow_summary_success.cy",
        \\fn first(xs: []const i32): i32 {
        \\    return xs[0];
        \\}
        \\
        \\fn forward(xs: []const i32): i32 {
        \\    return first(xs);
        \\}
        \\
        \\fn main(): i32 {
        \\    const values: [1]i32 = [1]i32 [ 7 ];
        \\    return forward(values[..]);
        \\}
        ,
    );
}

test "function-local isolated state is reset after semantic failure" {
    try helpers.expectSemanticFailed(
        std.testing.allocator,
        "context_isolation_isolated_failure.cy",
        \\var counter: i32 = 0;
        \\
        \\@concurrency.isolated
        \\fn worker(): i32 {
        \\    counter = 1;
        \\    return counter;
        \\}
        \\
        \\fn main(): i32 {
        \\    return worker();
        \\}
        ,
    );

    try helpers.expectSemanticSuccess(
        std.testing.allocator,
        "context_isolation_isolated_success.cy",
        \\var counter: i32 = 0;
        \\
        \\fn update(): i32 {
        \\    counter = 7;
        \\    return counter;
        \\}
        \\
        \\fn main(): i32 {
        \\    return update();
        \\}
        ,
    );
}

test "semantic hover collection reaches nested loop and branch locals" {
    try expectSemanticHoverContains(
        "context_hover_nested_control_flow.cy",
        \\fn main(): i32 {
        \\    var total: i32 = 0;
        \\    while total < 1 {
        \\        const loop_value: i32 = total + 1;
        \\        if loop_value == 1 {
        \\            const branch_value: i32 = loop_value + 40;
        \\            return branch_value + 1;
        \\        }
        \\        total = loop_value;
        \\    }
        \\    return 0;
        \\}
    ,
        &.{ "loop_value: i32", "branch_value: i32" },
    );
}

test "semantic hover collection reaches anonymous function bodies" {
    try expectSemanticHoverContains(
        "context_hover_function_expression.cy",
        \\fn apply(value: i32, callback: fn(i32): i32): i32 {
        \\    return callback(value);
        \\}
        \\
        \\fn main(): i32 {
        \\    return apply(41, fn(value) {
        \\        const nested_value: i32 = value + 1;
        \\        return nested_value;
        \\    });
        \\}
    ,
        &.{ "value: i32", "nested_value: i32" },
    );
}

test "semantic hover collection survives generic instantiation" {
    try expectSemanticHoverContains(
        "context_hover_generic.cy",
        \\fn identity<T>(value: T): T {
        \\    const result: T = value;
        \\    return result;
        \\}
        \\
        \\fn main(): i32 {
        \\    return identity<i32>(42);
        \\}
    ,
        &.{ "value: i32", "result: i32" },
    );
}

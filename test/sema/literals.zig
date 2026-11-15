const std = @import("std");

const helpers = @import("../helpers.zig");

test "generic call infers missing type from expected return" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "generic_return_context",
        \\fn empty<T>(): [:]T { return []; }
        \\fn identity<T>(value: T): T { return value; }
        \\fn main(): i32 {
        \\    const values: [:]i32 = empty();
        \\    const explicit = identity<[:]i32>([1, 2]);
        \\    const contextual: [:]i32 = identity([3, 4]);
        \\    const number: i32 = identity(42);
        \\    return number + values.len() as i32 + explicit.len() as i32 + contextual.len() as i32;
        \\}
    );
}

test "try passes payload context to generic call" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "generic_try_context",
        \\enum Failure { bad; }
        \\fn make<T>(): T!Failure { throw Failure.bad; }
        \\fn wrapped(): i32!Failure {
        \\    const value: i32 = try make();
        \\    return value;
        \\}
        \\fn main(): i32 { return 0; }
    );
}

test "generic return context rejects conflicting argument inference" {
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_return_conflict",
        \\fn identity<T>(value: T): T { return value; }
        \\fn main(): i32 {
        \\    const value: bool = identity(1 as i32);
        \\    return 0;
        \\}
    , "type mismatch");
}

test "generic call still requires context for an unbound return" {
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_return_missing_context",
        \\fn empty<T>(): [:]T { return []; }
        \\fn main(): i32 {
        \\    const values = empty();
        \\    return 0;
        \\}
    , "could not infer generic parameter");
}

test "try keeps error compatibility when return context infers payload" {
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_try_error_mismatch",
        \\enum First { bad; }
        \\enum Second { bad; }
        \\fn make<T>(): T!Second { throw Second.bad; }
        \\fn wrapped(): i32!First {
        \\    const value: i32 = try make();
        \\    return value;
        \\}
        \\fn main(): i32 { return 0; }
    , "error type mismatch");
}

test "inferred integer local converts for field assignment" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "inferred_integer_field_assignment",
        \\struct Info { count: usize; height: usize; }
        \\fn main(): i32 {
        \\    var info = Info { count: 0, height: 8 };
        \\    const rows_per_strip: usize = 2;
        \\    const count = 1 + (info.height - 1) / rows_per_strip;
        \\    info.count = count;
        \\    return info.count as i32;
        \\}
    );
}

test "discard binding accepts repeated values and consumes owned locals" {
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "discard_repeated_values",
        \\fn main(): i32 {
        \\    const _ = 40;
        \\    const _ = 41;
        \\    var values: List<i32> = list<i32>();
        \\    const _ = values;
        \\    return 42;
        \\}
    );
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "discard_moves_owned_local",
        \\fn main(): i32 {
        \\    var values: List<i32> = list<i32>();
        \\    const _ = values;
        \\    return values.len() as i32;
        \\}
    , "local `values` was handed off or dropped");
}

test "discard binding requires immutable untyped placeholder" {
    try helpers.expectParseFailedMessage(std.testing.allocator, "discard_mutable",
        \\fn main(): i32 { var _ = 42; return 0; }
    , "discard binding must use `const _`");
    try helpers.expectParseFailedMessage(std.testing.allocator, "discard_typed",
        \\fn main(): i32 { const _: i32 = 42; return 0; }
    , "discard binding cannot have a type annotation");
}

test "module-level floating constants are declarative copy values" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "global_float_constant",
        \\pub const maximum_channel_magnitude: f64 = 65536.0;
        \\const half: f64 = 0.5;
        \\const small: f32 = 1.0;
        \\fn main(): i32 {
        \\    if maximum_channel_magnitude * half == 32768.0 { return 42; }
        \\    return 0;
        \\}
    );
}

test "sequence literal factories infer contextual generic targets independently of names" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "sequence_factory_generic",
        \\struct Batch<T> { storage: [:]T; }
        \\@syntax.sequence_literal
        \\pub fn collect<T>(items: [:]T): Batch<T> { return Batch<T> { storage: items }; }
        \\fn wrap<T>(value: T): Batch<T> { return [value]; }
        \\fn empty(): Batch<i32> { return []; }
        \\fn consume(items: Batch<i32>): i32 { return items.storage[0]; }
        \\fn main(): i32 {
        \\    const a: Batch<i32> = [];
        \\    const b: Batch<i32> = [1, 2, 3];
        \\    const wrapped = wrap<i32>(7);
        \\    return consume([4, 5]);
        \\}
    );
}

test "sequence literal factories support standard List and nested contextual literals" {
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "sequence_factory_list",
        \\fn main(): i32 {
        \\    const empty: List<i32> = [];
        \\    const values: List<List<i32>> = [[], [1, 2]];
        \\    return 0;
        \\}
    );
}

test "sequence literal factories reject invalid signatures even when unused" {
    const declarations = [_][]const u8{
        "@syntax.sequence_literal pub fn bad(): i32 { return 0; }",
        "@syntax.sequence_literal pub fn bad(items: []i32): i32 { return 0; }",
        "@syntax.sequence_literal pub fn bad(items: &[:]i32): i32 { return 0; }",
        "@syntax.sequence_literal pub fn bad(items: [:]i32) {}",
        "@syntax.sequence_literal pub fn bad(items: [:]i32): void {}",
        "@syntax.sequence_literal pub fn bad(items: [:]i32, extra: i32): i32 { return 0; }",
        "type Nothing = void; @syntax.sequence_literal pub fn bad(items: [:]i32): Nothing {}",
        "@syntax.sequence_literal pub fn bad(items: [:]void): i32 { return 0; }",
    };
    for (declarations) |decl| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\nfn main(): i32 {{ return 0; }}", .{decl});
        defer std.testing.allocator.free(source);
        try helpers.expectSemanticFailedMessage(std.testing.allocator, "sequence_factory_bad_signature", source, "attribute `syntax.sequence_literal` requires");
    }
}

test "sequence literal factories reject invalid attribute placements and arguments" {
    const declarations = [_][]const u8{
        "@syntax.sequence_literal fn bad(items: [:]i32): i32 { return 0; }",
        "@syntax.sequence_literal pub struct Bad {}",
        "@syntax.sequence_literal pub const bad: i32 = 0;",
        "struct Bad { @syntax.sequence_literal pub fn bad(items: [:]i32): i32 { return 0; } }",
        "@syntax.sequence_literal(1) pub fn bad(items: [:]i32): i32 { return 0; }",
        "@syntax.sequence_literal @syntax.sequence_literal pub fn bad(items: [:]i32): i32 { return 0; }",
    };
    for (declarations) |decl| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\nfn main(): i32 {{ return 0; }}", .{decl});
        defer std.testing.allocator.free(source);
        try helpers.expectParseFailedMessage(std.testing.allocator, "sequence_factory_bad_attribute", source, "syntax.sequence_literal");
    }
}

test "sequence literal factories diagnose ambiguity and unresolved generics" {
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "sequence_factory_ambiguous",
        \\struct Batch { storage: [:]i32; }
        \\@syntax.sequence_literal
        \\pub fn first(items: [:]i32): Batch { return Batch { storage: items }; }
        \\@syntax.sequence_literal
        \\pub fn second(items: [:]i32): Batch { return Batch { storage: items }; }
        \\fn main(): i32 { const value: Batch = []; return 0; }
    , "ambiguous sequence literal: factories `.first` and `.second`");
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "sequence_factory_unresolved",
        \\struct Batch { storage: [:]i32; }
        \\@syntax.sequence_literal
        \\pub fn collect<T>(items: [:]i32): Batch { return Batch { storage: items }; }
        \\fn main(): i32 { const value: Batch = []; return 0; }
    , "cannot infer generic parameter `T`");
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "sequence_factory_unused_unresolved",
        \\struct Batch { storage: [:]i32; }
        \\@syntax.sequence_literal
        \\pub fn collect<T>(items: [:]i32): Batch { return Batch { storage: items }; }
        \\fn main(): i32 { return 0; }
    , "cannot infer generic parameter `T`");
}

test "sequence literal factories preserve native targets and require context" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "sequence_factory_native_priority",
        \\@syntax.sequence_literal
        \\pub fn native(items: [:]i32): [:]i32 { return items; }
        \\fn main(): i32 {
        \\    const fixed: [2]i32 = [1, 2];
        \\    const dense: [:]i32 = [];
        \\    const sparse: [;]i32 = [];
        \\    return fixed[0];
        \\}
    );
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "sequence_factory_needs_context",
        \\fn main(): i32 { const value = []; return 0; }
    , "cannot infer array literal type");
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "sequence_factory_element_mismatch",
        \\struct Batch { storage: [:]i32; }
        \\@syntax.sequence_literal
        \\pub fn collect(items: [:]i32): Batch { return Batch { storage: items }; }
        \\fn main(): i32 { const value: Batch = [true]; return 0; }
    , "type mismatch");
}

test "bare sequence literal in for header suggests a typed iterable" {
    try helpers.expectSemanticFailedHelp(std.testing.allocator, "for_bare_sequence_literal",
        \\fn main(): i32 {
        \\    for value in [1, 2, 3] { return value; }
        \\    return 0;
        \\}
    , "assign it to a typed binding before use");
    try helpers.expectSemanticSuccess(std.testing.allocator, "for_typed_sequence_literal",
        \\fn main(): i32 {
        \\    for value in [:]i32 [1, 2, 3] { return value; }
        \\    return 0;
        \\}
    );
}

test "sequence literal factories consume resource elements once" {
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "sequence_factory_moved_element",
        \\fn main(): i32 {
        \\    var resource: [:]i32 = [1];
        \\    const values: List<[:]i32> = [resource];
        \\    println(resource.len());
        \\    return 0;
        \\}
    , "handed off or dropped");
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "sequence_factory_duplicate_move",
        \\fn main(): i32 {
        \\    var resource: [:]i32 = [1];
        \\    const values: List<[:]i32> = [resource, resource];
        \\    return 0;
        \\}
    , "handed off or dropped");
}

test "sequence literal factories infer item-only parameters and transparent aliases" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "sequence_factory_item_inference",
        \\struct Count { value: usize; }
        \\@syntax.sequence_literal
        \\pub fn count_items<T>(items: [:]T): Count { return Count { value: items.len() }; }
        \\fn main(): i32 { const result: Count = [true, false]; return result.value as i32; }
    );
    try helpers.expectSemanticSuccess(std.testing.allocator, "sequence_factory_alias",
        \\struct Batch<T> { storage: [:]T; }
        \\type Collection<U> = Batch<U>;
        \\@syntax.sequence_literal
        \\pub fn collect<T>(items: [:]T): Collection<T> { return Batch<T> { storage: items }; }
        \\fn main(): i32 { const result: Batch<i32> = [1, 2]; return 0; }
    );
}

test "sequence literal factories filter candidates by declared generic constraints" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "sequence_factory_constraints",
        \\protocol Tagged { fn tag(self: &const Self): i32; }
        \\struct Plain {}
        \\struct Batch<T> { storage: [:]T; }
        \\@syntax.sequence_literal
        \\pub fn tagged<T: Tagged>(items: [:]T): Batch<T> { return Batch<T> { storage: items }; }
        \\@syntax.sequence_literal
        \\pub fn plain<T>(items: [:]T): Batch<T> { return Batch<T> { storage: items }; }
        \\fn main(): i32 { const result: Batch<Plain> = [Plain {}]; return 0; }
    );
}

test "dense array return literal uses the declared return type" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "dense_array_contextual_return",
        \\fn sample_header_bytes(): [:]u8 {
        \\    return [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 52, 0, 3];
        \\}
        \\fn main(): i32 {
        \\    const bytes = sample_header_bytes();
        \\    return bytes[0] as i32 - 0xCA;
        \\}
    );
}

test "usize accepts pointer-width unsigned hex literals" {
    const source =
        \\pub const kernel_base: usize = 0xffff800000000000;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticSuccess(
        std.testing.allocator,
        "usize_full_width_unsigned_hex_literal",
        source,
    );
}

test "usize rejects literals wider than the selected target pointer size" {
    const source =
        \\pub const kernel_base: usize = 0xffff800000000000;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessageWithOptions(
        std.testing.allocator,
        "usize_32_bit_target_rejects_64_bit_literal.cy",
        source,
        .{ .target = "riscv32-none-elf" },
        "does not fit usize",
    );
}

test "oversized integer literals require explicit fitting unsigned type" {
    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "oversized_integer_literal_untyped_rejected",
        \\fn main(): i32 {
        \\    const value = 0xffff800000000000;
        \\    return 0;
        \\}
    ,
        "requires an explicit unsigned integer type",
    );

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "oversized_integer_literal_small_unsigned_rejected",
        \\fn main(): i32 {
        \\    const value: u32 = 0xffff800000000000;
        \\    return 0;
        \\}
    ,
        "does not fit u32",
    );
}

test "rune literals reject invalid scalars and integer targets that cannot fit" {
    try helpers.expectParseFailedMessage(
        std.testing.allocator,
        "multi_scalar_rune_literal_rejected",
        \\fn main(): i32 {
        \\    const value = 'ab';
        \\    return 0;
        \\}
    ,
        "invalid rune literal",
    );

    try helpers.expectParseFailedMessage(
        std.testing.allocator,
        "surrogate_rune_literal_rejected",
        \\fn main(): i32 {
        \\    const value = '\u{D800}';
        \\    return 0;
        \\}
    ,
        "invalid rune literal",
    );

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "rune_literal_u8_fit_rejected",
        \\fn main(): i32 {
        \\    const value: u8 = '中';
        \\    return 0;
        \\}
    ,
        "does not fit u8",
    );
}

test "rune literal comparison uses concrete integer operand type" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "rune_literal_u8_comparison",
        \\fn main(): i32 {
        \\    const tag: u8 = 66;
        \\    if tag == 'B' { return 0; }
        \\    return 1;
        \\}
    );
}

test "sequence repeat fixed array length must match expected type" {
    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "sequence_repeat_fixed_array_length_mismatch",
        \\fn main(): i32 {
        \\    const values: [5]i32 = [1, 2] ** 3;
        \\    return values[0];
        \\}
    ,
        "array literal expects 5 items, got 6",
    );
}

test "reserved-looking construction methods do not customize literals" {
    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "reserved_sequence_construction_methods_are_ordinary",
        \\struct Bag {
        \\    pub fn __sequence_init(capacity: usize): Bag {
        \\        const ignored = capacity;
        \\        return Bag {};
        \\    }
        \\    pub fn __sequence_push(self: &Bag, value: i32): void {
        \\        const ignored_self = self;
        \\        const ignored_value = value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const bag: Bag = [];
        \\    return 0;
        \\}
    ,
        "array literal requires an expected fixed array, `[:]` array, or `[;]` storage target",
    );
}

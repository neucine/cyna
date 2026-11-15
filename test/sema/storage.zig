const std = @import("std");
const helpers = @import("../helpers.zig");

test "projected indexed assignment rejects const sparse roots" {
    const source =
        \\struct State {
        \\    slots: [;]i32;
        \\}
        \\
        \\struct Wrapper {
        \\    state: State;
        \\}
        \\
        \\fn main(): void {
        \\    const wrapper = Wrapper {
        \\        state: State { slots: [; 8] },
        \\    };
        \\    wrapper.state.slots[0] = 1;
        \\}
        \\
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "projected_sparse_array_const_assign",
        source,
        "cannot mutate const indexed place `wrapper`",
    );
}

test "Array remains reserved only for the removed generic spelling" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "array_named_struct",
        \\struct Array {
        \\    value: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    const array: Array = { value: 42 };
        \\    return array.value;
        \\}
    );

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "legacy_generic_array_rejected",
        \\fn main(): Array<i32> {
        \\    const value: Array<i32> = [1, 2];
        \\    const ignored = value;
        \\    return 0;
        \\}
    ,
        "`Array<T>` was replaced by `[:]T`",
    );
}

test "dense storage capacity must cover initializer length" {
    const source =
        \\fn main(): void {
        \\    var buf: [:]i32 = [: 2] [1, 2, 3];
        \\}
        \\
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "dense_storage_capacity_too_small",
        source,
        "dense storage capacity 2 is smaller than initializer length 3",
    );
}

test "sparse storage inline literal capacity must cover initializer length" {
    const source =
        \\fn main(): void {
        \\    var slots: [;]i32 = [; 2] [1, none, 3];
        \\}
        \\
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "sparse_array_capacity_too_small",
        source,
        "sparse storage capacity 2 is smaller than initializer length 3",
    );
}

test "sparse storage inline literals lower semantically" {
    const source =
        \\fn main(): void {
        \\    var contextual: [;]i32 = [1, none, 3];
        \\    var contextual_reserved: [;]i32 = [; 8] [1, none, 3];
        \\    var typed = [;]i32 [1, none, 3];
        \\    var typed_reserved = [; 8]i32 [1, none, 3];
        \\    var empty = [; 8]i32;
        \\}
        \\
    ;

    try helpers.expectSemanticSuccess(
        std.testing.allocator,
        "sparse_array_inline_literals_success",
        source,
    );
}

test "sparse storage keyed literal without capacity requires literal indices" {
    const source =
        \\fn main(): void {
        \\    const index = 3;
        \\    var slots: [;]i32 = { index: 42 };
        \\}
        \\
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "sparse_array_keyed_inferred_capacity_requires_literal_indices",
        source,
        "sparse keyed construction without explicit capacity requires integer literal indices",
    );
}

test "sparse storage keyed literals lower semantically" {
    const source =
        \\fn main(): void {
        \\    var contextual: [;]i32 = { 3: 40, 10: 2 };
        \\    var contextual_reserved: [;]i32 = [; 16] { 3: 40, 10: 2 };
        \\    var typed = [;]i32 { 3: 40, 10: 2 };
        \\    var typed_reserved = [; 16]i32 { 3: 40, 10: 2 };
        \\}
        \\
    ;

    try helpers.expectSemanticSuccess(
        std.testing.allocator,
        "sparse_array_keyed_literals_success",
        source,
    );
}

test "sparse storage keyed literal capacity must cover constant indices" {
    const source =
        \\fn main(): void {
        \\    var slots: [;]i32 = [; 2] { 2: 42 };
        \\}
        \\
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "sparse_array_keyed_capacity_too_small",
        source,
        "sparse storage keyed index 2 is outside capacity 2",
    );
}

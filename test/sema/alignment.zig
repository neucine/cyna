const std = @import("std");

const helpers = @import("../helpers.zig");

const expectSemanticFailedMessage = helpers.expectSemanticFailedMessage;
const expectSemanticSuccess = helpers.expectSemanticSuccess;

test "tuple type syntax resolves zero one and heterogeneous arities" {
    try expectSemanticSuccess(std.testing.allocator, "tuple_type_shapes",
        \\fn empty(value: ()): void {}
        \\fn single(value: (i32,)): void {}
        \\fn nested(value: (i32, (bool, f64))): void {}
        \\fn main(): void {}
    );
    try expectSemanticSuccess(std.testing.allocator, "tuple_grouped_type",
        \\fn grouped(value: (i32)): void {}
        \\fn main(): void {}
    );
    try expectSemanticFailedMessage(std.testing.allocator, "tuple_void_element",
        \\fn bad(value: (void, i32)): void {}
    , "tuple element cannot have type `void`");
}

test "tuple expressions infer ordered types and check contextual arity" {
    try expectSemanticSuccess(std.testing.allocator, "tuple_values",
        \\fn main(): i32 {
        \\    const empty: () = ();
        \\    const one: (i32,) = (42,);
        \\    const nested: (i32, (bool, i32)) = (1, (true, 2));
        \\    return 42;
        \\}
    );
    try expectSemanticFailedMessage(std.testing.allocator, "tuple_wrong_arity",
        \\fn main(): void { const value: (i32, bool) = (1,); }
    , "tuple expects 2 elements, got 1");
    try expectSemanticSuccess(std.testing.allocator, "tuple_resource_literal",
        \\fn main(): void { const value: ([:]i32,) = ([1],); const first = value.0; }
    );
}

test "tuple positional access checks nested positions and bounds" {
    try expectSemanticSuccess(std.testing.allocator, "tuple_nested_positions",
        \\fn main(): i32 {
        \\    const value: (i32, (i32, i32)) = (1, (40, 2));
        \\    return value.1.0 + value.1.1;
        \\}
    );
    try expectSemanticFailedMessage(std.testing.allocator, "tuple_position_out_of_bounds",
        \\fn main(): i32 { const value = (1, 2); return value.2; }
    , "tuple position 2 is out of bounds for 2 elements");
    try expectSemanticFailedMessage(std.testing.allocator, "tuple_position_must_be_integer",
        \\fn main(): i32 { const value = (1, 2); return value.foo; }
    , "tuple position must be a decimal integer");
}

test "tuple resource projection blocks owner invalidation" {
    const prefix =
        \\fn main(): i32 {
        \\    var pair: ([:]i32, i32) = ([40, 2], 0);
        \\    const first = pair.0;
    ;
    const suffix =
        \\    return first[0] + first[1];
        \\}
    ;
    try expectSemanticFailedMessage(std.testing.allocator, "tuple_borrow_drop", prefix ++
        \\    drop pair;
    ++ suffix, "while borrow `first` is live");
    try expectSemanticFailedMessage(std.testing.allocator, "tuple_borrow_move", prefix ++
        \\    const moved = pair;
    ++ suffix, "while borrow `first` is live");
    try expectSemanticFailedMessage(std.testing.allocator, "tuple_borrow_rebind", prefix ++
        \\    pair = ([1], 0);
    ++ suffix, "while borrow `first` is live");
}

test "tuple destructuring composes struct and indexed patterns" {
    try expectSemanticSuccess(std.testing.allocator, "tuple_nested_destructure",
        \\struct Row { x: i32; }
        \\fn main(): i32 {
        \\    const source: (i32, (Row, [1]i32)) = (1, (Row { x: 40 }, [1]i32 [2]));
        \\    const (ignored, ({ x: first }, [second])) = source;
        \\    return first + second;
        \\}
    );
    try helpers.expectParseFailedMessage(std.testing.allocator, "tuple_pattern_single_comma",
        \\fn main(): i32 { const source = (42,); const (value) = source; return value; }
    , "one-element tuple pattern requires a trailing comma");
}

test "tuple globals calls and returns resolve structurally" {
    try expectSemanticSuccess(std.testing.allocator, "tuple_global_call_return",
        \\const origin: (i32, i32) = (40, 2);
        \\fn pair(): (i32, i32) { return origin; }
        \\fn sum(value: (i32, i32)): i32 { return value.0 + value.1; }
        \\fn main(): i32 { return sum(pair()); }
    );
}

test "destructuring checks aliases nested paths and positional elements" {
    const source =
        \\struct Row { title: i32; }
        \\struct Doc { rows: [:]Row; }
        \\fn main(): i32 {
        \\    const document = Doc { rows: [Row { title: 40 }, Row { title: 2 }] };
        \\    const { rows: [{ title: first }, { title: second }] } = document;
        \\    return first + second;
        \\}
    ;
    try expectSemanticSuccess(std.testing.allocator, "destructure_nested_indexed", source);
}

test "destructuring owned leaves retain owner cleanup" {
    const prefix =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { inner: Inner; }
        \\fn consume(inner: Inner): void {}
    ;
    try expectSemanticFailedMessage(std.testing.allocator, "destructure_owned_handoff", prefix ++
        \\fn main(): void {
        \\    const owner = Outer { inner: Inner { items: [42] } };
        \\    const { inner } = owner;
        \\    consume(inner);
        \\}
    , "cannot hand off a projected owned value via function call");
    try expectSemanticFailedMessage(std.testing.allocator, "destructure_moves_source_owner", prefix ++
        \\fn main(): i32 {
        \\    const owner = Outer { inner: Inner { items: [42] } };
        \\    const { inner } = owner;
        \\    return owner.inner.items[0];
        \\}
    , "local `owner` was handed off or dropped");
}

test "destructuring does not transfer owned fields through a reference parameter" {
    try expectSemanticFailedMessage(std.testing.allocator, "destructure_ref_owned_leaf",
        \\struct Inner { items: [:]i32; }
        \\struct Outer { inner: Inner; }
        \\fn read(owner: &const Outer): i32 {
        \\    const { inner: { items } } = owner;
        \\    return items[0];
        \\}
    , "cannot hand off an alias");
}

test "destructuring rejects duplicate fields" {
    try helpers.expectParseFailedMessage(std.testing.allocator, "destructure_duplicate_field",
        \\struct Point { x: i32; y: i32; }
        \\fn main(): void {
        \\    const point = Point { x: 1, y: 2 };
        \\    const { x: a, x: b } = point;
        \\}
    , "duplicate field `x` in destructuring pattern");
    try helpers.expectParseFailedMessage(std.testing.allocator, "destructure_var_pattern",
        \\fn main(): void {
        \\    var [first] = [1];
        \\}
    , "destructuring declarations require `const`");
}

test "projected const bindings name stable owned struct fields transitively" {
    const source =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { inner: Inner; sibling: i32; }
        \\fn main(): i32 {
        \\    var owner = Outer { inner: Inner { items: [1, 2] }, sibling: 0 };
        \\    const field: Inner = owner.inner;
        \\    const same = field;
        \\    const items = same.items;
        \\    owner.sibling = 40;
        \\    return owner.sibling + (items.len() as i32);
        \\}
    ;
    try expectSemanticSuccess(std.testing.allocator, "projected_const_struct_fields", source);
}

test "projected const bindings retain checked named-union payloads" {
    const prefix =
        \\struct Payload { items: [:]i32; }
        \\union Boxed { payload: Payload; empty; }
    ;
    try expectSemanticSuccess(std.testing.allocator, "projected_union_payload", prefix ++
        \\fn main(): i32 {
        \\    var boxed: Boxed = .payload(Payload { items: [40, 2] });
        \\    const payload: Payload = boxed.payload;
        \\    const same = payload;
        \\    const items = same.items;
        \\    const answer = items[0] + items[1];
        \\    drop boxed;
        \\    return answer;
        \\}
    );
    try expectSemanticSuccess(std.testing.allocator, "projected_union_payload_direct_nested", prefix ++
        \\fn main(): i32 {
        \\    var boxed: Boxed = .payload(Payload { items: [40, 2] });
        \\    if boxed is .payload {
        \\        const items = boxed.payload.items;
        \\        return items[0] + items[1];
        \\    }
        \\    return 0;
        \\}
    );
    try expectSemanticFailedMessage(std.testing.allocator, "projected_union_payload_owner_drop", prefix ++
        \\fn main(): void {
        \\    var boxed: Boxed = .payload(Payload { items: [1] });
        \\    const payload = boxed.payload;
        \\    drop boxed;
        \\    println(payload.items.len());
        \\}
    , "while borrow `payload` is live");
    try expectSemanticFailedMessage(std.testing.allocator, "projected_union_payload_deferred_owner_drop", prefix ++
        \\fn main(): void {
        \\    var boxed: Boxed = .payload(Payload { items: [1] });
        \\    const payload = boxed.payload;
        \\    defer println(payload.items.len());
        \\    drop boxed;
        \\}
    , "while borrow `payload` is live");
    try expectSemanticFailedMessage(std.testing.allocator, "projected_union_payload_handoff", prefix ++
        \\fn consume(payload: Payload): void {}
        \\fn main(): void {
        \\    var boxed: Boxed = .payload(Payload { items: [1] });
        \\    const payload = boxed.payload;
        \\    consume(payload);
        \\}
    , "cannot hand off a projected owned value via function call");
}

test "indexed projected binding protects selected owned element" {
    const prefix =
        \\struct Inner { items: [:]i32; }
    ;
    try expectSemanticSuccess(std.testing.allocator, "indexed_projected_disjoint", prefix ++
        \\fn main(): i32 {
        \\    var entries: [:]Inner = [Inner { items: [1] }, Inner { items: [2] }];
        \\    const item = entries[0];
        \\    entries[1] = Inner { items: [3] };
        \\    return item.items[0];
        \\}
    );
    try expectSemanticSuccess(std.testing.allocator, "fixed_array_projected_disjoint", prefix ++
        \\fn main(): i32 {
        \\    var entries: [2]Inner = [Inner { items: [1] }, Inner { items: [2] }];
        \\    const item = entries[0];
        \\    entries[1] = Inner { items: [3] };
        \\    return item.items[0];
        \\}
    );
    try expectSemanticFailedMessage(std.testing.allocator, "indexed_projected_replace", prefix ++
        \\fn main(): void {
        \\    var entries: [:]Inner = [Inner { items: [1] }];
        \\    const item = entries[0];
        \\    entries[0] = Inner { items: [2] };
        \\    println(item.items.len());
        \\}
    , "overlapping borrow `item` is live");
    try expectSemanticFailedMessage(std.testing.allocator, "indexed_projected_dynamic_overlap", prefix ++
        \\fn read(index: usize): void {
        \\    var entries: [:]Inner = [Inner { items: [1] }, Inner { items: [2] }];
        \\    const item = entries[index];
        \\    entries[1] = Inner { items: [3] };
        \\    println(item.items.len());
        \\}
    , "overlapping borrow `item` is live");
    try expectSemanticFailedMessage(std.testing.allocator, "indexed_projected_resize", prefix ++
        \\fn main(): void {
        \\    var entries: [:]Inner = [Inner { items: [1] }];
        \\    const item = entries[0];
        \\    entries.push(Inner { items: [2] });
        \\    println(item.items.len());
        \\}
    , "overlapping borrow `item` is live");
    try expectSemanticFailedMessage(std.testing.allocator, "indexed_projected_drop", prefix ++
        \\fn main(): void {
        \\    var entries: [:]Inner = [Inner { items: [1] }];
        \\    const item = entries[0];
        \\    drop entries;
        \\    println(item.items.len());
        \\}
    , "while borrow `item` is live");
    try expectSemanticSuccess(std.testing.allocator, "indexed_projected_after_last_use", prefix ++
        \\fn main(): void {
        \\    var entries: [:]Inner = [Inner { items: [1] }];
        \\    const item = entries[0];
        \\    println(item.items.len());
        \\    drop entries;
        \\}
    );
    try expectSemanticFailedMessage(std.testing.allocator, "indexed_projected_deferred_use", prefix ++
        \\fn main(): void {
        \\    var entries: [:]Inner = [Inner { items: [1] }];
        \\    const item = entries[0];
        \\    defer println(item.items.len());
        \\    drop entries;
        \\}
    , "while borrow `item` is live");
    try expectSemanticSuccess(std.testing.allocator, "indexed_projected_branch_last_use", prefix ++
        \\fn main(): void {
        \\    var entries: [:]Inner = [Inner { items: [1] }];
        \\    const item = entries[0];
        \\    if entries.len() > 0 { println(item.items.len()); }
        \\    entries[0] = Inner { items: [2] };
        \\}
    );
    try expectSemanticFailedMessage(std.testing.allocator, "indexed_projected_future_branch_use", prefix ++
        \\fn main(): void {
        \\    var entries: [:]Inner = [Inner { items: [1] }];
        \\    const item = entries[0];
        \\    entries[0] = Inner { items: [2] };
        \\    if entries.len() > 0 { println(item.items.len()); }
        \\}
    , "overlapping borrow `item` is live");
    try expectSemanticFailedMessage(std.testing.allocator, "indexed_projected_derived_name_use", prefix ++
        \\fn main(): void {
        \\    var entries: [:]Inner = [Inner { items: [1] }];
        \\    const item = entries[0];
        \\    const same = item;
        \\    drop entries;
        \\    println(same.items.len());
        \\}
    , "while borrow `same` is live");
}

test "indexed projected slice binding retains the source owner" {
    const prefix =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { entries: [:]Inner; sibling: i32; }
    ;
    try expectSemanticSuccess(std.testing.allocator, "slice_projected_disjoint", prefix ++
        \\fn read(owner: &Outer, index: usize): i32 {
        \\    var entries = owner.entries[..];
        \\    const item = entries[index];
        \\    owner.sibling = 3;
        \\    return item.items[0];
        \\}
    );
    try expectSemanticSuccess(std.testing.allocator, "slice_projected_disjoint_call", prefix ++
        \\fn set_sibling(value: &i32): void { value = 3; }
        \\fn read(owner: &Outer): i32 {
        \\    var entries = owner.entries[..];
        \\    const item = entries[0];
        \\    set_sibling(&owner.sibling);
        \\    return item.items[0];
        \\}
    );
    try expectSemanticSuccess(std.testing.allocator, "slice_projected_after_last_use", prefix ++
        \\fn read(owner: &Outer): void {
        \\    var entries = owner.entries[..];
        \\    const item = entries[0];
        \\    println(item.items.len());
        \\    owner.entries[0] = Inner { items: [2] };
        \\}
    );
    try expectSemanticFailedMessage(std.testing.allocator, "slice_projected_replace", prefix ++
        \\fn read(owner: &Outer): void {
        \\    var entries = owner.entries[..];
        \\    const item = entries[0];
        \\    owner.entries[0] = Inner { items: [2] };
        \\    println(item.items.len());
        \\}
    , "overlapping borrow `item` is live");
    try expectSemanticFailedMessage(std.testing.allocator, "slice_projected_resize", prefix ++
        \\fn read(owner: &Outer): void {
        \\    var entries = owner.entries[..];
        \\    const item = entries[0];
        \\    owner.entries.push(Inner { items: [2] });
        \\    println(item.items.len());
        \\}
    , "overlapping borrow `item` is live");
    try expectSemanticFailedMessage(std.testing.allocator, "slice_projected_alias_write", prefix ++
        \\fn read(owner: &Outer): void {
        \\    var entries = owner.entries[..];
        \\    const item = entries[0];
        \\    entries[0] = Inner { items: [2] };
        \\    println(item.items.len());
        \\}
    , "overlapping borrow");
    try expectSemanticFailedMessage(std.testing.allocator, "slice_projected_new_alias", prefix ++
        \\fn read(owner: &Outer): void {
        \\    var entries = owner.entries[..];
        \\    const item = entries[0];
        \\    const alias = &owner.entries[0];
        \\    println(alias.items.len() + item.items.len());
        \\}
    , "overlapping borrow `item` is live");
    try expectSemanticFailedMessage(std.testing.allocator, "slice_projected_call_mutation", prefix ++
        \\fn replace(owner: &Outer): void { owner.entries[0] = Inner { items: [2] }; }
        \\fn read(owner: &Outer): void {
        \\    var entries = owner.entries[..];
        \\    const item = entries[0];
        \\    replace(owner);
        \\    println(item.items.len());
        \\}
    , "overlapping borrow `item` is live");
    try expectSemanticFailedMessage(std.testing.allocator, "slice_projected_method_mutation",
        \\struct Inner { items: [:]i32; }
        \\struct Outer {
        \\    entries: [:]Inner;
        \\    fn replace(self: &Outer): void { self.entries[0] = Inner { items: [2] }; }
        \\}
        \\fn read(owner: &Outer): void {
        \\    var entries = owner.entries[..];
        \\    const item = entries[0];
        \\    owner.replace();
        \\    println(item.items.len());
        \\}
    , "overlapping borrow `item` is live");
}

test "indexed projected binding follows borrowed slice parameters" {
    const prefix =
        \\struct Inner { items: [:]i32; }
    ;
    try expectSemanticSuccess(std.testing.allocator, "projected_slice_param", prefix ++
        \\fn read(classes: []Inner, index: usize): i32 {
        \\    const item = classes[index];
        \\    return item.items[0];
        \\}
    );
    try expectSemanticSuccess(std.testing.allocator, "projected_slice_carrier", prefix ++
        \\fn read(classes: []Inner, index: usize): i32 {
        \\    var class_view = classes;
        \\    const item = class_view[index];
        \\    return item.items[0];
        \\}
    );
    try expectSemanticFailedMessage(std.testing.allocator, "projected_slice_param_replace", prefix ++
        \\fn read(classes: []Inner): void {
        \\    const item = classes[0];
        \\    classes[0] = Inner { items: [2] };
        \\    println(item.items.len());
        \\}
    , "overlapping borrow `item` is live");
}

test "projected binding cannot outlive or discharge its owner" {
    const prefix =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { inner: Inner; }
    ;
    try expectSemanticFailedMessage(std.testing.allocator, "projected_owner_drop", prefix ++
        \\fn main(): void {
        \\    var owner = Outer { inner: Inner { items: [1] } };
        \\    const field = owner.inner;
        \\    drop owner;
        \\    println(field.items.len());
        \\}
    , "while borrow `field` is live");
    try expectSemanticFailedMessage(std.testing.allocator, "projected_local_drop", prefix ++
        \\fn main(): void {
        \\    var owner = Outer { inner: Inner { items: [1] } };
        \\    const field = owner.inner;
        \\    drop field;
        \\}
    , "cannot drop projected local `field`");
    try expectSemanticFailedMessage(std.testing.allocator, "projected_return", prefix ++
        \\fn escape(): Inner {
        \\    var owner = Outer { inner: Inner { items: [1] } };
        \\    const field = owner.inner;
        \\    return field;
        \\}
    , "cannot hand off a projected owned value via return");
}

test "projected binding blocks overlapping field replacement" {
    const source =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { inner: Inner; }
        \\fn main(): void {
        \\    var owner = Outer { inner: Inner { items: [1] } };
        \\    const field = owner.inner;
        \\    owner.inner = Inner { items: [2] };
        \\    println(field.items.len());
        \\}
    ;
    try expectSemanticFailedMessage(std.testing.allocator, "projected_field_replacement", source, "overlapping borrow `field` is live");
}

test "projected binding and writable aliases cannot overlap" {
    const prefix =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { inner: Inner; sibling: i32; }
    ;
    try expectSemanticFailedMessage(std.testing.allocator, "projected_then_writable_alias", prefix ++
        \\fn main(): void {
        \\    var owner = Outer { inner: Inner { items: [1] }, sibling: 0 };
        \\    const field = owner.inner;
        \\    const alias = &owner.inner;
        \\    alias.items.push(2);
        \\    println(field.items.len());
        \\}
    , "overlapping borrow `field` is live");
    try expectSemanticFailedMessage(std.testing.allocator, "writable_alias_then_projected", prefix ++
        \\fn main(): void {
        \\    var owner = Outer { inner: Inner { items: [1] }, sibling: 0 };
        \\    const alias = &owner.inner;
        \\    const field = owner.inner;
        \\    println(alias.items.len() + field.items.len());
        \\}
    , "writable alias `alias` may mutate it");
    try expectSemanticSuccess(std.testing.allocator, "disjoint_writable_alias_then_projected", prefix ++
        \\fn main(): void {
        \\    var owner = Outer { inner: Inner { items: [1] }, sibling: 0 };
        \\    const alias = &owner.sibling;
        \\    const field = owner.inner;
        \\    println(field.items.len());
        \\}
    );
}

test "projected binding rejects owned call and storage sinks" {
    const prefix =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { inner: Inner; }
        \\struct Holder { inner: Inner; }
        \\fn consume(inner: Inner): void {}
    ;
    try expectSemanticFailedMessage(std.testing.allocator, "projected_owned_call", prefix ++
        \\fn main(): void {
        \\    var owner = Outer { inner: Inner { items: [1] } };
        \\    const field = owner.inner;
        \\    consume(field);
        \\}
    , "cannot hand off a projected owned value via function call");
    try expectSemanticFailedMessage(std.testing.allocator, "projected_owned_storage", prefix ++
        \\fn main(): void {
        \\    var owner = Outer { inner: Inner { items: [1] } };
        \\    const field = owner.inner;
        \\    const holder = Holder { inner: field };
        \\}
    , "cannot hand off a projected owned value via struct literal field");
    try expectSemanticFailedMessage(std.testing.allocator, "projected_discard", prefix ++
        \\fn main(): void {
        \\    var owner = Outer { inner: Inner { items: [1] } };
        \\    const field = owner.inner;
        \\    const _ = field;
        \\}
    , "cannot hand off a projected owned value via discard");
}

test "projected binding excludes mutable locals and temporary fields" {
    const prefix =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { inner: Inner; }
    ;
    try expectSemanticFailedMessage(std.testing.allocator, "projected_mutable_binding", prefix ++
        \\fn main(): void {
        \\    var owner = Outer { inner: Inner { items: [1] } };
        \\    var field = owner.inner;
        \\}
    , "cannot hand off a projected owned value via binding");
    try expectSemanticFailedMessage(std.testing.allocator, "projected_temporary_binding", prefix ++
        \\fn make(): Outer { return Outer { inner: Inner { items: [1] } }; }
        \\fn main(): void {
        \\    const field = make().inner;
        \\}
    , "cannot hand off a projected owned value via binding");
}

test "alignment current checker rejects take from dense storage element" {
    const source =
        \\fn main(): void {
        \\    var xs: [:]i32 = [1, 2, 3];
        \\    const value = take xs[0];
        \\}
        \\
    ;

    try expectSemanticFailedMessage(
        std.testing.allocator,
        "alignment_take_dense_element_rejected",
        source,
        "`take` requires a writable optional place of type `?T`",
    );
}

test "alignment current checker accepts take from ref optional root" {
    const source =
        \\fn pull(slot: &?i32): ?i32 {
        \\    return take slot;
        \\}
        \\
    ;

    try expectSemanticSuccess(
        std.testing.allocator,
        "alignment_take_ref_optional_root_accepted",
        source,
    );
}

test "alignment current checker accepts take from ref optional dense slot" {
    const source =
        \\fn pull(slots: &[:]?i32): ?i32 {
        \\    return take slots[0];
        \\}
        \\
    ;

    try expectSemanticSuccess(
        std.testing.allocator,
        "alignment_take_ref_optional_dense_slot_accepted",
        source,
    );
}

test "alignment current checker accepts take from ref sparse slot" {
    const source =
        \\fn pull(slots: &[;]i32, i: i32): ?i32 {
        \\    return take slots[i];
        \\}
        \\
    ;

    try expectSemanticSuccess(
        std.testing.allocator,
        "alignment_take_ref_sparse_slot_accepted",
        source,
    );
}

test "alignment current checker rejects projected resource binding transfer" {
    const source =
        \\struct Inner {
        \\    items: [:]i32;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): void {
        \\    var outer = Outer {
        \\        inner: Inner { items: [1, 2, 3] }
        \\    };
        \\    const items = outer.inner.items;
        \\}
        \\
    ;

    try expectSemanticFailedMessage(
        std.testing.allocator,
        "alignment_projected_resource_binding_rejected",
        source,
        "use `[..]` for a slice/view borrow, `.clone()` when supported, or `take` where the projected place is detachable",
    );
}

test "alignment current checker accepts projected string binding" {
    const source =
        \\struct Method {
        \\    descriptor: string;
        \\}
        \\
        \\struct Holder {
        \\    method: Method;
        \\}
        \\
        \\fn main(): void {
        \\    var holder = Holder {
        \\        method: Method { descriptor: "()V" }
        \\    };
        \\    const descriptor = holder.method.descriptor;
        \\    assert(descriptor == "()V");
        \\}
        \\
    ;

    try expectSemanticSuccess(
        std.testing.allocator,
        "alignment_projected_string_binding_accepted",
        source,
    );
}

test "alignment current checker rejects projected resource assignment transfer" {
    const source =
        \\struct Inner {
        \\    items: [:]i32;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): void {
        \\    var outer = Outer {
        \\        inner: Inner { items: [1, 2, 3] }
        \\    };
        \\    var out: [:]i32 = [];
        \\    out = outer.inner.items;
        \\}
        \\
    ;

    try expectSemanticFailedMessage(
        std.testing.allocator,
        "alignment_projected_resource_assignment_rejected",
        source,
        "cannot hand off a projected owned value via assignment",
    );
}

test "alignment current checker rejects projected resource return transfer" {
    const source =
        \\struct Inner {
        \\    items: [:]i32;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): [:]i32 {
        \\    var outer = Outer {
        \\        inner: Inner { items: [1, 2, 3] }
        \\    };
        \\    return outer.inner.items;
        \\}
        \\
    ;

    try expectSemanticFailedMessage(
        std.testing.allocator,
        "alignment_projected_resource_return_rejected",
        source,
        "cannot hand off a projected owned value via return",
    );
}

test "alignment current checker rejects projected resource function call transfer" {
    const source =
        \\struct Inner {
        \\    items: [:]i32;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn consume(items: [:]i32): void {
        \\    if items.len() == 0 {
        \\        return;
        \\    }
        \\}
        \\
        \\fn main(): void {
        \\    var outer = Outer {
        \\        inner: Inner { items: [1, 2, 3] }
        \\    };
        \\    consume(outer.inner.items);
        \\}
        \\
    ;

    try expectSemanticFailedMessage(
        std.testing.allocator,
        "alignment_projected_resource_call_rejected",
        source,
        "cannot hand off a projected owned value via function call",
    );
}

test "alignment current checker rejects projected resource struct literal field transfer" {
    const source =
        \\struct Inner {
        \\    items: [:]i32;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\struct Holder {
        \\    items: [:]i32;
        \\}
        \\
        \\fn main(): void {
        \\    var outer = Outer {
        \\        inner: Inner { items: [1, 2, 3] }
        \\    };
        \\    const holder = Holder {
        \\        items: outer.inner.items
        \\    };
        \\}
        \\
    ;

    try expectSemanticFailedMessage(
        std.testing.allocator,
        "alignment_projected_resource_struct_literal_field_rejected",
        source,
        "cannot hand off a projected owned value via struct literal field",
    );
    try expectSemanticFailedMessage(
        std.testing.allocator,
        "alignment_projected_resource_struct_literal_field_guidance",
        source,
        "use `[..]` for a slice/view borrow, `.clone()` when supported, or `take` where the projected place is detachable",
    );
}

test "alignment current checker accepts projected resource copy binding" {
    const source =
        \\struct Inner {
        \\    items: [:]i32;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): void {
        \\    var outer = Outer {
        \\        inner: Inner { items: [1, 2, 3] }
        \\    };
        \\    const items = outer.inner.items.clone();
        \\}
        \\
    ;

    try expectSemanticSuccess(
        std.testing.allocator,
        "alignment_projected_resource_copy_binding_accepted",
        source,
    );
}

test "alignment current checker accepts projected resource copy assignment" {
    const source =
        \\struct Inner {
        \\    items: [:]i32;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): void {
        \\    var outer = Outer {
        \\        inner: Inner { items: [1, 2, 3] }
        \\    };
        \\    var out: [:]i32 = [];
        \\    out = outer.inner.items.clone();
        \\}
        \\
    ;

    try expectSemanticSuccess(
        std.testing.allocator,
        "alignment_projected_resource_copy_assignment_accepted",
        source,
    );
}

test "alignment current checker accepts projected resource copy return" {
    const source =
        \\struct Inner {
        \\    items: [:]i32;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): [:]i32 {
        \\    var outer = Outer {
        \\        inner: Inner { items: [1, 2, 3] }
        \\    };
        \\    return outer.inner.items.clone();
        \\}
        \\
    ;

    try expectSemanticSuccess(
        std.testing.allocator,
        "alignment_projected_resource_copy_return_accepted",
        source,
    );
}

test "alignment current checker accepts projected resource copy function call" {
    const source =
        \\struct Inner {
        \\    items: [:]i32;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn consume(items: [:]i32): void {
        \\    if items.len() == 0 {
        \\        return;
        \\    }
        \\}
        \\
        \\fn main(): void {
        \\    var outer = Outer {
        \\        inner: Inner { items: [1, 2, 3] }
        \\    };
        \\    consume(outer.inner.items.clone());
        \\}
        \\
    ;

    try expectSemanticSuccess(
        std.testing.allocator,
        "alignment_projected_resource_copy_call_accepted",
        source,
    );
}

test "break exits nearest loop and rejects function boundary escape" {
    try expectSemanticSuccess(std.testing.allocator, "break_loop_forms",
        \\fn main(): i32 {
        \\    var value = 0;
        \\    while true {
        \\        while true { break; }
        \\        if value == 0 { value = 1; break; }
        \\        continue;
        \\    }
        \\    const items: [:]i32 = [1, 2];
        \\    for item in items { if item == 1 { break; } }
        \\    return value;
        \\}
    );
    try expectSemanticFailedMessage(std.testing.allocator, "break_outside_loop",
        \\fn main(): void { break; }
    , "`break` is only valid inside a loop");
    try expectSemanticFailedMessage(std.testing.allocator, "break_in_nested_function",
        \\fn main(): void {
        \\    while true { const callback: fn(): void = fn(): void { break; }; break; }
        \\}
    , "`break` is only valid inside a loop");
}

test "break carries moves to the exit without feeding the loop backedge" {
    try expectSemanticSuccess(std.testing.allocator, "break_owned_handoff",
        \\fn consume(value: [:]i32): void {}
        \\fn main(): void {
        \\    const value: [:]i32 = [1];
        \\    while true { consume(value); break; }
        \\}
    );
    try expectSemanticFailedMessage(std.testing.allocator, "break_owned_reuse",
        \\fn consume(value: [:]i32): void {}
        \\fn main(): void {
        \\    const value: [:]i32 = [1];
        \\    while true { consume(value); break; }
        \\    consume(value);
        \\}
    , "handed off or dropped");
    try expectSemanticFailedMessage(std.testing.allocator, "break_conditional_owned_reuse",
        \\fn consume(value: [:]i32): void {}
        \\fn run(stop: bool): void {
        \\    const value: [:]i32 = [1];
        \\    while true { if stop { consume(value); break; } }
        \\    consume(value);
        \\}
    , "handed off or dropped");
}

test "enum alias cases resolve transparent chains and reject invalid namespaces" {
    try expectSemanticSuccess(std.testing.allocator, "enum_alias_chain",
        \\enum Status { ready = 7; done = 42; }
        \\type Alias = Status;
        \\type Chain = Alias;
        \\fn accept(value: Status): Status { return value; }
        \\fn main(): void { const value: Status = accept(Chain.done); }
    );
    try expectSemanticFailedMessage(std.testing.allocator, "enum_alias_unknown_case",
        \\enum Status { ready; }
        \\type Alias = Status;
        \\fn main(): void { const value = Alias.missing; }
    , "enum `Alias` has no case `missing`");
    try expectSemanticFailedMessage(std.testing.allocator, "enum_alias_scalar",
        \\type Scalar = i32;
        \\fn main(): void { const value = Scalar.ready; }
    , "unknown enum `Scalar`");
    try expectSemanticFailedMessage(std.testing.allocator, "enum_alias_distinct",
        \\type Distinct = distinct i32;
        \\fn main(): void { const value = Distinct.ready; }
    , "unknown enum `Distinct`");
}

test "optional success returns reject incompatible payloads and projected owners" {
    try expectSemanticFailedMessage(std.testing.allocator, "optional_success_wrong_payload",
        \\union Payload { number: i32; }
        \\enum Failure { invalid; }
        \\fn bad(): ?Payload!Failure { return true; }
    , "type mismatch");
    try expectSemanticFailedMessage(std.testing.allocator, "optional_success_unknown_case",
        \\union Payload { number: i32; }
        \\enum Failure { invalid; }
        \\fn bad(): ?Payload!Failure { return .missing(1); }
    , "has no case `missing`");
    try helpers.expectSemanticFailed(std.testing.allocator, "optional_success_projected_owner",
        \\struct Box { value: i32; }
        \\struct Holder { box: ^Box; }
        \\enum Failure { invalid; }
        \\fn bad(holder: &Holder): ?^Box!Failure { return holder.box; }
    );
}

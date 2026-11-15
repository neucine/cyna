const std = @import("std");
const helpers = @import("../helpers.zig");
const compat = @import("cyna").compat;

test "integer index syntax converts hook keys for reads writes and aliases" {
    const source =
        \\struct Bag {
        \\    values: [:]i32;
        \\    @syntax.index fn fetch(self: &const Bag, key: usize): &const i32 { return &self.values[key]; }
        \\    @syntax.index_set fn replace(self: &Bag, key: usize, value: i32): void { self.values[key] = value; }
        \\}
        \\fn main(): i32 {
        \\    var bag = Bag { values: [10, 20] };
        \\    const key: u16 = 1;
        \\    bag[key] = 42;
        \\    const item = &bag[key];
        \\    return item;
        \\}
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "integer_index_hook_key", "integer_index_hook_key.cy", source, 42);
}

test "integer index hook conversion traps when key does not fit" {
    const source =
        \\struct Small {
        \\    @syntax.index fn fetch(self: &const Small, key: u8): i32 { return key as i32; }
        \\}
        \\fn main(): i32 {
        \\    const item = Small {};
        \\    const key: i16 = -1;
        \\    return item[key];
        \\}
    ;
    try helpers.expectNativeFailure(std.testing.allocator, "integer_index_hook_key_trap.cy", source);
}

test "native renamed syntax roles support generic indexing mutation and iteration" {
    const source =
        \\struct Sequence<T> {
        \\    values: [:]T;
        \\    @syntax.index pub fn fetch(self: &const Sequence<T>, key: usize): &const T { return &self.values[key]; }
        \\    @syntax.index_set pub fn replace(self: &Sequence<T>, key: usize, value: T): void { self.values[key] = value; }
        \\    @syntax.iter pub fn begin(self: &const Sequence<T>): usize { return 0; }
        \\    @syntax.iter_has_next pub fn more(self: &const Sequence<T>, state: &const usize): bool { return state < self.values.len(); }
        \\    @syntax.iter_next pub fn advance(self: &const Sequence<T>, state: &usize): usize { const cursor: usize = state; state = state + 1; return cursor; }
        \\    @syntax.iter_item pub fn element(self: &const Sequence<T>, cursor: usize): &const T { return &self.values[cursor]; }
        \\}
        \\fn observe(value: &Sequence<i32>, calls: &i32): &Sequence<i32> { calls = calls + 1; return value; }
        \\fn main(): i32 {
        \\    var values = Sequence<i32> { values: [19, 22] };
        \\    var calls: i32 = 0;
        \\    observe(&values, &calls)[0] = 20;
        \\    assert(observe(&values, &calls)[0] == 20);
        \\    var total: i32 = 0;
        \\    for value in observe(&values, &calls) { total = total + value; }
        \\    assert(calls == 3);
        \\    return total;
        \\}
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "renamed_syntax_roles", "renamed_syntax_roles.cy", source, 42);
}

test "native fixed-array strings share through return and call flow" {
    const source =
        \\fn labels(): [2]string {
        \\    const ada = "Ada";
        \\    const names: [2]string = [ada, "Ken"];
        \\    return names;
        \\}
        \\
        \\fn first(names: [2]string): string {
        \\    return names[0];
        \\}
        \\
        \\fn main(): i32 {
        \\    const names = labels();
        \\    if first(names) == "Ada" {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "fixed_array_strings_return_call_share", "native_fixed_array_strings_return_call_share.cy", source, 42);
}

test "native fixed-array string reassignment drops old element" {
    const source =
        \\fn main(): i32 {
        \\    var names: [2]string = ["Ada", "Ken"];
        \\    names[0] = "Lin";
        \\    if names[0] == "Lin" {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "fixed_array_string_reassign_drops_old_element", "native_fixed_array_string_reassign_drops_old_element.cy", source, 42);
}

test "cstruct values support literals and field access" {
    const source =
        \\c struct Point {
        \\    x: i32;
        \\    y: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    const point = Point { x: 40, y: 2 };
        \\    return point.x + point.y;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "cstruct_values", "native_cstruct_values.cy", source, 42);
}

test "non-packed field aliases can mutate through ref params" {
    const source =
        \\struct Header {
        \\    len: i32;
        \\}
        \\
        \\fn set_len(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var header = Header { len: 0 };
        \\    set_len(&header.len);
        \\    return header.len;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "field_alias_supported", "native_field_alias_supported.cy", source, 42);
}

test "read-only aliases observe values and accept mutable alias narrowing" {
    const source =
        \\fn read(value: &const i32): i32 {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    var value: i32 = 42;
        \\    const mutable: &i32 = &value;
        \\    const readonly: &const i32 = mutable;
        \\    return read(readonly);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "readonly_alias_observation", "native_readonly_alias_observation.cy", source, 42);
}

test "read-only alias receivers call observation methods" {
    const source =
        \\struct Counter {
        \\    value: i32;
        \\
        \\    fn get(self: &const Counter): i32 {
        \\        return self.value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var counter = Counter { value: 42 };
        \\    const view: &const Counter = &counter;
        \\    return view.get();
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "readonly_alias_receiver", "native_readonly_alias_receiver.cy", source, 42);
}

test "alias carriers survive binding call return and field storage" {
    const source =
        \\struct View {
        \\    value: &const i32;
        \\}
        \\
        \\fn identity(value: &const i32): &const i32 {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    var value: i32 = 42;
        \\    const alias: &const i32 = identity(&value);
        \\    const view = View { value: alias };
        \\    const stored: &const i32 = view.value;
        \\    return stored;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "alias_carrier_contexts", "native_alias_carrier_contexts.cy", source, 42);
}

test "read-only syntax index field alias executes without capability widening" {
    const source =
        \\struct Item { value: i32; }
        \\
        \\struct Bag { items: [:]Item;
        \\    @syntax.index
        \\    fn index(self: &const Bag, index: usize): &const Item {
        \\        return &self.items[index];
        \\    }
        \\
        \\}
        \\
        \\
        \\
        \\fn expose(bag: &const Bag): &const i32 {
        \\    return &bag[0].value;
        \\}
        \\
        \\fn main(): i32 {
        \\    const bag = Bag { items: [Item { value: 42 }] };
        \\    const value: &const i32 = expose(&bag);
        \\    return value;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "readonly_syntax_index_field_alias", "native_readonly_syntax_index_field_alias.cy", source, 42);
}

test "writable syntax index field alias preserves writable capability" {
    const source =
        \\struct Item { value: i32; }
        \\
        \\struct Bag { target: &Item;
        \\    @syntax.index
        \\    fn index(self: &const Bag, index: usize): &Item {
        \\        const ignored = index;
        \\        return self.target;
        \\    }
        \\
        \\}
        \\
        \\
        \\
        \\fn set_value(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var item = Item { value: 0 };
        \\    const bag = Bag { target: &item };
        \\    set_value(&bag[0].value);
        \\    return item.value;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "writable_syntax_index_field_alias", "native_writable_syntax_index_field_alias.cy", source, 42);
}

test "nested non-packed field aliases can mutate through ref params" {
    const source =
        \\struct Inner {
        \\    age: i32;
        \\}
        \\
        \\struct User {
        \\    inner: Inner;
        \\}
        \\
        \\fn set_age(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { inner: Inner { age: 0 } };
        \\    set_age(&user.inner.age);
        \\    return user.inner.age;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "nested_field_alias_supported", "native_nested_field_alias_supported.cy", source, 42);
}

test "owned local field aliases can mutate through ref params" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn set_age(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = new User { age: 0 };
        \\    set_age(&user.age);
        \\    return user.age;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "owned_field_alias_supported", "native_owned_field_alias_supported.cy", source, 42);
}

test "live field alias still permits disjoint sibling field mutation" {
    const source =
        \\struct Pair {
        \\    left: i32;
        \\    right: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var pair = Pair { left: 7, right: 0 };
        \\    const left = &pair.left;
        \\    pair.right = 35;
        \\    return pair.left + pair.right;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "live_field_alias_permits_disjoint_sibling_field_mutation", "native_live_field_alias_permits_disjoint_sibling_field_mutation.cy", source, 42);
}

test "struct locals support direct field assignment" {
    const source =
        \\struct Header {
        \\    len: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var header = Header { len: 0 };
        \\    header.len = 42;
        \\    return header.len;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "struct_field_assign_local", "native_struct_field_assign_local.cy", source, 42);
}

test "struct ref params support direct field assignment" {
    const source =
        \\struct Header {
        \\    len: i32;
        \\}
        \\
        \\fn set_len(header: &Header): void {
        \\    header.len = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var header = Header { len: 0 };
        \\    set_len(&header);
        \\    return header.len;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "struct_field_assign_ref_param", "native_struct_field_assign_ref_param.cy", source, 42);
}

test "indexed aliases can mutate array elements through ref params" {
    const source =
        \\fn set_value(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: [2]i32 = [2]i32 [ 0, 1 ];
        \\    set_value(&values[0]);
        \\    return values[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "array_index_alias_supported", "native_array_index_alias_supported.cy", source, 42);
}

test "explicit mutable list element aliases can mutate through ref params" {
    const source =
        \\fn set_value(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: List<i32> = list_from<i32>([:]i32 [0, 1]);
        \\    set_value(values.get_mut(0));
        \\    return values[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "list_index_alias_supported", "native_list_index_alias_supported.cy", source, 42);
}

test "indexed aliases can mutate slice elements through ref params" {
    const source =
        \\fn set_value(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: [2]i32 = [2]i32 [ 0, 1 ];
        \\    var window: []i32 = values[..];
        \\    set_value(&window[0]);
        \\    return values[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "slice_index_alias_supported", "native_slice_index_alias_supported.cy", source, 42);
}

test "live index alias permits disjoint constant index mutation" {
    const source =
        \\fn main(): i32 {
        \\    var values: [2]i32 = [2]i32 [ 7, 0 ];
        \\    const first = &values[0];
        \\    values[1] = 35;
        \\    return values[0] + values[1];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "live_index_alias_permits_disjoint_constant_index_mutation", "native_live_index_alias_permits_disjoint_constant_index_mutation.cy", source, 42);
}

test "live slice view permits descendant element mutation" {
    const source =
        \\fn main(): i32 {
        \\    var values: [2]i32 = [2]i32 [ 7, 0 ];
        \\    const view = values[..];
        \\    values[1] = 35;
        \\    return view[0] + view[1];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "live_slice_view_permits_descendant_element_mutation", "native_live_slice_view_permits_descendant_element_mutation.cy", source, 42);
}

test "immutable aggregate carrier preserves borrowed field precision" {
    const source =
        \\struct Wrap {
        \\    view: []i32;
        \\}
        \\
        \\struct Pair {
        \\    left: []i32;
        \\    right: []i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var left_data: [1]i32 = [1]i32 [ 7 ];
        \\    var first_right: [1]i32 = [1]i32 [ 0 ];
        \\    var second_right: [1]i32 = [1]i32 [ 35 ];
        \\    var pair = Pair { left: left_data[..], right: first_right[..] };
        \\    const wrap = Wrap { view: pair.left };
        \\    const view = wrap.view;
        \\    pair.right = second_right[..];
        \\    return view[0] + pair.right[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "immutable_aggregate_carrier_preserves_borrowed_field_precision", "native_immutable_aggregate_carrier_preserves_borrowed_field_precision.cy", source, 42);
}

test "union payload capture preserves borrowed field precision" {
    const source =
        \\struct Pair {
        \\    left: []i32;
        \\    right: []i32;
        \\}
        \\
        \\union Token {
        \\    view: []i32;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    var left_data: [1]i32 = [1]i32 [ 7 ];
        \\    var first_right: [1]i32 = [1]i32 [ 0 ];
        \\    var second_right: [1]i32 = [1]i32 [ 35 ];
        \\    var pair = Pair { left: left_data[..], right: first_right[..] };
        \\    const token: Token = .view(pair.left);
        \\    switch token {
        \\    .view(view) => {
        \\        pair.right = second_right[..];
        \\        return view[0] + pair.right[0];
        \\    }
        \\    .eof => {
        \\        return 0;
        \\    }
        \\    }
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "union_payload_capture_preserves_borrowed_field_precision", "native_union_payload_capture_preserves_borrowed_field_precision.cy", source, 42);
}

test "optional payload capture preserves borrowed field precision" {
    const source =
        \\struct Wrap {
        \\    view: []i32;
        \\}
        \\
        \\struct Pair {
        \\    left: []i32;
        \\    right: []i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var left_data: [1]i32 = [1]i32 [ 7 ];
        \\    var first_right: [1]i32 = [1]i32 [ 0 ];
        \\    var second_right: [1]i32 = [1]i32 [ 35 ];
        \\    var pair = Pair { left: left_data[..], right: first_right[..] };
        \\    const maybe: ?Wrap = Wrap { view: pair.left };
        \\    if maybe is wrap {
        \\        pair.right = second_right[..];
        \\        return wrap.view[0] + pair.right[0];
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "optional_payload_capture_preserves_borrowed_field_precision", "native_optional_payload_capture_preserves_borrowed_field_precision.cy", source, 42);
}

test "error payload capture preserves borrowed field precision" {
    const source =
        \\struct Pair {
        \\    left: []i32;
        \\    right: []i32;
        \\}
        \\
        \\enum Status: i32 {
        \\    failed = 1;
        \\}
        \\
        \\fn capture(xs: []i32): []i32!Status {
        \\    return xs;
        \\}
        \\
        \\fn main(): i32 {
        \\    var left_data: [1]i32 = [1]i32 [ 7 ];
        \\    var first_right: [1]i32 = [1]i32 [ 0 ];
        \\    var second_right: [1]i32 = [1]i32 [ 35 ];
        \\    var pair = Pair { left: left_data[..], right: first_right[..] };
        \\    const view = capture(pair.left) catch (status) {
        \\        return status as i32;
        \\    };
        \\        pair.right = second_right[..];
        \\        return view[0] + pair.right[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "result_payload_capture_preserves_borrowed_field_precision", "native_result_payload_capture_preserves_borrowed_field_precision.cy", source, 42);
}

test "slice params can be returned directly" {
    const source =
        \\fn identity(xs: []const i32): []const i32 {
        \\    return xs;
        \\}
        \\
        \\fn main(): i32 {
        \\    const fixed: [3]i32 = [3]i32 [ 1, 2, 3 ];
        \\    const view = identity(fixed[..]);
        \\    return view[1];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "slice_param_return_identity", "native_slice_param_return_identity.cy", source, 2);
}

test "ref params forward as matching ref arguments" {
    const source =
        \\fn set_value(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn forward(value: &i32): void {
        \\    set_value(value);
        \\}
        \\
        \\fn main(): i32 {
        \\    var value: i32 = 0;
        \\    forward(&value);
        \\    return value;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "ref_param_forwarding", "native_ref_param_forwarding.cy", source, 42);
}

test "local slice ref bindings forward through ref params" {
    const source =
        \\fn replace(slot: &[]i32, value: []i32): void {
        \\    slot = value;
        \\}
        \\
        \\fn main(): i32 {
        \\    var first: [1]i32 = [1]i32 [ 42 ];
        \\    var second: [1]i32 = [1]i32 [ 7 ];
        \\    var view = first[..];
        \\    const slot = &view;
        \\    replace(slot, second[..]);
        \\    return view[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "local_slice_ref_bindings_forward_through_ref_params", "native_local_slice_ref_bindings_forward_through_ref_params.cy", source, 7);
}

test "local list ref bindings forward through ref params" {
    const source =
        \\fn append(values: &List<i32>): void {
        \\    values.push(42);
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: List<i32> = list<i32>();
        \\    const slot: &List<i32> = &values;
        \\    append(slot);
        \\    return values[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "local_list_ref_bindings_forward_through_ref_params", "native_local_list_ref_bindings_forward_through_ref_params.cy", source, 42);
}

test "call return provenance tracks only returned parameter" {
    const source =
        \\fn choose(first: []const i32, second: []const i32): []const i32 {
        \\    return second;
        \\}
        \\
        \\fn pass(second: []const i32): []const i32 {
        \\    const fixed: [1]i32 = [1]i32 [ 7 ];
        \\    return choose(fixed[..], second);
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [ 42 ];
        \\    return pass(seed[..])[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "call_return_provenance_tracks_only_returned_parameter", "native_call_return_provenance_tracks_only_returned_parameter.cy", source, 42);
}

test "recursive call return provenance tracks returned parameter" {
    const source =
        \\fn id(xs: []const i32, n: i32): []const i32 {
        \\    if n == 0 {
        \\        return xs;
        \\    }
        \\    return id(xs, n - 1);
        \\}
        \\
        \\fn main(): i32 {
        \\    const fixed: [1]i32 = [1]i32 [ 42 ];
        \\    return id(fixed[..], 2)[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "recursive_call_return_provenance_tracks_returned_parameter", "native_recursive_call_return_provenance_tracks_returned_parameter.cy", source, 42);
}

test "mutual recursive call return provenance tracks returned parameter" {
    const source =
        \\fn a(xs: []const i32, n: i32): []const i32 {
        \\    if n == 0 {
        \\        return xs;
        \\    }
        \\    return b(xs, n - 1);
        \\}
        \\
        \\fn b(xs: []const i32, n: i32): []const i32 {
        \\    if n == 0 {
        \\        return xs;
        \\    }
        \\    return a(xs, n - 1);
        \\}
        \\
        \\fn main(): i32 {
        \\    const fixed: [1]i32 = [1]i32 [ 42 ];
        \\    return a(fixed[..], 3)[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "mutual_recursive_call_return_provenance_tracks_returned_parameter", "native_mutual_recursive_call_return_provenance_tracks_returned_parameter.cy", source, 42);
}

test "branch join return provenance tracks shared parameter source" {
    const source =
        \\fn choose(xs: []const i32, flag: bool): []const i32 {
        \\    var current = xs;
        \\    if flag {
        \\        current = xs;
        \\    } else {
        \\        current = xs;
        \\    }
        \\    return current;
        \\}
        \\
        \\fn main(): i32 {
        \\    const fixed: [1]i32 = [1]i32 [ 42 ];
        \\    return choose(fixed[..], true)[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "branch_join_return_provenance_tracks_shared_parameter_source", "native_branch_join_return_provenance_tracks_shared_parameter_source.cy", source, 42);
}

test "local forwarding return provenance tracks shared parameter source" {
    const source =
        \\fn identity(xs: []const i32): []const i32 {
        \\    var tmp = xs;
        \\    return tmp;
        \\}
        \\
        \\fn main(): i32 {
        \\    const fixed: [1]i32 = [1]i32 [ 42 ];
        \\    return identity(fixed[..])[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "local_forwarding_return_provenance_tracks_shared_parameter_source", "native_local_forwarding_return_provenance_tracks_shared_parameter_source.cy", source, 42);
}

test "switch join return provenance tracks shared parameter source" {
    const source =
        \\enum Choice: i32 {
        \\    left = 0;
        \\    right = 1;
        \\}
        \\
        \\fn choose(xs: []const i32, choice: Choice): []const i32 {
        \\    var current = xs;
        \\    switch choice {
        \\    Choice.left => {
        \\        current = xs;
        \\    }
        \\    Choice.right => {
        \\        current = xs;
        \\    }
        \\    }
        \\    return current;
        \\}
        \\
        \\fn main(): i32 {
        \\    const fixed: [1]i32 = [1]i32 [ 42 ];
        \\    return choose(fixed[..], Choice.left)[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "switch_join_return_provenance_tracks_shared_parameter_source", "native_switch_join_return_provenance_tracks_shared_parameter_source.cy", source, 42);
}

test "loop join return provenance tracks shared parameter source" {
    const source =
        \\fn choose(xs: []const i32, flag: bool): []const i32 {
        \\    var current = xs;
        \\    var keep = flag;
        \\    while keep {
        \\        current = xs;
        \\        keep = false;
        \\    }
        \\    return current;
        \\}
        \\
        \\fn main(): i32 {
        \\    const fixed: [1]i32 = [1]i32 [ 42 ];
        \\    return choose(fixed[..], false)[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "loop_join_return_provenance_tracks_shared_parameter_source", "native_loop_join_return_provenance_tracks_shared_parameter_source.cy", source, 42);
}

test "aggregate return provenance tracks multiple stable borrow roots" {
    const source =
        \\struct Pair {
        \\    left: []const i32;
        \\    right: []const i32;
        \\}
        \\
        \\fn bundle(left: []const i32, right: []const i32): Pair {
        \\    return Pair { left: left, right: right };
        \\}
        \\
        \\fn main(): i32 {
        \\    const a: [1]i32 = [1]i32 [ 20 ];
        \\    const b: [1]i32 = [1]i32 [ 22 ];
        \\    const pair = bundle(a[..], b[..]);
        \\    return pair.left[0] + pair.right[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "aggregate_return_provenance_tracks_multiple_stable_borrow_roots", "native_aggregate_return_provenance_tracks_multiple_stable_borrow_roots.cy", source, 42);
}

test "method return provenance tracks only returned parameter" {
    const source =
        \\struct Picker {
        \\    value: i32;
        \\
        \\    fn choose(self: Picker, first: []const i32, second: []const i32): []const i32 {
        \\        return second;
        \\    }
        \\}
        \\
        \\fn pass(second: []const i32): []const i32 {
        \\    const picker = Picker { value: 1 };
        \\    const fixed: [1]i32 = [1]i32 [ 7 ];
        \\    return picker.choose(fixed[..], second);
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [ 42 ];
        \\    return pass(seed[..])[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "method_return_provenance_tracks_only_returned_parameter", "native_method_return_provenance_tracks_only_returned_parameter.cy", source, 42);
}

test "method return provenance tracks receiver without unrelated arg pollution" {
    const source =
        \\struct Holder {
        \\    view: []const i32;
        \\
        \\    fn get(self: Holder, extra: []const i32): []const i32 {
        \\        return self.view;
        \\    }
        \\}
        \\
        \\fn pass(view: []const i32): []const i32 {
        \\    const holder = Holder { view: view };
        \\    const fixed: [1]i32 = [1]i32 [ 7 ];
        \\    return holder.get(fixed[..]);
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [ 42 ];
        \\    return pass(seed[..])[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "method_return_provenance_tracks_receiver_without_arg_pollution", "native_method_return_provenance_tracks_receiver_without_arg_pollution.cy", source, 42);
}

test "transitive method return provenance tracks receiver without unrelated arg pollution" {
    const source =
        \\struct Holder {
        \\    view: []const i32;
        \\
        \\    fn get(self: Holder, extra: []const i32): []const i32 {
        \\        return self.view;
        \\    }
        \\
        \\    fn forward(self: Holder, extra: []const i32): []const i32 {
        \\        return self.get(extra);
        \\    }
        \\}
        \\
        \\fn pass(view: []const i32): []const i32 {
        \\    const holder = Holder { view: view };
        \\    const fixed: [1]i32 = [1]i32 [ 7 ];
        \\    return holder.forward(fixed[..]);
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [ 42 ];
        \\    return pass(seed[..])[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "transitive_method_return_provenance_tracks_receiver_without_arg_pollution", "native_transitive_method_return_provenance_tracks_receiver_without_arg_pollution.cy", source, 42);
}

test "projected receiver method return provenance tracks receiver without unrelated arg pollution" {
    const source =
        \\struct Holder {
        \\    view: []const i32;
        \\
        \\    fn get(self: Holder, extra: []const i32): []const i32 {
        \\        return self.view;
        \\    }
        \\}
        \\
        \\struct Wrapper {
        \\    holder: Holder;
        \\}
        \\
        \\fn pass(view: []const i32): []const i32 {
        \\    const wrapper = Wrapper { holder: Holder { view: view } };
        \\    const fixed: [1]i32 = [1]i32 [ 7 ];
        \\    return wrapper.holder.get(fixed[..]);
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [ 42 ];
        \\    return pass(seed[..])[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "projected_receiver_method_return_provenance_tracks_receiver_without_arg_pollution", "native_projected_receiver_method_return_provenance_tracks_receiver_without_arg_pollution.cy", source, 42);
}

test "scalar receiver-derived method args do not taint side-effect borrow summaries" {
    const source =
        \\struct Sink {
        \\    value: i32;
        \\}
        \\
        \\fn stash(n: i32, sink: &Sink): void {
        \\    sink.value = n;
        \\}
        \\
        \\struct Holder {
        \\    view: []const i32;
        \\
        \\    fn forward(self: Holder, sink: &Sink): void {
        \\        stash(self.view.len() as i32, sink);
        \\    }
        \\}
        \\
        \\fn run(sink: &Sink): void {
        \\    const fixed: [1]i32 = [1]i32 [ 42 ];
        \\    const holder = Holder { view: fixed[..] };
        \\    holder.forward(sink);
        \\}
        \\
        \\fn main(): i32 {
        \\    var sink = Sink { value: 0 };
        \\    run(&sink);
        \\    return sink.value;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "scalar_receiver_derived_method_args_do_not_taint_side_effect_borrow_summaries", "native_scalar_receiver_derived_method_args_do_not_taint_side_effect_borrow_summaries.cy", source, 1);
}

test "transitive scalar receiver-derived method args do not taint side-effect borrow summaries" {
    const source =
        \\struct Sink {
        \\    value: i32;
        \\}
        \\
        \\fn stash(n: i32, sink: &Sink): void {
        \\    sink.value = n;
        \\}
        \\
        \\fn forward_value(n: i32, sink: &Sink): void {
        \\    stash(n, sink);
        \\}
        \\
        \\struct Holder {
        \\    view: []const i32;
        \\
        \\    fn forward(self: Holder, sink: &Sink): void {
        \\        forward_value(self.view.len() as i32, sink);
        \\    }
        \\}
        \\
        \\fn run(sink: &Sink): void {
        \\    const fixed: [1]i32 = [1]i32 [ 42 ];
        \\    const holder = Holder { view: fixed[..] };
        \\    holder.forward(sink);
        \\}
        \\
        \\fn main(): i32 {
        \\    var sink = Sink { value: 0 };
        \\    run(&sink);
        \\    return sink.value;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "transitive_scalar_receiver_derived_method_args_do_not_taint_side_effect_borrow_summaries", "native_transitive_scalar_receiver_derived_method_args_do_not_taint_side_effect_borrow_summaries.cy", source, 1);
}

test "indexed scalar receiver-derived args do not taint side-effect borrow summaries" {
    const source =
        \\struct Sink {
        \\    value: i32;
        \\}
        \\
        \\fn stash(n: i32, sink: &Sink): void {
        \\    sink.value = n;
        \\}
        \\
        \\struct Holder {
        \\    view: []const i32;
        \\
        \\    fn forward(self: Holder, sink: &Sink): void {
        \\        stash(self.view[0], sink);
        \\    }
        \\}
        \\
        \\fn run(sink: &Sink): void {
        \\    const fixed: [1]i32 = [1]i32 [ 42 ];
        \\    const holder = Holder { view: fixed[..] };
        \\    holder.forward(sink);
        \\}
        \\
        \\fn main(): i32 {
        \\    var sink = Sink { value: 0 };
        \\    run(&sink);
        \\    return sink.value;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "indexed_scalar_receiver_derived_args_do_not_taint_side_effect_borrow_summaries", "native_indexed_scalar_receiver_derived_args_do_not_taint_side_effect_borrow_summaries.cy", source, 42);
}

test "casted scalar receiver-derived args do not taint side-effect borrow summaries" {
    const source =
        \\struct Sink {
        \\    value: i32;
        \\}
        \\
        \\fn stash(n: i32, sink: &Sink): void {
        \\    sink.value = n;
        \\}
        \\
        \\struct Holder {
        \\    view: []const i32;
        \\
        \\    fn forward(self: Holder, sink: &Sink): void {
        \\        stash(self.view.len() as i32, sink);
        \\    }
        \\}
        \\
        \\fn run(sink: &Sink): void {
        \\    const fixed: [1]i32 = [1]i32 [ 42 ];
        \\    const holder = Holder { view: fixed[..] };
        \\    holder.forward(sink);
        \\}
        \\
        \\fn main(): i32 {
        \\    var sink = Sink { value: 0 };
        \\    run(&sink);
        \\    return sink.value;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "casted_scalar_receiver_derived_args_do_not_taint_side_effect_borrow_summaries", "native_casted_scalar_receiver_derived_args_do_not_taint_side_effect_borrow_summaries.cy", source, 1);
}

test "method mixed return and side effect remains precise for stable sources" {
    const source =
        \\struct Holder {
        \\    view: []const i32;
        \\}
        \\
        \\struct Picker {
        \\    view: []const i32;
        \\
        \\    fn run(self: Picker, other: []const i32, holder: &Holder): []const i32 {
        \\        holder.view = other;
        \\        return self.view;
        \\    }
        \\}
        \\
        \\fn pass(view: []const i32, other: []const i32): []const i32 {
        \\    const picker = Picker { view: view };
        \\    var holder = Holder { view: other };
        \\    return picker.run(other, &holder);
        \\}
        \\
        \\fn main(): i32 {
        \\    const first: [1]i32 = [1]i32 [ 42 ];
        \\    const second: [1]i32 = [1]i32 [ 7 ];
        \\    return pass(first[..], second[..])[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "method_mixed_return_and_side_effect_remains_precise_for_stable_sources", "native_method_mixed_return_and_side_effect_remains_precise_for_stable_sources.cy", source, 42);
}

test "native struct field union projection supports payload reads" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    token: Token;
        \\}
        \\
        \\fn main(): i32 {
        \\    const holder = Holder { token: .number(42) };
        \\    return holder.token.number;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_struct_field_union_projection.cy", source, 42);
}

test "native helper-returned struct field union projection supports payload reads" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    token: Token;
        \\}
        \\
        \\fn produce(): Holder {
        \\    return Holder { token: .number(42) };
        \\}
        \\
        \\fn main(): i32 {
        \\    const holder = produce();
        \\    return holder.token.number;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_helper_struct_field_union_projection.cy", source, 42);
}

test "native indexed struct field union projection supports payload reads" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    tokens: [2]Token;
        \\}
        \\
        \\fn main(): i32 {
        \\    const holder = Holder { tokens: [.eof(), .number(42)] };
        \\    return holder.tokens[1].number;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_indexed_struct_field_union_projection.cy", source, 42);
}

test "native helper-returned indexed struct field union projection supports payload reads" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    tokens: [2]Token;
        \\}
        \\
        \\fn produce(): Holder {
        \\    return Holder { tokens: [.eof(), .number(42)] };
        \\}
        \\
        \\fn main(): i32 {
        \\    const holder = produce();
        \\    return holder.tokens[1].number;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_helper_indexed_struct_field_union_projection.cy", source, 42);
}
test "typed sequence initializers work for fixed arrays and runtime arrays" {
    const source =
        \\fn main(): i32 {
        \\    const fixed: [3]i32 = [3]i32 [10, 20, 12];
        \\    const zeros: [2]i32 = [2]i32 [];
        \\    const xs: [:]i32 = [1, 2, 3];
        \\    return fixed[0] + fixed[1] + fixed[2] + zeros[0] + zeros[1] + xs[0] + xs[1] + xs[2];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "typed_sequence_initializers", "native_typed_sequence_initializers.cy", source, 48);
}

test "string bytes views can drive for iteration" {
    const source =
        \\fn main(): i32 {
        \\    var total: i32 = 0;
        \\    for byte in "ABC".bytes() {
        \\        total = total + (byte as i32);
        \\    }
        \\    return total;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "string_bytes_for_iteration", "native_string_bytes_for_iteration.cy", source, 198);
}

test "const slice params accept string bytes views" {
    const source =
        \\fn sum(xs: []const u8): i32 {
        \\    var total: i32 = 0;
        \\    for byte in xs {
        \\        total = total + (byte as i32);
        \\    }
        \\    return total;
        \\}
        \\
        \\fn id(xs: []const u8): []const u8 {
        \\    return xs;
        \\}
        \\
        \\fn main(): i32 {
        \\    return sum(id("ABC".bytes()));
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "const_slice_param_accepts_string_bytes", "native_const_slice_param_accepts_string_bytes.cy", source, 198);
}

test "const slice params accept mutable slice arguments" {
    const source =
        \\fn sum(xs: []const u8): i32 {
        \\    var total: i32 = 0;
        \\    for byte in xs {
        \\        total = total + (byte as i32);
        \\    }
        \\    return total;
        \\}
        \\
        \\fn main(): i32 {
        \\    var bytes: [:]u8 = [65, 66, 67];
        \\    return sum(bytes[..]);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "const_slice_param_accepts_mutable_slice", "native_const_slice_param_accepts_mutable_slice.cy", source, 198);
}

test "string bytes view may stay in a local binding within the function" {
    const source =
        \\fn first(text: string): i32 {
        \\    const bytes = text.bytes();
        \\    return bytes[0] as i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    return first("ABC");
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "string_bytes_local_binding_is_ok", "native_string_bytes_local_binding_is_ok.cy", source, 65);
}

test "native projected global alias reads global storage" {
    const source =
        \\struct Item { value: i32; }
        \\
        \\const item: Item = Item { value: 42 };
        \\
        \\fn expose(): &const i32 { return &item.value; }
        \\
        \\fn main(): i32 {
        \\    const value = expose();
        \\    return value;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "projected_global_alias", "native_projected_global_alias.cy", source, 42);
}

test "native projected raw alias writes pointee storage" {
    const source =
        \\struct Item { value: i32; }
        \\
        \\fn write(value: &i32): void { value = 42; }
        \\
        \\fn main(): i32 {
        \\    var item = new Item { value: 0 };
        \\    const ptr: *Item = item.ptr();
        \\    unchecked {
        \\        write(&(*ptr).value);
        \\    }
        \\    return item.value;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "projected_raw_alias", "native_projected_raw_alias.cy", source, 42);
}

test "native nested collection query through indexed record preserves borrowed projections" {
    const source =
        \\struct Manifest { entries: List<i32>; }
        \\struct Entry { manifest: Manifest; }
        \\struct Catalog { entries: List<Entry>; }
        \\fn count(catalog: &const Catalog): usize {
        \\    return catalog.entries[0].manifest.entries.len();
        \\}
        \\fn main(): i32 {
        \\    var values = list<i32>();
        \\    values.push(7);
        \\    var catalog: Catalog = { entries: list<Entry>() };
        \\    catalog.entries.push(Entry { manifest: Manifest { entries: values } });
        \\    assert(catalog.entries[0].manifest.entries.len() == 1);
        \\    assert(count(&catalog) == 1);
        \\    assert(catalog.entries[0].manifest.entries[0] == 7);
        \\    assert(catalog.entries[0].manifest.entries.len() == 1);
        \\    const entry = &catalog.entries[0];
        \\    assert(entry.manifest.entries.len() == 1);
        \\    return 0;
        \\}
    ;
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "nested_collection_query.cy", source, 0);
}

test "native catch preserves aliases to resource values on success and failure" {
    const source =
        \\enum Error { missing; }
        \\struct Item { value: List<i32>; }
        \\fn borrow(item: &const Item, fail: bool): &const List<i32> ! Error {
        \\    if fail { throw Error.missing; }
        \\    return &item.value;
        \\}
        \\fn read(item: &const Item, fail: bool): usize {
        \\    const value = borrow(item, fail) catch (code) { return 0; };
        \\    return value.len();
        \\}
        \\fn choose(item: &const Item, fallback: &const Item, fail: bool): usize {
        \\    const value = borrow(item, fail) catch (code) { yield &fallback.value; };
        \\    return value.len();
        \\}
        \\fn main(): i32 {
        \\    var values = list<i32>(); values.push(7);
        \\    const item: Item = { value: values };
        \\    var others = list<i32>(); others.push(11); others.push(13);
        \\    const fallback: Item = { value: others };
        \\    assert(read(&item, false) == 1);
        \\    assert(read(&item, true) == 0);
        \\    assert(choose(&item, &fallback, false) == 1);
        \\    assert(choose(&item, &fallback, true) == 2);
        \\    assert(read(&item, false) == 1);
        \\    assert(item.value[0] == 7);
        \\    assert(fallback.value[1] == 13);
        \\    return 0;
        \\}
    ;
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "catch_resource_alias.cy", source, 0);
}

test "native switch expression captures support borrowed resource field projections" {
    const source =
        \\struct Element { children: List<usize>; }
        \\union Payload { element: Element; text: usize; }
        \\struct Node { payload: Payload; }
        \\struct Document { nodes: List<Node>; roots: List<usize>; }
        \\fn copy_ids(ids: &const List<usize>): List<usize> {
        \\    var output = list<usize>(); var i: usize = 0;
        \\    while i < ids.len() { output.push(ids[i]); i = i + 1; }
        \\    return output;
        \\}
        \\fn lower(document: &const Document): List<usize> {
        \\    const payload = &document.nodes[0].payload;
        \\    return switch payload {
        \\        .element(value) => copy_ids(&value.children);
        \\        .text(value) => copy_ids(&document.roots);
        \\    };
        \\}
        \\fn count(document: &const Document): usize {
        \\    const payload = &document.nodes[0].payload;
        \\    const size = switch payload {
        \\        .element(value) => value.children.len();
        \\        .text(value) => document.roots.len();
        \\    };
        \\    return size;
        \\}
        \\fn named(document: &const Document): List<usize> {
        \\    const payload = &document.nodes[0].payload;
        \\    return switch payload {
        \\        .element(value) => { const children = value.children; yield copy_ids(&children); }
        \\        .text(value) => copy_ids(&document.roots);
        \\    };
        \\}
        \\fn main(): i32 {
        \\    var children = list<usize>(); children.push(7); children.push(9);
        \\    var nodes = list<Node>(); nodes.push(Node { payload: .element(Element { children: children }) });
        \\    var roots = list<usize>(); roots.push(13);
        \\    const document: Document = { nodes: nodes, roots: roots };
        \\    var repeat = 0;
        \\    while repeat < 3 {
        \\        const result = lower(&document);
        \\        assert(result.len() == 2); assert(result[0] == 7); assert(result[1] == 9);
        \\        assert(count(&document) == 2);
        \\        const again = named(&document); assert(again[1] == 9);
        \\        repeat = repeat + 1;
        \\    }
        \\    var text_nodes = list<Node>(); text_nodes.push(Node { payload: .text(0) });
        \\    var text_roots = list<usize>(); text_roots.push(13);
        \\    const text: Document = { nodes: text_nodes, roots: text_roots };
        \\    const result = lower(&text); assert(result[0] == 13);
        \\    assert(count(&text) == 1);
        \\    return 0;
        \\}
    ;
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "switch_capture_resource_projection.cy", source, 0);
}

test "native alias success returns preserve carriers and result forwarding" {
    const source =
        \\enum Failure { missing; }
        \\fn borrow(values: &const [:]i32, fail: bool): &const [:]i32 ! Failure {
        \\    if fail { throw Failure.missing; }
        \\    return values;
        \\}
        \\fn local_alias(values: &const [:]i32): &const [:]i32 ! Failure {
        \\    const alias: &const [:]i32 = values;
        \\    return alias;
        \\}
        \\fn forward_call(values: &const [:]i32): &const [:]i32 ! Failure { return borrow(values, false); }
        \\fn forward_local(values: &const [:]i32): &const [:]i32 ! Failure {
        \\    const result = borrow(values, false);
        \\    return result;
        \\}
        \\fn copied<T>(value: &const T): T { return value; }
        \\fn borrowed_generic<T>(value: &const T): &const T ! Failure { return value; }
        \\fn writable(values: &[:]i32): &[:]i32 ! Failure { return values; }
        \\fn narrowed(values: &[:]i32): &const [:]i32 ! Failure { return values; }
        \\fn read(values: &const [:]i32, fail: bool): i32 {
        \\    const view = borrow(values, fail) catch (code) { return -1; };
        \\    assert(view[1] == 9);
        \\    const local = local_alias(values) catch (code) { return -2; };
        \\    const forwarded = forward_call(values) catch (code) { return -3; };
        \\    const named = forward_local(values) catch (code) { return -4; };
        \\    const result = borrow(values, false);
        \\    const via_generic = copied(&result) catch (code) { return -5; };
        \\    assert(via_generic[0] == view[0]);
        \\    const result_alias = borrowed_generic(&result) catch (code) { return -6; };
        \\    const recovered = result_alias catch (code) { return -7; };
        \\    assert(recovered[0] == view[0]);
        \\    assert(local[0] == view[0]); assert(forwarded[0] == view[0]); assert(named[0] == view[0]);
        \\    return view[0];
        \\}
        \\fn write(values: &[:]i32): void {
        \\    const view = writable(values) catch (code) { return; };
        \\    view[0] = 42;
        \\}
        \\fn observe(values: &[:]i32): i32 {
        \\    const view = narrowed(values) catch (code) { return -1; };
        \\    return view[0];
        \\}
        \\fn main(): i32 {
        \\    var values: [:]i32 = [7, 9];
        \\    assert(read(&values, false) == 7);
        \\    assert(read(&values, true) == -1);
        \\    assert(read(&values, false) == 7);
        \\    write(&values);
        \\    assert(observe(&values) == 42);
        \\    assert(read(&values, false) == 42);
        \\    assert(values[1] == 9);
        \\    return 0;
        \\}
    ;
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "alias_success_return.cy", source, 0);
}

test "native module-private nominal descriptors preserve List payloads and cleanup in either order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "a.cy", .data =
        \\struct Visit { id: usize; finish: bool; }
        \\union Token { number: usize; empty; }
        \\pub fn first(): usize {
        \\    var values = list<Visit>();
        \\    values.push(Visit { id: 7, finish: false });
        \\    var tokens = list<Token>();
        \\    tokens.push(.number(11));
        \\    const token = tokens.pop();
        \\    assert(token.number == 11);
        \\    const value = values.pop(); return value.id;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "b.cy", .data =
        \\struct Visit { id: usize; parent: string; finish: bool; }
        \\union Token { text: string; empty; }
        \\pub fn second(): string {
        \\    var values = list<Visit>();
        \\    values.push(Visit { id: 9, parent: string.from("fragment".bytes()), finish: false });
        \\    values.push(Visit { id: 10, parent: string.from("discarded".bytes()), finish: true });
        \\    const discarded = values.pop();
        \\    assert(discarded.parent == "discarded");
        \\    var tokens = list<Token>();
        \\    tokens.push(.text(string.from("owned union".bytes())));
        \\    const token = tokens.pop();
        \\    assert(token.text == "owned union");
        \\    const value = values.pop(); return value.parent;
        \\}
    });
    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);
    for ([_][]const u8{
        \\import { first } from .a;
        \\import { second } from .b;
        \\fn main(): i32 {
        \\    assert(first() == 7);
        \\    assert(second() == "fragment");
        \\    return 42;
        \\}
        ,
        \\import { second } from .b;
        \\import { first } from .a;
        \\fn main(): i32 {
        \\    assert(second() == "fragment");
        \\    assert(first() == 7);
        \\    return 42;
        \\}
        ,
    }) |source| {
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
        try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
    }
}

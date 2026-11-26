const std = @import("std");

const helpers = @import("../../helpers.zig");

fn expectNamedNative(comptime name: []const u8, source: []const u8, expected: i64) !void {
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, name, "native_" ++ name ++ ".cy", source, expected);
}

test "tuple types lower in native function signatures" {
    try expectNamedNative("tuple_signature_layout",
        \\fn read(value: (i32, (bool, f64))): i32 { return 42; }
        \\fn main(): i32 { return 42; }
    , 42);
}

test "tuple expressions construct empty single and nested aggregates" {
    try expectNamedNative("tuple_literal_layout",
        \\fn main(): i32 {
        \\    const empty: () = ();
        \\    const single: (i32,) = (42,);
        \\    const nested: (bool, (i32, i32)) = (true, (40, 2));
        \\    return 42;
        \\}
    , 42);
}

test "tuple positional access lowers nested scalar values" {
    try expectNamedNative("tuple_nested_scalar_projection",
        \\fn main(): i32 {
        \\    const value: (i32, (i32, i32)) = (1, (40, 2));
        \\    return value.1.0 + value.1.1;
        \\}
    , 42);
}

test "tuple resource positions retain their aggregate owner" {
    try expectNamedNative("tuple_resource_projection",
        \\fn main(): i32 {
        \\    const pair: ([:]i32, i32) = ([40, 2], 0);
        \\    const first = pair.0;
        \\    return first[0] + first[1];
        \\}
    , 42);
}

test "nested tuple resource pattern reads through its owner" {
    try expectNamedNative("tuple_nested_resource_pattern",
        \\fn main(): i32 {
        \\    const source: (i32, ([:]i32, i32)) = (0, ([40, 2], 0));
        \\    const (ignored, (items, unused)) = source;
        \\    return items[0] + items[1];
        \\}
    , 42);
}

test "tuple resource owner drops after projected final read" {
    try expectNamedNative("tuple_resource_drop_after_read",
        \\fn main(): i32 {
        \\    var pair: ([:]i32, i32) = ([40, 2], 0);
        \\    const first = pair.0;
        \\    const answer = first[0] + first[1];
        \\    drop pair;
        \\    return answer;
        \\}
    , 42);
}

test "owned tuple parameter projects its resource member" {
    try expectNamedNative("tuple_resource_parameter",
        \\fn read(value: ([:]i32, i32)): i32 {
        \\    const first = value.0;
        \\    return first[0] + first[1];
        \\}
        \\fn main(): i32 {
        \\    const pair: ([:]i32, i32) = ([40, 2], 0);
        \\    return read(pair);
        \\}
    , 42);
}

test "tuple destructuring composes nested struct and indexed places" {
    try expectNamedNative("tuple_nested_destructure",
        \\struct Row { x: i32; }
        \\fn main(): i32 {
        \\    const source: (i32, (Row, [1]i32)) = (1, (Row { x: 40 }, [1]i32 [2]));
        \\    const (ignored, ({ x: first }, [second])) = source;
        \\    return first + second;
        \\}
    , 42);
}

test "tuple parameters and returns preserve field order" {
    try expectNamedNative("tuple_call_and_return",
        \\fn pair(): (i32, i32) { return (40, 2); }
        \\fn sum(value: (i32, i32)): i32 { return value.0 + value.1; }
        \\fn main(): i32 { return sum(pair()); }
    , 42);
}

test "tuple constants have static native initializers" {
    try expectNamedNative("tuple_global_constant",
        \\const value: (i32, i32) = (40, 2);
        \\fn main(): i32 { return value.0 + value.1; }
    , 42);
}

test "destructuring renamed fields and nested indexed owned storage" {
    const source =
        \\struct Row { title: i32; }
        \\struct Doc { rows: [:]Row; }
        \\fn main(): i32 {
        \\    const document = Doc { rows: [Row { title: 40 }, Row { title: 2 }] };
        \\    const { rows: [{ title: first }, { title: second }] } = document;
        \\    return first + second;
        \\}
    ;
    try expectNamedNative("destructure_nested_indexed_owned", source, 42);
}

test "destructuring reads borrowed struct fields" {
    const source =
        \\struct Row { title: i32; }
        \\fn read(row: &const Row): i32 {
        \\    const { title: value } = row;
        \\    return value;
        \\}
        \\fn main(): i32 {
        \\    const row = Row { title: 42 };
        \\    return read(&row);
        \\}
    ;
    try expectNamedNative("destructure_borrowed_field", source, 42);
}

test "destructuring indexed tracked slice view retains its owner" {
    const source =
        \\struct Row { items: [:]i32; }
        \\struct Doc { rows: [:]Row; }
        \\fn read(doc: &Doc): i32 {
        \\    var view = doc.rows[..];
        \\    const [first] = view;
        \\    return first.items[0];
        \\}
        \\fn main(): i32 {
        \\    var doc = Doc { rows: [Row { items: [42] }] };
        \\    return read(&doc);
        \\}
    ;
    try expectNamedNative("destructure_tracked_slice_view", source, 42);
}

test "destructuring a projected source retains the original owner" {
    const source =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { inner: Inner; sibling: i32; }
        \\fn main(): i32 {
        \\    var owner = Outer { inner: Inner { items: [40] }, sibling: 2 };
        \\    const { items } = owner.inner;
        \\    owner.sibling = 2;
        \\    return items[0] + owner.sibling;
        \\}
    ;
    try expectNamedNative("destructure_projected_source", source, 42);
}

test "projected owned struct fields read through one owner" {
    const source =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { inner: Inner; sibling: i32; }
        \\fn main(): i32 {
        \\    var owner = Outer { inner: Inner { items: [4, 5] }, sibling: 0 };
        \\    const field = owner.inner;
        \\    const same = field;
        \\    const items = same.items;
        \\    owner.sibling = 40;
        \\    return owner.sibling + (items.len() as i32);
        \\}
    ;
    try expectNamedNative("projected_owned_struct_fields", source, 42);
}

test "projected union payload reads through one owner" {
    const source =
        \\struct Payload { items: [:]i32; }
        \\union Boxed { payload: Payload; empty; }
        \\fn main(): i32 {
        \\    var boxed: Boxed = .payload(Payload { items: [40, 2] });
        \\    const payload = boxed.payload;
        \\    const same = payload;
        \\    const items = same.items;
        \\    const answer = items[0] + items[1];
        \\    drop boxed;
        \\    return answer;
        \\}
    ;
    try expectNamedNative("projected_union_payload", source, 42);
}

test "narrowed union payload line can be bound directly" {
    const source =
        \\struct Payload { items: [:]i32; }
        \\union Boxed { payload: Payload; empty; }
        \\fn main(): i32 {
        \\    var boxed: Boxed = .payload(Payload { items: [40, 2] });
        \\    if boxed is .payload {
        \\        const items = boxed.payload.items;
        \\        return items[0] + items[1];
        \\    }
        \\    return 0;
        \\}
    ;
    try expectNamedNative("projected_union_payload_narrowed", source, 42);
}

test "indexed projected binding captures selected element once" {
    const source =
        \\struct Inner { items: [:]i32; }
        \\fn main(): i32 {
        \\    var entries: [:]Inner = [Inner { items: [42] }, Inner { items: [7] }];
        \\    var index: usize = 0;
        \\    const item = entries[index];
        \\    index = 1;
        \\    return item.items[0];
        \\}
    ;
    try expectNamedNative("indexed_projected_captured_element", source, 42);
}

test "indexed projected slice binding captures element through writable owner" {
    const source =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { entries: [:]Inner; sibling: i32; }
        \\fn read(owner: &Outer): i32 {
        \\    var entries = owner.entries[..];
        \\    var index: usize = 0;
        \\    const item = entries[index];
        \\    index = 1;
        \\    owner.sibling = 3;
        \\    return item.items[0] + owner.sibling;
        \\}
        \\fn main(): i32 {
        \\    var owner = Outer { entries: [Inner { items: [39] }, Inner { items: [7] }], sibling: 0 };
        \\    return read(&owner);
        \\}
    ;
    try expectNamedNative("indexed_projected_slice_capture", source, 42);
}

test "indexed projected owner drops after its final read" {
    const source =
        \\struct Inner { items: [:]i32; }
        \\fn main(): i32 {
        \\    var entries: [:]Inner = [Inner { items: [42] }];
        \\    const item = entries[0];
        \\    const answer = item.items[0];
        \\    drop entries;
        \\    return answer;
        \\}
    ;
    try expectNamedNative("indexed_projected_owner_drop_after_use", source, 42);
}

test "cloning a projected field creates an independent owner" {
    const source =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { inner: Inner; }
        \\fn make(): [:]i32 {
        \\    var owner = Outer { inner: Inner { items: [42] } };
        \\    const field = owner.inner;
        \\    const items = field.items;
        \\    return items.clone();
        \\}
        \\fn main(): i32 {
        \\    const copied = make();
        \\    return copied[0];
        \\}
    ;
    try expectNamedNative("projected_field_clone_owns_result", source, 42);
}

test "projected field survives branch and loop reads before owner cleanup" {
    const source =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { inner: Inner; }
        \\fn main(): i32 {
        \\    var owner = Outer { inner: Inner { items: [1, 2] } };
        \\    var total = 38;
        \\    while total < 42 {
        \\        const field = owner.inner;
        \\        total = total + (field.items.len() as i32);
        \\    }
        \\    if total == 42 {
        \\        const field = owner.inner;
        \\        return total + (field.items[0] - 1);
        \\    }
        \\    return 0;
        \\}
    ;
    try expectNamedNative("projected_field_branch_loop", source, 42);
}

test "projected field survives defer and error propagation" {
    const source =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { inner: Inner; }
        \\enum Problem { failed; }
        \\fn fail(): void!Problem { throw Problem.failed; }
        \\fn run(): i32!Problem {
        \\    var owner = Outer { inner: Inner { items: [42] } };
        \\    const field = owner.inner;
        \\    defer println(field.items.len());
        \\    try fail();
        \\    return field.items[0];
        \\}
        \\fn main(): i32 {
        \\    return run() catch (problem) { const ignored = problem; return 42; };
        \\}
    ;
    try expectNamedNative("projected_field_defer_try", source, 42);
}

test "projected field survives loop continue" {
    const source =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { inner: Inner; }
        \\fn main(): i32 {
        \\    var owner = Outer { inner: Inner { items: [42] } };
        \\    var count = 0;
        \\    while count < 2 {
        \\        const field = owner.inner;
        \\        count = count + 1;
        \\        if count < 2 { continue; }
        \\        if field.items[0] != 42 { return 0; }
        \\    }
        \\    return owner.inner.items[0];
        \\}
    ;
    try expectNamedNative("projected_field_loop_edges", source, 42);
}

test "field assignment capture transfers the displaced resource" {
    const source =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { inner: Inner; }
        \\fn main(): i32 {
        \\    var outer = Outer { inner: Inner { items: [1, 2] } };
        \\    outer.inner.items = [42] @ const old;
        \\    return old[0] + outer.inner.items[0];
        \\}
    ;

    try expectNamedNative("field_capture_displaced_resource", source, 43);
}

test "generic field assignment capture preserves the old field origin" {
    const source =
        \\struct Box<T> { value: T; }
        \\fn replace<T>(box: &Box<T>, next: T): T {
        \\    box.value = next @ const old;
        \\    return old;
        \\}
        \\fn main(): i32 {
        \\    var box = Box<i32> { value: 1 };
        \\    return replace(&box, 42) + box.value;
        \\}
    ;

    try expectNamedNative("generic_field_capture", source, 43);
}

test "mutable field assignment capture binds a writable old value" {
    const source =
        \\struct Box { value: i32; }
        \\fn main(): i32 {
        \\    var box = Box { value: 1 };
        \\    box.value = 42 @ var old;
        \\    old = old + 1;
        \\    return box.value + old;
        \\}
    ;

    try expectNamedNative("mutable_field_capture", source, 44);
}

test "field assignment capture preserves shared string values" {
    const source =
        \\struct Box { label: string; }
        \\fn main(): i32 {
        \\    var box = Box { label: "old" };
        \\    box.label = "new" @ const old;
        \\    if old == "old" and box.label == "new" { return 42; }
        \\    return 1;
        \\}
    ;

    try expectNamedNative("field_capture_shared_string", source, 42);
}

test "field assignment capture rejects an existing local name" {
    const source =
        \\struct Box { value: i32; }
        \\fn main(): i32 {
        \\    var box = Box { value: 1 };
        \\    const old = 0;
        \\    box.value = 42 @ const old;
        \\    return old;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "field_capture_existing_local", source, "assignment capture requires a new named local");
}

test "failed replacement leaves the field value in place" {
    const source =
        \\enum Problem { failed }
        \\struct Box { value: i32; }
        \\fn replacement(): i32!Problem { throw Problem.failed; }
        \\fn replace(box: &Box): void!Problem {
        \\    box.value = try replacement() @ const old;
        \\    const _ = old;
        \\    return;
        \\}
        \\fn main(): i32 {
        \\    var box = Box { value: 42 };
        \\    replace(&box) catch (problem) {
        \\        const ignored = problem;
        \\        return box.value;
        \\    };
        \\    return 0;
        \\}
    ;

    try expectNamedNative("field_capture_failed_replacement", source, 42);
}

test "resource field mutation through indexed container element works" {
    const source =
        \\struct User {
        \\    scores: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var users: List<User> = list<User>();
        \\    users.push(User { scores: list<i32>() });
        \\    users[0].scores.push(42);
        \\    return users[0].scores[0];
        \\}
    ;

    try expectNamedNative("indexed_resource_field_mutation", source, 42);
}

test "borrowed receiver through indexed field path lowers without leaking path storage" {
    const source =
        \\struct Method {
        \\    access: i32;
        \\
        \\    fn is_static(self: &const Method): bool {
        \\        return self.access == 8;
        \\    }
        \\}
        \\
        \\struct Class {
        \\    methods: List<Method>;
        \\
        \\    fn method_index(self: &const Class): i32 {
        \\        var i: usize = 0;
        \\        while i < self.methods.len() {
        \\            if self.methods[i].is_static() {
        \\                return i as i32;
        \\            }
        \\            i = i + 1;
        \\        }
        \\        return 0;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const class = Class { methods: list_from<Method>([:]Method [Method { access: 1 }, Method { access: 8 }]) };
        \\    return class.method_index() + 41;
        \\}
    ;

    try expectNamedNative("borrowed_receiver_indexed_field_path", source, 42);
}

test "borrowed reference fields can be returned and forwarded" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\struct UserView {
        \\    user: &User;
        \\}
        \\
        \\fn view(user: &User): UserView {
        \\    return UserView { user: user };
        \\}
        \\
        \\fn set_age(user: &User): void {
        \\    user.age = 42;
        \\}
        \\
        \\fn read_age(user: &User): i32 {
        \\    return user.age;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { age: 0 };
        \\    const borrowed = view(&user);
        \\    set_age(borrowed.user);
        \\    return read_age(&user);
        \\}
    ;

    try expectNamedNative("borrowed_ref_field_return_forward", source, 42);
}

test "direct borrowed reference returns can be forwarded" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn identity(user: &User): &User {
        \\    return user;
        \\}
        \\
        \\fn set_age(user: &User): void {
        \\    user.age = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { age: 0 };
        \\    const borrowed = identity(&user);
        \\    set_age(borrowed);
        \\    return user.age;
        \\}
    ;

    try expectNamedNative("direct_borrowed_ref_return_forward", source, 42);
}

test "generic structs can carry borrowed reference fields" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\struct Box<T> {
        \\    value: T;
        \\}
        \\
        \\fn set_age(user: &User): void {
        \\    user.age = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { age: 0 };
        \\    const box = Box<&User> { value: &user };
        \\    set_age(box.value);
        \\    return user.age;
        \\}
    ;

    try expectNamedNative("generic_struct_borrowed_ref_field", source, 42);
}

test "containers can store borrow carrying structs within source scope" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\struct UserView {
        \\    user: &User;
        \\}
        \\
        \\fn set_age(user: &User): void {
        \\    user.age = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { age: 0 };
        \\    var views: List<UserView> = list<UserView>();
        \\    views.push(UserView { user: &user });
        \\    set_age(views[0].user);
        \\    return user.age;
        \\}
    ;

    try expectNamedNative("list_stores_borrow_carrying_struct_in_scope", source, 42);
}

test "projected list string index call arg does not consume list" {
    const source =
        \\fn consume(value: string): i32 {
        \\    if value == "classfile" {
        \\        return 40;
        \\    }
        \\    return 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: List<string> = list_from<string>([:]string ["program", "classfile"]);
        \\    if values.len() < 2 {
        \\        drop values;
        \\        return 2;
        \\    }
        \\    const code = consume(values[1]);
        \\    drop values;
        \\    return code + 2;
        \\}
    ;

    try expectNamedNative("projected_list_string_index_call_arg", source, 42);
}

test "nested projected list string index call arg does not consume root" {
    const source =
        \\struct Holder {
        \\    values: List<string>;
        \\}
        \\
        \\fn consume(value: string): i32 {
        \\    if value == "classfile" {
        \\        return 40;
        \\    }
        \\    return 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    const holder = Holder { values: list_from<string>([:]string ["program", "classfile"]) };
        \\    const code = consume(holder.values[1]);
        \\    drop holder;
        \\    return code + 2;
        \\}
    ;

    try expectNamedNative("nested_projected_list_string_index_call_arg", source, 42);
}

test "indexed owned list fields pass to borrowed comparison in nested loops" {
    const source =
        \\struct ResourceRequirement { temporary_bytes: usize; alignment: usize; }
        \\struct ImplementationCost { model_id: u64; target_score: u64; }
        \\struct Layout { dimensions: List<usize>; }
        \\struct Candidate {
        \\    step: usize;
        \\    source_instruction: usize;
        \\    version: u32;
        \\    implementation_id: List<u8>;
        \\    execution_class: i32;
        \\    configuration: List<u8>;
        \\    deterministic: bool;
        \\    selected: bool;
        \\    numerical_class: i32;
        \\    layout_contract: i32;
        \\    input_requirements: List<Layout>;
        \\    output_properties: List<Layout>;
        \\    resources: ResourceRequirement;
        \\    cost: ImplementationCost;
        \\}
        \\fn candidate(configuration: u8): Candidate {
        \\    var inputs: List<Layout> = list<Layout>();
        \\    inputs.push(Layout { dimensions: list_from<usize>([:]usize [2, 3]) });
        \\    var outputs: List<Layout> = list<Layout>();
        \\    outputs.push(Layout { dimensions: list_from<usize>([:]usize [3, 2]) });
        \\    return Candidate { step: 1, source_instruction: 7, version: 2,
        \\        implementation_id: list_from<u8>([:]u8 [1, 2]), execution_class: 1,
        \\        configuration: list_from<u8>([:]u8 [configuration]),
        \\        deterministic: true, selected: false, numerical_class: 1,
        \\        layout_contract: 1, input_requirements: inputs,
        \\        output_properties: outputs,
        \\        resources: ResourceRequirement { temporary_bytes: 64, alignment: 8 },
        \\        cost: ImplementationCost { model_id: 1, target_score: 42 } };
        \\}
        \\fn bytes_equal(left: &const List<u8>, right: &const List<u8>): bool {
        \\    if left.len() != right.len() { return false; }
        \\    var index: usize = 0;
        \\    while index < left.len() {
        \\        if left[index] != right[index] { return false; }
        \\        index = index + 1;
        \\    }
        \\    return true;
        \\}
        \\fn has_duplicate(candidates: &const List<Candidate>): bool {
        \\    var left: usize = 0;
        \\    var duplicate = false;
        \\    while left < candidates.len() {
        \\        var right = left + 1;
        \\        while right < candidates.len() {
        \\            if not duplicate and candidates[left].step == candidates[right].step and
        \\                candidates[left].version == candidates[right].version and
        \\                bytes_equal(&candidates[left].implementation_id, &candidates[right].implementation_id) and
        \\                bytes_equal(&candidates[left].configuration, &candidates[right].configuration) {
        \\                duplicate = true;
        \\            }
        \\            right = right + 1;
        \\        }
        \\        left = left + 1;
        \\    }
        \\    return duplicate;
        \\}
        \\fn main(): i32 {
        \\    var candidates: List<Candidate> = list<Candidate>();
        \\    candidates.push(candidate(3));
        \\    candidates.push(candidate(3));
        \\    const found = has_duplicate(&candidates);
        \\    drop candidates;
        \\    var distinct: List<Candidate> = list<Candidate>();
        \\    distinct.push(candidate(3));
        \\    distinct.push(candidate(4));
        \\    const wrong_duplicate = has_duplicate(&distinct);
        \\    drop distinct;
        \\    if found and not wrong_duplicate { return 42; }
        \\    return 1;
        \\}
    ;

    try expectNamedNative("indexed_owned_list_borrowed_comparison", source, 42);
}

test "imported byte comparison in selection validation" {
    try helpers.expectNativeFileExitCode(
        std.testing.allocator,
        "test/ownership/projections/lg96/main.cy",
        42,
    );
}

test "returning switch branch does not poison outer ownership" {
    const source =
        \\enum Status: i32 {
        \\    failed = 1;
        \\}
        \\
        \\fn load(): string!Status {
        \\    return "classfile";
        \\}
        \\
        \\fn consume(value: string): i32 {
        \\    if value == "classfile" {
        \\        return 40;
        \\    }
        \\    return 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: List<string> = list_from<string>([:]string ["program", "classfile"]);
        \\    const source = load() catch (status) {
        \\        const ignored = status;
        \\        drop values;
        \\        return 2;
        \\    };
        \\    drop source;
        \\    const code = consume(values[1]);
        \\    drop values;
        \\    return code + 2;
        \\}
    ;

    try expectNamedNative("returning_switch_branch_outer_ownership", source, 42);
}

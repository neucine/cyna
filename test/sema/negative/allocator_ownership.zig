pub const negatives = [_]struct {
    name: []const u8,
    source: []const u8,
}{
    .{
        .name = "scoped_allocator_union_resource_escape_rejected",
        .source =
        \\struct User {
        \\    label: string;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\fn build(): Token {
        \\    using scoped alloc = 0 {
        \\        return .user(User { label: "temporary" });
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = build();
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "projected_union_resource_binding_cannot_transfer_ownership",
        .source =
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
        \\    const user = token.user;
        \\    return user.age;
        \\}
        ,
    },
    .{
        .name = "projected_resource_field_cannot_bind_by_transfer",
        .source =
        \\struct User {
        \\    scores: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { scores: list<i32>() };
        \\    const scores = user.scores;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "projected_resource_index_cannot_bind_by_transfer",
        .source =
        \\struct User {
        \\    scores: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var users: List<User> = list<User>();
        \\    users.push(User { scores: list<i32>() });
        \\    const user = users[0];
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "projected_resource_cannot_rebind_by_transfer",
        .source =
        \\struct User {
        \\    scores: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var users: List<User> = list<User>();
        \\    users.push(User { scores: list<i32>() });
        \\    var current = User { scores: list<i32>() };
        \\    current = users[0];
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "projected_resource_cannot_pass_by_value",
        .source =
        \\struct User {
        \\    scores: List<i32>;
        \\}
        \\
        \\fn take(user: User): i32 {
        \\    return 0;
        \\}
        \\
        \\fn main(): i32 {
        \\    var users: List<User> = list<User>();
        \\    users.push(User { scores: list<i32>() });
        \\    return take(users[0]);
        \\}
        ,
    },
    .{
        .name = "projected_resource_cannot_return_by_value",
        .source =
        \\struct User {
        \\    scores: List<i32>;
        \\}
        \\
        \\fn first(users: List<User>): User {
        \\    return users[0];
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "string_bytes_view_cannot_escape_parameter",
        .source =
        \\fn leak(text: string): [:]u8 {
        \\    return text.bytes();
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = leak("abc");
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "string_bytes_view_alias_cannot_escape_parameter",
        .source =
        \\fn leak(text: string): [:]u8 {
        \\    const bytes = text.bytes();
        \\    return bytes;
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = leak("abc");
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "string_bytes_view_cannot_escape_parameter_transitively",
        .source =
        \\fn expose(text: string): [:]u8 {
        \\    return text.bytes();
        \\}
        \\
        \\fn leak(text: string): [:]u8 {
        \\    return expose(text);
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = leak("abc");
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "string_bytes_view_cannot_escape_via_field_mutation",
        .source =
        \\struct Holder {
        \\    view: [:]u8;
        \\}
        \\
        \\fn store(text: string, holder: &Holder): void {
        \\    holder.view = text.bytes();
        \\}
        \\
        \\fn main(): i32 {
        \\    var holder = Holder { view: "abc".bytes() };
        \\    store("def", &holder);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "string_bytes_view_cannot_escape_via_list_push",
        .source =
        \\fn store(text: string, views: &List<[:]u8>): void {
        \\    views.push(text.bytes());
        \\}
        \\
        \\fn main(): i32 {
        \\    var views: List<[:]u8> = list<[:]u8>();
        \\    store("abc", &views);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "string_bytes_view_cannot_escape_via_assignment",
        .source =
        \\fn store(text: string): [:]u8 {
        \\    var leaked: [:]u8 = "abc".bytes();
        \\    leaked = text.bytes();
        \\    return leaked;
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = store("def");
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "string_bytes_view_cannot_escape_via_ref_assignment",
        .source =
        \\fn store(text: string, slot: &[:]u8): void {
        \\    slot = text.bytes();
        \\}
        \\
        \\fn main(): i32 {
        \\    var view: [:]u8 = "abc".bytes();
        \\    store("def", &view);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "string_bytes_view_cannot_escape_via_struct_return",
        .source =
        \\struct Holder {
        \\    view: [:]u8;
        \\}
        \\
        \\fn build(text: string): Holder {
        \\    return Holder { view: text.bytes() };
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = build("abc");
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "string_bytes_view_cannot_escape_via_error_success_return",
        .source =
        \\enum Status: i32 {
        \\    failed = 1;
        \\}
        \\
        \\fn build(text: string): [:]u8!Status {
        \\    return text.bytes();
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = build("abc");
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "local_slice_view_cannot_escape_via_return",
        .source =
        \\fn leak(): [:]i32 {
        \\    const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\    return fixed[..];
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = leak();
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "local_union_slice_payload_cannot_escape_via_return",
        .source =
        \\union Entry {
        \\    text: [:]i32;
        \\    other: i32;
        \\}
        \\
        \\fn leak(): [:]i32 {
        \\    const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\    const entry: Entry = .text(fixed[..]);
        \\    var entries: List<Entry> = list_from<Entry>([:]Entry [entry]);
        \\    switch entries[0] {
        \\    .text(values) => {
        \\        return values;
        \\    }
        \\    .other(value) => {
        \\        const ignored = value;
        \\        return fixed[..];
        \\    }
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = leak();
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "local_optional_slice_field_payload_cannot_escape_via_return",
        .source =
        \\struct Wrap {
        \\    view: [:]i32;
        \\}
        \\
        \\fn leak(): [:]i32 {
        \\    const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\    const value: ?Wrap = Wrap { view: fixed[..] };
        \\    var values: List<?Wrap> = list_from<?Wrap>([:]?Wrap [value]);
        \\    if values[0] is wrap {
        \\        return wrap.view;
        \\    }
        \\    return fixed[..];
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = leak();
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "local_slice_view_cannot_escape_via_outer_assignment",
        .source =
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var leaked: [:]i32 = seed[..];
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        leaked = fixed[..];
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "local_slice_view_cannot_escape_via_outer_field_mutation",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        holder.view = fixed[..];
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "local_slice_view_cannot_escape_via_outer_indexed_mutation",
        .source =
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var views: List<[:]i32> = list_from<[:]i32>([:][:]i32 [seed[..]]);
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        views[0] = fixed[..];
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "local_slice_view_cannot_escape_via_outer_list_push",
        .source =
        \\fn main(): i32 {
        \\    var views: List<[:]i32> = list<[:]i32>();
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        views.push(fixed[..]);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "local_slice_view_cannot_escape_via_outer_set_add",
        .source =
        \\fn main(): i32 {
        \\    var views: Set<[:]i32> = set<[:]i32>();
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        views.add(fixed[..]);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "local_slice_view_cannot_escape_via_ref_assignment",
        .source =
        \\fn store(slot: &[:]i32): void {
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        slot = fixed[..];
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var view = seed[..];
        \\    store(&view);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "live_slice_view_blocks_container_mutation",
        .source =
        \\fn main(): i32 {
        \\    var values: List<i32> = list_from<i32>([:]i32 [7]);
        \\    const view = values.view();
        \\    values.push(35);
        \\    return view[0];
        \\}
        ,
    },
    .{
        .name = "live_slice_view_blocks_field_replacement",
        .source =
        \\struct Pair {
        \\    left: [1]i32;
        \\    right: [1]i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    const left: [1]i32 = [1]i32 [ 7 ];
        \\    const right: [1]i32 = [1]i32 [ 0 ];
        \\    var pair = Pair { left: left, right: right };
        \\    const view = pair.left[..];
        \\    const replacement: [1]i32 = [1]i32 [ 35 ];
        \\    pair.left = replacement;
        \\    return view[0];
        \\}
        ,
    },
    .{
        .name = "mutated_local_struct_field_borrow_is_tracked_on_return",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\fn leak(): [:]i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\    holder.view = fixed[..];
        \\    return holder.view;
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = leak();
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "mutated_local_list_borrow_is_tracked_on_return",
        .source =
        \\fn leak(): List<[:]i32> {
        \\    var views: List<[:]i32> = list<[:]i32>();
        \\    const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\    views.push(fixed[..]);
        \\    return views;
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = leak();
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "list_pop_borrow_is_tracked_on_return",
        .source =
        \\fn leak(): [:]i32 {
        \\    var views: List<[:]i32> = list<[:]i32>();
        \\    const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\    views.push(fixed[..]);
        \\    return views.pop();
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = leak();
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "map_values_borrow_is_tracked_on_return",
        .source =
        \\fn leak(): List<[:]i32> {
        \\    var values: Map<i32, [:]i32> = map<i32, [:]i32>();
        \\    const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\    values[1] = fixed[..];
        \\    return values.values();
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = leak();
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "forwarded_call_borrow_is_tracked_on_return",
        .source =
        \\fn identity(xs: [:]i32): [:]i32 {
        \\    return xs;
        \\}
        \\
        \\fn leak(): [:]i32 {
        \\    const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\    return identity(fixed[..]);
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = leak();
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "forwarded_generic_call_borrow_is_tracked_on_return",
        .source =
        \\fn identity<T>(value: T): T {
        \\    return value;
        \\}
        \\
        \\fn leak(): [:]i32 {
        \\    const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\    return identity(fixed[..]);
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = leak();
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "local_forwarded_borrow_is_tracked_on_return",
        .source =
        \\fn leak(): [:]i32 {
        \\    const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\    var tmp = fixed[..];
        \\    return tmp;
        \\}
        \\
        \\fn main(): i32 {
        \\    const ignored = leak();
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "branch_join_return_rejects_short_lived_local_source",
        .source =
        \\fn choose(xs: [:]i32, flag: bool): [:]i32 {
        \\    var current = xs;
        \\    if flag {
        \\        current = xs;
        \\    } else {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        current = fixed[..];
        \\    }
        \\    return current;
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [ 0 ];
        \\    const ignored = choose(seed[..], true);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "branch_join_return_rejects_short_lived_local_source_in_then_arm",
        .source =
        \\fn choose(xs: [:]i32, flag: bool): [:]i32 {
        \\    var current = xs;
        \\    if flag {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        current = fixed[..];
        \\    } else {
        \\        current = xs;
        \\    }
        \\    return current;
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [ 0 ];
        \\    const ignored = choose(seed[..], false);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "switch_join_return_rejects_short_lived_local_source",
        .source =
        \\enum Choice: i32 {
        \\    left = 0;
        \\    right = 1;
        \\}
        \\
        \\fn choose(xs: [:]i32, choice: Choice): [:]i32 {
        \\    var current = xs;
        \\    switch choice {
        \\    Choice.left => {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        current = fixed[..];
        \\    }
        \\    Choice.right => {
        \\        current = xs;
        \\    }
        \\    }
        \\    return current;
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [ 0 ];
        \\    const ignored = choose(seed[..], Choice.right);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "loop_join_return_rejects_short_lived_local_source",
        .source =
        \\fn choose(xs: [:]i32, flag: bool): [:]i32 {
        \\    var current = xs;
        \\    var keep = flag;
        \\    while keep {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        current = fixed[..];
        \\        keep = false;
        \\    }
        \\    return current;
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [ 0 ];
        \\    const ignored = choose(seed[..], false);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "loop_continue_join_rejects_short_lived_local_source",
        .source =
        \\fn choose(xs: [:]i32, flag: bool): [:]i32 {
        \\    var current = xs;
        \\    var keep = true;
        \\    while keep {
        \\        if flag {
        \\            const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\            current = fixed[..];
        \\            keep = false;
        \\            continue;
        \\        }
        \\        keep = false;
        \\    }
        \\    return current;
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [ 0 ];
        \\    const ignored = choose(seed[..], false);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "loop_unchecked_continue_join_rejects_short_lived_local_source",
        .source =
        \\fn choose(xs: [:]i32, flag: bool): [:]i32 {
        \\    var current = xs;
        \\    var keep = true;
        \\    while keep {
        \\        unchecked {
        \\            if flag {
        \\                const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\                current = fixed[..];
        \\                keep = false;
        \\                continue;
        \\            }
        \\        }
        \\        keep = false;
        \\    }
        \\    return current;
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [ 0 ];
        \\    const ignored = choose(seed[..], false);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "loop_using_alloc_continue_join_rejects_short_lived_local_source",
        .source =
        \\fn choose(xs: [:]i32, flag: bool): [:]i32 {
        \\    var current = xs;
        \\    var keep = true;
        \\    while keep {
        \\        using scoped alloc = 0 {
        \\            if flag {
        \\                const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\                current = fixed[..];
        \\                keep = false;
        \\                continue;
        \\            }
        \\        }
        \\        keep = false;
        \\    }
        \\    return current;
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [ 0 ];
        \\    const ignored = choose(seed[..], false);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "aggregate_return_rejects_short_lived_local_component",
        .source =
        \\struct Pair {
        \\    left: [:]i32;
        \\    right: [:]i32;
        \\}
        \\
        \\fn bundle(left: [:]i32): Pair {
        \\    const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\    return Pair { left: left, right: fixed[..] };
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [ 0 ];
        \\    const ignored = bundle(seed[..]);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "borrowed_call_side_effect_escape_is_rejected",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\fn store(xs: [:]i32, holder: &Holder): void {
        \\    holder.view = xs;
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        store(fixed[..], &holder);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "borrowed_call_return_then_field_escape_is_rejected",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\fn identity(xs: [:]i32): [:]i32 {
        \\    return xs;
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        holder.view = identity(fixed[..]);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "borrowed_call_return_then_sink_escape_is_rejected",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\fn identity(xs: [:]i32): [:]i32 {
        \\    return xs;
        \\}
        \\
        \\fn store(xs: [:]i32, holder: &Holder): void {
        \\    holder.view = identity(xs);
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        store(fixed[..], &holder);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "transitive_borrowed_call_side_effect_escape_is_rejected",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\fn sink(xs: [:]i32, holder: &Holder): void {
        \\    holder.view = xs;
        \\}
        \\
        \\fn forward(xs: [:]i32, holder: &Holder): void {
        \\    sink(xs, holder);
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        forward(fixed[..], &holder);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "local_forwarded_borrowed_sink_escape_is_rejected",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\fn store(xs: [:]i32, holder: &Holder): void {
        \\    var tmp = xs;
        \\    holder.view = tmp;
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        store(fixed[..], &holder);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "transitive_generic_borrowed_call_side_effect_escape_is_rejected",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\fn sink<T>(xs: T, holder: &Holder): void {
        \\    holder.view = xs;
        \\}
        \\
        \\fn forward<T>(xs: T, holder: &Holder): void {
        \\    sink(xs, holder);
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        forward(fixed[..], &holder);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "generic_borrowed_call_return_then_sink_escape_is_rejected",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\fn identity<T>(value: T): T {
        \\    return value;
        \\}
        \\
        \\fn store(xs: [:]i32, holder: &Holder): void {
        \\    holder.view = identity(xs);
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        store(fixed[..], &holder);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "transitive_method_borrowed_call_side_effect_escape_is_rejected",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\    fn sink(self: &Holder, xs: [:]i32): void {
        \\        self.view = xs;
        \\    }
        \\
        \\    fn forward(self: &Holder, xs: [:]i32): void {
        \\        self.sink(xs);
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        holder.forward(fixed[..]);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "projected_receiver_method_borrowed_call_side_effect_escape_is_rejected",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\
        \\    fn sink(self: &Holder, xs: [:]i32): void {
        \\        self.view = xs;
        \\    }
        \\
        \\    fn forward(self: &Holder, xs: [:]i32): void {
        \\        self.sink(xs);
        \\    }
        \\}
        \\
        \\struct Wrapper {
        \\    holder: Holder;
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var wrapper = Wrapper { holder: Holder { view: seed[..] } };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        wrapper.holder.forward(fixed[..]);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "method_returned_view_keeps_receiver_field_borrow_live",
        .source =
        \\struct Wrap {
        \\    buf: [1]i32;
        \\
        \\    fn view(self: &Wrap): []i32 {
        \\        return self.buf[..];
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var wrap = Wrap { buf: [1]i32 [ 1 ] };
        \\    const view = wrap.view();
        \\    wrap.buf = [1]i32 [ 2 ];
        \\    return view[0];
        \\}
        ,
    },
    .{
        .name = "transitive_generic_method_borrowed_call_side_effect_escape_is_rejected",
        .source =
        \\struct Holder<T> {
        \\    view: T;
        \\
        \\    fn sink<U>(self: &Holder<T>, xs: U): void {
        \\        self.view = xs;
        \\    }
        \\
        \\    fn forward<U>(self: &Holder<T>, xs: U): void {
        \\        self.sink(xs);
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder: Holder<[:]i32> = Holder<[:]i32> { view: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        holder.forward(fixed[..]);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "recursive_borrowed_call_side_effect_escape_is_rejected",
        .source =
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
    },
    .{
        .name = "mutual_recursive_borrowed_call_side_effect_escape_is_rejected",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\fn first(xs: [:]i32, holder: &Holder, done: bool): void {
        \\    if done {
        \\        holder.view = xs;
        \\        return;
        \\    }
        \\    second(xs, holder);
        \\}
        \\
        \\fn second(xs: [:]i32, holder: &Holder): void {
        \\    first(xs, holder, true);
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        second(fixed[..], &holder);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "recursive_generic_instantiation_borrowed_call_side_effect_escape_is_rejected",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\fn adapt<T>(value: T, holder: &Holder, borrow: [:]i32, step: i32): void {
        \\    if step == 0 {
        \\        holder.view = borrow;
        \\        return;
        \\    }
        \\    adapt<i32>(0, holder, borrow, 0);
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        adapt<[:]i32>(fixed[..], &holder, fixed[..], 1);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "recursive_generic_method_instantiation_borrowed_call_side_effect_escape_is_rejected",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\struct Adapter<T> {
        \\    value: T;
        \\
        \\    fn run<U>(self: Adapter<T>, holder: &Holder, borrow: [:]i32, step: i32): void {
        \\        const ignored = self.value;
        \\        const ignored_step = step;
        \\        if step == 0 {
        \\            holder.view = borrow;
        \\            return;
        \\        }
        \\        self.run<i32>(holder, borrow, 0);
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    const adapter = Adapter<[:]i32> { value: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        adapter.run<[:]i32>(&holder, fixed[..], 1);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "mutual_recursive_generic_instantiation_borrowed_call_side_effect_escape_is_rejected",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\fn first<T>(value: T, holder: &Holder, borrow: [:]i32, step: i32): void {
        \\    const ignored = value;
        \\    if step == 0 {
        \\        holder.view = borrow;
        \\        return;
        \\    }
        \\    second<i32>(0, holder, borrow);
        \\}
        \\
        \\fn second<U>(value: U, holder: &Holder, borrow: [:]i32): void {
        \\    const ignored = value;
        \\    third<bool>(true, holder, borrow);
        \\}
        \\
        \\fn third<V>(value: V, holder: &Holder, borrow: [:]i32): void {
        \\    const ignored = value;
        \\    first<V>(value, holder, borrow, 0);
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        first<[:]i32>(fixed[..], &holder, fixed[..], 1);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "mutual_recursive_generic_method_instantiation_borrowed_call_side_effect_escape_is_rejected",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\struct Adapter<T> {
        \\    value: T;
        \\
        \\    fn first<U>(self: Adapter<T>, holder: &Holder, borrow: [:]i32, step: i32): void {
        \\        const ignored = self.value;
        \\        const ignored_step = step;
        \\        if step == 0 {
        \\            holder.view = borrow;
        \\            return;
        \\        }
        \\        self.second<bool>(holder, borrow);
        \\    }
        \\
        \\    fn second<V>(self: Adapter<T>, holder: &Holder, borrow: [:]i32): void {
        \\        const ignored = self.value;
        \\        self.third<i32>(holder, borrow);
        \\    }
        \\
        \\    fn third<W>(self: Adapter<T>, holder: &Holder, borrow: [:]i32): void {
        \\        const ignored = self.value;
        \\        self.first<W>(holder, borrow, 0);
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    const adapter = Adapter<[:]i32> { value: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        adapter.first<[:]i32>(&holder, fixed[..], 1);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "mixed_recursive_generic_function_method_borrowed_call_side_effect_escape_is_rejected",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\struct Adapter<T> {
        \\    value: T;
        \\
        \\    fn step<U>(self: Adapter<T>, holder: &Holder, borrow: [:]i32): void {
        \\        const ignored = self.value;
        \\        finish<U>(self, holder, borrow);
        \\    }
        \\}
        \\
        \\fn start<T>(adapter: Adapter<T>, holder: &Holder, borrow: [:]i32, step: i32): void {
        \\    const ignored = adapter.value;
        \\    if step == 0 {
        \\        holder.view = borrow;
        \\        return;
        \\    }
        \\    adapter.step<bool>(holder, borrow);
        \\}
        \\
        \\fn finish<V>(adapter: Adapter<V>, holder: &Holder, borrow: [:]i32): void {
        \\    const ignored = adapter.value;
        \\    start<V>(adapter, holder, borrow, 0);
        \\}
        \\
        \\fn main(): i32 {
        \\    var seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    const adapter = Adapter<[:]i32> { value: seed[..] };
        \\    if true {
        \\        const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\        start<[:]i32>(adapter, &holder, fixed[..], 1);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "method_mixed_return_and_side_effect_rejects_short_lived_side_effect_escape",
        .source =
        \\struct Holder {
        \\    view: [:]i32;
        \\}
        \\
        \\struct Picker {
        \\    view: [:]i32;
        \\
        \\    fn run(self: Picker, other: [:]i32, holder: &Holder): [:]i32 {
        \\        holder.view = other;
        \\        return self.view;
        \\    }
        \\}
        \\
        \\fn leak(view: [:]i32, holder: &Holder): [:]i32 {
        \\    const picker = Picker { view: view };
        \\    const fixed: [2]i32 = [2]i32 [ 1, 2 ];
        \\    return picker.run(fixed[..], holder);
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [ 0 ];
        \\    var holder = Holder { view: seed[..] };
        \\    const ignored = leak(seed[..], &holder);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "projected_resource_cannot_pass_by_value_to_generic_copy_identity",
        .source =
        \\struct User {
        \\    scores: List<i32>;
        \\}
        \\
        \\fn duplicate<T>(value: T): T {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    var users: List<User> = list<User>();
        \\    users.push(User { scores: list<i32>() });
        \\    const user = duplicate(users[0]);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "copy_requirement_is_checked_at_generic_call_site",
        .source =
        \\struct Box { value: i32; }
        \\fn duplicate<T: Clone>(value: &const T): T {
        \\    return value.clone();
        \\}
        \\
        \\fn main(): i32 {
        \\    const value = Box { value: 0 };
        \\    const other = duplicate<Box>(&value);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "live_alias_blocks_drop_of_source",
        .source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { age: 1, scores: list<i32>() };
        \\    const alias: &User = &user;
        \\    drop user;
        \\    return alias.age;
        \\}
        ,
    },
    .{
        .name = "live_alias_blocks_handoff_of_source",
        .source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\fn take(user: User): i32 {
        \\    return user.age;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { age: 1, scores: list<i32>() };
        \\    const alias: &User = &user;
        \\    return take(user) + alias.age;
        \\}
        ,
    },
    .{
        .name = "live_alias_blocks_rebind_of_source",
        .source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { age: 1, scores: list<i32>() };
        \\    const alias: &User = &user;
        \\    user = User { age: 2, scores: list<i32>() };
        \\    return alias.age;
        \\}
        ,
    },
    .{
        .name = "live_root_alias_blocks_field_mutation",
        .source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { age: 1, scores: list<i32>() };
        \\    const alias: &User = &user;
        \\    user.age = 2;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "live_field_alias_blocks_overlapping_field_mutation",
        .source =
        \\struct Pair {
        \\    left: i32;
        \\    right: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var pair = Pair { left: 1, right: 2 };
        \\    const left = &pair.left;
        \\    pair.left = 7;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "live_field_alias_blocks_take_same_field",
        .source =
        \\struct Pair {
        \\    left: ?i32;
        \\    right: ?i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var pair = Pair { left: some(1), right: some(2) };
        \\    const left = &pair.left;
        \\    const taken = take pair.left;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "live_index_alias_blocks_index_mutation",
        .source =
        \\fn main(): i32 {
        \\    var values: [2]i32 = [2]i32 [ 1, 2 ];
        \\    const first = &values[0];
        \\    values[0] = 7;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "live_index_alias_blocks_list_push",
        .source =
        \\fn main(): i32 {
        \\    var values: List<i32> = list_from<i32>([:]i32 [1]);
        \\    const first = &values[0];
        \\    values.push(7);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "live_field_alias_blocks_same_field_container_mutation",
        .source =
        \\struct Holder {
        \\    values: List<i32>;
        \\    other: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var holder = Holder { values: list<i32>(), other: 0 };
        \\    const values = &holder.values;
        \\    holder.values.push(7);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "live_field_alias_blocks_same_field_set_clear",
        .source =
        \\struct Holder {
        \\    values: Set<i32>;
        \\    other: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var holder = Holder { values: set<i32>(), other: 0 };
        \\    holder.values.add(1);
        \\    const values = &holder.values;
        \\    holder.values.clear();
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "for_loop_resource_binding_cannot_be_handed_off",
        .source =
        \\struct User {
        \\    scores: List<i32>;
        \\}
        \\
        \\fn take(user: User): i32 {
        \\    return 0;
        \\}
        \\
        \\fn main(): i32 {
        \\    var users: List<User> = list<User>();
        \\    users.push(User { scores: list<i32>() });
        \\    for user in users {
        \\        return take(user);
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "for_loop_resource_binding_cannot_bind_by_transfer",
        .source =
        \\struct User {
        \\    scores: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var users: List<User> = list<User>();
        \\    users.push(User { scores: list<i32>() });
        \\    for user in users {
        \\        const other = user;
        \\        return 0;
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "const_optional_array_slot_cannot_take",
        .source =
        \\fn main(): i32 {
        \\    var temp = [:]?i32 [none];
        \\    temp[0] = 42;
        \\    const slots = temp;
        \\    const value = take slots[0];
        \\    if value is n {
        \\        return n;
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "take_list_index_is_not_supported",
        .source =
        \\fn main(): i32 {
        \\    var values: List<i32> = list_from<i32>([:]i32 [1]);
        \\    const value = take values[0];
        \\    return value;
        \\}
        ,
    },
    .{
        .name = "take_map_index_is_not_supported",
        .source =
        \\fn main(): i32 {
        \\    var values: Map<i32, i32> = map<i32, i32>();
        \\    values[1] = 42;
        \\    const value = take values[1];
        \\    return value;
        \\}
        ,
    },
    .{
        .name = "live_alias_blocks_take_from_source",
        .source =
        \\struct Profile {
        \\    age: i32;
        \\}
        \\
        \\struct User {
        \\    profile: ?Profile;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { profile: some(Profile { age: 42 }) };
        \\    const alias: &User = &user;
        \\    const profile = take user.profile;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "live_alias_blocks_take_from_optional_array_root",
        .source =
        \\fn main(): i32 {
        \\    var slots = [:]?i32 [none];
        \\    slots[0] = 42;
        \\    const alias: &[:]?i32 = &slots;
        \\    const value = take slots[0];
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "live_alias_blocks_take_from_optional_local_root",
        .source =
        \\fn main(): i32 {
        \\    var value: ?List<i32> = some([1]);
        \\    const alias: &?List<i32> = &value;
        \\    const taken = take value;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "live_alias_blocks_take_from_nested_optional_path",
        .source =
        \\struct Profile {
        \\    age: ?i32;
        \\}
        \\
        \\struct User {
        \\    profile: ?Profile;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { profile: some(Profile { age: 42 }) };
        \\    const alias: &User = &user;
        \\    const age = take user.profile.age;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "take_non_optional_local_is_rejected",
        .source =
        \\fn main(): i32 {
        \\    var value: i32 = 42;
        \\    const taken = take value;
        \\    return taken;
        \\}
        ,
    },
    .{
        .name = "take_non_optional_field_is_rejected",
        .source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { age: 42 };
        \\    const taken = take user.age;
        \\    return taken;
        \\}
        ,
    },
    .{
        .name = "take_const_optional_local_is_rejected",
        .source =
        \\fn main(): i32 {
        \\    const value: ?i32 = 42;
        \\    const taken = take value;
        \\    if taken is n {
        \\        return n;
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "take_const_optional_field_is_rejected",
        .source =
        \\struct Profile {
        \\    age: i32;
        \\}
        \\
        \\struct User {
        \\    profile: ?Profile;
        \\}
        \\
        \\fn main(): i32 {
        \\    const user = User { profile: Profile { age: 42 } };
        \\    const taken = take user.profile;
        \\    if taken is profile {
        \\        return profile.age;
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "cunion_field_read_requires_unchecked",
        .source =
        \\c union Raw {
        \\    int_value: i32;
        \\}
        \\
        \\fn read(value: Raw): i32 {
        \\    return value.int_value;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "owned_packed_struct_field_alias_rejected",
        .source =
        \\packed struct User {
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
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "nested_packed_struct_field_alias_rejected",
        .source =
        \\packed struct Inner {
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
        \\    var user = User { inner: { age: 0 } };
        \\    set_age(&user.inner.age);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "owned_nested_packed_struct_field_alias_rejected",
        .source =
        \\packed struct Inner {
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
        \\    var user = new User { inner: { age: 0 } };
        \\    set_age(&user.inner.age);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "scoped_allocator_return_escape_rejected",
        .source =
        \\fn bad(): string {
        \\    using scoped alloc = 0 {
        \\        return "temporary";
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "scoped_allocator_assignment_escape_rejected",
        .source =
        \\fn main(): i32 {
        \\    var label: string = "";
        \\    using scoped alloc = 0 {
        \\        label = "temporary";
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "scoped_allocator_call_escape_rejected",
        .source =
        \\fn sink(label: string): void {}
        \\
        \\fn main(): i32 {
        \\    using scoped alloc = 0 {
        \\        sink("temporary");
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "scoped_allocator_method_self_escape_rejected",
        .source =
        \\struct Holder {
        \\    label: string;
        \\
        \\    fn use(self: Holder): void {}
        \\}
        \\
        \\fn main(): i32 {
        \\    using scoped alloc = 0 {
        \\        const holder = Holder { label: "temporary" };
        \\        holder.use();
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "scoped_allocator_list_mutation_escape_rejected",
        .source =
        \\fn main(): i32 {
        \\    var xs: List<string> = list<string>();
        \\    using scoped alloc = 0 {
        \\        xs.push("temporary");
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "scoped_allocator_set_mutation_escape_rejected",
        .source =
        \\fn main(): i32 {
        \\    var names: Set<string> = set<string>();
        \\    using scoped alloc = 0 {
        \\        names.add("temporary");
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "scoped_allocator_map_mutation_escape_rejected",
        .source =
        \\fn main(): i32 {
        \\    var scores: Map<i32, string> = map<i32, string>();
        \\    using scoped alloc = 0 {
        \\        scores[1] = "temporary";
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "scoped_allocator_outer_list_copy_escape_rejected",
        .source =
        \\fn main(): i32 {
        \\    var xs: List<string> = list<string>();
        \\    using scoped alloc = 0 {
        \\        const local = xs.clone();
        \\        xs = local;
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "scoped_allocator_struct_field_list_mutation_escape_rejected",
        .source =
        \\struct Holder {
        \\    names: List<string>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var holder = Holder { names: list<string>() };
        \\    using scoped alloc = 0 {
        \\        holder.names.push("temporary");
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "scoped_allocator_struct_field_index_mutation_escape_rejected",
        .source =
        \\struct Holder {
        \\    scores: Map<i32, string>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var holder = Holder { scores: map<i32, string>() };
        \\    using scoped alloc = 0 {
        \\        holder.scores[1] = "temporary";
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "use_after_drop",
        .source =
        \\fn main(): i32 {
        \\    var values: List<i32> = list_from<i32>([:]i32 [1]);
        \\    drop values;
        \\    return values.len();
        \\}
        ,
    },
    .{
        .name = "use_after_branch_drop",
        .source =
        \\fn main(): i32 {
        \\    var values: List<i32> = list_from<i32>([:]i32 [1]);
        \\    if true {
        \\        drop values;
        \\    }
        \\    return values.len();
        \\}
        ,
    },
    .{
        .name = "use_after_loop_drop",
        .source =
        \\fn main(): i32 {
        \\    var values: List<i32> = list_from<i32>([:]i32 [1]);
        \\    while true {
        \\        drop values;
        \\        break;
        \\    }
        \\    return values.len();
        \\}
        ,
    },
    .{
        .name = "drop_requires_storage_lifetime",
        .source =
        \\fn main(): i32 {
        \\    const value: i32 = 1;
        \\    drop value;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "use_after_handoff",
        .source =
        \\fn main(): i32 {
        \\    var xs: List<i32> = list_from<i32>([:]i32 [1]);
        \\    var ys = xs;
        \\    return xs.len();
        \\}
        ,
    },
    .{
        .name = "use_after_condition_handoff",
        .source =
        \\fn take(xs: List<i32>): bool {
        \\    return xs.len() == 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    var xs: List<i32> = list_from<i32>([:]i32 [1]);
        \\    if take(xs) {
        \\        return xs.len();
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "use_after_branch_handoff",
        .source =
        \\fn take(xs: List<i32>): i32 {
        \\    return xs.len();
        \\}
        \\
        \\fn main(): i32 {
        \\    var xs: List<i32> = list_from<i32>([:]i32 [1]);
        \\    if true {
        \\        const ignored = take(xs);
        \\    }
        \\    return xs.len();
        \\}
        ,
    },
    .{
        .name = "use_after_loop_handoff",
        .source =
        \\fn take(xs: List<i32>): i32 {
        \\    return xs.len();
        \\}
        \\
        \\fn main(): i32 {
        \\    var xs: List<i32> = list_from<i32>([:]i32 [1]);
        \\    while true {
        \\        const ignored = take(xs);
        \\        break;
        \\    }
        \\    return xs.len();
        \\}
        ,
    },
    .{
        .name = "defer_resource_handoff_makes_source_unavailable",
        .source =
        \\fn consume(xs: List<i32>): void {
        \\    const ignored = xs.len();
        \\    return;
        \\}
        \\
        \\fn main(): i32 {
        \\    var xs: List<i32> = list_from<i32>([:]i32 [1]);
        \\    defer consume(xs);
        \\    return xs.len();
        \\}
        ,
    },
    .{
        .name = "use_after_struct_field_handoff",
        .source =
        \\struct User {
        \\    id: i32;
        \\    addresses: List<string>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { id: 1, addresses: ["home"] };
        \\    var handed_off = user;
        \\    return user.id;
        \\}
        ,
    },
    .{
        .name = "use_after_Array_handoff",
        .source =
        \\fn main(): i32 {
        \\    var xs = [:]i32 [0, 0];
        \\    var ys = xs;
        \\    return xs[0];
        \\}
        ,
    },
};

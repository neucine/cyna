const std = @import("std");

const helpers = @import("../helpers.zig");

test "integer index hook keys use index syntax rules but direct calls stay strict" {
    const prefix =
        \\struct Box {
        \\    @syntax.index fn at(self: &const Box, key: u8): i32 { return key as i32; }
        \\}
    ;
    const indexed = prefix ++
        \\fn main(): i32 { const box = Box {}; const key: u16 = 1; return box[key]; }
    ;
    const called = prefix ++
        \\fn main(): i32 { const box = Box {}; const key: u16 = 1; return box.at(key); }
    ;
    try helpers.expectSemanticSuccess(std.testing.allocator, "integer_index_hook_syntax", indexed);
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "integer_index_hook_direct_call", called, "expected u8, got u16");
}

test "syntax indexing attributes validate unused declarations" {
    for ([_][]const u8{
        "@syntax.index fn read(): i32 { return 0; }",
        "struct Box { @syntax.index(1) fn read(self: &const Box, key: usize): i32 { return 0; } }",
        "struct Box { @syntax.index @syntax.copy fn read(self: &const Box, key: usize): i32 { return 0; } }",
        "struct Box { @syntax.index @syntax.index_set fn read(self: &const Box, key: usize): i32 { return 0; } }",
        "protocol Index { @syntax.index fn read(self: &const Self, key: usize): i32; }",
    }) |source| try helpers.expectParseFailed(std.testing.allocator, "invalid_syntax_attribute", source);
    for ([_][]const u8{
        "@syntax.index fn read(self: &Box, key: usize): i32 { return 0; }",
        "@syntax.index fn read(self: &const Box): i32 { return 0; }",
        "@syntax.index fn read<T>(self: &const Box, key: usize): i32 { return 0; }",
        "@syntax.index fn read(self: &const Box, key: usize): void {}",
        "@syntax.index_set fn write(self: &const Box, key: usize, value: i32): void {}",
        "@syntax.index_set fn write(self: &Box, key: usize, value: i32): i32 { return value; }",
        "@syntax.index fn first(self: &const Box, key: usize): i32 { return 0; } @syntax.index fn second(self: &const Box, key: usize): i32 { return 0; }",
    }) |methods| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "struct Box {{ {s} }} fn main(): i32 {{ return 0; }}", .{methods});
        defer std.testing.allocator.free(source);
        try helpers.expectSemanticFailedMessage(std.testing.allocator, "invalid_syntax_index", source, "requires one unique inherent method");
    }
}

test "syntax iteration attributes require a complete coherent contract" {
    const incomplete = "struct Box { @syntax.iter fn begin(self: &const Box): usize { return 0; } } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "incomplete_syntax_iteration", incomplete, "iteration requires all four attributes");
    const mismatch =
        \\struct Box {
        \\    @syntax.iter fn begin(self: &const Box): usize { return 0; }
        \\    @syntax.iter_has_next fn more(self: &const Box, state: &const i32): bool { return false; }
        \\    @syntax.iter_next fn advance(self: &const Box, state: &usize): usize { return 0; }
        \\    @syntax.iter_item fn read(self: &const Box, cursor: usize): i32 { return 42; }
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "mismatched_syntax_iteration_state", mismatch, "iteration state must match");
}

test "ordinary index method names do not grant syntax roles" {
    const source = "struct Box { fn index(self: &const Box, key: usize): i32 { return 42; } } fn main(): i32 { var value = Box {}; return value[0]; }";
    try helpers.expectSemanticFailed(std.testing.allocator, "unmarked_index_method", source);
    try helpers.expectLoadedSemanticFailed(std.testing.allocator, "lookalike_index_protocol",
        \\protocol Index { fn index(self: &const Self, key: usize): i32; }
        \\struct Box {}
        \\impl Box: Index { fn index(self: &const Box, key: usize): i32 { return 42; } }
        \\fn main(): i32 { const value = Box {}; return value[0]; }
    );
}

test "removed copy attribute is rejected even when unused" {
    for ([_][]const u8{
        "@syntax.copy fn duplicate(): i32 { return 0; }",
        "struct Box { @syntax.copy(1) fn duplicate(self: &const Box): Box { return Box {}; } }",
        "struct Box { @syntax.copy @syntax.copy fn duplicate(self: &const Box): Box { return Box {}; } }",
        "protocol Copy { @syntax.copy fn duplicate(self: &const Self): Self; }",
    }) |source| try helpers.expectParseFailed(std.testing.allocator, "copy_bad_attribute", source);
}

test "Clone implementations preserve borrowed result provenance" {
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "clone_borrow_escape",
        \\struct View {
        \\    data: []const i32;
        \\}
        \\impl View: Clone { fn clone(self: &const View): View { return View { data: self.data }; } }
        \\fn duplicate(view: &const View): View { return view.clone(); }
        \\fn escape(): View {
        \\    const values: [:]i32 = [42];
        \\    const view = View { data: values[..] };
        \\    return duplicate(&view);
        \\}
        \\fn main(): i32 { return 0; }
    , "borrowed values cannot escape");
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "clone_static_result",
        \\const values: [1]i32 = [42];
        \\struct View {
        \\    data: []const i32;
        \\}
        \\impl View: Clone { fn clone(self: &const View): View { return View { data: values[..] }; } }
        \\fn duplicate(view: &const View): View { return view.clone(); }
        \\fn escape(): View {
        \\    const local: [:]i32 = [7];
        \\    const view = View { data: local[..] };
        \\    return duplicate(&view);
        \\}
        \\fn main(): i32 { return escape().data[0]; }
    );
}

test "slice view attributes support List access and renamed generic methods" {
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "slice_view_access",
        \\struct Bag<T> {
        \\    data: [:]T;
        \\    @syntax.slice_view
        \\    pub fn inspect(self: &const Bag<T>): []const T { return self.data[..]; }
        \\    @syntax.slice_view
        \\    pub fn edit(self: &Bag<T>): []T { return self.data[..]; }
        \\}
        \\fn tail<T>(bag: &const Bag<T>): []const T { return bag[1..]; }
        \\fn main(): i32 {
        \\    var values: List<i32> = [1, 2, 3];
        \\    var middle: []i32 = values[1..3];
        \\    middle[0] = 7;
        \\    const fixed: List<i32> = [1, 2];
        \\    const read: []const i32 = fixed[..];
        \\    var bag = Bag<i32> { data: [1, 2, 3] };
        \\    const rest = tail<i32>(&bag);
        \\    return rest[0] + read[0];
        \\}
    );
}

test "slice view attributes reject invalid signatures when unused" {
    const methods = [_][]const u8{
        "@syntax.slice_view pub fn bad(): []i32 { return []; }",
        "@syntax.slice_view pub fn bad(self: Bag): []i32 { return []; }",
        "@syntax.slice_view pub fn bad(self: &Bag, extra: i32): []i32 { return self.data[..]; }",
        "@syntax.slice_view pub fn bad(self: &const Bag): []i32 { return []; }",
        "@syntax.slice_view pub fn bad(self: &Bag): []const i32 { return self.data[..]; }",
        "@syntax.slice_view pub fn bad(self: &Bag): i32 { return 0; }",
        "@syntax.slice_view pub fn bad<T>(self: &Bag): []i32 { return self.data[..]; }",
        "@syntax.slice_view pub fn bad(other: &Bag): []i32 { return other.data[..]; }",
    };
    for (methods) |method| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "struct Bag {{ data: [:]i32; {s} }} fn main(): i32 {{ return 0; }}", .{method});
        defer std.testing.allocator.free(source);
        try helpers.expectSemanticFailedMessage(std.testing.allocator, "slice_view_bad_signature", source, "attribute `syntax.slice_view` requires");
    }
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "slice_view_duplicates",
        \\struct Bag {
        \\    data: [:]i32;
        \\    @syntax.slice_view
        \\    fn first(self: &Bag): []i32 { return self.data[..]; }
        \\    @syntax.slice_view
        \\    fn second(self: &Bag): []i32 { return self.data[..]; }
        \\}
        \\fn main(): i32 { return 0; }
    , "duplicate `syntax.slice_view` methods");
}

test "slice view attributes reject invalid placement and arguments" {
    const sources = [_][]const u8{
        "@syntax.slice_view pub fn bad(): i32 { return 0; }",
        "@syntax.slice_view struct Bad {}",
        "@syntax.slice_view const bad: i32 = 0;",
        "struct Bag { @syntax.slice_view(1) fn bad(self: &Bag): []i32 { return []; } }",
        "struct Bag { @syntax.slice_view @syntax.slice_view fn bad(self: &Bag): []i32 { return []; } }",
        "protocol Bad { @syntax.slice_view fn bad(self: &Self): []i32; }",
    };
    for (sources) |source| try helpers.expectParseFailed(std.testing.allocator, "slice_view_bad_attribute", source);
}

test "slice view attributes preserve receiver access and escape checks" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "slice_view_const_fallback",
        \\struct Bag {
        \\    data: [:]i32;
        \\    @syntax.slice_view
        \\    fn inspect(self: &const Bag): []const i32 { return self.data[..]; }
        \\}
        \\fn main(): i32 { var bag = Bag { data: [42] }; const view: []const i32 = bag[..]; return view[0]; }
    );
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "slice_view_missing_const",
        \\struct Bag {
        \\    data: [:]i32;
        \\    @syntax.slice_view
        \\    fn edit(self: &Bag): []i32 { return self.data[..]; }
        \\}
        \\fn main(): i32 { const bag = Bag { data: [42] }; const view = bag[..]; return view[0]; }
    , "accessible `syntax.slice_view` method");
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "slice_view_readonly_mutation",
        \\fn main(): i32 {
        \\    const values: List<i32> = [1, 2];
        \\    var view = values[..];
        \\    view[0] = 3;
        \\    return 0;
        \\}
    , "read-only");
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "slice_view_local_escape",
        \\fn bad(): []const i32 { const values: List<i32> = [1]; return values[..]; }
        \\fn main(): i32 { return 0; }
    , "borrowed values cannot escape");
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "slice_view_live_borrow",
        \\fn main(): i32 {
        \\    var values: List<i32> = [1, 2];
        \\    const view = values[..];
        \\    values.push(3);
        \\    return view[0];
        \\}
    , "borrow");
}

test "slice view attributes use ordinary return provenance for unrelated storage" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "slice_view_static_return",
        \\struct Label {
        \\    @syntax.slice_view
        \\    fn bytes(self: &const Label): []const u8 { return "safe".bytes(); }
        \\}
        \\fn read(label: &const Label): []const u8 { return label[..]; }
        \\fn safe(): []const u8 { const label = Label {}; return read(&label); }
        \\fn main(): i32 { return 0; }
    );
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "slice_view_unrelated_local_return",
        \\struct Label {
        \\    @syntax.slice_view
        \\    fn bytes(self: &const Label): []const i32 { const local: [:]i32 = [1]; return local[..]; }
        \\}
        \\fn main(): i32 { const label = Label {}; const view = label[..]; return view[0]; }
    , "borrowed values cannot escape");
}

test "read-only alias rejects referent assignment" {
    const source =
        \\fn overwrite(value: &const i32): void {
        \\    value = 42;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "readonly_alias_assignment",
        source,
        "cannot assign through read-only alias `value`",
    );
}

test "read-only alias does not widen to mutable alias" {
    const source =
        \\fn overwrite(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn main(): void {
        \\    var value: i32 = 0;
        \\    const readonly: &const i32 = &value;
        \\    overwrite(readonly);
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "readonly_alias_no_mutable_widening",
        source,
        "cannot use read-only access `&const i32` where writable access `&i32` is required",
    );
}

test "const root projection forms a read-only alias" {
    const source =
        \\struct Box {
        \\    value: i32;
        \\}
        \\
        \\fn read(value: &const i32): i32 {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    const box = Box { value: 42 };
        \\    const value = &box.value;
        \\    return read(value);
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "const_root_projection_readonly_alias", source);
}

test "read-only receiver projection cannot return a writable alias" {
    const source =
        \\struct Box {
        \\    value: i32;
        \\}
        \\
        \\fn expose(box: &const Box): &i32 {
        \\    return &box.value;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "readonly_receiver_projection_no_writable_return",
        source,
        "cannot use read-only access `&const i32` where writable access `&i32` is required",
    );
}

test "read-only receiver projection can return a read-only alias" {
    const source =
        \\struct Box {
        \\    value: i32;
        \\}
        \\
        \\fn expose(box: &const Box): &const i32 {
        \\    return &box.value;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "readonly_receiver_projection_readonly_return", source);
}

test "reading an alias-valued field preserves its stored capability" {
    const source =
        \\struct View {
        \\    target: &i32;
        \\}
        \\
        \\fn expose(view: &const View): &i32 {
        \\    return view.target;
        \\}
        \\
        \\fn write(target: &i32): void {
        \\    target = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var value: i32 = 0;
        \\    const view = View { target: &value };
        \\    const target = expose(&view);
        \\    write(target);
        \\    return value;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "readonly_container_preserves_stored_alias_capability", source);
}

test "read-only indexed projection cannot amplify capability" {
    const source =
        \\struct Buffer {
        \\    values: [:]i32;
        \\}
        \\
        \\fn expose(buffer: &const Buffer, index: usize): &i32 {
        \\    return &buffer.values[index];
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "readonly_indexed_projection_no_amplification",
        source,
        "cannot use read-only access `&const i32` where writable access `&i32` is required",
    );
}

test "const binding holding mutable raw pointer retains pointee write access" {
    const source =
        \\struct Box { value: i32; }
        \\
        \\fn write(box: &Box): void { box.value = 42; }
        \\
        \\fn main(): i32 {
        \\    var box = new Box { value: 0 };
        \\    const ptr: *Box = box.ptr();
        \\    unchecked {
        \\        write(&*ptr);
        \\        return (*ptr).value;
        \\    }
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "const_raw_pointer_binding_shallow_access", source);
}

test "const raw pointer cannot produce writable projected alias" {
    const source =
        \\fn expose(ptr: *const i32): &i32 {
        \\    unchecked { return &*ptr; }
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "const_raw_pointer_projection_no_amplification",
        source,
        "cannot use read-only access `&const i32` where writable access `&i32` is required",
    );
}

test "generic function cannot amplify read-only alias capability" {
    const source =
        \\fn expose<T>(value: &const T): &T {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    const value: i32 = 42;
        \\    const alias = expose<i32>(&value);
        \\    return alias;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "generic_readonly_alias_no_amplification",
        source,
        "cannot use read-only access `&const i32` where writable access `&i32` is required",
    );
}

test "syntax index implementation cannot amplify receiver capability" {
    const source =
        \\struct Bag { values: [:]i32;
        \\    @syntax.index
        \\    fn index(self: &const Bag, index: usize): &i32 {
        \\        return &self.values[index];
        \\    }
        \\
        \\}
        \\
        \\
    ;

    try helpers.expectLoadedSemanticFailedMessage(
        std.testing.allocator,
        "syntax_index_readonly_receiver_no_amplification",
        source,
        "cannot use read-only access `&const i32` where writable access `&i32` is required",
    );
}

test "field projection through read-only syntax index output cannot amplify capability" {
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
        \\fn expose(bag: &const Bag): &i32 {
        \\    return &bag[0].value;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessage(
        std.testing.allocator,
        "syntax_index_field_readonly_no_amplification",
        source,
        "cannot use read-only access `&const i32` where writable access `&i32` is required",
    );
}

test "field projection through read-only syntax index output remains readable" {
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
    ;

    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "syntax_index_field_readonly_preserved", source);
}

test "list iteration is observational and works from a const root" {
    const source =
        \\fn main(): i32 {
        \\    const values = list_from<i32>([:]i32 [20, 22]);
        \\    var total: i32 = 0;
        \\    for value in values {
        \\        total = total + value;
        \\    }
        \\    return total;
        \\}
    ;

    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "list_iteration_from_const_root", source);
}

test "aggregate preserves read-only alias capability" {
    const source =
        \\struct View { value: &const i32; }
        \\
        \\fn write(value: &i32): void { value = 42; }
        \\fn mutate(view: View): void { write(view.value); }
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "aggregate_preserves_readonly_alias",
        source,
        "cannot use read-only access `&const i32` where writable access `&i32` is required",
    );
}

test "control flow return cannot join read-only alias as writable" {
    const source =
        \\fn choose(flag: bool, writable: &i32, readonly: &const i32): &i32 {
        \\    if flag { return writable; }
        \\    return readonly;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "control_flow_readonly_alias_no_amplification",
        source,
        "cannot use read-only access `&const i32` where writable access `&i32` is required",
    );
}

test "read-only slice cannot widen to writable slice" {
    const source =
        \\fn expose(values: []const i32): []i32 {
        \\    return values;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "readonly_slice_no_writable_widening",
        source,
        "cannot use read-only access `[]const i32` where writable access `[]i32` is required",
    );
}

test "slice projection from const storage is read-only" {
    const source =
        \\fn main(): void {
        \\    const values: [2]i32 = [2]i32 [1, 2];
        \\    var view: []i32 = values[..];
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "const_storage_slice_projection_readonly",
        source,
        "cannot use read-only access `[]const i32` where writable access `[]i32` is required",
    );
}

test "stored mutable slice capability remains shallow" {
    const source =
        \\struct View { values: []i32; }
        \\
        \\fn expose(view: &const View): []i32 {
        \\    return view.values[..];
        \\}
        \\
        \\fn mutate(view: &const View): void {
        \\    view.values[0] = 42;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "stored_mutable_slice_capability_is_shallow", source);
}

test "const slice binding retains its element capability" {
    const source =
        \\fn observe(view: &const []i32): usize { return view.len(); }
        \\
        \\fn main(): i32 {
        \\    var values: [1]i32 = [1]i32 [0];
        \\    const view: []i32 = values[..];
        \\    const ignored = observe(&view);
        \\    view[0] = 42;
        \\    return values[0];
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "const_mutable_slice_binding_retains_element_access", source);
}

test "method receiver declaration determines required access" {
    const source =
        \\struct Counter {
        \\    value: i32;
        \\    fn touch(self: &Counter): void {}
        \\}
        \\
        \\fn main(): void {
        \\    const counter = Counter { value: 0 };
        \\    counter.touch();
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "declared_writable_receiver_requires_writable_access",
        source,
        "cannot mutate const Counter `counter`",
    );
}

test "projected method receiver preserves root access" {
    const readonly_source =
        \\struct Counter {
        \\    value: i32;
        \\    fn touch(self: &Counter): void {}
        \\}
        \\struct Wrapper { counter: Counter; }
        \\
        \\fn main(): void {
        \\    const wrapper = Wrapper { counter: Counter { value: 0 } };
        \\    wrapper.counter.touch();
        \\}
    ;
    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "projected_method_receiver_preserves_readonly_root",
        readonly_source,
        "cannot mutate through read-only Counter receiver",
    );

    const stored_alias_source =
        \\struct Counter {
        \\    value: i32;
        \\    fn touch(self: &Counter): void { self.value = 42; }
        \\}
        \\struct View { counter: &Counter; }
        \\
        \\fn main(): i32 {
        \\    var counter = Counter { value: 0 };
        \\    const view = View { counter: &counter };
        \\    view.counter.touch();
        \\    return counter.value;
        \\}
    ;
    try helpers.expectSemanticSuccess(std.testing.allocator, "stored_alias_method_receiver_remains_writable", stored_alias_source);
}

test "list mutable view is explicit and requires writable root" {
    const writable_source =
        \\fn main(): i32 {
        \\    var values = list_from<i32>([:]i32 [0]);
        \\    var view = values.view_mut();
        \\    view[0] = 42;
        \\    return values[0];
        \\}
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "list_explicit_mutable_view", writable_source);

    const readonly_source =
        \\fn main(): void {
        \\    const values = list_from<i32>([:]i32 [0]);
        \\    const view = values.view_mut();
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(
        std.testing.allocator,
        "list_mutable_view_requires_writable_root",
        readonly_source,
        "cannot mutate const List<i32> `values`",
    );
}

test "read-only alias rejects field mutation" {
    const source =
        \\struct Counter {
        \\    value: i32;
        \\}
        \\
        \\fn overwrite(counter: &const Counter): void {
        \\    counter.value = 42;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "readonly_alias_field_assignment",
        source,
        "cannot assign through read-only alias `counter`",
    );
}

test "nested non-packed field aliases are supported" {
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
        \\    var user = User { inner: { age: 0 } };
        \\    set_age(&user.inner.age);
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "nested_nonpacked_field_alias_supported", source);
}

test "nested field alias through ref-root projection is supported" {
    const source =
        \\struct Header {
        \\    len: i32;
        \\}
        \\
        \\struct Holder {
        \\    header: Header;
        \\
        \\    fn set_len(self: &Holder): void {
        \\        const len = &self.header.len;
        \\        write_len(len);
        \\    }
        \\}
        \\
        \\fn write_len(len: &i32): void {
        \\    len = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var holder = Holder { header: Header { len: 0 } };
        \\    holder.set_len();
        \\    return holder.header.len;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "nested_field_alias_ref_root_supported", source);
}

test "nested indexed alias through ref-root projection is supported" {
    const source =
        \\struct Holder {
        \\    fields: [:]i32;
        \\
        \\    fn set_field(self: &Holder, i: i32): void {
        \\        const field = &self.fields[i];
        \\        write_field(field);
        \\    }
        \\}
        \\
        \\fn write_field(field: &i32): void {
        \\    field = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var holder = Holder { fields: [0, 1] };
        \\    holder.set_field(1);
        \\    return holder.fields[1];
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "nested_indexed_alias_ref_root_supported", source);
}

test "ordinary view methods do not change alias rules" {
    const source =
        \\struct LocalList {
        \\    storage: [:]i32;
        \\
        \\    pub fn view(self: &LocalList): []i32 {
        \\        return self.storage[..];
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var values = LocalList { storage: [1, 2] };
        \\    const alias = &values;
        \\    alias.storage[0] = 42;
        \\    return values.storage[0];
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "ordinary_view_method_alias_rules", source);
}

test "ordinary view method returns a slice" {
    const source =
        \\struct LocalList {
        \\    storage: [:]i32;
        \\
        \\    pub fn view(self: &LocalList): []i32 {
        \\        return self.storage[..];
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var values = LocalList { storage: [1, 2] };
        \\    const slice = values.view();
        \\    return slice[0] + slice[1];
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "ordinary_view_method_returns_slice", source);
}

test "reserved-looking view method does not customize slice syntax" {
    const source =
        \\struct LocalList {
        \\    storage: [:]i32;
        \\
        \\    pub fn __view(self: &LocalList): []i32 {
        \\        return self.storage[..];
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var values = LocalList { storage: [1, 2] };
        \\    const slice = values[..];
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "reserved_view_method_not_slice_syntax", source, "slice expression requires an array, dense storage, slice, or string");
}

test "list indexed optional payload capture can return receiver-rooted borrowed field" {
    const source =
        \\struct Wrap {
        \\    view: []const u8;
        \\}
        \\
        \\struct Table {
        \\    values: [:]?Wrap;
        \\
        \\    fn first_text(self: &Table): []const u8 {
        \\        if self.values[0] is wrap {
        \\            return wrap.view;
        \\        }
        \\        return "".bytes();
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "optional_payload_capture_receiver_rooted_borrow", source);
}

test "borrowed reference field cannot return local owner" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\struct UserView {
        \\    user: &User;
        \\}
        \\
        \\fn bad(): UserView {
        \\    var user = User { age: 0 };
        \\    return UserView { user: &user };
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "borrowed_ref_field_local_return_escape", source, "borrowed values cannot escape the function via return");
}

test "direct borrowed reference cannot return local owner" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn bad(): &User {
        \\    var user = User { age: 0 };
        \\    return &user;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "direct_borrowed_ref_local_return_escape", source, "borrowed values cannot escape the function via return");
}

test "generic borrowed reference field cannot return local owner" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\struct Box<T> {
        \\    value: T;
        \\}
        \\
        \\fn bad(): Box<&User> {
        \\    var user = User { age: 0 };
        \\    return Box<&User> { value: &user };
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_borrowed_ref_field_local_return_escape", source, "borrowed values cannot escape the function via return");
}

test "borrowed reference field assignment cannot escape into outer local" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\struct UserView {
        \\    user: &User;
        \\}
        \\
        \\fn main(): i32 {
        \\    var long = User { age: 1 };
        \\    var view = UserView { user: &long };
        \\    if true {
        \\        var short = User { age: 2 };
        \\        view = UserView { user: &short };
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "borrowed_ref_field_assignment_outer_escape", source, "borrowed values cannot escape into longer-lived assignment targets");
}

test "borrow carrying container cannot return local owner" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\struct UserView {
        \\    user: &User;
        \\}
        \\
        \\fn bad(): List<UserView> {
        \\    var user = User { age: 0 };
        \\    var views: List<UserView> = list<UserView>();
        \\    views.push(UserView { user: &user });
        \\    return views;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailed(std.testing.allocator, "borrow_carrying_container_local_return_escape", source);
}

test "live borrowed reference field blocks source mutation" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\struct UserView {
        \\    user: &User;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { age: 0 };
        \\    const view = UserView { user: &user };
        \\    user.age = 42;
        \\    return view.user.age;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "borrowed_ref_field_live_source_mutation", source, "cannot field-mutate local `user` while overlapping borrow `view` is live");
}

test "derived call borrow blocks owner leak on branch return" {
    const source =
        \\struct Box { value: i32; }
        \\fn observe(box: &Box): &i32 { return &box.value; }
        \\fn leak(flag: bool): *Box {
        \\    var box = new Box { value: 7 };
        \\    if flag {
        \\        const alias = observe(box);
        \\        return box.leak();
        \\    }
        \\    return box.leak();
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "derived_call_borrow_branch_owner_leak", source, "while borrow `alias` is live");
}

test "derived call borrow ends with its branch scope" {
    const source =
        \\struct Box { value: i32; }
        \\fn observe(box: &Box): &i32 { return &box.value; }
        \\fn leak(flag: bool): *Box {
        \\    var box = new Box { value: 7 };
        \\    if flag {
        \\        const alias = observe(box);
        \\        const seen = alias;
        \\    }
        \\    return box.leak();
        \\}
    ;
    try helpers.expectSemanticSuccess(std.testing.allocator, "derived_call_borrow_branch_scope", source);
}

test "derived call borrow from owned field blocks replacement" {
    const source =
        \\struct Box { value: i32; }
        \\struct Holder { item: ^Box; }
        \\fn observe(box: &Box): &i32 { return &box.value; }
        \\fn replace(): i32 {
        \\    var holder = Holder { item: new Box { value: 7 } };
        \\    const alias = observe(holder.item);
        \\    holder.item = new Box { value: 8 };
        \\    return alias;
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "derived_call_owned_field_replacement", source, "while overlapping borrow `alias` is live");
}

test "branch-joined returned borrow protects both possible owners" {
    const prefix =
        \\struct Box { value: i32; }
        \\fn observe(box: &Box): &i32 { return &box.value; }
        \\fn choose(a: &Box, b: &Box, flag: bool): &i32 {
        \\    if flag { return observe(a); }
        \\    return observe(b);
        \\}
    ;
    const leak_first = prefix ++
        \\fn probe(flag: bool): i32 {
        \\    var a = new Box { value: 7 };
        \\    var b = new Box { value: 8 };
        \\    const alias = choose(a, b, flag);
        \\    const ptr = a.leak();
        \\    return alias;
        \\}
    ;
    const leak_second = prefix ++
        \\fn probe(flag: bool): i32 {
        \\    var a = new Box { value: 7 };
        \\    var b = new Box { value: 8 };
        \\    const alias = choose(a, b, flag);
        \\    const ptr = b.leak();
        \\    return alias;
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "joined_borrow_first_owner", leak_first, "while borrow `alias` is live");
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "joined_borrow_second_owner", leak_second, "while borrow `alias` is live");
}

test "nested owned field forwarded borrow protects its source" {
    const prefix =
        \\struct Box { value: i32; }
        \\struct Holder { item: ^Box; }
        \\struct Outer { holder: Holder; }
        \\fn observe(box: &Box): &i32 { return &box.value; }
    ;
    const accepted = prefix ++
        \\fn probe(): i32 {
        \\    var outer = Outer { holder: Holder { item: new Box { value: 7 } } };
        \\    const alias = observe(outer.holder.item);
        \\    return alias;
        \\}
    ;
    const rejected = prefix ++
        \\fn probe(): i32 {
        \\    var outer = Outer { holder: Holder { item: new Box { value: 7 } } };
        \\    const alias = observe(outer.holder.item);
        \\    outer.holder.item = new Box { value: 8 };
        \\    return alias;
        \\}
    ;
    try helpers.expectSemanticSuccess(std.testing.allocator, "nested_owned_forwarded_borrow", accepted);
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "nested_owned_forwarded_replacement", rejected, "while overlapping borrow `alias` is live");
}

test "indirect borrowed result requires a provenance contract" {
    const source =
        \\struct Box { value: i32; }
        \\fn observe(box: &Box): &i32 { return &box.value; }
        \\fn probe(): i32 {
        \\    var box = new Box { value: 7 };
        \\    const callback: fn(&Box): &i32 = observe;
        \\    const alias = callback(box);
        \\    const leaked = box.leak();
        \\    return alias;
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "indirect_borrowed_result", source, "cannot return borrowed data without a checked provenance contract");
}

test "live list element alias blocks structural mutation" {
    const source =
        \\struct LocalList {
        \\    storage: [:]i32;
        \\
        \\    pub fn get_mut(self: &LocalList, index: usize): &i32 {
        \\        return &self.storage[index];
        \\    }
        \\
        \\    pub fn push(self: &LocalList, value: i32): void {
        \\        self.storage[0] = value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var values = LocalList { storage: [1] };
        \\    const first: &i32 = values.get_mut(0);
        \\    values.push(2);
        \\    return first;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "live_list_element_alias_blocks_structural_mutation", source, "cannot mutate container local `values` while overlapping borrow `first` is live");
}

test "live built-in element alias permits different constant index assignment" {
    const source =
        \\fn main(): i32 {
        \\    var values: [:]i32 = [1, 2];
        \\    const first: &i32 = &values[0];
        \\    values[1] = 3;
        \\    return first;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "live_builtin_element_alias_permits_different_constant_index_assignment", source);
}

test "live list element alias blocks same constant index assignment" {
    const source =
        \\struct LocalList {
        \\    storage: [:]i32;
        \\
        \\    pub fn get_mut(self: &LocalList, index: usize): &i32 {
        \\        return &self.storage[index];
        \\    }
        \\
        \\    @syntax.index_set
        \\    fn index_set(self: &LocalList, index: usize, value: i32): void { self.storage[index] = value; }
        \\
        \\}
        \\
        \\
        \\fn main(): i32 {
        \\    var values = LocalList { storage: [1, 2] };
        \\    const first: &i32 = values.get_mut(0);
        \\    values[0] = 3;
        \\    return first;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "live_list_element_alias_blocks_same_constant_index_assignment", source, "cannot index-mutate local `values` while overlapping borrow `first` is live");
}

test "break exit preserves the returned borrow after an otherwise returning loop" {
    const prefix =
        \\struct Box { value: i32; }
        \\fn observe(box: &Box): &i32 { return &box.value; }
        \\fn choose(a: &Box, b: &Box, flag: bool): &i32 {
        \\    while true { if flag { return observe(a); } break; }
        \\    return observe(b);
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "break_returned_borrow", prefix ++
        \\fn probe(flag: bool): i32 {
        \\    var a = new Box { value: 7 };
        \\    var b = new Box { value: 8 };
        \\    const alias = choose(a, b, flag);
        \\    const ptr = b.leak();
        \\    return alias;
        \\}
    , "while borrow `alias` is live");
}

test "optional success returns retain nested borrowed roots" {
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "optional_success_borrow",
        \\struct Box { value: i32; }
        \\struct View { value: &i32; }
        \\enum Failure { invalid; }
        \\fn view(box: &Box, absent: bool): ?View!Failure { if absent { return none; } return View { value: &box.value }; }
        \\fn probe(): i32 {
        \\    var box = new Box { value: 7 };
        \\    const maybe = view(box, false) catch (code) => none;
        \\    if maybe is result {
        \\        const pointer = box.leak();
        \\        return result.value;
        \\    }
        \\    return 0;
        \\}
    , "while borrow");
}

test "nested collection query records each generated reference projection" {
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
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "nested_collection_query", source);
}

test "catch resource alias preserves carrier inference" {
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
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "catch_resource_alias", source);
}

test "catch resource alias fallback cannot escape an arm local owner" {
    const source =
        \\enum Failure { missing; }
        \\struct Item { values: [:]i32; }
        \\fn borrow(item: &const Item): &const [:]i32 ! Failure { return &item.values; }
        \\fn bad(item: &const Item): &const [:]i32 {
        \\    const view = borrow(item) catch (code) {
        \\        const temporary: [:]i32 = [7];
        \\        yield &temporary;
        \\    };
        \\    return view;
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "catch_alias_arm_escape", source, "borrowed values cannot escape");
}

test "alias success return accepts parameter and local carriers" {
    const source =
        \\enum Failure { missing; }
        \\fn borrow(values: &const [:]i32): &const [:]i32 ! Failure { return values; }
        \\fn copied<T>(value: &const T): T { return value; }
        \\fn borrowed_generic<T>(value: &const T): &const T ! Failure { return value; }
        \\fn first(values: &const [:]i32): i32 ! Failure {
        \\    const result = borrow(values);
        \\    const view = try copied(&result);
        \\    const result_alias = try borrowed_generic(&result);
        \\    const recovered = try result_alias;
        \\    assert(recovered[0] == view[0]);
        \\    return view[0];
        \\}
        \\fn local_alias(values: &const [:]i32): &const [:]i32 ! Failure {
        \\    const view: &const [:]i32 = values;
        \\    return view;
        \\}
    ;
    try helpers.expectSemanticSuccess(std.testing.allocator, "alias_success_return", source);
}

test "alias success return retains lifetime ownership and access guards" {
    const prefix =
        \\enum Failure { missing; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "alias_success_return_local_escape", prefix ++
        \\fn bad(): &const [:]i32 ! Failure {
        \\    const values: [:]i32 = [7];
        \\    const view = &values;
        \\    return view;
        \\}
    , "borrowed values cannot escape");
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "alias_success_return_access_amplification", prefix ++
        \\fn bad(values: &const [:]i32): &[:]i32 ! Failure { return values; }
    , "read-only access");
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "alias_success_return_owning_handoff", prefix ++
        \\fn bad(values: &const [:]i32): [:]i32 ! Failure { return values; }
    , "cannot hand off an alias");
}

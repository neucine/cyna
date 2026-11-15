const std = @import("std");
const builtin = @import("builtin");

const cyna = @import("cyna");
const compat = cyna.compat;
const compiler = cyna.compiler;
const lexer = compiler.lexer;
const loader = compiler.loader;
const parser = compiler.parser;
const sema = compiler.sema;
const sir = compiler.sir;
const identity = compiler.identity;
const semantic_types = compiler.semantic_types;
const lowerModule = compiler.lower.lowerModule;
const lowerModuleWithOptions = compiler.lower.lowerModuleWithOptions;

const lir_support = @import("lir_support.zig");

test "LIR lowers self-referential nominal struct fields" {
    const source =
        \\struct Node {
        \\    value: i32;
        \\    next: ?*Node;
        \\}
        \\
        \\fn main(): i32 {
        \\    var tail = new Node { value: 2, next: none };
        \\    var head = new Node { value: 40, next: none };
        \\    return head.value + tail.value;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_recursive_nominal_struct.cy", source);
    defer std.testing.allocator.free(text);
    try std.testing.expect(text.len != 0);
}

test "LIR lowers borrowed projected sparse len through place path" {
    const source =
        \\struct Slots {
        \\    ids: [;]i32;
        \\}
        \\
        \\struct Outer {
        \\    slots: Slots;
        \\}
        \\
        \\fn main(): i32 {
        \\    var outer = Outer {
        \\        slots: Slots { ids: [; 8] [] }
        \\    };
        \\    outer.slots.ids.insert(2, 42);
        \\    return outer.slots.ids.len() as i32;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_borrowed_projected_sparse_len.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_len") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "borrowed_projection sparse_len_from_place") != null);
}

test "LIR lowers borrowed projected sparse insert through place path" {
    const source =
        \\struct Slots {
        \\    ids: [;]i32;
        \\}
        \\
        \\struct Outer {
        \\    slots: Slots;
        \\}
        \\
        \\fn main(): i32 {
        \\    var outer = Outer {
        \\        slots: Slots { ids: [; 8] [] }
        \\    };
        \\    outer.slots.ids.insert(2, 42);
        \\    return outer.slots.ids.len() as i32;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_borrowed_projected_sparse_insert.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_insert") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "borrowed_projection sparse_insert_from_place") != null);
}

test "LIR lowers borrowed projected sparse clear through place path" {
    const source =
        \\struct Slots {
        \\    ids: [;]i32;
        \\}
        \\
        \\struct Outer {
        \\    slots: Slots;
        \\}
        \\
        \\fn main(): i32 {
        \\    var outer = Outer {
        \\        slots: Slots { ids: [; 8] [] }
        \\    };
        \\    outer.slots.ids.insert(2, 42);
        \\    outer.slots.ids.clear();
        \\    return outer.slots.ids.len() as i32;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_borrowed_projected_sparse_clear.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_clear") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "borrowed_projection sparse_clear_from_place") != null);
}

test "LIR lowers borrowed projected sparse indices through place path" {
    const source =
        \\struct Slots {
        \\    ids: [;]i32;
        \\}
        \\
        \\struct Outer {
        \\    slots: Slots;
        \\}
        \\
        \\fn main(): i32 {
        \\    var outer = Outer {
        \\        slots: Slots { ids: [; 8] [] }
        \\    };
        \\    outer.slots.ids.insert(2, 42);
        \\    const ids = outer.slots.ids.indices();
        \\    return ids.len() as i32;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_borrowed_projected_sparse_indices.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_indices") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "borrowed_projection sparse_indices_from_place") != null);
}

test "LIR lowers borrowed projected sparse contains through place path" {
    const source =
        \\struct Slots {
        \\    ids: [;]i32;
        \\}
        \\
        \\struct Outer {
        \\    slots: Slots;
        \\}
        \\
        \\fn main(): i32 {
        \\    var outer = Outer {
        \\        slots: Slots { ids: [; 8] [] }
        \\    };
        \\    outer.slots.ids.insert(2, 42);
        \\    if outer.slots.ids.contains_index(2) {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_borrowed_projected_sparse_contains.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_contains_index") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "borrowed_projection sparse_contains_index_from_place") != null);
}

test "LIR lowers Array params and returns with distinct runtime-array type" {
    const source =
        \\fn passthrough(slots: [:]?i32): [:]?i32 {
        \\    return slots;
        \\}
        \\
        \\fn main(): i32 {
        \\    var slots = [:]?i32 [none];
        \\    slots[0] = 42;
        \\    var out = passthrough(slots);
        \\    if out[0] is n {
        \\        return n;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_array_signature_passthrough.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "fn cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "local#1 out: [:]?i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_fn_") != null);
}

test "LIR lowers dense runtime-array capacity construction with reserve" {
    const source =
        \\fn main(): i32 {
        \\    var buf: [:]i32 = [: 16] [1, 2, 3];
        \\    const view = buf[..];
        \\    return view.len() as i32;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_dense_dense_array_capacity.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "dense_new") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_reserve") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_push") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_len") != null);
}

test "LIR lowers sparse storage construction with sparse runtime call" {
    const source =
        \\fn main(): i32 {
        \\    var slots: [;]i32 = [; 128];
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_sparse_array_construct.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "local#0 slots: [;]i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_new") != null);
}

test "LIR lowers sparse storage inline literal through sparse set calls" {
    const source =
        \\fn main(): i32 {
        \\    var slots: [;]i32 = [; 8] [1, none, 3];
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_sparse_array_inline.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_new") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_set") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_tag") != null);
}

test "LIR lowers sparse storage indices helper call" {
    const source =
        \\fn main(): i32 {
        \\    var slots: [;]i32 = [; 8];
        \\    const ids = slots.indices();
        \\    return ids.len() as i32;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_sparse_array_indices.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_indices") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_len") != null);
}

test "LIR lowers slice map and set function signatures" {
    const source =
        \\fn first(values: []i32): i32 {
        \\    return values[0];
        \\}
        \\
        \\fn make_scores(): Map<string, i32> {
        \\    var scores: Map<string, i32> = map<string, i32>();
        \\    scores["ok"] = 42;
        \\    return scores;
        \\}
        \\
        \\fn make_seen(): Set<i32> {
        \\    var seen: Set<i32> = set<i32>();
        \\    seen.add(42);
        \\    return seen;
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: [1]i32 = [1]i32 [ 42 ];
        \\    var view: []i32 = values[..];
        \\    var seen = make_seen();
        \\    var total: i32 = 0;
        \\    for value in seen {
        \\        total = total + value;
        \\    }
        \\    var scores = make_scores();
        \\    return first(view) + scores["ok"] + total - 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_container_signature_mix.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "fn cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_make_scores(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_make_seen(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_fn_") != null);
}

test "LIR lowers fixed-array struct fields" {
    const source =
        \\struct Bag {
        \\    values: [2]i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var bag = Bag { values: [1, 2] };
        \\    bag.values[0] = 42;
        \\    return bag.values[0];
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_struct_fixed_array_field.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "make_array(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "index_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "stack_alloc [2]i32") == null);
}

test "LIR lowers ranged slice views" {
    const source =
        \\fn main(): i32 {
        \\    var values: [4]i32 = [4]i32 [ 10, 11, 12, 13 ];
        \\    var middle: []i32 = values[1..3];
        \\    var tail: []i32 = values[2..];
        \\    var head: []i32 = values[..2];
        \\    return middle[0] + middle[1] + tail[0] + head[1] - 23;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_slice_range.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "make_slice") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "index_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "int_binop sub") != null);
}

test "LIR lowers list runtime indexing and slice views" {
    const source =
        \\fn set_value(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var xs: List<i32> = list_from<i32>([:]i32 [0, 1]);
        \\    set_value(xs.get_mut(0));
        \\    var view: []i32 = xs.view_mut();
        \\    return view[0];
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_list_runtime.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "List<i32>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_new") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_push") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_at") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_len") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_slice") != null);
}

test "LIR lowers list ranged slice views through ordinary view method" {
    const source =
        \\fn main(): i32 {
        \\    var xs: List<i32> = list_from<i32>([:]i32 [10, 11, 12, 13]);
        \\    var middle: []const i32 = xs.view()[1..3];
        \\    return middle[0] + middle[1] - 23;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_list_slice_range.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_slice") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "int_binop sub") != null);
}

test "LIR lowers for loops over array list slice and set" {
    const source =
        \\fn main(): i32 {
        \\    var total: i32 = 0;
        \\
        \\    const fixed: [3]i32 = [1, 2, 3];
        \\    for value in fixed {
        \\        total = total + value;
        \\    }
        \\
        \\    var xs: List<i32> = list_from<i32>([:]i32 [4, 5]);
        \\    for value in xs {
        \\        total = total + value;
        \\    }
        \\
        \\    const view = xs.view();
        \\    for value in view {
        \\        total = total + value;
        \\    }
        \\
        \\    var seen: Set<i32> = set<i32>();
        \\    seen.add(8);
        \\    seen.add(10);
        \\    for value in seen {
        \\        total = total + value;
        \\    }
        \\
        \\    return total;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_for_iteration.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "bb1_for_cond") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_len") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_indices") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_get") != null);
}

test "LIR lowers for loops over sparse storage as optional slots" {
    const source =
        \\fn main(): i32 {
        \\    var slots: [;]i32 = [; 4];
        \\    for slot in slots {
        \\        if slot is value {
        \\            return value;
        \\        }
        \\    }
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_for_sparse_slots.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_capacity") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_get") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_some") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_none") != null);
}

test "LIR lowers map iteration through prelude methods and sparse storage" {
    const source =
        \\fn main(): i32 {
        \\    var scores: Map<string, i32> = map<string, i32>();
        \\    scores["Ada"] = 10;
        \\    scores["Ken"] = 12;
        \\
        \\    var key_count: i32 = 0;
        \\    for name in scores.keys() {
        \\        if name == "Ada" or name == "Ken" {
        \\            key_count = key_count + 1;
        \\        }
        \\    }
        \\
        \\    var total: i32 = 0;
        \\    for score in scores.values() {
        \\        total = total + score;
        \\    }
        \\
        \\    return total + key_count;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_map_iteration.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Map<string, i32>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_indices") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_get") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_new") != null);
}

test "LIR lowers direct map indexed reads through prelude methods" {
    const source =
        \\fn main(): i32 {
        \\    var scores: Map<string, i32> = map<string, i32>();
        \\    scores["Ada"] = 42;
        \\    return scores["Ada"];
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_map_read.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_indices") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_get") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load %") != null);
}

test "LIR lowers list operations over struct elements with generated descriptors" {
    const source =
        \\struct User {
        \\    id: i32;
        \\    name: string;
        \\}
        \\
        \\fn main(): i32 {
        \\    var users: List<User> = list<User>();
        \\    users.push(User { id: 1, name: "Ada" });
        \\    return users.len() as i32;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_list_struct_desc.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "type_desc User") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_push") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_struct(") != null);
}

const iterator_hook_source =
    \\struct Bag<T> {
    \\    items: [:]T;
    \\    @syntax.iter pub fn begin(self: &const Bag<T>): usize { return 0; }
    \\    @syntax.iter_has_next pub fn more(self: &const Bag<T>, state: &const usize): bool { return state < self.items.len(); }
    \\    @syntax.iter_next pub fn advance(self: &const Bag<T>, state: &usize): usize { const cursor: usize = state; state = state + 1; return cursor; }
    \\    @syntax.iter_item pub fn element(self: &const Bag<T>, cursor: usize): &const T { return &self.items[cursor]; }
    \\}
    \\protocol Readable { fn read(self: &const Self): i32; }
    \\struct Value { number: i32; }
    \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
    \\fn total<T: Readable>(values: &const Bag<T>): i32 {
    \\    var sum: i32 = 0;
    \\    for item in values { sum = sum + item.read(); }
    \\    return sum;
    \\}
    \\fn main(): i32 {
    \\    var values = Bag<Value> { items: [Value { number: 2 }, Value { number: 3 }] };
    \\    return total(&values);
    \\}
;

fn loweredText(allocator: std.mem.Allocator, module: sir.Module) ![]u8 {
    const lir_module = try lowerModule(allocator, module);
    defer lir_module.deinit(allocator);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    try lir_module.dump(&writer.writer);
    out = writer.toArrayList();
    return out.toOwnedSlice(allocator);
}

/// Count emitted `call` lines naming one lowered function, so a test can see
/// that each checked record produced exactly one call.
fn emittedCallCount(text: []const u8, callee: []const u8) usize {
    var calls: usize = 0;
    var position: usize = 0;
    while (std.mem.indexOf(u8, text[position..], callee)) |found| {
        const index = position + found;
        const line_start = std.mem.lastIndexOfScalar(u8, text[0..index], '\n') orelse 0;
        const line = text[line_start..index];
        if (!std.mem.startsWith(u8, line, "fn ") and std.mem.indexOf(u8, line, "call ") != null) calls += 1;
        position = index + callee.len;
    }
    return calls;
}

/// A shallow copy of one function's statement list so a test can corrupt a
/// record without destroying the module the copy came from.
const corrupted_loop = struct {
    functions: []sir.Function,
    body: []sir.Stmt,
    loop: *sir.For,
};

fn corruptedIteratorLoop(allocator: std.mem.Allocator, module: sir.Module) !corrupted_loop {
    const functions = try allocator.dupe(sir.Function, module.functions);
    errdefer allocator.free(functions);
    for (functions) |*function| {
        if (function.body.len == 0) continue;
        for (function.body, 0..) |statement, statement_index| {
            if (statement != .@"for" or statement.@"for".generated_method_uses.len == 0) continue;
            const body = try allocator.dupe(sir.Stmt, function.body);
            errdefer allocator.free(body);
            function.body = body;
            return corrupted_loop{
                .functions = functions,
                .body = body,
                .loop = &body[statement_index].@"for",
            };
        }
    }
    allocator.free(functions);
    return error.TestUnexpectedResult;
}

fn releaseCorruptedLoop(allocator: std.mem.Allocator, copy: corrupted_loop) void {
    // The statement and record allocations still belong to the original
    // module, so only the shallow copies are released here.
    allocator.free(copy.body);
    allocator.free(copy.functions);
}

test "LIR lowers each generated iterator hook from its checked record" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "iter_hooks"
        \\src = "."
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "iter_hooks.cy", .data = iterator_hook_source });
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    const file = try std.fs.path.join(allocator, &.{ root, "iter_hooks.cy" });
    defer allocator.free(file);
    var loaded = try loader.loadProgramWithOptions(allocator, file, .{});
    defer loaded.deinit(allocator);
    var module = try sema.buildSir(allocator, file, loaded.program);
    defer module.deinit(allocator);

    // Lowering emits one call per checked record, so every hook the loop
    // generates appears in the lowered output.
    const text = try loweredText(allocator, module);
    defer allocator.free(text);
    for ([_][]const u8{ "_begin(", "_more(", "_advance(", "_element(" }) |hook| {
        // Each checked record contributes exactly one emitted call.
        try std.testing.expectEqual(@as(usize, 1), emittedCallCount(text, hook));
    }

    var copy = try corruptedIteratorLoop(allocator, module);
    defer releaseCorruptedLoop(allocator, copy);
    var corrupted = module;
    corrupted.functions = copy.functions;
    const records = copy.loop.generated_method_uses;
    try std.testing.expectEqual(@as(usize, 4), records.len);
    const has_next = records[1];

    // A hook the loop reaches with no record of its own does not lower.
    copy.loop.generated_method_uses = records[0..3];
    try std.testing.expectError(error.MissingGeneratedMethodUse, loweredText(allocator, corrupted));
    copy.loop.generated_method_uses = records;

    // Two records claiming one hook role are not two distinct generated uses.
    copy.loop.generated_method_uses[1].role = .iterator_init;
    try std.testing.expectError(error.DuplicateGeneratedMethodUse, loweredText(allocator, corrupted));
    copy.loop.generated_method_uses[1] = has_next;

    // Two records sharing one use identity are not two distinct generated uses.
    copy.loop.generated_method_uses[1].use_id = records[0].use_id;
    try std.testing.expectError(error.DuplicateGeneratedMethodUse, loweredText(allocator, corrupted));
    copy.loop.generated_method_uses[1] = has_next;

    // A record naming a hook the loop does not reach is not lowering authority.
    copy.loop.generated_method_uses[1].method_declaration_id = records[2].method_declaration_id;
    try std.testing.expectError(error.IncorrectGeneratedMethodUse, loweredText(allocator, corrupted));
    copy.loop.generated_method_uses[1] = has_next;

    // A record naming a declaration the module never registered does not lower.
    copy.loop.generated_method_uses[1].method_declaration_id = @fromBackingInt(@intCast(99999));
    try std.testing.expectError(error.IncorrectGeneratedMethodUse, loweredText(allocator, corrupted));
    copy.loop.generated_method_uses[1] = has_next;
}

const print_helper_source =
    \\fn report(count: i64): void {
    \\    println("checked");
    \\    print(true);
    \\    print(count);
    \\}
;

/// One mutable handle per builtin print a module reaches, so a test can
/// corrupt a helper identity without rebuilding the module.
fn printRecords(allocator: std.mem.Allocator, module: sir.Module) ![]*sir.BuiltinPrint {
    var records: std.ArrayListUnmanaged(*sir.BuiltinPrint) = .empty;
    errdefer records.deinit(allocator);
    for (module.expr_metadata) |entry| {
        const expr = @constCast(entry.expr);
        if (expr.* == .builtin_print) try records.append(allocator, &expr.builtin_print);
    }
    return records.toOwnedSlice(allocator);
}

test "LIR lowers each print part from its checked helper identity" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "print_helpers"
        \\src = "."
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "print_helpers.cy", .data = print_helper_source });
    const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(root);
    const file = try std.fs.path.join(allocator, &.{ root, "print_helpers.cy" });
    defer allocator.free(file);
    var loaded = try loader.loadProgramWithOptions(allocator, file, .{});
    defer loaded.deinit(allocator);
    var module = try sema.buildSir(allocator, file, loaded.program);
    defer module.deinit(allocator);

    const records = try printRecords(allocator, module);
    defer allocator.free(records);
    try std.testing.expectEqual(@as(usize, 3), records.len);

    // Lowering emits the helper each printed part and each newline names.
    const text = try loweredText(allocator, module);
    defer allocator.free(text);
    for ([_][]const u8{
        "cyna_std_prelude_print_string(",
        "cyna_std_prelude_print_bool(",
        "cyna_std_prelude_print_int(",
        "cyna_std_prelude_print_newline(",
    }) |helper| {
        try std.testing.expectEqual(@as(usize, 1), emittedCallCount(text, helper));
    }

    const string_parts = @constCast(records[0].parts);
    const string_helper = string_parts[0].value.helper_declaration_id;
    const newline_helper = records[0].newline_helper_declaration_id;

    // A print part with no helper identity is a shape gap, not a name to guess.
    string_parts[0].value.helper_declaration_id = null;
    try std.testing.expectError(error.MissingPrintHelperIdentity, loweredText(allocator, module));
    string_parts[0].value.helper_declaration_id = string_helper;

    // An identity naming a declaration the module never registered is absent.
    string_parts[0].value.helper_declaration_id = @fromBackingInt(@intCast(99999));
    try std.testing.expectError(error.MissingPrintHelperIdentity, loweredText(allocator, module));
    string_parts[0].value.helper_declaration_id = string_helper;

    // An identity that resolves to a different helper is not the helper the
    // part prints through.
    string_parts[0].value.helper_declaration_id = records[1].parts[0].value.helper_declaration_id;
    try std.testing.expectError(error.IncorrectPrintHelperIdentity, loweredText(allocator, module));
    string_parts[0].value.helper_declaration_id = string_helper;

    // A println newline with no helper identity of its own does not lower.
    records[0].newline_helper_declaration_id = null;
    try std.testing.expectError(error.MissingPrintHelperIdentity, loweredText(allocator, module));
    records[0].newline_helper_declaration_id = newline_helper;

    // A function carrying the helper's name but not its shape is not the helper.
    const functions = try allocator.dupe(sir.Function, module.functions);
    defer allocator.free(functions);
    var reshapen = false;
    for (functions) |*function| {
        if (!std.mem.eql(u8, function.name, "print_int")) continue;
        function.params = &.{};
        reshapen = true;
    }
    try std.testing.expect(reshapen);
    var corrupted = module;
    corrupted.functions = functions;
    try std.testing.expectError(error.InvalidPrintHelperSignature, loweredText(allocator, corrupted));
}

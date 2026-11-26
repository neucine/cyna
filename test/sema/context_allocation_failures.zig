const std = @import("std");

const compiler = @import("cyna").compiler;
const lexer = compiler.lexer;
const parser = compiler.parser;
const sema = compiler.sema;

fn parseDestructureWithAllocator(allocator: std.mem.Allocator, source: []const u8, tokens: []const lexer.Token) !void {
    const program = try parser.parse(allocator, "destructure_oom.cy", source, tokens);
    defer program.deinit(allocator);
}

test "destructuring parser releases partial patterns after allocation failure" {
    const source =
        \\fn main(): i32 {
        \\    const values: [:]i32 = [42];
        \\    const [first] = values;
        \\    return first;
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    // The tail covers pattern expansion and ownership of its synthetic locals.
    // Earlier failures exercise preexisting function-declaration recovery.
    try checkAllocationFailuresAtTail(std.testing.allocator, parseDestructureWithAllocator, .{ source, tokens }, 16);
}

test "tuple parser releases nested expression items after allocation failure" {
    const source =
        \\fn main(): i32 {
        \\    const value = (1, (2, 3), 4);
        \\    return 42;
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    try checkAllocationFailuresAtTail(std.testing.allocator, parseDestructureWithAllocator, .{ source, tokens }, 12);
}

test "tuple destructuring parser releases projected pattern nodes after allocation failure" {
    const source =
        \\fn main(): i32 {
        \\    const source = (40, 2);
        \\    const (first, second) = source;
        \\    return first + second;
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    try checkAllocationFailuresAtTail(std.testing.allocator, parseDestructureWithAllocator, .{ source, tokens }, 20);
}

fn compileGenericShapeContract(allocator: std.mem.Allocator, program: compiler.ast.Program) !void {
    const module = try sema.buildSir(allocator, "generic_shape_oom.cy", program);
    module.deinit(allocator);
}

/// Sweeps the allocation points of a build, bounded to `max_indices` of them.
/// A program loaded through the prelude lowers every generic declaration at
/// its definition site, which makes its build carry far more allocation points
/// than a hand-written source; the bound keeps the lane practical while still
/// checking each swept point releases its artifacts. The total count is printed
/// when `CYNA_SEMA_TRACE` is set so the bound stays visible.
fn checkAllocationFailuresUpTo(
    backing_allocator: std.mem.Allocator,
    comptime test_fn: anytype,
    extra_args: anytype,
    max_indices: usize,
) !void {
    const total = x: {
        var failing = std.testing.FailingAllocator.init(backing_allocator, .{});
        try @call(.auto, test_fn, .{failing.allocator()} ++ extra_args);
        break :x failing.alloc_index;
    };
    // A smaller bound can be supplied for a focused run.
    const bound: usize = if (std.c.getenv("CYNA_OOM_SWEEP")) |text|
        std.fmt.parseInt(usize, std.mem.span(text), 10) catch max_indices
    else
        max_indices;
    // A contiguous range of points can be swept with CYNA_OOM_START/END.
    const start: usize = if (std.c.getenv("CYNA_OOM_START")) |text|
        std.fmt.parseInt(usize, std.mem.span(text), 10) catch 0
    else
        0;
    const sweep = @min(total, bound);
    if (std.c.getenv("CYNA_SEMA_TRACE") != null) {
        std.debug.print("allocation points: {d}, sweeping {d}\n", .{ total, sweep });
    }
    for (0..sweep) |sample| {
        // Spread the samples over the whole build so late allocation points in
        // the definition-site lowering are swept as well as the early ones.
        const fail_index = if (start > 0) start + sample else if (sweep == total) sample else sample * total / sweep;
        var failing = std.testing.FailingAllocator.init(backing_allocator, .{ .fail_index = fail_index });
        const completed = @call(.auto, test_fn, .{failing.allocator()} ++ extra_args);
        if (completed) |_| {
            if (failing.allocated_bytes != failing.freed_bytes) {
                std.debug.print("leak at fail_index {d}: allocated {d} freed {d}\n", .{ fail_index, failing.allocated_bytes, failing.freed_bytes });
                return error.MemoryLeakDetected;
            }
            if (failing.has_induced_failure) return error.SwallowedOutOfMemoryError;
            // Process-wide caches can make a later run use fewer allocations.
            // No allocation was forced to fail at this index, so keep sweeping.
            continue;
        } else |err| switch (err) {
            error.OutOfMemory => {
                if (failing.allocated_bytes != failing.freed_bytes) {
                    std.debug.print(
                        "fail_index: {d}/{d}\nallocated bytes: {d}\nfreed bytes: {d}\n",
                        .{ fail_index, total, failing.allocated_bytes, failing.freed_bytes },
                    );
                    return error.MemoryLeakDetected;
                }
            },
            else => return err,
        }
    }
}

fn checkAllocationFailuresAtTail(
    backing_allocator: std.mem.Allocator,
    comptime test_fn: anytype,
    extra_args: anytype,
    tail_count: usize,
) !void {
    const total = x: {
        var counting = std.testing.FailingAllocator.init(backing_allocator, .{});
        try @call(.auto, test_fn, .{counting.allocator()} ++ extra_args);
        break :x counting.alloc_index;
    };
    const start = total -| tail_count;
    for (start..total) |fail_index| {
        var failing = std.testing.FailingAllocator.init(backing_allocator, .{ .fail_index = fail_index });
        const completed = @call(.auto, test_fn, .{failing.allocator()} ++ extra_args);
        if (completed) |_| return error.SwallowedOutOfMemoryError else |err| {
            if (err != error.OutOfMemory and
                (!std.mem.eql(u8, @errorName(err), "ParseFailed") or !failing.has_induced_failure)) return err;
            if (failing.allocated_bytes != failing.freed_bytes) {
                std.debug.print("late failure at {d}/{d}: allocated {d}, freed {d}\n", .{
                    fail_index, total, failing.allocated_bytes, failing.freed_bytes,
                });
                return error.MemoryLeakDetected;
            }
        }
    }
}

test "scalar string switch allocation failures release pattern text" {
    const source =
        \\fn classify(value: string): i32 {
        \\    switch value {
        \\    "first" => { return 1; }
        \\    "second" => { return 2; }
        \\    _ => { return 0; }
        \\    }
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "scalar_switch_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, 256);
}

test "projected global alias allocation failures release checked place paths" {
    const source =
        \\struct Item { value: i32; }
        \\const item: Item = Item { value: 42 };
        \\fn expose(): &const i32 { return &item.value; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "generic_shape_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "projected local reference allocation failures release checked field paths" {
    const source =
        \\struct Box { value: i32; }
        \\fn main(): i32 {
        \\    var box = Box { value: 1 };
        \\    const plain: &i32 = &box.value;
        \\    var owned = new Box { value: 2 };
        \\    const pointed: &i32 = &owned.value;
        \\    return 0;
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "projected_ref_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try compileGenericShapeContract(std.testing.allocator, program);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "indexed borrowed receiver allocation failures release checked slots" {
    const source =
        \\struct Item {
        \\    value: i32;
        \\    fn total(self: &Item): i32 { return self.value; }
        \\}
        \\fn main(): i32 {
        \\    var values: [2]Item = [Item { value: 1 }, Item { value: 2 }];
        \\    const position: i32 = 1;
        \\    return values[0].total() + values[position].total();
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "indexed_ref_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "multi-step reference allocation failures release checked projections" {
    const source =
        \\struct Bag { values: [2]i32; }
        \\struct Outer { bag: Bag; }
        \\fn fields(outer: &Outer): &[2]i32 { return &outer.bag.values; }
        \\fn indexed(outer: &Outer): &i32 { return &outer.bag.values[0]; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "ref_path_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "derived owned field borrow allocation failures release place resolution" {
    const source =
        \\struct Box { value: i32; }
        \\struct Holder { item: ^Box; }
        \\fn observe(box: &Box): &i32 { return &box.value; }
        \\fn read(): i32 {
        \\    var holder = Holder { item: new Box { value: 7 } };
        \\    const alias = observe(holder.item);
        \\    return alias;
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "derived_owner_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "deferred owned handoff allocation failures release reservation snapshot" {
    const source =
        \\struct Box { value: i32; }
        \\fn consume(box: ^Box): void {}
        \\fn probe(): i32 {
        \\    var box = new Box { value: 7 };
        \\    defer consume(box);
        \\    return box.value;
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "deferred_owner_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "union payload receiver allocation failures release checked projections" {
    const source =
        \\struct Box {
        \\    value: i32;
        \\    fn total(self: &Box): i32 { return self.value; }
        \\}
        \\union Choice { value: Box; empty; }
        \\fn read(choice: &Choice): i32 { return choice.value.total(); }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "union_ref_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "raw pointer field assignment allocation failures release checked projections" {
    const source =
        \\struct Box { value: i32; }
        \\struct Holder { box: ^Box; }
        \\fn main(): i32 {
        \\    var holder = new Holder { box: new Box { value: 1 } };
        \\    const ptr: *Holder = holder.ptr();
        \\    unchecked { (*ptr).box = new Box { value: 2 }; }
        \\    return holder.box.value;
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "effect_raw_field_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "field assignment capture allocation failures release checked projections" {
    const source =
        \\struct Box { items: [:]i32; }
        \\fn main(): i32 {
        \\    var box = Box { items: [1, 2] };
        \\    box.items = [42] @ const old;
        \\    return old[0] + box.items[0];
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "field_capture_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "owned array item allocation failures release checked transfers" {
    const source =
        \\struct Box { value: i32; }
        \\struct Holder { box: ^Box; }
        \\fn main(): i32 {
        \\    var boxes: [2]Holder = [Holder { box: new Box { value: 1 } }, Holder { box: new Box { value: 2 } }];
        \\    return boxes[0].box.value;
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "effect_array_items_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    // A no-failure semantic build can use 89 or 90 allocations as process-wide
    // caches settle. Sweep every observed point while retaining leak checks.
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, 128);
}

test "owned tuple member allocation failures release checked transfers" {
    const source =
        \\fn main(): i32 {
        \\    const pair: ([:]i32, i32) = ([40, 2], 0);
        \\    const first = pair.0;
        \\    return first[0] + first[1];
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "effect_tuple_items_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "sparse literal item allocation failures release checked transfers" {
    const source =
        \\struct Profile { scores: [:]i32; }
        \\fn main(): i32 {
        \\    const index: i32 = 1;
        \\    var positional: [;]Profile = [; 3] [Profile { scores: [7] }];
        \\    var keyed: [;]Profile = [; 3] { index: Profile { scores: [8] } };
        \\    return 0;
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "effect_sparse_item_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try compileGenericShapeContract(std.testing.allocator, program);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "projected take allocation failures release checked source paths" {
    const source =
        \\struct Profile { scores: [:]i32; }
        \\struct User { profile: ?Profile; }
        \\fn pull(): ?Profile { var user = User { profile: Profile { scores: [7] } }; return take user.profile; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "effect_field_take_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try compileGenericShapeContract(std.testing.allocator, program);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "indexed take allocation failures release checked source paths" {
    const source =
        \\struct Profile { scores: [:]i32; }
        \\fn pull(): ?Profile { var slots: [:]?Profile = [Profile { scores: [7] }]; return take slots[0]; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "effect_index_take_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "nested indexed take allocation failures release checked source paths" {
    const source =
        \\struct Profile { scores: [:]i32; }
        \\struct Outer { slots: [:]?Profile; }
        \\fn pull(): ?Profile { var outer = Outer { slots: [Profile { scores: [7] }] }; return take outer.slots[0]; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "effect_nested_take_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try compileGenericShapeContract(std.testing.allocator, program);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "sparse take allocation failures release checked source paths" {
    const source =
        \\struct Profile { scores: [:]i32; }
        \\fn pull(): ?Profile { var slots: [;]Profile = [; 2] [Profile { scores: [7] }]; return take slots[0]; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "effect_sparse_take_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "nested sparse take allocation failures release checked source paths" {
    const source =
        \\struct Profile { scores: [:]i32; }
        \\struct Outer { slots: [;]Profile; }
        \\fn pull(i: i32): ?Profile { var outer = Outer { slots: [; 2] [Profile { scores: [7] }] }; return take outer.slots[i]; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "effect_sparse_prefix_take_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "inline error union allocation failures release canonical members" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\fn fail(): i32!First | Second { throw First.bad; }
        \\fn classify(): i32 {
        \\    return fail() catch (code) {
        \\        yield 1;
        \\    };
        \\}
        \\fn main(): i32 { return classify(); }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "inline_result_error_union_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "try error union widening allocation failures release propagation facts" {
    const source =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\union Errors = First | Second;
        \\fn fail(): i32!First { throw First.bad; }
        \\fn named(): i32!Errors { const value = try fail(); return value; }
        \\fn inline(): void!First | Second { const value = try fail(); return; }
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "try_error_union_widen_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "explicit bang return semantic allocation failures" {
    const source =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\fn fail(): i32!First | Second { throw First.bad; }
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "explicit_bang_return_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "contextual error returns release checked payloads on allocation failure" {
    const source =
        \\enum Failure { bad; }
        \\fn success(): i32!Failure { return 7; }
        \\fn failure(): i32!Failure { throw Failure.bad; }
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "contextual_result_return_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "inferred bang error cache releases failures" {
    const source =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\fn first(): i32!First { throw First.bad; }
        \\fn second(): i32!Second { throw Second.bad; }
        \\fn combined(): i32! { const a = try first(); const b = try second(); return a + b; }
        \\fn from_local(): i32! { const value = first(); return try value; }
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "inferred_bang_cache_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "inferred bang unannotated local releases failures" {
    const source =
        \\enum Second { bad; }
        \\fn second(): i32!Second { throw Second.bad; }
        \\fn from_inferred_local(): i32! { const value = second(); return try value; }
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "inferred_bang_unannotated_local_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, 1000);
}

test "inferred bang specialized try releases bindings" {
    const source =
        \\enum Failure { bad; }
        \\fn fail<T>(value: T): T! { throw Failure.bad; }
        \\fn outer(): i32! { return try fail<i32>(1); }
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "inferred_bang_specialized_try_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, 1000);
}

test "inferred bang union carrier releases failures" {
    const source =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\fn source(): i32!First | Second { throw Second.bad; }
        \\fn outer(): i32! { return try source(); }
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "inferred_bang_union_carrier_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, 1000);
}

test "named union result propagation releases failures" {
    const source =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\union Errors = First | Second;
        \\fn source(): i32!Errors { throw Second.bad; }
        \\fn outer(): i32!Errors { return try source(); }
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "named_union_result_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, 1000);
}

test "inferred bang value generic call releases bindings" {
    const source =
        \\enum Failure { bad; }
        \\fn fail<T>(value: T): T! { throw Failure.bad; }
        \\fn outer(): i32! { return try fail(1 as i32); }
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "inferred_bang_value_generic_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, 1000);
}

test "inferred bang union remap releases failures" {
    const source =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\enum Third { bad; }
        \\fn source(): i32!Second | Third { throw Second.bad; }
        \\fn outer(): i32! { if false { throw First.bad; } return try source(); }
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "inferred_bang_union_remap_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, 1000);
}

test "inferred bang switch expression releases scoped locals" {
    const source =
        \\enum Failure { bad; }
        \\fn number(): i32!Failure { throw Failure.bad; }
        \\fn outer(): i32! { return switch 1 { 1 => { const value = number(); yield try value; } _ => 0; }; }
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "inferred_bang_switch_expr_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, 1000);
}

test "catch fallback expression releases failures" {
    const source =
        \\enum Failure { bad; }
        \\fn source(): i32!Failure { throw Failure.bad; }
        \\fn main(): i32 { return source() catch (code) { yield 7; }; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "catch_fallback_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, 1000);
}

test "catch code switch releases failures" {
    const source =
        \\enum Failure { first; second; }
        \\fn source(): i32!Failure { throw Failure.second; }
        \\fn main(): i32 { return source() catch (code) { yield switch code { Failure.first => 1; Failure.second => 2; }; }; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "catch_arms_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, 1000);
}

test "ordinary catch enum union switch releases lowering allocations" {
    const source =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\fn source(): i32!First | Second { throw Second.bad; }
        \\fn main(): i32 {
        \\    return source() catch (code) {
        \\        yield switch code { First.bad => 1; Second.bad => 2; };
        \\    };
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "catch_enum_union_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, 1000);
}

test "catch failure view binding releases lowering allocations" {
    const source =
        \\enum Failure { bad; }
        \\fn source(): i32!Failure { throw Failure.bad; }
        \\fn main(): i32 { return source() catch (code, failure) { yield 1; }; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "catch_failure_view_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, 1000);
}

test "void result catch and successful return release lowering allocations" {
    const source =
        \\enum Failure { bad; }
        \\fn source(): void!Failure { return; }
        \\fn main(): i32 { source() catch (code) { return 1; }; return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "catch_void_result_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, 1000);
}

test "catch rethrow releases failures" {
    const source =
        \\enum Failure { first; second; }
        \\fn source(): i32!Failure { throw Failure.second; }
        \\fn partial(): i32!Failure { return source() catch (code) { if code == Failure.first { yield 7; } throw code; }; }
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "catch_partial_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, 1000);
}

test "catch union rethrow releases generated arms" {
    const source =
        \\enum First { bad; }
        \\enum Second { bad; }
        \\enum Third { bad; }
        \\fn source(): i32!First | Second | Third { throw Third.bad; }
        \\fn partial(): i32! { return source() catch (code) { yield switch code { First(value) => 1; Second(value) => { throw Second.bad; } Third(value) => { throw Third.bad; } }; }; }
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "catch_partial_narrow_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, 1000);
}

test "direct call argument effect allocation failures release records" {
    const source =
        \\struct Box { value: i32; }
        \\fn take(box: ^Box): i32 { return box.value; }
        \\fn main(): i32 { return take(new Box { value: 7 }); }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "effect_call_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "late TaskGroup settlement allocation failures release final SIR" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn settle(group: TaskGroup): void { group.finish(); }
        \\fn main(): i32 { return 0; }
    ;
    const compat = @import("cyna").compat;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data = "entry = \"main.cy\"\n" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root);
    var loaded = try compiler.loader.loadProgram(std.testing.allocator, root);
    defer loaded.deinit(std.testing.allocator);
    try checkAllocationFailuresAtTail(std.testing.allocator, compileGenericShapeContract, .{loaded.program}, 24);
}

test "closure capture effect allocation failures release records" {
    const source =
        \\struct Box { value: i32; }
        \\fn apply(f: (i32) => i32): i32 { return f(1); }
        \\fn main(): i32 {
        \\    var box = new Box { value: 41 };
        \\    return apply(|x| { return x + box.value; });
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "effect_closure_capture_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "generic shape contract allocation failures release analysis and requirement outputs" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Holder<Stored> { item: Stored; }
        \\type Container<Element> = Holder<Element>;
        \\fn inspect<T: Readable>(value: &const Container<T>): i32 { const item = &value.item; return item.read(); }
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "generic_shape_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "generic callback return allocation failures retain identity metadata and ownership" {
    const source =
        \\struct Value { number: i32; }
        \\fn keep(value: Value): Value { return value; }
        \\fn invoke<T>(action: fn(T): T, value: T): T { return action(value); }
        \\fn main(): i32 { const result = invoke<Value>(keep, Value { number: 42 }); return result.number; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "generic_shape_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "generic contextual callback allocation failures release staged arguments" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\fn apply<U>(value: U, action: fn(U): i32): i32 { return action(value); }
        \\fn apply_first<U>(action: fn(U): i32, value: U): i32 { return action(value); }
        \\fn inspect<T: Readable>(value: T): i32 { return apply(value, fn(item) { return item.read(); }); }
        \\fn inspect_first<T: Readable>(value: T): i32 { return apply_first(fn(item) { return item.read(); }, value); }
        \\fn main(): i32 { return inspect<Value>(Value { number: 21 }) + inspect_first<Value>(Value { number: 21 }); }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "generic_shape_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try compileGenericShapeContract(std.testing.allocator, program);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "generic payload contract allocation failures release symbolic capture bindings" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\fn optional<T: Readable>(value: ?T): i32 { if value is item { return item.read(); } return 0; }
        \\fn iterate<T: Readable>(values: []const T): i32 { for item in values { return item.read(); } return 0; }
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "generic_shape_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try compileGenericShapeContract(std.testing.allocator, program);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "generic catch contract allocation failures release payload bindings" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\enum Failure { bad, }
        \\fn produce<T>(value: T): T!Failure { return value; }
        \\fn inspect<T: Readable>(value: T): i32 {
        \\    const item = produce<T>(value) catch (reason) { return 0; };
        \\    return item.read();
        \\}
        \\fn loop<T: Readable>(value: T): i32 {
        \\    var once = true;
        \\    while once { once = false; const item = produce<T>(value) catch (reason) { return 0; }; return item.read(); }
        \\    return 0;
        \\}
        \\fn main(): i32 { const value = Value { number: 21 }; return inspect<Value>(value) + loop<Value>(value); }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "generic_shape_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try compileGenericShapeContract(std.testing.allocator, program);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "generic qualified contract allocation failures release witness call outputs" {
    const source =
        \\protocol CopyValue { fn duplicate(self: &const Self): Self; }
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: CopyValue { fn duplicate(self: &const Value): Value { return Value { number: self.number }; } }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\fn inspect<T: CopyValue & Readable>(value: &const T): i32 { const duplicated = CopyValue.duplicate(value); return Readable.read(&duplicated); }
        \\fn main(): i32 { const value = Value { number: 42 }; return inspect<Value>(&value); }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "generic_shape_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "generic impl contract allocation failures release symbolic substitutions" {
    const source =
        \\protocol Project { type Item; fn project(self: &const Self): Self.Item; }
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\struct Holder<Stored> { item: Stored; }
        \\impl<Element> Holder<Element>: Project { type Item = Element; fn project(self: &const Holder<Element>): Element { return self.item; } }
        \\fn inspect<T: Readable>(holder: &const Holder<T>): i32 { const item = holder.project(); return item.read(); }
        \\fn main(): i32 { const holder = Holder<Value> { item: Value { number: 42 } }; return inspect<Value>(&holder); }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "generic_shape_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "generic language associated allocation failures release loaded symbolic projections" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\fn indexed<T: Readable>(values: &const List<T>): i32 { return values[0].read(); }
        \\fn iterated<T: Readable>(values: &const List<T>): i32 { for item in values { return item.read(); } return 0; }
        \\fn main(): i32 { return 0; }
    ;
    const compat = @import("cyna").compat;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data = "entry = \"main.cy\"\n" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root);
    var loaded = try compiler.loader.loadProgram(std.testing.allocator, root);
    defer loaded.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{loaded.program}, 1000);
}

test "generic constructor contract allocation failures release repeated and keyed values" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\fn inspect<T: Readable>(value: T): i32 {
        \\    const repeated: [2]T = [value] ** 2;
        \\    var slots = [;]T { 0: value };
        \\    if &slots[0] is item { return item.read() + repeated[1].read(); }
        \\    return 0;
        \\}
        \\fn main(): i32 { return inspect<Value>(Value { number: 21 }); }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "generic_shape_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "indirect call effect allocation failures release argument records" {
    const source =
        \\struct Box { value: i32; }
        \\fn identity(value: ^Box): ^Box { return value; }
        \\fn main(): i32 {
        \\    const callback: fn(^Box): ^Box = identity;
        \\    var box = new Box { value: 42 };
        \\    const result = callback(box);
        \\    return result.value;
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "generic_shape_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "break exit allocation failures release branch and loop channels" {
    const source =
        \\fn add(value: &i32): void { value = value + 1; }
        \\fn main(): i32 {
        \\    var value: i32 = 0;
        \\    while value < 3 {
        \\        defer add(&value);
        \\        if value == 0 { break; } else { value = value + 1; }
        \\        const items: [:]i32 = [1, 2];
        \\        for item in items { if item == 1 { break; } }
        \\        break;
        \\    }
        \\    return value;
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "generic_shape_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "enum alias case allocation failures release canonical lookup state" {
    const source =
        \\enum Status { ready = 7; }
        \\type Alias = Status;
        \\type Chain = Alias;
        \\fn main(): void { const value: Status = Chain.ready; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "generic_shape_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "optional success return allocation failures release nested carrier facts" {
    const source =
        \\union Payload { number: i32; }
        \\enum Failure { invalid; }
        \\fn named(): ?Payload!Failure { const value: Payload = .number(42); return value; }
        \\fn literal(): ?Payload!Failure { return .number(42); }
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "generic_shape_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

test "hook indexed field reference allocation failures release generated projections" {
    const source =
        \\struct Leaf { value: i32; fn total(self: &const Leaf): i32 { return self.value; } }
        \\struct Inner { leaf: Leaf; }
        \\struct Outer { inner: Inner; }
        \\struct Bag {
        \\    item: Outer;
        \\    @syntax.index fn at(self: &const Bag, index: i32): &const Outer { return &self.item; }
        \\}
        \\fn main(): i32 {
        \\    const bag = Bag { item: Outer { inner: Inner { leaf: Leaf { value: 42 } } } };
        \\    return bag[0].inner.leaf.total();
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "hook_indexed_field_ref_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "catch resource alias inference releases allocation failures" {
    const source =
        \\enum Failure { missing; }
        \\struct Item { values: [:]i32; }
        \\fn borrow(item: &const Item): &const [:]i32 ! Failure { return &item.values; }
        \\fn read(item: &const Item): i32 {
        \\    const view = borrow(item) catch (code) { return 0; };
        \\    return view[0];
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "catch_resource_alias_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileGenericShapeContract, .{program});
}

test "alias success return allocation failures release contextual carriers" {
    const source =
        \\enum Failure { missing; }
        \\fn borrow(values: &const [:]i32): &const [:]i32 ! Failure { return values; }
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "alias_success_return_oom.cy", source, tokens);
    defer program.deinit(std.testing.allocator);
    try checkAllocationFailuresUpTo(std.testing.allocator, compileGenericShapeContract, .{program}, std.math.maxInt(usize));
}

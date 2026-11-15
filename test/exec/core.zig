const std = @import("std");

test "std.math covers scalar engine math and rounded narrowing" {
    try @import("../helpers.zig").expectNativeSourceExitCode(std.testing.allocator, "std_math.cy",
        \\import std.math;
        \\fn main(): i32 {
        \\    if math.log2_f64(8.0) != 3.0 or math.sqrt_f64(9.0) != 3.0 { return 1; }
        \\    if math.exp_f64(0.0) != 1.0 or math.log_f64(1.0) != 0.0 { return 10; }
        \\    if math.log_f64(math.exp_f64(2.0)) < 1.999999 or math.log_f64(math.exp_f64(2.0)) > 2.000001 { return 11; }
        \\    if math.pow_f64(2.0, 3.0) != 8.0 or math.round_f64(-2.5) != -3.0 { return 2; }
        \\    if math.log2_f32(8.0 as f32) != (3.0 as f32) { return 3; }
        \\    if math.exp2_f32(3.0 as f32) != (8.0 as f32) { return 4; }
        \\    if math.pow_f32(2.0 as f32, 3.0 as f32) != (8.0 as f32) { return 5; }
        \\    if math.floor_f32(-2.25 as f32) != (-3.0 as f32) { return 6; }
        \\    if math.to_f32_rounded(0.1) is value {
        \\        if value == (0.0 as f32) { return 7; }
        \\    } else { return 7; }
        \\    if math.to_f32_rounded(1.000000059604644775390625) is value {
        \\        if value != (1.0 as f32) { return 8; }
        \\    } else { return 8; }
        \\    if math.to_f32_rounded(math.pow_f64(2.0, 200.0)) is value { return 9; }
        \\    return 42;
        \\}
    , 42);
}

test "result-returning main uses success and failure exit statuses" {
    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "result_main_success.cy",
        \\enum Failure { bad; }
        \\fn main(): i32!Failure { return 42; }
    ));
    try std.testing.expectEqual(@as(i64, 1), try test_exec.runNativeSourceExitCode(std.testing.allocator, "result_main_failure.cy",
        \\enum Failure { bad; }
        \\fn main(): i32!Failure { throw Failure.bad, "boom"; }
    ));
}

test "Thread scope exit and explicit drop leave workers running" {
    try @import("../helpers.zig").expectNativeSourceExitCode(std.testing.allocator, "thread_scope_drop.cy",
        \\import std.thread;
        \\import std.time;
        \\import { AtomicI32, MemoryOrder, SyncStatus } from std.sync;
        \\struct Work { counter: AtomicI32; amount: i32; }
        \\@isolated
        \\fn add(work: Work): void { const ignored = work.counter.fetch_add(work.amount, MemoryOrder.seq_cst); }
        \\fn leave_scope(counter: AtomicI32): bool {
        \\    const handle = thread.spawn(add, Work { counter: counter, amount: 1 }) catch (problem) {
        \\        const ignored = problem;
        \\        return false;
        \\    };
        \\    return handle.id().is_valid();
        \\}
        \\fn explicit_drop(counter: AtomicI32): bool {
        \\    const handle = thread.spawn(add, Work { counter: counter, amount: 1 }) catch (problem) {
        \\        const ignored = problem;
        \\        return false;
        \\    };
        \\    drop handle;
        \\    return true;
        \\}
        \\fn main(): i32 {
        \\    const counter = AtomicI32.init(0);
        \\    if not leave_scope(counter) { return 1; }
        \\    if not explicit_drop(counter) { return 2; }
        \\    var tries: i32 = 0;
        \\    while counter.load(MemoryOrder.seq_cst) != 2 and tries < 1000 {
        \\        const ignored = time.sleep_ms(1);
        \\        tries = tries + 1;
        \\    }
        \\    const total = counter.load(MemoryOrder.seq_cst);
        \\    if counter.deinit() != SyncStatus.ok { return 3; }
        \\    return total + 40;
        \\}
    , 42);
}

test "copy of aggregate containing Arc retains independent shared claim" {
    try @import("../helpers.zig").expectNativeSourceExitCode(std.testing.allocator, "shared_aggregate_copy.cy",
        \\import { Arc, arc } from std.own;
        \\struct SharedHolder { shared: Arc<i32>; label: string; }
        \\fn read(value: &i32, ignored: i32): i32 { const unused = ignored; return value; }
        \\fn main(): i32 {
        \\    const original = SharedHolder { shared: arc<i32>(42), label: "ok" };
        \\    const copied = original;
        \\    drop original;
        \\    if copied.label != "ok" { return 1; }
        \\    const value = copied.shared.with_result(0 as i32, read) catch (status) {
        \\        const ignored = status;
        \\        return 2;
        \\    };
        \\    return value;
        \\}
    , 42);
}

test "take optional Arc field leaves aggregate cleanup independent" {
    try @import("../helpers.zig").expectNativeSourceExitCode(std.testing.allocator, "partial_arc_field_take.cy",
        \\import { Arc, arc } from std.own;
        \\struct Holder { shared: ?Arc<i32>; label: string; }
        \\fn read(value: &i32, ignored: i32): i32 { const unused = ignored; return value; }
        \\fn main(): i32 {
        \\    var holder = Holder { shared: arc<i32>(42), label: "ok" };
        \\    const removed = take holder.shared;
        \\    if removed is claim {
        \\        drop holder;
        \\        const value = claim.with_result(0 as i32, read) catch (status) {
        \\            const ignored = status;
        \\            return 2;
        \\        };
        \\        return value;
        \\    }
        \\    return 1;
        \\}
    , 42);
}

test "mixed unique storage shared string and borrowed view move and clean up once" {
    try @import("../helpers.zig").expectNativeSourceExitCode(std.testing.allocator, "mixed_ownership_move.cy",
        \\struct Box { value: i32; }
        \\struct Mixed {
        \\    owner: ^Box;
        \\    label: string;
        \\    values: [:]i32;
        \\    view: []const i32;
        \\}
        \\fn main(): i32 {
        \\    const borrowed_source: [1]i32 = [9];
        \\    var original = Mixed {
        \\        owner: new Box { value: 7 },
        \\        label: "ready",
        \\        values: [1, 2],
        \\        view: borrowed_source[..],
        \\    };
        \\    const moved = original;
        \\    if moved.label != "ready" or moved.values[1] != 2 or moved.view[0] != 9 {
        \\        return 1;
        \\    }
        \\    drop moved;
        \\    return 42;
        \\}
    , 42);
}

test "loop locals and indirect ABI temporaries use bounded stack space" {
    try @import("../helpers.zig").expectNativeSourceExitCode(std.testing.allocator, "loop_bounded_stack.cy",
        \\struct Payload { first: i64; second: i64; third: i64; }
        \\fn invoke(action: fn(Payload): ?Payload, value: Payload): ?Payload { return action(value); }
        \\fn main(): i32 {
        \\    var index: i32 = 0;
        \\    var answer: i32 = 0;
        \\    while index < 200000 {
        \\        const input = Payload { first: 21, second: 7, third: 14 };
        \\        if invoke(fn(value: Payload): ?Payload { return value; }, input) is value {
        \\            answer = (value.first + value.second + value.third) as i32;
        \\        }
        \\        index = index + 1;
        \\    }
        \\    return answer;
        \\}
    , 42);
}

test "std sync shared owns and destroys constructed resource payload" {
    try @import("../helpers.zig").expectNativeSourceExitCode(std.testing.allocator, "shared_owned_payload.cy",
        \\import std.sync;
        \\import { SyncStatus } from std.sync;
        \\struct State { values: List<i32>; }
        \\fn main(): i32 {
        \\    const shared = sync.shared(State { values: [21] });
        \\    assert(shared.with<i32>(21, fn(state: &State, value: i32): void { state.values.push(value); }) == SyncStatus.ok);
        \\    var answer: i32 = 0;
        \\    answer = shared.with_result<i32, i32>(0, fn(state: &State, ignored: i32): i32 { return state.values[0] + state.values[1]; }) catch (status) {
        \\        const ignored = status;
        \\        return 1;
        \\    };
        \\    assert(shared.destroy() == SyncStatus.ok);
        \\    return answer;
        \\}
    , 42);
}
const compat = @import("cyna").compat;
const compiler = @import("cyna").compiler;
const test_exec = @import("../support.zig");

test "std.testing helpers cover common primitive and byte assertions" {
    const source =
        \\import { TestError, expect, expect_eq_bool, expect_eq_bytes, expect_eq_i32, expect_eq_i64, expect_eq_u8, expect_eq_usize } from std.testing;
        \\
        \\fn run(): void!TestError {
        \\    try expect(true);
        \\    try expect_eq_bool(false, false);
        \\    try expect_eq_i32(-7, -7);
        \\    try expect_eq_i64(123456789, 123456789);
        \\    try expect_eq_u8('A', 65);
        \\    try expect_eq_usize("abc".bytes().len(), 3);
        \\    try expect_eq_bytes("abc".bytes(), "abc".bytes());
        \\    return;
        \\}
        \\
        \\fn main(): i32 {
        \\    run() catch (code) { return 1; };
        \\    return 0;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "std_testing_helpers.cy", source));
}

test "std.thread import does not collide with local Thread type" {
    const source =
        \\import { current_id } from std.thread;
        \\
        \\struct Thread {
        \\    value: i32;
        \\}
        \\
        \\fn make(): Thread {
        \\    return Thread { value: 1 };
        \\}
        \\
        \\fn main(): i32 {
        \\    const id = current_id();
        \\    const local = make();
        \\    if id.equals(current_id()) and local.value == 1 {
        \\        return 0;
        \\    }
        \\    return 1;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "std_thread_local_thread_collision.cy", source));
}

test "std.thread TaskGroup init and explicit finish execute through native runtime" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_smoke.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_smoke.cy", source));
}

test "std.thread TaskGroup spawn and join transfer a result through native runtime" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_roundtrip.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_roundtrip.cy", source));
}

test "std.thread TaskGroup preserves a joined failure trace after group finish" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_failure_trace.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_failure_trace.cy", source));
}

test "std.thread TaskGroup releases a discarded failure trace" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_failure_discard.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_failure_discard.cy", source));
}

test "std.thread TaskGroup propagates a joined failure through try" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_failure_propagation.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_failure_propagation.cy", source));
}

test "std.thread TaskGroup polling returns a live failure trace" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_failure_poll.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_failure_poll.cy", source));
}

test "std.thread TaskGroup pending poll retains a later failure trace" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_failure_pending_poll.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_failure_pending_poll.cy", source));
}

test "std.thread TaskGroup nested tasks transfer a failure trace" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_failure_nested.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_failure_nested.cy", source));
}

test "std.thread TaskGroup retires an unobserved failure trace" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_failure_unobserved.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_failure_unobserved.cy", source));
}

test "std.thread TaskGroup retires a discarded nested failure trace" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_failure_nested_discard.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_failure_nested_discard.cy", source));
}

test "std.thread TaskGroup exercises Cava-shaped guest work" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_cava_shape.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_cava_shape.cy", source));
}

test "std.thread TaskGroup context admits a descendant guest" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_descendant.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_descendant.cy", source));
}

test "std.thread TaskGroup exercises viewer request replacement" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_viewer_shape.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 22), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_viewer_shape.cy", source));
}

test "std.thread TaskGroup drops unobserved Task result interest" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_unobserved.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_unobserved.cy", source));
}

test "std.thread TaskGroup joins a void worker" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_void.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_void.cy", source));
}

test "std.thread TaskGroup rejects zero capacity" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_invalid_capacity.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_invalid_capacity.cy", source));
}

test "std.thread TaskGroup polls a void worker" {
    // The worker is held by an atomic gate, so the first poll must be pending.
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_void_poll.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_void_poll.cy", source));
}

test "std.thread TaskGroup polls a cancelled void worker" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_void_cancel_poll.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_void_cancel_poll.cy", source));
}

test "std.thread TaskGroup transfers an owned string result" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_owned_result.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 5), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_owned_result.cy", source));
}

test "std.thread TaskGroup polls an owned string result" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_owned_result_poll.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 0), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_owned_result_poll.cy", source));
}

test "std.thread TaskGroup transfers an owned union payload and result" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_union_result.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 5), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_union_result.cy", source));
}

test "std.thread TaskGroup transfers owned dense storage" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_dense_result.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_dense_result.cy", source));
}

test "std.thread TaskGroup moves a task handle through owned dense storage" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_task_carrier.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_task_carrier.cy", source));
}

test "std.thread TaskGroup transfers a struct containing owned task storage" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_nested_task_carrier.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_nested_task_carrier.cy", source));
}

test "std.thread TaskGroup accepts a nested task carrier constructed at spawn" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_nested_direct_carrier.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_nested_direct_carrier.cy", source));
}

test "std.thread TaskGroup returns a struct containing owned task storage" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_nested_task_result.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_nested_task_result.cy", source));
}

test "std.thread TaskGroup transfers owned sparse storage" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_sparse_result.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_sparse_result.cy", source));
}

test "std.thread TaskGroup moves a task handle through owned sparse storage" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_sparse_task_carrier.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_sparse_task_carrier.cy", source));
}

test "std.thread TaskGroup replaces an affine task handle in owned sparse storage" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_sparse_insert_task_carrier.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_sparse_insert_task_carrier.cy", source));
}

test "std.thread TaskGroup copies an immutable global string carrier" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_global_string.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 10), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_global_string.cy", source));
}

test "std.thread TaskGroup copies an immutable global string through local aliases" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_global_string_alias.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 15), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_global_string_alias.cy", source));
}

test "std.thread TaskGroup polling preserves pending handle" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_poll.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_poll.cy", source));
}

test "std.thread TaskGroup transfers a Task as owned worker input" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_nested_task.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_nested_task.cy", source));
}

test "std.thread TaskGroup transfers an owned string input" {
    const source = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_owned_input.cy", 16 * 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(i64, 5), try test_exec.runNativeSourceExitCode(std.testing.allocator, "task_group_owned_input.cy", source));
}

test "if statements accept else if chains" {
    const source =
        \\fn classify(value: i32): i32 {
        \\    if value < 0 {
        \\        return 1;
        \\    } else if value == 0 {
        \\        return 2;
        \\    } else if value == 42 {
        \\        return 42;
        \\    } else {
        \\        return 3;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return classify(42);
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "else_if_chain.cy", source));
}

test "nested if else binds correctly with else if chains" {
    const source =
        \\fn classify(outer: bool, inner: bool, fallback: bool): i32 {
        \\    if outer {
        \\        if inner {
        \\            return 1;
        \\        } else {
        \\            return 2;
        \\        }
        \\    } else if fallback {
        \\        return 3;
        \\    } else {
        \\        return 4;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    if classify(true, false, false) != 2 {
        \\        return 10;
        \\    }
        \\    if classify(false, true, true) != 3 {
        \\        return 11;
        \\    }
        \\    if classify(false, true, false) != 4 {
        \\        return 12;
        \\    }
        \\    return 42;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "nested_if_else_if.cy", source));
}

test "native runtime writer receives installed writes" {
    const llvm_ir =
        \\declare void @cyna_std_io_install_writer(ptr, ptr)
        \\declare void @cyna_runtime_writer_write(ptr, i64)
        \\declare void @cyna_std_io_clear_writer()
        \\declare void @cyna_test_sink_write(ptr, i64, ptr)
        \\declare i64 @cyna_test_verify_writer()
        \\
        \\@msg0 = private unnamed_addr constant [6 x i8] c"hello\00"
        \\@msg1 = private unnamed_addr constant [2 x i8] c"!\00"
        \\
        \\define i64 @main() {
        \\entry:
        \\  call void @cyna_std_io_install_writer(ptr @cyna_test_sink_write, ptr null)
        \\  %msg0_ptr = getelementptr [6 x i8], ptr @msg0, i64 0, i64 0
        \\  call void @cyna_runtime_writer_write(ptr %msg0_ptr, i64 5)
        \\  %msg1_ptr = getelementptr [2 x i8], ptr @msg1, i64 0, i64 0
        \\  call void @cyna_runtime_writer_write(ptr %msg1_ptr, i64 1)
        \\  call void @cyna_std_io_clear_writer()
        \\  %status = call i64 @cyna_test_verify_writer()
        \\  ret i64 %status
        \\}
    ;

    const sink_helper_source =
        \\#include <stdint.h>
        \\#include <string.h>
        \\
        \\static char cyna_test_sink_buffer[32];
        \\static int64_t cyna_test_sink_len = 0;
        \\
        \\void cyna_test_sink_write(const char *ptr, int64_t len, void *ctx) {
        \\    (void)ctx;
        \\    if (len < 0) return;
        \\    if (cyna_test_sink_len + len > (int64_t)sizeof(cyna_test_sink_buffer)) {
        \\        len = (int64_t)sizeof(cyna_test_sink_buffer) - cyna_test_sink_len;
        \\    }
        \\    if (len <= 0) return;
        \\    memcpy(cyna_test_sink_buffer + cyna_test_sink_len, ptr, (size_t)len);
        \\    cyna_test_sink_len += len;
        \\}
        \\
        \\int64_t cyna_test_verify_writer(void) {
        \\    static const char expected[] = "hello!";
        \\    if (cyna_test_sink_len != 6) return 1;
        \\    if (memcmp(cyna_test_sink_buffer, expected, 6) != 0) return 2;
        \\    return 0;
        \\}
    ;

    const exit_code = try test_exec.compileAndRunNativeIrWithCSources(
        std.testing.allocator,
        llvm_ir,
        .{ .runtime = true },
        &.{
            .{
                .name = "writer_test.c",
                .source = sink_helper_source,
            },
        },
    );
    try std.testing.expectEqual(@as(i64, 0), exit_code);
}

test "native runtime tracked allocations use installed root allocator" {
    const llvm_ir =
        \\declare void @cyna_runtime_clear_root_allocator()
        \\declare i1 @cyna_runtime_has_root_allocator()
        \\declare ptr @cyna_runtime_tracked_alloc(i64)
        \\declare void @cyna_runtime_tracked_free(ptr)
        \\declare void @cyna_test_install_allocator()
        \\declare i64 @cyna_test_verify_allocator()
        \\
        \\define i64 @main() {
        \\entry:
        \\  call void @cyna_runtime_clear_root_allocator()
        \\  call void @cyna_test_install_allocator()
        \\  %has = call i1 @cyna_runtime_has_root_allocator()
        \\  br i1 %has, label %alloc, label %fail
        \\
        \\alloc:
        \\  %ptr = call ptr @cyna_runtime_tracked_alloc(i64 8)
        \\  call void @cyna_runtime_tracked_free(ptr %ptr)
        \\  %status = call i64 @cyna_test_verify_allocator()
        \\  ret i64 %status
        \\
        \\fail:
        \\  ret i64 99
        \\}
    ;

    const allocator_helper_source =
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include <stdlib.h>
        \\
        \\typedef void *(*CynaAllocatorAllocFn)(void *ctx, size_t size);
        \\typedef void *(*CynaAllocatorReallocFn)(void *ctx, void *ptr, size_t size);
        \\typedef void (*CynaAllocatorFreeFn)(void *ctx, void *ptr);
        \\
        \\typedef struct {
        \\    void *ctx;
        \\    CynaAllocatorAllocFn alloc;
        \\    CynaAllocatorReallocFn realloc;
        \\    CynaAllocatorFreeFn free;
        \\} CynaAllocator;
        \\
        \\extern void cyna_runtime_install_root_allocator(CynaAllocator allocator);
        \\extern uint8_t cyna_runtime_has_root_allocator(void);
        \\
        \\static int64_t cyna_test_alloc_calls = 0;
        \\static int64_t cyna_test_free_calls = 0;
        \\
        \\static void *cyna_test_alloc(void *ctx, size_t size) {
        \\    (void)ctx;
        \\    cyna_test_alloc_calls += 1;
        \\    return malloc(size);
        \\}
        \\
        \\static void *cyna_test_realloc(void *ctx, void *ptr, size_t size) {
        \\    (void)ctx;
        \\    return realloc(ptr, size);
        \\}
        \\
        \\static void cyna_test_free(void *ctx, void *ptr) {
        \\    (void)ctx;
        \\    cyna_test_free_calls += 1;
        \\    free(ptr);
        \\}
        \\
        \\void cyna_test_install_allocator(void) {
        \\    cyna_runtime_install_root_allocator((CynaAllocator){
        \\        .ctx = NULL,
        \\        .alloc = cyna_test_alloc,
        \\        .realloc = cyna_test_realloc,
        \\        .free = cyna_test_free,
        \\    });
        \\}
        \\
        \\int64_t cyna_test_verify_allocator(void) {
        \\    if (!cyna_runtime_has_root_allocator()) return 1;
        \\    if (cyna_test_alloc_calls < 1) return 2;
        \\    if (cyna_test_free_calls < 1) return 3;
        \\    return 0;
        \\}
    ;

    const exit_code = try test_exec.compileAndRunNativeIrWithCSources(
        std.testing.allocator,
        llvm_ir,
        .{ .runtime = true },
        &.{
            .{
                .name = "root_allocator_test.c",
                .source = allocator_helper_source,
            },
        },
    );
    try std.testing.expectEqual(@as(i64, 0), exit_code);
}

test "std.alloc builtin module installs bump root allocator" {
    const source =
        \\import std.alloc as rt_alloc;
        \\
        \\fn main(): i32 {
        \\    var heap: [256]u8 = [];
        \\    rt_alloc.init_bump_root(heap[..]);
        \\    if not rt_alloc.has_root() {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;

    const exit_code = try test_exec.runNativeSourceExitCode(
        std.testing.allocator,
        "std_alloc_bump_root.cy",
        source,
    );
    try std.testing.expectEqual(@as(i64, 0), exit_code);
}

test "std.alloc builtin module emits root allocator extern signature" {
    const source =
        \\import std.alloc as rt_alloc;
        \\
        \\fn main(): i32 {
        \\    if rt_alloc.has_root() {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;

    const llvm = try test_exec.emitLlvmSource(
        std.testing.allocator,
        "std_alloc_root_signature.cy",
        source,
    );
    defer std.testing.allocator.free(llvm);

    try std.testing.expect(std.mem.indexOf(u8, llvm, "@cyna_std_alloc_install_root_(void %arg0)") == null);
}

test "std.alloc builtin module keeps RootAllocator param in SIR" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "tmp"
        \\src = "."
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\import std.alloc as rt_alloc;
        \\
        \\fn main(): i32 {
        \\    if rt_alloc.has_root() {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
        ,
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    var loaded = try compiler.loader.loadProgram(std.testing.allocator, root_path);
    defer loaded.deinit(std.testing.allocator);

    const module = try compiler.sema.buildSir(std.testing.allocator, root_path, loaded.program);
    defer module.deinit(std.testing.allocator);

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    var text_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &text);
    try module.dump(&text_writer.writer);
    text = text_writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, text.items, "extern c fn install_root_allocator(allocator: RootAllocator)") != null);
}

test "std.alloc builtin module keeps RootAllocator param in LIR" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "tmp"
        \\src = "."
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\import std.alloc as rt_alloc;
        \\
        \\fn main(): i32 {
        \\    if rt_alloc.has_root() {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
        ,
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    var loaded = try compiler.loader.loadProgram(std.testing.allocator, root_path);
    defer loaded.deinit(std.testing.allocator);

    const sir_module = try compiler.sema.buildSir(std.testing.allocator, root_path, loaded.program);
    defer sir_module.deinit(std.testing.allocator);

    const lir_module = try compiler.lower.lowerModule(std.testing.allocator, sir_module);
    defer lir_module.deinit(std.testing.allocator);

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    var text_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &text);
    try lir_module.dump(&text_writer.writer);
    text = text_writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, text.items, "fn cyna_std_alloc_install_root_(%allocator: void) -> void") == null);
}

test "std.alloc builtin module installs custom root allocator" {
    const source =
        \\import std.alloc as rt_alloc;
        \\import { RootAllocator } from std.alloc;
        \\
        \\extern {
        \\    c("malloc") fn malloc(size: c_size_t): *c_void;
        \\    c("realloc") fn realloc(ptr: *c_void, size: c_size_t): *c_void;
        \\    c("free") fn free(ptr: *c_void): void;
        \\}
        \\
        \\var alloc_calls: i32 = 0;
        \\var free_calls: i32 = 0;
        \\
        \\export c("custom_alloc") fn custom_alloc(_ctx: *c_void, size: c_size_t): *c_void {
        \\    alloc_calls = alloc_calls + 1;
        \\    return malloc(size);
        \\}
        \\
        \\export c("custom_realloc") fn custom_realloc(_ctx: *c_void, ptr: *c_void, size: c_size_t): *c_void {
        \\    alloc_calls = alloc_calls + 1;
        \\    return realloc(ptr, size);
        \\}
        \\
        \\export c("custom_free") fn custom_free(_ctx: *c_void, ptr: *c_void): void {
        \\    free_calls = free_calls + 1;
        \\    free(ptr);
        \\}
        \\
        \\fn main(): i32 {
        \\    rt_alloc.clear_root();
        \\    const allocator = RootAllocator {
        \\        ctx: 0 as! *c_void,
        \\        alloc_fn: custom_alloc,
        \\        realloc_fn: custom_realloc,
        \\        free_fn: custom_free,
        \\    };
        \\    rt_alloc.install_root_allocator(allocator);
        \\    if not rt_alloc.has_root() {
        \\        return 1;
        \\    }
        \\    var xs: List<i32> = list<i32>();
        \\    xs.push(1);
        \\    xs.push(2);
        \\    if xs.len() != 2 {
        \\        return 2;
        \\    }
        \\    if alloc_calls <= 0 {
        \\        return 3;
        \\    }
        \\    drop xs;
        \\    if free_calls <= 0 {
        \\        return 4;
        \\    }
        \\    return 0;
        \\}
    ;

    const exit_code = try test_exec.runNativeSourceExitCode(
        std.testing.allocator,
        "std_alloc_custom_root.cy",
        source,
    );
    try std.testing.expectEqual(@as(i64, 0), exit_code);
}

test "resource locals auto-drop at function scope exit" {
    const source =
        \\import std.alloc as rt_alloc;
        \\import { RootAllocator } from std.alloc;
        \\
        \\extern {
        \\    c("malloc") fn malloc(size: c_size_t): *c_void;
        \\    c("realloc") fn realloc(ptr: *c_void, size: c_size_t): *c_void;
        \\    c("free") fn free(ptr: *c_void): void;
        \\}
        \\
        \\var alloc_calls: i32 = 0;
        \\var free_calls: i32 = 0;
        \\
        \\export c("auto_drop_alloc") fn auto_drop_alloc(_ctx: *c_void, size: c_size_t): *c_void {
        \\    alloc_calls = alloc_calls + 1;
        \\    return malloc(size);
        \\}
        \\
        \\export c("auto_drop_realloc") fn auto_drop_realloc(_ctx: *c_void, ptr: *c_void, size: c_size_t): *c_void {
        \\    alloc_calls = alloc_calls + 1;
        \\    return realloc(ptr, size);
        \\}
        \\
        \\export c("auto_drop_free") fn auto_drop_free(_ctx: *c_void, ptr: *c_void): void {
        \\    free_calls = free_calls + 1;
        \\    free(ptr);
        \\}
        \\
        \\fn build_list(): i32 {
        \\    var xs: List<i32> = list<i32>();
        \\    xs.push(1);
        \\    xs.push(2);
        \\    return xs.len() as i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    rt_alloc.clear_root();
        \\    const allocator = RootAllocator {
        \\        ctx: 0 as! *c_void,
        \\        alloc_fn: auto_drop_alloc,
        \\        realloc_fn: auto_drop_realloc,
        \\        free_fn: auto_drop_free,
        \\    };
        \\    rt_alloc.install_root_allocator(allocator);
        \\    if build_list() != 2 {
        \\        return 1;
        \\    }
        \\    if alloc_calls <= 0 {
        \\        return 2;
        \\    }
        \\    if free_calls <= 0 {
        \\        return 3;
        \\    }
        \\    return 0;
        \\}
    ;

    const exit_code = try test_exec.runNativeSourceExitCode(
        std.testing.allocator,
        "resource_local_auto_drop_scope_exit.cy",
        source,
    );
    try std.testing.expectEqual(@as(i64, 0), exit_code);
}

test "break exits while and for loops and runs only exited scope defers" {
    try @import("../helpers.zig").expectNativeSourceExitCode(std.testing.allocator, "break_cleanup.cy",
        \\fn add(value: &i32, amount: i32): void { value = value + amount; }
        \\enum Choice { stop; }
        \\struct Sequence {
        \\    @syntax.iter fn begin(self: &const Sequence): i32 { return 0; }
        \\    @syntax.iter_has_next fn more(self: &const Sequence, state: &const i32): bool { return state < 3; }
        \\    @syntax.iter_next fn advance(self: &const Sequence, state: &i32): i32 { state = state + 1; return state; }
        \\    @syntax.iter_item fn item(self: &const Sequence, cursor: i32): i32 { return cursor; }
        \\}
        \\fn consume(value: [:]i32): void { assert(value[0] == 7); }
        \\fn after_break<T>(value: T): T { while true { break; } return value; }
        \\fn main(): i32 {
        \\    var total: i32 = 0;
        \\    defer add(&total, 1000);
        \\    while true {
        \\        defer add(&total, 10);
        \\        const local: [:]i32 = [7];
        \\        defer consume(local);
        \\        while true { defer add(&total, 1); break; }
        \\        if total != 1 { return 1; }
        \\        break;
        \\    }
        \\    if total != 11 { return 2; }
        \\    const items: [:]i32 = [1, 2, 3];
        \\    for item in items {
        \\        defer add(&total, item);
        \\        break;
        \\    }
        \\    if total != 12 { return 3; }
        \\    var index = 0;
        \\    while index < 5 {
        \\        index = index + 1;
        \\        if index < 3 { continue; }
        \\        switch Choice.stop { Choice.stop => { defer add(&total, 30); break; } }
        \\        return 4;
        \\    }
        \\    if total != 42 or index != 3 { return 5; }
        \\    const sequence = Sequence {};
        \\    for item in sequence { if item != 1 { return 6; } break; }
        \\    return after_break<i32>(total);
        \\}
    , 42);
}

test "is-test optional values assertions and short circuit conditions" {
    try @import("../helpers.zig").expectNativeSourceExitCode(std.testing.allocator, "is_test_optional.cy",
        \\struct Section { start: usize; }
        \\fn absent(calls: &i32): ?Section { calls = calls + 1; return none; }
        \\fn present(): ?Section { return Section { start: 7 }; }
        \\fn borrowed(value: &const ?Section): bool { return value is none; }
        \\fn main(): i32 {
        \\    var section: ?Section = none;
        \\    var order: u8 = 0;
        \\    const missing = section is none;
        \\    assert(missing);
        \\    assert(borrowed(&section));
        \\    assert(order > 1 or section is none);
        \\    assert(not (present() is none));
        \\    var calls: i32 = 0;
        \\    const skipped_or = true or absent(&calls) is none;
        \\    const skipped_and = false and absent(&calls) is none;
        \\    assert(skipped_or and not skipped_and and calls == 0);
        \\    const evaluated = false or absent(&calls) is none;
        \\    assert(evaluated and calls == 1);
        \\    if order > 1 or section is none { return 42; }
        \\    return 1;
        \\}
    , 42);
}

test "is-test union tags and owned optional subjects preserve cleanup" {
    try @import("../helpers.zig").expectNativeSourceExitCode(std.testing.allocator, "is_test_owned.cy",
        \\struct Box { value: i32; }
        \\union Choice { left: i32; right: i32; }
        \\fn make(): ?^Box { return new Box { value: 7 }; }
        \\fn main(): i32 {
        \\    const choice: Choice = .left(7);
        \\    assert(choice is .left);
        \\    assert(not (choice is .right));
        \\    const owner: ?^Box = make();
        \\    assert(not (owner is none));
        \\    if owner is box { assert(box.value == 7); } else { return 1; }
        \\    assert(not (make() is none));
        \\    var slots = [;]i32 { 2: 7 };
        \\    assert(slots[1] is none);
        \\    assert(not (slots[2] is none));
        \\    var owned_slots = [;]^Box { 2: new Box { value: 9 } };
        \\    assert((&owned_slots[1]) is none);
        \\    assert(not ((&owned_slots[2]) is none));
        \\    if &owned_slots[2] is box { assert(box.value == 9); } else { return 2; }
        \\    return 42;
        \\}
    , 42);
}

test "nullable C pointers round trip through imported and exported parameters and returns" {
    const source =
        \\extern c("nullable_get") fn get(present: c_int): ?*c_uchar;
        \\extern c("nullable_check") fn check(value: ?*c_uchar): c_int;
        \\extern c("nullable_exercise") fn exercise(): c_int;
        \\export c("nullable_roundtrip") fn roundtrip(value: ?*c_uchar): ?*c_uchar { return value; }
        \\export c("nullable_make") fn make(present: c_int): ?*c_uchar { return get(present); }
        \\fn main(): i32 {
        \\    if not (get(0) is none) { return 1; }
        \\    if get(1) is pointer { unchecked { *pointer = 9; } } else { return 2; }
        \\    if check(none) != 0 or check(get(1)) != 1 { return 3; }
        \\    if exercise() != 0 { return 4; }
        \\    if not (roundtrip(none) is none) or not (make(0) is none) { return 5; }
        \\    if check(roundtrip(get(1))) != 1 or check(make(1)) != 1 { return 6; }
        \\    return 42;
        \\}
    ;
    const helper =
        \\#include <stdint.h>
        \\#include <stddef.h>
        \\static uint8_t value;
        \\uint8_t *nullable_get(int32_t present) { return present ? &value : NULL; }
        \\int32_t nullable_check(uint8_t *ptr) { return ptr == &value && value == 9; }
        \\extern uint8_t *nullable_roundtrip(uint8_t *ptr);
        \\extern uint8_t *nullable_make(int32_t present);
        \\int32_t nullable_exercise(void) {
        \\    if (nullable_roundtrip(NULL) != NULL) return 1;
        \\    if (nullable_roundtrip(&value) != &value) return 2;
        \\    if (nullable_make(0) != NULL) return 3;
        \\    if (nullable_make(1) != &value) return 4;
        \\    return 0;
        \\}
    ;
    const allocator = std.testing.allocator;
    const llvm = try test_exec.emitLlvmSource(allocator, "nullable_c_roundtrip.cy", source);
    defer allocator.free(llvm);
    try std.testing.expect(std.mem.indexOf(u8, llvm, "declare ptr @nullable_get(i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm, "define ptr @nullable_roundtrip(ptr") != null);
    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCodeWithCSources(allocator, "nullable_c_roundtrip.cy", source, &.{.{ .name = "nullable.c", .source = helper }}));
}

test "nullable C malloc return supports write read and free" {
    try @import("../helpers.zig").expectNativeSourceExitCode(std.testing.allocator, "nullable_malloc.cy",
        \\extern c("malloc") fn allocate(size: c_size_t): ?*c_void;
        \\extern c("free") fn release(pointer: *c_void): void;
        \\fn main(): i32 {
        \\    const allocation = allocate(8);
        \\    if allocation is none { return 1; }
        \\    unchecked {
        \\        const pointer = allocation as! *u8;
        \\        *pointer = 7;
        \\        const byte = *pointer;
        \\        release(pointer as! *c_void);
        \\        return byte as i32;
        \\    }
        \\}
    , 7);
}

const std = @import("std");
const compat = @import("cyna").compat;
const helpers = @import("../helpers.zig");
const compiler = @import("cyna").compiler;
const ast = compiler.ast;
const lexer = compiler.lexer;
const sema = compiler.sema;
const SemaContext = sema.SemaContext;
const canonical = sema.canonical;
const lookup = sema.lookup;
const registeredOrGeneratedDeclId = sema.registeredOrGeneratedDeclId;
const GlobalBinding = sema.GlobalBinding;
const analyzeThreadBoundaryEntrypoint = sema.analyzeThreadBoundaryEntrypoint;
const validateBoundaryCall = sema.validateBoundaryCall;
const rejectIsolatedCallToFunction = sema.rejectIsolatedCallToFunction;
const typeIsThreadTransferable = sema.typeIsThreadTransferable;
const typeIsThreadShareable = sema.typeIsThreadShareable;
const firstNonTransferableResourcePath = sema.firstNonTransferableResourcePath;
const initCanonicalTestProgram = sema.initCanonicalTestProgram;
const deinitCanonicalTestProgram = sema.deinitCanonicalTestProgram;
const initCanonicalTestTypes = sema.initCanonicalTestTypes;
const deinitCanonicalTestTypes = sema.deinitCanonicalTestTypes;
const canonicalPrimitiveTypeId = canonical.primitiveType;
const canonicalInferredIntegerTypeId = canonical.inferredIntegerType;
const canonicalRefTypeId = canonical.refType;
const canonicalSliceTypeId = canonical.sliceType;
const canonicalRawTypeId = canonical.rawType;
const canonicalArrayTypeId = canonical.arrayType;
const canonicalDenseArrayTypeId = canonical.denseArrayType;
const canonicalSparseArrayTypeId = canonical.sparseArrayType;
const canonicalNominalTypeId = canonical.nominalType;
const canonicalOptionalTypeId = canonical.optionalType;
const canonicalOwnedTypeId = canonical.ownedType;

test "generic task join exposes exact application result type" {
    const source =
        \\import { Task, TaskStatus } from std.thread;
        \\fn take(task: Task<i32>): i32!TaskStatus {
        \\    return task.join();
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "generic_task_join_type", source);
}

test "generic task join supports void results" {
    const source =
        \\import { Task, TaskStatus } from std.thread;
        \\fn take(task: Task<void>): void!TaskStatus { return task.join(); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "generic_task_join_void", source);
}

test "generic task polling preserves pending result interest" {
    const source =
        \\import { Task, TaskStatus } from std.thread;
        \\fn poll(task: &Task<i32>): ?i32!TaskStatus {
        \\    return task.try_join();
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "generic_task_poll_type", source);
}

test "void task polling has a dedicated exact type" {
    const source =
        \\import { Task, TaskStatus, try_join_void } from std.thread;
        \\fn poll(task: &Task<void>): TaskStatus { return try_join_void(task); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "void_task_poll_type", source);
}

test "void task polling rejects result carrying task" {
    const source =
        \\import { Task, TaskStatus, try_join_void } from std.thread;
        \\fn poll(task: &Task<i32>): TaskStatus { return try_join_void(task); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailed(std.testing.allocator, "void_task_poll_nonvoid", source);
}

test "task group spawn infers ordinary named entry input and result" {
    const source =
        \\import { TaskGroup, TaskStatus, Task } from std.thread;
        \\fn worker(value: i32): i32 { return value + 1; }
        \\fn launch(group: &TaskGroup): Task<i32>!TaskStatus {
        \\    return group.spawn(worker, 41);
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_spawn_generic_inference", source);
}

test "task group spawn rejects unsafe named entry" {
    const source =
        \\import { TaskGroup, TaskStatus, Task } from std.thread;
        \\var counter: i32 = 0;
        \\fn worker(value: i32): i32 { counter = value; return value; }
        \\fn launch(group: &TaskGroup): Task<i32>!TaskStatus {
        \\    return group.spawn(worker, 41);
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_spawn_unsafe_entry", source, "concurrency boundary `TaskGroup.spawn` entrypoint `worker` reaches thread-unsafe code");
}

test "task group spawn rejects borrowed input" {
    const source =
        \\import { TaskGroup, TaskStatus, Task } from std.thread;
        \\struct Payload { value: &i32; }
        \\fn worker(value: Payload): i32 { const ignored = value; return 0; }
        \\fn launch(group: &TaskGroup, value: &i32): Task<i32>!TaskStatus {
        \\    return group.spawn(worker, Payload { value: value });
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_spawn_borrowed_input", source, "concurrency boundary `TaskGroup.spawn` payload type");
}

test "task group spawn rejects raw pointer result" {
    const source =
        \\import { TaskGroup, TaskStatus, Task } from std.thread;
        \\fn worker(value: i32): *c_void {
        \\    const ignored = value;
        \\    unchecked { return 0 as! *c_void; }
        \\}
        \\fn launch(group: &TaskGroup): Task<*c_void>!TaskStatus {
        \\    return group.spawn(worker, 41);
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_spawn_raw_result", source, "concurrency boundary `TaskGroup.spawn` result type `*c_void` is not thread-safe to transfer");
}

test "task group accepts transferable named union payload and result" {
    const source =
        \\import { TaskGroup, Task, TaskStatus } from std.thread;
        \\union Payload { text: string; number: i32; }
        \\fn worker(value: Payload): Payload { return value; }
        \\fn launch(group: &TaskGroup, value: Payload): Task<Payload>!TaskStatus {
        \\    return group.spawn(worker, value);
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_union_payload_result", source);
}

test "task group rejects borrowed member of named union payload" {
    const source =
        \\import { TaskGroup, Task, TaskStatus } from std.thread;
        \\union Payload { safe: i32; borrowed: &i32; }
        \\fn worker(value: Payload): i32 { return 1; }
        \\fn launch(group: &TaskGroup, value: Payload): Task<i32>!TaskStatus {
        \\    return group.spawn(worker, value);
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_union_borrowed_payload", source, "resource: Payload.borrowed");
}

test "task group reports borrowed union member inside a struct" {
    const source =
        \\import { TaskGroup, Task, TaskStatus } from std.thread;
        \\union Payload { safe: string; borrowed: &i32; }
        \\struct Envelope { payload: Payload; }
        \\fn worker(value: Envelope): i32 { return 1; }
        \\fn launch(group: &TaskGroup, value: Envelope): Task<i32>!TaskStatus {
        \\    return group.spawn(worker, value);
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_struct_union_borrowed", source, "resource: Envelope.payload.borrowed");
}

test "task group accepts owned dense and sparse storage with transferable items" {
    const source =
        \\import { TaskGroup, Task, TaskStatus } from std.thread;
        \\fn dense_worker(value: [:]i32): [:]i32 { return value; }
        \\fn sparse_worker(value: [;]i32): [;]i32 { return value; }
        \\fn dense(group: &TaskGroup, value: [:]i32): Task<[:]i32>!TaskStatus { return group.spawn(dense_worker, value); }
        \\fn sparse(group: &TaskGroup, value: [;]i32): Task<[;]i32>!TaskStatus { return group.spawn(sparse_worker, value); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_owned_storage_transfer", source);
}

test "task group rejects owned storage containing a borrowed member" {
    const source =
        \\import { TaskGroup, Task, TaskStatus } from std.thread;
        \\struct Item { alias: &i32; }
        \\fn worker(value: [:]Item): void { const ignored = value; }
        \\fn launch(group: &TaskGroup, value: [:]Item): Task<void>!TaskStatus { return group.spawn(worker, value); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_owned_storage_borrowed", source, "resource: [:]Item.item.alias");
}

test "task group owned storage handoff makes source unavailable" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn worker(value: [:]i32): void { const ignored = value; }
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (code) { return 1; };
        \\    const input: [:]i32 = [1, 2];
        \\    const task = group.spawn(worker, input) catch (code) { group.cancel_and_wait(); return 2; };
        \\    const size = input.len();
        \\    task.join() catch (code) { group.cancel_and_wait(); return 3; };
        \\    group.finish();
        \\    return size as i32;
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_dense_source_after_handoff", source, "local `input` was handed off or dropped");
}

test "sparse insertion consumes a task handle" {
    const source =
        \\import { TaskGroup, Task } from std.thread;
        \\fn worker(value: i32): i32 { return value; }
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (code) { return 1; };
        \\    const produced = group.spawn(worker, 42) catch (code) { group.cancel_and_wait(); return 2; };
        \\    var slots: [;]Task<i32> = [; 1];
        \\    slots.insert(0, produced);
        \\    const result = produced.join() catch (code) { group.cancel_and_wait(); return 3; };
        \\    group.finish();
        \\    return result;
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "sparse_task_insert_source_reuse", source, "local `produced` was handed off or dropped");
}

test "nested task carrier constructed at spawn transfers its handle once" {
    const accepted = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_nested_direct_carrier.cy", 16 * 1024);
    defer std.testing.allocator.free(accepted);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "nested_task_carrier_direct", accepted);
    const source =
        \\import { TaskGroup, Task } from std.thread;
        \\struct Carrier { tasks: [:]Task<i32>; }
        \\fn produce(value: i32): i32 { return value; }
        \\fn consume(input: Carrier): i32 { const ignored = input; return 0; }
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(2 as u32) catch (code) { return 1; };
        \\    const produced = group.spawn(produce, 42) catch (code) { group.cancel_and_wait(); return 2; };
        \\    const consumer = group.spawn(consume, Carrier { tasks: [produced] }) catch (code) { group.cancel_and_wait(); return 3; };
        \\    const reused = produced.join() catch (code) { group.cancel_and_wait(); return 4; };
        \\    const ignored = consumer;
        \\    group.finish();
        \\    return reused;
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "nested_task_carrier_reuse", source, "local `produced` was handed off or dropped");
}

test "task global string alias remains available and top-level union owner is rejected" {
    const accepted = try compat.readFileAlloc(std.testing.allocator, "examples/task_group_global_string_alias.cy", 16 * 1024);
    defer std.testing.allocator.free(accepted);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_global_string_alias", accepted);
    const rejected =
        \\import { TaskGroup } from std.thread;
        \\union Payload { text: string; number: i32; }
        \\const global_payload: Payload = .text("hello");
        \\fn worker(value: Payload): Payload { return value; }
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (code) { return 1; };
        \\    const task = group.spawn(worker, global_payload) catch (code) { group.cancel_and_wait(); return 2; };
        \\    const ignored = task;
        \\    group.finish();
        \\    return 0;
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_global_union_owner", rejected, "top-level binding type must be declarative and copy-valued");
}

test "task group owned storage handoff rejects a live borrowed view" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn worker(value: [:]i32): void { const ignored = value; }
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (code) { return 1; };
        \\    const input: [:]i32 = [1, 2];
        \\    const view = input[..];
        \\    const task = group.spawn(worker, input) catch (code) { group.cancel_and_wait(); return 2; };
        \\    const first = view[0];
        \\    task.join() catch (code) { group.cancel_and_wait(); return 3; };
        \\    group.finish();
        \\    return first;
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_dense_live_view_handoff", source, "while borrow `view` is live");
}

test "context-aware task entry may admit an owned child" {
    const source =
        \\import { TaskGroup, TaskContext, TaskStatus, Task } from std.thread;
        \\fn child(context: &TaskContext, value: i32): i32 { const ignored = context.is_cancelled(); return value + 1; }
        \\fn parent(context: &TaskContext, value: i32): i32 {
        \\    const task = context.spawn(child, value) catch (caught_problem_123) {
        \\        const ignored = caught_problem_123; return 0;
        \\    };
        \\    const result = task.join() catch (join_problem) { const ignored = join_problem; return 0; };
        \\    return result;
        \\}
        \\fn launch(group: &TaskGroup): Task<i32>!TaskStatus { return group.spawn_context(parent, 41); }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "context_entry_child", source);
}

test "context-aware task entry cannot return its invocation borrow" {
    const source =
        \\import { TaskGroup, TaskContext, TaskStatus, Task } from std.thread;
        \\fn leak(context: &TaskContext, value: i32): &TaskContext { const ignored = value; return context; }
        \\fn launch(group: &TaskGroup): Task<&TaskContext>!TaskStatus { return group.spawn_context(leak, 1); }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "context_entry_borrow_escape", source, "result type");
}

test "context-aware task entry cannot transfer its context as child input" {
    const source =
        \\import { TaskGroup, TaskContext, TaskStatus, Task } from std.thread;
        \\fn child(context: &TaskContext, borrowed: &TaskContext): i32 { const ignored = context.is_cancelled(); const ignored_borrow = borrowed.is_cancelled(); return 1; }
        \\fn parent(context: &TaskContext, value: i32): i32 {
        \\    const ignored_value = value;
        \\    const task = context.spawn(child, context) catch (caught_problem_148) {
        \\        const ignored = caught_problem_148; return 2;
        \\    };
        \\    const ignored = task.discard(); return 1;
        \\}
        \\fn launch(group: &TaskGroup): Task<i32>!TaskStatus { return group.spawn_context(parent, 1); }
    ;
    try helpers.expectLoadedSemanticFailed(std.testing.allocator, "context_child_borrow_escape", source);
}

test "task group exit does not require a compiler terminal call" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (caught_problem_162) {
        \\        const ignored = caught_problem_162; return 2;
        \\    };
        \\    return 1;
        \\}
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_unsettled_return", source);
}

test "task group explicit protocol permits exits through allocator scopes" {
    const prefix = "import { TaskGroup } from std.thread;\n";
    const rejected = [_][]const u8{
        "fn main(): i32 { using alloc = 0 { const group = TaskGroup.init(1 as u32) catch (init_problem) { const ignored = init_problem; return 1; }; return 0; } }",
        "fn abandon(group: TaskGroup): void { using alloc = 0 { using alloc = 1 { return; } } } fn main(): i32 { return 0; }",
        "fn abandon(group: TaskGroup): void { using alloc = 0 { const ignored = 0; } } fn main(): i32 { return 0; }",
    };
    for (rejected) |body| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, body });
        defer std.testing.allocator.free(source);
        try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_allocator_unsettled", source);
    }
    const accepted = [_][]const u8{
        "fn settle(group: TaskGroup): void { using alloc = 0 { group.finish(); return; } } fn main(): i32 { return 0; }",
        "fn settle(group: TaskGroup): void { using alloc = 0 { using alloc = 1 { group.cancel_and_wait(); } } } fn main(): i32 { return 0; }",
        "fn main(): i32 { using alloc = 0 { const group = TaskGroup.init(1 as u32) catch (init_problem) { const ignored = init_problem; return 1; }; group.finish(); return 0; } }",
    };
    for (accepted) |body| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, body });
        defer std.testing.allocator.free(source);
        try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_allocator_settled", source);
    }
}

test "task group defers may call terminal library methods" {
    const prefix = "import { TaskGroup } from std.thread;\n";
    for ([_][]const u8{
        "fn settle(group: TaskGroup): void { defer group.finish(); } fn main(): i32 { return 0; }",
        "fn settle(group: TaskGroup): void { defer group.cancel_and_wait(); return; } fn main(): i32 { return 0; }",
        "fn settle(group: TaskGroup): void { using alloc = 0 { defer group.finish(); } } fn main(): i32 { return 0; }",
        "fn settle(group: TaskGroup, flag: bool): void { if flag { defer group.finish(); return; } group.cancel_and_wait(); } fn main(): i32 { return 0; }",
    }) |body| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, body });
        defer std.testing.allocator.free(source);
        try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_deferred_settlement", source);
    }
    const rejected = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn abandon(group: TaskGroup): void { return; defer group.finish(); } fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(rejected);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_unreachable_defer", rejected);

    const propagated = try std.mem.concat(std.testing.allocator, u8, &.{
        prefix,
        "import { TaskGroupError } from std.thread; fn fail(): i32!TaskGroupError { throw TaskGroupError.no_memory; } fn settle(group: TaskGroup): i32!TaskGroupError { defer group.finish(); const value = try fail(); return value; } fn main(): i32 { return 0; }",
    });
    defer std.testing.allocator.free(propagated);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_deferred_try_settlement", propagated);
}

test "task group nested value fields do not impose settlement" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "import { TaskGroup } from std.thread;\nstruct Layer0 { group: TaskGroup; }\n");
    for (1..19) |index| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "struct Layer{d} {{ child: Layer{d}; }}\n", .{ index, index - 1 });
        defer std.testing.allocator.free(line);
        try source.appendSlice(std.testing.allocator, line);
    }
    try source.appendSlice(std.testing.allocator, "fn abandon(value: Layer18): void {} fn main(): i32 { return 0; }");
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_deep_value_fields", source.items);
}

test "task group array elements do not impose settlement" {
    const prefix = "import { TaskGroup } from std.thread;\n";
    for ([_][]const u8{
        "fn abandon(groups: [2]TaskGroup): void {} fn main(): i32 { return 0; }",
        "fn partial(groups: [2]TaskGroup): void { groups[0].finish(); } fn main(): i32 { return 0; }",
    }) |body| {
        const rejected = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, body });
        defer std.testing.allocator.free(rejected);
        if (std.mem.indexOf(u8, body, ".finish()") != null)
            try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_array_projected", rejected, "cannot consume concurrency handle through a projected place")
        else
            try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_array_unsettled", rejected);
    }
    const accepted = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn settle(groups: [2]TaskGroup): void { groups[0].finish(); groups[1].finish(); } fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(accepted);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_array_settled", accepted, "cannot consume concurrency handle through a projected place");
}

test "task group handoff into fixed array consumes each source" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn settle(first: TaskGroup, second: TaskGroup): void {
        \\    const groups: [2]TaskGroup = [first, second];
        \\    groups[0].finish();
        \\    groups[1].finish();
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_array_handoff_settled", source, "cannot consume concurrency handle through a projected place");
    const explicit =
        \\import { TaskGroup } from std.thread;
        \\fn settle(first: TaskGroup, second: TaskGroup): void {
        \\    const groups = [2]TaskGroup [first, second];
        \\    groups[0].finish();
        \\    groups[1].finish();
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_explicit_array_handoff_settled", explicit, "cannot consume concurrency handle through a projected place");
}

test "task group branch-local values compile with explicit protocol" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn settle(flag: bool): i32 {
        \\    if flag {
        \\        const group = TaskGroup.init(1 as u32) catch (caught_problem_275) {
        \\            const ignored = caught_problem_275; return 2;
        \\        };
        \\        group.finish(); return 1;
        \\    } else {
        \\        const group = TaskGroup.init(1 as u32) catch (caught_problem_280) {
        \\            const ignored = caught_problem_280; return 4;
        \\        };
        \\        group.cancel_and_wait(); return 3;
        \\    }
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_branch_owner_identities", source);
}

test "task group loop settlement tracks local availability" {
    const prefix = "import { TaskGroup } from std.thread; ";
    const accepted = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn settle(group: TaskGroup): void { while true { group.finish(); return; } } fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(accepted);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_guaranteed_loop_return", accepted);
    const rejected = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn abandon(group: TaskGroup): void { while false { group.finish(); } } fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(rejected);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_zero_iteration_loop", rejected, "local `group` was handed off or dropped");
}

test "task group continue edge does not impose settlement" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn main(): i32 {
        \\    while true {
        \\        const group = TaskGroup.init(1 as u32) catch (caught_problem_306) {
        \\            const ignored = caught_problem_306; return 1;
        \\        };
        \\        continue; group.finish();
        \\    }
        \\}
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_unsettled_continue", source);
    const conditional =
        \\import { TaskGroup } from std.thread;
        \\fn main(): i32 {
        \\    while true {
        \\        const group = TaskGroup.init(1 as u32) catch (caught_problem_318) {
        \\            const ignored = caught_problem_318; return 1;
        \\        };
        \\        if true { continue; } group.finish();
        \\    }
        \\}
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_conditional_continue", conditional);
}

test "task group loop defers may call terminal library methods" {
    const outer =
        \\import { TaskGroup } from std.thread;
        \\fn settle(group: TaskGroup): void {
        \\    var once = true;
        \\    while once { once = false; continue; }
        \\    group.finish();
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_outer_loop_continue", outer);
    const deferred =
        \\import { TaskGroup } from std.thread;
        \\fn main(): i32 {
        \\    while true {
        \\        const group = TaskGroup.init(1 as u32) catch (caught_problem_343) {
        \\            const ignored = caught_problem_343; return 1;
        \\        };
        \\        defer group.finish(); continue;
        \\    }
        \\}
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_deferred_loop_continue", deferred);
}

test "task group repeated loop settlement is rejected" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn settle(group: TaskGroup): void { while true { group.finish(); continue; } }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_repeated_loop_settlement", source, "local `group` was handed off or dropped");
}

test "task group optional captures allow explicit library protocol" {
    const abandoned =
        \\import { TaskGroup } from std.thread;
        \\fn abandon(group: ?TaskGroup): void {}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_optional_abandoned", abandoned);
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn settle(group: ?TaskGroup): void {
        \\    if group is item { item.finish(); }
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_optional_capture_settled", source);
    const nested =
        \\import { TaskGroup } from std.thread;
        \\struct Holder { group: TaskGroup; }
        \\fn settle(value: ?Holder): void {
        \\    if value is item { item.group.finish(); }
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_optional_nested_capture_settled", nested, "cannot consume concurrency handle through a projected place");
    const nested_optional =
        \\import { TaskGroup } from std.thread;
        \\struct Holder { group: ?TaskGroup; }
        \\fn settle(value: ?Holder): void {
        \\    if value is outer { if outer.group is inner { inner.finish(); } }
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_nested_optional_capture_settled", nested_optional);
    const indexed =
        \\import { TaskGroup } from std.thread;
        \\fn settle(value: ?[2]TaskGroup): void {
        \\    if value is items { items[0].finish(); items[1].finish(); }
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_optional_array_capture_settled", indexed, "cannot consume concurrency handle through a projected place");
    const unsettled =
        \\import { TaskGroup } from std.thread;
        \\fn abandon(group: ?TaskGroup): void { if group is item { const ignored = item; } }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_optional_capture_unsettled", unsettled);
}

test "task group union captures allow explicit library protocol" {
    const prefix =
        \\import { TaskGroup } from std.thread;
        \\union Choice { active: TaskGroup; empty; }
    ;
    const abandoned = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn abandon(value: Choice): void {} fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(abandoned);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_union_abandoned", abandoned);
    const settled = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn settle(value: Choice): void { if value is .active(group) { group.finish(); } } fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(settled);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_union_settled", settled);
    const alternatives =
        \\import { TaskGroup } from std.thread;
        \\union Choice { left: TaskGroup; right: TaskGroup; empty; }
        \\fn settle(value: Choice): void {
        \\    if value is .left(left) { left.finish(); }
        \\    else { if value is .right(right) { right.finish(); } }
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_union_alternatives_settled", alternatives);
    const partial =
        \\import { TaskGroup } from std.thread;
        \\union Choice { left: TaskGroup; right: TaskGroup; empty; }
        \\fn abandon(value: Choice): void { if value is .left(left) { left.finish(); } }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_union_alternative_unsettled", partial);
    const switched = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn settle(value: Choice): void { switch value { .active(group) => { group.finish(); } .empty => {} } } fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(switched);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_union_switch_settled", switched);
    const switched_alternatives =
        \\import { TaskGroup } from std.thread;
        \\union Choice { left: TaskGroup; right: TaskGroup; empty; }
        \\fn settle(value: Choice): void {
        \\    switch value {
        \\    .left(left) => { left.finish(); }
        \\    .right(right) => { right.finish(); }
        \\    .empty => {}
        \\    }
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_union_switch_alternatives", switched_alternatives);
    const temporary = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn wrap(group: TaskGroup): Choice { return .active(group); } fn settle(group: TaskGroup): void { if wrap(group) is .active(item) { item.finish(); } } fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(temporary);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_union_temporary_capture_settled", temporary);
    const temporary_unsettled = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn wrap(group: TaskGroup): Choice { return .active(group); } fn abandon(group: TaskGroup): void { if wrap(group) is .active(item) { const ignored = item; } } fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(temporary_unsettled);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_union_temporary_capture_unsettled", temporary_unsettled);
}

test "task group source is unavailable after checked union payload handoff" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\union Choice { active: TaskGroup; empty; }
        \\fn invalid(group: TaskGroup): Choice {
        \\    const choice: Choice = .active(group);
        \\    group.finish();
        \\    return choice;
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_union_source_after_handoff", source, "local `group` was handed off or dropped");
}

test "task group owned pointee does not impose settlement" {
    const prefix =
        \\import { TaskGroup } from std.thread;
        \\struct Owner { group: TaskGroup; }
    ;
    const abandoned = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn abandon(value: ^Owner): void {} fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(abandoned);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_owned_pointee_abandoned", abandoned);
    const settled = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn settle(value: ^Owner): void { value.group.finish(); } fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(settled);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_owned_pointee_settled", settled, "cannot consume concurrency handle through a projected place");
}

test "task group borrowed place still obeys ownership rules" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\struct Owner { group: TaskGroup; }
        \\fn settle(value: &Owner): void { value.group.finish(); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_borrowed_place_cannot_settle", source, "cannot consume a resource method receiver through a borrowed place");
    const nested =
        \\import { TaskGroup } from std.thread;
        \\struct Owner { group: TaskGroup; }
        \\struct Borrowed { owner: &Owner; }
        \\fn settle(value: Borrowed): void { const owner = value.owner; owner.group.finish(); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_nested_borrowed_place_cannot_settle", nested, "cannot consume a resource method receiver through a borrowed place");
    const qualified =
        \\import { TaskGroup } from std.thread;
        \\struct Owner { group: TaskGroup; }
        \\fn settle(value: &Owner): void { TaskGroup.finish(value.group); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_qualified_borrowed_place_cannot_settle", qualified, "cannot consume a resource function argument through a borrowed place");
    const slice =
        \\import { TaskGroup } from std.thread;
        \\struct Owner { group: TaskGroup; }
        \\fn settle(values: []Owner): void { values[0].group.finish(); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_slice_place_cannot_settle", slice, "cannot consume a resource method receiver through a borrowed place");
    const qualified_slice =
        \\import { TaskGroup } from std.thread;
        \\struct Owner { group: TaskGroup; }
        \\fn settle(values: []Owner): void { TaskGroup.finish(values[0].group); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_qualified_slice_place_cannot_settle", qualified_slice, "cannot consume a resource function argument through a borrowed place");
}

test "generic forwarding resolves caller bindings and releases borrow summary facts" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "generic_forwarding_cleanup",
        \\fn inner<T>(value: T): T { return value; }
        \\fn outer<T>(value: T): T { return inner<T>(value); }
        \\fn main(): i32 { return outer<i32>(42); }
    );
}

test "task group conditional exits do not impose settlement" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (caught_problem_541) {
        \\        const ignored = caught_problem_541; return 2;
        \\    };
        \\    if true { group.finish(); return 0; }
        \\    return 1;
        \\}
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_unsettled_branch", source);
}

test "task group terminal method consumes a local handle" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (caught_problem_555) {
        \\        const ignored = caught_problem_555; return 1;
        \\    };
        \\    group.finish(); group.finish(); return 0;
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_double_finish", source, "local `group` was handed off or dropped");
}

test "task join and discard each consume a local handle" {
    const prefix =
        \\import { TaskGroup } from std.thread;
        \\fn worker(value: i32): i32 { return value; }
    ;
    const double_join = prefix ++
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (code) { return 1; };
        \\    const task = group.spawn(worker, 42) catch (code) { group.cancel_and_wait(); return 2; };
        \\    const first = task.join() catch (code) { group.cancel_and_wait(); return 3; };
        \\    const second = task.join() catch (code) { group.cancel_and_wait(); return 4; };
        \\    group.finish();
        \\    return first + second;
        \\}
    ;
    const discard_then_join = prefix ++
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (code) { return 1; };
        \\    const task = group.spawn(worker, 42) catch (code) { group.cancel_and_wait(); return 2; };
        \\    const ignored = task.discard();
        \\    const value = task.join() catch (code) { group.cancel_and_wait(); return 3; };
        \\    group.finish();
        \\    return value;
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "task_double_join", double_join, "local `task` was handed off or dropped");
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "task_discard_then_join", discard_then_join, "local `task` was handed off or dropped");
}

test "task join rejects a projected handle" {
    const source =
        \\import { TaskGroup, Task } from std.thread;
        \\struct Owner { task: Task<i32>; }
        \\fn worker(value: i32): i32 { return value; }
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (code) { return 1; };
        \\    const task = group.spawn(worker, 42) catch (code) { group.cancel_and_wait(); return 2; };
        \\    var owner = Owner { task: task };
        \\    const value = owner.task.join() catch (code) { group.cancel_and_wait(); return 3; };
        \\    group.finish();
        \\    return value;
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "projected_task_join", source, "cannot consume concurrency handle through a projected place; keep the handle in a local");
}

test "qualified task group settlement rejects a projected handle" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\struct Owner { group: TaskGroup; }
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (code) { return 1; };
        \\    const owner = Owner { group: group };
        \\    TaskGroup.finish(owner.group);
        \\    TaskGroup.finish(owner.group);
        \\    return 0;
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "qualified_projected_group_finish", source, "cannot consume concurrency handle through a projected place");
}

test "task group handoff preserves ownership availability" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (caught_problem_568) {
        \\        const ignored = caught_problem_568; return 1;
        \\    };
        \\    const moved = group; moved.finish(); return 0;
        \\}
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_handoff", source);
}

test "nested direct call invalidates the source at its checked argument handoff" {
    const prefix =
        \\import { TaskGroup } from std.thread;
        \\fn relay(group: TaskGroup): TaskGroup { return group; }
        \\fn consume(group: TaskGroup): void {}
    ;
    const accepted = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn run(group: TaskGroup): void { consume(relay(group)); } fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(accepted);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "nested_call_handoff", accepted);

    const rejected = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn run(group: TaskGroup): void { consume(relay(group)); group.finish(); } fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(rejected);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "nested_call_source_after_handoff", rejected, "local `group` was handed off or dropped");
}

test "nested method call invalidates the source at its checked argument handoff" {
    const prefix =
        \\import { TaskGroup } from std.thread;
        \\struct Sink { fn consume(self: &const Sink, group: TaskGroup): void {} }
        \\fn relay(group: TaskGroup): TaskGroup { return group; }
    ;
    const accepted = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn run(sink: Sink, group: TaskGroup): void { sink.consume(relay(group)); } fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(accepted);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "nested_method_handoff", accepted);

    const direct = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn run(sink: Sink, group: TaskGroup): void { sink.consume(group); } fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(direct);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "direct_method_handoff", direct);

    const rejected = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn run(sink: Sink, group: TaskGroup): void { sink.consume(relay(group)); group.finish(); } fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(rejected);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "nested_method_source_after_handoff", rejected, "local `group` was handed off or dropped");

    const rejected_direct = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn run(sink: Sink, group: TaskGroup): void { sink.consume(group); group.finish(); } fn main(): i32 { return 0; }" });
    defer std.testing.allocator.free(rejected_direct);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "direct_method_source_after_handoff", rejected_direct, "local `group` was handed off or dropped");
}

test "task group struct field allows explicit protocol" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\struct Owner { group: TaskGroup; }
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (caught_problem_626) {
        \\        const ignored = caught_problem_626; return 1;
        \\    };
        \\    const owner = Owner { group: group }; owner.group.finish(); return 0;
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "group_field_settle", source, "cannot consume concurrency handle through a projected place");
}

test "task group nested union handoff allows explicit protocol" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\union Choice { active: TaskGroup; empty; }
        \\struct Owner { choice: Choice; }
        \\fn settle(group: TaskGroup): void {
        \\    const owner = Owner { choice: .active(group) };
        \\    if owner.choice is .active(item) { item.finish(); }
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_nested_carrier_settled", source);
}

test "task group struct value may leave without terminal call" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\struct Owner { group: TaskGroup; }
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (caught_problem_654) {
        \\        const ignored = caught_problem_654; return 1;
        \\    };
        \\    const owner = Owner { group: group }; const ignored = owner; return 0;
        \\}
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_field_unsettled", source);
}

test "task group try propagation does not impose settlement" {
    const source =
        \\import { TaskGroup, TaskGroupError } from std.thread;
        \\fn fail(): i32!TaskGroupError { throw TaskGroupError.no_memory; }
        \\fn run(): i32!TaskGroupError {
        \\    const group = TaskGroup.init(1 as u32) catch (caught_problem_668) {
        \\        throw caught_problem_668;
        \\    };
        \\    const value = try fail(); group.finish(); return value;
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_try_escape", source);
}

test "owned result carrier is unavailable after try" {
    const source =
        \\struct Box { value: i32; }
        \\enum Error { failed, }
        \\fn make(): ^Box!Error { return new Box { value: 7 }; }
        \\fn probe(): i32!Error {
        \\    const carrier = make();
        \\    const box = try carrier;
        \\    return box.value;
        \\}
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "owned_try_carrier", source);
    const rejected =
        \\struct Box { value: i32; }
        \\enum Error { failed, }
        \\fn make(): ^Box!Error { return new Box { value: 7 }; }
        \\fn probe(): i32!Error {
        \\    const carrier = make();
        \\    const box = try carrier;
        \\    const again = try carrier;
        \\    return box.value + again.value;
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "owned_try_carrier_reuse", rejected, "local `carrier` was handed off or dropped");
}

test "deferred owned handoff runs at exit and reserves its source" {
    const prefix =
        \\struct Box { value: i32; }
        \\fn consume(box: ^Box): void {}
    ;
    const accepted = prefix ++
        \\fn probe(): i32 {
        \\    var box = new Box { value: 7 };
        \\    defer consume(box);
        \\    return box.value;
        \\}
    ;
    const double_move = prefix ++
        \\fn probe(): i32 {
        \\    var box = new Box { value: 7 };
        \\    defer consume(box);
        \\    consume(box);
        \\    return 0;
        \\}
    ;
    const early_drop = prefix ++
        \\fn probe(): i32 {
        \\    var box = new Box { value: 7 };
        \\    defer consume(box);
        \\    drop box;
        \\    return 0;
        \\}
    ;
    const nested_scope = prefix ++
        \\fn probe(): i32 {
        \\    var box = new Box { value: 7 };
        \\    if true { defer consume(box); }
        \\    return box.value;
        \\}
    ;
    const fallible = prefix ++
        \\enum Error { failed, }
        \\fn maybe(): void!Error { return; }
        \\fn probe(): i32!Error {
        \\    var box = new Box { value: 7 };
        \\    defer consume(box);
        \\    try maybe();
        \\    return box.value;
        \\}
    ;
    const branch_exit = prefix ++
        \\fn probe(flag: bool): i32 {
        \\    var box = new Box { value: 7 };
        \\    if flag { defer consume(box); }
        \\    return box.value;
        \\}
    ;
    const loop_local = prefix ++
        \\fn probe(flag: bool): i32 {
        \\    var once = flag;
        \\    while once {
        \\        once = false;
        \\        var box = new Box { value: 7 };
        \\        defer consume(box);
        \\    }
        \\    return 0;
        \\}
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "deferred_owner_read_before_exit", accepted);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "deferred_owner_error_edge", fallible);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "deferred_owner_loop_local", loop_local);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "deferred_owner_double_move", double_move, "reserved for a deferred handoff");
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "deferred_owner_early_drop", early_drop, "reserved for a deferred handoff");
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "deferred_owner_nested_scope", nested_scope, "handed off or dropped");
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "deferred_owner_branch_exit", branch_exit, "handed off or dropped");
}

test "owned cast carriers are unavailable at the cast" {
    const optional_ok =
        \\struct Box { value: i32; }
        \\fn probe(): i32 {
        \\    const slot: ?^Box = new Box { value: 7 };
        \\    const box = slot as ^Box;
        \\    return box.value;
        \\}
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "owned_optional_cast_handoff", optional_ok);
    const optional_reuse =
        \\struct Box { value: i32; }
        \\fn probe(): i32 {
        \\    const slot: ?^Box = new Box { value: 7 };
        \\    const box = slot as ^Box;
        \\    const again = slot as ^Box;
        \\    return box.value + again.value;
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "owned_optional_cast_reuse", optional_reuse, "local `slot` was handed off or dropped");

    const union_reuse =
        \\struct Box { value: i32; }
        \\union Choice { item: ^Box; empty; }
        \\fn probe(): i32 {
        \\    const choice: Choice = .item(new Box { value: 7 });
        \\    const box = choice as ^Box;
        \\    const again = choice as ^Box;
        \\    return box.value + again.value;
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "owned_union_cast_reuse", union_reuse, "local `choice` was handed off or dropped");
}

test "nested scalar operators keep checked call handoffs" {
    const prefix =
        \\import { TaskGroup } from std.thread;
        \\fn score(group: TaskGroup): i32 { return 1; }
    ;
    const unary = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn run(group: TaskGroup): i32 { const value = -score(group); group.finish(); return value; }" });
    defer std.testing.allocator.free(unary);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "unary_nested_call_handoff", unary, "local `group` was handed off or dropped");

    const binary = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "fn run(group: TaskGroup): i32 { const value = score(group) + 1; group.finish(); return value; }" });
    defer std.testing.allocator.free(binary);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "binary_nested_call_handoff", binary, "local `group` was handed off or dropped");
}

test "owned error success payload is unavailable after call handoff" {
    const source =
        \\struct Box { value: i32; }
        \\enum Error { failed, }
        \\fn carry(box: ^Box): ^Box!Error { return box; }
        \\fn wrap(box: ^Box): ^Box!Error {
        \\    const carrier = carry(box);
        \\    const again = box.value;
        \\    return try carrier;
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "owned_result_payload_reuse", source, "local `box` was handed off or dropped");
}

test "owned leak invalidates the checked source binding" {
    const accepted =
        \\struct Box { value: i32; }
        \\fn leak(): *Box {
        \\    const box = new Box { value: 7 };
        \\    return box.leak();
        \\}
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "owned_leak_checked", accepted);
    const rejected =
        \\struct Box { value: i32; }
        \\fn leak(): i32 {
        \\    const box = new Box { value: 7 };
        \\    const ptr = box.leak();
        \\    return box.value;
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "owned_leak_checked_reuse", rejected, "local `box` was handed off or dropped");
    const borrowed =
        \\struct Box { value: i32; }
        \\fn leak(): *Box {
        \\    const box = new Box { value: 7 };
        \\    const alias = &box.value;
        \\    return box.leak();
        \\}
    ;
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "owned_leak_live_borrow", borrowed, "while borrow `alias` is live");
}

test "task group return transfers a value" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn rehome(group: TaskGroup): TaskGroup { return group; }
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (caught_problem_874) {
        \\        const ignored = caught_problem_874; return 1;
        \\    };
        \\    const moved = rehome(group); moved.finish(); return 0;
        \\}
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_return_transfer", source);
}

test "indirect borrowed TaskGroup call preserves ownership availability" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn observe(group: &TaskGroup): void { const ignored = 0; }
        \\fn settle(group: TaskGroup): void {
        \\    const callback: fn(&TaskGroup): void = observe;
        \\    callback(&group);
        \\    group.finish();
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_indirect_borrow", source);
}

test "task group result return transfers a value" {
    const source =
        \\import { TaskGroup, TaskGroupError } from std.thread;
        \\fn rehome(group: TaskGroup): TaskGroup!TaskGroupError { return group; }
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (init_problem) {
        \\        const ignored = init_problem; return 2;
        \\    };
        \\    const moved = rehome(group) catch (rehome_problem) {
        \\        const ignored = rehome_problem; return 1;
        \\    };
        \\    moved.finish(); return 0;
        \\}
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_result_return_transfer", source);
}

test "task group init result may leave without terminal call" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn main(): i32 {
        \\    const opened = TaskGroup.init(1 as u32);
        \\    const ignored = opened;
        \\    return 0;
        \\}
    ;
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "group_result_uninspected", source);
}

fn concurrencyInferenceSource(allocator: std.mem.Allocator, declarations: []const u8) ![]const u8 {
    return std.mem.concat(allocator, u8, &.{
        "import std.thread;\n",
        declarations,
        "\n",
        \\fn main(): i32 {
        \\    const handle = thread.spawn(worker, 1 as i32) catch (caught_problem_932) {
        \\        const ignored = caught_problem_932; return 1;
        \\    };
        \\    const ignored = handle; return 0;
        \\}
        ,
    });
}

test "concurrency inference follows unsafe immutable callback target" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\var counter: i32 = 0;
        \\fn unsafe_target(value: i32): void { counter = value; }
        \\fn worker(value: i32): void {
        \\    const callback: fn(i32): void = unsafe_target;
        \\    callback(value);
        \\}
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticFailedMessages(std.testing.allocator, "erased_local_callback", source, &.{
        "call chain: worker -> unsafe_target",
        "mutates mutable global `counter`",
    });
}

test "concurrency inference rejects callback parameter through helper" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\var counter: i32 = 0;
        \\fn unsafe_target(value: i32): void { counter = value; }
        \\fn invoke(value: i32, callback: fn(i32): void): void { callback(value); }
        \\fn worker(value: i32): void { invoke(value, unsafe_target); }
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticFailedMessages(std.testing.allocator, "erased_parameter_callback", source, &.{
        "call chain: worker -> invoke -> unsafe_target",
        "mutates mutable global `counter`",
    });
}

test "concurrency inference resolves local callable shadow before named helper" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\var counter: i32 = 0;
        \\fn unsafe_target(value: i32): void { counter = value; }
        \\fn callback(value: i32): void { const ignored = value; }
        \\fn worker(value: i32): void {
        \\    const callback: fn(i32): void = unsafe_target;
        \\    callback(value);
        \\}
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "shadowed_named_callback", source, "call chain: worker -> unsafe_target");
}

test "concurrency inference rejects mutable global interpolation read" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\var counter: i32 = 0;
        \\fn worker(value: i32): void {
        \\    const ignored = value;
        \\    const message = $"counter={counter}";
        \\}
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "interpolated_global_read", source, "function `worker` reads mutable global `counter`");
}

test "concurrency inference accepts ordinary named helpers without qualifiers" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\fn helper(value: i32): i32 { return value + 1; }
        \\fn worker(value: i32): void { const answer = helper(value); }
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "ordinary_named_entry", source);
}

test "concurrency inference preserves safe immutable callback target" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\fn safe_target(value: i32): void { const ignored = value; }
        \\fn worker(value: i32): void {
        \\    const callback: fn(i32): void = safe_target;
        \\    callback(value);
        \\}
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "preserved_safe_callback", source);
}

test "concurrency inference preserves transitive immutable callback aliases" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\fn safe_target(value: i32): void { const ignored = value; }
        \\fn worker(value: i32): void {
        \\    const first: fn(i32): void = safe_target;
        \\    const second: fn(i32): void = first;
        \\    second(value);
        \\}
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "preserved_callback_alias_chain", source);
}

test "concurrency inference does not preserve a mutable callback target" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\var counter: i32 = 0;
        \\fn safe_target(value: i32): void { const ignored = value; }
        \\fn unsafe_target(value: i32): void { counter = value; }
        \\fn worker(value: i32): void {
        \\    var callback: fn(i32): void = safe_target;
        \\    callback = unsafe_target;
        \\    const alias: fn(i32): void = callback;
        \\    alias(value);
        \\}
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "mutable_callback_not_preserved", source, "indirect callable `alias` has no preserved execution contract");
}

test "concurrency inference checks unsafe target through immutable alias chain" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\var counter: i32 = 0;
        \\fn unsafe_target(value: i32): void { counter = value; }
        \\fn worker(value: i32): void {
        \\    const first: fn(i32): void = unsafe_target;
        \\    const second: fn(i32): void = first;
        \\    second(value);
        \\}
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "unsafe_callback_alias_chain", source, "call chain: worker -> unsafe_target");
}

test "concurrency inference resolves scoped immutable callback before global function" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\var counter: i32 = 0;
        \\fn safe_target(value: i32): void { const ignored = value; }
        \\fn callback(value: i32): void { counter = value; }
        \\fn worker(value: i32): void {
        \\    if value > 0 {
        \\        const callback: fn(i32): void = safe_target;
        \\        callback(value);
        \\    }
        \\}
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "innermost_callback_binding", source);
}

test "concurrency inference restores callback provenance after nested scope" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\var counter: i32 = 0;
        \\fn safe_target(value: i32): void { const ignored = value; }
        \\fn callback(value: i32): void { counter = value; }
        \\fn worker(value: i32): void {
        \\    if value > 0 {
        \\        const callback: fn(i32): void = safe_target;
        \\        callback(value);
        \\    }
        \\    callback(value);
        \\}
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "restored_callback_binding", source, "call chain: worker -> callback");
}

test "concurrency inference preserves callback through helper parameters" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\fn safe_target(value: i32): void { const ignored = value; }
        \\fn invoke(value: i32, callback: fn(i32): void): void { callback(value); }
        \\fn forward(value: i32, callback: fn(i32): void): void { invoke(value, callback); }
        \\fn worker(value: i32): void { forward(value, safe_target); }
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "callback_parameter_forwarding", source);
}

test "concurrency inference preserves returned callback through nested helper calls" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\fn safe_target(value: i32): void { const ignored = value; }
        \\fn identity(callback: fn(i32): void): fn(i32): void { return callback; }
        \\fn invoke(value: i32, callback: fn(i32): void): void { callback(value); }
        \\fn worker(value: i32): void { invoke(value, identity(identity(safe_target))); }
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "callback_return_forwarding", source);
}

test "concurrency inference checks returned unsafe callback on invocation" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\var counter: i32 = 0;
        \\fn unsafe_target(value: i32): void { counter = value; }
        \\fn identity(callback: fn(i32): void): fn(i32): void { return callback; }
        \\fn worker(value: i32): void {
        \\    const callback = identity(unsafe_target);
        \\    callback(value);
        \\}
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "unsafe_callback_return", source, "call chain: worker -> unsafe_target");
}

test "concurrency inference does not execute an unused returned callback" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\var counter: i32 = 0;
        \\fn unsafe_target(value: i32): void { counter = value; }
        \\fn factory(): fn(i32): void { return unsafe_target; }
        \\fn worker(value: i32): void { const ignored = factory(); }
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "unused_callback_return", source);
}

test "concurrency inference joins matching callback returns across branches" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\fn safe_target(value: i32): void { const ignored = value; }
        \\fn choose(value: i32): fn(i32): void {
        \\    if value > 0 { return safe_target; } else { return safe_target; }
        \\}
        \\fn worker(value: i32): void { const callback = choose(value); callback(value); }
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "matching_callback_returns", source);
}

test "concurrency inference does not guess conflicting callback returns" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\var counter: i32 = 0;
        \\fn safe_target(value: i32): void { const ignored = value; }
        \\fn unsafe_target(value: i32): void { counter = value; }
        \\fn choose(value: i32): fn(i32): void {
        \\    if value > 0 { return safe_target; } else { return unsafe_target; }
        \\}
        \\fn worker(value: i32): void { const callback = choose(value); callback(value); }
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "conflicting_callback_returns", source, "indirect callable `callback` has no preserved execution contract");
}

test "concurrency inference revisits recursive helper with changed callback target" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\var counter: i32 = 0;
        \\fn safe_target(value: i32): void { const ignored = value; }
        \\fn unsafe_target(value: i32): void { counter = value; }
        \\fn repeat(value: i32, callback: fn(i32): void): void {
        \\    callback(value);
        \\    if value > 0 { repeat(value - 1, unsafe_target); }
        \\}
        \\fn worker(value: i32): void { repeat(value, safe_target); }
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "changed_recursive_callback", source, "call chain: worker -> repeat -> repeat -> unsafe_target");
}

test "concurrency inference accepts recursive helper with unchanged callback target" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\fn safe_target(value: i32): void { const ignored = value; }
        \\fn repeat(value: i32, callback: fn(i32): void): void {
        \\    callback(value);
        \\    if value > 0 { repeat(value - 1, callback); }
        \\}
        \\fn worker(value: i32): void { repeat(value, safe_target); }
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "unchanged_recursive_callback", source);
}

test "concurrency inference keeps reassigned callable parameters forbidden by language rules" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\var counter: i32 = 0;
        \\fn safe_target(value: i32): void { const ignored = value; }
        \\fn unsafe_target(value: i32): void { counter = value; }
        \\fn repeat(value: i32, callback: fn(i32): void): void {
        \\    while value > 0 { callback(value); callback = unsafe_target; }
        \\}
        \\fn worker(value: i32): void { repeat(value, safe_target); }
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "reassigned_callback_loop", source, "cannot assign to const local `callback`");
}

test "concurrency inference checks factory effects before using its returned target" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\var counter: i32 = 0;
        \\fn safe_target(value: i32): void { const ignored = value; }
        \\fn factory(): fn(i32): void { counter = 1; return safe_target; }
        \\fn worker(value: i32): void { const callback = factory(); callback(value); }
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "callback_factory_effects", source, "call chain: worker -> factory");
}

test "concurrency inference leaves recursive callback returns unknown" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\fn safe_target(value: i32): void { const ignored = value; }
        \\fn factory(value: i32): fn(i32): void {
        \\    if value > 0 { return factory(value - 1); } else { return safe_target; }
        \\}
        \\fn worker(value: i32): void { const callback = factory(value); callback(value); }
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "recursive_callback_returns", source, "indirect callable `callback` has no preserved execution contract");
}

test "concurrency inference accepts interpolated local shadow of mutable global" {
    const source = try concurrencyInferenceSource(std.testing.allocator,
        \\var counter: i32 = 0;
        \\fn worker(value: i32): void {
        \\    const counter = value;
        \\    const message = $"counter={counter}";
        \\}
    );
    defer std.testing.allocator.free(source);
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "interpolated_local_shadow", source);
}

test "isolated function accepts params locals and isolated helper" {
    const source =
        \\@concurrency.isolated
        \\fn add_one(value: i32): i32 {
        \\    return value + 1;
        \\}
        \\
        \\@concurrency.isolated
        \\fn worker(job: i32): i32 {
        \\    const base = add_one(job);
        \\    var total = base;
        \\    total = total + 1;
        \\    return total;
        \\}
        \\
        \\fn main(): i32 {
        \\    return worker(40);
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "isolated_accepts_local_work", source);
}

test "isolated attribute is only valid on functions" {
    const source =
        \\@concurrency.isolated
        \\const answer: i32 = 42;
        \\
        \\fn main(): i32 {
        \\    return answer;
        \\}
    ;

    try helpers.expectParseFailedMessage(
        std.testing.allocator,
        "isolated_rejects_const",
        source,
        "attribute `concurrency.isolated` is only supported on functions",
    );
}

test "isolated attribute expects no arguments" {
    const source =
        \\@concurrency.isolated(true)
        \\fn worker(): i32 {
        \\    return 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    return worker();
        \\}
    ;

    try helpers.expectParseFailedMessage(
        std.testing.allocator,
        "isolated_rejects_arguments",
        source,
        "attribute `concurrency.isolated` expects no arguments",
    );
}

test "isolated function rejects mutable global read" {
    const source =
        \\var counter: i32 = 1;
        \\
        \\@concurrency.isolated
        \\fn worker(): i32 {
        \\    return counter;
        \\}
        \\
        \\fn main(): i32 {
        \\    return worker();
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "isolated_rejects_mutable_global_read",
        source,
        "isolated function `worker` cannot read mutable global `counter`",
    );
}

test "isolated function rejects mutable global write" {
    const source =
        \\var counter: i32 = 1;
        \\
        \\@concurrency.isolated
        \\fn worker(): void {
        \\    counter = counter + 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    worker();
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "isolated_rejects_mutable_global_write",
        source,
        "isolated function `worker` cannot mutate mutable global `counter`",
    );
}

test "isolated function rejects non-isolated call" {
    const source =
        \\fn helper(value: i32): i32 {
        \\    return value + 1;
        \\}
        \\
        \\@concurrency.isolated
        \\fn worker(job: i32): i32 {
        \\    return helper(job);
        \\}
        \\
        \\fn main(): i32 {
        \\    return worker(41);
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "isolated_rejects_non_isolated_call",
        source,
        "isolated function `worker` cannot call non-isolated function `helper`",
    );
}

test "isolated function reports root violation through helper chain" {
    const source =
        \\var counter: i32 = 1;
        \\
        \\fn leaf(value: i32): i32 {
        \\    return value + counter;
        \\}
        \\
        \\fn middle(value: i32): i32 {
        \\    return leaf(value);
        \\}
        \\
        \\@concurrency.isolated
        \\fn worker(job: i32): i32 {
        \\    return middle(job);
        \\}
        \\
        \\fn main(): i32 {
        \\    return worker(41);
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "isolated_reports_helper_chain_root_violation",
        source,
        "thread-boundary chain: middle -> leaf; root violation: function `leaf` reads mutable global `counter`",
    );
}

test "isolated function rejects extern call" {
    const source =
        \\extern {
        \\    c fn tick(): void;
        \\}
        \\
        \\@concurrency.isolated
        \\fn worker(): void {
        \\    tick();
        \\}
        \\
        \\fn main(): i32 {
        \\    worker();
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "isolated_rejects_extern_call",
        source,
        "isolated function `worker` cannot call extern function `tick`",
    );
}

test "isolated function accepts trusted extern call" {
    const source =
        \\@concurrency.trusted_extern
        \\extern c("tick") fn tick(): void;
        \\
        \\@concurrency.isolated
        \\fn worker(): void {
        \\    tick();
        \\}
        \\
        \\fn main(): i32 {
        \\    worker();
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "isolated_accepts_trusted_extern", source);
}

test "shareable attribute is std core only" {
    const source =
        \\@concurrency.shareable
        \\struct Mutex {
        \\    value: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "shareable_rejects_user_module",
        source,
        "attribute `concurrency.shareable` is only supported in std/core modules",
    );
}

test "former concurrency attribute spellings are rejected" {
    const old_isolated =
        \\@isolated
        \\fn worker(): void {}
    ;
    try helpers.expectParseFailedMessage(std.testing.allocator, "old_isolated_attribute", old_isolated, "unknown attribute `isolated`");

    const old_resource =
        \\@sync_resource
        \\struct Mutex { value: i32; }
    ;
    try helpers.expectParseFailedMessage(std.testing.allocator, "old_sync_resource_attribute", old_resource, "unknown attribute `sync_resource`");

    const old_extern =
        \\@unchecked_thread_safe
        \\extern c("tick") fn tick(): void;
    ;
    try helpers.expectParseFailedMessage(std.testing.allocator, "old_unchecked_thread_safe_attribute", old_extern, "unknown attribute `unchecked_thread_safe`");
}

test "shared value attribute is std core only" {
    const source =
        \\@shared_value
        \\struct Arc {
        \\    value: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "shared_value_rejects_user_module",
        source,
        "attribute `shared_value` is only supported in std/core modules",
    );
}

test "owned value attribute is std core only" {
    const source =
        \\@ownership.owned
        \\struct Thread {
        \\    raw: c_ulong;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "owned_value_rejects_user_module",
        source,
        "attribute `ownership.owned` is only supported in std/core modules",
    );
}

test "thread spawn reports reachable mutable global field resource" {
    const source =
        \\import std.thread;
        \\
        \\struct ObjectStore {
        \\    count: i32;
        \\}
        \\
        \\struct Heap {
        \\    objects: ObjectStore;
        \\}
        \\
        \\var heap = Heap { objects: ObjectStore { count: 0 } };
        \\
        \\fn worker(value: i32): void {
        \\    heap.objects.count = value;
        \\}
        \\
        \\fn main(): i32 {
        \\    const handle = thread.spawn(worker, 1) catch (caught_problem_1527) {
        \\        const ignored = caught_problem_1527;
        \\        return 1;
        \\    };
        \\    const ignored = handle;
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessage(
        std.testing.allocator,
        "thread_spawn_reports_global_field_resource",
        source,
        "resource: heap.objects.count",
    );
}

test "thread spawn reports reachable mutable global method receiver resource" {
    const source =
        \\import std.thread;
        \\
        \\struct ObjectStore {
        \\    count: i32;
        \\
        \\    fn insert(self: &ObjectStore, value: i32): void {
        \\        self.count = value;
        \\    }
        \\}
        \\
        \\struct Heap {
        \\    objects: ObjectStore;
        \\}
        \\
        \\var heap = Heap { objects: ObjectStore { count: 0 } };
        \\
        \\fn worker(value: i32): void {
        \\    heap.objects.insert(value);
        \\}
        \\
        \\fn main(): i32 {
        \\    const handle = thread.spawn(worker, 1) catch (caught_problem_1567) {
        \\        const ignored = caught_problem_1567;
        \\        return 1;
        \\    };
        \\    const ignored = handle;
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessages(
        std.testing.allocator,
        "thread_spawn_reports_global_method_receiver_resource",
        source,
        &.{
            "resource: heap.objects",
            "function `worker` calls method `insert` on mutable global resource `heap.objects`",
        },
    );
}

test "thread spawn reports nested non-transferable payload resource" {
    const source =
        \\import std.thread;
        \\
        \\struct ObjectStore {
        \\    items: []i32;
        \\}
        \\
        \\struct Heap {
        \\    objects: ObjectStore;
        \\}
        \\
        \\struct VM {
        \\    heap: Heap;
        \\}
        \\
        \\fn worker(vm: VM): void {
        \\    const ignored = vm;
        \\}
        \\
        \\fn main(): i32 {
        \\    var values = [: 4]i32;
        \\    const view = values[..values.len()];
        \\    const vm = VM { heap: Heap { objects: ObjectStore { items: view } } };
        \\    const handle = thread.spawn(worker, vm) catch (caught_problem_1611) {
        \\        const ignored = caught_problem_1611;
        \\        return 1;
        \\    };
        \\    const ignored = handle;
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessage(
        std.testing.allocator,
        "thread_spawn_reports_nested_payload_resource",
        source,
        "resource: VM.heap.objects.items",
    );
}

test "thread spawn reports cava-like vm heap payload resource" {
    const source =
        \\import std.thread;
        \\
        \\struct ObjectStore {
        \\    items: []i32;
        \\
        \\    fn insert(self: &ObjectStore, value: i32): void {
        \\        const ignored = self;
        \\        const ignored_value = value;
        \\    }
        \\}
        \\
        \\struct Heap {
        \\    objects: ObjectStore;
        \\
        \\    fn allocate_object(self: &Heap, value: i32): void {
        \\        self.objects.insert(value);
        \\    }
        \\}
        \\
        \\struct VM {
        \\    heap: Heap;
        \\}
        \\
        \\fn execute_next(vm: &VM): void {
        \\    vm.heap.allocate_object(1);
        \\}
        \\
        \\fn execute_frame(vm: &VM): void {
        \\    execute_next(vm);
        \\}
        \\
        \\fn worker(vm: VM): void {
        \\    var local_vm = vm;
        \\    execute_frame(&local_vm);
        \\}
        \\
        \\fn main(): i32 {
        \\    var values = [: 4]i32;
        \\    const view = values[..values.len()];
        \\    const vm = VM { heap: Heap { objects: ObjectStore { items: view } } };
        \\    const handle = thread.spawn(worker, vm) catch (caught_problem_1670) {
        \\        const ignored = caught_problem_1670;
        \\        return 1;
        \\    };
        \\    const ignored = handle;
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessage(
        std.testing.allocator,
        "thread_spawn_reports_cava_like_vm_heap_payload_resource",
        source,
        "resource: VM.heap.objects.items",
    );
}

test "thread spawn explains borrowed cava-like vm reference payload" {
    const source =
        \\import std.thread;
        \\
        \\struct ObjectStore {
        \\    items: []i32;
        \\
        \\    fn insert(self: &ObjectStore, value: i32): void {
        \\        const ignored = self;
        \\        const ignored_value = value;
        \\    }
        \\}
        \\
        \\struct Heap {
        \\    objects: ObjectStore;
        \\
        \\    fn allocate_object(self: &Heap, value: i32): void {
        \\        self.objects.insert(value);
        \\    }
        \\}
        \\
        \\struct VM {
        \\    heap: Heap;
        \\}
        \\
        \\fn execute_next(vm: &VM): void {
        \\    vm.heap.allocate_object(1);
        \\}
        \\
        \\fn worker(vm: &VM): void {
        \\    execute_next(vm);
        \\}
        \\
        \\fn main(): i32 {
        \\    var values = [: 4]i32;
        \\    const view = values[..values.len()];
        \\    var vm = VM { heap: Heap { objects: ObjectStore { items: view } } };
        \\    const handle = thread.spawn(worker, &vm) catch (caught_problem_1724) {
        \\        const ignored = caught_problem_1724;
        \\        return 1;
        \\    };
        \\    const ignored = handle;
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessages(
        std.testing.allocator,
        "thread_spawn_explains_borrowed_cava_like_vm_reference_payload",
        source,
        &.{
            "reason: alias pointers cannot cross a detached thread boundary",
            "scoped concurrency can allow borrows only for join-before-return work, not detached threads",
        },
    );
}

test "thread spawn accepts sync resource payload field" {
    const source =
        \\import std.thread;
        \\import std.sync;
        \\import { AtomicI32, MemoryOrder } from std.sync;
        \\
        \\struct Work {
        \\    counter: AtomicI32;
        \\    amount: i32;
        \\}
        \\
        \\fn worker(work: Work): void {
        \\    const ignored = work.counter.fetch_add(work.amount, MemoryOrder.seq_cst);
        \\}
        \\
        \\fn main(): i32 {
        \\    const counter = AtomicI32.init(0);
        \\    const handle = thread.spawn(worker, Work { counter: counter, amount: 1 }) catch (caught_problem_1761) {
        \\        const ignored = caught_problem_1761;
        \\        return 1;
        \\    };
        \\    const ignored = handle;
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "thread_spawn_accepts_shareable_payload_field", source);
}

test "std sync share is not public user api" {
    const source =
        \\import std.sync;
        \\
        \\struct State {
        \\    value: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    const shared = sync.share(State { value: 42 });
        \\    const ignored = shared;
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessage(
        std.testing.allocator,
        "std_sync_share_is_not_public_user_api",
        source,
        "has no namespace function `share`",
    );
}

test "thread spawn accepts vm composed of concurrent container resources" {
    const source =
        \\import std.thread;
        \\import std.sync;
        \\import { ConcurrentList, ConcurrentSlotMap } from std.sync;
        \\
        \\struct Heap {
        \\    objects: ConcurrentSlotMap<i32>;
        \\    threads: ConcurrentList<i32>;
        \\}
        \\
        \\struct VM {
        \\    heap: Heap;
        \\}
        \\
        \\fn worker(vm: VM): void {
        \\    var local_vm = vm;
        \\    const object_count = local_vm.heap.objects.len();
        \\    const thread_count = local_vm.heap.threads.len();
        \\    const ignored_objects = object_count;
        \\    const ignored_threads = thread_count;
        \\}
        \\
        \\fn main(): i32 {
        \\    var vm = VM {
        \\        heap: Heap {
        \\            objects: sync.concurrent_slot_map<i32>(),
        \\            threads: sync.concurrent_list<i32>()
        \\        }
        \\    };
        \\    const handle = thread.spawn(worker, vm) catch (caught_problem_1826) {
        \\        const ignored = caught_problem_1826;
        \\        return 1;
        \\    };
        \\    const ignored = handle;
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "thread_spawn_accepts_vm_composed_of_concurrent_container_resources", source);
}

test "thread spawn rejects cloned vm handle composed of unique concurrent containers" {
    const source =
        \\import std.thread;
        \\import std.sync;
        \\import { ConcurrentList, ConcurrentSlotMap } from std.sync;
        \\
        \\struct Heap {
        \\    objects: ConcurrentSlotMap<i32>;
        \\    threads: ConcurrentList<i32>;
        \\
        \\    pub fn clone(self: &Heap): Heap {
        \\        return Heap {
        \\            objects: self.objects.clone(),
        \\            threads: self.threads.clone()
        \\        };
        \\    }
        \\}
        \\
        \\struct VM {
        \\    heap: Heap;
        \\
        \\    pub fn clone(self: &VM): VM {
        \\        return VM {
        \\            heap: self.heap.clone()
        \\        };
        \\    }
        \\}
        \\
        \\fn worker(vm: VM): void {
        \\    var local_vm = vm;
        \\    const object_count = local_vm.heap.objects.len();
        \\    const thread_count = local_vm.heap.threads.len();
        \\    const ignored_objects = object_count;
        \\    const ignored_threads = thread_count;
        \\}
        \\
        \\fn start(vm: &VM): void {
        \\    const handle = thread.spawn(worker, vm.clone()) catch (caught_problem_1875) {
        \\        const ignored = caught_problem_1875;
        \\        return;
        \\    };
        \\    const ignored = handle;
        \\}
        \\
        \\fn main(): i32 {
        \\    var vm = VM {
        \\        heap: Heap {
        \\            objects: sync.concurrent_slot_map<i32>(),
        \\            threads: sync.concurrent_list<i32>()
        \\        }
        \\    };
        \\    start(&vm);
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "thread_spawn_rejects_cloned_vm_handle_composed_of_concurrent_containers", source, "clone");
}

test "Thread handle cannot be used after by-value handoff" {
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "thread_handle_after_handoff",
        \\import std.thread;
        \\struct Work { value: i32; }
        \\fn worker(work: Work): void { const ignored = work.value; }
        \\fn main(): i32 {
        \\    const handle = thread.spawn(worker, Work { value: 1 }) catch (caught_problem_1902) {
        \\        const ignored = caught_problem_1902; return 1;
        \\    };
        \\    const moved = handle;
        \\    const id = handle.id();
        \\    const ignored = id;
        \\    drop moved;
        \\    return 42;
        \\}
    , "local `handle` was handed off or dropped");
}

test "thread spawn accepts arc vm handle composed of concurrent containers" {
    const source =
        \\import std.thread;
        \\import std.own;
        \\import std.sync;
        \\import { Arc } from std.own;
        \\import { ConcurrentList, ConcurrentSlotMap } from std.sync;
        \\
        \\struct Heap {
        \\    objects: ConcurrentSlotMap<i32>;
        \\    threads: ConcurrentList<i32>;
        \\}
        \\
        \\struct VM {
        \\    heap: Heap;
        \\}
        \\
        \\fn worker(vm: Arc<VM>): void {
        \\    const ignored = vm;
        \\}
        \\
        \\fn main(): i32 {
        \\    var vm = own.arc(VM {
        \\        heap: Heap {
        \\            objects: sync.concurrent_slot_map<i32>(),
        \\            threads: sync.concurrent_list<i32>()
        \\        }
        \\    });
        \\    const handle = thread.spawn(worker, vm) catch (caught_problem_1942) {
        \\        const ignored = caught_problem_1942;
        \\        return 1;
        \\    };
        \\    const ignored = handle;
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "thread_spawn_accepts_arc_vm_handle_composed_of_concurrent_containers", source);
}

test "thread spawn rejects arc vm handle with raw mutable containers" {
    const source =
        \\import std.thread;
        \\import std.own;
        \\import { Arc } from std.own;
        \\
        \\struct Heap {
        \\    objects: SlotMap<i32>;
        \\    threads: List<i32>;
        \\}
        \\
        \\struct VM {
        \\    heap: Heap;
        \\}
        \\
        \\fn worker(vm: Arc<VM>): void {
        \\    const ignored = vm;
        \\}
        \\
        \\fn main(): i32 {
        \\    var vm = own.arc(VM {
        \\        heap: Heap {
        \\            objects: slot_map<i32>(),
        \\            threads: list<i32>()
        \\        }
        \\    });
        \\    const handle = thread.spawn(worker, vm) catch (caught_problem_1980) {
        \\        const ignored = caught_problem_1980;
        \\        return 1;
        \\    };
        \\    const ignored = handle;
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessages(
        std.testing.allocator,
        "thread_spawn_rejects_arc_vm_handle_with_raw_mutable_containers",
        source,
        &.{
            "payload type `Arc<",
            "is not thread-safe to transfer",
            "heap.objects",
        },
    );
}

test "thread spawn rejects vm composed of raw mutable containers" {
    const source =
        \\import std.thread;
        \\
        \\struct Heap {
        \\    objects: SlotMap<i32>;
        \\    threads: List<i32>;
        \\}
        \\
        \\struct VM {
        \\    heap: Heap;
        \\}
        \\
        \\fn worker(vm: VM): void {
        \\    const ignored = vm;
        \\}
        \\
        \\fn main(): i32 {
        \\    var objects: SlotMap<i32> = slot_map<i32>();
        \\    var threads: List<i32> = list<i32>();
        \\    const vm = VM {
        \\        heap: Heap {
        \\            objects: objects,
        \\            threads: threads
        \\        }
        \\    };
        \\    const handle = thread.spawn(worker, vm) catch (caught_problem_2027) {
        \\        const ignored = caught_problem_2027;
        \\        return 1;
        \\    };
        \\    const ignored = handle;
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessage(
        std.testing.allocator,
        "thread_spawn_rejects_vm_composed_of_raw_mutable_containers",
        source,
        "resource: VM.heap.objects",
    );
}

test "thread transfer and shareability predicates classify primitive and string types conservatively" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    initCanonicalTestTypes(context);
    defer deinitCanonicalTestTypes(context);

    const empty_program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = &.{},
        .functions = &.{},
        .tests = &.{},
    };

    const inferred_int = try canonicalInferredIntegerTypeId(context);
    const bool_type = try canonicalPrimitiveTypeId(context, .bool);
    const string_type = try canonicalPrimitiveTypeId(context, .string);
    try std.testing.expect(try typeIsThreadTransferable(context, "", empty_program, inferred_int));
    try std.testing.expect(try typeIsThreadShareable(context, "", empty_program, inferred_int));
    try std.testing.expect(try typeIsThreadTransferable(context, "", empty_program, bool_type));
    try std.testing.expect(try typeIsThreadShareable(context, "", empty_program, bool_type));
    try std.testing.expect(try typeIsThreadTransferable(context, "", empty_program, string_type));
    try std.testing.expect(try typeIsThreadShareable(context, "", empty_program, string_type));
}

test "thread transfer distinguishes owned storage from borrowed and shared mutable types" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    initCanonicalTestTypes(context);
    defer deinitCanonicalTestTypes(context);

    const empty_program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = &.{},
        .functions = &.{},
        .tests = &.{},
    };
    const int_type = try canonicalInferredIntegerTypeId(context);

    try std.testing.expect(!(try typeIsThreadTransferable(context, "", empty_program, try canonicalRefTypeId(context, int_type))));
    try std.testing.expect(!(try typeIsThreadShareable(context, "", empty_program, try canonicalRefTypeId(context, int_type))));
    try std.testing.expect(!(try typeIsThreadTransferable(context, "", empty_program, try canonicalSliceTypeId(context, int_type, false))));
    try std.testing.expect(!(try typeIsThreadShareable(context, "", empty_program, try canonicalSliceTypeId(context, int_type, true))));
    try std.testing.expect(!(try typeIsThreadTransferable(context, "", empty_program, try canonicalRawTypeId(context, int_type, false))));
    try std.testing.expect(!(try typeIsThreadShareable(context, "", empty_program, try canonicalRawTypeId(context, int_type, false))));
    try std.testing.expect(!(try typeIsThreadTransferable(context, "", empty_program, try canonicalOwnedTypeId(context, int_type))));
    try std.testing.expect(!(try typeIsThreadShareable(context, "", empty_program, try canonicalOwnedTypeId(context, int_type))));
    try std.testing.expect(try typeIsThreadTransferable(context, "", empty_program, try canonicalDenseArrayTypeId(context, int_type)));
    try std.testing.expect(try typeIsThreadTransferable(context, "", empty_program, try canonicalSparseArrayTypeId(context, int_type)));
    try std.testing.expect(!(try typeIsThreadShareable(context, "", empty_program, try canonicalDenseArrayTypeId(context, int_type))));
    try std.testing.expect(!(try typeIsThreadShareable(context, "", empty_program, try canonicalSparseArrayTypeId(context, int_type))));
}

test "sync resource struct is transferable and shareable boundary" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;

    const zero = std.mem.zeroes(lexer.Token);
    var borrowed_fields = [_]ast.FieldDecl{.{
        .name = "view",
        .type_name = .{ .is_slice = true, .array_len = null, .name = "i32", .args = &.{}, .token = zero },
        .is_pub = false,
        .name_token = zero,
    }};
    var structs = [_]ast.StructDecl{.{
        .module_name = "std.sync",
        .name = "CustomLock",
        .type_params = &.{},
        .layout = .normal,
        .fields = borrowed_fields[0..],
        .methods = &.{},
        .is_pub = true,
        .is_concurrency_shareable = true,
        .name_token = zero,
    }};
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = structs[0..],
        .functions = &.{},
        .tests = &.{},
    };

    try initCanonicalTestProgram(context, "thread-sync-resource.cy", program);
    defer deinitCanonicalTestProgram(context);
    const ty = try canonicalNominalTypeId(context, .@"struct", try lookup.registeredDeclId(context, "std.sync", null, "CustomLock", .@"struct"), null);
    const type_id = ty;
    try std.testing.expect(try typeIsThreadTransferable(context, "", program, type_id));
    try std.testing.expect(try typeIsThreadShareable(context, "", program, type_id));
}

test "std shared resource is a transferable boundary" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;

    const zero = std.mem.zeroes(lexer.Token);
    var handle_fields = [_]ast.FieldDecl{.{
        .name = "raw",
        .type_name = .{ .array_len = null, .name = "c_ulong", .args = &.{}, .token = zero },
        .is_pub = false,
        .name_token = zero,
    }};
    var shared_fields = [_]ast.FieldDecl{.{
        .name = "handle",
        .type_name = .{ .module_name = "std.sync", .name = "SharedHandle", .args = &.{}, .token = zero },
        .is_pub = false,
        .name_token = zero,
    }};
    var structs = [_]ast.StructDecl{
        .{
            .module_name = "std.sync",
            .name = "SharedHandle",
            .type_params = &.{},
            .layout = .c,
            .fields = handle_fields[0..],
            .methods = &.{},
            .is_pub = true,
            .is_concurrency_shareable = true,
            .name_token = zero,
        },
        .{
            .module_name = "std.sync",
            .name = "Shared",
            .type_params = &.{},
            .layout = .normal,
            .fields = shared_fields[0..],
            .methods = &.{},
            .is_pub = true,
            .is_concurrency_shareable = true,
            .name_token = zero,
        },
    };
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = structs[0..],
        .functions = &.{},
        .tests = &.{},
    };

    try initCanonicalTestProgram(context, "thread-shared-resource.cy", program);
    defer deinitCanonicalTestProgram(context);
    const ty = try canonicalNominalTypeId(context, .@"struct", try lookup.registeredDeclId(context, "std.sync", null, "Shared", .@"struct"), null);
    const type_id = ty;
    try std.testing.expect(try typeIsThreadTransferable(context, "", program, type_id));
    try std.testing.expect(try typeIsThreadShareable(context, "", program, type_id));
    const resource = try firstNonTransferableResourcePath(context, std.testing.allocator, "", program, type_id);
    defer if (resource) |name| std.testing.allocator.free(name);
    try std.testing.expect(resource == null);
}

test "non-transferable resource path reports nested payload field" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;

    const zero = std.mem.zeroes(lexer.Token);
    var object_store_fields = [_]ast.FieldDecl{.{
        .name = "items",
        .type_name = .{ .is_slice = true, .name = "i32", .args = &.{}, .token = zero },
        .is_pub = false,
        .name_token = zero,
    }};
    var heap_fields = [_]ast.FieldDecl{.{
        .name = "objects",
        .type_name = .{ .name = "ObjectStore", .args = &.{}, .token = zero },
        .is_pub = false,
        .name_token = zero,
    }};
    var vm_fields = [_]ast.FieldDecl{.{
        .name = "heap",
        .type_name = .{ .name = "Heap", .args = &.{}, .token = zero },
        .is_pub = false,
        .name_token = zero,
    }};
    var structs = [_]ast.StructDecl{
        .{
            .module_name = "std.sync",
            .name = "ObjectStore",
            .type_params = &.{},
            .layout = .normal,
            .fields = object_store_fields[0..],
            .methods = &.{},
            .is_pub = false,
            .name_token = zero,
        },
        .{
            .module_name = "",
            .name = "Heap",
            .type_params = &.{},
            .layout = .normal,
            .fields = heap_fields[0..],
            .methods = &.{},
            .is_pub = false,
            .name_token = zero,
        },
        .{
            .module_name = "std.sync",
            .name = "VM",
            .type_params = &.{},
            .layout = .normal,
            .fields = vm_fields[0..],
            .methods = &.{},
            .is_pub = false,
            .name_token = zero,
        },
    };
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = structs[0..],
        .functions = &.{},
        .tests = &.{},
    };

    try initCanonicalTestProgram(context, "thread-resource-path.cy", program);
    defer deinitCanonicalTestProgram(context);
    const ty = try canonicalNominalTypeId(context, .@"struct", try lookup.registeredDeclId(context, "std.sync", null, "VM", .@"struct"), null);
    const resource = try firstNonTransferableResourcePath(
        context,
        std.testing.allocator,
        "",
        program,
        ty,
    );
    defer if (resource) |name| std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("VM.heap.objects.items", resource.?);
}

test "non-transferable resource path stops at sync resource" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;

    const zero = std.mem.zeroes(lexer.Token);
    var object_store_fields = [_]ast.FieldDecl{.{
        .name = "items",
        .type_name = .{ .is_slice = true, .name = "i32", .args = &.{}, .token = zero },
        .is_pub = false,
        .name_token = zero,
    }};
    var vm_fields = [_]ast.FieldDecl{.{
        .name = "objects",
        .type_name = .{ .name = "ObjectStore", .args = &.{}, .token = zero },
        .is_pub = false,
        .name_token = zero,
    }};
    var structs = [_]ast.StructDecl{
        .{
            .module_name = "",
            .name = "ObjectStore",
            .type_params = &.{},
            .layout = .normal,
            .fields = object_store_fields[0..],
            .methods = &.{},
            .is_pub = false,
            .is_concurrency_shareable = true,
            .name_token = zero,
        },
        .{
            .module_name = "",
            .name = "VM",
            .type_params = &.{},
            .layout = .normal,
            .fields = vm_fields[0..],
            .methods = &.{},
            .is_pub = false,
            .name_token = zero,
        },
    };
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = structs[0..],
        .functions = &.{},
        .tests = &.{},
    };

    try initCanonicalTestProgram(context, "thread-safe-resource-path.cy", program);
    defer deinitCanonicalTestProgram(context);
    const ty = try canonicalNominalTypeId(context, .@"struct", try lookup.registeredDeclId(context, "", null, "VM", .@"struct"), null);
    const resource = try firstNonTransferableResourcePath(
        context,
        std.testing.allocator,
        "",
        program,
        ty,
    );
    defer if (resource) |name| std.testing.allocator.free(name);
    try std.testing.expect(resource == null);
}

test "thread transfer and shareability predicates compose through fixed aggregates and structs" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;

    const zero = std.mem.zeroes(lexer.Token);
    var plain_fields = [_]ast.FieldDecl{
        .{
            .name = "id",
            .type_name = .{ .array_len = null, .name = "i32", .args = &.{}, .token = zero },
            .is_pub = true,
            .name_token = zero,
        },
        .{
            .name = "ok",
            .type_name = .{ .array_len = null, .name = "bool", .args = &.{}, .token = zero },
            .is_pub = true,
            .name_token = zero,
        },
    };
    var text_fields = [_]ast.FieldDecl{
        .{
            .name = "name",
            .type_name = .{ .array_len = null, .name = "string", .args = &.{}, .token = zero },
            .is_pub = true,
            .name_token = zero,
        },
    };
    var borrowed_fields = [_]ast.FieldDecl{
        .{
            .name = "view",
            .type_name = .{ .is_slice = true, .array_len = null, .name = "i32", .args = &.{}, .token = zero },
            .is_pub = true,
            .name_token = zero,
        },
    };
    var structs = [_]ast.StructDecl{
        .{
            .module_name = "",
            .name = "Plain",
            .type_params = &.{},
            .layout = .normal,
            .fields = plain_fields[0..],
            .methods = &.{},
            .is_pub = true,
            .name_token = zero,
        },
        .{
            .module_name = "",
            .name = "TextBox",
            .type_params = &.{},
            .layout = .normal,
            .fields = text_fields[0..],
            .methods = &.{},
            .is_pub = true,
            .name_token = zero,
        },
        .{
            .module_name = "",
            .name = "BorrowedBox",
            .type_params = &.{},
            .layout = .normal,
            .fields = borrowed_fields[0..],
            .methods = &.{},
            .is_pub = true,
            .name_token = zero,
        },
    };
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = structs[0..],
        .functions = &.{},
        .tests = &.{},
    };

    try initCanonicalTestProgram(context, "thread-aggregate-types.cy", program);
    defer deinitCanonicalTestProgram(context);
    const inferred_int = try canonicalInferredIntegerTypeId(context);
    const array_type_id = try canonicalArrayTypeId(context, 4, inferred_int);
    const optional_type_id = try canonicalOptionalTypeId(context, inferred_int);
    const plain_type_id = try canonicalNominalTypeId(context, .@"struct", try lookup.registeredDeclId(context, "", null, "Plain", .@"struct"), null);
    const text_type_id = try canonicalNominalTypeId(context, .@"struct", try lookup.registeredDeclId(context, "", null, "TextBox", .@"struct"), null);
    const borrowed_type_id = try canonicalNominalTypeId(context, .@"struct", try lookup.registeredDeclId(context, "", null, "BorrowedBox", .@"struct"), null);
    try std.testing.expect(try typeIsThreadTransferable(context, "", program, array_type_id));
    try std.testing.expect(try typeIsThreadShareable(context, "", program, array_type_id));
    try std.testing.expect(try typeIsThreadTransferable(context, "", program, optional_type_id));
    try std.testing.expect(try typeIsThreadShareable(context, "", program, optional_type_id));
    try std.testing.expect(try typeIsThreadTransferable(context, "", program, plain_type_id));
    try std.testing.expect(try typeIsThreadShareable(context, "", program, plain_type_id));
    try std.testing.expect(try typeIsThreadTransferable(context, "", program, text_type_id));
    try std.testing.expect(try typeIsThreadShareable(context, "", program, text_type_id));
    try std.testing.expect(!(try typeIsThreadTransferable(context, "", program, borrowed_type_id)));
    try std.testing.expect(!(try typeIsThreadShareable(context, "", program, borrowed_type_id)));
}
test "isolated functions trust std sync extern primitives only" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    const saved_isolated = context.function_state.active_isolated_function;
    defer context.function_state.active_isolated_function = saved_isolated;

    const zero = std.mem.zeroes(lexer.Token);
    const empty_program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = &.{},
        .functions = &.{},
        .tests = &.{},
    };
    const empty_globals: []const GlobalBinding = &.{};
    const isolated_function = ast.Function{
        .module_name = "",
        .owner = null,
        .name = "worker",
        .type_params = &.{},
        .params = &.{},
        .return_type = null,
        .body = &.{},
        .is_pub = false,
        .is_extern = false,
        .is_export = false,
        .is_isolated = true,
        .calling_convention = .cyna,
        .name_token = zero,
    };

    context.function_state.active_isolated_function = &isolated_function;
    const sync_call = ast.Function{
        .module_name = "std.sync",
        .owner = null,
        .name = "atomic_i32_fetch_add",
        .type_params = &.{},
        .params = &.{},
        .return_type = null,
        .body = &.{},
        .is_pub = true,
        .is_extern = true,
        .is_export = false,
        .calling_convention = .c,
        .name_token = zero,
    };
    try rejectIsolatedCallToFunction(context, std.testing.allocator, "", empty_program, "", empty_globals, zero, sync_call);

    const user_call = ast.Function{
        .module_name = "",
        .owner = null,
        .name = "host_call",
        .type_params = &.{},
        .params = &.{},
        .return_type = null,
        .body = &.{},
        .is_pub = false,
        .is_extern = true,
        .is_export = false,
        .calling_convention = .c,
        .name_token = zero,
    };
    try std.testing.expectError(error.SemanticFailed, rejectIsolatedCallToFunction(context, std.testing.allocator, "", empty_program, "", empty_globals, zero, user_call));
}

test "boundary validation accepts isolated entrypoint and transferable payload" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;

    const zero = std.mem.zeroes(lexer.Token);
    const entry_type = ast.TypeName{
        .is_function = true,
        .name = "fn",
        .args = &.{},
        .function_params = @constCast(&[_]ast.TypeName{.{ .name = "i32", .args = &.{}, .token = zero }}),
        .function_return_type = @constCast(&ast.TypeName{ .name = "void", .args = &.{}, .token = zero }),
        .token = zero,
    };
    const payload_type = ast.TypeName{ .name = "i32", .args = &.{}, .token = zero };
    var params = [_]ast.Param{
        .{ .name = "entry", .type_name = entry_type, .name_token = zero },
        .{ .name = "arg", .type_name = payload_type, .name_token = zero },
    };
    var functions = [_]ast.Function{
        .{
            .module_name = "std.thread",
            .owner = null,
            .name = "spawn",
            .type_params = &.{},
            .params = params[0..],
            .return_type = null,
            .body = &.{},
            .is_pub = true,
            .is_extern = false,
            .is_export = false,
            .calling_convention = .cyna,
            .name_token = zero,
        },
        .{
            .module_name = "",
            .owner = null,
            .name = "worker",
            .type_params = &.{},
            .params = &.{},
            .return_type = null,
            .body = &.{},
            .is_pub = false,
            .is_extern = false,
            .is_export = false,
            .is_isolated = true,
            .calling_convention = .cyna,
            .name_token = zero,
        },
    };
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = &.{},
        .functions = functions[0..],
        .tests = &.{},
    };
    var worker_expr = ast.Expr{ .name = .{ .text = "worker", .token = zero } };
    var payload_expr = ast.Expr{ .int = .{ .value = 1, .unsigned_value = null, .token = zero } };
    var args = [_]ast.CallArg{
        .{ .value = &worker_expr },
        .{ .value = &payload_expr },
    };
    const call = ast.Call{
        .owner = "std.thread",
        .callee = "spawn",
        .callee_token = zero,
        .type_args = &.{},
        .args = args[0..],
    };

    try initCanonicalTestProgram(context, "boundary-isolated.cy", program);
    defer deinitCanonicalTestProgram(context);
    try validateBoundaryCall(context, std.testing.allocator, "", program, "", &.{}, call, functions[0], null, null);
}

test "boundary validation accepts resource-safe unmarked entrypoint" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;

    const zero = std.mem.zeroes(lexer.Token);
    const entry_type = ast.TypeName{
        .is_function = true,
        .name = "fn",
        .args = &.{},
        .function_params = @constCast(&[_]ast.TypeName{.{ .name = "i32", .args = &.{}, .token = zero }}),
        .function_return_type = @constCast(&ast.TypeName{ .name = "void", .args = &.{}, .token = zero }),
        .token = zero,
    };
    const payload_type = ast.TypeName{ .name = "i32", .args = &.{}, .token = zero };
    var params = [_]ast.Param{
        .{ .name = "entry", .type_name = entry_type, .name_token = zero },
        .{ .name = "arg", .type_name = payload_type, .name_token = zero },
    };
    var functions = [_]ast.Function{
        .{
            .module_name = "embedded.task",
            .owner = null,
            .name = "spawn",
            .type_params = &.{},
            .params = params[0..],
            .return_type = null,
            .body = &.{},
            .is_pub = true,
            .is_extern = false,
            .is_export = false,
            .calling_convention = .cyna,
            .name_token = zero,
        },
        .{
            .module_name = "",
            .owner = null,
            .name = "worker",
            .type_params = &.{},
            .params = &.{},
            .return_type = null,
            .body = &.{},
            .is_pub = false,
            .is_extern = false,
            .is_export = false,
            .calling_convention = .cyna,
            .name_token = zero,
        },
    };
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = &.{},
        .functions = functions[0..],
        .tests = &.{},
    };
    var worker_expr = ast.Expr{ .name = .{ .text = "worker", .token = zero } };
    var payload_expr = ast.Expr{ .int = .{ .value = 1, .unsigned_value = null, .token = zero } };
    var args = [_]ast.CallArg{
        .{ .value = &worker_expr },
        .{ .value = &payload_expr },
    };
    const call = ast.Call{
        .owner = "embedded.task",
        .callee = "spawn",
        .callee_token = zero,
        .type_args = &.{},
        .args = args[0..],
    };

    try initCanonicalTestProgram(context, "boundary-resource-safe.cy", program);
    defer deinitCanonicalTestProgram(context);
    try validateBoundaryCall(context, std.testing.allocator, "", program, "", &.{}, call, functions[0], null, null);
}

test "boundary validation rejects entrypoint reaching mutable global" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;

    const zero = std.mem.zeroes(lexer.Token);
    const entry_type = ast.TypeName{
        .is_function = true,
        .name = "fn",
        .args = &.{},
        .function_params = @constCast(&[_]ast.TypeName{.{ .name = "i32", .args = &.{}, .token = zero }}),
        .function_return_type = @constCast(&ast.TypeName{ .name = "void", .args = &.{}, .token = zero }),
        .token = zero,
    };
    const payload_type = ast.TypeName{ .name = "i32", .args = &.{}, .token = zero };
    var params = [_]ast.Param{
        .{ .name = "entry", .type_name = entry_type, .name_token = zero },
        .{ .name = "arg", .type_name = payload_type, .name_token = zero },
    };
    var counter_expr = ast.Expr{ .name = .{ .text = "counter", .token = zero } };
    var worker_body = [_]ast.Stmt{.{ .expr = &counter_expr }};
    var functions = [_]ast.Function{
        .{
            .module_name = "std.thread",
            .owner = null,
            .name = "spawn",
            .type_params = &.{},
            .params = params[0..],
            .return_type = null,
            .body = &.{},
            .is_pub = true,
            .is_extern = false,
            .is_export = false,
            .calling_convention = .cyna,
            .name_token = zero,
        },
        .{
            .module_name = "",
            .owner = null,
            .name = "worker",
            .type_params = &.{},
            .params = &.{},
            .return_type = null,
            .body = worker_body[0..],
            .is_pub = false,
            .is_extern = false,
            .is_export = false,
            .calling_convention = .cyna,
            .name_token = zero,
        },
    };
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = &.{},
        .functions = functions[0..],
        .tests = &.{},
    };
    try initCanonicalTestProgram(context, "boundary-mutable-global.cy", program);
    defer deinitCanonicalTestProgram(context);
    const globals = [_]GlobalBinding{.{
        .id = @fromBackingInt(@intCast(0)),
        .name = "counter",
        .module_name = "",
        .is_pub = false,
        .is_mutable = true,
        .type_id = try canonicalInferredIntegerTypeId(context),
    }};
    var worker_expr = ast.Expr{ .name = .{ .text = "worker", .token = zero } };
    var payload_expr = ast.Expr{ .int = .{ .value = 1, .unsigned_value = null, .token = zero } };
    var args = [_]ast.CallArg{
        .{ .value = &worker_expr },
        .{ .value = &payload_expr },
    };
    const call = ast.Call{
        .owner = "std.thread",
        .callee = "spawn",
        .callee_token = zero,
        .type_args = &.{},
        .args = args[0..],
    };

    try std.testing.expectError(error.SemanticFailed, validateBoundaryCall(context, std.testing.allocator, "", program, "", globals[0..], call, functions[0], null, null));
}

test "thread boundary analysis reports mutable global field resource path" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;

    const zero = std.mem.zeroes(lexer.Token);
    var heap_expr = ast.Expr{ .name = .{ .text = "heap", .token = zero } };
    var value_expr = ast.Expr{ .int = .{ .value = 1, .unsigned_value = null, .token = zero } };
    var fields = [_]ast.DerefFieldAssignStep{.{
        .field = "objects",
        .field_token = zero,
    }};
    var worker_body = [_]ast.Stmt{.{ .field_assign = .{
        .object = &heap_expr,
        .fields = fields[0..],
        .value = &value_expr,
        .token = zero,
    } }};
    const worker = ast.Function{
        .module_name = "",
        .owner = null,
        .name = "worker",
        .type_params = &.{},
        .params = &.{},
        .return_type = null,
        .body = worker_body[0..],
        .is_pub = false,
        .is_extern = false,
        .is_export = false,
        .calling_convention = .cyna,
        .name_token = zero,
    };
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = &.{},
        .functions = @constCast(&[_]ast.Function{worker}),
        .tests = &.{},
    };
    try initCanonicalTestProgram(context, "thread-global-field-resource.cy", program);
    defer deinitCanonicalTestProgram(context);
    const globals = [_]GlobalBinding{.{
        .id = @fromBackingInt(@intCast(0)),
        .name = "heap",
        .module_name = "",
        .is_pub = false,
        .is_mutable = true,
        .type_id = try canonicalNominalTypeId(context, .@"struct", try registeredOrGeneratedDeclId(context, "", null, "Heap", .@"struct"), null),
    }};

    const trace = (try analyzeThreadBoundaryEntrypoint(context, std.testing.allocator, program, "", globals[0..], worker, .resource_reachability)) orelse return error.TestExpectedEqual;
    defer trace.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("worker", trace.chain);
    try std.testing.expectEqualStrings("heap.objects", trace.resource.?);
    try std.testing.expect(std.mem.indexOf(u8, trace.reason, "heap.objects") != null);
}

test "thread boundary analysis reports mutable global method receiver resource path" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;

    const zero = std.mem.zeroes(lexer.Token);
    var heap_expr = ast.Expr{ .name = .{ .text = "heap", .token = zero } };
    var objects_expr = ast.Expr{ .field = .{
        .object = &heap_expr,
        .field = "objects",
        .field_token = zero,
    } };
    var value_expr = ast.Expr{ .int = .{ .value = 1, .unsigned_value = null, .token = zero } };
    var args = [_]ast.CallArg{.{ .value = &value_expr }};
    var insert_expr = ast.Expr{ .method_call = .{
        .object = &objects_expr,
        .method = "insert",
        .method_token = zero,
        .type_args = &.{},
        .args = args[0..],
    } };
    var worker_body = [_]ast.Stmt{.{ .expr = &insert_expr }};
    const worker = ast.Function{
        .module_name = "",
        .owner = null,
        .name = "worker",
        .type_params = &.{},
        .params = &.{},
        .return_type = null,
        .body = worker_body[0..],
        .is_pub = false,
        .is_extern = false,
        .is_export = false,
        .calling_convention = .cyna,
        .name_token = zero,
    };
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = &.{},
        .functions = @constCast(&[_]ast.Function{worker}),
        .tests = &.{},
    };
    try initCanonicalTestProgram(context, "thread-global-method-resource.cy", program);
    defer deinitCanonicalTestProgram(context);
    const globals = [_]GlobalBinding{.{
        .id = @fromBackingInt(@intCast(0)),
        .name = "heap",
        .module_name = "",
        .is_pub = false,
        .is_mutable = true,
        .type_id = try canonicalNominalTypeId(context, .@"struct", try registeredOrGeneratedDeclId(context, "", null, "Heap", .@"struct"), null),
    }};

    const trace = (try analyzeThreadBoundaryEntrypoint(context, std.testing.allocator, program, "", globals[0..], worker, .resource_reachability)) orelse return error.TestExpectedEqual;
    defer trace.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("worker", trace.chain);
    try std.testing.expectEqualStrings("heap.objects", trace.resource.?);
    try std.testing.expect(std.mem.indexOf(u8, trace.reason, "insert") != null);
}

test "thread boundary analysis allows mutable global sync resource method receiver" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;

    const zero = std.mem.zeroes(lexer.Token);
    var lock_expr = ast.Expr{ .name = .{ .text = "lock", .token = zero } };
    var lock_call_expr = ast.Expr{ .method_call = .{
        .object = &lock_expr,
        .method = "lock",
        .method_token = zero,
        .type_args = &.{},
        .args = &.{},
    } };
    var worker_body = [_]ast.Stmt{.{ .expr = &lock_call_expr }};
    const worker = ast.Function{
        .module_name = "",
        .owner = null,
        .name = "worker",
        .type_params = &.{},
        .params = &.{},
        .return_type = null,
        .body = worker_body[0..],
        .is_pub = false,
        .is_extern = false,
        .is_export = false,
        .calling_convention = .cyna,
        .name_token = zero,
    };
    var structs = [_]ast.StructDecl{.{
        .module_name = "std.sync",
        .name = "Mutex",
        .type_params = &.{},
        .layout = .normal,
        .fields = &.{},
        .methods = &.{},
        .is_pub = true,
        .is_concurrency_shareable = true,
        .name_token = zero,
    }};
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = structs[0..],
        .functions = @constCast(&[_]ast.Function{worker}),
        .tests = &.{},
    };
    try initCanonicalTestProgram(context, "thread-global-sync-method.cy", program);
    defer deinitCanonicalTestProgram(context);
    const globals = [_]GlobalBinding{.{
        .id = @fromBackingInt(@intCast(0)),
        .name = "lock",
        .module_name = "",
        .is_pub = false,
        .is_mutable = true,
        .type_id = try canonicalNominalTypeId(context, .@"struct", try lookup.registeredDeclId(context, "std.sync", null, "Mutex", .@"struct"), null),
    }};

    try std.testing.expect(try analyzeThreadBoundaryEntrypoint(context, std.testing.allocator, program, "", globals[0..], worker, .resource_reachability) == null);
}

test "thread boundary analysis allows nested sync resource field method receiver" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;

    const zero = std.mem.zeroes(lexer.Token);
    var state_expr = ast.Expr{ .name = .{ .text = "state", .token = zero } };
    var state_lock_expr = ast.Expr{ .field = .{
        .object = &state_expr,
        .field = "lock",
        .field_token = zero,
    } };
    var lock_call_expr = ast.Expr{ .method_call = .{
        .object = &state_lock_expr,
        .method = "lock",
        .method_token = zero,
        .type_args = &.{},
        .args = &.{},
    } };
    var worker_body = [_]ast.Stmt{.{ .expr = &lock_call_expr }};
    const worker = ast.Function{
        .module_name = "",
        .owner = null,
        .name = "worker",
        .type_params = &.{},
        .params = &.{},
        .return_type = null,
        .body = worker_body[0..],
        .is_pub = false,
        .is_extern = false,
        .is_export = false,
        .calling_convention = .cyna,
        .name_token = zero,
    };
    var state_fields = [_]ast.FieldDecl{.{
        .name = "lock",
        .type_name = .{ .module_name = "sync", .name = "Mutex", .args = &.{}, .token = zero },
        .is_pub = false,
        .name_token = zero,
    }};
    var structs = [_]ast.StructDecl{
        .{
            .module_name = "std.sync",
            .name = "Mutex",
            .type_params = &.{},
            .layout = .normal,
            .fields = &.{},
            .methods = &.{},
            .is_pub = true,
            .is_concurrency_shareable = true,
            .name_token = zero,
        },
        .{
            .module_name = "",
            .name = "State",
            .type_params = &.{},
            .layout = .normal,
            .fields = state_fields[0..],
            .methods = &.{},
            .is_pub = false,
            .name_token = zero,
        },
    };
    var namespace_imports = [_]ast.ImportDecl{.{ .path = "std.sync", .local_name = "sync", .items = &.{}, .path_token = zero }};
    var module_infos = [_]ast.ModuleInfo{.{ .name = "", .imports = namespace_imports[0..] }};
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = module_infos[0..],
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = structs[0..],
        .functions = @constCast(&[_]ast.Function{worker}),
        .tests = &.{},
    };
    try initCanonicalTestProgram(context, "thread-nested-sync-field.cy", program);
    defer deinitCanonicalTestProgram(context);
    const globals = [_]GlobalBinding{.{
        .id = @fromBackingInt(@intCast(0)),
        .name = "state",
        .module_name = "",
        .is_pub = false,
        .is_mutable = true,
        .type_id = try canonicalNominalTypeId(context, .@"struct", try lookup.registeredDeclId(context, "", null, "State", .@"struct"), null),
    }};

    try std.testing.expect(try analyzeThreadBoundaryEntrypoint(context, std.testing.allocator, program, "", globals[0..], worker, .resource_reachability) == null);
}

test "thread boundary analysis still rejects sync resource global replacement" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;

    const zero = std.mem.zeroes(lexer.Token);
    var value_expr = ast.Expr{ .name = .{ .text = "other", .token = zero } };
    var worker_body = [_]ast.Stmt{.{ .assign = .{
        .name = "lock",
        .name_token = zero,
        .value = &value_expr,
    } }};
    const worker = ast.Function{
        .module_name = "",
        .owner = null,
        .name = "worker",
        .type_params = &.{},
        .params = &.{},
        .return_type = null,
        .body = worker_body[0..],
        .is_pub = false,
        .is_extern = false,
        .is_export = false,
        .calling_convention = .cyna,
        .name_token = zero,
    };
    var structs = [_]ast.StructDecl{.{
        .module_name = "std.sync",
        .name = "Mutex",
        .type_params = &.{},
        .layout = .normal,
        .fields = &.{},
        .methods = &.{},
        .is_pub = true,
        .is_concurrency_shareable = true,
        .name_token = zero,
    }};
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = structs[0..],
        .functions = @constCast(&[_]ast.Function{worker}),
        .tests = &.{},
    };
    try initCanonicalTestProgram(context, "thread-sync-global-replacement.cy", program);
    defer deinitCanonicalTestProgram(context);
    const globals = [_]GlobalBinding{.{
        .id = @fromBackingInt(@intCast(0)),
        .name = "lock",
        .module_name = "",
        .is_pub = false,
        .is_mutable = true,
        .type_id = try canonicalNominalTypeId(context, .@"struct", try lookup.registeredDeclId(context, "std.sync", null, "Mutex", .@"struct"), null),
    }};

    const trace = (try analyzeThreadBoundaryEntrypoint(context, std.testing.allocator, program, "", globals[0..], worker, .resource_reachability)) orelse return error.TestExpectedEqual;
    defer trace.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("lock", trace.resource.?);
}

test "boundary validation rejects non-transferable payload type" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;

    const zero = std.mem.zeroes(lexer.Token);
    const entry_type = ast.TypeName{
        .is_function = true,
        .name = "fn",
        .args = &.{},
        .function_params = @constCast(&[_]ast.TypeName{.{ .is_slice = true, .name = "i32", .args = &.{}, .token = zero }}),
        .function_return_type = @constCast(&ast.TypeName{ .name = "void", .args = &.{}, .token = zero }),
        .token = zero,
    };
    const payload_type = ast.TypeName{ .is_slice = true, .name = "i32", .args = &.{}, .token = zero };
    var params = [_]ast.Param{
        .{ .name = "entry", .type_name = entry_type, .name_token = zero },
        .{ .name = "arg", .type_name = payload_type, .name_token = zero },
    };
    var functions = [_]ast.Function{
        .{
            .module_name = "std.thread",
            .owner = null,
            .name = "spawn",
            .type_params = &.{},
            .params = params[0..],
            .return_type = null,
            .body = &.{},
            .is_pub = true,
            .is_extern = false,
            .is_export = false,
            .calling_convention = .cyna,
            .name_token = zero,
        },
        .{
            .module_name = "",
            .owner = null,
            .name = "worker",
            .type_params = &.{},
            .params = &.{},
            .return_type = null,
            .body = &.{},
            .is_pub = false,
            .is_extern = false,
            .is_export = false,
            .is_isolated = true,
            .calling_convention = .cyna,
            .name_token = zero,
        },
    };
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = &.{},
        .functions = functions[0..],
        .tests = &.{},
    };
    var worker_expr = ast.Expr{ .name = .{ .text = "worker", .token = zero } };
    var payload_expr = ast.Expr{ .name = .{ .text = "view", .token = zero } };
    var args = [_]ast.CallArg{
        .{ .value = &worker_expr },
        .{ .value = &payload_expr },
    };
    const call = ast.Call{
        .owner = "std.thread",
        .callee = "spawn",
        .callee_token = zero,
        .type_args = &.{},
        .args = args[0..],
    };

    try std.testing.expectError(error.SemanticFailed, validateBoundaryCall(context, std.testing.allocator, "", program, "", &.{}, call, functions[0], null, null));
}

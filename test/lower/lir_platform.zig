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

test "LIR lowers raw pointer params returns and dereference" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn keep(ptr: *User): *User {
        \\    return ptr;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = new User { age: 42 };
        \\    const ptr: *User = user.ptr();
        \\    const again = keep(ptr);
        \\    unchecked {
        \\        return (*again).age;
        \\    }
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_raw_pointer_passthrough.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "fn cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "local#1 ptr: &User") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load %") != null);
}

test "LIR lowers generic thread spawn i32 through boxed primitive" {
    const source =
        \\import std.thread;
        \\
        \\@isolated
        \\fn worker(value: i32): void {
        \\    const ignored = value;
        \\}
        \\
        \\fn main(): i32 {
        \\    const handle = thread.spawn(worker, 42 as i32) catch (spawn_problem) {
        \\        const ignored = spawn_problem;
        \\        return 1;
        \\    };
        \\    const ignored = handle;
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_thread_spawn_boxed_i32.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_thread_spawn_boxed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "type_desc i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_thread_spawn_i32") == null);
}

test "LIR lowers generic thread spawn string through boxed primitive" {
    const source =
        \\import std.thread;
        \\
        \\@isolated
        \\fn worker(value: string): void {
        \\    const ignored = value;
        \\}
        \\
        \\fn main(): i32 {
        \\    const handle = thread.spawn(worker, "payload") catch (spawn_problem) {
        \\        const ignored = spawn_problem;
        \\        return 1;
        \\    };
        \\    const ignored = handle;
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_thread_spawn_boxed_string.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_thread_spawn_boxed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "type_desc string") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_thread_spawn_i32") == null);
}

test "LIR lowers generic thread spawn optional payload through shaped boxed primitive" {
    const source =
        \\import std.thread;
        \\
        \\@isolated
        \\fn worker(value: ?i32): void {
        \\    const ignored = value;
        \\}
        \\
        \\fn main(): i32 {
        \\    const payload: ?i32 = 42;
        \\    const handle = thread.spawn(worker, payload) catch (spawn_problem) {
        \\        const ignored = spawn_problem;
        \\        return 1;
        \\    };
        \\    const ignored = handle;
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_thread_spawn_boxed_optional.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_thread_spawn_boxed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "type_desc ?i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_thread_spawn_i32") == null);
}

test "LIR lowers generic arc through boxed primitive with retain release" {
    const source =
        \\import std.own;
        \\import { Arc } from std.own;
        \\
        \\struct State {
        \\    value: i32;
        \\}
        \\
        \\fn keep(value: Arc<State>): void {
        \\    const ignored = value;
        \\}
        \\
        \\fn main(): i32 {
        \\    var state = own.arc(State { value: 42 });
        \\    keep(state);
        \\    keep(state);
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_arc_boxed_retain_release.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_sync_arc_new_boxed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "type_desc State") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_sync_arc_retain") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_sync_arc_release") != null);
}

test "LIR lowers sync locked value access through shared bridge" {
    const source =
        \\import std.sync;
        \\import { SyncStatus } from std.sync;
        \\
        \\struct Cell {
        \\    value: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var locked = sync.locked(Cell { value: 2 });
        \\    const set_status = locked.with<i32>(40 as i32, fn(cell: &Cell, value: i32): void {
        \\        cell.value = value;
        \\    });
        \\    if set_status != SyncStatus.ok {
        \\        return 1;
        \\    }
        \\    const value = locked.with_result<i32, i32>(2 as i32, fn(cell: &Cell, amount: i32): i32 {
        \\        return cell.value + amount;
        \\    }) catch (status) {
        \\        const ignored_status = status;
        \\        const ignored = locked.destroy();
        \\        return 2;
        \\    };
        \\    const ignored = locked.destroy();
        \\    return value;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_sync_locked.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_sync_share_boxed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_sync_shared_lock") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_sync_shared_unlock") != null);
}

test "LIR lowers concurrent list sync resource operations" {
    const source =
        \\import std.sync;
        \\import { SyncStatus } from std.sync;
        \\
        \\fn main(): i32 {
        \\    var values = sync.concurrent_list<i32>();
        \\    if values.push(40 as i32) != SyncStatus.ok {
        \\        return 1;
        \\    }
        \\    if values.push(2 as i32) != SyncStatus.ok {
        \\        return 2;
        \\    }
        \\    const index = values.push_len(3 as i32) catch (push_failure) {
        \\        const ignored = push_failure;
        \\        return 10;
        \\    };
        \\        if index != 2 {
        \\            return 9;
        \\        }
        \\    const length = values.len() catch (len_failure) {
        \\        const ignored = len_failure;
        \\        return 4;
        \\    };
        \\        if length != 3 {
        \\            return 3;
        \\        }
        \\    const status = values.with<i32>(1 as i32, fn(items: &List<i32>, value: i32): void {
        \\        items.push(value);
        \\    });
        \\    if status != SyncStatus.ok {
        \\        return 5;
        \\    }
        \\    const first = values.with_index_result<i32, i32>(0, 2 as i32, fn(item: &i32, amount: i32): i32 {
        \\        return item + amount;
        \\    }) catch (index_failure) {
        \\        const ignored = index_failure;
        \\        return 12;
        \\    };
        \\        if first != 42 {
        \\            return 11;
        \\        }
        \\    const count = values.with_result<i32, i32>(1 as i32, fn(items: &List<i32>, amount: i32): i32 {
        \\        return items.len() as i32 + amount;
        \\    }) catch (with_failure) {
        \\        const ignored = with_failure;
        \\        return 7;
        \\    };
        \\        if count != 5 {
        \\            return 6;
        \\        }
        \\    if values.clear() != SyncStatus.ok {
        \\        return 8;
        \\    }
        \\    const ignored = values.destroy();
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_sync_concurrent_list.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_sync_share_boxed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_sync_shared_lock") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_sync_shared_unlock") != null);
}

test "LIR lowers concurrent slot map sync resource operations" {
    const source =
        \\import std.sync;
        \\import { SyncStatus } from std.sync;
        \\
        \\fn main(): i32 {
        \\    var values = sync.concurrent_slot_map<i32>();
        \\    const key = values.insert(42 as i32) catch (insert_failure) {
        \\        const ignored_insert = insert_failure;
        \\        return 1;
        \\    };
        \\    const found = values.contains(key) catch (contains_failure) {
        \\        const ignored_contains = contains_failure;
        \\        return 3;
        \\    };
        \\    if not found { return 2; }
        \\    const length = values.len() catch (len_failure) {
        \\        const ignored_len = len_failure;
        \\        return 5;
        \\    };
        \\    if length != 1 { return 4; }
        \\    const status = values.with<i32>(1 as i32, fn(items: &SlotMap<i32>, value: i32): void {
        \\        const ignored = items.insert(value);
        \\    });
        \\    if status != SyncStatus.ok {
        \\        return 6;
        \\    }
        \\    const count = values.with_result<i32, i32>(1 as i32, fn(items: &SlotMap<i32>, amount: i32): i32 {
        \\        return items.len() as i32 + amount;
        \\    }) catch (with_failure) {
        \\        const ignored_with = with_failure;
        \\        return 8;
        \\    };
        \\    if count != 3 { return 7; }
        \\    const ignored = values.destroy();
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_sync_concurrent_slot_map.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_sync_share_boxed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_sync_shared_lock") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_sync_shared_unlock") != null);
}

test "LIR resolves local Thread separately from std.thread.Thread" {
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_thread_import_local_thread_collision.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "_make(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_std_thread_current_id_raw") != null);
}

test "LIR keeps dedicated test module for local Thread collision" {
    const source =
        \\import { current_id } from std.thread;
        \\
        \\struct Thread {
        \\    id: i32;
        \\}
        \\
        \\fn new_thread(id: i32): Thread {
        \\    const native_id = current_id();
        \\    const ignored = native_id;
        \\    return Thread { id: id };
        \\}
        \\
        \\test "local thread field in test root" {
        \\    var thread = new_thread(7);
        \\    assert(thread.id == 7);
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_thread_import_local_thread_collision.test.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "__cyna_test_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
}

test "LIR lowers raw pointer writes inside unchecked" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = new User { age: 1 };
        \\    const user_ptr: *User = user.ptr();
        \\    unchecked {
        \\        *user_ptr = User { age: 40 };
        \\        (*user_ptr).age = 42;
        \\    }
        \\    return user.age;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_raw_pointer_writes.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "store %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_struct(") != null);
}

test "LIR lowers raw pointer indexed field writes inside unchecked" {
    const source =
        \\struct Bag {
        \\    values: [2]i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var bag = new Bag { values: [1, 2] };
        \\    const ptr: *Bag = bag.ptr();
        \\    unchecked {
        \\        (*ptr).values[0] = 42;
        \\    }
        \\    return bag.values[0];
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_raw_pointer_indexed_field_writes.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "index_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store %") != null);
}

test "LIR lowers unchecked cunion field reads" {
    const source =
        \\c union Raw {
        \\    int_value: i32;
        \\}
        \\
        \\fn read(value: Raw): i32 {
        \\    unchecked {
        \\        return value.int_value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_cunion_field_read_unchecked.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "fn cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_field") != null);
}

test "LIR lowers inline asm inside unchecked" {
    if (builtin.target.cpu.arch != .aarch64) return;

    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        asm volatile {
        \\            "mov {value}, {other}";
        \\            in value = 40;
        \\            in other = 2;
        \\            clobber memory;
        \\            clobber flags;
        \\            clobber x0;
        \\        }
        \\    }
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_inline_asm_unchecked.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "inline_asm volatile { \"mov {value}, {other}\"; in reg value=%") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "in reg other=%") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "clobber memory;") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "clobber flags;") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "clobber x0;") != null);
}

test "LIR lowers inline asm expression result" {
    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        const value = asm(i32) {
        \\            "add {result}, {left}, {right}";
        \\            out reg result;
        \\            in reg left = 40;
        \\            in reg right = 2;
        \\        };
        \\        return value;
        \\    }
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_inline_asm_expr.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "inline_asm { \"add {result}, {left}, {right}\"; out reg result; in reg left=%") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "local#0 value: i32") != null);
}

test "LIR lowers inline asm expression inout operand" {
    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        const value = asm(i32) {
        \\            "add {acc}, {rhs}";
        \\            inout reg acc = 40;
        \\            in reg rhs = 2;
        \\        };
        \\        return value;
        \\    }
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_inline_asm_expr_inout.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "inline_asm { \"add {acc}, {rhs}\"; inout reg acc=%") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "in reg rhs=%") != null);
}

test "LIR lowers inline asm expression tied input operand" {
    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        const value = asm(i32) {
        \\            "add {result}, {seed}";
        \\            out reg result;
        \\            in tied reg seed = 40;
        \\        };
        \\        return value;
        \\    }
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_inline_asm_expr_tied.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "inline_asm { \"add {result}, {seed}\"; out reg result; in tied_reg seed=%") != null);
}

test "LIR lowers extern const raw pointer globals" {
    const source =
        \\extern {
        \\    c("bytes") const bytes: *u8;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_extern_const_raw_global.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "extern const") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bytes:") != null);
}

test "LIR lowers imported public globals across files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/math.cy", .data =
        \\
        \\pub const base: i32 = 40;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { base } from lib.math;
        \\
        \\const answer: i32 = base + 2;
        \\
        \\fn main(): i32 {
        \\    return answer;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    const text = try lir_support.lowerLirFileText(std.testing.allocator, root_path);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "base: i32 = \"cyna_global_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "answer: i32 = \"cyna_global_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "global_addr cyna_global_") != null);
}

test "LIR indexes imported public fixed-array globals by address" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/table.cy", .data =
        \\
        \\pub var starts: [16]usize = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        \\pub var kinds: [16]i32 = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { starts, kinds } from lib.table;
        \\
        \\fn read_start(index: usize): usize {
        \\    return starts[index];
        \\}
        \\
        \\fn read_kind(index: usize): i32 {
        \\    return kinds[index];
        \\}
        \\
        \\fn main(): i32 {
        \\    if read_start(0) == 0 {
        \\        return read_kind(0);
        \\    }
        \\    return 1;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    const text = try lir_support.lowerLirFileText(std.testing.allocator, root_path);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "starts: [16]u64 = \"cyna_global_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "kinds: [16]i32 = \"cyna_global_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "index_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "stack_alloc [16]u64") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "stack_alloc [16]i32") == null);
}

test "LIR projects imported public struct globals by address" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/state.cy", .data =
        \\
        \\pub struct Pair {
        \\    pub left: i32;
        \\    pub right: i32;
        \\}
        \\
        \\pub var pair: Pair = Pair { left: 10, right: 32 };
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { pair } from lib.state;
        \\
        \\fn main(): i32 {
        \\    return pair.right;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    const text = try lir_support.lowerLirFileText(std.testing.allocator, root_path);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "pair: Pair = \"cyna_global_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "global_addr cyna_global_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_field") == null);
}

test "LIR preserves packed struct layout marker" {
    const source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn main(): i32 {
        \\    const reg = StatusReg { ready: 1, mode: 2, error: 3 };
        \\    return (reg.ready as i32) + (reg.mode as i32) + (reg.error as i32);
        \\}
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);

    const program = try parser.parse(std.testing.allocator, "lir_packed_layout_marker.cy", source, tokens);
    defer program.deinit(std.testing.allocator);

    const sir_module = try sema.buildSir(std.testing.allocator, "lir_packed_layout_marker.cy", program);
    defer sir_module.deinit(std.testing.allocator);

    const lir_module = try lowerModule(std.testing.allocator, sir_module);
    defer lir_module.deinit(std.testing.allocator);

    var found_packed = false;
    for (lir_module.types) |ty| {
        switch (ty) {
            .@"struct" => |struct_ty| {
                if (std.mem.eql(u8, struct_ty.name, "StatusReg")) {
                    found_packed = true;
                    try std.testing.expect(struct_ty.is_packed);
                }
            },
            else => {},
        }
    }
    try std.testing.expect(found_packed);
}

test "LIR lowers usize with selected target pointer width" {
    const source =
        \\fn main(): usize {
        \\    return 0xffffffff;
        \\}
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "lir_usize_target_width.cy", source, tokens);
    defer program.deinit(std.testing.allocator);

    const sir_module = try sema.buildSirWithOptions(std.testing.allocator, "lir_usize_target_width.cy", program, .{
        .target = "riscv32-none-elf",
    });
    defer sir_module.deinit(std.testing.allocator);

    const lir_module = try lowerModuleWithOptions(std.testing.allocator, sir_module, .{
        .target = "riscv32-none-elf",
    });
    defer lir_module.deinit(std.testing.allocator);

    const main = lir_module.functions[0];
    const ret_ty = lir_module.types[main.return_type].int;
    try std.testing.expectEqual(@as(u16, 32), ret_ty.bits);
    try std.testing.expect(!ret_ty.signed);
}

test "LIR computes packed bit offsets and total width" {
    const source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\packed struct Wrapper {
        \\    reg: StatusReg;
        \\    tail: u8;
        \\}
        \\
        \\fn main(): i32 {
        \\    const value = Wrapper { reg: StatusReg { ready: 1, mode: 2, error: 3 }, tail: 4 };
        \\    return (value.reg.mode as i32) + (value.tail as i32);
        \\}
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);

    const program = try parser.parse(std.testing.allocator, "lir_packed_bit_offsets.cy", source, tokens);
    defer program.deinit(std.testing.allocator);

    const sir_module = try sema.buildSir(std.testing.allocator, "lir_packed_bit_offsets.cy", program);
    defer sir_module.deinit(std.testing.allocator);

    const lir_module = try lowerModule(std.testing.allocator, sir_module);
    defer lir_module.deinit(std.testing.allocator);

    var found_status = false;
    var found_wrapper = false;
    for (lir_module.types) |ty| {
        switch (ty) {
            .@"struct" => |struct_ty| {
                if (std.mem.eql(u8, struct_ty.name, "StatusReg")) {
                    found_status = true;
                    try std.testing.expect(struct_ty.is_packed);
                    try std.testing.expectEqual(@as(u32, 8), struct_ty.packed_bits);
                    try std.testing.expectEqual(@as(u32, 0), struct_ty.fields[0].bit_offset);
                    try std.testing.expectEqual(@as(u16, 1), struct_ty.fields[0].bit_width);
                    try std.testing.expectEqual(@as(u32, 1), struct_ty.fields[1].bit_offset);
                    try std.testing.expectEqual(@as(u16, 3), struct_ty.fields[1].bit_width);
                    try std.testing.expectEqual(@as(u32, 4), struct_ty.fields[2].bit_offset);
                    try std.testing.expectEqual(@as(u16, 4), struct_ty.fields[2].bit_width);
                }
                if (std.mem.eql(u8, struct_ty.name, "Wrapper")) {
                    found_wrapper = true;
                    try std.testing.expect(struct_ty.is_packed);
                    try std.testing.expectEqual(@as(u32, 16), struct_ty.packed_bits);
                    try std.testing.expectEqual(@as(u32, 0), struct_ty.fields[0].bit_offset);
                    try std.testing.expectEqual(@as(u16, 8), struct_ty.fields[0].bit_width);
                    try std.testing.expectEqual(@as(u32, 8), struct_ty.fields[1].bit_offset);
                    try std.testing.expectEqual(@as(u16, 8), struct_ty.fields[1].bit_width);
                }
            },
            else => {},
        }
    }

    try std.testing.expect(found_status);
    try std.testing.expect(found_wrapper);
}

const std = @import("std");
const compat = @import("cyna").compat;

const test_exec = @import("../support.zig");

const runNativeFileExitCodeFast = test_exec.runNativeFileExitCodeFast;

test "native std.thread spawn accepts string payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
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
            \\    switch handle.join() {
            \\    .settled => {
            \\        return 42;
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 2;
            \\    }
            \\    }
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.thread generic spawn starts and joins i32 worker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\
            \\@isolated
            \\fn worker(value: i32): void {
            \\    const ignored = value;
            \\}
            \\
            \\fn main(): i32 {
            \\    const payload: i32 = 42;
            \\    const handle = thread.spawn(worker, payload) catch (spawn_problem) {
            \\        const ignored = spawn_problem;
            \\        return 1;
            \\    };
            \\    switch handle.join() {
            \\    .settled => {
            \\        return 42;
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 2;
            \\    }
            \\    }
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.thread detached handle reports successful release" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
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
            \\    switch handle.detach() {
            \\    .settled => {
            \\        return 42;
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 2;
            \\    }
            \\    }
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.thread exposes opaque thread ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\
            \\@isolated
            \\fn worker(value: i32): void {
            \\    const ignored = value;
            \\}
            \\
            \\fn main(): i32 {
            \\    const current = thread.current_id();
            \\    if not current.is_valid() {
            \\        return 1;
            \\    }
            \\    if not current.equals(thread.current_id()) {
            \\        return 2;
            \\    }
            \\    const payload: i32 = 42;
            \\    const handle = thread.spawn(worker, payload) catch (spawn_problem) {
            \\        const ignored = spawn_problem;
            \\        return 4;
            \\    };
            \\    if not handle.id().is_valid() {
            \\        return 3;
            \\    }
            \\    switch handle.join() {
            \\    .settled => {
            \\        return 42;
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 5;
            \\    }
            \\    }
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.thread generic spawn routes i32 payload to hosted worker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\
            \\@isolated
            \\fn worker(value: i32): void {
            \\    const ignored = value;
            \\}
            \\
            \\fn main(): i32 {
            \\    const payload: i32 = 42;
            \\    const handle = thread.spawn(worker, payload) catch (spawn_problem) {
            \\        const ignored = spawn_problem;
            \\        return 1;
            \\    };
            \\    switch handle.join() {
            \\    .settled => {
            \\        return 42;
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 2;
            \\    }
            \\    }
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.thread generic spawn copies structured transferable payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\
            \\struct Job {
            \\    id: i32;
            \\    name: string;
            \\}
            \\
            \\@isolated
            \\fn worker(job: Job): void {
            \\    assert(job.id == 40);
            \\    assert(job.name == "Ada");
            \\}
            \\
            \\fn main(): i32 {
            \\    const payload = Job { id: 40, name: "Ada" };
            \\    const handle = thread.spawn(worker, payload) catch (spawn_problem) {
            \\        const ignored = spawn_problem;
            \\        return 1;
            \\    };
            \\    switch handle.join() {
            \\    .settled => {
            \\        return 42;
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 2;
            \\    }
            \\    }
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.thread spawn_boxed copies payload and joins hosted worker" {
    const source =
        \\import std.thread;
        \\
        \\extern c("call_spawn_boxed_i32") fn call_spawn_boxed_i32(): c_int;
        \\extern c("call_spawn_boxed_aligned") fn call_spawn_boxed_aligned(): c_int;
        \\extern c("set_spawn_boxed_seen") fn set_spawn_boxed_seen(value: c_int): void;
        \\
        \\@isolated
        \\fn unused_worker(value: i32): void {
        \\    const ignored = value;
        \\}
        \\
        \\export c("boxed_i32_worker") fn boxed_i32_worker(ctx: *c_void): void {
        \\    unchecked {
        \\        const payload = ctx as! *i32;
        \\        set_spawn_boxed_seen(*payload as c_int);
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const result = call_spawn_boxed_i32();
        \\    if result == -1 {
        \\        const zero: i32 = 0;
        \\        const handle = thread.spawn(unused_worker, zero) catch (spawn_problem) {
        \\            const ignored = spawn_problem;
        \\            return result as i32;
        \\        };
        \\        const ignored = handle;
        \\    }
        \\    if result != 42 {
        \\        return result as i32;
        \\    }
        \\    const aligned = call_spawn_boxed_aligned();
        \\    return aligned as i32;
        \\}
        \\
    ;
    const c_source =
        \\#include <stdint.h>
        \\#include <stddef.h>
        \\#include <string.h>
        \\
        \\typedef struct CynaTypeDesc CynaTypeDesc;
        \\typedef void (*CynaCopyFn)(void *dst, const void *src, const CynaTypeDesc *desc);
        \\typedef void (*CynaDropFn)(void *value, const CynaTypeDesc *desc);
        \\typedef uint8_t (*CynaEqFn)(const void *lhs, const void *rhs, const CynaTypeDesc *desc);
        \\typedef uint64_t (*CynaHashFn)(const void *value, const CynaTypeDesc *desc);
        \\struct CynaTypeDesc {
        \\    int64_t size;
        \\    int64_t align;
        \\    uint32_t flags;
        \\    CynaCopyFn copy;
        \\    CynaDropFn drop;
        \\    CynaEqFn eq;
        \\    CynaHashFn hash;
        \\    const void *extra;
        \\};
        \\typedef struct {
        \\    unsigned long raw;
        \\} CynaThread;
        \\typedef struct {
        \\    uint8_t is_ok;
        \\    CynaThread ok;
        \\    int32_t err;
        \\} CynaResultThreadThreadError;
        \\typedef struct {
        \\    _Bool settled;
        \\    int32_t code;
        \\    CynaThread handle;
        \\} CynaThreadOpRaw;
        \\
        \\extern const CynaTypeDesc cyna_desc_i32;
        \\extern void boxed_i32_worker(void *);
        \\extern CynaResultThreadThreadError cyna_std_thread_spawn_boxed(void (*entry)(void *), const void *value, const CynaTypeDesc *desc);
        \\extern CynaThreadOpRaw cyna_std_thread_join(CynaThread thread);
        \\
        \\static int32_t seen = 0;
        \\typedef struct {
        \\    unsigned char bytes[64];
        \\} AlignedPayload;
        \\static int32_t aligned_seen = 0;
        \\
        \\void set_spawn_boxed_seen(int32_t value) {
        \\    __atomic_store_n(&seen, value, __ATOMIC_SEQ_CST);
        \\}
        \\
        \\static void copy_aligned_payload(void *dst, const void *src, const CynaTypeDesc *desc) {
        \\    (void)desc;
        \\    memcpy(dst, src, sizeof(AlignedPayload));
        \\}
        \\
        \\static const CynaTypeDesc aligned_payload_desc = {
        \\    sizeof(AlignedPayload), 64, 0, copy_aligned_payload, NULL, NULL, NULL, NULL
        \\};
        \\
        \\static void aligned_worker(void *ctx) {
        \\    uintptr_t addr = (uintptr_t)ctx;
        \\    AlignedPayload *payload = (AlignedPayload *)ctx;
        \\    int ok = (addr % 64u) == 0u && payload->bytes[0] == 42u;
        \\    __atomic_store_n(&aligned_seen, ok ? 42 : 7, __ATOMIC_SEQ_CST);
        \\}
        \\
        \\int32_t call_spawn_boxed_i32(void) {
        \\    int32_t value = 42;
        \\    __atomic_store_n(&seen, 0, __ATOMIC_SEQ_CST);
        \\    CynaResultThreadThreadError spawned = cyna_std_thread_spawn_boxed(boxed_i32_worker, &value, &cyna_desc_i32);
        \\    if (spawned.is_ok != 0) return 1;
        \\    CynaThreadOpRaw joined = cyna_std_thread_join(spawned.ok);
        \\    if (not joined.settled) return 2;
        \\    return __atomic_load_n(&seen, __ATOMIC_SEQ_CST) == 42 ? 42 : 3;
        \\}
        \\
        \\int32_t call_spawn_boxed_aligned(void) {
        \\    AlignedPayload value;
        \\    memset(&value, 0, sizeof(value));
        \\    value.bytes[0] = 42u;
        \\    __atomic_store_n(&aligned_seen, 0, __ATOMIC_SEQ_CST);
        \\    CynaResultThreadThreadError spawned = cyna_std_thread_spawn_boxed(aligned_worker, &value, &aligned_payload_desc);
        \\    if (spawned.is_ok != 0) return 4;
        \\    CynaThreadOpRaw joined = cyna_std_thread_join(spawned.ok);
        \\    if (not joined.settled) return 5;
        \\    return __atomic_load_n(&aligned_seen, __ATOMIC_SEQ_CST) == 42 ? 42 : 6;
        \\}
        \\
    ;

    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCodeWithCSources(
        std.testing.allocator,
        "native_std_thread_spawn_boxed_i32.cy",
        source,
        &.{.{ .name = "spawn_boxed_i32.c", .source = c_source }},
    ));
}

test "native std.sync supports atomic and mutex basics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.sync;
            \\import { AtomicBool, AtomicI32, AtomicUsize, MemoryOrder, Mutex, SyncStatus } from std.sync;
            \\
            \\fn main(): i32 {
            \\    const order = MemoryOrder.seq_cst;
            \\    const cell = AtomicI32.init(41);
            \\    if not cell.is_valid() {
            \\        return 1;
            \\    }
            \\    if cell.load(order) != 41 {
            \\        return 2;
            \\    }
            \\    if cell.fetch_add(1, order) != 41 {
            \\        return 3;
            \\    }
            \\    if cell.load(order) != 42 {
            \\        return 4;
            \\    }
            \\    if not cell.compare_exchange(42, 7, order, MemoryOrder.acquire) {
            \\        return 5;
            \\    }
            \\    if cell.exchange(11, order) != 7 {
            \\        return 6;
            \\    }
            \\    if cell.store(42, order) != SyncStatus.ok {
            \\        return 7;
            \\    }
            \\    if cell.load(order) != 42 {
            \\        return 8;
            \\    }
            \\    if cell.deinit() != SyncStatus.ok {
            \\        return 9;
            \\    }
            \\
            \\    const index = AtomicUsize.init(40);
            \\    if not index.is_valid() {
            \\        return 20;
            \\    }
            \\    if index.load(order) != 40 {
            \\        return 21;
            \\    }
            \\    if index.fetch_add(2, order) != 40 {
            \\        return 22;
            \\    }
            \\    if index.load(order) != 42 {
            \\        return 23;
            \\    }
            \\    if not index.compare_exchange(42, 7, order, MemoryOrder.acquire) {
            \\        return 24;
            \\    }
            \\    if index.exchange(11, order) != 7 {
            \\        return 25;
            \\    }
            \\    if index.store(42, order) != SyncStatus.ok {
            \\        return 26;
            \\    }
            \\    if index.load(order) != 42 {
            \\        return 27;
            \\    }
            \\    if index.deinit() != SyncStatus.ok {
            \\        return 28;
            \\    }
            \\
            \\    const flag = AtomicBool.init(false);
            \\    if not flag.is_valid() {
            \\        return 10;
            \\    }
            \\    if flag.load(order) {
            \\        return 11;
            \\    }
            \\    if flag.store(true, order) != SyncStatus.ok {
            \\        return 12;
            \\    }
            \\    if not flag.exchange(false, order) {
            \\        return 13;
            \\    }
            \\    if not flag.compare_exchange(false, true, order, MemoryOrder.relaxed) {
            \\        return 14;
            \\    }
            \\    if flag.deinit() != SyncStatus.ok {
            \\        return 15;
            \\    }
            \\
            \\    const mutex = Mutex.init();
            \\    if not mutex.is_valid() {
            \\        return 16;
            \\    }
            \\    if mutex.try_lock() != SyncStatus.ok {
            \\        return 17;
            \\    }
            \\    if mutex.try_lock() != SyncStatus.busy {
            \\        return 18;
            \\    }
            \\    if mutex.unlock() != SyncStatus.ok {
            \\        return 19;
            \\    }
            \\    if mutex.lock() != SyncStatus.ok {
            \\        return 29;
            \\    }
            \\    if mutex.unlock() != SyncStatus.ok {
            \\        return 30;
            \\    }
            \\    if mutex.destroy() != SyncStatus.ok {
            \\        return 31;
            \\    }
            \\    return 42;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.sync condvar wakes hosted worker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\import std.sync;
            \\import { AtomicBool, Condvar, MemoryOrder, Mutex, SyncStatus } from std.sync;
            \\
            \\struct Work {
            \\    mutex: Mutex;
            \\    condvar: Condvar;
            \\    ready: AtomicBool;
            \\    done: AtomicBool;
            \\}
            \\
            \\@isolated
            \\fn waiter(work: Work): void {
            \\    if work.mutex.lock() != SyncStatus.ok {
            \\        return;
            \\    }
            \\    const ignored_ready = work.ready.store(true, MemoryOrder.seq_cst);
            \\    const waited = work.condvar.wait(work.mutex);
            \\    if waited != SyncStatus.ok {
            \\        const ignored_unlock = work.mutex.unlock();
            \\        return;
            \\    }
            \\    const ignored_done = work.done.store(true, MemoryOrder.seq_cst);
            \\    const ignored_unlock = work.mutex.unlock();
            \\}
            \\
            \\fn main(): i32 {
            \\    const mutex = Mutex.init();
            \\    if not mutex.is_valid() {
            \\        return 1;
            \\    }
            \\    const condvar = Condvar.init();
            \\    if not condvar.is_valid() {
            \\        return 2;
            \\    }
            \\    const ready = AtomicBool.init(false);
            \\    if not ready.is_valid() {
            \\        return 3;
            \\    }
            \\    const done = AtomicBool.init(false);
            \\    if not done.is_valid() {
            \\        return 4;
            \\    }
            \\    const work = Work { mutex: mutex, condvar: condvar, ready: ready, done: done };
            \\    const handle = thread.spawn(waiter, work) catch (spawn_problem) {
            \\        const ignored = spawn_problem;
            \\        return 9;
            \\    };
            \\    while not ready.load(MemoryOrder.seq_cst) {
            \\    }
            \\    if mutex.lock() != SyncStatus.ok {
            \\        return 5;
            \\    }
            \\    if condvar.signal() != SyncStatus.ok {
            \\        return 6;
            \\    }
            \\    if mutex.unlock() != SyncStatus.ok {
            \\        return 7;
            \\    }
            \\    switch handle.join() {
            \\    .settled => {
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 8;
            \\    }
            \\    }
            \\    if not done.load(MemoryOrder.seq_cst) {
            \\        return 10;
            \\    }
            \\    if condvar.broadcast() != SyncStatus.ok {
            \\        return 11;
            \\    }
            \\    if condvar.destroy() != SyncStatus.ok {
            \\        return 12;
            \\    }
            \\    if mutex.destroy() != SyncStatus.ok {
            \\        return 13;
            \\    }
            \\    if ready.deinit() != SyncStatus.ok {
            \\        return 14;
            \\    }
            \\    if done.deinit() != SyncStatus.ok {
            \\        return 15;
            \\    }
            \\    return 42;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.thread workers share std.sync atomic handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\import std.sync;
            \\import { AtomicI32, MemoryOrder, SyncStatus } from std.sync;
            \\
            \\struct Work {
            \\    counter: AtomicI32;
            \\    amount: i32;
            \\}
            \\
            \\@isolated
            \\fn worker(work: Work): void {
            \\    const ignored = work.counter.fetch_add(work.amount, MemoryOrder.seq_cst);
            \\}
            \\
            \\fn main(): i32 {
            \\    const counter = AtomicI32.init(0);
            \\    if not counter.is_valid() {
            \\        return 1;
            \\    }
            \\
            \\    const first = thread.spawn(worker, Work { counter: counter, amount: 10 }) catch (first_spawn_problem) {
            \\        const ignored = first_spawn_problem;
            \\        return 5;
            \\    };
            \\    const second = thread.spawn(worker, Work { counter: counter, amount: 32 }) catch (second_spawn_problem) {
            \\        const ignored = second_spawn_problem;
            \\        return 4;
            \\    };
            \\    switch first.join() {
            \\    .settled => {
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 2;
            \\    }
            \\    }
            \\    switch second.join() {
            \\    .settled => {
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 3;
            \\    }
            \\    }
            \\
            \\    const total = counter.load(MemoryOrder.seq_cst);
            \\    if counter.deinit() != SyncStatus.ok {
            \\        return 6;
            \\    }
            \\    if total != 42 {
            \\        return 7;
            \\    }
            \\    return 42;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native std.thread workers share std.sync atomic usize handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\import std.thread;
            \\import std.sync;
            \\import { AtomicUsize, MemoryOrder, SyncStatus } from std.sync;
            \\
            \\struct Work {
            \\    counter: AtomicUsize;
            \\    amount: usize;
            \\}
            \\
            \\@isolated
            \\fn worker(work: Work): void {
            \\    const ignored = work.counter.fetch_add(work.amount, MemoryOrder.seq_cst);
            \\}
            \\
            \\fn main(): i32 {
            \\    const counter = AtomicUsize.init(0);
            \\    if not counter.is_valid() {
            \\        return 1;
            \\    }
            \\
            \\    const first = thread.spawn(worker, Work { counter: counter, amount: 10 }) catch (first_spawn_problem) {
            \\        const ignored = first_spawn_problem;
            \\        return 5;
            \\    };
            \\    const second = thread.spawn(worker, Work { counter: counter, amount: 32 }) catch (second_spawn_problem) {
            \\        const ignored = second_spawn_problem;
            \\        return 4;
            \\    };
            \\    switch first.join() {
            \\    .settled => {
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 2;
            \\    }
            \\    }
            \\    switch second.join() {
            \\    .settled => {
            \\    }
            \\    .retry(problem) => {
            \\        const ignored = problem.code;
            \\        return 3;
            \\    }
            \\    }
            \\
            \\    const total = counter.load(MemoryOrder.seq_cst);
            \\    if counter.deinit() != SyncStatus.ok {
            \\        return 6;
            \\    }
            \\    if total != 42 {
            \\        return 7;
            \\    }
            \\    return 42;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

const std = @import("std");
const compat = @import("cyna").compat;

const test_exec = @import("../support.zig");
const helpers = @import("../helpers.zig");

test "builtin string and dense clone preserve independent backing" {
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "builtin_clone_native.cy",
        \\var calls: i32 = 0;
        \\fn make_text(): string { calls = calls + 1; return "hello"; }
        \\fn make_numbers(): [:]i32 { calls = calls + 1; return [42]; }
        \\fn main(): i32 {
        \\    const text = "hello";
        \\    const duplicate = make_text().clone();
        \\    const second = text.clone();
        \\    assert(duplicate == text);
        \\    assert(second == duplicate);
        \\    var numbers: [:]i32 = [42];
        \\    var cloned = make_numbers().clone();
        \\    var second_cloned = numbers.clone();
        \\    cloned[0] = 7;
        \\    second_cloned[0] = 8;
        \\    assert(numbers[0] == 42);
        \\    assert(calls == 2);
        \\    return numbers[0];
        \\}
    , 42);
}

test "builtin clone methods reject arguments" {
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "string_clone_arity.cy",
        \\fn main(): i32 { const value = "hello"; const other = value.clone(1); return 0; }
    , "method `clone` expects 0 args after self, got 1");
    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "dense_clone_arity.cy",
        \\fn main(): i32 { const value: [:]i32 = [1]; const other = value.clone(1); return 0; }
    , "[:].clone expects no arguments");
}

test "Clone implementations execute generic methods without moving source" {
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "clone_protocol_native.cy",
        \\var calls: i32 = 0;
        \\struct Box<T> {
        \\    data: [:]T;
        \\}
        \\impl<T: Clone> Box<T>: Clone {
        \\    fn clone(self: &const Box<T>): Box<T> { calls = calls + 1; return Box<T> { data: self.data.clone() }; }
        \\}
        \\fn borrow<T>(box: &const Box<T>): &const Box<T> { calls = calls + 10; return box; }
        \\fn duplicate<T: Clone>(box: &const Box<T>): Box<T> { return box.clone(); }
        \\fn main(): i32 {
        \\    const original = Box<i32> { data: [21] };
        \\    var other = borrow<i32>(&original).clone();
        \\    other.data[0] = 7;
        \\    const third = duplicate<i32>(&original);
        \\    assert(calls == 12);
        \\    assert(other.data[0] == 7);
        \\    const values: List<i32> = [21];
        \\    var copied = values.clone();
        \\    copied[0] = 2;
        \\    assert(values[0] == 21);
        \\    return original.data[0] + third.data[0];
        \\}
    , 42);
}

test "indirect callbacks preserve large aggregate arguments and results" {
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "callback_aggregate_abi.cy",
        \\struct Payload { first: i64; second: i64; third: i64; }
        \\fn call(action: fn(Payload): ?Payload, value: Payload): ?Payload { return action(value); }
        \\fn main(): i32 {
        \\    const input = Payload { first: 21, second: 7, third: 14 };
        \\    if call(fn(value: Payload): ?Payload { return value; }, input) is value {
        \\        return (value.first + value.second + value.third) as i32;
        \\    }
        \\    return 1;
        \\}
    , 42);
}

test "Clone retains Arc ownership" {
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "clone_arc_native.cy",
        \\import std.own;
        \\struct Payload { value: [:]i32; }
        \\fn main(): i32 {
        \\    const original = own.arc(Payload { value: [42] });
        \\    const other = original.clone();
        \\    drop original;
        \\    const value = other.with_result<i32, i32>(0, fn(payload: &Payload, ignored: i32): i32 { return payload.value[0]; }) catch (status) {
        \\        const ignored = status;
        \\        return 1;
        \\    };
        \\    return value;
        \\}
    , 42);
}

test "slice view attributes execute mutable List and renamed generic views" {
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "slice_view_native.cy",
        \\var trace: i32 = 0;
        \\struct Bag<T> {
        \\    data: [:]T;
        \\    @syntax.slice_view
        \\    fn inspect(self: &const Bag<T>): []const T { trace = trace * 10 + 2; return self.data[..]; }
        \\    @syntax.slice_view
        \\    fn edit(self: &Bag<T>): []T { return self.data[..]; }
        \\}
        \\fn receiver(bag: &const Bag<i32>): &const Bag<i32> { trace = trace * 10 + 1; return bag; }
        \\fn bound(value: i32): i32 { trace = trace * 10 + value; return value - 3; }
        \\fn main(): i32 {
        \\    var values: List<i32> = [1, 2, 3];
        \\    var view: []i32 = values[1..3];
        \\    view[0] = 21;
        \\    assert(values[1] == 21);
        \\    const fixed: List<i32> = [21, 7];
        \\    const read: []const i32 = fixed[..];
        \\    const bag = Bag<i32> { data: [7, 8, 9] };
        \\    const chosen = receiver(&bag)[bound(3)..bound(5)];
        \\    assert(trace == 1235);
        \\    assert(chosen.len() == 2);
        \\    assert(chosen[0] == 7);
        \\    assert(chosen[1] == 8);
        \\    return view[0] + read[0];
        \\}
    , 42);
}

test "slice view attributes enforce native range bounds" {
    for ([_][]const u8{ "1..3", "2..1", "-1..1" }) |bounds| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "fn main(): i32 {{ var values: List<i32> = [1, 2]; const bad = values[{s}]; return bad[0]; }}", .{bounds});
        defer std.testing.allocator.free(source);
        try helpers.expectNativeFailure(std.testing.allocator, "slice_view_bounds.cy", source);
    }
}

fn runNativeFileExitCodeFast(path: []const u8) !i64 {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    return test_exec.runNativeFileExitCode(scratch.allocator(), path);
}

test "slice ranges execute through array-backed views" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\fn main(): i32 {
        \\    var values: [4]i32 = [4]i32 [ 10, 11, 12, 13 ];
        \\    var middle: []i32 = values[1..3];
        \\    var tail: []i32 = values[2..];
        \\    var head: []i32 = values[..2];
        \\    return middle[0] + middle[1] + tail[0] + head[1] - 23;
        \\}
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 23), try runNativeFileExitCodeFast(source_path));
}

test "slice ranges execute through list views" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\fn main(): i32 {
        \\    var values: List<i32> = list_from<i32>([:]i32 [ 10, 11, 12, 13 ]);
        \\    var middle: []const i32 = values.view()[1..3];
        \\    var tail: []const i32 = values.view()[2..];
        \\    var head: []const i32 = values.view()[..2];
        \\    return middle[0] + middle[1] + tail[0] + head[1] - 23;
        \\}
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 23), try runNativeFileExitCodeFast(source_path));
}

test "list mutable views require the explicit mutable API" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\fn main(): i32 {
        \\    var values = list_from<i32>([:]i32 [0, 1]);
        \\    var view = values.view_mut();
        \\    view[0] = 42;
        \\    return values[0];
        \\}
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "slice ranges execute through existing slice views" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\fn middle(xs: []i32): []i32 {
        \\    return xs[1..3];
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: [4]i32 = [4]i32 [ 10, 11, 12, 13 ];
        \\    const view = middle(values[..]);
        \\    return view[0] + view[1];
        \\}
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 23), try runNativeFileExitCodeFast(source_path));
}

test "const byte slice ranges execute through existing slice views" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\fn middle(xs: []const u8): []const u8 {
        \\    return xs[1..3];
        \\}
        \\
        \\fn main(): i32 {
        \\    const view = middle("ABCD".bytes());
        \\    return (view[0] as i32) + (view[1] as i32) - 110;
        \\}
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 23), try runNativeFileExitCodeFast(source_path));
}

test "ordinary view method returning const slice preserves slice type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\struct ReadOnlyInts {
        \\    storage: [:]i32;
        \\
        \\    pub fn view(self: &ReadOnlyInts): []const i32 {
        \\        return self.storage[..];
        \\    }
        \\}
        \\
        \\fn sum(xs: []const i32): i32 {
        \\    return xs[0] + xs[1];
        \\}
        \\
        \\fn main(): i32 {
        \\    var values = ReadOnlyInts { storage: [20, 22] };
        \\    const view: []const i32 = values.view();
        \\    return sum(view);
        \\}
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "indexing an ordinary view method result reads the slice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\struct ReadOnlyInts {
        \\    storage: [:]i32;
        \\
        \\    pub fn view(self: &ReadOnlyInts): []const i32 {
        \\        return self.storage[..];
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var values = ReadOnlyInts { storage: [7, 35] };
        \\    return values.view()[0] + values.view()[1];
        \\}
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "list indexed union switch can read slice payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\union Entry {
        \\    text: []const u8;
        \\    other: i32;
        \\}
        \\
        \\fn first(entries: List<Entry>): i32 {
        \\    switch entries[0] {
        \\    .text(bytes) => {
        \\        return bytes[0] as i32;
        \\    }
        \\    .other(value) => {
        \\        return value;
        \\    }
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const entry: Entry = .text("ABC".bytes());
        \\    const entries: List<Entry> = list_from<Entry>([:]Entry [entry]);
        \\    return first(entries);
        \\}
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 65), try runNativeFileExitCodeFast(source_path));
}

test "borrowed receiver can return list indexed union slice payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\union Entry {
        \\    text: []const u8;
        \\    other: i32;
        \\}
        \\
        \\struct Table {
        \\    entries: List<Entry>;
        \\
        \\    fn first_text(self: &Table): []const u8 {
        \\        switch self.entries[0] {
        \\        .text(bytes) => {
        \\            return bytes;
        \\        }
        \\        .other(value) => {
        \\            const ignored = value;
        \\            return "".bytes();
        \\        }
        \\        }
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const entry: Entry = .text("ABC".bytes());
        \\    var table = Table { entries: list_from<Entry>([:]Entry [entry]) };
        \\    const text = table.first_text();
        \\    return text[0] as i32;
        \\}
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 65), try runNativeFileExitCodeFast(source_path));
}

test "borrowed receiver can return list indexed optional slice field payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\struct Wrap {
        \\    view: []const u8;
        \\}
        \\
        \\struct Table {
        \\    values: List<?Wrap>;
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
        \\    var table = Table { values: list_from<?Wrap>([:]?Wrap [Wrap { view: "ABC".bytes() }]) };
        \\    const text = table.first_text();
        \\    return text[0] as i32;
        \\}
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 65), try runNativeFileExitCodeFast(source_path));
}

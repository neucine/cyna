const std = @import("std");
const compat = @import("cyna").compat;

const helpers = @import("../helpers.zig");
const test_exec = @import("../support.zig");

fn runNativeFileExitCodeFast(path: []const u8) !i64 {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    return test_exec.runNativeFileExitCode(scratch.allocator(), path);
}

test "native std.fs read_file strings survive map key lookup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const data = try compat.dirCreateFile(tmp.dir, "input.txt", .{});
        defer compat.closeFile(data);
        try compat.fileWriteAll(data, "ABC");
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ root, "input.txt" });
    defer std.testing.allocator.free(input_path);

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\import std.fs;
        \\import {{ FsError }} from std.fs;
        \\
        \\fn run(): i32!FsError {{
        \\    var scores: Map<string, i32> = map<string, i32>();
        \\    const text = try fs.read_file("{s}");
        \\    scores[text] = 42;
        \\    if scores.contains(text) and scores.contains("ABC") {{
        \\        return scores["ABC"];
        \\    }}
        \\    return 1;
        \\}}
        \\
        \\fn main(): i32 {{
        \\    const code = run() catch (problem) {{
        \\        const ignored = problem;
        \\        return 99;
        \\    }};
        \\    return code;
        \\}}
        \\
    , .{input_path});
    defer std.testing.allocator.free(source);

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native copy string preserves contents for runtime strings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const data = try compat.dirCreateFile(tmp.dir, "input.txt", .{});
        defer compat.closeFile(data);
        try compat.fileWriteAll(data, "ABC");
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ root, "input.txt" });
    defer std.testing.allocator.free(input_path);

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\import std.fs;
        \\import {{ FsError }} from std.fs;
        \\
        \\fn run(): i32!FsError {{
        \\    const text = try fs.read_file("{s}");
        \\    const copied = text.clone();
        \\    if text == "ABC" and copied == "ABC" {{
        \\        return 42;
        \\    }}
        \\    return 1;
        \\}}
        \\
        \\fn main(): i32 {{
        \\    const code = run() catch (problem) {{
        \\        const ignored = problem;
        \\        return 99;
        \\    }};
        \\    return code;
        \\}}
        \\
    , .{input_path});
    defer std.testing.allocator.free(source);

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native string rfind and slice work" {
    const source =
        \\fn main(): i32 {
        \\    const text = string.from("alpha beta alpha".bytes());
        \\    const part = text.slice(6, 10);
        \\    if part != "beta" {
        \\        return 1;
        \\    }
        \\    if text.rfind("alpha") is pos {
        \\        if pos != 11 {
        \\            return 2;
        \\        }
        \\    } else {
        \\        return 3;
        \\    }
        \\    if text.rfind("missing") is pos {
        \\        const unexpected = pos;
        \\        return 4;
        \\    }
        \\    const empty = text.slice(5, 5);
        \\    if empty != "" {
        \\        return 5;
        \\    }
        \\    const temp = string.from("012345".bytes()).slice(2, 5);
        \\    if temp != "234" {
        \\        return 6;
        \\    }
        \\    return 42;
        \\}
        \\
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_string_rfind_slice.cy", source, 42);
}

test "native projected list copy preserves string elements" {
    const source =
        \\struct Holder {
        \\    values: List<string>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: List<string> = list<string>();
        \\    values.push(string.from("Main".bytes()));
        \\
        \\    const holder = Holder { values: values };
        \\    const copied = Holder { values: holder.values.clone() };
        \\
        \\    if copied.values.len() != 1 {
        \\        return 1;
        \\    }
        \\    if copied.values[0] != "Main" {
        \\        return 2;
        \\    }
        \\    if holder.values[0] != "Main" {
        \\        return 3;
        \\    }
        \\    return 42;
        \\}
        \\
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_projected_list_copy_string_elements.cy", source, 42);
}

test "native list string index bytes drops compiler temporary" {
    const source =
        \\fn consume(bytes: []const u8): i32 {
        \\    if bytes == "java/util/Map".bytes() {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: List<string> = list<string>();
        \\    values.push("java/util/Map");
        \\    const code = consume(values[0].bytes());
        \\    values.clear();
        \\    return code;
        \\}
        \\
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_list_string_index_bytes_temp_drop.cy", source, 42);
}

test "native struct field list string index bytes compares by content" {
    const source =
        \\struct Pool {
        \\    symbols: List<string>;
        \\
        \\    fn contains(self: &Pool, value: []const u8): bool {
        \\        var index: usize = 0;
        \\        while index < self.symbols.len() {
        \\            if self.symbols[index].bytes() == value {
        \\                return true;
        \\            }
        \\            index = index + 1;
        \\        }
        \\        return false;
        \\    }
        \\
        \\    fn add(self: &Pool, value: []const u8): void {
        \\        if self.contains(value) {
        \\            return;
        \\        }
        \\        const symbol = string.from(value);
        \\        self.symbols.push(symbol);
        \\        drop symbol;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var pool = Pool { symbols: list<string>() };
        \\    pool.add("abc".bytes());
        \\    pool.add("abc".bytes());
        \\    pool.add("def".bytes());
        \\    if not pool.contains("abc".bytes()) {
        \\        return 1;
        \\    }
        \\    if pool.contains("xyz".bytes()) {
        \\        return 2;
        \\    }
        \\    if pool.symbols.len() != 2 {
        \\        return 3;
        \\    }
        \\    pool.symbols.clear();
        \\    return 42;
        \\}
        \\
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_struct_field_list_string_index_bytes_compare.cy", source, 42);
}

test "native list pop of shared string detaches from receiver" {
    const source =
        \\fn run(path: string): i32 {
        \\    if path == "class" {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: List<string> = list_from<string>([:]string ["program", "class"]);
        \\    var popped_path: string = values.pop();
        \\    var class_path = popped_path.clone();
        \\    values.clear();
        \\    return run(class_path);
        \\}
        \\
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_list_pop_shared_string_detaches.cy", source, 42);
}

test "native union string payload switch through list index does not drop source" {
    const source =
        \\union Entry {
        \\    text: string;
        \\    alias: u16;
        \\    pair: Pair;
        \\}
        \\
        \\struct Pair {
        \\    left: u16;
        \\    right: u16;
        \\}
        \\
        \\struct Resolved {
        \\    left: string;
        \\    right: string;
        \\}
        \\
        \\enum E { bad = 0 }
        \\
        \\struct Table {
        \\    entries: List<Entry>;
        \\
        \\    fn text_into(self: &Table, index: u16, out: &string): void!E {
        \\        switch self.entries[index as usize] {
        \\        .text(value) => {
        \\            out = string.from(value.bytes());
        \\            return;
        \\        }
        \\        _ => { throw E.bad; }
        \\        }
        \\    }
        \\
        \\    fn alias_into(self: &Table, index: u16, out: &string): void!E {
        \\        switch self.entries[index as usize] {
        \\        .alias(text_index) => {
        \\            return self.text_into(text_index, out);
        \\        }
        \\        _ => { throw E.bad; }
        \\        }
        \\    }
        \\
        \\    fn pair_into(self: &Table, index: u16, out: &Resolved): void!E {
        \\        var pair = Pair { left: 0, right: 0 };
        \\        switch self.entries[index as usize] {
        \\        .pair(actual) => { pair = actual; }
        \\        _ => { throw E.bad; }
        \\        }
        \\
        \\        var left = "";
        \\        var right = "";
        \\        try self.text_into(pair.left, &left);
        \\        try self.text_into(pair.right, &right);
        \\        out = Resolved {
        \\            left: left,
        \\            right: right,
        \\        };
        \\        return;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var table = Table {
        \\        entries: list_from<Entry>([:]Entry [
        \\            .text(string.from("Main".bytes())),
        \\            .alias(0),
        \\            .text(string.from("I".bytes())),
        \\            .pair(Pair { left: 0, right: 2 }),
        \\        ]),
        \\    };
        \\
        \\    var value = "";
        \\    table.alias_into(1, &value) catch (alias_failure) {
        \\        const ignored = alias_failure;
        \\        return 1;
        \\    };
        \\    if value != "Main" {
        \\        return 2;
        \\    }
        \\    drop value;
        \\
        \\    var resolved = Resolved {
        \\        left: "",
        \\        right: "",
        \\    };
        \\    table.pair_into(3, &resolved) catch (pair_failure) {
        \\        const ignored = pair_failure;
        \\        return 3;
        \\    };
        \\    if resolved.left != "Main" or resolved.right != "I" {
        \\        return 4;
        \\    }
        \\    drop resolved;
        \\
        \\    if table.entries[0].text != "Main" {
        \\        return 5;
        \\    }
        \\    drop table;
        \\    return 42;
        \\}
        \\
    ;

    try std.testing.expectEqual(
        @as(i64, 42),
        try test_exec.runNativeSourceExitCode(
            std.testing.allocator,
            "native_union_string_payload_switch_list_index_no_source_drop.cy",
            source,
        ),
    );
}

test "native result string payload survives switch capture" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const data = try compat.dirCreateFile(tmp.dir, "input.txt", .{});
        defer compat.closeFile(data);
        try compat.fileWriteAll(data, "ABC");
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ root, "input.txt" });
    defer std.testing.allocator.free(input_path);

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\import std.fs;
        \\import {{ FsError }} from std.fs;
        \\
        \\fn load(): string!FsError {{
        \\    return try fs.read_file("{s}");
        \\}}
        \\
        \\fn main(): i32 {{
        \\    const text = load() catch (problem) {{
        \\        const ignored = problem;
        \\        return 99;
        \\    }};
        \\    if text == "ABC" {{ return 42; }}
        \\    return 1;
        \\}}
        \\
    , .{input_path});
    defer std.testing.allocator.free(source);

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native try string payload survives local binding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const data = try compat.dirCreateFile(tmp.dir, "input.txt", .{});
        defer compat.closeFile(data);
        try compat.fileWriteAll(data, "ABC");
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ root, "input.txt" });
    defer std.testing.allocator.free(input_path);

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\import std.fs;
        \\import {{ FsError }} from std.fs;
        \\
        \\fn load(): string!FsError {{
        \\    return try fs.read_file("{s}");
        \\}}
        \\
        \\fn run(): i32!FsError {{
        \\    const text = try load();
        \\    if text == "ABC" {{
        \\        return 42;
        \\    }}
        \\    return 1;
        \\}}
        \\
        \\fn main(): i32 {{
        \\    const code = run() catch (problem) {{
        \\        const ignored = problem;
        \\        return 99;
        \\    }};
        \\    return code;
        \\}}
        \\
    , .{input_path});
    defer std.testing.allocator.free(source);

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native for loop observes successive runtime string list items" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const data = try compat.dirCreateFile(tmp.dir, "input.txt", .{});
        defer compat.closeFile(data);
        try compat.fileWriteAll(data, "ABC");
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ root, "input.txt" });
    defer std.testing.allocator.free(input_path);

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\import std.fs;
        \\import {{ FsError }} from std.fs;
        \\
        \\fn run(): i32!FsError {{
        \\    var values: List<string> = list<string>();
        \\    values.push(try fs.read_file("{s}"));
        \\    values.push(try fs.read_file("{s}"));
        \\    var seen = 0;
        \\    for text in values {{
        \\        if text != "ABC" {{
        \\            return 1;
        \\        }}
        \\        seen = seen + 1;
        \\    }}
        \\    if seen == 2 {{
        \\        return 42;
        \\    }}
        \\    return 2;
        \\}}
        \\
        \\fn main(): i32 {{
        \\    const code = run() catch (problem) {{
        \\        const ignored = problem;
        \\        return 99;
        \\    }};
        \\    return code;
        \\}}
        \\
    , .{ input_path, input_path });
    defer std.testing.allocator.free(source);

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCodeFast(source_path));
}

test "native string_from copies byte slice into owned string" {
    const source =
        \\fn build(): string {
        \\    var bytes: [:]u8 = [65, 66, 67];
        \\    const text = string.from(bytes[..]);
        \\    bytes[0] = 90;
        \\    return text;
        \\}
        \\
        \\fn main(): i32 {
        \\    const text = build();
        \\    if text == "ABC" {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
        \\
    ;

    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "string_from.cy", source));
}

test "native string literals decode quote and newline escapes" {
    const source =
        \\fn main(): i32 {
        \\    const text = "a\"b\n";
        \\    const bytes = text.bytes();
        \\    if bytes.len() != 4 {
        \\        return 1;
        \\    }
        \\    if bytes[0] != 97 or bytes[1] != 34 or bytes[2] != 98 or bytes[3] != 10 {
        \\        return 2;
        \\    }
        \\    return 42;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try test_exec.runNativeSourceExitCode(std.testing.allocator, "string_literal_escapes.cy", source));
}

test "native borrowed iterator preserves list optional strings across exits" {
    const source =
        \\struct Entry { name: ?string; }
        \\fn contains(entries: &const List<Entry>, target: string): bool {
        \\    for entry in entries {
        \\        if entry.name is name {
        \\            if name == target { return true; }
        \\        }
        \\    }
        \\    return false;
        \\}
        \\fn visit(visits: &i32): void { visits = visits + 1; }
        \\fn exercise(entries: &const List<Entry>, visits: &i32): void {
        \\    for entry in entries {
        \\        defer visit(visits);
        \\        if entry.name is name {
        \\            if name == "header" { continue; }
        \\            if name == "footer" { break; }
        \\        }
        \\    }
        \\}
        \\fn main(): i32 {
        \\    var entries = list<Entry>();
        \\    assert(not contains(&entries, "header"));
        \\    entries.push(Entry { name: string.from("header".bytes()) });
        \\    assert(contains(&entries, "header"));
        \\    assert(not contains(&entries, "Header"));
        \\    if entries[0].name is name { assert(name == "header"); } else { assert(false); }
        \\    entries.push(Entry { name: none });
        \\    entries.push(Entry { name: string.from("footer".bytes()) });
        \\    var repeat = 0;
        \\    while repeat < 3 {
        \\        assert(contains(&entries, "header"));
        \\        assert(contains(&entries, "footer"));
        \\        assert(not contains(&entries, "missing"));
        \\        var visits: i32 = 0;
        \\        exercise(&entries, &visits);
        \\        assert(visits == 3);
        \\        repeat = repeat + 1;
        \\    }
        \\    assert(contains(&entries, "header"));
        \\    assert(contains(&entries, "footer"));
        \\    return 0;
        \\}
    ;
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "borrowed_list_entries.cy", source, 0);
}

test "native borrowed iterator preserves custom hook elements across repeated bindings" {
    const source =
        \\struct Entry { name: ?string; }
        \\struct Bag<T> {
        \\    values: [:]T;
        \\    @syntax.iter fn begin(self: &const Bag<T>): usize { return 0; }
        \\    @syntax.iter_has_next fn more(self: &const Bag<T>, state: &const usize): bool { return state < self.values.len(); }
        \\    @syntax.iter_next fn advance(self: &const Bag<T>, state: &usize): usize { const cursor: usize = state; state = state + 1; return cursor; }
        \\    @syntax.iter_item fn element(self: &const Bag<T>, cursor: usize): &const T { return &self.values[cursor]; }
        \\}
        \\fn main(): i32 {
        \\    var bag = Bag<Entry> { values: [Entry { name: string.from("kept".bytes()) }, Entry { name: none }] };
        \\    var visits = 0;
        \\    for entry in &bag {
        \\        if entry.name is name { assert(name == "kept"); }
        \\        visits = visits + 1;
        \\    }
        \\    assert(visits == 2);
        \\    for entry in &bag {
        \\        if entry.name is name { assert(name == "kept"); }
        \\    }
        \\    if bag.values[0].name is name { assert(name == "kept"); } else { assert(false); }
        \\    return 0;
        \\}
    ;
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "borrowed_custom_entries.cy", source, 0);
}

test "native borrowed iterator preserves fixed dense and slice elements" {
    const source =
        \\struct Entry { name: ?string; }
        \\fn temporary(): [2]Entry {
        \\    return [Entry { name: string.from("temporary".bytes()) }, Entry { name: none }];
        \\}
        \\fn main(): i32 {
        \\    var fixed: [2]Entry = [Entry { name: string.from("fixed".bytes()) }, Entry { name: none }];
        \\    var dense: [:]Entry = [Entry { name: string.from("dense".bytes()) }, Entry { name: none }];
        \\    var repeat = 0;
        \\    while repeat < 3 {
        \\        for entry in fixed { if entry.name is name { assert(name == "fixed"); } }
        \\        for entry in dense { if entry.name is name { assert(name == "dense"); } }
        \\        const view: []const Entry = fixed[..];
        \\        for entry in view { if entry.name is name { assert(name == "fixed"); } }
        \\        repeat = repeat + 1;
        \\    }
        \\    if fixed[0].name is name { assert(name == "fixed"); } else { assert(false); }
        \\    if dense[0].name is name { assert(name == "dense"); } else { assert(false); }
        \\    for entry in temporary() { if entry.name is name { assert(name == "temporary"); } }
        \\    for entry in temporary() { if entry.name is name { assert(name == "temporary"); } break; }
        \\    return 0;
        \\}
    ;
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "borrowed_builtin_entries.cy", source, 0);
}

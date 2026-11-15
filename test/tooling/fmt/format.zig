const std = @import("std");
const cyna = @import("cyna");
const compat = cyna.compat;

fn formatted(source: []const u8) ![]u8 {
    var context = cyna.compiler.diagnostics.Context.discarded();
    return cyna.formatter.format(std.testing.allocator, "format.cy", source, &context);
}

fn expectFormat(source: []const u8, expected: []const u8) !void {
    const actual = try formatted(source);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    const twice = try formatted(actual);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(actual, twice);
}

test "fmt preserves short catch arms" {
    const source =
        \\enum Failure { bad; }
        \\fn source(): i32!Failure { throw Failure.bad; }
        \\fn main(): i32 { return source() catch(code)=>7; }
    ;
    const expected =
        \\enum Failure {
        \\    bad;
        \\}
        \\fn source(): i32 ! Failure {
        \\    throw Failure.bad;
        \\}
        \\fn main(): i32 {
        \\    return source() catch (code) => 7;
        \\}
        \\
    ;
    try expectFormat(source, expected);
}

test "fmt separates assignment capture from attribute syntax" {
    const source =
        \\struct Box { value: i32; }
        \\fn main(): i32 {
        \\    var box = Box { value: 1 };
        \\    box.value=2@const old;
        \\    box.value=3@var previous;
        \\    return old + previous;
        \\}
    ;
    const actual = try formatted(source);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "box.value = 2 @ const old;") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "box.value = 3 @ var previous;") != null);
    const twice = try formatted(actual);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(actual, twice);
}

test "fmt preserves renamed indexing and iteration attributes" {
    const source =
        \\struct Box {
        \\    value: i32;
        \\    @syntax.index fn fetch(self: &const Box, key: usize): i32 { return self.value; }
        \\    @syntax.index_set fn replace(self: &Box, key: usize, value: i32): void { self.value = value; }
        \\    @syntax.iter fn begin(self: &const Box): usize { return 0; }
        \\    @syntax.iter_has_next fn more(self: &const Box, state: &const usize): bool { return state < 1; }
        \\    @syntax.iter_next fn advance(self: &const Box, state: &usize): usize { state = state + 1; return 0; }
        \\    @syntax.iter_item fn element(self: &const Box, cursor: usize): i32 { return self.value; }
        \\}
        \\fn main(): i32 { var box = Box { value: 42 }; box[0] = 42; for item in box { return box.fetch(0) + item; } return 0; }
    ;
    const actual = try formatted(source);
    defer std.testing.allocator.free(actual);
    for ([_][]const u8{ "@syntax.index", "@syntax.index_set", "@syntax.iter", "@syntax.iter_has_next", "@syntax.iter_next", "@syntax.iter_item", "box.fetch(0)" }) |text| {
        try std.testing.expect(std.mem.indexOf(u8, actual, text) != null);
    }
    const twice = try formatted(actual);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(actual, twice);
}

test "fmt removes redundant integer casts from index hook syntax only" {
    const source =
        \\struct Bag {
        \\    values: [:]i32;
        \\    @syntax.index fn fetch(self: &const Bag, key: usize): &const i32 { return &self.values[key]; }
        \\    @syntax.index_set fn replace(self: &Bag, key: usize, value: i32): void { self.values[key] = value; }
        \\}
        \\fn main(): i32 {
        \\    var bag = Bag { values: [10, 20] };
        \\    const key: u16 = 1;
        \\    bag[key as usize] = 42;
        \\    const direct = bag.fetch(key as usize);
        \\    const indexed = bag[key as usize];
        \\    const nested = bag[(key as usize) + 0];
        \\    return direct + indexed + nested - 84;
        \\}
    ;
    const actual = try formatted(source);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "bag[key] = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "bag[key];") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "bag.fetch(key as usize)") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "(key as usize) + 0") != null);
    const twice = try formatted(actual);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(actual, twice);
}

test "fmt normalizes imported List integer index casts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        \\fn main(): i32 {
        \\    var items: List<i32> = [10, 42];
        \\    const key: u16 = 1;
        \\    return items[key as usize];
        \\}
    ;
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(path);
    var context = cyna.compiler.diagnostics.Context.discarded();
    const actual = try cyna.formatter.format(std.testing.allocator, path, source, &context);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "return items[key];") != null);
}

test "fmt normalizes index casts in source order across functions" {
    const source =
        \\struct Bag {
        \\    values: [:]i32;
        \\    @syntax.index fn at(self: &const Bag, key: usize): i32 { return self.values[key]; }
        \\}
        \\fn early(bag: &const Bag, key: u16): i32 { return bag[key as usize]; }
        \\fn late(bag: &const Bag, key: u16): i32 { return bag[key as usize]; }
        \\fn main(): i32 {
        \\    const bag = Bag { values: [21, 21] };
        \\    return early(&bag, 0) + late(&bag, 1);
        \\}
    ;
    const actual = try formatted(source);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, actual, "return bag[key];"));
    const twice = try formatted(actual);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(actual, twice);
}

test "fmt removes exact contextual literal casts and retains value-changing casts" {
    const source =
        \\fn take(value: f32): f32 { return value; }
        \\fn number(value: usize): usize { return value; }
        \\fn abi(value: c_double): c_double { return value; }
        \\fn abi32(value: c_float): c_float { return value; }
        \\fn exact(): f32 {
        \\    const local: f32 = (0.5 as f32);
        \\    return take((0.25 as f32)) + local;
        \\}
        \\fn rounded(): f32 { return take(0.1 as f32); }
        \\fn main(): i32 {
        \\    const count = number(2 as usize);
        \\    const floating = abi(2.0 as c_double);
        \\    const exact_abi32 = abi32(0.5 as c_float);
        \\    const rounded_abi32 = abi32(0.1 as c_float);
        \\    const uncontexted = 2 as usize;
        \\    return 0;
        \\}
    ;
    const actual = try formatted(source);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "number(2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "abi(2.0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "abi32(0.5)") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "abi32(0.1 as c_float)") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "uncontexted = 2 as usize") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "take(0.25)") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "local: f32 = 0.5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "take(0.1 as f32)") != null);
    const twice = try formatted(actual);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(actual, twice);
}

test "fmt normalizes only semantically equivalent slice view attributes" {
    const source =
        \\struct Bag {
        \\    data: [:]i32;
        \\    @syntax.slice_view
        \\    fn inspect(self: &const Bag): []const i32 { return self.data[..]; }
        \\    @syntax.slice_view
        \\    fn edit(self: &Bag): []i32 { return self.data[..]; }
        \\}
        \\struct Other {
        \\    data: [:]i32;
        \\    fn view_mut(self: &Other): []i32 { return self.data[..]; }
        \\}
        \\fn mutable(bag: &Bag): []i32 { return bag.edit(); }
        \\fn readonly(bag: &const Bag): []const i32 { return bag.inspect(); }
        \\fn force_const(bag: &Bag): []const i32 { return bag.inspect(); }
        \\fn unmarked(other: &Other): []i32 { return other.view_mut(); }
        \\fn comments(bag: &Bag): []i32 { return bag.edit( // retain
        \\); }
    ;
    const actual = try formatted(source);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "return bag[..];") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "return bag.inspect();") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "return other.view_mut();") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "// retain") != null);
    const twice = try formatted(actual);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(actual, twice);
}

test "fmt preserves ordinary clone method calls" {
    const source =
        \\struct Box {
        \\    value: i32;
        \\    fn duplicate(self: &const Box): Box { return Box { value: self.value }; }
        \\}
        \\fn main(): i32 { const original = Box { value: 21 }; const other = original.duplicate(); return other.duplicate().value; }
    ;
    const actual = try formatted(source);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "original.duplicate()") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "other.duplicate()") != null);
    const twice = try formatted(actual);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(actual, twice);
}

test "fmt normalizes imported List methods using slice view attributes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        \\fn mutable(items: &List<i32>): []i32 { return items.view_mut(); }
        \\fn readonly(items: &const List<i32>): []const i32 { return items.view(); }
        \\fn force_const(items: &List<i32>): []const i32 { return items.view(); }
        \\fn main(): i32 { return 0; }
    ;
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(path);
    var context = cyna.compiler.diagnostics.Context.discarded();
    const actual = try cyna.formatter.format(std.testing.allocator, path, source, &context);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, actual, "return items[..];"));
    try std.testing.expect(std.mem.indexOf(u8, actual, "return items.view();") != null);
    const twice = try cyna.formatter.format(std.testing.allocator, path, actual, &context);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(actual, twice);
}

test "fmt preserves slice method spellings when semantic proof is unavailable" {
    const actual = try formatted("fn unresolved(items: &Unknown): []i32 { return items.view_mut(); }");
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "return items.view_mut();") != null);
}

test "fmt preserves slice calls inside generic caller bodies" {
    const source =
        \\struct Crate<T> {
        \\    data: [:]T;
        \\    @syntax.slice_view
        \\    fn expose(self: &Crate<T>): []T { return self.data[..]; }
        \\}
        \\fn borrow<T>(owner: &Crate<T>): []T { return owner.expose(); }
        \\fn main(): i32 {
        \\    var owner = Crate<i32> { data: [42] };
        \\    const view = borrow<i32>(&owner);
        \\    return view[0];
        \\}
    ;
    const actual = try formatted(source);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "return owner.expose();") != null);
    const twice = try formatted(actual);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(actual, twice);
}

test "fmt normalizes whitespace and redundant construction types idempotently" {
    try expectFormat("struct A{x:i32;} fn main():i32{const a:A=A{x:42};return a.x;}",
        \\struct A {
        \\    x: i32;
        \\}
        \\fn main(): i32 {
        \\    const a: A = {
        \\        x: 42
        \\    };
        \\    return a.x;
        \\}
        \\
    );
}

test "fmt removes a matching dense array type from a direct return" {
    try expectFormat("fn sample_header_bytes(): [:]u8 { return [:]u8[0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 52, 0, 3]; }",
        \\fn sample_header_bytes(): [:]u8 {
        \\    return [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 52, 0, 3];
        \\}
        \\
    );
    const different = try formatted("fn other(): [:]u8 { return [:]i32[1]; }");
    defer std.testing.allocator.free(different);
    try std.testing.expect(std.mem.indexOf(u8, different, "return [:]i32[1];") != null);
}

test "fmt preserves comments literals and escaped names around normalization" {
    const source =
        \\// leading
        \\struct A { `type`: string; }
        \\fn main(): i32 {
        \\const a: A = /*invalid*/ A {};
        \\}
    ;
    try std.testing.expectError(error.ParseFailed, formatted(source));
    const valid =
        \\// leading
        \\struct A { `type`: string; }
        \\fn main(): i32 {
        \\const a: A = // before constructor
        \\A // after constructor
        \\{ `type`: "a // b\n" }; // trailing
        \\const text = "payload";
        \\const s = $"literal {text}";
        \\return 0;
        \\}
        \\// final
    ;
    const actual = try formatted(valid);
    defer std.testing.allocator.free(actual);
    for ([_][]const u8{ "// leading", "// before constructor", "// after constructor", "// trailing", "// final", "`type`", "\"a // b\\n\"", "$\"literal {text}\"" }) |part| {
        try std.testing.expect(std.mem.indexOf(u8, actual, part) != null);
    }
    const twice = try formatted(actual);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(actual, twice);
}

test "fmt retains constructors without direct matching named context" {
    const source =
        \\struct A { x: i32; }
        \\struct B { x: i32; }
        \\fn main(): i32 {
        \\const inferred = A { x: 1 };
        \\const optional: ?A = A { x: 2 };
        \\const other: B = A { x: 3 };
        \\const expression: A = A { x: 4 }.x;
        \\return inferred.x;
        \\}
    ;
    const actual = try formatted(source);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, actual, "= A {"));
}

test "fmt handles pointer types operators multiline parameters sparse and generic storage" {
    const source =
        \\fn add(
        \\ a: i32,
        \\ b: i32
        \\): i32 { return a * -b; }
        \\fn main(): i32 {
        \\var xs: [;]i32 = [1, none, 3];
        \\var values: List<i32> = list<i32>();
        \\var n: i32 = 1;
        \\const p: &i32 = &n;
        \\const text = "unchanged";
        \\return add(n, -2);
        \\}
    ;
    const actual = try formatted(source);
    defer std.testing.allocator.free(actual);
    const twice = try formatted(actual);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(actual, twice);
    try std.testing.expect(std.mem.indexOf(u8, actual, "a * -b") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "[;]i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "&i32 = &n") != null);
}

test "fmt rejects syntax errors before changing files and check never writes" {
    const allocator = std.testing.allocator;
    const workspace = try compat.makeTempWorkspace(allocator, "fmt-command");
    defer workspace.cleanup(allocator);
    const valid = try std.fs.path.join(allocator, &.{ workspace.path, "valid.cy" });
    defer allocator.free(valid);
    const invalid = try std.fs.path.join(allocator, &.{ workspace.path, "invalid.cy" });
    defer allocator.free(invalid);
    const source = "fn main():i32{return 42;}";
    try compat.writeTextFile(valid, source);
    try compat.writeTextFile(invalid, "fn main( {");
    var context = cyna.compiler.diagnostics.Context.discarded();
    const check = try cyna.commands.fmt.formatPaths(allocator, &.{workspace.path}, .{ .check = true, .report_changes = false }, &context);
    try std.testing.expectEqual(@as(usize, 1), check.changed);
    try std.testing.expectEqual(@as(usize, 1), check.failed);
    const unchanged = try compat.readFileAlloc(allocator, valid, 4096);
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(source, unchanged);
    const update = try cyna.commands.fmt.formatPaths(allocator, &.{valid}, .{ .report_changes = false }, &context);
    try std.testing.expectEqual(@as(usize, 1), update.changed);
    const clean = try cyna.commands.fmt.formatPaths(allocator, &.{valid}, .{ .check = true, .report_changes = false }, &context);
    try std.testing.expectEqual(@as(usize, 0), clean.changed);
    const still_invalid = try compat.readFileAlloc(allocator, invalid, 4096);
    defer allocator.free(still_invalid);
    try std.testing.expectEqualStrings("fn main( {", still_invalid);
}

test "fmt directory traversal skips generated and hidden sources" {
    const allocator = std.testing.allocator;
    const workspace = try compat.makeTempWorkspace(allocator, "fmt-recursion");
    defer workspace.cleanup(allocator);
    for ([_][]const u8{ "nested/source.cy", ".git/ignored.cy", "build/generated.cy", "node_modules/vendor.cy" }) |relative| {
        const path = try std.fs.path.join(allocator, &.{ workspace.path, relative });
        defer allocator.free(path);
        try compat.writeTextFile(path, "fn main():i32{return 0;}");
    }
    var context = cyna.compiler.diagnostics.Context.discarded();
    const result = try cyna.commands.fmt.formatPaths(allocator, &.{workspace.path}, .{ .report_changes = false }, &context);
    try std.testing.expectEqual(@as(usize, 1), result.changed);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
}

test "fmt remains idempotent across examples and standard library syntax" {
    for ([_][]const u8{
        "examples/concurrency_atomic.cy",
        "examples/milestone_app.cy",
        "examples/task_group_cava_shape.cy",
        "examples/task_group_descendant.cy",
        "examples/task_group_viewer_shape.cy",
        "packages/std/src/std_json.cy",
        "packages/std/src/std_prelude.cy",
        "packages/std/src/std_thread.cy",
    }) |path| {
        const source = try compat.readFileAlloc(std.testing.allocator, path, 4 * 1024 * 1024);
        defer std.testing.allocator.free(source);
        const actual = try formatted(source);
        defer std.testing.allocator.free(actual);
        const twice = try formatted(actual);
        defer std.testing.allocator.free(twice);
        try std.testing.expectEqualStrings(actual, twice);
    }
}

test "fmt normalization preserves semantic validity" {
    const helpers = @import("../../helpers.zig");
    const source =
        \\struct A { x: i32; }
        \\fn main(): i32 {
        \\    const a: A = A { x: 20 };
        \\    var b: A = A { x: 22 };
        \\    b.x = b.x + 1;
        \\    const inferred = A { x: 1 };
        \\    const optional: ?A = A { x: 0 };
        \\    return a.x + b.x - inferred.x;
        \\}
    ;
    try helpers.expectSemanticSuccess(std.testing.allocator, "fmt_before", source);
    const actual = try formatted(source);
    defer std.testing.allocator.free(actual);
    try helpers.expectSemanticSuccess(std.testing.allocator, "fmt_after", actual);
}

test "fmt indents standalone comments in otherwise empty blocks" {
    try expectFormat("fn empty(): void {\n// keep this\n}\n",
        \\fn empty(): void {
        \\    // keep this
        \\}
        \\
    );
}

test "fmt keeps imports casts and asm specifiers conventional" {
    const source =
        \\import { Value, Other } from .foo;
        \\export asm("VALUE") const exported: usize = 1;
        \\fn read(addr: usize): u8 {
        \\    unchecked { const integer: usize = addr as! usize; return *(integer as! *u8); }
        \\}
    ;
    const actual = try formatted(source);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "import { Value, Other } from .foo;") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "export asm(\"VALUE\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "as! *u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "as! usize") != null);
    const twice = try formatted(actual);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(actual, twice);
}

test "fmt preserves blank lines around comments" {
    const source =
        \\import .foo;
        \\
        \\// explanation
        \\fn main(): i32 {
        \\    const x: i32 = 1;
        \\
        \\    // next step
        \\    return x;
        \\}
    ;
    const actual = try formatted(source);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "import .foo;\n\n// explanation") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "const x: i32 = 1;\n\n    // next step") != null);
    const twice = try formatted(actual);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(actual, twice);
}

test "fmt keeps generic commas and multiline empty blocks" {
    const source =
        \\struct Box<T, const N: usize> { value: T; }
        \\fn main(): i32 {
        \\    var box: Box<i32, 4> = Box<i32, 4> { value: 1 };
        \\    while false {
        \\    }
        \\    return box.value;
        \\}
    ;
    const actual = try formatted(source);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "Box<i32, 4>") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "while false {\n    }") != null);
    const twice = try formatted(actual);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(actual, twice);
}

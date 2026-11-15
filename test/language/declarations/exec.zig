const std = @import("std");
const compat = @import("cyna").compat;

const helpers = @import("../../helpers.zig");

test "private imports are rejected across files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/math.cy", .data =
        \\
        \\fn hidden(): i32 {
        \\    return 42;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import lib.math;
        \\
        \\fn main(): i32 {
        \\    return math.hidden();
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectModuleSemanticFailed(std.testing.allocator, root_path);
}

test "private struct fields stay private across files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/model.cy", .data =
        \\
        \\pub struct User {
        \\    pub id: i32;
        \\    secret: i32;
        \\}
        \\
        \\pub fn make(): User {
        \\    return User { id: 1, secret: 2 };
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { make } from lib.model;
        \\
        \\fn main(): i32 {
        \\    return make().secret;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectModuleSemanticFailed(std.testing.allocator, root_path);
}

test "ambiguous imported functions are rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/a.cy", .data =
        \\
        \\pub fn value(): i32 {
        \\    return 1;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/b.cy", .data =
        \\
        \\pub fn value(): i32 {
        \\    return 2;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { value } from lib.a;
        \\import { value } from lib.b;
        \\
        \\fn main(): i32 {
        \\    return value();
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectModuleSemanticFailed(std.testing.allocator, root_path);
}

test "private globals do not resolve across files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/math.cy", .data =
        \\
        \\const hidden: i32 = 42;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { hidden } from lib.math;
        \\
        \\fn main(): i32 {
        \\    return hidden;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectModuleSemanticFailed(std.testing.allocator, root_path);
}

test "top-level globals support declarative initialization and mutation" {
    const source =
        \\const base: i32 = 40;
        \\const answer: i32 = base + 2;
        \\var counter: i32 = base;
        \\const initial_counter: i32 = counter;
        \\
        \\fn main(): i32 {
        \\    counter = answer;
        \\    return counter + initial_counter - 40;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "top_level_globals", "native_top_level_globals.cy", source, 42);
}

test "native global initializer can use imported public constant" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/base.cy", .data =
        \\pub const base: i32 = 40;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { base } from lib.base;
        \\const answer: i32 = base + 2;
        \\fn main(): i32 { return answer; }
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);
    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "global initializer copies imported mutable global initial value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/base.cy", .data =
        \\pub var base: i32 = 40;
        \\pub fn change_base(): void { base = 1; }
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { base, change_base } from lib.base;
        \\const answer: i32 = base + 2;
        \\fn main(): i32 {
        \\    change_base();
        \\    return answer;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);
    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "native top-level struct globals can be passed by mutable reference to helpers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/table.cy", .data =
        \\
        \\pub struct Table {
        \\    pub count: i32;
        \\    pub values: [2]i32;
        \\}
        \\
        \\pub fn bump(table: &Table): void {
        \\    table.count = table.count + 1;
        \\    table.values[0] = table.values[0] + 1;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { Table, bump } from lib.table;
        \\
        \\var table: Table = Table {
        \\    count: 39,
        \\    values: [1, 1],
        \\};
        \\
        \\fn main(): i32 {
        \\    bump(&table);
        \\    return table.count + table.values[0];
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "native top-level struct globals can call mutable receiver methods" {
    const source =
        \\struct Counter {
        \\    value: i32;
        \\
        \\    pub fn bump(self: &Counter): void {
        \\        self.value = self.value + 1;
        \\    }
        \\}
        \\
        \\var counter: Counter = Counter { value: 41 };
        \\
        \\fn main(): i32 {
        \\    counter.bump();
        \\    return counter.value;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "top_level_global_mutable_method_receiver", "native_top_level_global_mutable_method_receiver.cy", source, 42);
}

test "native imported public globals support cross-file reads and projections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/math.cy", .data =
        \\
        \\pub union Token {
        \\    number: i32;
        \\    eof;
        \\}
        \\
        \\pub struct Pair {
        \\    pub left: i32;
        \\    pub right: i32;
        \\}
        \\
        \\pub struct Holder {
        \\    pub values: [3]i32;
        \\    pub token: Token;
        \\    pub tokens: [2]Token;
        \\}
        \\
        \\pub struct InnerFields {
        \\    pub left: i32;
        \\    pub right: i32;
        \\}
        \\
        \\pub struct OuterFields {
        \\    pub inner: InnerFields;
        \\    pub tail: i32;
        \\}
        \\
        \\pub struct OuterToken {
        \\    pub inner: Holder;
        \\}
        \\
        \\pub const forty_two: i32 = 42;
        \\pub const base: i32 = 40;
        \\pub const values: [3]i32 = [10, 20, 12];
        \\pub const pair: Pair = Pair { left: 40, right: 2 };
        \\pub const outer_fields: OuterFields = OuterFields { inner: InnerFields { left: 20, right: 20 }, tail: 2 };
        \\pub const holder: Holder = Holder {
        \\    values: [10, 20, 12],
        \\    token: .number(42),
        \\    tokens: [.eof(), .number(42)],
        \\};
        \\pub const outer_token: OuterToken = OuterToken {
        \\    inner: Holder {
        \\        values: [10, 20, 12],
        \\        token: .number(42),
        \\        tokens: [.eof(), .number(42)],
        \\    },
        \\};
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { Holder, Pair, Token, base, forty_two, holder, outer_fields, outer_token, pair, values } from lib.math;
        \\
        \\fn score_holder(value: Holder): i32 {
        \\    return value.values[0] + value.values[1] + value.values[2];
        \\}
        \\
        \\fn main(): i32 {
        \\    const answer: i32 = base + 2;
        \\    const local_pair: Pair = pair;
        \\    const local_token: Token = holder.token;
        \\    if forty_two != 42 {
        \\        return 1;
        \\    }
        \\    if answer != 42 {
        \\        return 2;
        \\    }
        \\    if values[0] + values[1] + values[2] != 42 {
        \\        return 3;
        \\    }
        \\    if local_pair.left + local_pair.right != 42 {
        \\        return 4;
        \\    }
        \\    if outer_fields.inner.left + outer_fields.inner.right + outer_fields.tail != 42 {
        \\        return 5;
        \\    }
        \\    if score_holder(holder) != 42 {
        \\        return 6;
        \\    }
        \\    if local_token.number != 42 {
        \\        return 7;
        \\    }
        \\    if holder.tokens[1].number != 42 {
        \\        return 8;
        \\    }
        \\    if outer_token.inner.token.number != 42 {
        \\        return 9;
        \\    }
        \\    if outer_token.inner.tokens[1].number != 42 {
        \\        return 10;
        \\    }
        \\    return 42;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "native top-level struct globals support union payload projection" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    token: Token;
        \\}
        \\
        \\const holder: Holder = Holder { token: .number(42) };
        \\
        \\fn main(): i32 {
        \\    return holder.token.number;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_top_level_struct_global_union_projection.cy", source, 42);
}

test "native top-level struct globals support indexed union payload projection" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    tokens: [2]Token;
        \\}
        \\
        \\const holder: Holder = Holder { tokens: [.eof(), .number(42)] };
        \\
        \\fn main(): i32 {
        \\    return holder.tokens[1].number;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_top_level_struct_global_indexed_union_projection.cy", source, 42);
}

test "native top-level nested struct globals support union payload projection" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    eof;
        \\}
        \\
        \\struct Inner {
        \\    token: Token;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\const outer: Outer = Outer { inner: Inner { token: .number(42) } };
        \\
        \\fn main(): i32 {
        \\    return outer.inner.token.number;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_top_level_nested_struct_global_union_projection.cy", source, 42);
}

test "native top-level nested struct globals support indexed union payload projection" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    eof;
        \\}
        \\
        \\struct Inner {
        \\    tokens: [2]Token;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\const outer: Outer = Outer { inner: Inner { tokens: [.eof(), .number(42)] } };
        \\
        \\fn main(): i32 {
        \\    return outer.inner.tokens[1].number;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_top_level_nested_struct_global_indexed_union_projection.cy", source, 42);
}

test "native top-level fixed-array globals support indexed reads" {
    const source =
        \\const values: [3]i32 = [10, 20, 12];
        \\
        \\fn main(): i32 {
        \\    return values[0] + values[1] + values[2];
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_top_level_fixed_array_global_index.cy", source, 42);
}

test "native top-level fixed-array globals support empty contextual initialization" {
    const source =
        \\const values: [3]i32 = [];
        \\
        \\fn main(): i32 {
        \\    if values[0] != 0 {
        \\        return 1;
        \\    }
        \\    if values[1] != 0 {
        \\        return 2;
        \\    }
        \\    if values[2] != 0 {
        \\        return 3;
        \\    }
        \\    return 42;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_top_level_empty_fixed_array_global.cy", source, 42);
}

test "native top-level array globals infer struct items and enum fields" {
    const source =
        \\enum Op: i32 {
        \\    add = 40,
        \\    done = 2,
        \\}
        \\
        \\struct Step {
        \\    op: Op;
        \\    amount: i32;
        \\}
        \\
        \\const steps: [2]Step = [{ op: .add, amount: 40 }, { op: .done, amount: 2 }];
        \\
        \\fn main(): i32 {
        \\    if steps[0].op != Op.add {
        \\        return 1;
        \\    }
        \\    if steps[1].op != Op.done {
        \\        return 2;
        \\    }
        \\    return steps[0].amount + steps[1].amount;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_top_level_array_global_contextual_items.cy", source, 42);
}

test "native top-level array globals support function pointer fields" {
    const source =
        \\struct Step {
        \\    run: fn(): i32;
        \\}
        \\
        \\type StepTable = [2]Step;
        \\
        \\fn forty(): i32 {
        \\    return 40;
        \\}
        \\
        \\fn two(): i32 {
        \\    return 2;
        \\}
        \\
        \\const steps: StepTable = [
        \\    { run: forty },
        \\    { run: two },
        \\];
        \\
        \\fn main(): i32 {
        \\    const first = steps[0].run;
        \\    const second = steps[1].run;
        \\    return first() + second();
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_top_level_array_global_function_pointer_fields.cy", source, 42);
}

test "native function expressions support contextual callback arguments" {
    const source =
        \\fn apply(value: i32, f: fn(i32): i32): i32 {
        \\    return f(value);
        \\}
        \\
        \\fn main(): i32 {
        \\    return apply(41, fn(x) {
        \\        return x + 1;
        \\    });
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_function_expr_contextual_callback.cy", source, 42);
}

test "native function expressions support explicit local function pointer values" {
    const source =
        \\fn main(): i32 {
        \\    const add_one = fn(x: i32): i32 {
        \\        return x + 1;
        \\    };
        \\    return add_one(41);
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_function_expr_explicit_local.cy", source, 42);
}

test "native function expressions support generic struct method callbacks" {
    const source =
        \\struct Box<T> {
        \\    value: T;
        \\
        \\    fn apply(self: Box<T>, f: fn(T): T): T {
        \\        return f(self.value);
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const box = Box<i32> { value: 41 };
        \\    return box.apply(fn(value) {
        \\        return value + 1;
        \\    });
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_function_expr_generic_struct_method_callback.cy", source, 42);
}

test "native lambda expressions support contextual callback arguments" {
    const source =
        \\fn apply(value: i32, f: fn(i32): i32): i32 {
        \\    return f(value);
        \\}
        \\
        \\fn main(): i32 {
        \\    return apply(41, |x| {
        \\        return x + 1;
        \\    });
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_lambda_expr_contextual_callback.cy", source, 42);
}

test "native non-escaping callable parameters support noncapturing lambda arguments" {
    const source =
        \\fn apply(value: i32, f: (i32) => i32): i32 {
        \\    return f(value);
        \\}
        \\
        \\fn main(): i32 {
        \\    return apply(41, |x| {
        \\        return x + 1;
        \\    });
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_arrow_callable_lambda_callback.cy", source, 42);
}

test "native non-escaping callable parameters accept named functions" {
    const source =
        \\fn add_one(value: i32): i32 {
        \\    return value + 1;
        \\}
        \\
        \\fn apply(value: i32, f: (i32) => i32): i32 {
        \\    return f(value);
        \\}
        \\
        \\fn main(): i32 {
        \\    return apply(41, add_one);
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_arrow_callable_named_function_callback.cy", source, 42);
}

test "native non-escaping callable parameters capture local values" {
    const source =
        \\fn apply(value: i32, f: (i32) => i32): i32 {
        \\    return f(value);
        \\}
        \\
        \\fn main(): i32 {
        \\    const bias = 1;
        \\    return apply(41, |x| {
        \\        return x + bias;
        \\    });
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_arrow_callable_captured_lambda_callback.cy", source, 42);
}

test "native non-escaping callable parameters retain resource captures for the call" {
    const source =
        \\fn apply(value: i32, f: (i32) => i32): i32 {
        \\    return f(value);
        \\}
        \\
        \\fn main(): i32 {
        \\    const label = "Ada";
        \\    return apply(41, |value| {
        \\        if label == "Ada" {
        \\            return value + 1;
        \\        }
        \\        return 0;
        \\    });
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_arrow_callable_resource_capture.cy", source, 42);
}

test "native lambda expressions support noncapturing function pointer storage" {
    const source =
        \\fn main(): i32 {
        \\    const add_one: fn(i32): i32 = |x| {
        \\        return x + 1;
        \\    };
        \\    return add_one(41);
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_lambda_expr_function_pointer_storage.cy", source, 42);
}

test "native top-level struct globals support field reads" {
    const source =
        \\struct Pair {
        \\    left: i32;
        \\    right: i32;
        \\}
        \\
        \\const pair: Pair = Pair { left: 40, right: 2 };
        \\
        \\fn main(): i32 {
        \\    return pair.left + pair.right;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_top_level_struct_global_field.cy", source, 42);
}

test "native top-level optional globals support none initialization" {
    const source =
        \\const value: ?i32 = none;
        \\
        \\fn main(): i32 {
        \\    if value is none {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_top_level_optional_global_none.cy", source, 42);
}

test "native top-level struct globals support optional field initialization" {
    const source =
        \\struct Reference {
        \\    object_id: ?u64;
        \\}
        \\
        \\const null_ref: Reference = Reference { object_id: none };
        \\
        \\fn main(): i32 {
        \\    if null_ref.object_id is none {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_top_level_struct_global_optional_field.cy", source, 42);
}

test "native mutable top-level fixed-array globals support indexed mutation" {
    const source =
        \\var values: [3]i32 = [0, 20, 12];
        \\
        \\fn main(): i32 {
        \\    values[0] = 10;
        \\    return values[0] + values[1] + values[2];
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_top_level_fixed_array_global_mutation.cy", source, 42);
}

test "native mutable top-level struct globals support union field-then-index mutation" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    values: [3]i32;
        \\    tokens: [2]Token;
        \\}
        \\
        \\var holder: Holder = Holder { values: [0, 20, 12], tokens: [.eof(), .eof()] };
        \\
        \\fn main(): i32 {
        \\    holder.values[0] = 10;
        \\    holder.tokens[1] = .number(42);
        \\    if holder.values[0] + holder.values[1] + holder.values[2] != 42 {
        \\        return 1;
        \\    }
        \\    return holder.tokens[1].number;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_mutable_top_level_struct_global_union_mutation.cy", source, 42);
}

test "native imported public mutable globals support cross-file mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/math.cy", .data =
        \\
        \\pub union Token {
        \\    number: i32;
        \\    eof;
        \\}
        \\
        \\pub struct Holder {
        \\    pub values: [3]i32;
        \\    pub tokens: [2]Token;
        \\}
        \\
        \\pub var values: [3]i32 = [0, 20, 12];
        \\pub var holder: Holder = Holder { values: [0, 20, 12], tokens: [.eof(), .eof()] };
        \\pub var holder_values: Holder = Holder { values: [0, 20, 12], tokens: [.eof(), .eof()] };
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { holder, holder_values, values } from lib.math;
        \\
        \\fn main(): i32 {
        \\    values[0] = 10;
        \\    holder.values[0] = 10;
        \\    holder.tokens[1] = .number(42);
        \\    holder_values.values[0] = 10;
        \\    if values[0] + values[1] + values[2] != 42 {
        \\        return 1;
        \\    }
        \\    if holder.tokens[1].number != 42 {
        \\        return 2;
        \\    }
        \\    if holder_values.values[0] + holder_values.values[1] + holder_values.values[2] != 42 {
        \\        return 3;
        \\    }
        \\    return 42;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "enum alias cases retain identity across imports and typed failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "errors.cy", .data =
        \\pub enum OriginalError { invalid = 7; }
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "api.cy", .data =
        \\import { OriginalError } from .errors;
        \\type LocalAlias = OriginalError;
        \\pub type PublicError = LocalAlias;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { OriginalError as Actual } from .errors;
        \\import { PublicError as ErrorAlias } from .api;
        \\enum OriginalError { invalid = 3; }
        \\fn fail(): i32!Actual { throw ErrorAlias.invalid, "expected"; }
        \\fn recover(code: Actual): i32 {
        \\    if code == ErrorAlias.invalid { return 42; }
        \\    return 1;
        \\}
        \\fn main(): i32 { return fail() catch (code) => recover(code); }
    });
    const path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(path);
    try helpers.expectNativeFileExitCode(std.testing.allocator, path, 42);
}

test "enum alias cases do not expose private imported aliases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "api.cy", .data =
        \\pub enum Status { ready; }
        \\type Hidden = Status;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { Hidden } from .api;
        \\fn main(): void { const value = Hidden.ready; }
    });
    const path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(path);
    try helpers.expectModuleSemanticFailed(std.testing.allocator, path);
}

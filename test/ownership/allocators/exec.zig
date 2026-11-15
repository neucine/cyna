const std = @import("std");

const helpers = @import("../../helpers.zig");

fn expectNamedNative(comptime name: []const u8, source: []const u8, expected: i64) !void {
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, name, "native_" ++ name ++ ".cy", source, expected);
}

test "allocator context blocks parse and run as a scoped statement" {
    const source =
        \\fn main(): i32 {
        \\    using alloc = 0 {
        \\        return 42;
        \\    }
        \\}
    ;

    try expectNamedNative("allocator_context_stmt", source, 42);
}

test "scoped allocator contexts allow local temporary use" {
    const source =
        \\fn main(): i32 {
        \\    using scoped alloc = 0 {
        \\        const xs: List<i32> = list<i32>();
        \\        if xs.len() == 0 {
        \\            return 42;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("scoped_allocator_local_use", source, 42);
}

test "scoped allocator raw pointer field mutation stays local to the block" {
    const source =
        \\struct Holder {
        \\    label: string;
        \\}
        \\
        \\fn main(): i32 {
        \\    using scoped alloc = 0 {
        \\        var holder = new Holder { label: "" };
        \\        unchecked {
        \\            (*holder.ptr()).label = "temporary";
        \\        }
        \\        return 42;
        \\    }
        \\}
    ;

    try expectNamedNative("scoped_allocator_raw_pointer_field_local", source, 42);
}

test "scoped allocator raw pointer rebind stays local to the block" {
    const source =
        \\struct Holder {
        \\    label: string;
        \\}
        \\
        \\fn main(): i32 {
        \\    using scoped alloc = 0 {
        \\        var holder = new Holder { label: "" };
        \\        const tmp = Holder { label: "temporary" };
        \\        unchecked {
        \\            *holder.ptr() = tmp;
        \\        }
        \\        return 42;
        \\    }
        \\}
    ;

    try expectNamedNative("scoped_allocator_raw_pointer_rebind_local", source, 42);
}

test "scoped allocator can return scalar field copied from scoped-owned storage" {
    const source =
        \\struct Holder {
        \\    label: string;
        \\    count: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    using scoped alloc = 0 {
        \\        const holder = Holder { label: "temporary", count: 42 };
        \\        return holder.count;
        \\    }
        \\}
    ;

    try expectNamedNative("scoped_allocator_return_scalar_projection", source, 42);
}

test "scoped allocator can pass scalar field copied from scoped-owned storage by value" {
    const source =
        \\struct Holder {
        \\    label: string;
        \\    count: i32;
        \\}
        \\
        \\fn add_one(value: i32): i32 {
        \\    return value + 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    using scoped alloc = 0 {
        \\        const holder = Holder { label: "temporary", count: 41 };
        \\        return add_one(holder.count);
        \\    }
        \\}
    ;

    try expectNamedNative("scoped_allocator_call_scalar_projection", source, 42);
}

test "scoped allocator can assign scalar field copied from scoped-owned storage outward" {
    const source =
        \\struct Holder {
        \\    label: string;
        \\    count: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var value: i32 = 0;
        \\    using scoped alloc = 0 {
        \\        const holder = Holder { label: "temporary", count: 42 };
        \\        value = holder.count;
        \\    }
        \\    return value;
        \\}
    ;

    try expectNamedNative("scoped_allocator_assign_scalar_projection", source, 42);
}

test "scoped allocator can push scalar field copied from scoped-owned storage into outer list" {
    const source =
        \\struct Holder {
        \\    label: string;
        \\    count: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var xs: List<i32> = list<i32>();
        \\    using scoped alloc = 0 {
        \\        const holder = Holder { label: "temporary", count: 42 };
        \\        xs.push(holder.count);
        \\    }
        \\    return xs[0];
        \\}
    ;

    try expectNamedNative("scoped_allocator_list_mutation_scalar_projection", source, 42);
}

test "allocator contexts work with nested container creation and copy" {
    const source =
        \\fn main(): i32 {
        \\    using alloc = 1 {
        \\        const xs: List<i32> = list<i32>();
        \\        using alloc = 2 {
        \\            const ys = xs.clone();
        \\            return ys.len() as i32;
        \\        }
        \\    }
        \\}
    ;

    try expectNamedNative("allocator_context_nested_copy", source, 0);
}

test "scoped allocator can return non-capturing union values" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    label: string;
        \\    eof;
        \\}
        \\
        \\fn build_number(): Token {
        \\    using scoped alloc = 0 {
        \\        const token: Token = .number(42);
        \\        return token;
        \\    }
        \\}
        \\
        \\fn build_eof(): Token {
        \\    using scoped alloc = 0 {
        \\        return .eof();
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const number = build_number();
        \\    const eof = build_eof();
        \\    if eof is .eof {
        \\        return number.number;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("scoped_allocator_return_non_capturing_union", source, 42);
}

test "scoped allocator can assign non-capturing union values outward" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    label: string;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    var token: Token = .eof();
        \\    using scoped alloc = 0 {
        \\        token = .number(42);
        \\    }
        \\    return token.number;
        \\}
    ;

    try expectNamedNative("scoped_allocator_assign_non_capturing_union", source, 42);
}

test "scoped allocator can return non-capturing optionals of resource-capable types" {
    const source =
        \\struct User {
        \\    label: string;
        \\}
        \\
        \\fn build(): ?User {
        \\    using scoped alloc = 0 {
        \\        return none;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const value = build();
        \\    if value is none {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("scoped_allocator_return_non_capturing_optional", source, 42);
}

test "scoped allocator can return non-capturing union projections from scoped-owned aggregates" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    label: string;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    label: string;
        \\    token: Token;
        \\}
        \\
        \\fn build(): Token {
        \\    using scoped alloc = 0 {
        \\        const holder = Holder { label: "temporary", token: .number(42) };
        \\        return holder.token;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return build().number;
        \\}
    ;

    try expectNamedNative("scoped_allocator_return_union_projection_from_aggregate", source, 42);
}

test "scoped allocator can return non-capturing indexed union projections from scoped-owned aggregates" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    label: string;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    labels: List<string>;
        \\    tokens: [2]Token;
        \\}
        \\
        \\fn build(): Token {
        \\    using scoped alloc = 0 {
        \\        const holder = Holder { labels: list<string>(), tokens: [.eof(), .number(42)] };
        \\        return holder.tokens[1];
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return build().number;
        \\}
    ;

    try expectNamedNative("scoped_allocator_return_indexed_union_projection_from_aggregate", source, 42);
}

test "scoped allocator can return non-capturing indexed empty union projections from scoped-owned aggregates" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    label: string;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    labels: List<string>;
        \\    tokens: [2]Token;
        \\}
        \\
        \\fn build(): Token {
        \\    using scoped alloc = 0 {
        \\        const holder = Holder { labels: list<string>(), tokens: [.number(1), .eof()] };
        \\        return holder.tokens[1];
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    if build() is .eof {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("scoped_allocator_return_indexed_empty_union_projection_from_aggregate", source, 42);
}

test "scoped allocator can pass non-capturing indexed union projections by value" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    label: string;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    labels: List<string>;
        \\    tokens: [2]Token;
        \\}
        \\
        \\fn score(token: Token): i32 {
        \\    return token.number;
        \\}
        \\
        \\fn main(): i32 {
        \\    using scoped alloc = 0 {
        \\        const holder = Holder { labels: list<string>(), tokens: [.eof(), .number(42)] };
        \\        return score(holder.tokens[1]);
        \\    }
        \\}
    ;

    try expectNamedNative("scoped_allocator_call_indexed_union_projection", source, 42);
}

test "scoped allocator can assign non-capturing indexed union projections outward" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    label: string;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    labels: List<string>;
        \\    tokens: [2]Token;
        \\}
        \\
        \\fn main(): i32 {
        \\    var token: Token = .eof();
        \\    using scoped alloc = 0 {
        \\        const holder = Holder { labels: list<string>(), tokens: [.eof(), .number(42)] };
        \\        token = holder.tokens[1];
        \\    }
        \\    return token.number;
        \\}
    ;

    try expectNamedNative("scoped_allocator_assign_indexed_union_projection", source, 42);
}

test "scoped allocator can return nested field-index union projections from scoped-owned aggregates" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    label: string;
        \\    eof;
        \\}
        \\
        \\struct Inner {
        \\    tokens: [2]Token;
        \\}
        \\
        \\struct Outer {
        \\    labels: List<string>;
        \\    inner: Inner;
        \\}
        \\
        \\fn build(): Token {
        \\    using scoped alloc = 0 {
        \\        const outer = Outer { labels: list<string>(), inner: Inner { tokens: [.eof(), .number(42)] } };
        \\        return outer.inner.tokens[1];
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return build().number;
        \\}
    ;

    try expectNamedNative("scoped_allocator_return_nested_union_projection", source, 42);
}

test "scoped allocator can pass nested field-index union projections by value" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    label: string;
        \\    eof;
        \\}
        \\
        \\struct Inner {
        \\    tokens: [2]Token;
        \\}
        \\
        \\struct Outer {
        \\    labels: List<string>;
        \\    inner: Inner;
        \\}
        \\
        \\fn score(token: Token): i32 {
        \\    return token.number;
        \\}
        \\
        \\fn main(): i32 {
        \\    using scoped alloc = 0 {
        \\        const outer = Outer { labels: list<string>(), inner: Inner { tokens: [.eof(), .number(42)] } };
        \\        return score(outer.inner.tokens[1]);
        \\    }
        \\}
    ;

    try expectNamedNative("scoped_allocator_call_nested_union_projection", source, 42);
}

test "scoped allocator can assign nested field-index union projections outward" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    label: string;
        \\    eof;
        \\}
        \\
        \\struct Inner {
        \\    tokens: [2]Token;
        \\}
        \\
        \\struct Outer {
        \\    labels: List<string>;
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): i32 {
        \\    var token: Token = .eof();
        \\    using scoped alloc = 0 {
        \\        const outer = Outer { labels: list<string>(), inner: Inner { tokens: [.eof(), .number(42)] } };
        \\        token = outer.inner.tokens[1];
        \\    }
        \\    return token.number;
        \\}
    ;

    try expectNamedNative("scoped_allocator_assign_nested_union_projection", source, 42);
}

test "scoped allocator can return helper-built nested field-index union projections" {
    const source =
        \\union Token {
        \\    number: i32;
        \\    label: string;
        \\    eof;
        \\}
        \\
        \\struct Inner {
        \\    tokens: [2]Token;
        \\}
        \\
        \\struct Outer {
        \\    labels: List<string>;
        \\    inner: Inner;
        \\}
        \\
        \\fn make_outer(): Outer {
        \\    return Outer { labels: list<string>(), inner: Inner { tokens: [.eof(), .number(42)] } };
        \\}
        \\
        \\fn build(): Token {
        \\    using scoped alloc = 0 {
        \\        const outer = make_outer();
        \\        return outer.inner.tokens[1];
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return build().number;
        \\}
    ;

    try expectNamedNative("scoped_allocator_return_helper_nested_union_projection", source, 42);
}

test "scoped allocator raw pointer field mutation is allowed under unchecked" {
    const source =
        \\struct Holder {
        \\    label: string;
        \\}
        \\
        \\fn main(): i32 {
        \\    using scoped alloc = 0 {
        \\        var holder = new Holder { label: "" };
        \\        const ptr: *Holder = holder.ptr();
        \\        unchecked {
        \\            (*ptr).label = "temporary";
        \\        }
        \\        return 42;
        \\    }
        \\}
    ;

    try expectNamedNative("scoped_allocator_raw_pointer_field_local", source, 42);
}

test "scoped allocator raw pointer helper passthrough is allowed" {
    const source =
        \\struct Holder {
        \\    label: string;
        \\}
        \\
        \\fn id(ptr: *Holder): *Holder {
        \\    return ptr;
        \\}
        \\
        \\fn main(): i32 {
        \\    using scoped alloc = 0 {
        \\        var holder = new Holder { label: "" };
        \\        const ptr: *Holder = id(holder.ptr());
        \\        unchecked {
        \\            (*ptr).label = "temporary";
        \\        }
        \\        return 42;
        \\    }
        \\}
    ;

    try expectNamedNative("scoped_allocator_raw_pointer_helper_passthrough", source, 42);
}

test "scoped allocator outer raw pointer mutation is allowed under unchecked" {
    const source =
        \\struct Holder {
        \\    label: string;
        \\}
        \\
        \\fn main(): i32 {
        \\    var outer = new Holder { label: "" };
        \\    const ptr: *Holder = outer.ptr();
        \\    using scoped alloc = 0 {
        \\        unchecked {
        \\            (*ptr).label = "temporary";
        \\        }
        \\        return 42;
        \\    }
        \\}
    ;

    try expectNamedNative("scoped_allocator_outer_raw_pointer_mutation", source, 42);
}

test "scoped allocator raw pointer local rebinding is allowed" {
    const source =
        \\struct Holder {
        \\    label: string;
        \\}
        \\
        \\fn main(): i32 {
        \\    using scoped alloc = 0 {
        \\        var holder = new Holder { label: "" };
        \\        var ptr: *Holder = holder.ptr();
        \\        const ptr2: *Holder = ptr;
        \\        ptr = ptr2;
        \\        unchecked {
        \\            (*ptr).label = "temporary";
        \\        }
        \\        return 42;
        \\    }
        \\}
    ;

    try expectNamedNative("scoped_allocator_raw_pointer_mutable_rebind", source, 42);
}

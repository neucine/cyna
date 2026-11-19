const std = @import("std");

const helpers = @import("../../helpers.zig");

fn expectNamedNative(comptime name: []const u8, source: []const u8, expected: i64) !void {
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, name, "native_" ++ name ++ ".cy", source, expected);
}

test "owned pointers support borrow and handoff" {
    const source =
        \\struct User {
        \\    age: i32;
        \\
        \\    fn read(self: ^User): i32 {
        \\        return self.age;
        \\    }
        \\}
        \\
        \\fn consume(user: ^User): i32 {
        \\    return user.read();
        \\}
        \\
        \\fn peek(user: &User): i32 {
        \\    return user.age;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = new User { age: 20 };
        \\    const seen = peek(user);
        \\    return seen + consume(user);
        \\}
    ;

    try expectNamedNative("owned_pointer", source, 40);
}

test "raw pointer types parse and type-check in declarations" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn keep(ptr: ?*User): ?*User {
        \\    return ptr;
        \\}
        \\
        \\fn main(): i32 {
        \\    const ptr: ?*User = none;
        \\    if keep(ptr) == none {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("raw_pointer_types", source, 42);
}

test "leaked owned pointers cross a function boundary and reconstruct for cleanup" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn make(): *User {
        \\    var user = new User { age: 42 };
        \\    return user.leak();
        \\}
        \\
        \\fn release(raw: *User): void {
        \\    var owner: ^User = resource.from_raw(raw);
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw = make();
        \\    var age: i32 = 0;
        \\    unchecked { age = (*raw).age; }
        \\    release(raw);
        \\    return age;
        \\}
    ;

    try expectNamedNative("leak_reconstruct_owned_pointer", source, 42);
}

test "namespace leak and reconstruct release nested owned storage" {
    const source =
        \\struct Holder {
        \\    values: List<i32>;
        \\}
        \\
        \\fn make(): *Holder {
        \\    var holder = new Holder { values: list_from<i32>([:]i32 [20, 22]) };
        \\    return resource.leak(holder);
        \\}
        \\
        \\fn release(raw: *Holder): void {
        \\    var holder: ^Holder = resource.from_raw(raw);
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw = make();
        \\    var value: i32 = 0;
        \\    unchecked { value = (*raw).values[0] + (*raw).values[1]; }
        \\    release(raw);
        \\    return value;
        \\}
    ;

    try expectNamedNative("resource_leak_reconstruct_nested", source, 42);
}

test "resource reconstruction requires a non-optional raw pointer" {
    const non_raw =
        \\fn reconstruct(value: i32): void {
        \\    var owner: ^i32 = resource.from_raw(value);
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "resource_from_raw_non_raw",
        non_raw,
        "resource.from_raw expects a non-optional `*T` raw pointer",
    );

    const optional_raw =
        \\struct User { age: i32; }
        \\fn reconstruct(raw: ?*User): void {
        \\    var owner: ^User = resource.from_raw(raw);
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "resource_from_raw_optional_raw",
        optional_raw,
        "resource.from_raw expects a non-optional `*T` raw pointer",
    );
}

test "resource reconstruction rejects callable pointees" {
    const source =
        \\fn reconstruct(raw: *fn(): void): void {
        \\    var owner = resource.from_raw(raw);
        \\}
        \\fn main(): i32 { return 0; }
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "resource_from_raw_callable",
        source,
        "resource.from_raw cannot reconstruct a callable value",
    );
}

test "resource reconstruction must initialize an owning local" {
    const source =
        \\struct User { age: i32; }
        \\fn make(): *User {
        \\    var user = new User { age: 42 };
        \\    return user.leak();
        \\}
        \\fn adopt(raw: *User): ^User {
        \\    return resource.from_raw(raw);
        \\}
        \\fn main(): i32 { return 0; }
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "resource_from_raw_non_local",
        source,
        "resource.from_raw must directly initialize an owning local",
    );
}

test "resource reconstruction consumes the raw binding" {
    const source =
        \\struct User { age: i32; }
        \\fn release(raw: *User): void {
        \\    var first: ^User = resource.from_raw(raw);
        \\    var second: ^User = resource.from_raw(raw);
        \\}
        \\fn main(): i32 { return 0; }
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "resource_from_raw_consumes_raw",
        source,
        "local `raw` was handed off or dropped",
    );
}

test "volatile raw pointer types parse and type-check in declarations" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn keep(ptr: ?*volatile User): ?*volatile User {
        \\    return ptr;
        \\}
        \\
        \\fn main(): i32 {
        \\    const ptr: ?*volatile User = none;
        \\    if keep(ptr) == none {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("volatile_raw_pointer_types", source, 42);
}

test "raw pointers can be dereferenced inside unchecked" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = new User { age: 42 };
        \\    const ptr: *User = user.ptr();
        \\    unchecked {
        \\        return (*ptr).age;
        \\    }
        \\}
    ;

    try expectNamedNative("raw_pointer_deref", source, 42);
}

test "raw pointer addition advances by pointee elements" {
    const source =
        \\extern {
        \\    c("malloc") fn malloc(size: c_size_t): *c_void;
        \\    c("free") fn free(ptr: *c_void): void;
        \\}
        \\
        \\fn main(): i32 {
        \\    unchecked {
        \\        const ptr = malloc(8 as c_size_t) as! *i32;
        \\        *ptr = 1;
        \\        *(ptr + 1) = 42;
        \\        const value = *(ptr + 1);
        \\        free(ptr as! *c_void);
        \\        return value;
        \\    }
        \\}
    ;

    try expectNamedNative("raw_pointer_element_offset", source, 42);
}

test "raw pointer addition requires unchecked" {
    const source =
        \\fn next(ptr: *i32): *i32 {
        \\    return ptr + 1;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "raw_pointer_offset_requires_unchecked", source, "raw pointer arithmetic requires `unchecked`");
}

test "const C float pointer addition keeps its pointee type" {
    const source =
        \\fn sample(ptr: *const c_float): c_float {
        \\    unchecked { return *(ptr + 1); }
        \\}
        \\fn main(): i32 { return 0; }
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "const_c_float_pointer_offset", source);
}

test "void raw pointer addition has no element stride" {
    const source =
        \\fn next(ptr: *c_void): *c_void {
        \\    unchecked { return ptr + 1; }
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "void_raw_pointer_offset", source, "raw pointer arithmetic requires a sized pointee");
}

test "raw pointer deref field can feed borrowed projection hook" {
    const source =
        \\struct Bag {
        \\    pub items: List<i32>;
        \\}
        \\
        \\fn sum(values: []const i32): i32 {
        \\    return values[0] + values[1];
        \\}
        \\
        \\fn main(): i32 {
        \\    var bag = new Bag { items: list_from<i32>([:]i32 [20, 22]) };
        \\    const ptr: *Bag = bag.ptr();
        \\    unchecked {
        \\        return sum((*ptr).items.view());
        \\    }
        \\}
    ;

    try expectNamedNative("raw_pointer_deref_field_borrowed_projection", source, 42);
}

test "volatile raw pointers can be dereferenced inside unchecked" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn read(ptr: *volatile User): i32 {
        \\    unchecked {
        \\        return (*ptr).age;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return 42;
        \\}
    ;

    try expectNamedNative("volatile_raw_pointer_deref", source, 42);
}

test "volatile packed struct field writes are allowed" {
    const source =
        \\packed struct Status {
        \\    ready: u1;
        \\}
        \\
        \\fn poke(ptr: *volatile Status): void {
        \\    unchecked {
        \\        (*ptr).ready = 1;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "volatile_packed_field_write_allowed", source);
}

test "integer can reinterpret as volatile raw pointer" {
    const source =
        \\struct UartRegs {
        \\    dr: u32;
        \\}
        \\
        \\fn uart0(): *volatile UartRegs {
        \\    unchecked {
        \\        return 0x40001000 as! *volatile UartRegs;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "int_to_volatile_raw_pointer", source);
}

test "volatile packed struct field reads are allowed" {
    const source =
        \\packed struct Status {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn read_error(ptr: *volatile Status): u8 {
        \\    unchecked {
        \\        return (*ptr).error as u8;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "volatile_packed_field_read_allowed", source);
}

test "volatile raw pointer can reinterpret back to integer" {
    const source =
        \\struct UartRegs {
        \\    dr: u32;
        \\}
        \\
        \\fn base(ptr: *volatile UartRegs): usize {
        \\    unchecked {
        \\        return ptr as! usize;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "volatile_raw_pointer_to_int", source);
}

test "raw pointer dereference requires unchecked" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = new User { age: 42 };
        \\    const ptr: *User = user.ptr();
        \\    return (*ptr).age;
        \\}
    ;

    try helpers.expectParseFailed(std.testing.allocator, "raw_pointer_deref_requires_unchecked", source);
}

test "raw pointers can be assigned inside unchecked" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = new User { age: 1 };
        \\    const ptr: *User = user.ptr();
        \\    unchecked {
        \\        *ptr = User { age: 42 };
        \\    }
        \\    return user.age;
        \\}
    ;

    try expectNamedNative("raw_pointer_assign", source, 42);
}

test "raw pointer assignment requires unchecked" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = new User { age: 1 };
        \\    const ptr: *User = user.ptr();
        \\    *ptr = User { age: 42 };
        \\    return user.age;
        \\}
    ;

    try helpers.expectParseFailed(std.testing.allocator, "raw_pointer_assign_requires_unchecked", source);
}

test "raw pointer fields can be assigned inside unchecked" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = new User { age: 1 };
        \\    const ptr: *User = user.ptr();
        \\    unchecked {
        \\        (*ptr).age = 42;
        \\    }
        \\    return user.age;
        \\}
    ;

    try expectNamedNative("raw_pointer_field_assign", source, 42);
}

test "raw pointer indexed fields can be assigned inside unchecked" {
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

    try expectNamedNative("raw_pointer_indexed_field_assign", source, 42);
}

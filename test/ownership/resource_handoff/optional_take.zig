const std = @import("std");

const helpers = @import("../../helpers.zig");

fn expectNamedNative(comptime name: []const u8, source: []const u8, expected: i64) !void {
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, name, "native_" ++ name ++ ".cy", source, expected);
}

test "Array optional index binding detaches slot to none" {
    const source =
        \\fn main(): i32 {
        \\    var slots = [:]?i32 [none, none];
        \\    slots[0] = 42;
        \\    const value = take slots[0];
        \\    if value is n {
        \\        if slots[0] is none {
        \\            return n;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "array_optional_take_index", "native_array_optional_take_index.cy", source, 42);
}

test "Array optional resource index binding detaches slot to none" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var slots = [:]?User [none];
        \\    slots[0] = User { age: 42, scores: list<i32>() };
        \\    const user = take slots[0];
        \\    if user is value {
        \\        if slots[0] is none {
        \\            return value.age;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "array_optional_resource_take_index", "native_array_optional_resource_take_index.cy", source, 42);
}

test "Array optional index detaches through ref parameter" {
    const source =
        \\fn pull(slots: &[:]?i32): ?i32 {
        \\    return take slots[0];
        \\}
        \\
        \\fn main(): i32 {
        \\    var slots = [:]?i32 [none];
        \\    slots[0] = 42;
        \\    const value = pull(&slots);
        \\    if value is n {
        \\        if slots[0] is none {
        \\            return n;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "array_optional_take_ref_param", "native_array_optional_take_ref_param.cy", source, 42);
}

test "local struct field Array optional index detaches slot to none" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\struct State {
        \\    slots: [:]?User;
        \\}
        \\
        \\fn main(): i32 {
        \\    var state = State { slots: [:]?User [none] };
        \\    state.slots[0] = User { age: 42, scores: list<i32>() };
        \\    const user = take state.slots[0];
        \\    if user is value {
        \\        if state.slots[0] is none {
        \\            return value.age;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "struct_field_array_optional_take_index", "native_struct_field_array_optional_take_index.cy", source, 42);
}

test "nested local struct field Array optional index detaches slot to none" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\struct State {
        \\    slots: [:]?User;
        \\}
        \\
        \\struct Wrapper {
        \\    state: State;
        \\}
        \\
        \\fn main(): i32 {
        \\    var wrapper = Wrapper { state: State { slots: [:]?User [none] } };
        \\    wrapper.state.slots[0] = User { age: 42, scores: list<i32>() };
        \\    const user = take wrapper.state.slots[0];
        \\    if user is value {
        \\        if wrapper.state.slots[0] is none {
        \\            return value.age;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "nested_struct_field_array_optional_take_index", "native_nested_struct_field_array_optional_take_index.cy", source, 42);
}

test "indexed then field path Array optional index detaches slot to none" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\struct State {
        \\    slots: [:]?User;
        \\}
        \\
        \\struct Wrapper {
        \\    state: State;
        \\}
        \\
        \\fn main(): i32 {
        \\    var wrappers: [1]Wrapper = [1]Wrapper [
        \\        Wrapper { state: State { slots: [:]?User [none] } }
        \\    ];
        \\    wrappers[0].state.slots[0] = User { age: 42, scores: list<i32>() };
        \\    const user = take wrappers[0].state.slots[0];
        \\    if user is value {
        \\        if wrappers[0].state.slots[0] is none {
        \\            return value.age;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "indexed_field_struct_array_optional_take_index", "native_indexed_field_struct_array_optional_take_index.cy", source, 42);
}

test "optional local take clears binding to none" {
    const source =
        \\fn main(): i32 {
        \\    var value: ?i32 = 42;
        \\    const taken = take value;
        \\    if taken is n {
        \\        if value is none {
        \\            return n;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("optional_local_take", source, 42);
}

test "optional field take clears field to none" {
    const source =
        \\struct Profile {
        \\    age: i32;
        \\}
        \\
        \\struct User {
        \\    profile: ?Profile;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { profile: Profile { age: 42 } };
        \\    const taken = take user.profile;
        \\    if taken is profile {
        \\        if user.profile is none {
        \\            return profile.age;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("optional_field_take", source, 42);
}

test "read from Array optional index does not detach slot" {
    const source =
        \\fn main(): i32 {
        \\    var slots = [:]?i32 [none];
        \\    slots[0] = 42;
        \\    if slots[0] is first {
        \\        if slots[0] is second {
        \\            return first + second;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("array_optional_read_index", source, 84);
}

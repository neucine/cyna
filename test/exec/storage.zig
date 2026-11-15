const std = @import("std");
const helpers = @import("../helpers.zig");

test "discard binding evaluates values and drops owned results" {
    const source =
        \\fn main(): i32 {
        \\    var values: List<i32> = list<i32>();
        \\    values.push(7);
        \\    const _ = values;
        \\    const _ = list<i32>();
        \\    const _ = 40;
        \\    const _ = 41;
        \\    return 42;
        \\}
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "discard_binding", "native_discard_binding.cy", source, 42);
}

test "native language failures report assertion bounds and capacity" {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    try helpers.test_exec.expectNativeSourceFailureMessage(allocator, "native_assertion_diagnostic.cy",
        \\fn main(): i32 { assert(false); return 0; }
    , "cyna assertion failed");
    try helpers.test_exec.expectNativeSourceFailureMessage(allocator, "native_bounds_diagnostic.cy",
        \\fn main(): i32 {
        \\    var rows: [:]i32 = [1, 2];
        \\    rows[5] = 4;
        \\    return 0;
        \\}
    , "cyna index out of bounds: index=5 length=2");
    try helpers.test_exec.expectNativeSourceFailureMessage(allocator, "native_capacity_diagnostic.cy",
        \\fn main(): i32 {
        \\    var cap: i32 = -1;
        \\    var slots = [; cap]i32;
        \\    return slots.len() as i32;
        \\}
    , "cyna capacity check failed: requested=-1 capacity=0");
}

test "dense push grows past literal capacity" {
    const source =
        \\fn main(): i32 {
        \\    var rows: [:]i32 = [1, 2, 3, 4, 5];
        \\    rows.push(6);
        \\    rows.push(7);
        \\    rows.push(8);
        \\    rows.push(9);
        \\    if rows.len() != 9 { return 1; }
        \\    if rows[0] != 1 { return 2; }
        \\    if rows[8] != 9 { return 3; }
        \\    rows.push(10);
        \\    rows.push(11);
        \\    rows.push(12);
        \\    rows.push(13);
        \\    rows.push(14);
        \\    rows.push(15);
        \\    rows.push(16);
        \\    rows.push(rows[0]);
        \\    if rows.len() != 17 { return 4; }
        \\    if rows[16] != 1 { return 5; }
        \\    return 42;
        \\}
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "dense_push_grows_past_literal_capacity", "native_dense_push_grows_past_literal_capacity.cy", source, 42);
}

test "dense and sparse storage runtime behaviors work" {
    const source =
        \\struct State {
        \\    slots: [;]i32;
        \\}
        \\
        \\struct Wrapper {
        \\    state: State;
        \\}
        \\
        \\struct ResourceObject {
        \\    fields: List<i32>;
        \\}
        \\
        \\fn check_dense_capacity(): i32 {
        \\    var buf: [:]i32 = [: 16] [1, 2, 3];
        \\    const view = buf[..];
        \\    if view.len() != 3 {
        \\        return 1;
        \\    }
        \\    if buf[0] + buf[1] + buf[2] != 6 {
        \\        return 2;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn check_dynamic_dense(): i32 {
        \\    const cap = 8;
        \\    var buf = [: cap]i32;
        \\    if buf.len() != 0 {
        \\        return 1;
        \\    }
        \\    buf.push(40);
        \\    buf.push(2);
        \\    if buf[0] + buf[1] != 42 {
        \\        return 2;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn check_sparse_construction(): i32 {
        \\    var slots: [;]i32 = [; 128];
        \\    slots.clear();
        \\    if slots.len() != 0 {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn check_dynamic_sparse(): i32 {
        \\    const cap = 8;
        \\    var slots = [; cap]i32;
        \\    if slots.len() != 0 {
        \\        return 1;
        \\    }
        \\    slots[3] = 42;
        \\    if slots[3] is value {
        \\        if value != 42 {
        \\            return 2;
        \\        }
        \\        return 0;
        \\    }
        \\    return 3;
        \\}
        \\
        \\fn check_sparse_inline_literal(): i32 {
        \\    var slots: [;]i32 = [; 8] [1, none, 3];
        \\    if slots[0] is value {
        \\        if value != 1 {
        \\            return 1;
        \\        }
        \\    } else {
        \\        return 2;
        \\    }
        \\    if slots[1] is value {
        \\        const unexpected = value;
        \\        return unexpected;
        \\    }
        \\    if slots[2] is value {
        \\        if value != 3 {
        \\            return 3;
        \\        }
        \\    } else {
        \\        return 4;
        \\    }
        \\    if slots.len() != 2 {
        \\        return 5;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn check_sparse_keyed_literal(): i32 {
        \\    var slots: [;]i32 = [; 16] { 3: 40, 10: 2 };
        \\    if slots.len() != 2 {
        \\        return 1;
        \\    }
        \\    if slots[0] is value {
        \\        return value;
        \\    }
        \\    if slots[3] is a {
        \\        if slots[10] is b {
        \\            if a + b != 42 {
        \\                return 2;
        \\            }
        \\            return 0;
        \\        }
        \\    }
        \\    return 3;
        \\}
        \\
        \\fn check_sparse_mutation(): i32 {
        \\    var slots: [;]i32 = [; 8];
        \\    if slots.contains_index(3) {
        \\        return 1;
        \\    }
        \\    slots.insert(3, 42);
        \\    if not slots.contains_index(3) {
        \\        return 2;
        \\    }
        \\    if slots.len() != 1 {
        \\        return 3;
        \\    }
        \\    if slots[3] is value {
        \\        if value != 42 {
        \\            return 4;
        \\        }
        \\    } else {
        \\        return 5;
        \\    }
        \\    slots[3] = none;
        \\    if slots[3] is value {
        \\        const unexpected = value;
        \\        return unexpected;
        \\    }
        \\    slots[3] = 42;
        \\    if slots.take(3) is value {
        \\        if value != 42 {
        \\            return 6;
        \\        }
        \\    } else {
        \\        return 7;
        \\    }
        \\    if slots.contains_index(3) {
        \\        return 8;
        \\    }
        \\    if slots.len() != 0 {
        \\        return 9;
        \\    }
        \\    if take slots[3] is value {
        \\        return value;
        \\    }
        \\    if slots.take(3) is value {
        \\        return value;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn check_projected_sparse(): i32 {
        \\    var wrapper = Wrapper {
        \\        state: State { slots: [; 8] },
        \\    };
        \\    wrapper.state.slots[2] = 7;
        \\    if wrapper.state.slots[2] is value {
        \\        if value != 7 {
        \\            return 1;
        \\        }
        \\    } else {
        \\        return 2;
        \\    }
        \\    if take wrapper.state.slots[2] is value {
        \\        if value != 7 {
        \\            return 3;
        \\        }
        \\    } else {
        \\        return 4;
        \\    }
        \\    if wrapper.state.slots[2] is value {
        \\        return value;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn check_borrowed_sparse_resource(): i32 {
        \\    var slots = [; 4]ResourceObject;
        \\    var fields: List<i32> = list<i32>();
        \\    fields.push(41);
        \\    slots.insert(1, ResourceObject { fields: fields });
        \\    if &slots[1] is object {
        \\        if object.fields.len() != 1 {
        \\            return 1;
        \\        }
        \\    } else {
        \\        return 2;
        \\    }
        \\    if slots.contains_index(1) {
        \\        return 0;
        \\    }
        \\    return 3;
        \\}
        \\
        \\fn main(): i32 {
        \\    if check_dense_capacity() != 0 {
        \\        return 1;
        \\    }
        \\    if check_dynamic_dense() != 0 {
        \\        return 2;
        \\    }
        \\    if check_sparse_construction() != 0 {
        \\        return 3;
        \\    }
        \\    if check_dynamic_sparse() != 0 {
        \\        return 4;
        \\    }
        \\    if check_sparse_inline_literal() != 0 {
        \\        return 5;
        \\    }
        \\    if check_sparse_keyed_literal() != 0 {
        \\        return 6;
        \\    }
        \\    if check_sparse_mutation() != 0 {
        \\        return 7;
        \\    }
        \\    if check_projected_sparse() != 0 {
        \\        return 8;
        \\    }
        \\    if check_borrowed_sparse_resource() != 0 {
        \\        return 9;
        \\    }
        \\    return 42;
        \\}
        \\
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "storage_runtime_behaviors",
        "native_storage_runtime_behaviors.cy",
        source,
        42,
    );
}

test "sparse storage iteration and none checks work at runtime" {
    const source =
        \\fn check_for_optional_slots(): i32 {
        \\    var slots: [;]i32 = [; 4];
        \\    slots[1] = 7;
        \\    var seen_none = 0;
        \\    var seen_some = 0;
        \\    for slot in slots {
        \\        if slot is value {
        \\            if value != 7 {
        \\                return 1;
        \\            }
        \\            seen_some = seen_some + 1;
        \\        } else {
        \\            seen_none = seen_none + 1;
        \\        }
        \\    }
        \\    if seen_some != 1 {
        \\        return 2;
        \\    }
        \\    if seen_none != 3 {
        \\        return 3;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn check_indices(): i32 {
        \\    var slots: [;]i32 = [; 6];
        \\    slots[1] = 10;
        \\    slots[4] = 20;
        \\    var sum = 0;
        \\    var count = 0;
        \\    for idx in slots.indices() {
        \\        sum = sum + idx;
        \\        count = count + 1;
        \\    }
        \\    if count != 2 {
        \\        return 1;
        \\    }
        \\    if sum != 5 {
        \\        return 2;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn check_none_index(): i32 {
        \\    var slots: [;]i32 = [; 128];
        \\    if slots[0] is none {
        \\        return 0;
        \\    }
        \\    return 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    if check_for_optional_slots() != 0 {
        \\        return 1;
        \\    }
        \\    if check_indices() != 0 {
        \\        return 2;
        \\    }
        \\    if check_none_index() != 0 {
        \\        return 3;
        \\    }
        \\    return 42;
        \\}
        \\
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "sparse_storage_iteration_runtime",
        "native_sparse_storage_iteration_runtime.cy",
        source,
        42,
    );
}

test "slotmap stores values behind generational keys" {
    const source =
        \\fn main(): i32 {
        \\    var slots: SlotMap<i32> = slot_map<i32>();
        \\    slots.reserve(1);
        \\    const first = slots.insert(10);
        \\    if slots.len() != 1 {
        \\        return 1;
        \\    }
        \\    if slots.contains(first) {
        \\        if slots.slots[first.index] is value {
        \\            if value != 10 {
        \\                return 2;
        \\            }
        \\        } else {
        \\            return 3;
        \\        }
        \\    } else {
        \\        return 3;
        \\    }
        \\    if slots.remove(first) is removed {
        \\        if removed != 10 {
        \\            return 4;
        \\        }
        \\    } else {
        \\        return 5;
        \\    }
        \\    if slots.contains(first) {
        \\        return 6;
        \\    }
        \\    if slots.contains(first) {
        \\        return 7;
        \\    }
        \\
        \\    const second = slots.insert(32);
        \\    if second.index != first.index {
        \\        return 7;
        \\    }
        \\    if second.generation == first.generation {
        \\        return 8;
        \\    }
        \\    if slots.remove(first) is stale_removed {
        \\        return stale_removed;
        \\    }
        \\    if slots.contains(second) {
        \\        if slots.slots[second.index] is current {
        \\            return current + 10;
        \\        }
        \\    }
        \\    return 9;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "slotmap_generational_keys", "native_slotmap_generational_keys.cy", source, 42);
}

test "slotmap supports literal initialization and resource removal" {
    const source =
        \\struct User {
        \\    name: string;
        \\}
        \\
        \\fn main(): i32 {
        \\    var users: SlotMap<User> = slot_map<User>();
        \\    const ada = users.insert(User { name: "Ada" });
        \\    const ken = users.insert(User { name: "Ken" });
        \\    if users.len() != 2 {
        \\        return 1;
        \\    }
        \\    if users.remove(ada) is user {
        \\        if user.name.len() != 3 {
        \\            return 2;
        \\        }
        \\    } else {
        \\        return 3;
        \\    }
        \\    if users.contains(ada) {
        \\        return 4;
        \\    }
        \\    if users.remove(ken) is live {
        \\        return 39 + (live.name.len() as i32);
        \\    }
        \\    return 4;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "slotmap_resource_values", "native_slotmap_resource_values.cy", source, 42);
}

test "slotmap grows from zero capacity and rejects invalid keys" {
    const source =
        \\fn main(): i32 {
        \\    var slots: SlotMap<i32> = slot_map<i32>();
        \\    const a = slots.insert(10);
        \\    const b = slots.insert(20);
        \\    const c = slots.insert(12);
        \\    if slots.len() != 3 {
        \\        return 1;
        \\    }
        \\    if not slots.contains(a) {
        \\        return 5;
        \\    }
        \\    if not slots.contains(b) {
        \\        return 4;
        \\    }
        \\    if not slots.contains(c) {
        \\        return 3;
        \\    }
        \\    if slots.slots[a.index] is av {
        \\        if slots.slots[b.index] is bv {
        \\            if slots.slots[c.index] is cv {
        \\                if av + bv + cv != 42 {
        \\                    return 2;
        \\                }
        \\            }
        \\        }
        \\    }
        \\
        \\    const out_of_range = SlotMapKey { index: 99, generation: 0 };
        \\    if slots.contains(out_of_range) {
        \\        return 6;
        \\    }
        \\    if slots.contains(out_of_range) {
        \\        return 7;
        \\    }
        \\
        \\    const wrong_generation = SlotMapKey {
        \\        index: a.index,
        \\        generation: a.generation + 1
        \\    };
        \\    if slots.contains(wrong_generation) {
        \\        return 7;
        \\    }
        \\    if slots.remove(wrong_generation) is removed {
        \\        return removed;
        \\    }
        \\    return 42;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "slotmap_growth_and_invalid_keys", "native_slotmap_growth_and_invalid_keys.cy", source, 42);
}

test "slotmap clear drops entries and invalidates old keys" {
    const source =
        \\struct User {
        \\    name: string;
        \\}
        \\
        \\fn main(): i32 {
        \\    var users: SlotMap<User> = slot_map<User>();
        \\    users.reserve(2);
        \\    const ada = users.insert(User { name: "Ada" });
        \\    const ken = users.insert(User { name: "Ken" });
        \\    users.clear();
        \\    if users.len() != 0 {
        \\        return 1;
        \\    }
        \\    if users.contains(ada) {
        \\        return 2;
        \\    }
        \\    if users.contains(ken) {
        \\        return 3;
        \\    }
        \\    if users.remove(ada) is removed {
        \\        return removed.name.len() as i32;
        \\    }
        \\
        \\    const new_user = users.insert(User { name: "Jo" });
        \\    if new_user.index != ada.index {
        \\        return 3;
        \\    }
        \\    if new_user.generation == ada.generation {
        \\        return 4;
        \\    }
        \\    if users.remove(new_user) is live {
        \\        return 40 + (live.name.len() as i32);
        \\    }
        \\    return 5;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "slotmap_clear_invalidates_keys", "native_slotmap_clear_invalidates_keys.cy", source, 42);
}

test "slotmap sequence literals insert values" {
    const source =
        \\fn main(): i32 {
        \\    var slots: SlotMap<i32> = slot_map<i32>();
        \\    const first = slots.insert(10);
        \\    const second = slots.insert(20);
        \\    const third = slots.insert(12);
        \\    const ignored_first = first;
        \\    const ignored_second = second;
        \\    const ignored_third = third;
        \\    if slots.len() != 3 {
        \\        return 1;
        \\    }
        \\    const a = SlotMapKey { index: 0, generation: 0 };
        \\    const b = SlotMapKey { index: 1, generation: 0 };
        \\    const c = SlotMapKey { index: 2, generation: 0 };
        \\    if not slots.contains(a) {
        \\        return 0;
        \\    }
        \\    if not slots.contains(b) {
        \\        return 0;
        \\    }
        \\    if not slots.contains(c) {
        \\        return 0;
        \\    }
        \\    if slots.slots[a.index] is av {
        \\        if slots.slots[b.index] is bv {
        \\            if slots.slots[c.index] is cv {
        \\                return av + bv + cv;
        \\            }
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "slotmap_sequence_literal", "native_slotmap_sequence_literal.cy", source, 42);
}

test "sparse take moves resource payload into match capture" {
    const source =
        \\struct Resource {
        \\    values: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var slots: [;]Resource = [; 2];
        \\    slots.insert(0, Resource { values: list_from<i32>([:]i32 [40, 2]) });
        \\    if slots.take(0) is resource {
        \\        return resource.values[0] + resource.values[1];
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeSourceExitCode(std.testing.allocator, "native_sparse_take_resource_capture.cy", source, 42);
}

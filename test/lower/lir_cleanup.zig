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

test "LIR clears taken resource source before later optional cleanup check" {
    const source =
        \\struct Box {
        \\    values: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var value: ?Box = Box { values: list_from<i32>([:]i32 [1]) };
        \\    const taken = take value;
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_take_optional_resource_drop_once.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "make_none") != null);
    try std.testing.expect(std.mem.count(u8, text, "dense_drop") >= 2);
    const drop_at = std.mem.indexOf(u8, text, "dense_drop") orelse return error.TestUnexpectedResult;
    const ret_at = std.mem.lastIndexOf(u8, text, "return %") orelse return error.TestUnexpectedResult;
    try std.testing.expect(drop_at < ret_at);
}

test "LIR ownership trace records take and cleanup decisions" {
    const source =
        \\struct Box {
        \\    values: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var value: ?Box = Box { values: list_from<i32>([:]i32 [1]) };
        \\    const taken = take value;
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_trace_take_optional_resource.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "ownership:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "owner value") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "owner taken") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "take value: source cleared to none") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop taken at return (") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop value at return (") != null);
}

test "LIR drops sparse indexed optional capture source" {
    const source =
        \\fn main(): i32 {
        \\    var slots: [;]string = [; 1] ["Ada"];
        \\    if slots[0] is name {
        \\        if name == "Ada" {
        \\            return 42;
        \\        }
        \\    }
        \\    return 1;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_sparse_index_optional_capture_drop.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_get") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_payload") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_share_into(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_release_at(") != null);
}

test "LIR lowers explicit drop for resource locals" {
    const source =
        \\fn main(): i32 {
        \\    var values: List<i32> = list_from<i32>([:]i32 [42]);
        \\    drop values;
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_drop_list.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "dense_new") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_drop") != null);
}

test "LIR lowers explicit drop recursively through struct fields" {
    const source =
        \\struct Cache {
        \\    values: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var cache = Cache { values: list_from<i32>([:]i32 [1, 2]) };
        \\    drop cache;
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_drop_struct_resource.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "extract_field") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_drop") != null);
}

test "LIR lowers explicit drop recursively through union payloads" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    var token: Token = .user(User { age: 42, scores: list_from<i32>([:]i32 [1, 2]) });
        \\    drop token;
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_drop_union_resource.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "extract_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_payload") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_drop") != null);
}

test "LIR drops old fixed-array string element on indexed reassignment" {
    const source =
        \\fn main(): i32 {
        \\    var names: [2]string = ["Ada", "Ken"];
        \\    names[0] = "Lin";
        \\    if names[0] == "Lin" {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_string_fixed_array_index_reassign_drop.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "[2]string") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "index_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_share_into(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_release_at(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_copy(") == null);
}

test "LIR returns local string by sharing before local cleanup" {
    const source =
        \\fn label(): string {
        \\    const text = "Ada";
        \\    return text;
        \\}
        \\
        \\fn main(): i32 {
        \\    if label() == "Ada" {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_string_return_shares_before_cleanup.cy", source);
    defer std.testing.allocator.free(text);

    const share_at = std.mem.indexOf(u8, text, "call cyna_string_share_into(") orelse return error.TestUnexpectedResult;
    const release_at = std.mem.indexOfPos(u8, text, share_at, "call cyna_string_release_at(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(share_at < release_at);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop text at return") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_copy(") == null);
}

test "LIR cleans a call-local resource capture after the non-escaping call" {
    const source =
        \\fn apply(value: i32, callback: (i32) => i32): i32 {
        \\    return callback(value);
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_nonescaping_resource_capture_cleanup.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.count(u8, text, "call cyna_string_share_into(") >= 3);
    try std.testing.expect(std.mem.count(u8, text, "call cyna_string_release_at(") >= 3);
    try std.testing.expect(std.mem.indexOf(u8, text, "owner closure_env_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop closure_env_") != null);
}

test "LIR hands an optional resource payload to the caller without callee cleanup" {
    const source =
        \\fn build(): ?List<i32> {
        \\    const outgoing: List<i32> = list_from<i32>([:]i32 [42]);
        \\    return outgoing;
        \\}
        \\
        \\fn main(): i32 {
        \\    const maybe = build();
        \\    if maybe is received {
        \\        return received[0];
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_optional_resource_payload_escape.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "handoff outgoing: source cleanup suppressed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop outgoing at return") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_drop") != null);
}

test "LIR returns fixed-array strings through structural copy before cleanup" {
    const source =
        \\fn labels(): [2]string {
        \\    const ada = "Ada";
        \\    const names: [2]string = [ada, "Ken"];
        \\    return names;
        \\}
        \\
        \\fn main(): i32 {
        \\    const names = labels();
        \\    if names[0] == "Ada" {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_string_array_return_structural_copy.cy", source);
    defer std.testing.allocator.free(text);

    const copy_at = std.mem.indexOf(u8, text, "call cyna_copy_") orelse return error.TestUnexpectedResult;
    const release_at = std.mem.indexOfPos(u8, text, copy_at, "call cyna_string_release_at(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(copy_at < release_at);
    try std.testing.expect(std.mem.indexOf(u8, text, "type_desc [2]string") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop names at return") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_copy(") == null);
}

test "LIR lowers defer in reverse order before return" {
    const source =
        \\enum Status: i32 {
        \\    ok = 0,
        \\    failed,
        \\}
        \\
        \\fn mark(digit: i32): void {
        \\    const ignored = digit;
        \\    return;
        \\}
        \\
        \\fn ok_step(): void!Status {
        \\    return;
        \\}
        \\
        \\fn scope(): i32!Status {
        \\    defer mark(2);
        \\    defer mark(4);
        \\    try ok_step();
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_defer_order.cy", source);
    defer std.testing.allocator.free(text);

    const mark4 = std.mem.indexOf(u8, text, "call cyna_fn_");
    try std.testing.expect(mark4 != null);
    const second = std.mem.lastIndexOf(u8, text, "call cyna_fn_");
    try std.testing.expect(second != null);
    try std.testing.expect(mark4.? != second.?);
    try std.testing.expect(std.mem.indexOf(u8, text, "ownership:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "run_defers at return (") != null);
}

test "LIR emits successful fallthrough for void typed failure" {
    const source =
        \\enum Failure: i32 { missing = 0 }
        \\fn probe(value: i32): void!Failure {
        \\    if value < 0 { throw Failure.missing; }
        \\}
    ;
    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_void_result_fallthrough.cy", source);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_result ok") != null);
}

test "LIR drops old owned value before local reassignment" {
    const source =
        \\fn main(): i32 {
        \\    var values: List<i32> = list_from<i32>([:]i32 [1]);
        \\    values = values.clone();
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_assign_drop_list.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "_clone(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_drop") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ownership:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "rebind_drop values") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop values at return (") != null);
}

test "LIR drops old union payload before local reassignment" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    var token: Token = .user(User { age: 42, scores: list_from<i32>([:]i32 [1]) });
        \\    token = .eof();
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_assign_drop_union_resource.cy", source);
    defer std.testing.allocator.free(text);

    const store_at = std.mem.indexOf(u8, text, "store %") orelse return error.TestUnexpectedResult;
    const drop_at = std.mem.indexOf(u8, text, "dense_drop") orelse return error.TestUnexpectedResult;
    try std.testing.expect(store_at < drop_at);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "rebind_drop token") != null);
}

test "LIR drops old union-containing struct value before local reassignment" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    token: Token;
        \\}
        \\
        \\fn main(): i32 {
        \\    var holder = Holder { token: .user(User { age: 42, scores: list_from<i32>([:]i32 [1]) }) };
        \\    holder = Holder { token: .eof() };
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_assign_drop_struct_union_resource.cy", source);
    defer std.testing.allocator.free(text);

    const store_at = std.mem.indexOf(u8, text, "store %") orelse return error.TestUnexpectedResult;
    const drop_at = std.mem.indexOf(u8, text, "dense_drop") orelse return error.TestUnexpectedResult;
    try std.testing.expect(store_at < drop_at);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_field") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "rebind_drop holder") != null);
}

test "LIR auto-drops union-containing struct locals before return" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    token: Token;
        \\}
        \\
        \\fn main(): i32 {
        \\    var holder = Holder { token: .user(User { age: 42, scores: list_from<i32>([:]i32 [1]) }) };
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_auto_drop_struct_union_resource.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "dense_drop") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_field") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ownership:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop holder at return (") != null);
}

test "LIR auto-drops resource locals before return" {
    const source =
        \\fn main(): i32 {
        \\    var values: List<i32> = list_from<i32>([:]i32 [1]);
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_auto_drop_list.cy", source);
    defer std.testing.allocator.free(text);

    const drop_at = std.mem.indexOf(u8, text, "dense_drop") orelse return error.TestUnexpectedResult;
    const ret_at = std.mem.lastIndexOf(u8, text, "return %") orelse return error.TestUnexpectedResult;
    try std.testing.expect(drop_at < ret_at);
}

test "LIR auto-drops dense byte buffer after string.from return" {
    const source =
        \\fn descriptor(): string {
        \\    var bytes: [:]u8 = [76, 77, 59];
        \\    const out = string.from(bytes[..]);
        \\    return out;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_string_from_dense_auto_drop.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop out at return (") != null);
    const bytes_drop_trace = std.mem.indexOf(u8, text, "auto_drop bytes at return (") orelse return error.TestUnexpectedResult;
    const string_release_at = std.mem.indexOf(u8, text, "call cyna_string_release_at(") orelse return error.TestUnexpectedResult;
    const dense_drop_at = std.mem.indexOf(u8, text, "dense_drop") orelse return error.TestUnexpectedResult;
    const ret_at = std.mem.lastIndexOf(u8, text, "return %") orelse return error.TestUnexpectedResult;
    try std.testing.expect(bytes_drop_trace < dense_drop_at);
    try std.testing.expect(string_release_at < dense_drop_at);
    try std.testing.expect(dense_drop_at < ret_at);
}

test "LIR does not auto-drop handed off return values" {
    const source =
        \\fn build(): List<i32> {
        \\    var values: List<i32> = list_from<i32>([:]i32 [1]);
        \\    return values;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_handoff_return_list.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "ownership:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "handoff values: source cleanup suppressed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop values at return (") == null);
}

test "LIR does not auto-drop leaked owned pointers" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = new User { age: 42 };
        \\    const ptr = user.leak();
        \\    unchecked {
        \\        return (*ptr).age;
        \\    }
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_leak_owned_pointer.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "ownership:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "leak user: source cleanup suppressed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop user at scope_exit (") == null);
}

test "LIR does not auto-drop handed off union-containing struct return values" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    token: Token;
        \\}
        \\
        \\fn build(): Holder {
        \\    var holder = Holder { token: .user(User { age: 42, scores: list_from<i32>([:]i32 [1]) }) };
        \\    return holder;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_handoff_return_struct_union_resource.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "ownership:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "handoff holder: source cleanup suppressed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop holder at return (") == null);
}

test "LIR auto-drops loop-body resource locals at continue" {
    const source =
        \\fn main(): i32 {
        \\    var i = 0;
        \\    while i < 1 {
        \\        var values: List<i32> = list_from<i32>([:]i32 [1]);
        \\        i = i + 1;
        \\        continue;
        \\    }
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_continue_auto_drop_list.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "ownership:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop values at continue (") != null);
}

test "LIR runs defers before dropping union-containing struct resources at return" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    token: Token;
        \\}
        \\
        \\fn mark(digit: i32): void {
        \\    const ignored = digit;
        \\    return;
        \\}
        \\
        \\fn main(): i32 {
        \\    defer mark(7);
        \\    var holder = Holder { token: .user(User { age: 42, scores: list_from<i32>([:]i32 [1]) }) };
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_defer_before_drop_struct_union_return.cy", source);
    defer std.testing.allocator.free(text);

    const mark_at = std.mem.indexOf(u8, text, "call cyna_fn_") orelse return error.TestUnexpectedResult;
    const drop_at = std.mem.indexOf(u8, text, "dense_drop") orelse return error.TestUnexpectedResult;
    try std.testing.expect(mark_at < drop_at);
    try std.testing.expect(std.mem.indexOf(u8, text, "run_defers at return (") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop holder at return (") != null);
}

test "LIR runs defers before dropping union-containing struct resources at continue" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    token: Token;
        \\}
        \\
        \\fn mark(digit: i32): void {
        \\    const ignored = digit;
        \\    return;
        \\}
        \\
        \\fn main(): i32 {
        \\    var i = 0;
        \\    while i < 1 {
        \\        defer mark(7);
        \\        var holder = Holder { token: .user(User { age: 42, scores: list_from<i32>([:]i32 [1]) }) };
        \\        i = i + 1;
        \\        continue;
        \\    }
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_defer_before_drop_struct_union_continue.cy", source);
    defer std.testing.allocator.free(text);

    const mark_at = std.mem.indexOf(u8, text, "call cyna_fn_") orelse return error.TestUnexpectedResult;
    const drop_at = std.mem.indexOf(u8, text, "dense_drop") orelse return error.TestUnexpectedResult;
    try std.testing.expect(mark_at < drop_at);
    try std.testing.expect(std.mem.indexOf(u8, text, "run_defers at continue (") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop holder at continue (") != null);
}

test "LIR auto-drops branch-local union-containing struct resources at scope exit" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    token: Token;
        \\}
        \\
        \\fn main(): i32 {
        \\    if true {
        \\        var holder = Holder { token: .user(User { age: 42, scores: list_from<i32>([:]i32 [1]) }) };
        \\        const ignored = holder.token.user.age;
        \\    }
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_scope_exit_branch_struct_union_resource.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "dense_drop") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_field") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ownership:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop holder at scope_exit (") != null);
}

test "LIR auto-drops loop-body union-containing struct resources at scope exit" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\union Token {
        \\    user: User;
        \\    eof;
        \\}
        \\
        \\struct Holder {
        \\    token: Token;
        \\}
        \\
        \\fn main(): i32 {
        \\    var i = 0;
        \\    while i < 1 {
        \\        var holder = Holder { token: .user(User { age: 42, scores: list_from<i32>([:]i32 [1]) }) };
        \\        const ignored = holder.token.user.age;
        \\        i = i + 1;
        \\    }
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_scope_exit_loop_struct_union_resource.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "dense_drop") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_field") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ownership:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop holder at scope_exit (") != null);
}

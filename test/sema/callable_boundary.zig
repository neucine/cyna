const std = @import("std");
const helpers = @import("../helpers.zig");

test "non-escaping callable parameter type is accepted" {
    const source =
        \\fn apply(value: i32, f: (i32) => i32): i32 {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "arrow_callable_parameter_type_accepted", source);
}

test "non-escaping callable return type is rejected" {
    const source =
        \\fn make(): (i32) => i32 {
        \\    return fn(x) {
        \\        return x + 1;
        \\    };
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "arrow_callable_return_type_rejected",
        source,
        "use `fn(...)` for a non-capturing stored callback, or store explicit context beside the function pointer",
    );
}

test "non-escaping callable storage positions are rejected" {
    const source =
        \\fn main(): i32 {
        \\    const f: (i32) => i32 = 0;
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "arrow_callable_local_storage_rejected",
        source,
        "non-escaping callable values cannot be stored by `local binding` because their capture environment is call-local",
    );
}

test "non-escaping callable struct fields are rejected" {
    const source =
        \\struct CallbackBox {
        \\    call: (i32) => i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "arrow_callable_struct_field_rejected",
        source,
        "struct field",
    );
}

test "non-escaping callable aliases are rejected" {
    const source =
        \\type Callback = (i32) => i32;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "arrow_callable_alias_rejected",
        source,
        "type alias",
    );
}

test "non-escaping callable lambda captures local in synthetic environment" {
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

    try helpers.expectSemanticSuccess(
        std.testing.allocator,
        "arrow_callable_lambda_capture_environment",
        source,
    );
}

test "callable boundary slice diagnostic suggests pointer-plus-length wrapper" {
    const source =
        \\extern {
        \\    c fn bad(bytes: []const u8): c_int;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "callable_boundary_slice_diag",
        source,
        "explicit pointer-plus-length `c struct`",
    );
}

test "callable boundary ordinary struct diagnostic suggests cstruct or pointer" {
    const source =
        \\struct User {
        \\    id: i32;
        \\}
        \\
        \\extern {
        \\    c fn bad(user: User): c_int;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "callable_boundary_struct_diag",
        source,
        "use `c struct` or an explicit raw pointer",
    );
}

test "extern C rejects Cyna runtime carriers" {
    const source =
        \\extern c fn bad(text: string): c_int;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "extern_c_rejects_runtime_carrier",
        source,
        "`string` is a Cyna runtime type, not a C-layout ABI type",
    );
}

test "c_str is accepted as a borrowed C parameter" {
    const source =
        \\extern c fn inspect(text: c_str): c_int;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "c_str_parameter", source);
}

test "static string literals safely adapt to c_str parameters" {
    const source =
        \\extern c fn inspect(text: c_str): c_int;
        \\
        \\fn main(): i32 {
        \\    const ignored = inspect("hello");
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "c_str_static_literal_adaptation", source);
}

test "dynamic strings do not implicitly adapt to c_str" {
    const source =
        \\extern c fn inspect(text: c_str): c_int;
        \\
        \\fn main(): i32 {
        \\    const text = "hello";
        \\    const ignored = inspect(text);
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "c_str_dynamic_string_rejected",
        source,
        "expected c_str, got string",
    );
}

test "c_str cannot be returned" {
    const source =
        \\extern c fn borrowed_name(): c_str;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "c_str_return_rejected",
        source,
        "`c_str` cannot be returned because its borrow lifetime is not expressed",
    );
}

test "c_str cannot be made optional" {
    const source =
        \\extern c fn inspect(text: ?c_str): c_int;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "optional_c_str_rejected",
        source,
        "use `?*const c_char` for nullable C pointers",
    );
}

test "c_str cannot be stored in aggregates" {
    const source =
        \\c struct Bad {
        \\    text: c_str;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "c_str_field_rejected",
        source,
        "`c_str` is a borrowed C string view and cannot be stored in a struct",
    );
}

test "callable boundary container diagnostic suggests explicit boundary representation" {
    const source =
        \\extern {
        \\    c fn bad(items: List<i32>): c_int;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "callable_boundary_container_diag",
        source,
        "convert it to an explicit boundary representation",
    );
}

test "c struct string field diagnostic requires an explicit representation" {
    const source =
        \\c struct Bad {
        \\    name: string;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "cstruct_string_field_diag",
        source,
        "`c struct` field `name` cannot use `string`; adapt it to an explicit C representation",
    );
}

test "cstruct ordinary struct field diagnostic suggests nested cstruct" {
    const source =
        \\struct User {
        \\    id: i32;
        \\}
        \\
        \\c struct Bad {
        \\    user: User;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "cstruct_struct_field_diag",
        source,
        "use a nested `c struct` instead",
    );
}

test "cstruct borrowed reference field diagnostic keeps safe refs out of C layout" {
    const source =
        \\struct User {
        \\    id: i32;
        \\}
        \\
        \\c struct Bad {
        \\    user: &User;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "cstruct_ref_field_diag",
        source,
        "must use a C-layout ABI type",
    );
}

test "callable boundary c fn payload rejects Cyna runtime types with C-layout wording" {
    const source =
        \\extern {
        \\    c fn bad(cb: c fn(string): c_int): c_int;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "callable_boundary_c_fn_string_param_diag",
        source,
        "`string` is a Cyna runtime type, not a C-layout ABI type",
    );
}

test "callable boundary c fn rejects pointer modifier wrapping" {
    const source =
        \\extern {
        \\    c fn bad(cb: *c fn(c_int): c_int): c_int;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "callable_boundary_c_fn_pointer_wrapper_diag",
        source,
        "function pointer types cannot combine pointer or optional modifiers",
    );
}

test "function expression rejects local capture" {
    const source =
        \\fn apply(value: i32, f: fn(i32): i32): i32 {
        \\    return f(value);
        \\}
        \\
        \\fn main(): i32 {
        \\    const bias = 1;
        \\    return apply(41, fn(x) {
        \\        return x + bias;
        \\    });
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "function_expr_rejects_local_capture",
        source,
        "function expression cannot capture local `bias`",
    );
}

test "capturing lambda passed to function pointer explains the direct-callable alternative" {
    const source =
        \\fn apply(value: i32, f: fn(i32): i32): i32 {
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

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "lambda_expr_rejects_capture_for_function_pointer",
        source,
        "pass the lambda directly to a `(...) => R` parameter, or store explicit context beside the function pointer",
    );
}

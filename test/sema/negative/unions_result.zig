pub const negatives = [_]struct {
    name: []const u8,
    source: []const u8,
}{
    .{
        .name = "union_cast_requires_unique_payload_type",
        .source =
        \\union Value {
        \\    first: i32;
        \\    second: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    const value: Value = .first(42);
        \\    return value as i32;
        \\}
        ,
    },
    .{
        .name = "union_case_requires_expected_type",
        .source =
        \\union Token {
        \\    ident: string;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    const token = .ident("name");
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "union_switch_must_be_exhaustive",
        .source =
        \\union Token {
        \\    ident: string;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    const token: Token = .ident("name");
        \\    switch token {
        \\    .ident(name) => {
        \\        return name.len();
        \\    }
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "union_projection_requires_payload_case",
        .source =
        \\union Token {
        \\    ident: string;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    const token: Token = .eof;
        \\    const marker = token.eof;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "is_capture_is_only_allowed_in_if_conditions",
        .source =
        \\union Token {
        \\    ident: string;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    const token: Token = .ident("answer");
        \\    const ok = token is .ident(name);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "err_requires_enum_value",
        .source =
        \\enum Status: i32 {
        \\    ok = 0,
        \\    failed,
        \\}
        \\
        \\fn fail(): i32!Status {
        \\    throw 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "ok_requires_value",
        .source =
        \\enum Status: i32 {
        \\    ok = 0,
        \\    failed,
        \\}
        \\
        \\fn value(): i32!Status {
        \\    return;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "check_requires_result",
        .source =
        \\fn main(): i32 {
        \\    const value = try 1;
        \\    return value;
        \\}
        ,
    },
    .{
        .name = "result_error_type_must_be_enum",
        .source =
        \\fn fail(): i32!i32 {
        \\    return 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "result_error_union_member_must_be_enum",
        .source =
        \\enum Failure { bad; }
        \\union Invalid = Failure | i32;
        \\fn fail(): i32!Invalid { return 42; }
        \\fn main(): i32 { return 0; }
        ,
    },
};

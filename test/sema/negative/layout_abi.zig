pub const negatives = [_]struct {
    name: []const u8,
    source: []const u8,
}{
    .{
        .name = "packed_bitcast_requires_explicit_width_source",
        .source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn main(): i32 {
        \\    const reg = 53 as! StatusReg;
        \\    return reg.mode as i32;
        \\}
        ,
    },
    .{
        .name = "packed_bitcast_rejects_width_mismatch_int_to_packed",
        .source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: u16 = 53;
        \\    const reg = raw as! StatusReg;
        \\    return reg.mode as i32;
        \\}
        ,
    },
    .{
        .name = "packed_bitcast_rejects_width_mismatch_packed_to_int",
        .source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: u8 = 53 as u8;
        \\    const reg = raw as! StatusReg;
        \\    const wide = reg as! u16;
        \\    return wide as i32;
        \\}
        ,
    },
    .{
        .name = "packed_bitcast_rejects_normal_struct_target",
        .source =
        \\struct StatusReg {
        \\    raw: u8;
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: u8 = 53 as u8;
        \\    const reg = raw as! StatusReg;
        \\    return reg.raw as i32;
        \\}
        ,
    },
    .{
        .name = "c_abi_symbols_must_be_unique",
        .source =
        \\export c("puts") fn first_puts(text: c_str): c_int {
        \\    return 0;
        \\}
        \\
        \\export c("puts") fn second_puts(text: c_str): c_int {
        \\    return 0;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "comptime_rejects_ordinary_struct_layout_metadata",
        .source =
        \\struct User {
        \\    id: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    return comptime User.size as i32;
        \\}
        ,
    },
    .{
        .name = "packed_struct_cannot_contain_normal_struct_field",
        .source =
        \\struct Inner {
        \\    value: i32;
        \\}
        \\
        \\packed struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "packed_struct_cannot_contain_resource_field",
        .source =
        \\packed struct Header {
        \\    name: string;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "packed_struct_cannot_contain_bool_field",
        .source =
        \\packed struct Header {
        \\    ready: bool;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "packed_struct_cannot_contain_enum_without_explicit_repr",
        .source =
        \\enum Mode {
        \\    ready = 1,
        \\}
        \\
        \\packed struct Header {
        \\    mode: Mode;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "packed_struct_cannot_contain_raw_pointer_field",
        .source =
        \\packed struct Header {
        \\    data: *i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "packed_struct_cannot_contain_fixed_array_field",
        .source =
        \\packed struct Header {
        \\    bytes: [2]u8;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "packed_struct_cannot_contain_cstruct_field",
        .source =
        \\c struct Inner {
        \\    value: c_int;
        \\}
        \\
        \\packed struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "packed_struct_cannot_contain_cstruct_with_resource_field",
        .source =
        \\c struct Inner {
        \\    name: string;
        \\}
        \\
        \\packed struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "cstruct_cannot_contain_resource_field",
        .source =
        \\c struct Bad {
        \\    name: string;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "cstruct_cannot_contain_normal_struct_field",
        .source =
        \\struct Inner {
        \\    value: i32;
        \\}
        \\
        \\c struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "generic_cstruct_instantiation_cannot_contain_resource_field",
        .source =
        \\c struct Box<T> {
        \\    value: T;
        \\}
        \\
        \\fn main(): i32 {
        \\    const bad = Box<string> { value: "answer" };
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "generic_cstruct_instantiation_cannot_contain_normal_struct_field",
        .source =
        \\struct Inner {
        \\    value: i32;
        \\}
        \\
        \\c struct Box<T> {
        \\    value: T;
        \\}
        \\
        \\fn main(): i32 {
        \\    const bad = Box<Inner> { value: Inner { value: 42 } };
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "generic_packed_struct_instantiation_cannot_contain_resource_field",
        .source =
        \\packed struct Box<T> {
        \\    value: T;
        \\}
        \\
        \\fn main(): i32 {
        \\    const bad = Box<string> { value: "answer" };
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "generic_packed_struct_instantiation_cannot_contain_normal_struct_field",
        .source =
        \\struct Inner {
        \\    value: i32;
        \\}
        \\
        \\packed struct Box<T> {
        \\    value: T;
        \\}
        \\
        \\fn main(): i32 {
        \\    const bad = Box<Inner> { value: Inner { value: 42 } };
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "packed_struct_unusual_width_literal_must_fit",
        .source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn main(): i32 {
        \\    const reg = StatusReg { ready: 2, mode: 2, error: 3 };
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "c_abi_invalid_boundary_types_are_rejected",
        .source =
        \\extern {
        \\    c fn puts(text: string): i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "c_abi_extern_global_string_is_rejected",
        .source =
        \\extern {
        \\    c("program_name") var program_name: string;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "extern_c_calls_are_not_executable_in_interpreter",
        .source =
        \\extern {
        \\    c fn puts(text: c_str): c_int;
        \\}
        \\
        \\fn main(): i32 {
        \\    return puts("hi" as c_str);
        \\}
        ,
    },
};

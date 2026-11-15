pub const negatives = [_]struct {
    name: []const u8,
    source: []const u8,
}{
    .{
        .name = "distinct_types_do_not_mix_with_underlying",
        .source =
        \\type UserId = distinct i32;
        \\
        \\fn takes(id: UserId): i32 {
        \\    return 0;
        \\}
        \\
        \\fn main(): i32 {
        \\    return takes(1);
        \\}
        ,
    },
    .{
        .name = "distinct_alias_over_struct_not_supported_yet",
        .source =
        \\struct User {
        \\    id: i32;
        \\}
        \\
        \\type UserBox = distinct User;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "ambiguous_nested_struct_short_type_name",
        .source =
        \\struct Uart0 {
        \\    packed struct Txdata {
        \\        data: u8;
        \\    }
        \\}
        \\
        \\struct Uart1 {
        \\    packed struct Txdata {
        \\        data: u8;
        \\    }
        \\}
        \\
        \\struct Device {
        \\    txdata: Txdata;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "continue_is_only_valid_inside_loops",
        .source =
        \\fn main(): i32 {
        \\    continue;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "cenum_switch_requires_else",
        .source =
        \\c enum Status: i32 {
        \\    ok = 0,
        \\    failed = 1,
        \\}
        \\
        \\fn code(status: Status): i32 {
        \\    switch status {
        \\        Status.ok => {
        \\            return 42;
        \\        }
        \\        Status.failed => {
        \\            return 1;
        \\        }
        \\    }
        \\
        \\    return 0;
        \\}
        \\
        \\fn main(): i32 {
        \\    return code(Status.ok);
        \\}
        ,
    },
    .{
        .name = "top_level_global_initializer_cannot_call_functions",
        .source =
        \\fn init(): i32 {
        \\    return 42;
        \\}
        \\
        \\const answer: i32 = init();
        \\
        \\fn main(): i32 {
        \\    return answer;
        \\}
        ,
    },
    .{
        .name = "bitwise_ops_reject_plain_enums",
        .source =
        \\enum Mode: i32 {
        \\    read = 1,
        \\    write = 2,
        \\}
        \\
        \\fn main(): i32 {
        \\    const mode: Mode = Mode.read | Mode.write;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "non_integer_casts_not_supported_yet",
        .source =
        \\fn main(): i32 {
        \\    const value = "42" as i32;
        \\    return value;
        \\}
        ,
    },
    .{
        .name = "typed_integers_do_not_mix_implicitly",
        .source =
        \\fn main(): i32 {
        \\    const wide: i64 = 42;
        \\    const narrow: i32 = wide;
        \\    return narrow;
        \\}
        ,
    },
    .{
        .name = "in_requires_membership_rhs",
        .source =
        \\fn main(): i32 {
        \\    if 1 in 2 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "top_level_global_cannot_hold_resource_value",
        .source =
        \\const values: List<i32> = List<i32> {};
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "top_level_global_cannot_reference_later_global",
        .source =
        \\const answer: i32 = base + 2;
        \\const base: i32 = 40;
        \\
        \\fn main(): i32 {
        \\    return answer;
        \\}
        ,
    },
    .{
        .name = "top_level_integer_divisor_cannot_resolve_to_zero",
        .source =
        \\const zero: i64 = 0;
        \\const answer: i64 = 42 / zero;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "top_level_shift_count_must_fit_compiler_integer_range",
        .source =
        \\const width: i64 = 64;
        \\const answer: i64 = 1 << width;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "volatile_raw_pointer_cannot_replace_resource_value",
        .source =
        \\fn replace(ptr: *volatile List<i32>): void {
        \\    unchecked {
        \\        *ptr = [1, 2];
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "packed_struct_field_alias_rejected",
        .source =
        \\packed struct Header {
        \\    len: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var header = Header { len: 42 };
        \\    const ptr: &i32 = &header.len;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "map_entry_alias_rejected",
        .source =
        \\fn main(): i32 {
        \\    var values: Map<i32, i32> = map<i32, i32>();
        \\    const ptr: &i32 = &values[1];
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "alias_pointer_requires_mutable_local",
        .source =
        \\fn inc(x: &i32): void {
        \\    x = x + 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    const value: i32 = 1;
        \\    inc(&value);
        \\    return value;
        \\}
        ,
    },
    .{
        .name = "alias_pointer_argument_requires_amp",
        .source =
        \\fn inc(x: &i32): void {
        \\    x = x + 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    var value: i32 = 1;
        \\    inc(value);
        \\    return value;
        \\}
        ,
    },
    .{
        .name = "list_wrong_item_type",
        .source =
        \\fn main(): i32 {
        \\    var xs: List<i32> = list<i32>();
        \\    xs.push(true);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "list_literal_needs_expected_type",
        .source =
        \\fn main(): i32 {
        \\    var xs = [];
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "slice_wrong_item_type",
        .source =
        \\fn count(xs: []i32): i32 {
        \\    return xs.len();
        \\}
        \\
        \\fn main(): i32 {
        \\    const values: [2]bool = [true, false];
        \\    return count(values[..]);
        \\}
        ,
    },
    .{
        .name = "slice_requires_array_or_list",
        .source =
        \\fn main(): i32 {
        \\    const value: i32 = 1;
        \\    const view = value[..];
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "for_requires_iterable",
        .source =
        \\fn main(): i32 {
        \\    const value: i32 = 1;
        \\    for item in value {
        \\        return item;
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "for_map_not_defined_yet",
        .source =
        \\fn main(): i32 {
        \\    var scores: Map<string, i32> = map<string, i32>();
        \\    for item in scores {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "index_requires_integer",
        .source =
        \\fn main(): i32 {
        \\    const values: [2]i32 = [1, 2];
        \\    return values[true];
        \\}
        ,
    },
    .{
        .name = "index_requires_sequence",
        .source =
        \\fn main(): i32 {
        \\    const value: i32 = 1;
        \\    return value[0];
        \\}
        ,
    },
    .{
        .name = "index_assign_wrong_value_type",
        .source =
        \\fn main(): i32 {
        \\    var values: [2]i32 = [1, 2];
        \\    values[0] = true;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "index_assign_const_array",
        .source =
        \\fn main(): i32 {
        \\    const values: [2]i32 = [1, 2];
        \\    values[0] = 3;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "clone_rejects_arguments",
        .source =
        \\fn main(): i32 {
        \\    const value: i32 = 1;
        \\    const other = value.clone(1);
        \\    return other;
        \\}
        ,
    },
    .{
        .name = "map_wrong_key_type",
        .source =
        \\fn main(): i32 {
        \\    var scores: Map<string, i32> = map<string, i32>();
        \\    scores[1] = 2;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "map_wrong_value_type",
        .source =
        \\fn main(): i32 {
        \\    var scores: Map<string, i32> = map<string, i32>();
        \\    scores["Ada"] = true;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "map_clear_no_arguments",
        .source =
        \\fn main(): i32 {
        \\    var scores: Map<string, i32> = map<string, i32>();
        \\    scores.clear(1);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "map_keys_no_arguments",
        .source =
        \\fn main(): i32 {
        \\    var scores: Map<string, i32> = map<string, i32>();
        \\    return scores.keys(1).len();
        \\}
        ,
    },
    .{
        .name = "map_contains_wrong_key_type",
        .source =
        \\fn main(): i32 {
        \\    var scores: Map<string, i32> = map<string, i32>();
        \\    if scores.contains(1) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "const_map_rejects_index_assignment",
        .source =
        \\fn main(): i32 {
        \\    const scores: Map<string, i32> = map<string, i32>();
        \\    scores["Ada"] = 1;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "const_list_rejects_mutation",
        .source =
        \\fn main(): i32 {
        \\    const xs: List<i32> = list<i32>();
        \\    xs.push(1);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "set_wrong_item_type",
        .source =
        \\fn main(): i32 {
        \\    var names: Set<string> = {};
        \\    names.add(1);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "set_contains_wrong_item_type",
        .source =
        \\fn main(): i32 {
        \\    var names: Set<string> = {};
        \\    return names.contains(1);
        \\}
        ,
    },
    .{
        .name = "set_clear_no_arguments",
        .source =
        \\fn main(): i32 {
        \\    var names: Set<string> = {};
        \\    names.clear(1);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "const_set_rejects_mutation",
        .source =
        \\fn main(): i32 {
        \\    const names: Set<string> = {};
        \\    names.add("Ada");
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "unknown_string_method",
        .source =
        \\fn main(): i32 {
        \\    const text = "cyna";
        \\    text.push(1);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "list_reserve_requires_int",
        .source =
        \\fn main(): i32 {
        \\    var xs: List<i32> = list<i32>();
        \\    xs.reserve(true);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "list_clear_no_arguments",
        .source =
        \\fn main(): i32 {
        \\    var xs: List<i32> = list<i32>();
        \\    xs.clear(1);
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "list_pop_no_arguments",
        .source =
        \\fn main(): i32 {
        \\    var xs: List<i32> = list_from<i32>([:]i32 [1]);
        \\    return xs.pop(1);
        \\}
        ,
    },
    .{
        .name = "const_list_rejects_pop",
        .source =
        \\fn main(): i32 {
        \\    const xs: List<i32> = list_from<i32>([:]i32 [1]);
        \\    return xs.pop();
        \\}
        ,
    },
    .{
        .name = "non_void_defer",
        .source =
        \\fn value(): i32 {
        \\    return 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    defer value();
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "string_ordering",
        .source =
        \\fn main(): i32 {
        \\    if "a" < "b" {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        ,
    },
    .{
        .name = "bad_boolean_and",
        .source =
        \\fn main(): i32 {
        \\    if 1 and true {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        ,
    },
    .{
        .name = "duplicate_type_alias",
        .source =
        \\type Count = i32;
        \\type Count = i64;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "type_alias_cycle",
        .source =
        \\type A = B;
        \\type B = A;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "none_without_expected_type",
        .source =
        \\fn main(): i32 {
        \\    const value = none;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "none_compared_to_plain_value",
        .source =
        \\fn main(): i32 {
        \\    if none == 1 {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        ,
    },
    .{
        .name = "optional_void",
        .source =
        \\fn main(): i32 {
        \\    const value: ?void = none;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "array_wrong_length",
        .source =
        \\fn main(): i32 {
        \\    const values: [2]i32 = [1, 2, 3];
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "array_wrong_item_type",
        .source =
        \\fn main(): i32 {
        \\    const values: [2]i32 = [1, true];
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "array_literal_without_expected_type",
        .source =
        \\fn main(): i32 {
        \\    const values = [1, 2];
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "slice_items_cannot_be_void",
        .source =
        \\fn take(values: []void): i32 {
        \\    return 0;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "map_keys_cannot_be_list_values",
        .source =
        \\fn main(): i32 {
        \\    var scores: Map<List<i32>, i32> = map<List<i32>, i32>();
        \\    return scores.len();
        \\}
        ,
    },
    .{
        .name = "set_items_cannot_be_list_values",
        .source =
        \\fn main(): i32 {
        \\    var values: Set<List<i32>> = set<List<i32>>();
        \\    return values.len();
        \\}
        ,
    },
    .{
        .name = "integer_width_must_be_in_range",
        .source =
        \\fn main(): i32 {
        \\    const value: u65 = 1;
        \\    return value;
        \\}
        ,
    },
    .{
        .name = "Array_default_requires_defaultable_item",
        .source =
        \\struct User {
        \\    names: List<string>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var users: [2]User = [];
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "string_bytes_view_is_read_only",
        .source =
        \\fn main(): i32 {
        \\    var bytes = "cyna".bytes();
        \\    bytes[0] = 1;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "string_bytes_view_copy_binding_is_read_only",
        .source =
        \\fn main(): i32 {
        \\    const bytes = "cyna".bytes();
        \\    var alias = bytes;
        \\    alias[0] = 1;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "string_bytes_view_rebind_preserves_read_only",
        .source =
        \\fn main(): i32 {
        \\    var bytes: [:]u8 = "abc".bytes();
        \\    bytes = "def".bytes();
        \\    bytes[0] = 1;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "const_slice_annotation_is_read_only",
        .source =
        \\fn main(): i32 {
        \\    var bytes: []const u8 = "cyna".bytes();
        \\    bytes[0] = 1;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "const_slice_param_is_read_only",
        .source =
        \\fn mutate(bytes: []const u8): void {
        \\    bytes[0] = 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "const_view_hook_bound_view_is_read_only",
        .source =
        \\struct ReadOnlyInts {
        \\    storage: [:]i32;
        \\
        \\    pub fn view(self: &ReadOnlyInts): []const i32 {
        \\        return self.storage[..];
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var values = ReadOnlyInts { storage: [1, 2] };
        \\    var view = values.view();
        \\    view[0] = 42;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "const_view_hook_inline_view_is_read_only",
        .source =
        \\struct ReadOnlyInts {
        \\    storage: [:]i32;
        \\
        \\    pub fn view(self: &ReadOnlyInts): []const i32 {
        \\        return self.storage[..];
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var values = ReadOnlyInts { storage: [1, 2] };
        \\    values.view()[0] = 42;
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "string_bytes_view_cannot_escape_by_value_string_param",
        .source =
        \\fn leak(text: string): []const u8 {
        \\    return text.bytes();
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "map_keys_cannot_use_optional_shape",
        .source =
        \\fn main(): i32 {
        \\    var scores: Map<?i32, i32> = map<?i32, i32>();
        \\    return 0;
        \\}
        ,
    },
};

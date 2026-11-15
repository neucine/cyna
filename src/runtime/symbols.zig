const std = @import("std");

// Central runtime ABI spellings and layouts used by the compiler.
//
// We keep these names in one place so backend/support code can:
// - emit calls to the exact runtime-exported symbols
// - emit LLVM declarations for helpers whose signatures are compiler-known
// - detect when a LIR module depends on runtime support and must link it
pub const Id = enum {
    string_eq,
    sequence_eq,
    sparse_eq,
    string_starts_with,
    string_ends_with,
    string_contains,
    string_find,
    string_rfind,
    string_slice,
    string_from_bytes,
    string_copy,
    string_share,
    string_release,
    string_share_into,
    string_release_at,
    string_from_bytes_into,
    string_slice_into,
    string_find_into,
    string_rfind_into,
    fmt_empty_into,
    fmt_append_string_into,
    fmt_append_int_into,
    fmt_empty,
    fmt_append_string,
    fmt_append_int,
    assert_fail,
    assertion_fail,
    bounds_fail,
    capacity_fail,
    arc_retain,
    arc_release,
    tracked_alloc,
    tracked_alloc_site,
    tracked_free,
    install_root_allocator,
    clear_root_allocator,
    has_root_allocator,
    install_writer,
    clear_writer,
    writer_write,
    assert_no_leaks,
};

pub fn name(id: Id) []const u8 {
    return switch (id) {
        .string_eq => "cyna_string_eq",
        .sequence_eq => "cyna_sequence_eq",
        .sparse_eq => "cyna_sparse_eq",
        .string_starts_with => "cyna_string_starts_with",
        .string_ends_with => "cyna_string_ends_with",
        .string_contains => "cyna_string_contains",
        .string_find => "cyna_string_find",
        .string_rfind => "cyna_string_rfind",
        .string_slice => "cyna_string_slice",
        .string_from_bytes => "cyna_string_from_bytes",
        .string_copy => "cyna_string_copy",
        .string_share => "cyna_string_share",
        .string_release => "cyna_string_release",
        .string_share_into => "cyna_string_share_into",
        .string_release_at => "cyna_string_release_at",
        .string_from_bytes_into => "cyna_string_from_bytes_into",
        .string_slice_into => "cyna_string_slice_into",
        .string_find_into => "cyna_string_find_into",
        .string_rfind_into => "cyna_string_rfind_into",
        .fmt_empty_into => "cyna_runtime_fmt_empty_into",
        .fmt_append_string_into => "cyna_runtime_fmt_append_string_into",
        .fmt_append_int_into => "cyna_runtime_fmt_append_int_into",
        .fmt_empty => "cyna_runtime_fmt_empty",
        .fmt_append_string => "cyna_runtime_fmt_append_string",
        .fmt_append_int => "cyna_runtime_fmt_append_int",
        .assert_fail => "cyna_assert_fail",
        .assertion_fail => "cyna_runtime_assertion_fail",
        .bounds_fail => "cyna_runtime_bounds_fail",
        .capacity_fail => "cyna_runtime_capacity_fail",
        .arc_retain => "cyna_std_sync_arc_retain",
        .arc_release => "cyna_std_sync_arc_release",
        .tracked_alloc => "cyna_runtime_tracked_alloc",
        .tracked_alloc_site => "cyna_runtime_tracked_alloc_site",
        .tracked_free => "cyna_runtime_tracked_free",
        .install_root_allocator => "cyna_runtime_install_root_allocator",
        .clear_root_allocator => "cyna_runtime_clear_root_allocator",
        .has_root_allocator => "cyna_runtime_has_root_allocator",
        .install_writer => "cyna_std_io_install_writer",
        .clear_writer => "cyna_std_io_clear_writer",
        .writer_write => "cyna_runtime_writer_write",
        .assert_no_leaks => "cyna_runtime_assert_no_leaks",
    };
}

pub const string_eq_symbol = name(.string_eq);
pub const sequence_eq_symbol = name(.sequence_eq);
pub const sparse_eq_symbol = name(.sparse_eq);
pub const string_starts_with_symbol = name(.string_starts_with);
pub const string_ends_with_symbol = name(.string_ends_with);
pub const string_contains_symbol = name(.string_contains);
pub const string_find_symbol = name(.string_find);
pub const string_rfind_symbol = name(.string_rfind);
pub const string_slice_symbol = name(.string_slice);
pub const string_from_bytes_symbol = name(.string_from_bytes);
pub const string_copy_symbol = name(.string_copy);
pub const string_share_symbol = name(.string_share);
pub const string_release_symbol = name(.string_release);
pub const fmt_empty_symbol = name(.fmt_empty);
pub const fmt_append_string_symbol = name(.fmt_append_string);
pub const fmt_append_int_symbol = name(.fmt_append_int);
pub const assert_fail_symbol = name(.assert_fail);
pub const assertion_fail_symbol = name(.assertion_fail);
pub const bounds_fail_symbol = name(.bounds_fail);
pub const capacity_fail_symbol = name(.capacity_fail);
pub const TypeDescField = enum(u8) {
    size = 0,
    alignment = 1,
    flags = 2,
    copy = 3,
    drop = 4,
    equality = 5,
    hash = 6,
    extra = 7,
};

pub const type_desc_llvm_type = "{ i64, i64, i32, ptr, ptr, ptr, ptr, ptr }";
pub const dense_carrier_llvm_type = "{ ptr, i64, i64 }";
pub const sparse_carrier_llvm_type = "{ ptr, ptr, i64, i64 }";
pub const dense_runtime_llvm_type = "{ ptr, i64, i64, ptr }";
pub const sparse_runtime_llvm_type = "{ ptr, i64, i64, ptr, ptr }";
pub const dense_runtime_alloc_size = 32;
pub const sparse_runtime_alloc_size = 40;
pub const descriptor_global_prefix = "cyna_desc_";
pub const descriptor_copy_prefix = "cyna_copy_";
pub const descriptor_drop_prefix = "cyna_drop_";
pub const desc_u8_symbol = "cyna_desc_u8";
pub const desc_i32_symbol = "cyna_desc_i32";
pub const desc_i64_symbol = "cyna_desc_i64";
pub const desc_f32_symbol = "cyna_desc_f32";
pub const desc_f64_symbol = "cyna_desc_f64";
pub const desc_bool_symbol = "cyna_desc_bool";
pub const desc_string_symbol = "cyna_desc_string";
pub const primitive_descriptor_symbols = [_][]const u8{
    desc_u8_symbol,
    desc_i32_symbol,
    desc_bool_symbol,
    desc_i64_symbol,
    desc_f32_symbol,
    desc_f64_symbol,
    desc_string_symbol,
};

pub const RuntimeDecl = struct {
    id: Id,
    return_type: []const u8,
    signature: []const u8,
    always_emit: bool = false,
};

// Runtime helpers that the backend may need to declare explicitly in LLVM IR.
pub const container_runtime_decls = [_]RuntimeDecl{
    .{ .id = .assert_fail, .return_type = "void", .signature = "()", .always_emit = true },
    .{ .id = .assertion_fail, .return_type = "void", .signature = "()", .always_emit = true },
    .{ .id = .bounds_fail, .return_type = "void", .signature = "(i64, i64)", .always_emit = true },
    .{ .id = .capacity_fail, .return_type = "void", .signature = "(i64, i64)", .always_emit = true },
    .{ .id = .sequence_eq, .return_type = "i1", .signature = "(ptr, i64, ptr, i64, ptr)" },
    .{ .id = .sparse_eq, .return_type = "i1", .signature = "(ptr, ptr, i64, i64, ptr, ptr, i64, i64, ptr)" },
};

pub const string_runtime_decls = [_]RuntimeDecl{
    .{ .id = .string_from_bytes, .return_type = "{ ptr, i64 }", .signature = "({ ptr, i64 })" },
    .{ .id = .string_copy, .return_type = "{ ptr, i64 }", .signature = "({ ptr, i64 })" },
    .{ .id = .string_share, .return_type = "{ ptr, i64 }", .signature = "({ ptr, i64 })" },
    .{ .id = .string_release, .return_type = "void", .signature = "({ ptr, i64 })" },
    .{ .id = .string_share_into, .return_type = "void", .signature = "(ptr, ptr)" },
    .{ .id = .string_release_at, .return_type = "void", .signature = "(ptr)" },
    .{ .id = .string_from_bytes_into, .return_type = "void", .signature = "(ptr, ptr)" },
    .{ .id = .string_slice_into, .return_type = "void", .signature = "(ptr, ptr, i64, i64)" },
    .{ .id = .string_find_into, .return_type = "void", .signature = "(ptr, ptr, i64, ptr, i64)" },
    .{ .id = .string_rfind_into, .return_type = "void", .signature = "(ptr, ptr, i64, ptr, i64)" },
    .{ .id = .fmt_empty_into, .return_type = "void", .signature = "(ptr)" },
    .{ .id = .fmt_append_string_into, .return_type = "void", .signature = "(ptr, ptr, ptr)" },
    .{ .id = .fmt_append_int_into, .return_type = "void", .signature = "(ptr, ptr, i64, i32, i32)" },
    .{ .id = .string_starts_with, .return_type = "i1", .signature = "(ptr, i64, ptr, i64)" },
    .{ .id = .string_ends_with, .return_type = "i1", .signature = "(ptr, i64, ptr, i64)" },
    .{ .id = .string_contains, .return_type = "i1", .signature = "(ptr, i64, ptr, i64)" },
    .{ .id = .string_find, .return_type = "{ i1, i64 }", .signature = "({ ptr, i64 }, { ptr, i64 })" },
    .{ .id = .string_rfind, .return_type = "{ i1, i64 }", .signature = "({ ptr, i64 }, { ptr, i64 })" },
    .{ .id = .string_slice, .return_type = "{ ptr, i64 }", .signature = "({ ptr, i64 }, i64, i64)" },
    .{ .id = .fmt_empty, .return_type = "{ ptr, i64 }", .signature = "()" },
    .{ .id = .fmt_append_string, .return_type = "{ ptr, i64 }", .signature = "({ ptr, i64 }, { ptr, i64 })" },
    .{ .id = .fmt_append_int, .return_type = "{ ptr, i64 }", .signature = "({ ptr, i64 }, i64, i32, i32)" },
};

pub const infrastructure_runtime_decls = [_]RuntimeDecl{
    .{ .id = .tracked_alloc, .return_type = "ptr", .signature = "(i64)", .always_emit = true },
    .{ .id = .tracked_alloc_site, .return_type = "ptr", .signature = "(i64, ptr, i64, ptr)", .always_emit = true },
    .{ .id = .tracked_free, .return_type = "void", .signature = "(ptr)", .always_emit = true },
};

// Low-level runtime support entry points that imply a runtime link dependency
// even when they are not represented by RuntimeDecl metadata.
pub const runtime_support_symbols = [_][]const u8{
    name(.install_root_allocator),
    name(.clear_root_allocator),
    name(.has_root_allocator),
    name(.install_writer),
    name(.clear_writer),
    name(.writer_write),
    name(.assert_no_leaks),
};

comptime {
    @setEvalBranchQuota(10_000);
    var seen: [@typeInfo(Id).@"enum".field_names.len]bool = @splat(false);
    for (@typeInfo(Id).@"enum".field_values) |field_value| {
        const id: Id = @fromBackingInt(@intCast(field_value));
        const symbol = name(id);
        if (symbol.len == 0) @compileError("runtime ABI symbols must not be empty");
        for (@typeInfo(Id).@"enum".field_values) |other_value| {
            if (other_value >= field_value) continue;
            const other: Id = @fromBackingInt(@intCast(other_value));
            if (std.mem.eql(u8, symbol, name(other))) @compileError("runtime ABI symbol is registered more than once");
        }
        seen[@backingInt(id)] = true;
    }
    for (seen) |defined| {
        if (!defined) @compileError("runtime ABI registry must cover every identity");
    }
}

test "runtime ABI identities and descriptor layout are stable" {
    try std.testing.expectEqualStrings("cyna_string_copy", name(.string_copy));
    try std.testing.expectEqualStrings("cyna_std_sync_arc_retain", name(.arc_retain));
    try std.testing.expectEqual(@as(u8, 3), @backingInt(TypeDescField.copy));
    try std.testing.expectEqual(@as(u8, 4), @backingInt(TypeDescField.drop));
}

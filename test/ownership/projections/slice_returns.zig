const std = @import("std");

const helpers = @import("../../helpers.zig");

test "returned slice may derive from a slice parameter" {
    const source =
        \\fn tail(values: []i32): []i32 {
        \\    return values[1..];
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: [3]i32 = [1, 40, 2];
        \\    const view = tail(values[..]);
        \\    return view[0] + view[1];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "returned_slice_parameter_provenance",
        "native_returned_slice_parameter_provenance.cy",
        source,
        42,
    );
}

test "returned slice may derive from global storage" {
    const source =
        \\var values: [3]i32 = [1, 40, 2];
        \\
        \\fn tail(): []i32 {
        \\    return values[1..];
        \\}
        \\
        \\fn main(): i32 {
        \\    const view = tail();
        \\    return view[0] + view[1];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "returned_slice_global_provenance",
        "native_returned_slice_global_provenance.cy",
        source,
        42,
    );
}

test "returned slice cannot derive from local storage" {
    const source =
        \\fn invalid(): []i32 {
        \\    var values: [2]i32 = [40, 2];
        \\    return values[..];
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "returned_slice_local_provenance",
        source,
        "borrowed values cannot escape the function via return",
    );
}

test "returned slice cannot derive from value parameter storage" {
    const source =
        \\fn invalid(values: [2]i32): []i32 {
        \\    return values[..];
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "returned_slice_value_parameter_provenance",
        source,
        "borrowed values cannot escape the function via return",
    );
}

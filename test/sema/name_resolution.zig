const std = @import("std");
const compat = @import("cyna").compat;
const helpers = @import("../helpers.zig");

test "unambiguous nested enum can use short type name" {
    const source =
        \\struct Device {
        \\    enum Mode {
        \\        idle,
        \\        busy,
        \\    }
        \\
        \\    mode: Mode;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "nested_enum_short_type_name", source);
}

test "ambiguous nested enum short type names report candidates" {
    const source =
        \\struct DeviceA {
        \\    enum Mode {
        \\        idle,
        \\    }
        \\}
        \\
        \\struct DeviceB {
        \\    enum Mode {
        \\        idle,
        \\    }
        \\}
        \\
        \\struct Holder {
        \\    mode: Mode;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "ambiguous_nested_enum_short_type_name",
        source,
        "ambiguous type name `Mode`; candidates are",
    );
}

test "ambiguous unqualified union names across modules report candidates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "ambiguous-union-test"
        \\src = "."
        \\entry = "main.cy"
        \\
        ,
    });
    try compat.dirMakePath(tmp.dir, "driver");
    try compat.dirMakePath(tmp.dir, "proto");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "driver/status.cy",
        .data =
        \\pub union Result {
        \\    ok;
        \\}
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "proto/status.cy",
        .data =
        \\pub union Result {
        \\    ok;
        \\}
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\import .driver.status;
        \\import .proto.status as proto_status;
        \\
        \\struct Holder {
        \\    result: Result;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        \\
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try helpers.expectModuleSemanticFailedMessage(std.testing.allocator, source_path, "ambiguous type name `Result`; candidates are");
}

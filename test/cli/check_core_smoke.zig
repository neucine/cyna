const std = @import("std");
const helpers = @import("check_helpers.zig");
const compat = helpers.compat;

test "check smoke accepts standalone source file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\fn main(): i32 {
        \\    return 0;
        \\}
        \\
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try helpers.expectCheckSuccess(source_path);
}

test "check smoke reports standalone parse diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\fn main(): i32 {
        \\    const value = ;
        \\    return 0;
        \\}
        \\
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try helpers.expectCheckFailure(source_path, "expected expression");
}

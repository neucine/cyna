const std = @import("std");
const helpers = @import("check_helpers.zig");
const compat = helpers.compat;
const check_api = @import("check_api");
const check_mod = check_api.check;

test "check command accepts project directory manifest entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "check-project"
        \\src = "src"
        \\entry = "src/main.cy"
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
        \\import .util;
        \\
        \\fn main(): i32 {
        \\    return util.answer();
        \\}
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/util.cy", .data =
        \\pub fn answer(): i32 {
        \\    return 42;
        \\}
        \\
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root_path);

    try helpers.expectCheckSuccess(root_path);
}

test "check command reports parse diagnostics for invalid source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "parse-invalid"
        \\src = "src"
        \\entry = "src/main.cy"
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
        \\fn main(): i32 {
        \\    const value = ;
        \\    return 0;
        \\}
        \\
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root_path);

    try helpers.expectCheckFailure(root_path, "expected expression");
}

test "check command reports semantic diagnostics for invalid source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "semantic-invalid"
        \\src = "src"
        \\entry = "src/main.cy"
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
        \\fn main(): i32 {
        \\    return "oops";
        \\}
        \\
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root_path);

    try helpers.expectCheckFailure(root_path, "type mismatch: expected i32, got string");
}

test "check command accepts standalone source file" {
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

test "check command reports standalone parse diagnostics" {
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

test "check command reports standalone semantic diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\fn main(): i32 {
        \\    return "oops";
        \\}
        \\
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try helpers.expectCheckFailure(source_path, "type mismatch: expected i32, got string");
}

test "check command reports unresolved project import with attempted path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "missing-import"
        \\src = "src"
        \\entry = "src/main.cy"
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
        \\import .missing;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        \\
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root_path);

    var outcome = try check_mod.checkCommand(std.testing.allocator, root_path, .{});
    defer outcome.deinit(std.testing.allocator);
    switch (outcome) {
        .success => return error.TestUnexpectedResult,
        .reported_failure => |text| {
            try std.testing.expect(std.mem.indexOf(u8, text, "unresolved import `missing`") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "attempted path") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "current source root") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "FileNotFound") == null);
            try std.testing.expect(std.mem.indexOf(u8, text, "std/") == null);
        },
    }
}

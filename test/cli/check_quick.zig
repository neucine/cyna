const std = @import("std");
const helpers = @import("check_helpers.zig");
const compat = helpers.compat;

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

test "check command reports parse diagnostics for invalid project source" {
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

test "check command reports ordered independent parser errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\broken_one
        \\fn valid(): i32 { return 1; }
        \\broken_two
        \\fn main(): i32 { return valid(); }
        \\
    });
    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    const check_api = @import("check_api");
    var outcome = try check_api.check.checkCommand(std.testing.allocator, source_path, .{
        .diagnostic_format = .human,
    });
    defer outcome.deinit(std.testing.allocator);
    switch (outcome) {
        .success => return error.TestUnexpectedResult,
        .reported_failure => |text| {
            try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "error[E-parse_syntax]"));
            const first = std.mem.indexOf(u8, text, "1 | broken_one") orelse return error.TestUnexpectedResult;
            const second = std.mem.indexOf(u8, text, "3 | broken_two") orelse return error.TestUnexpectedResult;
            try std.testing.expect(first < second);
        },
    }
}

test "check command reports semantic diagnostics for invalid project source" {
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

test "check command explains the capturing callable refactor boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\fn apply(value: i32, callback: fn(i32): i32): i32 {
        \\    return callback(value);
        \\}
        \\
        \\fn main(): i32 {
        \\    const bias = 1;
        \\    return apply(41, |value| {
        \\        return value + bias;
        \\    });
        \\}
        \\
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try helpers.expectCheckFailure(
        source_path,
        "pass the lambda directly to a `(...) => R` parameter, or store explicit context beside the function pointer",
    );
}

test "check command defaults to source excerpts" {
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

    const check_api = @import("check_api");
    var outcome = try check_api.check.checkCommand(std.testing.allocator, source_path, .{});
    defer outcome.deinit(std.testing.allocator);
    switch (outcome) {
        .success => return error.TestUnexpectedResult,
        .reported_failure => |text| {
            try std.testing.expect(std.mem.indexOf(u8, text, "error[E-type_mismatch]: type mismatch: expected i32, got string") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "2 |     return \"oops\";") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "^~~~~~") != null);
        },
    }
}

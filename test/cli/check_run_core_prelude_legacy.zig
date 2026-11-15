const std = @import("std");
const helpers = @import("check_helpers.zig");
const compat = helpers.compat;

test "check command accepts prelude List Map and Set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\fn main(): i32 {
            \\    var xs: List<i32> = list<i32>();
            \\    var scores: Map<string, i32> = map<string, i32>();
            \\    var names: Set<string> = set<string>();
            \\    xs.push(1);
            \\    scores["ok"] = 42;
            \\    names.add("Ada");
            \\    if xs.len() == 1 and scores["ok"] == 42 and names.contains("Ada") {
            \\        return 0;
            \\    }
            \\    return 1;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try helpers.expectCheckSuccess(source_path);
}

test "check command accepts prelude List method calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\fn main(): i32 {
            \\    var xs: List<i32> = list<i32>();
            \\    xs.reserve(4);
            \\    xs.push(1);
            \\    xs.push(2);
            \\    const last = xs.pop();
            \\    if last == 2 and xs.len() == 1 {
            \\        return 0;
            \\    }
            \\    return 1;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try helpers.expectCheckSuccess(source_path);
}

test "check command accepts prelude Map and Set method calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\fn main(): i32 {
            \\    var scores: Map<string, i32> = map<string, i32>();
            \\    scores["ok"] = 42;
            \\    var names: Set<string> = set<string>();
            \\    names.add("Ada");
            \\    if scores.contains("ok") and not scores.contains("bad") and names.contains("Ada") and scores.len() == 1 and names.len() == 1 {
            \\        return 0;
            \\    }
            \\    return 1;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try helpers.expectCheckSuccess(source_path);
}

test "check command accepts prelude Map keys values and Set clear methods" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\fn main(): i32 {
            \\    var scores: Map<string, i32> = map<string, i32>();
            \\    scores["Ada"] = 10;
            \\    scores["Ken"] = 12;
            \\    var names: Set<string> = set<string>();
            \\    names.add("Ada");
            \\    names.add("Ken");
            \\    names.clear();
            \\    var key_count: i32 = 0;
            \\    for name in scores.keys() {
            \\        if name == "Ada" or name == "Ken" {
            \\            key_count = key_count + 1;
            \\        }
            \\    }
            \\    var total: i32 = 0;
            \\    var value_count: i32 = 0;
            \\    for value in scores.values() {
            \\        total = total + value;
            \\        value_count = value_count + 1;
            \\    }
            \\    if key_count == 2 and total == 22 and value_count == 2 and names.len() == 0 {
            \\        return 0;
            \\    }
            \\    return 1;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try helpers.expectCheckSuccess(source_path);
}

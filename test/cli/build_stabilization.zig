const std = @import("std");
const compat = @import("cyna").compat;
const support = @import("../support.zig");
const helpers = @import("../helpers.zig");

fn expectBuild(root: []const u8, output: []const u8, expected: u8, allow_whole_cache: bool) !void {
    const result = try support.runCommand(&.{ "zig", "build", "run", "-Doptimize=debug", "--", "build", root, "--output", output, "--verbose" });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try helpers.expectStderrNotContains(result.stderr, "leaked");
    if (!allow_whole_cache) try helpers.expectStderrNotContains(result.stderr, "reusing cached native build");
    const executed = try support.runCommand(&.{output});
    defer std.testing.allocator.free(executed.stdout);
    defer std.testing.allocator.free(executed.stderr);
    try std.testing.expectEqual(expected, executed.term.exited);
}

test "stabilization public build and run failures exit unsuccessfully without artifacts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const output = try std.fs.path.join(std.testing.allocator, &.{ root, "artifact" });
    defer std.testing.allocator.free(output);
    const cases = [_]struct { manifest: []const u8, source: []const u8, diagnostic: []const u8 }{
        .{ .manifest = "name = \"invalid\"\nentry = \"main.cy\"\n", .source = "fn main(): i32 { return missing_value; }", .diagnostic = "unknown value" },
        .{ .manifest = "name = \"invalid\"\nentry = \"main.cy\"\n", .source = "fn main(): i32 { const value = ; return 0; }", .diagnostic = "expected expression" },
        .{ .manifest = "type = \"invalid-kind\"\n", .source = "fn main(): i32 { return 0; }", .diagnostic = "build kind must be" },
        .{ .manifest = "entry = \"main.cy\"\n[build]\ntarget = \"invalid-target\"\n", .source = "fn main(): i32 { return 0; }", .diagnostic = "unsupported build.target" },
    };
    for (cases) |case| {
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data = case.manifest });
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = case.source });
        for ([_][]const u8{ "build", "run" }) |command| {
            const argv: []const []const u8 = if (std.mem.eql(u8, command, "build"))
                &.{ "zig", "build", "run", "-Doptimize=debug", "--", command, root, "--emit-sir", "--output", output }
            else
                &.{ "zig", "build", "run", "-Doptimize=debug", "--", command, root };
            const result = try support.runCommand(argv);
            defer std.testing.allocator.free(result.stdout);
            defer std.testing.allocator.free(result.stderr);
            try std.testing.expect(result.term.exited != 0);
            try helpers.expectStderrContains(result.stderr, case.diagnostic);
            try helpers.expectStderrNotContains(result.stderr, "wrote native artifact");
            try helpers.expectStderrNotContains(result.stderr, "program exited");
            try helpers.expectStderrNotContains(result.stderr, "panic:");
            try std.testing.expectError(error.FileNotFound, compat.access(output, .{}));
            const sir_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.sir", .{output});
            defer std.testing.allocator.free(sir_path);
            try std.testing.expectError(error.FileNotFound, compat.access(sir_path, .{}));
        }
    }
}

test "stabilization Debug CLI renders generic summary rejection safely" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.cy" });
    defer std.testing.allocator.free(source_path);
    const cases = [_]struct { source: []const u8, diagnostic: []const u8 }{
        .{ .source = "fn inner<T>(value: T): T { return value; } fn outer<T>(value: T): T { return inner<Missing>(value); } fn main(): i32 { return outer<i32>(42); }", .diagnostic = "unknown type `Missing`" },
    };
    for (cases) |case| {
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = case.source });
        const result = try support.runCommand(&.{ "zig", "build", "run", "-Doptimize=debug", "--", "check", source_path });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        try std.testing.expect(result.term.exited != 0);
        try helpers.expectStderrContains(result.stderr, case.diagnostic);
        try helpers.expectStderrNotContains(result.stderr, "Segmentation fault");
        try helpers.expectStderrNotContains(result.stderr, "Double free");
        try helpers.expectStderrNotContains(result.stderr, "leaked");
    }
}

test "stabilization Debug CLI honors deferred TaskGroup settlement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.cy" });
    defer std.testing.allocator.free(source_path);
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = "import { TaskGroup } from std.thread; fn settle(group: TaskGroup): void { defer group.finish(); return; } fn main(): i32 { return 0; }" });
    const result = try support.runCommand(&.{ "zig", "build", "run", "-Doptimize=debug", "--", "check", source_path });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try helpers.expectStderrNotContains(result.stderr, "without finish() or cancel_and_wait()");
    try helpers.expectStderrNotContains(result.stderr, "leaked");
}

test "stabilization Debug CLI honors optional TaskGroup capture settlement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.cy" });
    defer std.testing.allocator.free(source_path);
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = "import { TaskGroup } from std.thread; fn settle(group: ?TaskGroup): void { if group is item { item.finish(); } } fn main(): i32 { return 0; }" });
    const result = try support.runCommand(&.{ "zig", "build", "run", "-Doptimize=debug", "--", "check", source_path });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try helpers.expectStderrNotContains(result.stderr, "without finish() or cancel_and_wait()");
    try helpers.expectStderrNotContains(result.stderr, "leaked");
}

test "stabilization Debug CLI permits explicit union TaskGroup protocol" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.cy" });
    defer std.testing.allocator.free(source_path);
    const cases = [_][]const u8{
        "fn abandon(value: Choice): void {}",
        "fn settle(value: Choice): void { switch value { .active(group) => { group.finish(); } .empty => {} } }",
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "import {{ TaskGroup }} from std.thread; union Choice {{ active: TaskGroup; empty; }} {s} fn main(): i32 {{ return 0; }}", .{case});
        defer std.testing.allocator.free(source);
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
        const result = try support.runCommand(&.{ "zig", "build", "run", "-Doptimize=debug", "--", "check", source_path });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
        try helpers.expectStderrNotContains(result.stderr, "leaked");
    }
}

test "stabilization Debug CLI rejects indexed TaskGroup settlement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.cy" });
    defer std.testing.allocator.free(source_path);
    const cases = [_][]const u8{
        "groups[0].finish();",
        "groups[0].finish(); groups[1].finish();",
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "import {{ TaskGroup }} from std.thread; fn settle(groups: [2]TaskGroup): void {{ {s} }} fn main(): i32 {{ return 0; }}", .{case});
        defer std.testing.allocator.free(source);
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
        const result = try support.runCommand(&.{ "zig", "build", "run", "-Doptimize=debug", "--", "check", source_path });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        try std.testing.expect(result.term.exited != 0);
        try helpers.expectStderrContains(result.stderr, "cannot consume concurrency handle through a projected place");
        try helpers.expectStderrNotContains(result.stderr, "leaked");
    }
}

test "stabilization Debug CLI accepts guaranteed loop return after settlement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.cy" });
    defer std.testing.allocator.free(source_path);
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = "import { TaskGroup } from std.thread; fn settle(group: TaskGroup): void { while true { group.finish(); return; } } fn main(): i32 { return 0; }" });
    const result = try support.runCommand(&.{ "zig", "build", "run", "-Doptimize=debug", "--", "check", source_path });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try helpers.expectStderrNotContains(result.stderr, "without finish() or cancel_and_wait()");
    try helpers.expectStderrNotContains(result.stderr, "leaked");
}

test "stabilization native and package failures propagate unsuccessful outcomes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const output = try std.fs.path.join(std.testing.allocator, &.{ root, "program" });
    defer std.testing.allocator.free(output);
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data = "entry = \"main.cy\"\n[c]\nsources = [\"broken.c\"]\n" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = "fn main(): i32 { return 0; }" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "broken.c", .data = "#error normalization_native_failure\n" });
    const native_failure = try support.runCommand(&.{ "zig", "build", "run", "-Doptimize=debug", "--", "build", root, "--output", output });
    defer std.testing.allocator.free(native_failure.stdout);
    defer std.testing.allocator.free(native_failure.stderr);
    try std.testing.expect(native_failure.term.exited != 0);
    try helpers.expectStderrContains(native_failure.stderr, "normalization_native_failure");
    try helpers.expectStderrNotContains(native_failure.stderr, "wrote native artifact");
    try std.testing.expectError(error.FileNotFound, compat.access(output, .{}));
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data = "name = \"invalid-package\"\n" });
    for ([_][]const u8{ "build", "pack", "publish" }) |command| {
        const result = try support.runCommand(&.{ "zig", "build", "run", "-Doptimize=debug", "--", "package", command, root });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        try std.testing.expect(result.term.exited != 0);
        try helpers.expectStderrContains(result.stderr, "package pack requires manifest `version`");
    }
}

test "stabilization warm build follows manifest entry and source root changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirMakePath(tmp.dir, "other");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data = "fn main(): i32 { return 23; }" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/alternate.cy", .data = "fn main(): i32 { return 37; }" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "other/main.cy", .data = "fn main(): i32 { return 41; }" });
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const output = try std.fs.path.join(std.testing.allocator, &.{ root, "program" });
    defer std.testing.allocator.free(output);
    const entries = [_][]const u8{ "name = \"entry\"\nsrc = \"src\"\nentry = \"src/main.cy\"\n", "name = \"entry\"\nsrc = \"src\"\nentry = \"src/alternate.cy\"\n", "name = \"entry\"\nsrc = \"other\"\nentry = \"other/main.cy\"\n" };
    for (entries, [_]u8{ 23, 37, 41 }) |manifest, expected| {
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data = manifest });
        try expectBuild(root, output, expected, false);
    }
}

test "stabilization warm cache restores executable into absent output directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data = "entry = \"main.cy\"\n" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = "fn main(): i32 { return 37; }" });
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const output = try std.fs.path.join(std.testing.allocator, &.{ root, "output", "program" });
    defer std.testing.allocator.free(output);
    try expectBuild(root, output, 37, true);
    try compat.deleteTreeAbsolute(std.fs.path.dirname(output).?);
    try std.testing.expectError(error.FileNotFound, compat.access(output, .{}));
    const restored = try support.runCommand(&.{ "zig", "build", "run", "-Doptimize=debug", "--", "build", root, "--output", output, "--verbose" });
    defer std.testing.allocator.free(restored.stdout);
    defer std.testing.allocator.free(restored.stderr);
    errdefer std.debug.print("restoration CLI stderr:\n{s}\n", .{restored.stderr});
    try std.testing.expectEqual(@as(u8, 0), restored.term.exited);
    // The implicit prelude keeps this public program out of whole-build
    // admission. Require the actual native artifact hit, not a fresh link;
    // whole-build bundle/sidecar restoration has its own source-root tests.
    if (@import("builtin").os.tag == .linux) {
        // GNU ld's sysroot-relative SEARCH_DIR entries disable native link
        // cache reuse until their implicit inputs can be inventoried safely.
        try helpers.expectStderrContains(restored.stderr, "linking native executable");
    } else {
        try helpers.expectStderrContains(restored.stderr, "reusing cached native artifact");
        try helpers.expectStderrNotContains(restored.stderr, "linking native executable");
    }
    try helpers.expectStderrNotContains(restored.stderr, "leaked");
    const executed = try support.runCommand(&.{output});
    defer std.testing.allocator.free(executed.stdout);
    defer std.testing.allocator.free(executed.stderr);
    try std.testing.expectEqual(@as(u8, 37), executed.term.exited);
}

test "stabilization warm build recompiles transitive C headers with and without include paths" {
    for ([_]bool{ false, true }) |explicit_includes| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try compat.dirMakePath(tmp.dir, "native");
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = "extern c(\"helper\") fn helper(): c_int; fn main(): i32 { return helper() as i32; }" });
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "native/helper.c", .data = "#include \"helper.h\"\nint helper(void) { return VALUE; }\n" });
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "native/helper.h", .data = "#include \"detail.h\"\n" });
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data = if (explicit_includes)
            "name = \"headers\"\nentry = \"main.cy\"\n[c]\nsources = [\"native/helper.c\"]\ninclude_paths = [\"native\"]\n"
        else
            "name = \"headers\"\nentry = \"main.cy\"\n[c]\nsources = [\"native/helper.c\"]\n" });
        const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
        defer std.testing.allocator.free(root);
        const output = try std.fs.path.join(std.testing.allocator, &.{ root, "program" });
        defer std.testing.allocator.free(output);
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "native/detail.h", .data = "#define VALUE 11\n" });
        try expectBuild(root, output, 11, false);
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "native/detail.h", .data = "#define VALUE 23\n" });
        try expectBuild(root, output, 23, false);
        try expectBuild(root, output, 23, false);
    }
}

test "stabilization warm build follows changed source root with unchanged entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data = "import .value; fn main(): i32 { return value.answer(); }" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "value.cy", .data = "pub fn answer(): i32 { return 23; }" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/value.cy", .data = "pub fn answer(): i32 { return 37; }" });
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const output = try std.fs.path.join(std.testing.allocator, &.{ root, "program" });
    defer std.testing.allocator.free(output);
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data = "name = \"source-root\"\nsrc = \".\"\nentry = \"src/main.cy\"\n" });
    try expectBuild(root, output, 23, false);
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data = "name = \"source-root\"\nsrc = \"src\"\nentry = \"src/main.cy\"\n" });
    try expectBuild(root, output, 37, false);
}

test "stabilization public generic method admission and declared SIR authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data = "entry = \"main.cy\"\n" });
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    for ([_][]const u8{
        "fn unused<T>(value: T): i32 { const alias = &value; return alias.secret(); } fn main(): i32 { return 0; }",
        "fn identity<U>(value: U): U { return value; } fn unused<T>(value: T): i32 { return identity(value).secret(); } fn main(): i32 { return 0; }",
        "protocol Secret { fn secret(self: &const Self): i32; } fn unused<T>(value: &const T): i32 { return Secret.secret(value); } fn main(): i32 { return 0; }",
        "fn unused<T>(values: &const List<T>): i32 { return values[0].secret(); } fn main(): i32 { return 0; }",
        "fn unused<T>(values: &const List<T>): i32 { for item in values { return item.secret(); } return 0; } fn main(): i32 { return 0; }",
        "fn first<U>(values: [2]U): U { return values[0]; } fn unused<T>(value: T): i32 { const selected = first([value] ** 2); return selected.secret(); } fn main(): i32 { return 0; }",
        "fn unused<T>(value: T): i32 { var slots = [;]T { 0: value }; if &slots[0] is item { return item.secret(); } return 0; } fn main(): i32 { return 0; }",
        "fn unused<T>(): i32 { unchecked { const selected = asm(T) { \"{result}\"; out reg result; }; return selected.secret(); } } fn main(): i32 { return 0; }",
    }) |source| {
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
        const rejected = try support.runCommand(&.{ "zig", "build", "run", "-Doptimize=debug", "--", "check", root });
        defer std.testing.allocator.free(rejected.stdout);
        defer std.testing.allocator.free(rejected.stderr);
        try std.testing.expect(rejected.term.exited != 0);
        helpers.expectStderrContains(rejected.stderr, "requires a declared protocol for method `secret`") catch |err| {
            std.debug.print("generic admission source: {s}\nactual stderr: {s}\n", .{ source, rejected.stderr });
            return err;
        };
        try helpers.expectStderrNotContains(rejected.stderr, "leaked");
    }
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = "protocol Readable { fn read(self: &const Self): i32; } fn identity<U>(value: U): U { return value; } fn inspect<T: Readable & Clone>(value: T): i32 { const duplicate: T = value.clone(); const returned = identity(duplicate); return returned.read(); } fn qualified<T: Readable>(value: &const T): i32 { return Readable.read(value); } fn indexed<T: Readable>(values: &const List<T>): i32 { return values[0].read(); } fn iterated<T: Readable>(values: &const List<T>): i32 { for item in values { return item.read(); } return 0; } fn projection<T>(value: T): bool { const item = value.item; return item == item; } fn main(): i32 { return 0; }" });
    const output = try std.fs.path.join(std.testing.allocator, &.{ root, "inspection" });
    defer std.testing.allocator.free(output);
    const accepted = try support.runCommand(&.{ "zig", "build", "run", "-Doptimize=debug", "--", "build", root, "--emit-sir", "--output", output });
    defer std.testing.allocator.free(accepted.stdout);
    defer std.testing.allocator.free(accepted.stderr);
    try std.testing.expectEqual(@as(u8, 0), accepted.term.exited);
    try helpers.expectStderrNotContains(accepted.stderr, "leaked");
    const sir_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.sir", .{output});
    defer std.testing.allocator.free(sir_path);
    const sir_text = try compat.readFileAlloc(std.testing.allocator, sir_path, 1 << 20);
    defer std.testing.allocator.free(sir_text);
    try std.testing.expect(std.mem.indexOf(u8, sir_text, "inspect<T>: clone @+") != null);
    try std.testing.expect(std.mem.indexOf(u8, sir_text, "inspect<T>: read @+") != null);
    try std.testing.expect(std.mem.indexOf(u8, sir_text, "qualified<T>: read @+") != null);
    try std.testing.expect(std.mem.indexOf(u8, sir_text, "indexed<T>: read @+") != null);
    try std.testing.expect(std.mem.indexOf(u8, sir_text, "iterated<T>: read @+") != null);
    try std.testing.expect(std.mem.indexOf(u8, sir_text, "[declared main::Readable]") != null);
}

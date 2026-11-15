const std = @import("std");
const compat = @import("cyna").compat;

const test_helpers = @import("../helpers.zig");
const test_exec = @import("../support.zig");

const expectStderrContains = test_helpers.expectStderrContains;
const expectStderrNotContains = test_helpers.expectStderrNotContains;
const expectTestSummary = test_helpers.expectTestSummary;
const runCommand = test_exec.runCommand;

fn writeFile(dir: anytype, path: []const u8, source: []const u8) !void {
    const file = try compat.dirCreateFile(dir, path, .{});
    defer compat.closeFile(file);
    try compat.fileWriteAll(file, source);
}

test "test command discovers only test roots under the source tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src/nested");

    try writeFile(tmp.dir, "src/main.cy",
        \\fn main(): i32 { return 0; }
        \\
    );
    try writeFile(tmp.dir, "src/nested/math.test.cy",
        \\test "test root runs" {
        \\    assert(20 + 22 == 42);
        \\}
        \\
    );

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const result = try runCommand(&.{ "zig", "build", "run", "--", "test", root });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try expectStderrContains(result.stderr, "math.test.cy");
    try expectStderrContains(result.stderr, "test root runs");
    try expectTestSummary(result.stderr, 1, 0);
}

test "test command runs roots in a static library project" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    try writeFile(tmp.dir, "cyna.toml",
        \\name = "library-tests"
        \\version = "0.1.0"
        \\type = "staticlib"
    );
    try writeFile(tmp.dir, "src/lib.cy", "pub fn answer(): i32 { return 42; }\n");
    try writeFile(tmp.dir, "src/answer.test.cy",
        \\import { answer } from .lib;
        \\test "library root runs" { assert(answer() == 42); }
    );

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const result = try runCommand(&.{ "zig", "build", "run", "--", "test", root });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try expectStderrContains(result.stderr, "library root runs");
    try expectTestSummary(result.stderr, 1, 0);
}

test "test command links imported std.math C companion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try writeFile(tmp.dir, "cyna.toml",
        \\name = "math-tests"
        \\version = "0.1.0"
        \\type = "staticlib"
    );
    try writeFile(tmp.dir, "src/lib.cy", "pub fn answer(): i32 { return 42; }\n");
    try writeFile(tmp.dir, "src/math.test.cy",
        \\import std.math;
        \\test "standard rounded conversion" {
        \\    const rounded = math.to_f32_rounded(0.1);
        \\    if rounded is none { assert(false); }
        \\}
    );

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const result = try runCommand(&.{ "zig", "build", "run", "--", "test", root, "--filter", "standard rounded conversion" });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    errdefer std.debug.print("std.math test CLI stderr:\n{s}\n", .{result.stderr});

    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try expectTestSummary(result.stderr, 1, 0);
}

test "test command fails for an invalid project manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try writeFile(tmp.dir, "cyna.toml", "type = \"executable\"\n");
    try writeFile(tmp.dir, "src/main.cy", "fn main(): i32 { return 0; }\n");
    try writeFile(tmp.dir, "src/main.test.cy", "test \"would run\" { assert(true); }\n");

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const result = try runCommand(&.{ "zig", "build", "run", "--", "test", root });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expect(result.term.exited != 0);
    try expectStderrContains(result.stderr, "build kind must be");
    try expectStderrNotContains(result.stderr, "would run");
}

test "test root has friend access to private sibling declarations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    try writeFile(tmp.dir, "src/main.cy", "fn main(): i32 { return 0; }\n");
    try writeFile(tmp.dir, "src/math.cy",
        \\const answer: i32 = 42;
        \\
        \\fn add_private(a: i32, b: i32): i32 {
        \\    return a + b;
        \\}
        \\
        \\struct Pair {
        \\    left: i32;
        \\    right: i32;
        \\
        \\    fn total(self: Pair): i32 {
        \\        return self.left + self.right;
        \\    }
        \\}
        \\
    );
    try writeFile(tmp.dir, "src/math.test.cy",
        \\import { answer, add_private, Pair } from .math;
        \\
        \\test "friend sees private declarations" {
        \\    assert(answer == 42);
        \\    assert(add_private(20, 22) == answer);
        \\    const pair: Pair = Pair { left: 20, right: 22 };
        \\    assert(pair.total() == answer);
        \\}
        \\
    );

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const result = try runCommand(&.{ "zig", "build", "run", "--", "test", root });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try expectStderrContains(result.stderr, "friend sees private declarations");
    try expectTestSummary(result.stderr, 1, 0);
}

test "test root links manifest C sources with include paths and flags" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirMakePath(tmp.dir, "csrc");
    try compat.dirMakePath(tmp.dir, "include");

    try writeFile(tmp.dir, "cyna.toml",
        \\name = "native-test"
        \\version = "0.1.0"
        \\src = "src"
        \\type = "exe"
        \\entry = "src/main.cy"
        \\
        \\[c]
        \\sources = ["csrc/fixture.c"]
        \\include_paths = ["include"]
        \\flags = ["-DFIXTURE_VALUE=42"]
        \\
    );
    try writeFile(tmp.dir, "src/main.cy", "fn main(): i32 { return 0; }\n");
    try writeFile(tmp.dir, "src/ffi.cy",
        \\pub extern c("fixture_answer") fn fixture_answer(): c_int;
        \\
    );
    try writeFile(tmp.dir, "src/ffi.test.cy",
        \\import { fixture_answer } from .ffi;
        \\
        \\test "manifest C source is linked" {
        \\    assert(fixture_answer() == 42);
        \\}
        \\
    );
    try writeFile(tmp.dir, "include/fixture.h",
        \\#define FIXTURE_RESULT FIXTURE_VALUE
        \\
    );
    try writeFile(tmp.dir, "csrc/fixture.c",
        \\#include "fixture.h"
        \\
        \\int fixture_answer(void) {
        \\    return FIXTURE_RESULT;
        \\}
        \\
    );

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const result = try runCommand(&.{ "zig", "build", "run", "--", "test", root });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try expectStderrContains(result.stderr, "manifest C source is linked");
    try expectTestSummary(result.stderr, 1, 0);
}

test "test root can exist without a production sibling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    try writeFile(tmp.dir, "src/main.cy", "fn main(): i32 { return 0; }\n");
    try writeFile(tmp.dir, "src/standalone.test.cy",
        \\fn helper(): i32 { return 42; }
        \\
        \\test "standalone root runs" {
        \\    assert(helper() == 42);
        \\}
        \\
    );

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const result = try runCommand(&.{ "zig", "build", "run", "--", "test", root });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try expectTestSummary(result.stderr, 1, 0);
}

test "test command filter matches test names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "beta_checkout/src");

    try writeFile(tmp.dir, "beta_checkout/src/main.cy", "fn main(): i32 { return 0; }\n");
    try writeFile(tmp.dir, "beta_checkout/src/filter.test.cy",
        \\test "alpha path" { assert(true); }
        \\test "beta path" { assert(true); }
        \\
    );

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "beta_checkout");
    defer std.testing.allocator.free(root);
    const result = try runCommand(&.{ "zig", "build", "run", "--", "test", root, "--filter", "beta" });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try expectStderrContains(result.stderr, "beta path");
    try expectStderrNotContains(result.stderr, "alpha path");
    try expectTestSummary(result.stderr, 1, 0);
}

test "a broken test root does not prevent later roots from running" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    try writeFile(tmp.dir, "src/main.cy", "fn main(): i32 { return 0; }\n");
    try writeFile(tmp.dir, "src/a_broken.test.cy", "test \"broken\" { this is not valid; }\n");
    try writeFile(tmp.dir, "src/z_working.test.cy",
        \\test "still runs" {
        \\    assert(true);
        \\}
        \\
    );

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const result = try runCommand(&.{ "zig", "build", "run", "--", "test", root });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try expectStderrContains(result.stderr, "a_broken.test.cy");
    try expectStderrContains(result.stderr, "z_working.test.cy: still runs");
    try expectStderrContains(result.stderr, "<compile> (ParseFailed)");
    try expectTestSummary(result.stderr, 1, 1);
}

test "normal build rejects a test file as its root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    try writeFile(tmp.dir, "src/main.cy", "fn main(): i32 { return 0; }\n");
    try writeFile(tmp.dir, "src/direct.test.cy", "test \"only through test command\" { assert(true); }\n");

    const path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "src/direct.test.cy");
    defer std.testing.allocator.free(path);
    const result = try runCommand(&.{ "zig", "build", "run", "--", "build", path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try expectStderrContains(result.stderr, "test files can only be compiled as roots by `cyna test`");
}

test "normal build rejects test blocks in production source files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    try writeFile(tmp.dir, "src/main.cy",
        \\fn main(): i32 { return 0; }
        \\
        \\test "must move to main.test.cy" {
        \\    assert(true);
        \\}
        \\
    );

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const result = try runCommand(&.{ "zig", "build", "run", "--", "build", root });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try expectStderrContains(result.stderr, "test blocks are only allowed in *.test.cy files");
}

test "dotted imports still resolve directory modules rather than test filenames" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src/foo");

    try writeFile(tmp.dir, "src/main.cy", "fn main(): i32 { return 0; }\n");
    try writeFile(tmp.dir, "src/foo/bar.cy", "pub fn value(): i32 { return 42; }\n");
    try writeFile(tmp.dir, "src/foo.bar.cy", "this file must not be resolved by import foo.bar;\n");
    try writeFile(tmp.dir, "src/imports.test.cy",
        \\import foo.bar;
        \\
        \\test "directory module wins" {
        \\    assert(bar.value() == 42);
        \\}
        \\
    );

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const result = try runCommand(&.{ "zig", "build", "run", "--", "test", root });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try expectTestSummary(result.stderr, 1, 0);
}

test "friend visibility follows the sibling path rather than a flattened dotted name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src/foo");

    try writeFile(tmp.dir, "src/main.cy", "fn main(): i32 { return 0; }\n");
    try writeFile(tmp.dir, "src/foo/bar.cy", "fn hidden(): i32 { return 42; }\n");
    try writeFile(tmp.dir, "src/foo.bar.cy", "fn sibling(): i32 { return 1; }\n");
    try writeFile(tmp.dir, "src/foo.bar.test.cy",
        \\import { hidden } from foo.bar;
        \\test "not a friend of the directory module" {
        \\    assert(hidden() == 42);
        \\}
        \\
    );

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const result = try runCommand(&.{ "zig", "build", "run", "--", "test", root });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try expectStderrContains(result.stderr, "hidden");
    try expectStderrContains(result.stderr, "<compile> (SemanticFailed)");
}

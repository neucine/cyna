const std = @import("std");
const compat = @import("cyna").compat;

const test_helpers = @import("../helpers.zig");
const test_exec = @import("../support.zig");

const expectStderrContains = test_helpers.expectStderrContains;
const expectStderrNotContains = test_helpers.expectStderrNotContains;
const runCommand = test_exec.runCommand;

test "build emits compiler stage artifacts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "app.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\fn main(): i32 {
            \\    return 0;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app.cy");
    defer std.testing.allocator.free(source_path);
    const base = try std.fs.path.join(std.testing.allocator, &.{ std.fs.path.dirname(source_path) orelse ".", "app" });
    defer std.testing.allocator.free(base);

    const tok_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.tok", .{base});
    defer std.testing.allocator.free(tok_path);
    const ast_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.ast", .{base});
    defer std.testing.allocator.free(ast_path);
    const ll_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.ll", .{base});
    defer std.testing.allocator.free(ll_path);
    const result = try runCommand(&.{
        "zig",
        "build",
        "run",
        "--",
        "build",
        source_path,
        "--emit-tok",
        "--emit-ast",
        "--emit-ll",
    });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try compat.access(tok_path, .{});
    try compat.access(ast_path, .{});
    try compat.access(ll_path, .{});
    try expectStderrContains(result.stderr, "wrote TOK to");
    try expectStderrContains(result.stderr, "wrote AST to");
    try expectStderrContains(result.stderr, "wrote LLVM IR to");
    try expectStderrNotContains(result.stderr, "== TOK ==");
    try expectStderrNotContains(result.stderr, "keyword_fn");
}

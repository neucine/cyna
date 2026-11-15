const std = @import("std");
const builtin = @import("builtin");
const compat = @import("cyna").compat;

const test_exec = @import("../support.zig");

const runCommand = test_exec.runCommand;
const expectCommandExitedZero = test_exec.expectCommandExitedZero;
const expectCommandReportedProgramExit = test_exec.expectCommandReportedProgramExit;

test "generated header compiles in a C consumer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(tmp_root);

    const output_base = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "c_header_consumer" });
    defer std.testing.allocator.free(output_base);
    const source_path = try compat.cwdRealpathAlloc(std.testing.allocator, "examples/c_header_consumer/api.cy");
    defer std.testing.allocator.free(source_path);
    const consumer_path = try compat.cwdRealpathAlloc(std.testing.allocator, "examples/c_header_consumer/consumer.c");
    defer std.testing.allocator.free(consumer_path);
    const object_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "consumer.o" });
    defer std.testing.allocator.free(object_path);

    const build_result = try runCommand(&.{ "zig", "build", "run", "--", "build", source_path, "--emit-c-header", "--output", output_base });
    defer {
        std.testing.allocator.free(build_result.stdout);
        std.testing.allocator.free(build_result.stderr);
    }
    try std.testing.expectEqual(@as(u8, 0), build_result.term.exited);

    var compile_scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer compile_scratch.deinit();
    const compile_result = try compat.runProcess(compile_scratch.allocator(), .{
        .argv = &.{ "/usr/bin/cc", "-std=c11", "-c", consumer_path, "-I", tmp_root, "-o", object_path },
    });
    try std.testing.expectEqual(@as(u8, 0), compile_result.term.exited);
}

test "project directory build uses src/main.cy convention" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    {
        const file = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\fn main(): i32 {
            \\    return 0;
            \\}
            \\
        );
    }
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    try expectCommandExitedZero(&.{ "zig", "build", "run", "--", "build", root });
    const stem = std.fs.path.basename(root);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root, "build", stem });
    defer std.testing.allocator.free(output_path);
    try compat.access(output_path, .{});
}

test "project manifest can build and run with companion C source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirMakePath(tmp.dir, "native/include");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
        \\extern {
        \\    c("helper") fn helper(): c_int;
        \\}
        \\
        \\fn main(): i32 {
        \\    return helper() as i32;
        \\}
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "native/include/helper.h", .data =
        \\#define HELPER_VALUE 11
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "native/helper.c", .data =
        \\#include "helper.h"
        \\int helper(void) { return HELPER_VALUE; }
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "with-c"
        \\type = "exe"
        \\entry = "src/main.cy"
        \\
        \\[c]
        \\sources = ["native/helper.c"]
        \\include_paths = ["native/include"]
        \\
    });
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    try expectCommandReportedProgramExit(&.{ "zig", "build", "run", "--", "run", root }, 11);
}

test "explicit manifest entry build path keeps companion C symbol imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
        \\extern {
        \\    c("marker") const marker: *i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    unchecked {
        \\        return *marker;
        \\    }
        \\}
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "native.c", .data =
        \\int marker = 42;
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "symbols"
        \\entry = "src/main.cy"
        \\
        \\[c]
        \\sources = ["native.c"]
        \\
    });
    const entry_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "src/main.cy");
    defer std.testing.allocator.free(entry_path);
    try expectCommandReportedProgramExit(&.{ "zig", "build", "run", "--", "run", entry_path }, 42);
}

test "project manifest can link prebuilt static library" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirMakePath(tmp.dir, "native/lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
        \\extern {
        \\    c("helper") fn helper(): c_int;
        \\}
        \\
        \\fn main(): i32 {
        \\    return helper() as i32;
        \\}
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "native/helper.c", .data =
        \\int helper(void) { return 21; }
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "with-lib"
        \\type = "exe"
        \\entry = "src/main.cy"
        \\
        \\[link]
        \\libs = ["helper"]
        \\search_paths = ["native/lib"]
        \\
    });
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const helper_c = try std.fs.path.join(std.testing.allocator, &.{ root, "native", "helper.c" });
    defer std.testing.allocator.free(helper_c);
    const helper_o = try std.fs.path.join(std.testing.allocator, &.{ root, "native", "helper.o" });
    defer std.testing.allocator.free(helper_o);
    const helper_a = try std.fs.path.join(std.testing.allocator, &.{ root, "native", "lib", "libhelper.a" });
    defer std.testing.allocator.free(helper_a);
    try expectCommandExitedZero(&.{ "/usr/bin/cc", "-c", helper_c, "-o", helper_o });
    try expectCommandExitedZero(&.{ "/usr/bin/ar", "rcs", helper_a, helper_o });
    try expectCommandReportedProgramExit(&.{ "zig", "build", "run", "--", "run", root }, 21);
}

test "project manifest can build with companion assembly source" {
    if (builtin.cpu.arch != .aarch64 or builtin.os.tag != .macos) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirMakePath(tmp.dir, "native");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
        \\extern {
        \\    c("helper") fn helper(): c_int;
        \\}
        \\
        \\fn main(): i32 {
        \\    return helper() as i32;
        \\}
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "native/helper.S", .data =
        \\.text
        \\.globl _helper
        \\_helper:
        \\    mov w0, #13
        \\    ret
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "with-asm"
        \\type = "exe"
        \\entry = "src/main.cy"
        \\
        \\[asm]
        \\sources = ["native/helper.S"]
        \\
    });
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    try expectCommandReportedProgramExit(&.{ "zig", "build", "run", "--", "run", root }, 13);
}

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("cyna").compat;

const test_helpers = @import("../helpers.zig");
const test_exec = @import("../support.zig");

const expectStderrContains = test_helpers.expectStderrContains;
const expectStderrNotContains = test_helpers.expectStderrNotContains;
const runCommand = test_exec.runCommand;
const expectCommandExitedZero = test_exec.expectCommandExitedZero;
const expectCommandReportedProgramExit = test_exec.expectCommandReportedProgramExit;

test {
    _ = @import("build_stabilization.zig");
}

test "resource tuple crosses module call and return boundaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src/lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "tuple_modules"
        \\src = "src"
        \\entry = "src/main.cy"
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/lib/pair.cy", .data =
        \\pub fn make(): ([:]i32, i32) { return ([40, 2], 0); }
        \\pub fn read(value: ([:]i32, i32)): i32 {
        \\    const first = value.0;
        \\    return first[0] + first[1];
        \\}
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
        \\import .lib.pair as values;
        \\fn main(): i32 { return values.read(values.make()); }
        \\
    });
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    try expectCommandReportedProgramExit(&.{ "zig", "build", "run", "--", "run", root }, 42);
}

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
        .argv = &.{
            "/usr/bin/cc",
            "-std=c11",
            "-c",
            consumer_path,
            "-I",
            tmp_root,
            "-o",
            object_path,
        },
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

test "build reuses safe lower caches and invalidates changed sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "src/main.cy",
        .data =
        \\fn main(): i32 {
        \\    return 0;
        \\}
        \\
        ,
    });

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const output = try std.fs.path.join(std.testing.allocator, &.{ root, "program" });
    defer std.testing.allocator.free(output);
    const argv = &.{ "zig", "build", "run", "--", "build", root, "--output", output, "--verbose" };

    const first = try runCommand(argv);
    defer {
        std.testing.allocator.free(first.stdout);
        std.testing.allocator.free(first.stderr);
    }
    try std.testing.expectEqual(@as(u8, 0), first.term.exited);
    try expectStderrNotContains(first.stderr, "reusing cached native build");

    const second = try runCommand(argv);
    defer {
        std.testing.allocator.free(second.stdout);
        std.testing.allocator.free(second.stderr);
    }
    try std.testing.expectEqual(@as(u8, 0), second.term.exited);
    // The autoloaded prelude requires bundled C runtime dependencies, so its
    // whole-build cache is deliberately ineligible until header tracking exists.
    try expectStderrNotContains(second.stderr, "reusing cached native build");
    try expectStderrContains(second.stderr, "reusing cached module main");
    try expectStderrContains(second.stderr, "native objects ready (0 compiled, 2 reused)");
    const unchanged = try runCommand(&.{output});
    defer std.testing.allocator.free(unchanged.stdout);
    defer std.testing.allocator.free(unchanged.stderr);
    try std.testing.expectEqual(@as(u8, 0), unchanged.term.exited);

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "src/main.cy",
        .data =
        \\fn main(): i32 {
        \\    return 1;
        \\}
        \\
        ,
    });
    const third = try runCommand(argv);
    defer {
        std.testing.allocator.free(third.stdout);
        std.testing.allocator.free(third.stderr);
    }
    try std.testing.expectEqual(@as(u8, 0), third.term.exited);
    try expectStderrNotContains(third.stderr, "reusing cached native build");
    try expectStderrContains(third.stderr, "lowering module main");
    const changed = try runCommand(&.{output});
    defer std.testing.allocator.free(changed.stdout);
    defer std.testing.allocator.free(changed.stderr);
    try std.testing.expectEqual(@as(u8, 1), changed.term.exited);
}

test "project manifest can build and run with companion C source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirMakePath(tmp.dir, "native/include");

    {
        const file = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\extern {
            \\    c("helper") fn helper(): c_int;
            \\}
            \\
            \\fn main(): i32 {
            \\    return helper() as i32;
            \\}
            \\
        );
    }
    {
        const header = try compat.dirCreateFile(tmp.dir, "native/include/helper.h", .{});
        defer compat.closeFile(header);
        try compat.fileWriteAll(header,
            \\#define HELPER_VALUE 11
            \\
        );
    }
    {
        const source = try compat.dirCreateFile(tmp.dir, "native/helper.c", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source,
            \\#include "helper.h"
            \\int helper(void) { return HELPER_VALUE; }
            \\
        );
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "with-c"
            \\type = "exe"
            \\entry = "src/main.cy"
            \\
            \\[c]
            \\sources = ["native/helper.c"]
            \\include_paths = ["native/include"]
            \\
        );
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    try expectCommandReportedProgramExit(&.{ "zig", "build", "run", "--", "run", root }, 11);
}

test "explicit manifest entry build path keeps companion C symbol imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const file = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
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
        );
    }
    {
        const source = try compat.dirCreateFile(tmp.dir, "native.c", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source,
            \\int marker = 42;
            \\
        );
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "symbols"
            \\entry = "src/main.cy"
            \\
            \\[c]
            \\sources = ["native.c"]
            \\
        );
    }

    const entry_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "src/main.cy");
    defer std.testing.allocator.free(entry_path);
    try expectCommandReportedProgramExit(&.{ "zig", "build", "run", "--", "run", entry_path }, 42);
}

test "project manifest can link prebuilt static library" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirMakePath(tmp.dir, "native/lib");

    {
        const file = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\extern {
            \\    c("helper") fn helper(): c_int;
            \\}
            \\
            \\fn main(): i32 {
            \\    return helper() as i32;
            \\}
            \\
        );
    }
    {
        const source = try compat.dirCreateFile(tmp.dir, "native/helper.c", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source,
            \\int helper(void) { return 21; }
            \\
        );
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "with-lib"
            \\type = "exe"
            \\entry = "src/main.cy"
            \\
            \\[link]
            \\libs = ["helper"]
            \\search_paths = ["native/lib"]
            \\
        );
    }

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

    {
        const file = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\extern {
            \\    c("helper") fn helper(): c_int;
            \\}
            \\
            \\fn main(): i32 {
            \\    return helper() as i32;
            \\}
            \\
        );
    }
    {
        const source = try compat.dirCreateFile(tmp.dir, "native/helper.S", .{});
        defer compat.closeFile(source);
        try compat.fileWriteAll(source,
            \\.text
            \\.globl _helper
            \\_helper:
            \\    mov w0, #13
            \\    ret
            \\
        );
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "with-asm"
            \\type = "exe"
            \\entry = "src/main.cy"
            \\
            \\[asm]
            \\sources = ["native/helper.S"]
            \\
        );
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    try expectCommandReportedProgramExit(&.{ "zig", "build", "run", "--", "run", root }, 13);
}

test "explicit manifest entry build path keeps freestanding staticlib flow for raw pointer rebinding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const file = try compat.dirCreateFile(tmp.dir, "src/lib.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\struct UartRegs {
            \\    dr: u32;
            \\}
            \\
            \\export c("uart0_base") fn uart0_base(): c_size_t {
            \\    unchecked {
            \\        return (0x40001000 as! *volatile UartRegs) as! c_size_t;
            \\    }
            \\}
            \\
        );
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "firmware"
            \\type = "staticlib"
            \\entry = "src/lib.cy"
            \\
            \\[build]
            \\target = "aarch64-none-elf"
            \\
        );
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    try expectCommandExitedZero(&.{ "zig", "build", "run", "--", "build", root });
    const archive_path = try std.fs.path.join(std.testing.allocator, &.{ root, "build", "libfirmware.a" });
    defer std.testing.allocator.free(archive_path);
    try compat.access(archive_path, .{});
}

test "riscv64 freestanding executable links compiler-rt builtins for integer remainder" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const file = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\var sink: usize = 0;
            \\
            \\export c("cyna_entry") fn cyna_entry(): void {
            \\    var value: usize = sink + 123;
            \\    var divisor: usize = sink + 10;
            \\    sink = value % divisor;
            \\}
            \\
        );
    }
    {
        const linker = try compat.dirCreateFile(tmp.dir, "link.ld", .{});
        defer compat.closeFile(linker);
        try compat.fileWriteAll(linker,
            \\ENTRY(cyna_entry)
            \\
            \\SECTIONS
            \\{
            \\  . = 0x80000000;
            \\  .text : { *(.text*) *(.rodata*) }
            \\  .data : { *(.data*) }
            \\  .bss (NOLOAD) : { *(.bss*) *(COMMON) }
            \\}
            \\
        );
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "riscv-builtins"
            \\entry = "src/main.cy"
            \\
            \\[build]
            \\target = "riscv64-none-elf"
            \\cpu = "generic-rv64"
            \\emit = ["elf"]
            \\
            \\[link]
            \\script = "link.ld"
            \\entry_symbol = "cyna_entry"
            \\
        );
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    try expectCommandExitedZero(&.{ "zig", "build", "run", "--", "build", root });
    const elf_path = try std.fs.path.join(std.testing.allocator, &.{ root, "build", "riscv-builtins.elf" });
    defer std.testing.allocator.free(elf_path);
    try compat.access(elf_path, .{});
}

test "riscv64 freestanding executable links aggregate memory clear support" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");

    {
        const file = try compat.dirCreateFile(tmp.dir, "src/main.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\struct PageSet {
            \\    live: [32]bool;
            \\    owners: [32]usize;
            \\    count: usize;
            \\}
            \\
            \\var pages: PageSet = PageSet {
            \\    live: [false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false],
            \\    owners: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            \\    count: 0,
            \\};
            \\var sink: usize = 0;
            \\
            \\fn clear_pages(pages: &PageSet): void {
            \\    pages.count = 0;
            \\}
            \\
            \\export c("cyna_entry") fn cyna_entry(): void {
            \\    pages.live[0] = true;
            \\    pages.owners[0] = 42;
            \\    pages.count = pages.count + 1;
            \\    clear_pages(&pages);
            \\    sink = pages.owners[0] + pages.count;
            \\}
            \\
        );
    }
    {
        const linker = try compat.dirCreateFile(tmp.dir, "link.ld", .{});
        defer compat.closeFile(linker);
        try compat.fileWriteAll(linker,
            \\ENTRY(cyna_entry)
            \\
            \\SECTIONS
            \\{
            \\  . = 0x80000000;
            \\  .text : { *(.text*) *(.rodata*) }
            \\  .data : { *(.data*) }
            \\  .bss (NOLOAD) : { *(.bss*) *(COMMON) }
            \\}
            \\
        );
    }
    {
        const manifest = try compat.dirCreateFile(tmp.dir, "cyna.toml", .{});
        defer compat.closeFile(manifest);
        try compat.fileWriteAll(manifest,
            \\name = "riscv-aggregate-clear"
            \\entry = "src/main.cy"
            \\
            \\[build]
            \\target = "riscv64-none-elf"
            \\cpu = "generic-rv64"
            \\emit = ["elf"]
            \\
            \\[link]
            \\script = "link.ld"
            \\entry_symbol = "cyna_entry"
            \\
        );
    }

    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    try expectCommandExitedZero(&.{ "zig", "build", "run", "--", "build", root });
    const elf_path = try std.fs.path.join(std.testing.allocator, &.{ root, "build", "riscv-aggregate-clear.elf" });
    defer std.testing.allocator.free(elf_path);
    try compat.access(elf_path, .{});
}

test "clean removes convention-based project build directory" {
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
    const stem = std.fs.path.basename(root);
    const artifact = try std.fs.path.join(std.testing.allocator, &.{ root, "build", stem });
    defer std.testing.allocator.free(artifact);

    try expectCommandExitedZero(&.{ "zig", "build", "run", "--", "build", root });
    try compat.access(artifact, .{});

    try expectCommandExitedZero(&.{ "zig", "build", "run", "--", "clean", root });
    try std.testing.expectError(error.FileNotFound, compat.access(artifact, .{}));
}

test "clean removes single-file emitted artifacts" {
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
    const sir_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.sir", .{base});
    defer std.testing.allocator.free(sir_path);

    try expectCommandExitedZero(&.{ "zig", "build", "run", "--", "build", source_path, "--emit-sir" });
    try compat.access(sir_path, .{});

    try expectCommandExitedZero(&.{ "zig", "build", "run", "--", "clean", source_path });
    try std.testing.expectError(error.FileNotFound, compat.access(sir_path, .{}));
}

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

test "build emits exported asm constants" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "trap_frame.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\c struct TrapFrame {
            \\    x0: c_ulong;
            \\    x1: c_ulong;
            \\}
            \\
            \\export asm("TF_X1") const trap_frame_x1: usize = comptime TrapFrame.field.x1.offset;
            \\
        );
    }

    const tmp_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(tmp_root);
    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "trap_frame.cy");
    defer std.testing.allocator.free(source_path);
    const output_base = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "trap_frame" });
    defer std.testing.allocator.free(output_base);

    try expectCommandExitedZero(&.{ "zig", "build", "run", "--", "build", source_path, "--emit-asm-include", "--output", output_base });

    const asm_include_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.asm.inc", .{output_base});
    defer std.testing.allocator.free(asm_include_path);
    const asm_include_text = try compat.readFileAlloc(std.testing.allocator, asm_include_path, 64 * 1024);
    defer std.testing.allocator.free(asm_include_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_include_text, ".equ TF_X1, 8") != null);
}

test "build lowers unqualified calls in their resolved module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "src/a");
    try compat.dirMakePath(tmp.dir, "src/b");

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "module_call_resolution"
        \\src = "src"
        \\entry = "src/main.cy"
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/a/mod.cy", .data =
        \\extern c("sink4") fn arch_activate_identity_vm(a: c_ulong, b: c_ulong, c: c_ulong, d: c_ulong): void;
        \\
        \\pub fn run(): void {
        \\    arch_activate_identity_vm(1 as c_ulong, 2 as c_ulong, 3 as c_ulong, 4 as c_ulong);
        \\}
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/b/mod.cy", .data =
        \\extern c("sink1") fn arch_activate_identity_vm(a: c_ulong): void;
        \\
        \\pub fn run(): void {
        \\    arch_activate_identity_vm(1 as c_ulong);
        \\}
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
        \\import .a.mod as a;
        \\import .b.mod as b;
        \\
        \\fn main(): i32 {
        \\    a.run();
        \\    b.run();
        \\    return 0;
        \\}
        \\
    });

    const tmp_root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(tmp_root);

    const output_base = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "resolved" });
    defer std.testing.allocator.free(output_base);
    try expectCommandExitedZero(&.{ "zig", "build", "run", "--", "build", tmp_root, "--emit-ll", "--output", output_base });
    const llvm_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.ll", .{output_base});
    defer std.testing.allocator.free(llvm_path);
    const llvm_text = try compat.readFileAlloc(std.testing.allocator, llvm_path, 4 * 1024 * 1024);
    defer std.testing.allocator.free(llvm_text);
    try std.testing.expect(std.mem.indexOf(u8, llvm_text, "call void @sink4(i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_text, "call void @sink1(i64") != null);
}

test "build emit-obj does not require main or link a native artifact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "isp.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\pub fn init_sensor(): void {
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "isp.cy");
    defer std.testing.allocator.free(source_path);
    const base = try std.fs.path.join(std.testing.allocator, &.{ std.fs.path.dirname(source_path) orelse ".", "isp" });
    defer std.testing.allocator.free(base);

    const header_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.h", .{base});
    defer std.testing.allocator.free(header_path);
    const object_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.o", .{base});
    defer std.testing.allocator.free(object_path);
    const native_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.native", .{base});
    defer std.testing.allocator.free(native_path);

    const result = try runCommand(&.{
        "zig",
        "build",
        "run",
        "--",
        "build",
        source_path,
        "--emit-c-header",
        "--emit-obj",
    });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try compat.access(header_path, .{});
    try compat.access(object_path, .{});
    try std.testing.expectError(error.FileNotFound, compat.access(native_path, .{}));
    try expectStderrContains(result.stderr, "wrote object file to");
    try expectStderrNotContains(result.stderr, "wrote native artifact to");
}

test "build emit-c-header preserves strict C pointer qualifiers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try compat.dirCreateFile(tmp.dir, "abi_header.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file,
            \\export c("inspect_name") fn inspect_name(name: c_str, out: **const c_char): c_int {
            \\    return 0;
            \\}
            \\
            \\export c("inspect_bytes") fn inspect_bytes(data: *const c_uchar, len: c_size_t): c_int {
            \\    return 0;
            \\}
            \\
            \\export c("replace_name") fn replace_name(slot: *const *c_char): c_int {
            \\    return 0;
            \\}
            \\
        );
    }

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "abi_header.cy");
    defer std.testing.allocator.free(source_path);
    const output_base = try std.fs.path.join(std.testing.allocator, &.{ std.fs.path.dirname(source_path) orelse ".", "abi_header" });
    defer std.testing.allocator.free(output_base);
    const header_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.h", .{output_base});
    defer std.testing.allocator.free(header_path);

    const result = try runCommand(&.{
        "zig",
        "build",
        "run",
        "--",
        "build",
        source_path,
        "--emit-c-header",
        "--output",
        output_base,
    });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    const header_text = try compat.readFileAlloc(std.testing.allocator, header_path, 64 * 1024);
    defer std.testing.allocator.free(header_text);

    try std.testing.expect(std.mem.indexOf(u8, header_text, "#include <cyna.h>") != null);
    try std.testing.expect(std.mem.indexOf(u8, header_text, "int inspect_name(const char *name, const char **out);") != null);
    try std.testing.expect(std.mem.indexOf(u8, header_text, "int inspect_bytes(const unsigned char *data, size_t len);") != null);
    try std.testing.expect(std.mem.indexOf(u8, header_text, "int replace_name(char * const *slot);") != null);
}

test "check presents collection ownership instantiation at user and definition sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\struct Key {
        \\    id: i32;
        \\    values: List<i32>;
        \\}
        \\impl Key: Eq {
        \\    fn eq(self: &const Key, other: &const Key): bool {
        \\        return self.id == other.id;
        \\    }
        \\}
        \\fn main(): i32 {
        \\    var values: Map<Key, i32> = map<Key, i32>();
        \\    const keys = values.keys();
        \\    return keys.len() as i32;
        \\}
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);
    const user_diagnostic = try std.fmt.allocPrint(std.testing.allocator, "{s}:12:", .{source_path});
    defer std.testing.allocator.free(user_diagnostic);
    const bogus_user_definition = try std.fmt.allocPrint(std.testing.allocator, "{s}:646:", .{source_path});
    defer std.testing.allocator.free(bogus_user_definition);

    const result = try runCommand(&.{ "zig", "build", "run", "--", "check", source_path });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try expectStderrContains(result.stderr, user_diagnostic);
    try expectStderrContains(result.stderr, "method `keys` is unavailable for receiver");
    try expectStderrContains(result.stderr, "packages/std/src/std_prelude.cy:");
    try expectStderrNotContains(result.stderr, bogus_user_definition);
}

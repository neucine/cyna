const std = @import("std");
const compat = @import("cyna").compat;

const test_exec = @import("../support.zig");

const expectCommandExitedZero = test_exec.expectCommandExitedZero;

test "explicit manifest entry build path keeps freestanding staticlib flow for raw pointer rebinding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/lib.cy", .data =
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
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "firmware"
        \\type = "staticlib"
        \\entry = "src/lib.cy"
        \\
        \\[build]
        \\target = "aarch64-none-elf"
        \\
    });
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
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
        \\var sink: usize = 0;
        \\
        \\export c("cyna_entry") fn cyna_entry(): void {
        \\    var value: usize = sink + 123;
        \\    var divisor: usize = sink + 10;
        \\    sink = value % divisor;
        \\}
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "link.ld", .data =
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
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
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
    });
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
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/main.cy", .data =
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
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "link.ld", .data =
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
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
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
    });
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    try expectCommandExitedZero(&.{ "zig", "build", "run", "--", "build", root });
    const elf_path = try std.fs.path.join(std.testing.allocator, &.{ root, "build", "riscv-aggregate-clear.elf" });
    defer std.testing.allocator.free(elf_path);
    try compat.access(elf_path, .{});
}

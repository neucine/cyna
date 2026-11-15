const std = @import("std");
const compat = @import("cyna").compat;

const test_exec = @import("../support.zig");

const expectCommandExitedZero = test_exec.expectCommandExitedZero;

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

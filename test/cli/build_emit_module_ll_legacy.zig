const std = @import("std");
const compat = @import("cyna").compat;

const test_exec = @import("../support.zig");

const expectCommandExitedZero = test_exec.expectCommandExitedZero;

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

test "static library declares a cross-module C export in its caller" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "src");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "cross_module_c_export"
        \\src = "src"
        \\type = "staticlib"
        \\entry = "src/lib.cy"
        \\
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/exposure.cy", .data =
        \\pub export c("expose") fn expose(value: c_float): c_float { return value; }
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "src/lib.cy", .data =
        \\import .exposure;
        \\pub export c("render") fn render(value: c_float): c_float {
        \\    return exposure.expose(value);
        \\}
    });
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(root);
    const archive = try std.fs.path.join(std.testing.allocator, &.{ root, "libcross_module_c_export.a" });
    defer std.testing.allocator.free(archive);
    try expectCommandExitedZero(&.{ "zig", "build", "run", "--", "build", root, "--emit-c-header", "--output", archive });
    try compat.access(archive, .{});
    const header = try std.fmt.allocPrint(std.testing.allocator, "{s}.h", .{archive});
    defer std.testing.allocator.free(header);
    try compat.access(header, .{});
}

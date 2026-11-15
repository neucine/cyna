const std = @import("std");
const compat = @import("cyna").compat;

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

    const result = try testExecRunCommand(&.{
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

const test_exec = @import("../support.zig");
const testExecRunCommand = test_exec.runCommand;

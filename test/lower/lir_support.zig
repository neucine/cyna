const std = @import("std");

const cyna = @import("cyna");
const compat = cyna.compat;
const compiler = cyna.compiler;
const loader = compiler.loader;
const sema = compiler.sema;
const lowerModule = compiler.lower.lowerModule;

pub fn lowerLirText(allocator: std.mem.Allocator, path: []const u8, source: []const u8) ![]u8 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "tmp"
        \\src = "."
        \\
        ,
    });
    if (std.fs.path.dirname(path)) |dir_name| {
        try compat.dirMakePath(tmp.dir, dir_name);
    }
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = path, .data = source });

    const tmp_root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
    defer allocator.free(tmp_root);
    const root_path = try std.fs.path.join(allocator, &.{ tmp_root, path });
    defer allocator.free(root_path);

    var loaded = try loader.loadProgramWithOptions(allocator, root_path, .{
        .allow_test_root = std.mem.endsWith(u8, path, ".test.cy"),
    });
    defer loaded.deinit(allocator);

    const sir_module = try sema.buildSir(allocator, root_path, loaded.program);
    defer sir_module.deinit(allocator);

    const lir_module = try lowerModule(allocator, sir_module);
    defer lir_module.deinit(allocator);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var out_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    try lir_module.dump(&out_writer.writer);
    out = out_writer.toArrayList();
    return out.toOwnedSlice(allocator);
}

pub fn lowerLirFileText(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var loaded = try loader.loadProgram(allocator, path);
    defer loaded.deinit(allocator);

    const sir_module = try sema.buildSir(allocator, path, loaded.program);
    defer sir_module.deinit(allocator);

    const lir_module = try lowerModule(allocator, sir_module);
    defer lir_module.deinit(allocator);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var out_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    try lir_module.dump(&out_writer.writer);
    out = out_writer.toArrayList();
    return out.toOwnedSlice(allocator);
}

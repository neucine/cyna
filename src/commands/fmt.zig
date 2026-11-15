const std = @import("std");
const compat = @import("../compat.zig");
const formatter = @import("../formatter.zig");
const diagnostics = @import("../compiler/diagnostics.zig");

pub const Options = struct { check: bool = false, report_changes: bool = true };
pub const Outcome = struct { changed: usize = 0, failed: usize = 0 };

/// Visit explicit files or recursively visit .cy files in a directory. Generated,
/// hidden, and dependency directories and symlink entries are not traversed.
pub fn formatPaths(allocator: std.mem.Allocator, paths: []const []const u8, options: Options, context: *diagnostics.Context) !Outcome {
    var outcome: Outcome = .{};
    if (paths.len == 0) {
        try visit(allocator, ".", options, context, &outcome);
    } else for (paths) |path| try visit(allocator, path, options, context, &outcome);
    return outcome;
}

fn visit(allocator: std.mem.Allocator, path: []const u8, options: Options, context: *diagnostics.Context, outcome: *Outcome) anyerror!void {
    const stat = compat.cwd().statFile(compat.io(), path, .{ .follow_symlinks = false }) catch |err| {
        outcome.failed += 1;
        try context.emitPath(path, @errorName(err));
        return;
    };
    if (stat.kind == .sym_link) {
        outcome.failed += 1;
        try context.emitPath(path, "fmt does not follow symlink inputs; pass the source path directly");
        return;
    }
    if (stat.kind != .file and stat.kind != .directory) {
        outcome.failed += 1;
        try context.emitPath(path, "fmt expects a regular file or directory");
        return;
    }
    var dir = compat.openDir(path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return formatFile(allocator, path, options, context, outcome),
        else => {
            outcome.failed += 1;
            try context.emitPath(path, @errorName(err));
            return;
        },
    };
    defer compat.closeDir(dir);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var iterator = dir.iterate();
    while (try compat.dirIteratorNext(&iterator)) |entry| {
        const include = switch (entry.kind) {
            .file => std.mem.endsWith(u8, entry.name, ".cy"),
            .directory => !skipDirectory(entry.name),
            else => false,
        };
        if (include) try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    for (names.items) |name| {
        const child = try std.fs.path.join(allocator, &.{ path, name });
        defer allocator.free(child);
        try visit(allocator, child, options, context, outcome);
    }
}

fn skipDirectory(name: []const u8) bool {
    return std.mem.startsWith(u8, name, ".") or
        std.mem.eql(u8, name, "build") or std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "dist") or std.mem.eql(u8, name, "node_modules");
}

fn formatFile(allocator: std.mem.Allocator, path: []const u8, options: Options, context: *diagnostics.Context, outcome: *Outcome) !void {
    if (!std.mem.endsWith(u8, path, ".cy")) {
        outcome.failed += 1;
        try context.emitPath(path, "fmt expects a .cy file or directory");
        return;
    }
    const source = compat.readFileAlloc(allocator, path, 32 * 1024 * 1024) catch |err| {
        outcome.failed += 1;
        try context.emitPath(path, @errorName(err));
        return;
    };
    defer allocator.free(source);
    const formatted = formatter.format(allocator, path, source, context) catch |err| {
        outcome.failed += 1;
        if (err != error.ParseFailed) try context.emitPath(path, @errorName(err));
        return;
    };
    defer allocator.free(formatted);
    if (std.mem.eql(u8, source, formatted)) return;
    if (!options.check) {
        replaceFile(path, formatted) catch |err| {
            outcome.failed += 1;
            try context.emitPath(path, @errorName(err));
            return;
        };
    }
    outcome.changed += 1;
    if (options.report_changes) std.debug.print("{s}\n", .{path});
}

fn replaceFile(path: []const u8, bytes: []const u8) !void {
    const original = try compat.openFile(path, .{});
    defer compat.closeFile(original);
    const stat = try original.stat(compat.io());
    var file = try compat.cwd().createFileAtomic(compat.io(), path, .{
        .replace = true,
        .permissions = stat.permissions,
    });
    defer file.deinit(compat.io());
    try file.file.setPermissions(compat.io(), stat.permissions);
    try compat.fileWriteAll(file.file, bytes);
    try file.file.sync(compat.io());
    try file.replace(compat.io());
}

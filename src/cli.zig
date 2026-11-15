const std = @import("std");
const check_mod = @import("commands/check.zig");
const run_mod = @import("commands/run.zig");
const test_mod = @import("commands/test.zig");

pub const CheckOptions = check_mod.CheckOptions;
pub const RunOptions = run_mod.RunOptions;
pub const TestOptions = test_mod.TestOptions;

pub const PathAndArgs = struct {
    path: ?[]const u8,
    rest: []const []const u8,
};

pub fn parseRunOptions(allocator: std.mem.Allocator, args: []const []const u8) !RunOptions {
    var options: RunOptions = .{};
    var passthrough: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer passthrough.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            try passthrough.appendSlice(allocator, args[i + 1 ..]);
            break;
        } else {
            return error.UnknownOption;
        }
    }

    options.argv = try passthrough.toOwnedSlice(allocator);
    return options;
}

pub fn parseTestOptions(args: []const []const u8) !TestOptions {
    var options: TestOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            options.filter = args[i];
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            options.jobs = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidOptionValue;
            if (options.jobs == 0) return error.InvalidOptionValue;
        } else if (std.mem.eql(u8, arg, "--timings")) {
            options.timings = true;
        } else {
            return error.UnknownOption;
        }
    }
    return options;
}

pub fn parseCheckOptions(args: []const []const u8) !CheckOptions {
    var options: CheckOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--build")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            options.build_config = args[i];
        } else if (std.mem.eql(u8, arg, "--diagnostic-format")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            if (std.mem.eql(u8, args[i], "compact")) {
                options.diagnostic_format = .compact;
            } else if (std.mem.eql(u8, args[i], "human")) {
                options.diagnostic_format = .human;
            } else {
                return error.InvalidOptionValue;
            }
        } else {
            return error.UnknownOption;
        }
    }
    return options;
}

pub fn splitPathAndArgs(args: []const []const u8) PathAndArgs {
    if (args.len == 0) return .{ .path = null, .rest = args };
    const first = args[0];
    if (std.mem.startsWith(u8, first, "--")) {
        return .{ .path = null, .rest = args };
    }
    return .{ .path = first, .rest = args[1..] };
}

test "parse run options forwards passthrough args" {
    const options = try parseRunOptions(std.testing.allocator, &.{
        "--",
        "alpha",
        "beta",
    });
    defer std.testing.allocator.free(options.argv);

    try std.testing.expectEqual(@as(usize, 2), options.argv.len);
    try std.testing.expectEqualStrings("alpha", options.argv[0]);
    try std.testing.expectEqualStrings("beta", options.argv[1]);
}

test "parse test options accepts a bounded worker count" {
    const options = try parseTestOptions(&.{ "--filter", "math", "--jobs", "4", "--timings" });
    try std.testing.expectEqualStrings("math", options.filter.?);
    try std.testing.expectEqual(@as(usize, 4), options.jobs);
    try std.testing.expect(options.timings);
}

test "parse test options rejects zero workers" {
    try std.testing.expectError(error.InvalidOptionValue, parseTestOptions(&.{ "--jobs", "0" }));
}

test "parse check options selects a diagnostic format" {
    try std.testing.expectEqual(.human, (try parseCheckOptions(&.{})).diagnostic_format);
    const human = try parseCheckOptions(&.{ "--build", "debug", "--diagnostic-format", "human" });
    try std.testing.expectEqualStrings("debug", human.build_config.?);
    try std.testing.expectEqual(.human, human.diagnostic_format);

    const compact = try parseCheckOptions(&.{ "--diagnostic-format", "compact" });
    try std.testing.expectEqual(.compact, compact.diagnostic_format);
    try std.testing.expectError(
        error.InvalidOptionValue,
        parseCheckOptions(&.{ "--diagnostic-format", "json" }),
    );
}

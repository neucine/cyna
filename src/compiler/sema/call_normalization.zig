const std = @import("std");
const ast = @import("../parser/ast.zig");

pub const Parameter = struct {
    name: []const u8,
    has_default: bool = false,
};

pub const Argument = struct {
    name: ?[]const u8 = null,
};

pub const Error = error{
    UnknownName,
    DuplicateArgument,
    MissingArgument,
    PositionalAfterNamed,
    TooManyArguments,
    NonTrailingDefault,
    UnsupportedDefault,
    OutOfMemory,
};

pub const Mapping = struct {
    parameter_to_argument: []?usize,
    argument_to_parameter: []usize,

    pub fn deinit(self: Mapping, allocator: std.mem.Allocator) void {
        allocator.free(self.parameter_to_argument);
        allocator.free(self.argument_to_parameter);
    }
};

pub const NormalizedCall = struct {
    args: []ast.CallArg,
    evaluation_order: []u32,

    pub fn deinit(self: NormalizedCall, allocator: std.mem.Allocator) void {
        allocator.free(self.args);
        allocator.free(self.evaluation_order);
    }
};

pub fn normalizeCall(
    allocator: std.mem.Allocator,
    parameters: []const ast.Param,
    arguments: []const ast.CallArg,
) Error!NormalizedCall {
    const normalized_parameters = try allocator.alloc(Parameter, parameters.len);
    defer allocator.free(normalized_parameters);
    const normalized_arguments = try allocator.alloc(Argument, arguments.len);
    defer allocator.free(normalized_arguments);

    var saw_default = false;
    for (parameters, 0..) |parameter, index| {
        const has_default = parameter.default_value != null;
        if (has_default) {
            if (!defaultExpressionSupported(parameter.default_value.?)) return error.UnsupportedDefault;
            saw_default = true;
        } else if (saw_default) {
            return error.NonTrailingDefault;
        }
        normalized_parameters[index] = .{
            .name = parameter.name,
            .has_default = has_default,
        };
    }
    for (arguments, 0..) |argument, index| {
        normalized_arguments[index] = .{ .name = argument.name };
    }

    const mapping = try mapArguments(allocator, normalized_parameters, normalized_arguments);
    defer mapping.deinit(allocator);

    const slots = try allocator.alloc(ast.CallArg, parameters.len);
    errdefer allocator.free(slots);
    for (parameters, mapping.parameter_to_argument, 0..) |parameter, source_index, parameter_index| {
        slots[parameter_index] = if (source_index) |source|
            arguments[source]
        else
            .{ .value = parameter.default_value.? };
    }

    const evaluation_order = try allocator.alloc(u32, parameters.len);
    errdefer allocator.free(evaluation_order);
    var cursor: usize = 0;
    for (mapping.argument_to_parameter) |parameter_index| {
        evaluation_order[cursor] = @intCast(parameter_index);
        cursor += 1;
    }
    for (mapping.parameter_to_argument, 0..) |source, parameter_index| {
        if (source != null) continue;
        evaluation_order[cursor] = @intCast(parameter_index);
        cursor += 1;
    }
    return .{
        .args = slots,
        .evaluation_order = evaluation_order,
    };
}

pub fn mapArguments(
    allocator: std.mem.Allocator,
    parameters: []const Parameter,
    arguments: []const Argument,
) Error!Mapping {
    const parameter_to_argument = try allocator.alloc(?usize, parameters.len);
    errdefer allocator.free(parameter_to_argument);
    @memset(parameter_to_argument, null);
    const argument_to_parameter = try allocator.alloc(usize, arguments.len);
    errdefer allocator.free(argument_to_parameter);

    var next_positional: usize = 0;
    var saw_named = false;
    for (arguments, 0..) |argument, argument_index| {
        const parameter_index = if (argument.name) |name| blk: {
            saw_named = true;
            for (parameters, 0..) |parameter, index| {
                if (std.mem.eql(u8, parameter.name, name)) break :blk index;
            }
            return error.UnknownName;
        } else blk: {
            if (saw_named) return error.PositionalAfterNamed;
            if (next_positional >= parameters.len) return error.TooManyArguments;
            defer next_positional += 1;
            break :blk next_positional;
        };
        if (parameter_to_argument[parameter_index] != null) return error.DuplicateArgument;
        parameter_to_argument[parameter_index] = argument_index;
        argument_to_parameter[argument_index] = parameter_index;
    }
    for (parameters, parameter_to_argument) |parameter, source| {
        if (source == null and !parameter.has_default) return error.MissingArgument;
    }
    return .{
        .parameter_to_argument = parameter_to_argument,
        .argument_to_parameter = argument_to_parameter,
    };
}

/// Defaults are inserted at the call site, so only expressions that do not
/// resolve caller names and cannot fail or allocate are safe in this slice.
pub fn defaultExpressionSupported(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .int, .float, .rune, .string, .bool, .none, .enum_case => true,
        .unary => |unary| switch (unary.op) {
            .negate => switch (unary.expr.*) {
                .int, .float => true,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

test "reordered names preserve source order and positional slots" {
    const parameters = [_]Parameter{
        .{ .name = "path" },
        .{ .name = "max_bytes", .has_default = true },
        .{ .name = "retry", .has_default = true },
    };
    const arguments = [_]Argument{
        .{ .name = "retry" },
        .{ .name = "path" },
    };
    const mapping = try mapArguments(std.testing.allocator, &parameters, &arguments);
    defer mapping.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(usize, &.{ 2, 0 }, mapping.argument_to_parameter);
    try std.testing.expectEqualSlices(?usize, &.{ 1, null, 0 }, mapping.parameter_to_argument);
}

test "invalid calls are rejected before evaluation" {
    const parameters = [_]Parameter{ .{ .name = "path" }, .{ .name = "retry", .has_default = true } };
    try std.testing.expectError(error.UnknownName, mapArguments(std.testing.allocator, &parameters, &.{.{ .name = "missing" }}));
    try std.testing.expectError(error.DuplicateArgument, mapArguments(std.testing.allocator, &parameters, &.{ .{}, .{ .name = "path" } }));
    try std.testing.expectError(error.MissingArgument, mapArguments(std.testing.allocator, &parameters, &.{.{ .name = "retry" }}));
    try std.testing.expectError(error.PositionalAfterNamed, mapArguments(std.testing.allocator, &parameters, &.{ .{ .name = "path" }, .{} }));
}

test "only literal-shaped defaults are accepted" {
    var literal: ast.Expr = .{ .int = .{ .token = undefined, .value = 1 } };
    var negative: ast.Expr = .{ .unary = .{
        .op = .negate,
        .expr = &literal,
    } };
    var name: ast.Expr = .{ .name = .{ .token = undefined, .text = "other" } };

    try std.testing.expect(defaultExpressionSupported(&literal));
    try std.testing.expect(defaultExpressionSupported(&negative));
    var enum_case: ast.Expr = .{ .enum_case = .{
        .type_name = "Mode",
        .case_name = "read",
        .token = undefined,
    } };

    try std.testing.expect(defaultExpressionSupported(&enum_case));
    try std.testing.expect(!defaultExpressionSupported(&name));
}

fn normalizeOomFixture(
    allocator: std.mem.Allocator,
    parameters: []const ast.Param,
    arguments: []const ast.CallArg,
) !void {
    const result = try normalizeCall(allocator, parameters, arguments);
    result.deinit(allocator);
}

test "normalization releases slots under allocation failure" {
    var default_value: ast.Expr = .{ .int = .{ .token = undefined, .value = 2 } };
    var argument_value: ast.Expr = .{ .int = .{ .token = undefined, .value = 1 } };
    const parameters = [_]ast.Param{
        .{ .name = "first", .type_name = .{ .name = "i32", .args = &.{}, .token = undefined }, .name_token = undefined },
        .{ .name = "second", .type_name = .{ .name = "i32", .args = &.{}, .token = undefined }, .default_value = &default_value, .name_token = undefined },
    };
    const arguments = [_]ast.CallArg{
        .{ .value = &argument_value, .name = "second", .name_token = undefined },
        .{ .value = &argument_value, .name = "first", .name_token = undefined },
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        normalizeOomFixture,
        .{ &parameters, &arguments },
    );
}

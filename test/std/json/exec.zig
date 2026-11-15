const std = @import("std");

const helpers = @import("../../helpers.zig");

fn bytesLiteral(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (text, 0..) |byte, index| {
        if (index != 0) try out.append(allocator, ',');
        var buffer: [16]u8 = undefined;
        const rendered = try std.fmt.bufPrint(&buffer, "{d}", .{byte});
        try out.appendSlice(allocator, rendered);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

test "std.json round-trips nested values and exposes ordered accessors" {
    const allocator = std.testing.allocator;
    const json_text = "{\"name\":\"Ada\",\"items\":[true,null,1.5e2],\"nested\":{\"x\":-0}}";
    const input = try bytesLiteral(allocator, json_text);
    defer allocator.free(input);
    const expected = try bytesLiteral(allocator, json_text);
    defer allocator.free(expected);

    const source = try std.fmt.allocPrint(allocator,
        \\import std.json;
        \\
        \\fn owned(raw: []const u8): string {{
        \\    return string.from(raw);
        \\}}
        \\
        \\fn main(): i32 {{
        \\    var input: [:]u8 = {s};
        \\    var expected: [:]u8 = {s};
        \\    const value = json.parse(owned(input[..])) catch (problem) {{
        \\        return (problem as i32) + 10;
        \\    }};
        \\        const encoded = json.encode(&value);
        \\        if encoded != owned(expected[..]) {{
        \\            return 1;
        \\        }}
        \\        switch value {{
        \\        .object(object) => {{
        \\            if object.len() != 3 {{
        \\                return 2;
        \\            }}
        \\            if not object.contains("items") {{
        \\                return 3;
        \\            }}
        \\            switch object["name"] {{
        \\            .string(name) => {{
        \\                if name != "Ada" {{
        \\                    return 4;
        \\                }}
        \\            }}
        \\            _ => {{
        \\                return 5;
        \\            }}
        \\            }}
        \\            switch object["items"] {{
        \\            .array(items) => {{
        \\                if items.len() != 3 {{
        \\                    return 6;
        \\                }}
        \\                switch items[1] {{
        \\                .null_value => {{
        \\                }}
        \\                _ => {{
        \\                    return 7;
        \\                }}
        \\                }}
        \\            }}
        \\            _ => {{
        \\                return 8;
        \\            }}
        \\            }}
        \\        }}
        \\        _ => {{
        \\            return 9;
        \\        }}
        \\        }}
        \\        return 42;
        \\}}
        \\
    , .{ input, expected });
    defer allocator.free(source);

    try helpers.expectNativeSourceExitCode(allocator, "std_json_roundtrip.cy", source, 42);
}

test "std.json decodes escapes and surrogate pairs" {
    const allocator = std.testing.allocator;
    const input = try bytesLiteral(allocator, "\"a\\u0041\\n\\/\\uD83D\\uDE00\"");
    defer allocator.free(input);
    const expected = try bytesLiteral(allocator, "\"aA\\n/\xF0\x9F\x98\x80\"");
    defer allocator.free(expected);

    const source = try std.fmt.allocPrint(allocator,
        \\import std.json;
        \\
        \\fn owned(raw: []const u8): string {{
        \\    return string.from(raw);
        \\}}
        \\
        \\fn main(): i32 {{
        \\    var input: [:]u8 = {s};
        \\    var expected: [:]u8 = {s};
        \\    const value = json.parse(owned(input[..])) catch (problem) {{
        \\        return (problem as i32) + 10;
        \\    }};
        \\        const encoded = json.encode(&value);
        \\        if encoded != owned(expected[..]) {{
        \\            return 1;
        \\        }}
        \\        return 42;
        \\}}
        \\
    , .{ input, expected });
    defer allocator.free(source);

    try helpers.expectNativeSourceExitCode(allocator, "std_json_escapes.cy", source, 42);
}

test "std.json rejects malformed input without leaks" {
    const allocator = std.testing.allocator;
    const bad_leading_zero = try bytesLiteral(allocator, "01");
    defer allocator.free(bad_leading_zero);
    const duplicate_key = try bytesLiteral(allocator, "{\"a\":1,\"\\u0061\":2}");
    defer allocator.free(duplicate_key);
    const trailing_data = try bytesLiteral(allocator, "true false");
    defer allocator.free(trailing_data);
    const lone_surrogate = try bytesLiteral(allocator, "\"\\uD800\"");
    defer allocator.free(lone_surrogate);
    const control_character = try bytesLiteral(allocator, "\"\n\"");
    defer allocator.free(control_character);

    const source = try std.fmt.allocPrint(allocator,
        \\import std.json;
        \\import {{ Error }} from std.json;
        \\
        \\fn owned(raw: []const u8): string {{
        \\    return string.from(raw);
        \\}}
        \\
        \\fn rejects(raw: []const u8, expected: Error): bool {{
        \\    const value = json.parse(owned(raw)) catch (problem) {{
        \\        return problem == expected;
        \\    }};
        \\        const ignored = value;
        \\        return false;
        \\}}
        \\
        \\fn rejects_bytes(raw: []const u8, expected: Error): bool {{
        \\    const value = json.parse_bytes(raw) catch (problem) {{
        \\        return problem == expected;
        \\    }};
        \\    const ignored = value;
        \\    return false;
        \\}}
        \\
        \\fn validate_rejects(raw: string, expected: Error): bool {{
        \\    json.validate(raw) catch (problem) {{
        \\        return problem == expected;
        \\    }};
        \\    return false;
        \\}}
        \\
        \\fn main(): i32 {{
        \\    var bad_number: [:]u8 = {s};
        \\    if not rejects(bad_number[..], Error.invalid_token) {{
        \\        return 1;
        \\    }}
        \\    var duplicate: [:]u8 = {s};
        \\    if not rejects(duplicate[..], Error.duplicate_key) {{
        \\        return 2;
        \\    }}
        \\    var trailing: [:]u8 = {s};
        \\    if not rejects(trailing[..], Error.trailing_data) {{
        \\        return 3;
        \\    }}
        \\    json.validate("true") catch (problem) {{
        \\        return (problem as i32) + 20;
        \\    }};
        \\    if not validate_rejects(owned(trailing[..]), Error.trailing_data) {{ return 31; }}
        \\    var surrogate: [:]u8 = {s};
        \\    if not rejects(surrogate[..], Error.invalid_unicode) {{
        \\        return 4;
        \\    }}
        \\    var control: [:]u8 = {s};
        \\    if not rejects(control[..], Error.invalid_escape) {{
        \\        return 5;
        \\    }}
        \\
        \\    var deep: List<u8> = list<u8>();
        \\    var index: usize = 0;
        \\    while index < 258 {{
        \\        deep.push(91);
        \\        index = index + 1;
        \\    }}
        \\    index = 0;
        \\    while index < 258 {{
        \\        deep.push(93);
        \\        index = index + 1;
        \\    }}
        \\    if not rejects(deep[..], Error.depth_exceeded) {{
        \\        return 6;
        \\    }}
        \\
        \\    var invalid_utf8: [:]u8 = [34, 255, 34];
        \\    if not rejects_bytes(invalid_utf8[..], Error.invalid_utf8) {{ return 8; }}
        \\    return 42;
        \\}}
        \\
    , .{ bad_leading_zero, duplicate_key, trailing_data, lone_surrogate, control_character });
    defer allocator.free(source);

    try helpers.expectNativeSourceExitCode(allocator, "std_json_errors.cy", source, 42);
}

test "std.json pretty output preserves value order" {
    const allocator = std.testing.allocator;
    const input = try bytesLiteral(allocator, "[1,{\"a\":2}]");
    defer allocator.free(input);
    const expected = try bytesLiteral(allocator, "[\n  1,\n  {\n    \"a\": 2\n  }\n]");
    defer allocator.free(expected);

    const source = try std.fmt.allocPrint(allocator,
        \\import std.json;
        \\
        \\fn owned(raw: []const u8): string {{
        \\    return string.from(raw);
        \\}}
        \\
        \\fn main(): i32 {{
        \\    var input: [:]u8 = {s};
        \\    var expected: [:]u8 = {s};
        \\    const value = json.parse(owned(input[..])) catch (problem) {{
        \\        return (problem as i32) + 10;
        \\    }};
        \\        const pretty = json.encode_pretty(&value);
        \\        if pretty != owned(expected[..]) {{
        \\            return 1;
        \\        }}
        \\        return 42;
        \\}}
        \\
    , .{ input, expected });
    defer allocator.free(source);

    try helpers.expectNativeSourceExitCode(allocator, "std_json_pretty.cy", source, 42);
}

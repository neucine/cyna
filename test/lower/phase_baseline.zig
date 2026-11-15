const std = @import("std");

const compiler = @import("cyna").compiler;
const commands = @import("cyna").commands;
const llvm_backend = @import("cyna").llvm_backend;
const lexer = compiler.lexer;
const lower = compiler.lower;
const parser = compiler.parser;
const sema = compiler.sema;
const sir = compiler.sir;
const generic_origins = compiler.generic_origins;
const lir = compiler.lir;
const compat = @import("cyna").compat;
const loader = compiler.loader;

test "checked origin scalar operators and interpolation use typed children" {
    const allocator = std.testing.allocator;
    const source =
        \\fn arithmetic(value: i32): i32 { return -(value + 2); }
        \\fn formatted(value: i32): string { return $"value: {value}"; }
        \\fn observed(value: i32): i32 {
        \\    assert(value > 0);
        \\    println(value);
        \\    return value;
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "scalar_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "scalar_origin.cy", program);
    defer module.deinit(allocator);
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const concrete = try store.intern(&.{.concrete});
    var visited: usize = 0;
    for (module.functions) |*function| {
        if (!std.mem.eql(u8, function.name, "arithmetic") and !std.mem.eql(u8, function.name, "formatted") and !std.mem.eql(u8, function.name, "observed")) continue;
        visited += 1;
        const parameter = try store.internFact(try adapter.term(function.params[0].type_id.?), origin, &.{});
        var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
        defer prepared.deinit();
        const result = try prepared.run(&store);
        defer result.deinit(allocator);
        try std.testing.expect(result.did_return);
        try std.testing.expectEqual(if (std.mem.eql(u8, function.name, "observed")) origin else concrete, result.returned.?.receiver);
    }
    try std.testing.expectEqual(@as(usize, 3), visited);

    const arithmetic = for (module.functions) |*function| {
        if (std.mem.eql(u8, function.name, "arithmetic")) break function;
    } else return error.TestUnexpectedResult;
    const formatted = for (module.functions) |*function| {
        if (std.mem.eql(u8, function.name, "formatted")) break function;
    } else return error.TestUnexpectedResult;
    const corrupted = try allocator.dupe(sir.ExprMetadataEntry, module.expr_metadata);
    defer allocator.free(corrupted);
    const arithmetic_return = arithmetic.body[0].@"return" orelse return error.TestUnexpectedResult;
    var changed = false;
    for (corrupted) |*entry| {
        if (entry.expr != arithmetic_return) continue;
        entry.metadata.type_id = formatted.return_type_id.?;
        changed = true;
    }
    try std.testing.expect(changed);
    const parameter = try store.internFact(try adapter.term(arithmetic.params[0].type_id.?), origin, &.{});
    var invalid = try generic_origins.PreparedStraightLine.init(allocator, adapter, arithmetic, corrupted, module.structs, module.unions, &.{parameter});
    defer invalid.deinit();
    try std.testing.expectError(error.IncorrectResultType, invalid.run(&store));

    try std.testing.expect(arithmetic_return.* == .unary and arithmetic_return.unary.expr.* == .binary);
    const literal = arithmetic_return.unary.expr.binary.right;
    const bad_literal = try allocator.dupe(sir.ExprMetadataEntry, module.expr_metadata);
    defer allocator.free(bad_literal);
    changed = false;
    for (bad_literal) |*entry| {
        if (entry.expr != literal) continue;
        entry.metadata.type_id = formatted.return_type_id.?;
        changed = true;
    }
    try std.testing.expect(changed);
    var invalid_literal = try generic_origins.PreparedStraightLine.init(allocator, adapter, arithmetic, bad_literal, module.structs, module.unions, &.{parameter});
    defer invalid_literal.deinit();
    try std.testing.expectError(error.IncorrectResultType, invalid_literal.run(&store));

    const formatted_return = formatted.body[0].@"return" orelse return error.TestUnexpectedResult;
    try std.testing.expect(formatted_return.* == .interpolated_string);
    const hole = for (formatted_return.interpolated_string) |part| switch (part) {
        .value => |value| break value.expr,
        .literal => continue,
    } else return error.TestUnexpectedResult;
    const bad_identity = try allocator.dupe(sir.ExprMetadataEntry, module.expr_metadata);
    defer allocator.free(bad_identity);
    changed = false;
    for (bad_identity) |*entry| {
        if (entry.expr != hole) continue;
        entry.metadata.checked_place_root = .{ .binding = arithmetic.params[0].binding_id.? };
        changed = true;
    }
    try std.testing.expect(changed);
    const formatted_parameter = try store.internFact(try adapter.term(formatted.params[0].type_id.?), origin, &.{});
    try std.testing.expectError(error.IncorrectBindingIdentity, generic_origins.PreparedStraightLine.init(allocator, adapter, formatted, bad_identity, module.structs, module.unions, &.{formatted_parameter}));
}

test "checked origin read-only string intrinsics traverse operands" {
    const allocator = std.testing.allocator;
    const source =
        \\fn measure(text: string): usize { return text.len(); }
        \\fn contains(text: string): bool { return text.contains("x"); }
        \\fn find(text: string): ?usize { return text.find("x"); }
        \\fn roundtrip(text: string): string { return string.from(text.bytes()); }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "string_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "string_origin.cy", program);
    defer module.deinit(allocator);
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const concrete = try store.intern(&.{.concrete});
    try std.testing.expectEqual(@as(usize, 4), module.functions.len);
    for (module.functions) |*function| {
        const parameter = try store.internFact(try adapter.term(function.params[0].type_id.?), origin, &.{});
        var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
        defer prepared.deinit();
        const result = try prepared.run(&store);
        defer result.deinit(allocator);
        try std.testing.expect(result.did_return);
        try std.testing.expectEqual(concrete, result.returned.?.receiver);
        if (std.mem.eql(u8, function.name, "find")) {
            const item = result.returned.?.child(.optional_item) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(concrete, item.receiver);
        }
    }
    const roundtrip = for (module.functions) |*function| {
        if (std.mem.eql(u8, function.name, "roundtrip")) break function;
    } else return error.TestUnexpectedResult;
    const returned = roundtrip.body[0].@"return" orelse return error.TestUnexpectedResult;
    try std.testing.expect(returned.* == .string_from and returned.string_from.* == .string_bytes);
    const corrupted = try allocator.dupe(sir.ExprMetadataEntry, module.expr_metadata);
    defer allocator.free(corrupted);
    var changed = false;
    for (corrupted) |*entry| {
        if (entry.expr != returned.string_from) continue;
        entry.metadata.type_id = roundtrip.return_type_id.?;
        changed = true;
    }
    try std.testing.expect(changed);
    const parameter = try store.internFact(try adapter.term(roundtrip.params[0].type_id.?), origin, &.{});
    var invalid = try generic_origins.PreparedStraightLine.init(allocator, adapter, roundtrip, corrupted, module.structs, module.unions, &.{parameter});
    defer invalid.deinit();
    try std.testing.expectError(error.IncorrectResultType, invalid.run(&store));
}

test "checked origin sparse constructors retain checked item facts" {
    const allocator = std.testing.allocator;
    const source =
        \\fn keyed(value: i32): [;]i32 { return [; 4] { 0: value }; }
        \\fn inline(value: i32): [;]i32 { return [; 4] [value, none]; }
        \\fn empty(): [;]i32 { return [; 4]; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "sparse_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "sparse_origin.cy", program);
    defer module.deinit(allocator);
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const concrete = try store.intern(&.{.concrete});
    try std.testing.expectEqual(@as(usize, 3), module.functions.len);
    for (module.functions) |*function| {
        const params: []const *const generic_origins.Fact = if (function.params.len == 0) &.{} else blk: {
            const fact = try store.internFact(try adapter.term(function.params[0].type_id.?), origin, &.{});
            break :blk &.{fact};
        };
        var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, params);
        defer prepared.deinit();
        const result = try prepared.run(&store);
        defer result.deinit(allocator);
        const item = result.returned.?.child(.sequence_item) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(if (std.mem.eql(u8, function.name, "empty")) &generic_origins.unresolved else origin, item.receiver);
        try std.testing.expectEqual(concrete, result.returned.?.receiver);
    }
    const keyed = for (module.functions) |*function| {
        if (std.mem.eql(u8, function.name, "keyed")) break function;
    } else return error.TestUnexpectedResult;
    const keyed_return = keyed.body[0].@"return" orelse return error.TestUnexpectedResult;
    try std.testing.expect(keyed_return.* == .sparse_keyed_literal);
    const original_item = keyed_return.sparse_keyed_literal.item_type_id;
    keyed_return.sparse_keyed_literal.item_type_id = keyed.return_type_id;
    const parameter = try store.internFact(try adapter.term(keyed.params[0].type_id.?), origin, &.{});
    var invalid = try generic_origins.PreparedStraightLine.init(allocator, adapter, keyed, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer invalid.deinit();
    try std.testing.expectError(error.IncorrectResultType, invalid.run(&store));
    keyed_return.sparse_keyed_literal.item_type_id = original_item;
}

test "checked origin sparse indices has concrete index items" {
    const allocator = std.testing.allocator;
    const source =
        \\fn count(values: [;]i32): usize { return values.indices().len(); }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "sparse_indices_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "sparse_indices_origin.cy", program);
    defer module.deinit(allocator);
    const function = &module.functions[0];
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const concrete = try store.intern(&.{.concrete});
    const item_type = (try types.get(function.params[0].type_id.?)).sparse_array;
    const item = try store.internFact(try adapter.term(item_type), origin, &.{});
    const parameter = try store.internFact(try adapter.term(function.params[0].type_id.?), concrete, &.{.{ .key = .sequence_item, .fact = item }});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expectEqual(concrete, result.returned.?.receiver);
    const returned = function.body[0].@"return" orelse return error.TestUnexpectedResult;
    try std.testing.expect(returned.* == .sequence_len and returned.sequence_len.* == .sparse_indices);
    var expression = prepared.expression;
    expression.binding_values = result.values;
    expression.resolved_reads = prepared.reads;
    const index_list = try expression.eval(&store, returned.sequence_len);
    try std.testing.expectEqual(concrete, (index_list.child(.sequence_item) orelse return error.TestUnexpectedResult).receiver);
    const corrupted = try allocator.dupe(sir.ExprMetadataEntry, module.expr_metadata);
    defer allocator.free(corrupted);
    var changed = false;
    for (corrupted) |*entry| {
        if (entry.expr != returned.sequence_len) continue;
        entry.metadata.type_id = function.return_type_id.?;
        changed = true;
    }
    try std.testing.expect(changed);
    var invalid = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, corrupted, module.structs, module.unions, &.{parameter});
    defer invalid.deinit();
    try std.testing.expectError(error.IncorrectResultType, invalid.run(&store));
}

test "checked origin enum case rejects forged declaration identity" {
    const allocator = std.testing.allocator;
    const source =
        \\enum State { ready }
        \\fn state(): State { return State.ready; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "enum_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "enum_origin.cy", program);
    defer module.deinit(allocator);
    const function = &module.functions[0];
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expectEqual(try store.intern(&.{.concrete}), result.returned.?.receiver);
    const returned = function.body[0].@"return" orelse return error.TestUnexpectedResult;
    try std.testing.expect(returned.* == .enum_case);
    const original = returned.enum_case.decl_id;
    returned.enum_case.decl_id = function.decl_id;
    try std.testing.expectError(error.IncorrectCaseOwner, prepared.run(&store));
    returned.enum_case.decl_id = original;
}

test "checked origin local aliases retain target facts" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\fn read(box: &Box): i32 {
        \\    const alias = box;
        \\    return alias.value;
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "alias_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "alias_origin.cy", program);
    defer module.deinit(allocator);
    const function = &module.functions[0];
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const concrete = try store.intern(&.{.concrete});
    const box_type = (try types.get(function.params[0].type_id.?)).ref_.target;
    const box = try adapter.nominalFact(&store, box_type, module.structs);
    const field = try store.internFact(try adapter.term(module.structs[0].fields[0].type_id.?), origin, &.{});
    const box_value = try store.internFact(box.type_term, concrete, &.{.{ .key = .{ .field = 0 }, .fact = field }});
    const parameter = try store.internFact(try adapter.term(function.params[0].type_id.?), concrete, &.{.{ .key = .ref_target, .fact = box_value }});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expectEqual(origin, result.returned.?.receiver);
    const corrupted = try allocator.dupe(sir.ExprMetadataEntry, module.expr_metadata);
    defer allocator.free(corrupted);
    var changed = false;
    for (corrupted) |*entry| {
        if (entry.expr != function.body[0].local.init) continue;
        entry.metadata.checked_place_root = .{ .binding = function.body[0].local.binding_id.? };
        changed = true;
    }
    try std.testing.expect(changed);
    try std.testing.expectError(error.IncorrectBindingIdentity, generic_origins.PreparedStraightLine.init(allocator, adapter, function, corrupted, module.structs, module.unions, &.{parameter}));
}

test "checked straight-line origin flow prepares compiler-produced SIR" {
    const allocator = std.testing.allocator;
    const source =
        \\fn forward(value: i32): i32 {
        \\    var local: i32 = value;
        \\    local = 1;
        \\    return local;
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "straight_line_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "straight_line_origin.cy", program);
    defer module.deinit(allocator);
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "forward")) break candidate;
    } else return error.TestUnexpectedResult;
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const parameter = try store.internFact(try adapter.term(function.params[0].type_id.?), origin, &.{});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.did_return);
    try std.testing.expectEqual(try store.intern(&.{.concrete}), result.returned.?.receiver);

    const corrupted = try allocator.dupe(sir.ExprMetadataEntry, module.expr_metadata);
    defer allocator.free(corrupted);
    const read = function.body[2].@"return".?;
    var changed = false;
    for (corrupted) |*entry| {
        if (entry.expr != read) continue;
        entry.metadata.checked_place_root = .{ .binding = function.params[0].binding_id.? };
        changed = true;
        break;
    }
    try std.testing.expect(changed);
    try std.testing.expectError(error.IncorrectBindingIdentity, generic_origins.PreparedStraightLine.init(allocator, adapter, function, corrupted, module.structs, module.unions, &.{parameter}));

    const assignment: *sir.Stmt = @constCast(&function.body[1]);
    const original_id = assignment.assign.binding_id;
    assignment.assign.binding_id = function.params[0].binding_id;
    try std.testing.expectError(error.InvalidBindingIdentity, module.verifyCompilerIdentities());
    try std.testing.expectError(error.IncorrectBindingIdentity, generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter}));
    assignment.assign.binding_id = original_id;
    try module.verifyCompilerIdentities();
}

test "checked origin flow evaluates is-test subject and returns concrete bool" {
    const allocator = std.testing.allocator;
    const source =
        \\fn probe(value: ?i32): bool { return value is none; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "is_test_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "is_test_origin.cy", program);
    defer module.deinit(allocator);
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "probe")) break candidate;
    } else return error.TestUnexpectedResult;
    const returned = function.body[0].@"return" orelse return error.TestUnexpectedResult;
    try std.testing.expect(returned.* == .is_test);
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const skeleton = try adapter.unknownFact(&store, function.params[0].type_id.?);
    const payload = skeleton.child(.optional_item) orelse return error.TestUnexpectedResult;
    const concrete = try store.intern(&.{.concrete});
    const payload_fact = try store.internFact(payload.type_term, origin, &.{});
    const parameter = try store.internFact(skeleton.type_term, concrete, &.{.{ .key = .optional_item, .fact = payload_fact }});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.did_return);
    try std.testing.expectEqual(concrete, result.returned.?.receiver);
}

test "checked origin flow preserves array item through compiler-produced slice" {
    const allocator = std.testing.allocator;
    const source =
        \\fn project(values: [2]i32): i32 {
        \\    const view = values[0..1];
        \\    return view[0];
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "slice_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "slice_origin.cy", program);
    defer module.deinit(allocator);
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "project")) break candidate;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(function.body[0].local.init.* == .slice_range);
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const concrete = try store.intern(&.{.concrete});
    const skeleton = try adapter.unknownFact(&store, function.params[0].type_id.?);
    const item = skeleton.child(.sequence_item) orelse return error.TestUnexpectedResult;
    const item_fact = try store.internFact(item.type_term, origin, &.{});
    const parameter = try store.internFact(skeleton.type_term, concrete, &.{.{ .key = .sequence_item, .fact = item_fact }});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.did_return);
    try std.testing.expectEqual(origin, result.returned.?.receiver);

    const corrupted = try allocator.dupe(sir.ExprMetadataEntry, module.expr_metadata);
    defer allocator.free(corrupted);
    var changed = false;
    for (corrupted) |*entry| {
        if (entry.expr != function.body[0].local.init) continue;
        entry.metadata.type_id = function.return_type_id.?;
        changed = true;
        break;
    }
    try std.testing.expect(changed);
    var invalid = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, corrupted, module.structs, module.unions, &.{parameter});
    defer invalid.deinit();
    try std.testing.expectError(error.IncorrectResultType, invalid.run(&store));
}

test "checked origin flow follows resolved direct call returns" {
    const allocator = std.testing.allocator;
    const source =
        \\fn id(value: i32): i32 { return value; }
        \\fn chain(value: i32): i32 { return id(id(value)); }
        \\fn choose(flag: bool, left: i32, right: i32): i32 {
        \\    if flag { return left; }
        \\    return right;
        \\}
        \\fn branch(flag: bool, left: i32, right: i32): i32 { return choose(flag, left, right); }
        \\fn pair(first: i32, second: i32): i32 { return second; }
        \\fn ordered(value: i32): i32 { return pair(value, value); }
        \\fn after(value: i32): i32 { const moved = id(value); return value; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "call_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "call_origin.cy", program);
    defer module.deinit(allocator);
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "chain")) break candidate;
    } else return error.TestUnexpectedResult;
    const returned = function.body[0].@"return" orelse return error.TestUnexpectedResult;
    try std.testing.expect(returned.* == .call);
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const parameter = try store.internFact(try adapter.term(function.params[0].type_id.?), origin, &.{});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer prepared.deinit();
    prepared.expression.functions = module.functions;
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.did_return);
    try std.testing.expectEqual(origin, result.returned.?.receiver);

    const call: *sir.Expr = @constCast(returned);
    const original = call.call.decl_id;
    call.call.decl_id = null;
    try std.testing.expectError(error.MissingCallTarget, prepared.run(&store));
    call.call.decl_id = function.decl_id;
    // A call that is already on the substitution stack is summarized by the
    // callee's declared return contract instead of failing the transfer.
    const summary = try prepared.run(&store);
    defer summary.deinit(allocator);
    try std.testing.expect(summary.did_return);
    try std.testing.expect(isConcreteCarrier(summary.returned.?));
    const choose = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "choose")) break candidate;
    } else return error.TestUnexpectedResult;
    call.call.decl_id = choose.decl_id;
    try std.testing.expectError(error.IncorrectCallSignature, prepared.run(&store));
    call.call.decl_id = original;

    const branch = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "branch")) break candidate;
    } else return error.TestUnexpectedResult;
    const concrete = try store.intern(&.{.concrete});
    const left_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 1 } }});
    const right_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 2 } }});
    const flag_fact = try store.internFact(try adapter.term(branch.params[0].type_id.?), concrete, &.{});
    const left_fact = try store.internFact(try adapter.term(branch.params[1].type_id.?), left_origin, &.{});
    const right_fact = try store.internFact(try adapter.term(branch.params[2].type_id.?), right_origin, &.{});
    var prepared_branch = try generic_origins.PreparedStraightLine.init(allocator, adapter, branch, module.expr_metadata, module.structs, module.unions, &.{ flag_fact, left_fact, right_fact });
    defer prepared_branch.deinit();
    prepared_branch.expression.functions = module.functions;
    const branch_result = try prepared_branch.run(&store);
    defer branch_result.deinit(allocator);
    try std.testing.expect(branch_result.did_return);
    try std.testing.expectEqual(try store.join(left_origin, right_origin), branch_result.returned.?.receiver);

    const ordered = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "ordered")) break candidate;
    } else return error.TestUnexpectedResult;
    var prepared_ordered = try generic_origins.PreparedStraightLine.init(allocator, adapter, ordered, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer prepared_ordered.deinit();
    prepared_ordered.expression.functions = module.functions;
    const ordered_result = try prepared_ordered.run(&store);
    defer ordered_result.deinit(allocator);
    try std.testing.expectEqual(origin, ordered_result.returned.?.receiver);
    const ordered_call = ordered.body[0].@"return" orelse return error.TestUnexpectedResult;
    const first_argument: *sir.Expr = @constCast(ordered_call.call.args[0].value);
    const original_argument = first_argument.*;
    first_argument.* = .{ .handoff_local = "value" };
    try std.testing.expectError(error.UninitializedBinding, prepared_ordered.run(&store));
    first_argument.* = original_argument;

    const after = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "after")) break candidate;
    } else return error.TestUnexpectedResult;
    var prepared_after = try generic_origins.PreparedStraightLine.init(allocator, adapter, after, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer prepared_after.deinit();
    prepared_after.expression.functions = module.functions;
    const after_call = after.body[0].local.init;
    const moved_argument: *sir.Expr = @constCast(after_call.call.args[0].value);
    const original_moved = moved_argument.*;
    moved_argument.* = .{ .handoff_local = "value" };
    try std.testing.expectError(error.UninitializedBinding, prepared_after.run(&store));
    moved_argument.* = original_moved;
}

test "checked origin try statement joins propagated error with successful return" {
    const allocator = std.testing.allocator;
    const source =
        \\enum Failure { bad }
        \\fn source(value: Failure): void!Failure { throw value; }
        \\fn forward(value: Failure): i32!Failure {
        \\    try source(value);
        \\    return 1;
        \\}
        \\fn branch(flag: bool, value: Failure): i32!Failure {
        \\    if flag { try source(value); }
        \\    return 1;
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "try_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "try_origin.cy", program);
    defer module.deinit(allocator);
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "forward")) break @constCast(candidate);
    } else return error.TestUnexpectedResult;
    try std.testing.expect(function.body[0] == .@"try");
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const concrete = try store.intern(&.{.concrete});
    const result_type = (try types.get(function.return_type_id.?)).result;
    const parameter = try store.internFact(try adapter.term(function.params[0].type_id.?), origin, &.{});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer prepared.deinit();
    prepared.expression.functions = module.functions;
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.did_return);
    try std.testing.expect(result.reachable == false);
    try std.testing.expect(result.returned.?.child(.result_ok) != null);
    try std.testing.expectEqual(origin, (result.returned.?.child(.result_err) orelse return error.TestUnexpectedResult).receiver);

    const original_return = function.return_type_id;
    function.return_type_id = result_type.ok;
    var invalid = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer invalid.deinit();
    invalid.expression.functions = module.functions;
    try std.testing.expectError(error.IncorrectReturnType, invalid.run(&store));
    function.return_type_id = original_return;

    const branch = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "branch")) break candidate;
    } else return error.TestUnexpectedResult;
    const flag = try store.internFact(try adapter.term(branch.params[0].type_id.?), concrete, &.{});
    var branched = try generic_origins.PreparedStraightLine.init(allocator, adapter, branch, module.expr_metadata, module.structs, module.unions, &.{ flag, parameter });
    defer branched.deinit();
    branched.expression.functions = module.functions;
    const branch_result = try branched.run(&store);
    defer branch_result.deinit(allocator);
    try std.testing.expectEqual(origin, (branch_result.returned.?.child(.result_err) orelse return error.TestUnexpectedResult).receiver);
}

test "checked origin direct try initializer preserves both result exits" {
    const allocator = std.testing.allocator;
    const source =
        \\enum Failure { bad }
        \\fn source(value: i32, problem: Failure): i32!Failure { if value == 0 { throw problem; } return value; }
        \\fn forward(value: i32, problem: Failure): i32!Failure {
        \\    const item = try source(value, problem);
        \\    return item;
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "try_initializer_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "try_initializer_origin.cy", program);
    defer module.deinit(allocator);
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "forward")) break candidate;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(function.body[0] == .local and function.body[0].local.init.* == .@"try");
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const ok_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const err_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 1 } }});
    const result_type = (try types.get(function.return_type_id.?)).result;
    const value = try store.internFact(try adapter.term(function.params[0].type_id.?), ok_origin, &.{});
    const problem = try store.internFact(try adapter.term(function.params[1].type_id.?), err_origin, &.{});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{ value, problem });
    defer prepared.deinit();
    prepared.expression.functions = module.functions;
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.returned.?.child(.result_ok) != null);
    try std.testing.expect(generic_origins.Origin.leq(err_origin, (result.returned.?.child(.result_err) orelse return error.TestUnexpectedResult).receiver));

    const attempted = function.body[0].local.init;
    const original_type = attempted.@"try".result_ok_type_id;
    attempted.@"try".result_ok_type_id = result_type.err;
    try std.testing.expectError(error.IncorrectResultCaseType, prepared.run(&store));
    attempted.@"try".result_ok_type_id = original_type;
}

const nested_try_source =
    \\enum Failure { bad }
    \\fn source(value: i32, problem: Failure): i32!Failure { if value == 0 { throw problem; } return value; }
    \\fn nested(value: i32, problem: Failure): i32!Failure {
    \\    const payload = try source(value, problem);
    \\    const total = payload + 1;
    \\    return total;
    \\}
    \\fn argument(value: i32, problem: Failure): i32!Failure {
    \\    return (try source(value, problem)) * 2;
    \\}
    \\fn loader(): i32!Failure { throw Failure.bad; }
    \\fn voidLoader(): void!Failure { throw Failure.bad; }
    \\fn settled(): i32!Failure {
    \\    const total = (try loader()) + 1;
    \\    return total;
    \\}
    \\fn skipped(): i32!Failure {
    \\    try voidLoader();
    \\    return 1;
    \\}
    \\fn branch(value: i32, problem: Failure): i32!Failure {
    \\    if (true) {
    \\        const payload = try source(value, problem);
    \\        return payload;
    \\    }
    \\    throw Failure.bad;
    \\}
;

test "checked origin nested try forks the statement exit edge" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "nested_try_origins.cy", nested_try_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    const concrete = try store.intern(&.{.concrete});

    const nested = probe.function("nested") orelse return error.TestUnexpectedResult;
    const ok_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const err_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 1 } }});
    const value = try store.internFact(try adapter.term(nested.params[0].type_id.?), ok_origin, &.{});
    const problem = try store.internFact(try adapter.term(nested.params[1].type_id.?), err_origin, &.{});

    // The success edge survives the fork: the projected payload keeps its
    // origin, later statements still run, and the propagated error joins with
    // the ordinary return. The callee's internal carrier may join input origins.
    const outcome = try flowVariant(&probe, &store, nested, &.{ value, problem });
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome.did_return);
    try std.testing.expect(outcome.values[1] != null);
    try std.testing.expect(outcome.values[2] != null);
    try std.testing.expect(outcome.returned.?.child(.result_err) != null);
    try std.testing.expect(outcome.returned.?.child(.result_ok) != null);

    // A nested `try` deep inside a call argument forks the same statement.
    const argument = probe.function("argument") orelse return error.TestUnexpectedResult;
    const argument_result = try flowVariant(&probe, &store, argument, &.{ value, problem });
    defer argument_result.deinit(allocator);
    try std.testing.expect(argument_result.returned.?.child(.result_err) != null);

    // `loader` provably takes the error case, so the success edge never reaches
    // the following statement and neither local is written.
    const settled = probe.function("settled") orelse return error.TestUnexpectedResult;
    const settled_result = try flowVariant(&probe, &store, settled, &.{});
    defer settled_result.deinit(allocator);
    try std.testing.expect(settled_result.did_return);
    try std.testing.expect(!settled_result.reachable);
    try std.testing.expect(settled_result.values[0] == null);
    const propagated = settled_result.returned orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(propagated));
    const dead_ok = propagated.child(.result_ok) orelse return error.TestUnexpectedResult;
    try std.testing.expect(dead_ok.receiver.* == .set and dead_ok.receiver.set.len == 0);

    // A statement-rooted `try` whose error case is provable stops the segment
    // before the following return, so the propagated error is the only result.
    const skipped = probe.function("skipped") orelse return error.TestUnexpectedResult;
    const skipped_result = try flowVariant(&probe, &store, skipped, &.{});
    defer skipped_result.deinit(allocator);
    try std.testing.expect(skipped_result.did_return);
    try std.testing.expect(!skipped_result.reachable);
    const skipped_returned = skipped_result.returned orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(concrete, (skipped_returned.child(.result_err) orelse return error.TestUnexpectedResult).receiver);
    try std.testing.expect((skipped_returned.child(.result_ok) orelse return error.TestUnexpectedResult).receiver.* == .set and
        skipped_returned.child(.result_ok).?.receiver.set.len == 0);

    // The fork stays inside the branch that contains it: the error edge of a
    // `try` in a nested segment still reaches the enclosing function exit, and
    // a branch that returns leaves the rest of the segment unreachable.
    const branch = probe.function("branch") orelse return error.TestUnexpectedResult;
    const branch_result = try flowVariant(&probe, &store, branch, &.{ value, problem });
    defer branch_result.deinit(allocator);
    try std.testing.expect(branch_result.did_return);
    try std.testing.expect(branch_result.returned.?.child(.result_err) != null);
}
test "checked origin nested try rejects forged result case or enclosing return type" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "nested_try_corruption.cy", nested_try_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };

    const nested = probe.function("nested") orelse return error.TestUnexpectedResult;
    const result_type = (try types.get(nested.return_type_id.?)).result;

    const forged = try copiedBody(allocator, nested);
    defer allocator.free(forged);
    const attempted = firstExprWithBody(forged, "try") orelse return error.TestUnexpectedResult;
    try std.testing.expect(attempted.* == .@"try");
    const original_err = attempted.@"try".result_err_type_id;
    attempted.@"try".result_err_type_id = result_type.ok;
    try std.testing.expectError(error.IncorrectResultCaseType, runVariant(&probe, &store, nested, forged));
    attempted.@"try".result_err_type_id = original_err;
    const restored = try runVariant(&probe, &store, nested, forged);
    try std.testing.expect(restored != null);

    // A `try` cannot propagate an error the enclosing function does not return.
    const settled = probe.function("settled") orelse return error.TestUnexpectedResult;
    var narrowed = settled.*;
    narrowed.return_type_id = result_type.ok;
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, &narrowed, probe.module.expr_metadata, probe.module.structs, probe.module.unions, &.{});
    defer prepared.deinit();
    prepared.expression.functions = probe.module.functions;
    try std.testing.expectError(error.IncorrectReturnType, prepared.run(&store));
}

test "checked origin flow carries payload through compiler-produced result case" {
    const allocator = std.testing.allocator;
    const source =
        \\enum Failure { failed }
        \\fn wrap(value: i32): i32!Failure { return value; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "result_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "result_origin.cy", program);
    defer module.deinit(allocator);
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "wrap")) break candidate;
    } else return error.TestUnexpectedResult;
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const parameter = try store.internFact(try adapter.term(function.params[0].type_id.?), origin, &.{});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.did_return);
    try std.testing.expectEqual(origin, result.returned.?.child(.result_ok).?.receiver);
    try std.testing.expectEqual(try store.intern(&.{.concrete}), result.returned.?.receiver);
}

test "checked origin joins distinct nominal union case payloads" {
    const allocator = std.testing.allocator;
    const source =
        \\union Choice { left: i32; right: i32; }
        \\fn choose(flag: bool, left: i32, right: i32): Choice {
        \\    if flag { return .left(left); }
        \\    return .right(right);
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "union_join_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "union_join_origin.cy", program);
    defer module.deinit(allocator);
    const function = &module.functions[0];
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const concrete = try store.intern(&.{.concrete});
    const left_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const right_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 1 } }});
    const flag = try store.internFact(try adapter.term(function.params[0].type_id.?), concrete, &.{});
    const left = try store.internFact(try adapter.term(function.params[1].type_id.?), left_origin, &.{});
    const right = try store.internFact(try adapter.term(function.params[2].type_id.?), right_origin, &.{});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{ flag, left, right });
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expectEqual(left_origin, (result.returned.?.child(.{ .case_payload = 0 }) orelse return error.TestUnexpectedResult).receiver);
    try std.testing.expectEqual(right_origin, (result.returned.?.child(.{ .case_payload = 1 }) orelse return error.TestUnexpectedResult).receiver);
}

test "checked origin flow constructs compiler-produced nominal union case" {
    const allocator = std.testing.allocator;
    const source =
        \\union Choice { value: i32; empty; }
        \\fn wrap(value: i32): Choice { return .value(value); }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "union_constructor_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "union_constructor_origin.cy", program);
    defer module.deinit(allocator);
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "wrap")) break candidate;
    } else return error.TestUnexpectedResult;
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const parameter = try store.internFact(try adapter.term(function.params[0].type_id.?), origin, &.{});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.did_return);
    try std.testing.expectEqual(origin, result.returned.?.child(.{ .case_payload = 0 }).?.receiver);
    try std.testing.expectEqual(try store.intern(&.{.concrete}), result.returned.?.receiver);

    const constructed = function.body[0].@"return".?;
    const original_decl_id = constructed.union_case.decl_id;
    constructed.union_case.decl_id = @fromBackingInt(@intCast(999999));
    try std.testing.expectError(error.IncorrectCaseOwner, prepared.run(&store));
    constructed.union_case.decl_id = original_decl_id;
}

test "checked origin flow replaces nested struct field without erasing siblings" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Inner { value: i32; }
        \\struct Outer { inner: Inner; other: i32; }
        \\fn update(seed: Outer): Outer {
        \\    var box: Outer = seed;
        \\    box.inner.value = 1;
        \\    return box;
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "field_write_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "field_write_origin.cy", program);
    defer module.deinit(allocator);
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "update")) break candidate;
    } else return error.TestUnexpectedResult;
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const seed_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const other_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 1 } }});
    const concrete = try store.intern(&.{.concrete});
    const int_type = module.structs[0].fields[0].type_id.?;
    const inner_type = module.structs[1].fields[0].type_id.?;
    const seed_value = try store.internFact(try adapter.term(int_type), seed_origin, &.{});
    const other = try store.internFact(try adapter.term(int_type), other_origin, &.{});
    const inner = try store.internFact(try adapter.term(inner_type), concrete, &.{.{ .key = .{ .field = 0 }, .fact = seed_value }});
    const parameter = try store.internFact(try adapter.term(function.params[0].type_id.?), concrete, &.{
        .{ .key = .{ .field = 0 }, .fact = inner },
        .{ .key = .{ .field = 1 }, .fact = other },
    });
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.did_return);
    try std.testing.expectEqual(concrete, result.returned.?.child(.{ .field = 0 }).?.child(.{ .field = 0 }).?.receiver);
    try std.testing.expectEqual(other_origin, result.returned.?.child(.{ .field = 1 }).?.receiver);
    try std.testing.expectEqual(seed_origin, parameter.child(.{ .field = 0 }).?.child(.{ .field = 0 }).?.receiver);

    const assignment: *sir.Stmt = @constCast(&function.body[1]);
    const original_id = assignment.field_assign.root_binding_id;
    assignment.field_assign.root_binding_id = function.params[0].binding_id;
    try std.testing.expectError(error.InvalidBindingIdentity, module.verifyCompilerIdentities());
    try std.testing.expectError(error.IncorrectBindingIdentity, generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter}));
    assignment.field_assign.root_binding_id = original_id;
}

test "checked origin flow constructs nested struct facts from checked fields" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Inner { value: i32; }
        \\struct Outer { inner: Inner; other: i32; }
        \\fn build(value: i32): Outer {
        \\    return Outer { inner: Inner { value: value }, other: 1 };
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "struct_constructor_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "struct_constructor_origin.cy", program);
    defer module.deinit(allocator);
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "build")) break candidate;
    } else return error.TestUnexpectedResult;
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const concrete = try store.intern(&.{.concrete});
    const parameter = try store.internFact(try adapter.term(function.params[0].type_id.?), origin, &.{});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.did_return);
    try std.testing.expectEqual(origin, result.returned.?.child(.{ .field = 0 }).?.child(.{ .field = 0 }).?.receiver);
    try std.testing.expectEqual(concrete, result.returned.?.child(.{ .field = 1 }).?.receiver);
    try std.testing.expectEqual(concrete, result.returned.?.receiver);

    const constructed = function.body[0].@"return".?;
    const original_id = constructed.struct_literal.decl_id;
    constructed.struct_literal.decl_id = @fromBackingInt(@intCast(999999));
    try std.testing.expectError(error.IncorrectFieldOwner, prepared.run(&store));
    constructed.struct_literal.decl_id = original_id;
}

test "checked origin flow summarizes compiler-produced array items and projects index" {
    const allocator = std.testing.allocator;
    const source =
        \\fn one(value: i32): i32 {
        \\    const values: [1]i32 = [value];
        \\    return values[0];
        \\}
        \\fn mixed(value: i32): i32 {
        \\    const values: [2]i32 = [value, 1];
        \\    return values[1];
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "sequence_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "sequence_origin.cy", program);
    defer module.deinit(allocator);
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const concrete = try store.intern(&.{.concrete});
    for (module.functions) |*function| {
        if (!std.mem.eql(u8, function.name, "one") and !std.mem.eql(u8, function.name, "mixed")) continue;
        const parameter = try store.internFact(try adapter.term(function.params[0].type_id.?), origin, &.{});
        var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
        defer prepared.deinit();
        const result = try prepared.run(&store);
        defer result.deinit(allocator);
        try std.testing.expect(result.did_return);
        try std.testing.expectEqual(if (std.mem.eql(u8, function.name, "one")) origin else try store.join(origin, concrete), result.returned.?.receiver);
    }
}

test "checked origin flow weakly updates local array item summary" {
    const allocator = std.testing.allocator;
    const source =
        \\fn update(value: i32): i32 {
        \\    var values: [2]i32 = [value, value];
        \\    values[0] = 1;
        \\    return values[1];
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "index_write_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "index_write_origin.cy", program);
    defer module.deinit(allocator);
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "update")) break candidate;
    } else return error.TestUnexpectedResult;
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const concrete = try store.intern(&.{.concrete});
    const parameter = try store.internFact(try adapter.term(function.params[0].type_id.?), origin, &.{});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.did_return);
    try std.testing.expectEqual(try store.join(origin, concrete), result.returned.?.receiver);

    const object = function.body[1].index_assign.object;
    const corrupted = try allocator.dupe(sir.ExprMetadataEntry, module.expr_metadata);
    defer allocator.free(corrupted);
    var changed = false;
    for (corrupted) |*entry| {
        if (entry.expr != object) continue;
        entry.metadata.checked_place_root = .{ .binding = function.params[0].binding_id.? };
        changed = true;
        break;
    }
    try std.testing.expect(changed);
    try std.testing.expectError(error.IncorrectBindingIdentity, generic_origins.PreparedStraightLine.init(allocator, adapter, function, corrupted, module.structs, module.unions, &.{parameter}));
}

test "checked origin flow preserves struct field inside compiler-produced owned value" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\fn make(value: i32): ^Box { return new Box { value: value }; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "owned_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "owned_origin.cy", program);
    defer module.deinit(allocator);
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "make")) break candidate;
    } else return error.TestUnexpectedResult;
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const concrete = try store.intern(&.{.concrete});
    const parameter = try store.internFact(try adapter.term(function.params[0].type_id.?), origin, &.{});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.did_return);
    try std.testing.expectEqual(origin, result.returned.?.child(.owned_target).?.child(.{ .field = 0 }).?.receiver);
    try std.testing.expectEqual(concrete, result.returned.?.receiver);

    const constructed = function.body[0].@"return".?;
    const original_id = constructed.new_owned.decl_id;
    constructed.new_owned.decl_id = @fromBackingInt(@intCast(999999));
    try std.testing.expectError(error.IncorrectFieldOwner, prepared.run(&store));
    constructed.new_owned.decl_id = original_id;
}

test "checked origin flow joins compiler-produced plain if exits" {
    const allocator = std.testing.allocator;
    const source =
        \\fn choose(flag: bool, value: i32): i32 {
        \\    var current: i32 = value;
        \\    if flag { current = 1; }
        \\    return current;
        \\}
        \\fn choose_return(flag: bool, value: i32): i32 {
        \\    if flag { return value; }
        \\    return 1;
        \\}
        \\fn choose_reverse(flag: bool, value: i32): i32 {
        \\    var current: i32 = 1;
        \\    if flag { current = value; }
        \\    return current;
        \\}
        \\fn choose_constant(value: i32): i32 {
        \\    var current: i32 = value;
        \\    if true { current = 1; }
        \\    return current;
        \\}
        \\fn choose_scoped(flag: bool, value: i32): i32 {
        \\    if flag { const temporary: i32 = value; }
        \\    else { const temporary: i32 = 1; }
        \\    return value;
        \\}
        \\fn choose_scoped_return(flag: bool, value: i32): i32 {
        \\    if flag { const temporary: i32 = value; return temporary; }
        \\    else { const temporary: i32 = 1; return temporary; }
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "if_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "if_origin.cy", program);
    defer module.deinit(allocator);
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "choose")) break candidate;
    } else return error.TestUnexpectedResult;
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const flag_origin = try store.intern(&.{.concrete});
    const value_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 1 } }});
    const flag_fact = try store.internFact(try adapter.term(function.params[0].type_id.?), flag_origin, &.{});
    const value_fact = try store.internFact(try adapter.term(function.params[1].type_id.?), value_origin, &.{});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{ flag_fact, value_fact });
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.did_return);
    try std.testing.expectEqual(try store.join(value_origin, flag_origin), result.returned.?.receiver);
    const return_function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "choose_return")) break candidate;
    } else return error.TestUnexpectedResult;
    var prepared_return = try generic_origins.PreparedStraightLine.init(allocator, adapter, return_function, module.expr_metadata, module.structs, module.unions, &.{ flag_fact, value_fact });
    defer prepared_return.deinit();
    const returned_result = try prepared_return.run(&store);
    defer returned_result.deinit(allocator);
    try std.testing.expect(returned_result.did_return);
    try std.testing.expect(!returned_result.reachable);
    try std.testing.expectEqual(try store.join(value_origin, flag_origin), returned_result.returned.?.receiver);
    const reverse_function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "choose_reverse")) break candidate;
    } else return error.TestUnexpectedResult;
    var prepared_reverse = try generic_origins.PreparedStraightLine.init(allocator, adapter, reverse_function, module.expr_metadata, module.structs, module.unions, &.{ flag_fact, value_fact });
    defer prepared_reverse.deinit();
    const reversed_result = try prepared_reverse.run(&store);
    defer reversed_result.deinit(allocator);
    try std.testing.expectEqual(result.returned.?.receiver, reversed_result.returned.?.receiver);
    const constant_function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "choose_constant")) break candidate;
    } else return error.TestUnexpectedResult;
    var prepared_constant = try generic_origins.PreparedStraightLine.init(allocator, adapter, constant_function, module.expr_metadata, module.structs, module.unions, &.{value_fact});
    defer prepared_constant.deinit();
    const constant_result = try prepared_constant.run(&store);
    defer constant_result.deinit(allocator);
    try std.testing.expectEqual(flag_origin, constant_result.returned.?.receiver);
    const scoped_function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "choose_scoped")) break candidate;
    } else return error.TestUnexpectedResult;
    const then_local = scoped_function.body[0].@"if".then_body[0].local;
    const else_local = scoped_function.body[0].@"if".else_body[0].local;
    try std.testing.expect(scoped_function.params[0].binding_id != null);
    try std.testing.expect(then_local.binding_id != null and else_local.binding_id != null);
    try std.testing.expect(then_local.binding_id.? != else_local.binding_id.?);
    try std.testing.expect(then_local.binding_id.? != scoped_function.params[0].binding_id.?);
    var prepared_scoped = try generic_origins.PreparedStraightLine.init(allocator, adapter, scoped_function, module.expr_metadata, module.structs, module.unions, &.{ flag_fact, value_fact });
    defer prepared_scoped.deinit();
    const scoped_result = try prepared_scoped.run(&store);
    defer scoped_result.deinit(allocator);
    try std.testing.expectEqual(value_origin, scoped_result.returned.?.receiver);
    try std.testing.expect(scoped_result.values[2] == null and scoped_result.values[3] == null);
    const scoped_return_function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "choose_scoped_return")) break candidate;
    } else return error.TestUnexpectedResult;
    var prepared_scoped_return = try generic_origins.PreparedStraightLine.init(allocator, adapter, scoped_return_function, module.expr_metadata, module.structs, module.unions, &.{ flag_fact, value_fact });
    defer prepared_scoped_return.deinit();
    const scoped_return_result = try prepared_scoped_return.run(&store);
    defer scoped_return_result.deinit(allocator);
    try std.testing.expect(!scoped_return_result.reachable);
    try std.testing.expectEqual(try store.join(value_origin, flag_origin), scoped_return_result.returned.?.receiver);
}

test "checked origin flow carries optional capture through compiler-produced SIR" {
    const allocator = std.testing.allocator;
    const source =
        \\fn capture(value: ?i32): i32 {
        \\    if value is item { return item; }
        \\    return 0;
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "optional_capture_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "optional_capture_origin.cy", program);
    defer module.deinit(allocator);
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "capture")) break candidate;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(function.body[0].@"if".capture_binding_id != null);
    try std.testing.expect(function.body[0].@"if".capture_binding_id.? != function.params[0].binding_id.?);
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const parameter_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const concrete = try store.intern(&.{.concrete});
    const optional_type = function.params[0].type_id.?;
    const optional_node = try types.get(optional_type);
    const item_type = optional_node.optional;
    const item_fact = try store.internFact(try adapter.term(item_type), parameter_origin, &.{});
    const optional_fact = try store.internFact(try adapter.term(optional_type), concrete, &.{.{ .key = .optional_item, .fact = item_fact }});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{optional_fact});
    defer prepared.deinit();
    try std.testing.expect(prepared.scope_exits[0].capture_slot != null);
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(!result.reachable);
    try std.testing.expectEqual(try store.join(parameter_origin, concrete), result.returned.?.receiver);
}

test "checked origin flow carries union case capture through compiler-produced SIR" {
    const allocator = std.testing.allocator;
    const source =
        \\union Choice { value: i32; empty; }
        \\fn capture(value: Choice): i32 {
        \\    if value is .value(item) { return item; }
        \\    return 0;
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "union_capture_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "union_capture_origin.cy", program);
    defer module.deinit(allocator);
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "capture")) break candidate;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(function.body[0].@"if".capture_binding_id != null);
    try std.testing.expect(function.body[0].@"if".capture_binding_id.? != function.params[0].binding_id.?);
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const parameter_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const concrete = try store.intern(&.{.concrete});
    const payload_type = module.unions[0].fields[0].type_id.?;
    const payload = try store.internFact(try adapter.term(payload_type), parameter_origin, &.{});
    const union_fact = try store.internFact(try adapter.term(function.params[0].type_id.?), concrete, &.{.{ .key = .{ .case_payload = 0 }, .fact = payload }});
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{union_fact});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(!result.reachable);
    try std.testing.expectEqual(try store.join(parameter_origin, concrete), result.returned.?.receiver);
}

test "switch payload captures retain sema binding identity" {
    const allocator = std.testing.allocator;
    const source =
        \\union Choice { active: i32; empty; }
        \\fn regular(value: Choice): i32 {
        \\    switch value { .active(item) => { return item; } .empty => { return 0; } }
        \\}
        \\fn looped(value: Choice): i32 {
        \\    var once: bool = true;
        \\    while once {
        \\        switch value { .active(item) => { return item; } .empty => { once = false; } }
        \\    }
        \\    return 0;
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "switch_binding_identity.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "switch_binding_identity.cy", program);
    defer module.deinit(allocator);
    const regular = for (module.functions) |*function| {
        if (std.mem.eql(u8, function.name, "regular")) break function;
    } else return error.TestUnexpectedResult;
    const looped = for (module.functions) |*function| {
        if (std.mem.eql(u8, function.name, "looped")) break function;
    } else return error.TestUnexpectedResult;
    const regular_id = regular.body[0].@"switch".cases[0].payload_binding_id orelse return error.TestUnexpectedResult;
    const loop_id = looped.body[1].@"while".body[0].@"switch".cases[0].payload_binding_id orelse return error.TestUnexpectedResult;
    try std.testing.expect(regular_id != regular.params[0].binding_id.?);
    try std.testing.expect(loop_id != looped.params[0].binding_id.?);
    try std.testing.expect(regular_id != loop_id);
}

test "checked origin flow joins exhaustive switch payload branches" {
    const allocator = std.testing.allocator;
    const source =
        \\union Choice { active: i32; empty; }
        \\fn choose(value: Choice): i32 {
        \\    switch value { .active(item) => { return item; } .empty => { return 0; } }
        \\}
        \\fn assign(value: Choice, seed: i32): i32 {
        \\    var current: i32 = seed;
        \\    switch value { .active(item) => { current = item; } .empty => { current = 0; } }
        \\    return current;
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "switch_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "switch_origin.cy", program);
    defer module.deinit(allocator);
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const payload_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const seed_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 1 } }});
    const concrete = try store.intern(&.{.concrete});
    const payload_type = module.unions[0].fields[0].type_id.?;
    const payload = try store.internFact(try adapter.term(payload_type), payload_origin, &.{});
    for (module.functions) |*function| {
        if (!std.mem.eql(u8, function.name, "choose") and !std.mem.eql(u8, function.name, "assign")) continue;
        const choice = try store.internFact(try adapter.term(function.params[0].type_id.?), concrete, &.{.{ .key = .{ .case_payload = 0 }, .fact = payload }});
        const seed = try store.internFact(try adapter.term(payload_type), seed_origin, &.{});
        const params: []const *const generic_origins.Fact = if (function.params.len == 1) &.{choice} else &.{ choice, seed };
        var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, params);
        defer prepared.deinit();
        const result = try prepared.run(&store);
        defer result.deinit(allocator);
        try std.testing.expect(result.did_return);
        try std.testing.expect(!result.reachable);
        try std.testing.expectEqual(try store.join(payload_origin, concrete), result.returned.?.receiver);
    }
}

test "checked origin flow projects nominal union switch payloads" {
    const allocator = std.testing.allocator;
    const source =
        \\union Outcome { value: i32; failure: i32; }
        \\fn unwrap(value: Outcome): i32 {
        \\    switch value { .value(item) => { return item; } .failure(reason) => { return 0; } }
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "result_switch_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "result_switch_origin.cy", program);
    defer module.deinit(allocator);
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "unwrap")) break candidate;
    } else return error.TestUnexpectedResult;
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const concrete = try store.intern(&.{.concrete});
    const cases: []sir.SwitchCase = @constCast(function.body[0].@"switch".cases);
    const ok = try store.internFact(try adapter.term(cases[0].payload_type_id.?), origin, &.{});
    const err = try store.internFact(try adapter.term(cases[1].payload_type_id.?), concrete, &.{});
    const parameter = try store.internFact(try adapter.term(function.params[0].type_id.?), concrete, &.{
        .{ .key = .{ .case_payload = 0 }, .fact = ok },
        .{ .key = .{ .case_payload = 1 }, .fact = err },
    });
    var prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, function, module.expr_metadata, module.structs, module.unions, &.{parameter});
    defer prepared.deinit();
    const result = try prepared.run(&store);
    defer result.deinit(allocator);
    try std.testing.expect(result.did_return);
    try std.testing.expect(!result.reachable);
    try std.testing.expectEqual(try store.join(origin, concrete), result.returned.?.receiver);

    const original_case = cases[0].payload_path.?.active_case;
    cases[0].payload_path.?.active_case = cases[1].payload_path.?.active_case;
    try std.testing.expectError(error.InvalidCapturePath, prepared.run(&store));
    cases[0].payload_path.?.active_case = original_case;
}

test "checked origin flow converges compiler-produced while loop" {
    const allocator = std.testing.allocator;
    const source =
        \\fn join_loop(flag: bool, value: i32): i32 {
        \\    var once: bool = flag;
        \\    var current: i32 = value;
        \\    while once {
        \\        const temporary: i32 = 1;
        \\        current = temporary;
        \\        once = false;
        \\    }
        \\    return current;
        \\}
        \\fn skip_loop(value: i32): i32 {
        \\    var current: i32 = value;
        \\    while false { current = 1; }
        \\    return current;
        \\}
        \\fn return_loop(value: i32): i32 {
        \\    while true { return value; }
        \\}
        \\fn continue_loop(flag: bool, value: i32): i32 {
        \\    var once: bool = flag;
        \\    var current: i32 = value;
        \\    while once {
        \\        if once {
        \\            const temporary: i32 = 1;
        \\            current = temporary;
        \\            once = false;
        \\            continue;
        \\        }
        \\        current = value;
        \\    }
        \\    return current;
        \\}
        \\fn for_loop(values: []const i32, seed: i32): i32 {
        \\    var current: i32 = seed;
        \\    for item in values {
        \\        current = item;
        \\        continue;
        \\    }
        \\    return current;
        \\}
        \\fn sparse_loop(values: [;]i32, seed: i32): i32 {
        \\    var current: i32 = seed;
        \\    for item in values {
        \\        if item is value { current = value; }
        \\    }
        \\    return current;
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "while_origin.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "while_origin.cy", program);
    defer module.deinit(allocator);
    const types = if (module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const concrete = try store.intern(&.{.concrete});
    const parameter_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const join_function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "join_loop")) break candidate;
    } else return error.TestUnexpectedResult;
    const flag_fact = try store.internFact(try adapter.term(join_function.params[0].type_id.?), concrete, &.{});
    const value_fact = try store.internFact(try adapter.term(join_function.params[1].type_id.?), parameter_origin, &.{});
    var join_prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, join_function, module.expr_metadata, module.structs, module.unions, &.{ flag_fact, value_fact });
    defer join_prepared.deinit();
    const joined = try join_prepared.run(&store);
    defer joined.deinit(allocator);
    try std.testing.expectEqual(try store.join(parameter_origin, concrete), joined.returned.?.receiver);
    try std.testing.expect(joined.values[4] == null);
    const skip_function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "skip_loop")) break candidate;
    } else return error.TestUnexpectedResult;
    var skip_prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, skip_function, module.expr_metadata, module.structs, module.unions, &.{value_fact});
    defer skip_prepared.deinit();
    const skipped = try skip_prepared.run(&store);
    defer skipped.deinit(allocator);
    try std.testing.expectEqual(parameter_origin, skipped.returned.?.receiver);
    const return_function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "return_loop")) break candidate;
    } else return error.TestUnexpectedResult;
    var return_prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, return_function, module.expr_metadata, module.structs, module.unions, &.{value_fact});
    defer return_prepared.deinit();
    const returned = try return_prepared.run(&store);
    defer returned.deinit(allocator);
    try std.testing.expect(returned.did_return and !returned.reachable);
    try std.testing.expectEqual(parameter_origin, returned.returned.?.receiver);
    const continue_function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "continue_loop")) break candidate;
    } else return error.TestUnexpectedResult;
    var continue_prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, continue_function, module.expr_metadata, module.structs, module.unions, &.{ flag_fact, value_fact });
    defer continue_prepared.deinit();
    const continued = try continue_prepared.run(&store);
    defer continued.deinit(allocator);
    try std.testing.expectEqual(try store.join(parameter_origin, concrete), continued.returned.?.receiver);
    try std.testing.expect(continued.values[4] == null);
    const for_function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "for_loop")) break candidate;
    } else return error.TestUnexpectedResult;
    const for_stmt = for_function.body[1].@"for";
    try std.testing.expect(for_stmt.binding_id != null);
    try std.testing.expect(for_stmt.binding_id.? != for_function.params[0].binding_id.?);
    const item_fact = try store.internFact(try adapter.term(for_stmt.item_type_id.?), parameter_origin, &.{});
    const iterable_fact = try store.internFact(try adapter.term(for_function.params[0].type_id.?), concrete, &.{.{ .key = .sequence_item, .fact = item_fact }});
    const seed_fact = try store.internFact(try adapter.term(for_function.params[1].type_id.?), concrete, &.{});
    var for_prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, for_function, module.expr_metadata, module.structs, module.unions, &.{ iterable_fact, seed_fact });
    defer for_prepared.deinit();
    const iterated = try for_prepared.run(&store);
    defer iterated.deinit(allocator);
    try std.testing.expectEqual(try store.join(parameter_origin, concrete), iterated.returned.?.receiver);
    try std.testing.expect(iterated.values[3] == null);
    const sparse_function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "sparse_loop")) break candidate;
    } else return error.TestUnexpectedResult;
    const sparse_item_fact = try store.internFact(try adapter.term((try adapter.types.get(sparse_function.params[0].type_id.?)).sparse_array), parameter_origin, &.{});
    const sparse_fact = try store.internFact(try adapter.term(sparse_function.params[0].type_id.?), concrete, &.{.{ .key = .sequence_item, .fact = sparse_item_fact }});
    var sparse_prepared = try generic_origins.PreparedStraightLine.init(allocator, adapter, sparse_function, module.expr_metadata, module.structs, module.unions, &.{ sparse_fact, seed_fact });
    defer sparse_prepared.deinit();
    const sparse_result = try sparse_prepared.run(&store);
    defer sparse_result.deinit(allocator);
    try std.testing.expectEqual(try store.join(parameter_origin, concrete), sparse_result.returned.?.receiver);
}

fn dumpModule(allocator: std.mem.Allocator, module: anytype) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &output);
    try module.dump(&writer.writer);
    output = writer.toArrayList();
    return output.toOwnedSlice(allocator);
}

test "representative AST artifact remains stable" {
    const allocator = std.testing.allocator;
    const source =
        \\type Count = i32;
        \\
        \\fn add(value: Count): Count {
        \\    const next: Count = value + 2;
        \\    return next;
        \\}
        \\
        \\fn main(): i32 {
        \\    return add(40);
        \\}
    ;

    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "ast_baseline.cy", source, tokens);
    defer program.deinit(allocator);

    const ast_text = try commands.build.renderAstText(allocator, program);
    defer allocator.free(ast_text);
    try std.testing.expectEqualStrings(
        \\ast-summary-v1
        \\type Count = i32
        \\fn add (1 params): Count (2 statements)
        \\fn main (0 params): i32 (1 statements)
        \\
    , ast_text);
}

test "SIR carries resolved non-owning place origins across the semantic boundary" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Record { field: i32; }
        \\fn from_alias(value: &Record): i32 { return value.field; }
        \\fn from_view(values: []Record): i32 { return values[0].field; }
        \\fn from_owned(values: [1]Record): i32 { return values[0].field; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "place_origins.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "place_origins.cy", program);
    defer module.deinit(allocator);

    var seen: usize = 0;
    for (module.functions) |function| {
        const expected: ?bool = if (std.mem.eql(u8, function.name, "from_alias") or std.mem.eql(u8, function.name, "from_view"))
            true
        else if (std.mem.eql(u8, function.name, "from_owned"))
            false
        else
            null;
        if (expected) |non_owning| {
            const expr = function.body[0].@"return".?;
            const metadata = module.metadataForExpr(expr) orelse return error.MissingMetadata;
            try std.testing.expectEqual(non_owning, metadata.non_owning_place_origin);
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
}

test "SIR exposes inferred generic requirements without instantiating the declaration" {
    const allocator = std.testing.allocator;
    const source =
        \\protocol Hashable { fn hash(self: &const Self): usize; }
        \\fn inspect<T: Hashable>(left: T, right: T): usize {
        \\    const duplicate: T = left;
        \\    if left == right {
        \\        const digest = left.hash();
        \\        return digest;
        \\    }
        \\    return 0;
        \\}
        \\fn make<T>(): ^T {
        \\    return new T {};
        \\}
    ;

    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "generic_requirements.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "generic_requirements.cy", program);
    defer module.deinit(allocator);

    // The checked body records its method uses before the syntax walk records
    // the operators it sees, so the requirements are grouped by kind rather
    // than by position.
    try std.testing.expectEqual(@as(usize, 4), module.generic_requirements.len);
    var operator_uses: usize = 0;
    var lowered_uses: usize = 0;
    var constructed: usize = 0;
    for (module.generic_requirements) |requirement| {
        try std.testing.expect(requirement.declaration_id != null);
        if (std.mem.eql(u8, requirement.declaration, "make")) {
            try std.testing.expectEqualStrings("construct", requirement.operation);
            constructed += 1;
            continue;
        }
        try std.testing.expectEqualStrings("inspect", requirement.declaration);
        try std.testing.expectEqualStrings("T", requirement.parameter);
        if (requirement.declared_protocol) |authority| {
            lowered_uses += 1;
            try std.testing.expectEqualStrings("hash", requirement.operation);
            try std.testing.expectEqualStrings("Hashable", authority.name);
            try std.testing.expect(requirement.use_id != null);
            try std.testing.expect(requirement.source_offset > 0);
        } else {
            operator_uses += 1;
            try std.testing.expectEqualStrings("eq", requirement.operation);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), operator_uses);
    try std.testing.expectEqual(@as(usize, 1), lowered_uses);
    try std.testing.expectEqual(@as(usize, 1), constructed);

    const text = try dumpModule(allocator, module);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "inspect<T>: eq @+") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "inspect<T>: hash @+") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[declared Hashable]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make<T>: construct @+") != null);
}

test "SIR generic facts distinguish inferred operator from declared method with same name" {
    const allocator = std.testing.allocator;
    const source =
        \\protocol Comparable { fn eq(self: &const Self, other: &const Self): bool; }
        \\fn inspect<T: Comparable>(left: T, right: T): bool {
        \\    const alias = &left;
        \\    const operator = left == right;
        \\    return alias.eq(&right);
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "generic_authority.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "generic_authority.cy", program);
    defer module.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), module.generic_requirements.len);
    var declared_authority: usize = 0;
    var inferred_operators: usize = 0;
    for (module.generic_requirements) |requirement| {
        try std.testing.expectEqualStrings("eq", requirement.operation);
        if (requirement.declared_protocol) |authority| {
            declared_authority += 1;
            try std.testing.expectEqualStrings("Comparable", authority.name);
            try std.testing.expect(requirement.use_id != null);
        } else {
            inferred_operators += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), declared_authority);
    try std.testing.expectEqual(@as(usize, 2), inferred_operators);
    const text = try dumpModule(allocator, module);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "[declared Comparable]") != null);
}

test "generic method admission records qualified protocol authority before instantiation" {
    const allocator = std.testing.allocator;
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\fn inspect<T: Readable>(value: &const T): i32 { return Readable.read(value); }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "qualified_generic_authority.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "qualified_generic_authority.cy", program);
    defer module.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), module.generic_requirements.len);
    const requirement = module.generic_requirements[0];
    try std.testing.expect(requirement.declaration_id != null);
    try std.testing.expectEqualStrings("inspect", requirement.declaration);
    try std.testing.expectEqualStrings("T", requirement.parameter);
    try std.testing.expectEqualStrings("read", requirement.operation);
    try std.testing.expectEqualStrings("Readable", requirement.declared_protocol.?.name);
    const text = try dumpModule(allocator, module);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "[declared Readable]") != null);
}

test "same-named protocol methods retain distinct checked declaration identities" {
    const allocator = std.testing.allocator;
    const source =
        \\protocol Left { fn read(self: &const Self): i32; }
        \\protocol Right { fn read(self: &const Self): i32; }
        \\fn from_left<T: Left>(value: &const T): i32 { return Left.read(value); }
        \\fn from_right<T: Right>(value: &const T): i32 { return Right.read(value); }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "distinct_protocol_method_ids.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "distinct_protocol_method_ids.cy", program);
    defer module.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), module.generic_requirements.len);
    const left = module.generic_requirements[0].declared_protocol.?;
    const right = module.generic_requirements[1].declared_protocol.?;
    try std.testing.expect(left.id != right.id);
    try std.testing.expect(left.method_id.? != right.method_id.?);
}

test "instantiated generic method call retains its checked source authority" {
    const allocator = std.testing.allocator;
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\fn inspect<T: Readable>(value: T): i32 { return value.read(); }
        \\fn main(): i32 { return inspect<Value>(Value { number: 42 }); }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "checked_generic_method_use.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "checked_generic_method_use.cy", program);
    defer module.deinit(allocator);
    try module.verifyGenericRequirements();
    var protocol_calls: usize = 0;
    var live_calls: usize = 0;
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .call) continue;
        // Every lowered call settles to a checked record, and the record names
        // the concrete declaration the call reaches.
        const use = entry.expr.call.checked_method_use orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(use.callee_declaration_id, entry.expr.call.decl_id);
        live_calls += 1;
        if (use.protocol_id == null) continue;
        try std.testing.expect(use.source_declaration_id == module.generic_requirements[0].declaration_id.?);
        try std.testing.expect(use.source_offset == module.generic_requirements[0].source_offset);
        try std.testing.expect(use.protocol_id == module.generic_requirements[0].declared_protocol.?.id);
        try std.testing.expect(use.method_id == module.generic_requirements[0].declared_protocol.?.method_id.?);
        protocol_calls += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), protocol_calls);
    try std.testing.expectEqual(@as(usize, 2), live_calls);
}

test "method-use records keep two protocol uses in one body distinct" {
    const allocator = std.testing.allocator;
    const source =
        \\protocol Eq { fn eq(self: &const Self, other: &const Self): bool; }
        \\struct Item { key: i32; }
        \\impl Item: Eq { fn eq(self: &const Item, other: &const Item): bool { return self.key == other.key; } }
        \\struct Box<T> { value: T; }
        \\impl<T: Eq> Box<T>: Eq { fn eq(self: &const Box<T>, other: &const Box<T>): bool { return self.value.eq(&other.value); } }
        \\fn bothWays<T: Eq>(value: T, other: T): bool {
        \\    if value.eq(&other) {
        \\        return other.eq(&value);
        \\    }
        \\    return false;
        \\}
        \\fn main(): i32 {
        \\    var a = Box<Item> { value: Item { key: 1 } };
        \\    var b = Box<Item> { value: Item { key: 2 } };
        \\    if bothWays(a, b) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "distinct_method_use_ids.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "distinct_method_use_ids.cy", program);
    defer module.deinit(allocator);
    try module.verifyGenericRequirements();

    // Every lowered call carries a record naming the concrete callee it reached,
    // the type it settled, and, for a protocol witness, the type arguments its
    // specialization substituted. Two source uses of one operation in a body
    // never share an identity.
    var first_id: u32 = 0;
    var calls: usize = 0;
    var protocol_uses: usize = 0;
    var specialized_uses: usize = 0;
    var concrete_uses: usize = 0;
    var ordinary_uses: usize = 0;
    var shared_specialization: ?sir.TypeId = null;
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .call) continue;
        const use = entry.expr.call.checked_method_use orelse return error.TestUnexpectedResult;
        try std.testing.expect(use.use_id != 0);
        try std.testing.expectEqual(use.callee_declaration_id, entry.expr.call.decl_id);
        try std.testing.expectEqual(use.result_type_id, entry.metadata.type_id);
        if (use.protocol_id == null) {
            // A call that settles to a declaration owns no protocol authority:
            // its record is its own callee identity.
            try std.testing.expectEqual(use.callee_declaration_id, entry.expr.call.decl_id);
            ordinary_uses += 1;
        } else {
            protocol_uses += 1;
            // `bothWays` reaches the impl specialized for `T = Item`; the
            // witness body's own `eq` on a concrete `Item` has no generic
            // parameters left.
            if (use.substitution.len != 0) {
                specialized_uses += 1;
                if (shared_specialization == null) shared_specialization = use.substitution[0];
                try std.testing.expectEqual(shared_specialization.?, use.substitution[0]);
            } else {
                concrete_uses += 1;
            }
        }
        if (calls == 0) first_id = use.use_id;
        try std.testing.expect(use.use_id != first_id or calls == 0);
        calls += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), calls);
    try std.testing.expectEqual(@as(usize, 3), protocol_uses);
    try std.testing.expectEqual(@as(usize, 2), specialized_uses);
    try std.testing.expectEqual(@as(usize, 1), concrete_uses);
    try std.testing.expectEqual(@as(usize, 1), ordinary_uses);
}

test "method-use records reject a forged callee, result, or substitution" {
    const allocator = std.testing.allocator;
    const source =
        \\protocol Eq { fn eq(self: &const Self, other: &const Self): bool; }
        \\struct Item { key: i32; }
        \\impl Item: Eq { fn eq(self: &const Item, other: &const Item): bool { return self.key == other.key; } }
        \\struct Box<T> { value: T; }
        \\impl<T: Eq> Box<T>: Eq { fn eq(self: &const Box<T>, other: &const Box<T>): bool { return self.value.eq(&other.value); } }
        \\fn compare<T: Eq>(left: T, right: T): bool { return left.eq(&right); }
        \\fn unrelated(): string { return "z"; }
        \\fn main(): i32 {
        \\    var a = Box<Item> { value: Item { key: 1 } };
        \\    var b = Box<Item> { value: Item { key: 2 } };
        \\    if compare(a, b) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "forged_method_use.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "forged_method_use.cy", program);
    defer module.deinit(allocator);
    try module.verifyGenericRequirements();

    const entries: []sir.ExprMetadataEntry = @constCast(module.expr_metadata);
    var entry: ?*sir.ExprMetadataEntry = null;
    for (entries, 0..) |candidate, index| {
        if (candidate.expr.* != .call) continue;
        if (candidate.expr.call.checked_method_use == null) continue;
        // Forge the use whose witness carries a specialization: the impl's
        // generic parameter is substituted with `Item` there.
        if (candidate.expr.call.checked_method_use.?.substitution.len == 0) continue;
        entry = &entries[index];
        break;
    }
    const located = entry orelse return error.TestUnexpectedResult;
    const call: *sir.Call = @constCast(&located.expr.call);
    const use = call.checked_method_use.?;
    var foreign_type: ?sir.TypeId = null;
    var foreign_decl: @TypeOf(use.callee_declaration_id) = null;
    for (module.functions) |*function| {
        // `unrelated`'s `string` result is interned by the compilation but is
        // never substituted into `T`, so it is a foreign type for the record.
        if (std.mem.eql(u8, function.name, "unrelated")) foreign_type = function.return_type_id.?;
        if (std.mem.eql(u8, function.name, "main")) foreign_decl = function.decl_id.?;
    }
    if (foreign_type == null or foreign_decl == null) return error.TestUnexpectedResult;
    const other_type = foreign_type.?;
    const other_decl = foreign_decl.?;
    var seen_result = false;
    var seen_callee = false;
    var seen_substitution = false;

    call.checked_method_use.?.result_type_id = other_type;
    try std.testing.expectError(error.IncorrectMethodUseSignature, module.verifyGenericRequirements());
    call.checked_method_use.?.result_type_id = use.result_type_id;
    seen_result = true;

    call.checked_method_use.?.callee_declaration_id = other_decl;
    try std.testing.expectError(error.MissingMethodUseSignature, module.verifyGenericRequirements());
    call.checked_method_use.?.callee_declaration_id = use.callee_declaration_id;
    seen_callee = true;

    // Forge the substitution in place so the record keeps its own allocation:
    // `unrelated`'s `string` type is interned but never substituted into `T`.
    const original_substitution = use.substitution[0];
    @constCast(use.substitution)[0] = other_type;
    try std.testing.expectError(error.InvalidMethodUseSubstitution, module.verifyGenericRequirements());
    @constCast(use.substitution)[0] = original_substitution;
    seen_substitution = true;

    try std.testing.expect(seen_result and seen_callee and seen_substitution);
    try module.verifyGenericRequirements();
}

test "SIR expression metadata retains checked local and global place roots" {
    const allocator = std.testing.allocator;
    const source =
        \\const global_value: i32 = 5;
        \\fn main(): i32 { const local_value = global_value; return local_value; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "checked_place_roots.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "checked_place_roots.cy", program);
    defer module.deinit(allocator);
    const global_id = module.globals[0].decl_id.?;
    const binding_id = module.functions[0].body[0].local.binding_id.?;
    var saw_global = false;
    var saw_local = false;
    for (module.expr_metadata) |entry| {
        const root = entry.metadata.checked_place_root orelse continue;
        switch (root) {
            .global => |id| {
                try std.testing.expectEqual(global_id, id);
                saw_global = true;
            },
            .binding => |id| {
                try std.testing.expectEqual(binding_id, id);
                saw_local = true;
            },
        }
    }
    try std.testing.expect(saw_global and saw_local);
    try module.verifyCompilerIdentities();
    const mutable_entries: []sir.ExprMetadataEntry = @constCast(module.expr_metadata);
    for (mutable_entries) |*entry| {
        const root = entry.metadata.checked_place_root orelse continue;
        switch (root) {
            .binding => {
                entry.metadata.checked_place_root = .{ .binding = @fromBackingInt(@intCast(999999)) };
                try std.testing.expectError(error.InvalidCheckedPlaceRoot, module.verifyCompilerIdentities());
            },
            .global => {
                entry.metadata.checked_place_root = .{ .global = @fromBackingInt(@intCast(999999)) };
                try std.testing.expectError(error.InvalidCheckedPlaceRoot, module.verifyCompilerIdentities());
            },
        }
        entry.metadata.checked_place_root = root;
    }
    try module.verifyCompilerIdentities();
}

test "SIR values have distinct stable temporary identities" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main(): i32 { const first = 1 + 2; const second = 3 + 4; return first + second; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "temporary_ids.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "temporary_ids.cy", program);
    defer module.deinit(allocator);
    var seen = std.AutoHashMap(@TypeOf(module.expr_metadata[0].metadata.temporary_id.?), void).init(allocator);
    defer seen.deinit();
    var count: usize = 0;
    for (module.expr_metadata) |entry| {
        if (entry.metadata.semantics.category != .value) continue;
        const id = entry.metadata.temporary_id orelse return error.MissingTemporaryIdentity;
        try std.testing.expect(!seen.contains(id));
        try seen.put(id, {});
        count += 1;
    }
    try std.testing.expect(count >= 4);

    try module.verifyCompilerIdentities();
    const mutable_entries: []sir.ExprMetadataEntry = @constCast(module.expr_metadata);
    var first_value_index: ?usize = null;
    var second_value_index: ?usize = null;
    for (mutable_entries, 0..) |entry, index| {
        if (entry.metadata.temporary_id == null) continue;
        if (first_value_index == null) {
            first_value_index = index;
        } else {
            second_value_index = index;
            break;
        }
    }
    const first_index = first_value_index orelse return error.MissingTemporaryIdentity;
    const second_index = second_value_index orelse return error.MissingTemporaryIdentity;
    const original_id = mutable_entries[second_index].metadata.temporary_id;
    mutable_entries[second_index].metadata.temporary_id = mutable_entries[first_index].metadata.temporary_id;
    try std.testing.expectError(error.InvalidTemporaryIdentity, module.verifyCompilerIdentities());
    mutable_entries[second_index].metadata.temporary_id = null;
    try std.testing.expectError(error.InvalidTemporaryIdentity, module.verifyCompilerIdentities());
    mutable_entries[second_index].metadata.temporary_id = original_id;
    try module.verifyCompilerIdentities();
}

test "SIR verifier rejects a checked local root from another visible binding" {
    const allocator = std.testing.allocator;
    const source =
        \\fn inspect(left: i32, right: i32): i32 { return left + right; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "scoped_binding_root.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "scoped_binding_root.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    const params: []sir.Param = @constCast(module.functions[0].params);
    const original_right_id = params[1].binding_id;
    params[1].binding_id = params[0].binding_id;
    try std.testing.expectError(error.InvalidBindingIdentity, module.verifyCompilerIdentities());
    params[1].binding_id = @fromBackingInt(@intCast(@as(u64, 1) << 62));
    try std.testing.expectError(error.InvalidBindingIdentity, module.verifyCompilerIdentities());
    params[1].binding_id = original_right_id;
    try module.verifyCompilerIdentities();
    const right_id = module.functions[0].params[1].binding_id.?;
    const entries: []sir.ExprMetadataEntry = @constCast(module.expr_metadata);
    var found = false;
    for (entries) |*entry| {
        if (entry.expr.* != .local or !std.mem.eql(u8, entry.expr.local, "left")) continue;
        const original_root = entry.metadata.checked_place_root orelse continue;
        entry.metadata.checked_place_root = .{ .binding = right_id };
        try std.testing.expectError(error.InvalidCheckedPlaceRoot, module.verifyCompilerIdentities());
        entry.metadata.checked_place_root = original_root;
        try module.verifyCompilerIdentities();
        found = true;
    }
    try std.testing.expect(found);
}

test "SIR projected binding records require a scoped field source and cannot own an effect" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Inner { items: [:]i32; }
        \\struct Owner { value: Inner; }
        \\fn inspect(): i32 {
        \\    var owner = Owner { value: Inner { items: [42] } };
        \\    const field = owner.value;
        \\    return field.items.len() as i32;
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "projected_binding_record.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "projected_binding_record.cy", program);
    defer module.deinit(allocator);
    const body: []sir.Stmt = @constCast(module.functions[0].body);
    const local = &body[1].local;
    const metadata = module.metadataForExpr(local.init) orelse return error.MissingExpressionMetadata;
    const source_place = metadata.checkedPlacePath() orelse return error.MissingPlaceIdentity;
    try module.verifyCompilerIdentities();
    try module.verifyValueActions();

    try std.testing.expectEqual(sir.BindingMode.projected, local.binding_mode);
    try std.testing.expect(std.meta.eql(source_place.root, local.projected_place.?.root));
    try module.verifyCompilerIdentities();
    try module.verifyValueActions();

    local.projected_place.?.root = .{ .binding = local.binding_id.? };
    try std.testing.expectError(error.InvalidBindingIdentity, module.verifyCompilerIdentities());
    local.projected_place.?.root = source_place.root;
    local.projected_place.?.projections = null;
    try std.testing.expectError(error.InvalidBindingIdentity, module.verifyCompilerIdentities());
    local.projected_place.?.projections = source_place.projections;
    local.projected_place.?.non_owning = false;
    try std.testing.expectError(error.InvalidBindingIdentity, module.verifyCompilerIdentities());
    local.projected_place.?.non_owning = true;
    local.checked_effect = .{ .effect = .{ .drop = .{ .place = .{
        .root = .{ .binding = local.binding_id.? },
        .projections = null,
        .non_owning = false,
    } } } };
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
}

test "SIR verifier rejects a checked root from an exited branch scope" {
    const allocator = std.testing.allocator;
    const source =
        \\fn inspect(flag: bool): i32 {
        \\    const outer: i32 = 1;
        \\    if flag { const inner: i32 = 2; return inner; }
        \\    return outer;
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "exited_scope_root.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "exited_scope_root.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    const inner_id = module.functions[0].body[1].@"if".then_body[0].local.binding_id.?;
    const entries: []sir.ExprMetadataEntry = @constCast(module.expr_metadata);
    var found = false;
    for (entries) |*entry| {
        if (entry.expr.* != .local or !std.mem.eql(u8, entry.expr.local, "outer")) continue;
        const original_root = entry.metadata.checked_place_root orelse continue;
        entry.metadata.checked_place_root = .{ .binding = inner_id };
        try std.testing.expectError(error.InvalidCheckedPlaceRoot, module.verifyCompilerIdentities());
        entry.metadata.checked_place_root = original_root;
        try module.verifyCompilerIdentities();
        found = true;
    }
    try std.testing.expect(found);
}

test "SIR verifier checks optional capture binding mapping" {
    const allocator = std.testing.allocator;
    const source =
        \\fn inspect(value: ?i32): i32 { if value is item { return item; } return 0; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "capture_identity.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "capture_identity.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    const mutable_body: []sir.Stmt = @constCast(module.functions[0].body);
    const capture_id = mutable_body[0].@"if".capture_binding_id orelse return error.MissingCaptureIdentity;
    mutable_body[0].@"if".capture_binding_id = null;
    try std.testing.expectError(error.InvalidCaptureIdentity, module.verifyCompilerIdentities());
    mutable_body[0].@"if".capture_binding_id = capture_id;
    try module.verifyCompilerIdentities();
    const capture_type_id = mutable_body[0].@"if".capture_type_id;
    mutable_body[0].@"if".capture_type_id = module.functions[0].params[0].type_id;
    try std.testing.expectError(error.InvalidCaptureIdentity, module.verifyCompilerIdentities());
    mutable_body[0].@"if".capture_type_id = capture_type_id;
    try module.verifyCompilerIdentities();
    const capture_origin = (mutable_body[0].@"if".capture_path orelse return error.MissingCaptureIdentity).source orelse return error.MissingCaptureIdentity;
    try std.testing.expect(capture_origin == .place);
    mutable_body[0].@"if".capture_path.?.source = .{ .place = .{ .root = .{ .binding = capture_id }, .projections = capture_origin.place.projections, .non_owning = capture_origin.place.non_owning } };
    try std.testing.expectError(error.InvalidCaptureIdentity, module.verifyCompilerIdentities());
    mutable_body[0].@"if".capture_path.?.source = capture_origin;
    try module.verifyCompilerIdentities();
    mutable_body[0].@"if".capture_path.?.source = null;
    try std.testing.expectError(error.InvalidCaptureIdentity, module.verifyCompilerIdentities());
    mutable_body[0].@"if".capture_path.?.source = capture_origin;
    try module.verifyCompilerIdentities();
    mutable_body[0].@"if".capture_path.?.source.?.place.non_owning = !capture_origin.place.non_owning;
    try std.testing.expectError(error.InvalidCaptureIdentity, module.verifyCompilerIdentities());
    mutable_body[0].@"if".capture_path.?.source = capture_origin;
    try module.verifyCompilerIdentities();
    const checked_case = (mutable_body[0].@"if".capture_path orelse return error.MissingCaptureIdentity).active_case;
    try std.testing.expect(checked_case == .optional_some);
    mutable_body[0].@"if".capture_path.?.active_case = .{ .result = .ok };
    try std.testing.expectError(error.InvalidCaptureIdentity, module.verifyCompilerIdentities());
    mutable_body[0].@"if".capture_path.?.active_case = checked_case;
    try module.verifyCompilerIdentities();
    const complete_path = mutable_body[0].@"if".capture_path;
    mutable_body[0].@"if".capture_path = null;
    try std.testing.expectError(error.InvalidCaptureIdentity, module.verifyCompilerIdentities());
    mutable_body[0].@"if".capture_path = complete_path;
    try module.verifyCompilerIdentities();
}

test "SIR capture retains the checked source projection sequence" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Holder { maybe: ?i32; }
        \\fn inspect(holder: Holder): i32 {
        \\    if holder.maybe is item { return item; }
        \\    return 0;
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "projected_capture_identity.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "projected_capture_identity.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    const branch = &@constCast(module.functions[0].body)[0].@"if";
    const origin = (branch.capture_path orelse return error.MissingCaptureIdentity).source orelse return error.MissingCaptureIdentity;
    try std.testing.expect(origin == .place);
    const steps = origin.place.projections orelse return error.MissingCheckedPlaceProjection;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    try std.testing.expectEqualStrings("maybe", steps[0].step.field.name);
    branch.capture_path.?.source.?.place.projections = null;
    try std.testing.expectError(error.InvalidCaptureIdentity, module.verifyCompilerIdentities());
    branch.capture_path.?.source = origin;
    try module.verifyCompilerIdentities();
}

test "SIR verifier checks union switch capture binding mapping" {
    const allocator = std.testing.allocator;
    const source =
        \\union Choice { active: i32; empty; }
        \\fn inspect(value: Choice): i32 {
        \\    switch value {
        \\    .active(item) => { return item; }
        \\    .empty => { return 0; }
        \\    }
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "switch_capture_identity.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "switch_capture_identity.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    const mutable_cases: []sir.SwitchCase = @constCast(module.functions[0].body[0].@"switch".cases);
    const capture_id = mutable_cases[0].payload_binding_id orelse return error.MissingCaptureIdentity;
    mutable_cases[0].payload_binding_id = null;
    try std.testing.expectError(error.InvalidCaptureIdentity, module.verifyCompilerIdentities());
    mutable_cases[0].payload_binding_id = capture_id;
    try module.verifyCompilerIdentities();
    const payload_type_id = mutable_cases[0].payload_type_id orelse return error.MissingCaptureIdentity;
    mutable_cases[0].payload_type_id = module.functions[0].params[0].type_id;
    try std.testing.expectError(error.InvalidCaptureIdentity, module.verifyCompilerIdentities());
    mutable_cases[0].payload_type_id = payload_type_id;
    try module.verifyCompilerIdentities();
    const payload_origin = (mutable_cases[0].payload_path orelse return error.MissingCaptureIdentity).source orelse return error.MissingCaptureIdentity;
    try std.testing.expect(payload_origin == .place);
    mutable_cases[0].payload_path.?.source = .{ .place = .{ .root = .{ .binding = capture_id }, .projections = payload_origin.place.projections, .non_owning = payload_origin.place.non_owning } };
    try std.testing.expectError(error.InvalidCaptureIdentity, module.verifyCompilerIdentities());
    mutable_cases[0].payload_path.?.source = payload_origin;
    try module.verifyCompilerIdentities();
    const checked_case = (mutable_cases[0].payload_path orelse return error.MissingCaptureIdentity).active_case;
    try std.testing.expect(checked_case == .union_field);
    mutable_cases[0].payload_path.?.active_case = .{ .union_field = .{ .owner_decl_id = checked_case.union_field.owner_decl_id, .ordinal = 1 } };
    try std.testing.expectError(error.InvalidCaptureIdentity, module.verifyCompilerIdentities());
    mutable_cases[0].payload_path.?.active_case = checked_case;
    try module.verifyCompilerIdentities();
}

test "SIR union switch capture records temporary source identity" {
    const allocator = std.testing.allocator;
    const source =
        \\enum Failure { invalid, }
        \\union Outcome { value: i32; failure: Failure; }
        \\fn make(): Outcome { return .value(42); }
        \\fn inspect(): i32 {
        \\    switch make() {
        \\    .value(item) => { return item; }
        \\    .failure(problem) => { const ignored = problem; return 0; }
        \\    }
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "temporary_capture_identity.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "temporary_capture_identity.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    const function = for (module.functions) |candidate| {
        if (std.mem.eql(u8, candidate.name, "inspect")) break candidate;
    } else return error.TestUnexpectedResult;
    const cases: []sir.SwitchCase = @constCast(function.body[0].@"switch".cases);
    const origin = (cases[0].payload_path orelse return error.MissingCaptureIdentity).source orelse return error.MissingCaptureIdentity;
    try std.testing.expect(origin == .temporary);
    const subject_metadata = module.metadataForExpr(function.body[0].@"switch".value) orelse return error.MissingMetadata;
    try std.testing.expectEqual(subject_metadata.temporary_id.?, origin.temporary);
    cases[0].payload_path.?.source = .{ .place = .{ .root = .{ .binding = @fromBackingInt(@intCast(123)) }, .projections = null, .non_owning = false } };
    try std.testing.expectError(error.InvalidCaptureIdentity, module.verifyCompilerIdentities());
    cases[0].payload_path.?.source = origin;
    try module.verifyCompilerIdentities();
    const checked_case = (cases[0].payload_path orelse return error.MissingCaptureIdentity).active_case;
    try std.testing.expect(checked_case == .union_field);
    cases[0].payload_path.?.active_case = cases[1].payload_path.?.active_case;
    try std.testing.expectError(error.InvalidCaptureIdentity, module.verifyCompilerIdentities());
    cases[0].payload_path.?.active_case = checked_case;
    try module.verifyCompilerIdentities();
}

test "checked place overlap keeps roots fields indices and alias capability distinct" {
    const value_type: sir.TypeId = @fromBackingInt(@intCast(1));
    const owner: compiler.identity.DeclId = @fromBackingInt(@intCast(2));
    var dynamic_index = sir.Expr{ .local = "position" };
    const left_field = [_]sir.CheckedPlaceProjection{.{ .step = .{ .field = .{ .owner_decl_id = owner, .name = "left" } }, .result_type_id = value_type }};
    const right_field = [_]sir.CheckedPlaceProjection{.{ .step = .{ .field = .{ .owner_decl_id = owner, .name = "right" } }, .result_type_id = value_type }};
    const first = [_]sir.CheckedPlaceProjection{.{ .step = .{ .index = .{ .fixed = 0 } }, .result_type_id = value_type }};
    const second = [_]sir.CheckedPlaceProjection{.{ .step = .{ .index = .{ .fixed = 1 } }, .result_type_id = value_type }};
    const dynamic = [_]sir.CheckedPlaceProjection{.{ .step = .{ .index = .{ .dynamic = &dynamic_index } }, .result_type_id = value_type }};
    const nested = [_]sir.CheckedPlaceProjection{ left_field[0], first[0] };
    const union_left = [_]sir.CheckedPlaceProjection{.{ .step = .{ .union_payload = .{ .owner_decl_id = owner, .name = "left" } }, .result_type_id = value_type }};
    const union_right = [_]sir.CheckedPlaceProjection{.{ .step = .{ .union_payload = .{ .owner_decl_id = owner, .name = "right" } }, .result_type_id = value_type }};
    const range = [_]sir.CheckedPlaceProjection{.{ .step = .{ .range = .{ .start = .{ .fixed = 0 }, .end = .{ .fixed = 1 } } }, .result_type_id = value_type }};
    const later_range = [_]sir.CheckedPlaceProjection{.{ .step = .{ .range = .{ .start = .{ .fixed = 1 }, .end = .{ .fixed = 2 } } }, .result_type_id = value_type }};
    const root = sir.CheckedPlacePath{ .root = .{ .binding = @fromBackingInt(@intCast(1)) }, .projections = null, .non_owning = false };
    const left = sir.CheckedPlacePath{ .root = root.root, .projections = &left_field, .non_owning = false };
    const right = sir.CheckedPlacePath{ .root = root.root, .projections = &right_field, .non_owning = false };
    const indexed = sir.CheckedPlacePath{ .root = root.root, .projections = &first, .non_owning = false };
    const another = sir.CheckedPlacePath{ .root = root.root, .projections = &second, .non_owning = false };
    const unknown = sir.CheckedPlacePath{ .root = root.root, .projections = &dynamic, .non_owning = false };
    const nested_place = sir.CheckedPlacePath{ .root = root.root, .projections = &nested, .non_owning = false };
    const first_range = sir.CheckedPlacePath{ .root = root.root, .projections = &range, .non_owning = true };
    const second_range = sir.CheckedPlacePath{ .root = root.root, .projections = &later_range, .non_owning = true };
    try std.testing.expect(root.mayOverlap(left) and left.mayOverlap(root));
    try std.testing.expect(!left.mayOverlap(right) and !right.mayOverlap(left));
    try std.testing.expect(left.mayOverlap(nested_place) and nested_place.mayOverlap(left));
    try std.testing.expect(!right.mayOverlap(nested_place));
    try std.testing.expect(!indexed.mayOverlap(another));
    try std.testing.expect(indexed.mayOverlap(unknown) and unknown.mayOverlap(another));
    try std.testing.expect(first_range.mayOverlap(indexed) and indexed.mayOverlap(first_range));
    try std.testing.expect(!first_range.mayOverlap(another) and !first_range.mayOverlap(second_range));
    try std.testing.expect(!sir.CheckedPlacePath.mayOverlap(.{ .root = root.root, .projections = &union_left, .non_owning = false }, .{ .root = root.root, .projections = &union_right, .non_owning = false }));
    try std.testing.expect(!left.mayOverlap(.{ .root = .{ .binding = @fromBackingInt(@intCast(3)) }, .projections = &left_field, .non_owning = false }));
    const borrowed = sir.CheckedPlacePath{ .root = root.root, .projections = &left_field, .non_owning = true };
    try std.testing.expect(borrowed.mayOverlap(left));
    try std.testing.expect(!borrowed.canOwn() and left.canOwn());
}

test "SIR place metadata carries typed nested field projections" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Inner { value: i32; }
        \\struct Outer { inner: Inner; }
        \\fn main(): i32 { const holder = Outer { inner: Inner { value: 42 } }; return holder.inner.value; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "checked_place_projections.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "checked_place_projections.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    const binding_id = module.functions[0].body[0].local.binding_id.?;
    var found = false;
    for (module.expr_metadata) |entry| {
        const steps = entry.metadata.checked_place_projections orelse continue;
        if (steps.len != 2) continue;
        try std.testing.expectEqual(binding_id, entry.metadata.checked_place_root.?.binding);
        try std.testing.expectEqualStrings("inner", steps[0].step.field.name);
        try std.testing.expectEqualStrings("value", steps[1].step.field.name);
        try std.testing.expectEqual(entry.metadata.type_id, steps[1].result_type_id);
        const mutable_steps: []sir.CheckedPlaceProjection = @constCast(steps);
        const original_name = mutable_steps[0].step.field.name;
        mutable_steps[0].step.field.name = "wrong";
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        mutable_steps[0].step.field.name = original_name;
        try module.verifyCompilerIdentities();
        found = true;
    }
    try std.testing.expect(found);
}

test "SIR place metadata verifies fixed index projection" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main(): i32 { const values: [2]i32 = [10, 20]; return values[1]; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "checked_place_index.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "checked_place_index.cy", program);
    defer module.deinit(allocator);
    var found = false;
    for (module.expr_metadata) |entry| {
        const steps = entry.metadata.checked_place_projections orelse continue;
        if (steps.len != 1 or steps[0].step != .index) continue;
        try std.testing.expectEqual(@as(i64, 1), steps[0].step.index.fixed);
        const mutable_steps: []sir.CheckedPlaceProjection = @constCast(steps);
        mutable_steps[0].step.index = .{ .fixed = 0 };
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        mutable_steps[0].step.index = .{ .fixed = 1 };
        try module.verifyCompilerIdentities();
        found = true;
    }
    try std.testing.expect(found);
}

test "SIR place metadata retains dynamic index expression identity" {
    const allocator = std.testing.allocator;
    const source =
        \\fn read(values: [2]i32, position: usize): i32 { return values[position]; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "checked_dynamic_index.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "checked_dynamic_index.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    const expr = module.functions[0].body[0].@"return".?;
    try std.testing.expect(expr.* == .index);
    const metadata = module.metadataForExpr(expr) orelse return error.MissingMetadata;
    const steps = metadata.checked_place_projections orelse return error.MissingCheckedPlaceProjection;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    try std.testing.expect(steps[0].step.index == .dynamic);
    try std.testing.expectEqual(expr.index.index, steps[0].step.index.dynamic);
    const mutable_steps: []sir.CheckedPlaceProjection = @constCast(steps);
    mutable_steps[0].step.index = .{ .dynamic = expr.index.object };
    try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
    mutable_steps[0].step.index = .{ .dynamic = expr.index.index };
    try module.verifyCompilerIdentities();
}

test "SIR slice range retains checked non-owning source and bounds" {
    const allocator = std.testing.allocator;
    const source =
        \\fn inspect(values: [4]i32, start: usize): i32 {
        \\    const view = values[start..3];
        \\    return view[0];
        \\}
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "checked_slice_range.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "checked_slice_range.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    const expr = module.functions[0].body[0].local.init;
    try std.testing.expect(expr.* == .slice_range);
    const metadata = module.metadataForExpr(expr) orelse return error.MissingMetadata;
    const place = metadata.checkedPlacePath() orelse return error.MissingCheckedPlaceRoot;
    try std.testing.expect(!place.canOwn());
    try std.testing.expectEqual(module.functions[0].params[0].binding_id.?, place.root.binding);
    const steps = place.projections orelse return error.MissingCheckedPlaceProjection;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    try std.testing.expectEqual(expr.slice_range.start.?, steps[0].step.range.start.?.dynamic);
    try std.testing.expectEqual(@as(i64, 3), steps[0].step.range.end.?.fixed);
    const mutable_steps: []sir.CheckedPlaceProjection = @constCast(steps);
    mutable_steps[0].step.range.start = .{ .dynamic = expr.slice_range.object };
    try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
    mutable_steps[0].step.range.start = .{ .dynamic = expr.slice_range.start.? };
    try module.verifyCompilerIdentities();
    const entries: []sir.ExprMetadataEntry = @constCast(module.expr_metadata);
    for (entries) |*entry| {
        if (entry.expr != expr) continue;
        entry.metadata.non_owning_place_origin = false;
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        entry.metadata.non_owning_place_origin = true;
        try module.verifyCompilerIdentities();
        break;
    }
}

test "raw dereference does not acquire an owned checked place root" {
    const allocator = std.testing.allocator;
    const source =
        \\fn read(ptr: *i32): i32 { unchecked { return *ptr; } }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "raw_deref_place_identity.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "raw_deref_place_identity.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    const entries: []sir.ExprMetadataEntry = @constCast(module.expr_metadata);
    var found = false;
    for (entries) |*entry| {
        if (entry.expr.* != .raw_deref) continue;
        try std.testing.expect(entry.metadata.checked_place_root == null);
        try std.testing.expect(entry.metadata.checked_place_projections == null);
        const raw_deref = entry.metadata.checked_raw_deref orelse return error.MissingCheckedRawDeref;
        try std.testing.expectEqual(module.functions[0].params[0].binding_id.?, raw_deref.pointer_source.binding);
        try std.testing.expectEqual(entry.metadata.type_id, raw_deref.pointee_type_id);
        entry.metadata.checked_place_root = .{ .binding = module.functions[0].params[0].binding_id.? };
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        entry.metadata.checked_place_root = null;
        try module.verifyCompilerIdentities();
        entry.metadata.checked_raw_deref.?.pointer_source = .{ .binding = @fromBackingInt(@intCast(999)) };
        try std.testing.expectError(error.InvalidCheckedPlaceRoot, module.verifyCompilerIdentities());
        entry.metadata.checked_raw_deref = raw_deref;
        try module.verifyCompilerIdentities();
        found = true;
    }
    try std.testing.expect(found);
}

test "raw address-of dereference records non-owning pointer provenance" {
    const allocator = std.testing.allocator;
    const source =
        \\fn alias(ptr: *i32): &i32 { unchecked { return &*ptr; } }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "raw_address_of_identity.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "raw_address_of_identity.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    const entries: []sir.ExprMetadataEntry = @constCast(module.expr_metadata);
    var found = false;
    for (entries) |*entry| {
        if (entry.expr.* != .ref_raw_deref) continue;
        try std.testing.expect(entry.metadata.checked_place_root == null);
        try std.testing.expect(entry.metadata.checked_place_projections == null);
        const checked = entry.metadata.checked_raw_deref orelse return error.MissingCheckedRawDeref;
        try std.testing.expectEqual(module.functions[0].params[0].binding_id.?, checked.pointer_source.binding);
        entry.metadata.checked_raw_deref.?.pointee_type_id = module.functions[0].params[0].type_id.?;
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        entry.metadata.checked_raw_deref = checked;
        try module.verifyCompilerIdentities();
        found = true;
    }
    try std.testing.expect(found);
}

test "raw field alias retains inner dereference provenance" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\fn alias(ptr: *Box): &i32 { unchecked { return &(*ptr).value; } }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "raw_field_alias_identity.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "raw_field_alias_identity.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    const entries: []sir.ExprMetadataEntry = @constCast(module.expr_metadata);
    var found = false;
    for (entries) |*entry| {
        if (entry.expr.* != .ref_raw_deref) continue;
        const checked = entry.metadata.checked_raw_deref orelse return error.MissingCheckedRawDeref;
        try std.testing.expectEqual(module.functions[0].params[0].binding_id.?, checked.pointer_source.binding);
        entry.metadata.checked_raw_deref.?.pointer_source = .{ .binding = @fromBackingInt(@intCast(999)) };
        try std.testing.expectError(error.InvalidCheckedPlaceRoot, module.verifyCompilerIdentities());
        entry.metadata.checked_raw_deref = checked;
        try module.verifyCompilerIdentities();
        found = true;
    }
    try std.testing.expect(found);
}

test "generic requirement inspection follows lexical aliases fields and projection identity" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Holder<Stored> { item: Stored; }
        \\fn inspect<T>(left: T, right: T, holder: &const Holder<T>): bool {
        \\    const alias = left;
        \\    const field = holder.item;
        \\    return alias == right and field == right;
        \\}
        \\fn projected<T>(value: T): bool {
        \\    const item = value.item;
        \\    const projected_equal = item == item;
        \\    const direct_equal = value == value;
        \\    return projected_equal and direct_equal;
        \\}
        \\fn concrete<T>(value: T): bool { const local: i32 = 1; return local == local; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "generic_lexical_requirements.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "generic_lexical_requirements.cy", program);
    defer module.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 8), module.generic_requirements.len);
    var direct_eq: usize = 0;
    var projected_eq: usize = 0;
    for (module.generic_requirements) |requirement| {
        try std.testing.expect(requirement.declaration_id != null);
        try std.testing.expect(requirement.declared_protocol == null);
        try std.testing.expectEqualStrings("T", requirement.parameter);
        try std.testing.expect(!std.mem.eql(u8, requirement.declaration, "concrete"));
        if (std.mem.eql(u8, requirement.declaration, "projected")) {
            if (std.mem.eql(u8, requirement.operation, "eq")) {
                if (requirement.projected) projected_eq += 1 else direct_eq += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 2), direct_eq);
    try std.testing.expectEqual(@as(usize, 2), projected_eq);
    const text = try dumpModule(allocator, module);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "[projection]") != null);
}

test "generic alternative return requirements retain both declared origins" {
    const allocator = std.testing.allocator;
    // Two binders each reach a method use on their own branch, so each origin is
    // recorded from the use the checked flow actually reaches.
    const source =
        \\protocol Secret { fn secret(self: &const Self): i32; }
        \\fn inspect<T: Secret, U: Secret>(left: T, right: U): i32 {
        \\    if left.secret() > 0 {
        \\        return right.secret();
        \\    }
        \\    return 0;
        \\}
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "generic_alternative_requirements.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "generic_alternative_requirements.cy", program);
    defer module.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), module.generic_requirements.len);
    try std.testing.expectEqualStrings("T", module.generic_requirements[0].parameter);
    try std.testing.expectEqualStrings("U", module.generic_requirements[1].parameter);
    try std.testing.expect(module.generic_requirements[0].parameter_definition_offset != null);
    try std.testing.expect(module.generic_requirements[1].parameter_definition_offset != null);
    try std.testing.expect(module.generic_requirements[0].parameter_definition_offset.? != module.generic_requirements[1].parameter_definition_offset.?);
    try std.testing.expect(module.generic_requirements[0].parameter_id != null);
    try std.testing.expect(module.generic_requirements[1].parameter_id != null);
    try std.testing.expect(!std.meta.eql(module.generic_requirements[0].parameter_id.?, module.generic_requirements[1].parameter_id.?));
    for (module.generic_requirements) |requirement| {
        try std.testing.expectEqualStrings("inspect", requirement.declaration);
        try std.testing.expectEqualStrings("secret", requirement.operation);
        try std.testing.expectEqualStrings("Secret", requirement.declared_protocol.?.name);
    }
    const output = try dumpModule(allocator, module);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "inspect<T>: secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "inspect<U>: secret") != null);
}

test "generic alternative container indexing retains both declared element origins" {
    const allocator = std.testing.allocator;
    const source =
        \\protocol Secret { fn secret(self: &const Self): i32; }
        \\fn inspect<T: Secret, U: Secret>(left: [1]T, right: [1]U): i32 {
        \\    return left[0].secret() + right[0].secret();
        \\}
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "generic_alternative_index_requirements.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "generic_alternative_index_requirements.cy", program);
    defer module.deinit(allocator);
    var seen_t = false;
    var seen_u = false;
    for (module.generic_requirements) |requirement| {
        if (!std.mem.eql(u8, requirement.operation, "secret")) continue;
        try std.testing.expectEqualStrings("Secret", requirement.declared_protocol.?.name);
        if (std.mem.eql(u8, requirement.parameter, "T")) seen_t = true;
        if (std.mem.eql(u8, requirement.parameter, "U")) seen_u = true;
    }
    try std.testing.expect(seen_t and seen_u);
}

test "generic alternative try and slice retain both declared payload origins" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "generic_alternative_try_requirements.cy", .source =
        \\enum Failure { invalid, }
        \\protocol Secret { fn secret(self: &const Self): i32; }
        \\fn source<T>(value: T): T!Failure { return value; }
        \\fn inspect<T: Secret, U: Secret>(left: T, right: U): i32!Failure {
        \\    const payload = try source(left);
        \\    const other = try source(right);
        \\    return payload.secret() + other.secret();
        \\}
        \\fn main(): i32 { return 0; }
        },
        .{ .name = "generic_alternative_slice_requirements.cy", .source =
        \\protocol Secret { fn secret(self: &const Self): i32; }
        \\fn inspect<T: Secret, U: Secret>(left: [1]T, right: [1]U): i32 {
        \\    const head = left[0..1][0];
        \\    const tail = right[0..1][0];
        \\    return head.secret() + tail.secret();
        \\}
        \\fn main(): i32 { return 0; }
        },
    };
    for (cases) |case| {
        const tokens = try lexer.lexAll(allocator, case.source);
        defer allocator.free(tokens);
        const program = try parser.parse(allocator, case.name, case.source, tokens);
        defer program.deinit(allocator);
        const module = try sema.buildSir(allocator, case.name, program);
        defer module.deinit(allocator);
        var seen_t = false;
        var seen_u = false;
        for (module.generic_requirements) |requirement| {
            if (!std.mem.eql(u8, requirement.operation, "secret")) continue;
            try std.testing.expectEqualStrings("Secret", requirement.declared_protocol.?.name);
            if (std.mem.eql(u8, requirement.parameter, "T")) seen_t = true;
            if (std.mem.eql(u8, requirement.parameter, "U")) seen_u = true;
        }
        try std.testing.expect(seen_t and seen_u);
    }
}

test "generic sequence literal retains every declared element origin" {
    const allocator = std.testing.allocator;
    // A literal whose elements come from two different binders has no element
    // type, so each origin keeps its own annotated literal; every element use
    // still records the binder it reaches.
    const source =
        \\protocol Secret { fn secret(self: &const Self): i32; }
        \\fn inspect<T: Secret, U: Secret>(left: T, right: U): i32 {
        \\    const items: [2]T = [left, left];
        \\    const others: [2]U = [right, right];
        \\    return items[0].secret() + others[1].secret();
        \\}
        \\fn main(): i32 { return 0; }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "generic_sequence_requirements.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "generic_sequence_requirements.cy", program);
    defer module.deinit(allocator);
    var seen_t = false;
    var seen_u = false;
    for (module.generic_requirements) |requirement| {
        if (!std.mem.eql(u8, requirement.operation, "secret")) continue;
        try std.testing.expectEqualStrings("Secret", requirement.declared_protocol.?.name);
        if (std.mem.eql(u8, requirement.parameter, "T")) seen_t = true;
        if (std.mem.eql(u8, requirement.parameter, "U")) seen_u = true;
    }
    try std.testing.expect(seen_t and seen_u);
}

test "AST summary covers representative declaration families" {
    const allocator = std.testing.allocator;
    const source =
        \\const answer: i32 = 42;
        \\pub enum State { ready, }
        \\union Maybe { value: i32; empty; }
        \\protocol Readable {
        \\    fn read(self: Self): i32;
        \\}
        \\struct Reader {
        \\    value: i32;
        \\}
        \\impl Reader: Readable {
        \\    fn read(self: Reader): i32 { return self.value; }
        \\}
        \\test "reads" {
        \\    assert(true);
        \\}
        \\fn main(): i32 { return answer; }
    ;

    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "ast_declarations.cy", source, tokens);
    defer program.deinit(allocator);

    const ast_text = try commands.build.renderAstText(allocator, program);
    defer allocator.free(ast_text);
    try std.testing.expectEqualStrings(
        \\ast-summary-v1
        \\const answer: i32
        \\pub enum State (1 cases)
        \\union Maybe (2 cases)
        \\protocol Readable (0 associated types, 1 methods)
        \\impl Reader: Readable
        \\struct Reader (1 fields, 0 methods)
        \\fn main (0 params): i32 (1 statements)
        \\test "reads" (1 statements)
        \\
    , ast_text);
}

test "representative LLVM artifact remains stable" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main(): i32 {
        \\    return 42;
        \\}
    ;

    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "llvm_baseline.cy", source, tokens);
    defer program.deinit(allocator);
    const sir_module = try sema.buildSir(allocator, "llvm_baseline.cy", program);
    defer sir_module.deinit(allocator);
    const lir_module = try lower.lowerModuleWithOptions(allocator, sir_module, .{
        .fallback_source_path = "llvm_baseline.cy",
    });
    defer lir_module.deinit(allocator);
    const llvm_text = try llvm_backend.emitModule(allocator, lir_module);
    defer allocator.free(llvm_text);

    const expected_llvm =
        \\; ModuleID = 'cyna'
        \\@.cyna.alloc.file = private unnamed_addr constant [34 x i8] c"compiler/backend/llvm/emitter.zig\00"
        \\@.cyna.alloc.dense.copy.data = private unnamed_addr constant [25 x i8] c"compiler.dense.copy.data\00"
        \\@.cyna.alloc.sparse.copy.occupied = private unnamed_addr constant [30 x i8] c"compiler.sparse.copy.occupied\00"
        \\@.cyna.alloc.sparse.copy.data = private unnamed_addr constant [26 x i8] c"compiler.sparse.copy.data\00"
        \\@.cyna.alloc.sparse.indices.data = private unnamed_addr constant [29 x i8] c"compiler.sparse.indices.data\00"
        \\@.cyna.alloc.dense.reserve.data = private unnamed_addr constant [28 x i8] c"compiler.dense.reserve.data\00"
        \\@.cyna.alloc.sparse.new.occupied = private unnamed_addr constant [29 x i8] c"compiler.sparse.new.occupied\00"
        \\@.cyna.alloc.sparse.new.data = private unnamed_addr constant [25 x i8] c"compiler.sparse.new.data\00"
        \\@.cyna.alloc.dense.runtime.object = private unnamed_addr constant [30 x i8] c"compiler.dense.runtime.object\00"
        \\@.cyna.alloc.sparse.runtime.object = private unnamed_addr constant [31 x i8] c"compiler.sparse.runtime.object\00"
        \\
        \\@cyna_desc_u8 = external global { i64, i64, i32, ptr, ptr, ptr, ptr, ptr }
        \\@cyna_desc_i32 = external global { i64, i64, i32, ptr, ptr, ptr, ptr, ptr }
        \\@cyna_desc_bool = external global { i64, i64, i32, ptr, ptr, ptr, ptr, ptr }
        \\@cyna_desc_i64 = external global { i64, i64, i32, ptr, ptr, ptr, ptr, ptr }
        \\@cyna_desc_f32 = external global { i64, i64, i32, ptr, ptr, ptr, ptr, ptr }
        \\@cyna_desc_f64 = external global { i64, i64, i32, ptr, ptr, ptr, ptr, ptr }
        \\@cyna_desc_string = external global { i64, i64, i32, ptr, ptr, ptr, ptr, ptr }
        \\
        \\declare void @llvm.trap()
        \\declare void @cyna_trace_release_abi(ptr, ptr)
        \\declare void @cyna_assert_fail()
        \\declare void @cyna_runtime_assertion_fail()
        \\declare void @cyna_runtime_bounds_fail(i64, i64)
        \\declare void @cyna_runtime_capacity_fail(i64, i64)
        \\declare ptr @cyna_runtime_tracked_alloc(i64)
        \\declare ptr @cyna_runtime_tracked_alloc_site(i64, ptr, i64, ptr)
        \\declare void @cyna_runtime_tracked_free(ptr)
        \\define i32 @main() !dbg !5 {
        \\bb0_bb0:
        \\  call void asm sideeffect "", ""(), !dbg !6
        \\  ret i32 42
        \\}
        \\
        \\!llvm.dbg.cu = !{!0}
        \\!llvm.module.flags = !{!1, !2}
        \\!llvm.ident = !{!3}
        \\!0 = distinct !DICompileUnit(language: DW_LANG_C, file: !4, producer: "cyna", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug)
        \\!1 = !{i32 7, !"Dwarf Version", i32 4}
        \\!2 = !{i32 2, !"Debug Info Version", i32 3}
        \\!3 = !{!"cyna"}
        \\!4 = !DIFile(filename: "llvm_baseline.cy", directory: ".")
        \\!7 = !DISubroutineType(types: !{})
        \\!5 = distinct !DISubprogram(name: "main", linkageName: "main", scope: !4, file: !4, line: 1, type: !7, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !0)
        \\!6 = !DILocation(line: 1, column: 4, scope: !5)
        \\
    ;
    try std.testing.expectEqualStrings(expected_llvm, llvm_text);
}

test "error-return calls share one boundary trace context through direct and indirect calls" {
    const allocator = std.testing.allocator;
    const source =
        \\enum Fault { bad; }
        \\fn fail(): i32!Fault { throw Fault.bad; }
        \\fn rethrow(code: Fault): i32!Fault { throw code; }
        \\fn direct(): i32!Fault { return fail(); }
        \\fn indirect(): i32!Fault {
        \\    const callback: fn(): i32!Fault = direct;
        \\    return callback();
        \\}
        \\fn main(): i32 { return indirect() catch (code) { yield 9; }; }
    ;

    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "trace_context_abi.cy", source, tokens);
    defer program.deinit(allocator);
    const sir_module = try sema.buildSir(allocator, "trace_context_abi.cy", program);
    defer sir_module.deinit(allocator);
    var source_throws: usize = 0;
    var direct_local_throws: usize = 0;
    for (sir_module.functions) |function| {
        for (function.body) |stmt| {
            if (stmt != .@"return") continue;
            const returned = stmt.@"return" orelse continue;
            if (returned.* != .union_case or !returned.union_case.from_throw) continue;
            if (std.mem.eql(u8, function.name, "fail")) source_throws += 1;
            if (std.mem.eql(u8, function.name, "rethrow") and
                returned.union_case.throw_local_binding_id == function.params[0].binding_id)
            {
                direct_local_throws += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), source_throws);
    try std.testing.expectEqual(@as(usize, 1), direct_local_throws);
    const lir_module = try lower.lowerModuleWithOptions(allocator, sir_module, .{
        .fallback_source_path = "trace_context_abi.cy",
    });
    defer lir_module.deinit(allocator);
    var catch_entries: usize = 0;
    for (lir_module.functions) |function| for (function.blocks) |block| {
        if (block.catch_failure != null) catch_entries += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), catch_entries);
    const llvm_text = try llvm_backend.emitModule(allocator, lir_module);
    defer allocator.free(llvm_text);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, llvm_text, "= call ptr @cyna_trace_new()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, llvm_text, "call void @cyna_trace_release_root(ptr %trace_context)"));
    try std.testing.expect(std.mem.count(u8, llvm_text, "ptr %trace_context)") >= 5);
}

test "lowering preserves SIR verifier identity and phase context" {
    const invalid_module: sir.Module = .{
        .globals = &.{},
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &.{},
    };
    try std.testing.expectError(error.MissingCanonicalTypes, lower.lowerModule(std.testing.allocator, invalid_module));

    var message_buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "internal compiler error during SIR-to-LIR lowering: SIR has no canonical type graph [MissingCanonicalTypes]",
        compiler.internal_error.message(&message_buffer, .sir_to_lir, error.MissingCanonicalTypes).?,
    );
    try std.testing.expectEqualStrings(
        "internal compiler error during LIR-to-LLVM emission: LIR inline-assembly tables are inconsistent [InvalidInlineAsm]",
        compiler.internal_error.message(&message_buffer, .lir_to_llvm, error.InvalidInlineAsm).?,
    );
    try std.testing.expectEqualStrings(
        "internal compiler error during SIR-to-LIR lowering: verified SIR state has no matching lowering invariant case [LowerInvariantViolation]",
        compiler.internal_error.message(&message_buffer, .sir_to_lir, error.LowerInvariantViolation).?,
    );
    try std.testing.expectEqualStrings(
        "internal compiler error during LIR-to-LLVM emission: verified LIR state has no matching LLVM emission invariant case [BackendInvariantViolation]",
        compiler.internal_error.message(&message_buffer, .lir_to_llvm, error.BackendInvariantViolation).?,
    );
}

test "representative SIR and LIR dumps remain stable" {
    const allocator = std.testing.allocator;
    const source =
        \\const answer: i32 = 40;
        \\
        \\fn add(value: i32): i32 {
        \\    const next: i32 = value + 2;
        \\    return next;
        \\}
        \\
        \\fn main(): i32 {
        \\    return add(answer);
        \\}
    ;

    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "phase_baseline.cy", source, tokens);
    defer program.deinit(allocator);

    const sir_module = try sema.buildSir(allocator, "phase_baseline.cy", program);
    defer sir_module.deinit(allocator);
    try std.testing.expect(sir_module.globals[0].decl_id != null);
    try std.testing.expect(sir_module.functions[0].decl_id != null);
    try std.testing.expect(sir_module.functions[1].decl_id != null);
    try std.testing.expect(sir_module.globals[0].decl_id.? != sir_module.functions[0].decl_id.?);
    try std.testing.expect(sir_module.functions[0].decl_id.? != sir_module.functions[1].decl_id.?);
    const main_call = sir_module.functions[1].body[0].@"return".?.call;
    try std.testing.expectEqual(sir_module.functions[0].decl_id.?, main_call.decl_id.?);
    try std.testing.expectEqual(sir_module.globals[0].decl_id.?, main_call.args[0].value.global_ref.decl_id.?);

    const sir_text = try dumpModule(allocator, sir_module);
    defer allocator.free(sir_text);

    const lir_module = try lower.lowerModule(allocator, sir_module);
    defer lir_module.deinit(allocator);
    const lir_text = try dumpModule(allocator, lir_module);
    defer allocator.free(lir_text);

    const expected_sir =
        \\const answer: i32 = 40
        \\fn add(value: i32): i32 {
        \\  var next: i32 = (value add 2)
        \\  return next
        \\}
        \\fn main(): i32 {
        \\  return add(.answer)
        \\}
        \\
    ;
    const expected_lir =
        \\globals:
        \\  const answer: i32 = "cyna_global_5cf2e69687d91119_answer" = 40
        \\
        \\fn cyna_fn_cde3a3e368582d5a_add(%value: i32) -> i32
        \\locals:
        \\  local#0 value: i32
        \\  local#1 next: i32
        \\bb0_bb0:
        \\  %0 = stack_alloc i32
        \\  %1 = param_ref 0
        \\  store %0, %1
        \\  %2 = stack_alloc i32
        \\  %3 = load %0
        \\  %4 = const_int 2
        \\  %5 = int_to_int %4
        \\  %6 = int_binop add %3, %5
        \\  store %2, %6
        \\  %7 = load %2
        \\  return %7
        \\
        \\fn main() -> i32
        \\bb0_bb0:
        \\  %0 = global_addr cyna_global_5cf2e69687d91119_answer
        \\  %1 = load %0
        \\  %2 = call cyna_fn_cde3a3e368582d5a_add(%1)
        \\  return %2
        \\
    ;
    try std.testing.expectEqualStrings(expected_sir, sir_text);
    try std.testing.expectEqualStrings(expected_lir, lir_text);

    const mutable_main_call = &@constCast(sir_module.functions[1].body)[0].@"return".?.call;
    const mutable_global_ref = &mutable_main_call.args[0].value.global_ref;
    const saved_call_module = mutable_main_call.module_name;
    const saved_call_name = mutable_main_call.callee;
    const saved_global_module = mutable_global_ref.module_name;
    const saved_global_name = mutable_global_ref.name;
    mutable_main_call.module_name = "wrong.module";
    mutable_main_call.callee = "wrong_function";
    mutable_global_ref.module_name = "wrong.module";
    mutable_global_ref.name = "wrong_global";
    const id_lowered_module = try lower.lowerModule(allocator, sir_module);
    defer id_lowered_module.deinit(allocator);
    const id_lowered_text = try dumpModule(allocator, id_lowered_module);
    defer allocator.free(id_lowered_text);
    try std.testing.expectEqualStrings(expected_lir, id_lowered_text);
    mutable_main_call.module_name = saved_call_module;
    mutable_main_call.callee = saved_call_name;
    mutable_global_ref.module_name = saved_global_module;
    mutable_global_ref.name = saved_global_name;

    const mutable_globals = @constCast(sir_module.globals);
    const saved_global_id = mutable_globals[0].decl_id;
    mutable_globals[0].decl_id = null;
    try std.testing.expectError(error.InvalidCheckedPlaceRoot, lower.lowerModule(allocator, sir_module));
    mutable_globals[0].decl_id = saved_global_id;

    const saved_call_id = mutable_main_call.decl_id;
    mutable_main_call.decl_id = null;
    // The ordered call sites still carry the callee's effects, so the module
    // is rejected before lowering resolves a callee at all.
    try std.testing.expectError(error.InvalidCheckedEffect, lower.lowerModule(allocator, sir_module));
    mutable_main_call.decl_id = saved_call_id;
}

test "nominal declarations require stable identity before lowering" {
    const allocator = std.testing.allocator;
    const source =
        \\enum Status: i32 {
        \\    ready,
        \\}
        \\
        \\union Payload {
        \\    value: i32;
        \\}
        \\
        \\struct Point {
        \\    x: i32;
        \\}
        \\
        \\struct Holder {
        \\    point: Point;
        \\    payload: Payload;
        \\    status: Status;
        \\    maybe_point: ?Point;
        \\    points: [2]Point;
        \\}
        \\
        \\fn status(): Status {
        \\    return Status.ready;
        \\}
        \\
        \\fn inspect(value: Holder, points: []Point, point: &Point): i32 {
        \\    return 0;
        \\}
        \\
        \\fn make_payload(): Payload {
        \\    return .value(42);
        \\}
        \\
        \\fn read_payload(payload: Payload): i32 {
        \\    return payload.value;
        \\}
        \\
        \\fn switch_status(value: Status): i32 {
        \\    switch value {
        \\        Status.ready => {
        \\            return 1;
        \\        }
        \\    }
        \\}
        \\
        \\fn switch_payload(payload: Payload): i32 {
        \\    switch payload {
        \\        .value(value) => {
        \\            return value;
        \\        }
        \\    }
        \\}
        \\
        \\fn narrow_payload(payload: Payload): i32 {
        \\    if payload is .value(value) {
        \\        return value;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn construct_and_ref(): i32 {
        \\    var point: Point = { x: 1 };
        \\    const field_ref = &point.x;
        \\    return 0;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "nominal_identity.cy", source, tokens);
    defer program.deinit(allocator);

    const sir_module = try sema.buildSir(allocator, "nominal_identity.cy", program);
    defer sir_module.deinit(allocator);
    try std.testing.expect(sir_module.enums[0].decl_id != null);
    try std.testing.expect(sir_module.unions[0].decl_id != null);
    try std.testing.expect(sir_module.structs[0].decl_id != null);
    try std.testing.expect(sir_module.structs[1].decl_id != null);
    try std.testing.expect(sir_module.enums[0].decl_id.? != sir_module.unions[0].decl_id.?);
    try std.testing.expect(sir_module.unions[0].decl_id.? != sir_module.structs[0].decl_id.?);
    const holder_fields = @constCast(sir_module.structs[1].fields);
    const canonical_types = &sir_module.canonical_types.?;
    const point_node = try canonical_types.get(holder_fields[0].type_id.?);
    const payload_node = try canonical_types.get(holder_fields[1].type_id.?);
    const status_node = try canonical_types.get(holder_fields[2].type_id.?);
    const optional_point_node = try canonical_types.get(holder_fields[3].type_id.?);
    const array_point_node = try canonical_types.get(holder_fields[4].type_id.?);
    const slice_point_node = try canonical_types.get(sir_module.functions[1].params[1].type_id.?);
    const ref_point_node = try canonical_types.get(sir_module.functions[1].params[2].type_id.?);
    try std.testing.expectEqual(sir_module.structs[0].decl_id.?, point_node.nominal.decl_id);
    try std.testing.expectEqual(sir_module.unions[0].decl_id.?, payload_node.nominal.decl_id);
    try std.testing.expectEqual(sir_module.enums[0].decl_id.?, status_node.nominal.decl_id);
    try std.testing.expectEqual(sir_module.structs[0].decl_id.?, (try canonical_types.get(optional_point_node.optional)).nominal.decl_id);
    try std.testing.expectEqual(sir_module.structs[0].decl_id.?, (try canonical_types.get(array_point_node.array.item)).nominal.decl_id);
    try std.testing.expectEqual(sir_module.structs[0].decl_id.?, (try canonical_types.get(slice_point_node.slice.item)).nominal.decl_id);
    try std.testing.expectEqual(sir_module.structs[0].decl_id.?, (try canonical_types.get(ref_point_node.ref_.target)).nominal.decl_id);
    const enum_case = &@constCast(sir_module.functions[0].body)[0].@"return".?.enum_case;
    try std.testing.expectEqual(sir_module.enums[0].decl_id.?, enum_case.decl_id.?);
    const union_case = &@constCast(sir_module.functions[2].body)[0].@"return".?.union_case;
    const union_field = &@constCast(sir_module.functions[3].body)[0].@"return".?.union_field;
    const enum_switch = &@constCast(sir_module.functions[4].body)[0].@"switch";
    const union_switch = &@constCast(sir_module.functions[5].body)[0].@"switch";
    const union_if = &@constCast(sir_module.functions[6].body)[0].@"if";
    const construct_body = @constCast(sir_module.functions[7].body);
    const point_literal = &construct_body[0].local.init.struct_literal;
    const point_field_ref = &construct_body[1].local.init.ref_field_local;
    try std.testing.expectEqual(sir_module.unions[0].decl_id.?, union_case.decl_id.?);
    try std.testing.expectEqual(sir_module.unions[0].decl_id.?, union_field.union_decl_id.?);
    const payload_expr = sir_module.functions[3].body[0].@"return".?;
    const payload_metadata = sir_module.metadataForExpr(payload_expr) orelse return error.MissingMetadata;
    const payload_steps = payload_metadata.checked_place_projections orelse return error.MissingCheckedPlaceProjection;
    try std.testing.expectEqual(@as(usize, 1), payload_steps.len);
    try std.testing.expectEqualStrings("value", payload_steps[0].step.union_payload.name);
    const mutable_payload_steps: []sir.CheckedPlaceProjection = @constCast(payload_steps);
    const saved_payload_name = mutable_payload_steps[0].step.union_payload.name;
    mutable_payload_steps[0].step.union_payload.name = "wrong";
    try std.testing.expectError(error.InvalidCheckedPlaceProjection, sir_module.verifyCompilerIdentities());
    mutable_payload_steps[0].step.union_payload.name = saved_payload_name;
    try sir_module.verifyCompilerIdentities();
    try std.testing.expectEqual(sir_module.enums[0].decl_id.?, enum_switch.subject_decl_id.?);
    try std.testing.expectEqual(sir_module.unions[0].decl_id.?, union_switch.subject_decl_id.?);
    try std.testing.expectEqual(sir_module.unions[0].decl_id.?, union_if.union_decl_id.?);
    try std.testing.expectEqual(sir_module.structs[0].decl_id.?, point_literal.decl_id.?);
    try std.testing.expectEqual(sir_module.structs[0].decl_id.?, point_field_ref.struct_decl_id.?);

    const lowered = try lower.lowerModule(allocator, sir_module);
    lowered.deinit(allocator);

    const saved_enum_name = enum_case.type_name;
    enum_case.type_name = "WrongStatus";
    const identity_lowered = try lower.lowerModule(allocator, sir_module);
    identity_lowered.deinit(allocator);
    enum_case.type_name = saved_enum_name;

    const saved_union_case_name = union_case.union_name;
    const saved_union_field_name = union_field.union_name;
    union_case.union_name = "WrongPayloadCase";
    union_field.union_name = "WrongPayloadField";
    const union_identity_lowered = try lower.lowerModule(allocator, sir_module);
    union_identity_lowered.deinit(allocator);
    union_case.union_name = saved_union_case_name;
    union_field.union_name = saved_union_field_name;

    const saved_enum_switch_name = enum_switch.subject_type_name;
    const saved_union_switch_name = union_switch.subject_type_name;
    enum_switch.subject_type_name = "WrongStatusSwitch";
    union_switch.subject_type_name = "WrongPayloadSwitch";
    const switch_identity_lowered = try lower.lowerModule(allocator, sir_module);
    switch_identity_lowered.deinit(allocator);
    enum_switch.subject_type_name = saved_enum_switch_name;
    union_switch.subject_type_name = saved_union_switch_name;

    const saved_literal_name = point_literal.type_name;
    const saved_ref_struct_name = point_field_ref.struct_name;
    point_literal.type_name = "WrongLiteralPoint";
    point_field_ref.struct_name = "WrongRefPoint";
    const expression_identity_lowered = try lower.lowerModule(allocator, sir_module);
    expression_identity_lowered.deinit(allocator);
    point_literal.type_name = saved_literal_name;
    point_field_ref.struct_name = saved_ref_struct_name;

    const saved_optional_type_id = holder_fields[3].type_id;
    holder_fields[3].type_id = null;
    try std.testing.expectError(error.InvalidIdentity, lower.lowerModule(allocator, sir_module));
    holder_fields[3].type_id = saved_optional_type_id;

    const saved_field_type_id = holder_fields[0].type_id;
    holder_fields[0].type_id = null;
    try std.testing.expectError(error.InvalidIdentity, lower.lowerModule(allocator, sir_module));
    holder_fields[0].type_id = saved_field_type_id;

    const saved_literal_id = point_literal.decl_id;
    point_literal.decl_id = null;
    try std.testing.expectError(error.InvalidIdentity, lower.lowerModule(allocator, sir_module));
    point_literal.decl_id = saved_literal_id;

    const saved_ref_struct_id = point_field_ref.struct_decl_id;
    point_field_ref.struct_decl_id = null;
    try std.testing.expectError(error.InvalidCheckedPlaceProjection, lower.lowerModule(allocator, sir_module));
    point_field_ref.struct_decl_id = saved_ref_struct_id;

    const saved_union_case_id = union_case.decl_id;
    union_case.decl_id = null;
    try std.testing.expectError(error.InvalidIdentity, lower.lowerModule(allocator, sir_module));
    union_case.decl_id = saved_union_case_id;

    const saved_union_field_id = union_field.union_decl_id;
    union_field.union_decl_id = null;
    try std.testing.expectError(error.InvalidCheckedPlaceProjection, lower.lowerModule(allocator, sir_module));
    union_field.union_decl_id = saved_union_field_id;

    const saved_enum_switch_id = enum_switch.subject_decl_id;
    enum_switch.subject_decl_id = null;
    try std.testing.expectError(error.InvalidIdentity, lower.lowerModule(allocator, sir_module));
    enum_switch.subject_decl_id = saved_enum_switch_id;

    const saved_union_switch_id = union_switch.subject_decl_id;
    union_switch.subject_decl_id = null;
    try std.testing.expectError(error.InvalidIdentity, lower.lowerModule(allocator, sir_module));
    union_switch.subject_decl_id = saved_union_switch_id;

    const saved_union_if_id = union_if.union_decl_id;
    union_if.union_decl_id = null;
    try std.testing.expectError(error.InvalidIdentity, lower.lowerModule(allocator, sir_module));
    union_if.union_decl_id = saved_union_if_id;

    const mutable_enums = @constCast(sir_module.enums);
    const saved_enum_id = mutable_enums[0].decl_id;
    mutable_enums[0].decl_id = null;
    try std.testing.expectError(error.InvalidIdentity, lower.lowerModule(allocator, sir_module));
    mutable_enums[0].decl_id = saved_enum_id;

    const mutable_unions = @constCast(sir_module.unions);
    const saved_union_id = mutable_unions[0].decl_id;
    mutable_unions[0].decl_id = null;
    try std.testing.expectError(error.InvalidCheckedPlaceProjection, lower.lowerModule(allocator, sir_module));
    mutable_unions[0].decl_id = saved_union_id;

    const mutable_structs = @constCast(sir_module.structs);
    const saved_struct_id = mutable_structs[0].decl_id;
    mutable_structs[0].decl_id = null;
    try std.testing.expectError(error.InvalidIdentity, lower.lowerModule(allocator, sir_module));
    mutable_structs[0].decl_id = saved_struct_id;
}

test "generated arrow adapter parameters carry distinct binding identities" {
    const allocator = std.testing.allocator;
    const source =
        \\fn add_one(value: i32): i32 { return value + 1; }
        \\fn apply(callback: (i32) => i32): i32 { return callback(41); }
        \\fn main(): i32 { return apply(add_one); }
    ;
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "generated_adapter_bindings.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try sema.buildSir(allocator, "generated_adapter_bindings.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    var found = false;
    for (module.functions) |function| {
        if (!std.mem.startsWith(u8, function.name, "__cyna_arrow_adapter_")) continue;
        try std.testing.expectEqual(@as(usize, 2), function.params.len);
        const environment_id = function.params[0].binding_id orelse return error.MissingBindingIdentity;
        const argument_id = function.params[1].binding_id orelse return error.MissingBindingIdentity;
        try std.testing.expect(environment_id != argument_id);
        var mapped = false;
        const entries: []sir.ExprMetadataEntry = @constCast(module.expr_metadata);
        for (entries) |*entry| {
            if (entry.expr.* != .local or !std.mem.eql(u8, entry.expr.local, function.params[1].name)) continue;
            const root = entry.metadata.checked_place_root orelse continue;
            if (root != .binding or root.binding != argument_id) continue;
            entry.metadata.checked_place_root = .{ .binding = environment_id };
            try std.testing.expectError(error.InvalidCheckedPlaceRoot, module.verifyCompilerIdentities());
            entry.metadata.checked_place_root = root;
            try module.verifyCompilerIdentities();
            mapped = true;
        }
        try std.testing.expect(mapped);
        found = true;
    }
    try std.testing.expect(found);
}

test "closure environments lower through generated declaration identity" {
    const allocator = std.testing.allocator;
    const source =
        \\fn apply(value: i32, f: (i32) => i32): i32 {
        \\    return f(value);
        \\}
        \\
        \\fn main(): i32 {
        \\    const bias = 1;
        \\    return apply(41, |x| {
        \\        return x + bias;
        \\    });
        \\}
    ;

    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, "closure_environment_identity.cy", source, tokens);
    defer program.deinit(allocator);

    const sir_module = try sema.buildSir(allocator, "closure_environment_identity.cy", program);
    defer sir_module.deinit(allocator);

    const main_call = &@constCast(sir_module.functions[1].body)[1].@"return".?.call;
    const closure = &main_call.args[1].value.closure;
    try std.testing.expect(closure.env_decl_id != null);

    const lowered = try lower.lowerModule(allocator, sir_module);
    lowered.deinit(allocator);

    const saved_env_name = closure.env_type_name;
    closure.env_type_name = "WrongClosureEnvironment";
    const identity_lowered = try lower.lowerModule(allocator, sir_module);
    identity_lowered.deinit(allocator);
    closure.env_type_name = saved_env_name;

    const saved_env_id = closure.env_decl_id;
    closure.env_decl_id = null;
    try std.testing.expectError(error.InvalidCheckedEffect, sir_module.verifyValueActions());
    try std.testing.expectError(error.InvalidCheckedEffect, lower.lowerModule(allocator, sir_module));
    closure.env_decl_id = saved_env_id;
}

const origin_probe = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    loaded: loader.LoadedProgram,
    module: sir.Module,

    fn load(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !origin_probe {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try compat.dirWriteFile(tmp.dir, .{
            .sub_path = "cyna.toml",
            .data =
            \\name = "origin_probe"
            \\src = "."
            \\
            ,
        });
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = path, .data = source });
        const root = try compat.tmpDirRealpathAlloc(allocator, &tmp, ".");
        defer allocator.free(root);
        const file = try std.fs.path.join(allocator, &.{ root, path });
        defer allocator.free(file);
        var loaded = try loader.loadProgramWithOptions(allocator, file, .{
            .diagnostic_context = .{ .destination = .stderr },
        });
        errdefer loaded.deinit(allocator);
        const module = try sema.buildSirWithOptions(allocator, file, loaded.program, .{
            .diagnostic_context = .{ .destination = .stderr },
        });
        return origin_probe{
            .allocator = allocator,
            .tmp = tmp,
            .loaded = loaded,
            .module = module,
        };
    }

    fn deinit(self: *origin_probe) void {
        self.module.deinit(self.allocator);
        self.loaded.deinit(self.allocator);
        self.tmp.cleanup();
    }

    fn function(self: *const origin_probe, name: []const u8) ?*const sir.Function {
        for (self.module.functions) |*candidate| {
            if (std.mem.eql(u8, candidate.name, name)) return candidate;
        }
        return null;
    }

    fn run(self: *origin_probe, store: *generic_origins.Store, target: *const sir.Function) !?*const generic_origins.Fact {
        const types = if (self.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
        const adapter = generic_origins.TypeAdapter{ .types = types };
        var params: std.ArrayListUnmanaged(*const generic_origins.Fact) = .empty;
        defer params.deinit(self.allocator);
        for (target.params) |param| {
            const ty = param.type_id orelse return error.TestUnexpectedResult;
            try params.append(self.allocator, try adapter.unknownFact(store, ty));
        }
        var prepared = try generic_origins.PreparedStraightLine.init(self.allocator, adapter, target, self.module.expr_metadata, self.module.structs, self.module.unions, params.items);
        defer prepared.deinit();
        prepared.expression.functions = self.module.functions;
        const result = try prepared.run(store);
        defer result.deinit(self.allocator);
        return result.returned;
    }
};

fn copiedBody(allocator: std.mem.Allocator, target: *const sir.Function) ![]const sir.Stmt {
    return allocator.dupe(sir.Stmt, target.body);
}

/// Run one checked function body against a locally copied statement slice so a
/// probe can corrupt SIR payload identity without touching the loaded module.
fn runVariant(
    probe: *const origin_probe,
    store: *generic_origins.Store,
    target: *const sir.Function,
    body: []const sir.Stmt,
) (generic_origins.PreparedStraightLine.Error || error{TestUnexpectedResult})!?*const generic_origins.Fact {
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var params: std.ArrayListUnmanaged(*const generic_origins.Fact) = .empty;
    defer params.deinit(probe.allocator);
    for (target.params) |param| {
        const ty = param.type_id orelse return error.TestUnexpectedResult;
        try params.append(probe.allocator, try adapter.unknownFact(store, ty));
    }
    var variant = target.*;
    variant.body = body;
    var prepared = try generic_origins.PreparedStraightLine.init(probe.allocator, adapter, &variant, probe.module.expr_metadata, probe.module.structs, probe.module.unions, params.items);
    defer prepared.deinit();
    prepared.expression.functions = probe.module.functions;
    const result = try prepared.run(store);
    defer result.deinit(probe.allocator);
    return result.returned;
}

/// Run a checked body with explicitly supplied parameter facts and keep the
/// whole edge result, so a test can inspect reachability as well as the joined
/// return fact.
fn flowVariant(
    probe: *const origin_probe,
    store: *generic_origins.Store,
    target: *const sir.Function,
    params: []const *const generic_origins.Fact,
) (generic_origins.PreparedStraightLine.Error || error{TestUnexpectedResult})!generic_origins.StraightLineFlow.Result {
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var prepared = try generic_origins.PreparedStraightLine.init(probe.allocator, adapter, target, probe.module.expr_metadata, probe.module.structs, probe.module.unions, params);
    defer prepared.deinit();
    prepared.expression.functions = probe.module.functions;
    return try prepared.run(store);
}

/// The same edge walk as `flowVariant`, but over a copied statement slice so a
/// probe can hand the flow a body the borrow checker itself would reject.
fn flowBodyVariant(
    probe: *const origin_probe,
    store: *generic_origins.Store,
    target: *const sir.Function,
    params: []const *const generic_origins.Fact,
    body: []const sir.Stmt,
) (generic_origins.PreparedStraightLine.Error || error{TestUnexpectedResult})!generic_origins.StraightLineFlow.Result {
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    var variant = target.*;
    variant.body = body;
    var prepared = try generic_origins.PreparedStraightLine.init(probe.allocator, adapter, &variant, probe.module.expr_metadata, probe.module.structs, probe.module.unions, params);
    defer prepared.deinit();
    prepared.expression.functions = probe.module.functions;
    return try prepared.run(store);
}

const container_source =
    \\fn pushLiteral(): i32 {
    \\    var items: [:]i32 = [1, 2];
    \\    items.push(3);
    \\    return items[0];
    \\}
    \\fn widenedItem(values: [:]i32): i32 {
    \\    var items: [:]i32 = [1, 2];
    \\    items.push(values[0]);
    \\    return items[0];
    \\}
    \\fn popLiteral(): i32 {
    \\    var items: [:]i32 = [4, 5];
    \\    return items.pop();
    \\}
    \\fn clearAll(items: [:]i32): usize { items.clear(); return items.len(); }
    \\fn reserveItems(items: [:]i32, capacity: usize): usize { items.reserve(capacity); return items.len(); }
    \\fn keyedSlot(slots: [;]i32, key: usize, value: i32): i32 {
    \\    slots.insert(key, value);
    \\    const found = slots.take(key);
    \\    slots.clear();
    \\    if found == none { return 0; }
    \\    return value;
    \\}
    \\fn hasSlot(slots: [;]i32, key: usize): bool { return slots.contains_index(key); }
    \\fn either(left: bool, right: bool): bool { return left and right or left; }
    \\fn label(): string { return "checked"; }
;

test "checked origin transfer accepts every checked container mutation and read form" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "container_origins.cy", container_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();

    for ([_]([]const u8){ "pushLiteral", "widenedItem", "popLiteral", "clearAll", "reserveItems", "keyedSlot", "hasSlot", "either" }) |name| {
        const function = probe.function(name) orelse return error.TestUnexpectedResult;
        _ = try probe.run(&store, function);
    }

    // A literal container keeps its concrete element origin after a checked push.
    const concrete = try probe.run(&store, probe.function("pushLiteral") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expect(concrete.receiver.* == .set);
    // An element with no checked origin widens the container element fact.
    const widened = try probe.run(&store, probe.function("widenedItem") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expect(widened.receiver.* == .unresolved);
}

test "checked container origins reject corrupted receiver, payload, and operand identity" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "container_corruption.cy", container_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();

    const scalar = probe.function("label") orelse return error.TestUnexpectedResult;
    try std.testing.expect(scalar.body[0] == .@"return");
    const scalar_leaf = scalar.body[0].@"return" orelse return error.TestUnexpectedResult;
    try std.testing.expect(scalar_leaf.* == .string);

    // A push whose checked receiver is not a container has no element origin.
    const push = probe.function("pushLiteral") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, push);
        defer allocator.free(body);
        try std.testing.expect(body[1] == .expr);
        const node = @constCast(body[1].expr);
        const receiver = node.sequence_push.object;
        const payload = node.sequence_push.value;
        node.sequence_push.object = payload;
        node.sequence_push.value = receiver;
        try std.testing.expectError(error.IncorrectResultType, runVariant(&probe, &store, push, body));
        node.sequence_push.object = receiver;
        node.sequence_push.value = payload;
    }

    // A pop projected from a scalar leaf has no sequence element to take.
    const pop = probe.function("popLiteral") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, pop);
        defer allocator.free(body);
        try std.testing.expect(body[0] == .local and body[1] == .@"return");
        const node = @constCast(body[1].@"return" orelse return error.TestUnexpectedResult);
        try std.testing.expect(node.* == .sequence_pop);
        const container = node.sequence_pop;
        node.sequence_pop = scalar_leaf;
        try std.testing.expectError(error.UnsupportedExpression, runVariant(&probe, &store, pop, body));
        node.sequence_pop = container;
    }

    // Reserve requires a dense container and an integer capacity.
    const reserve = probe.function("reserveItems") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, reserve);
        defer allocator.free(body);
        try std.testing.expect(body[0] == .expr);
        const node = @constCast(body[0].expr);
        const receiver = node.sequence_reserve.object;
        const capacity = node.sequence_reserve.capacity;
        node.sequence_reserve.object = capacity;
        node.sequence_reserve.capacity = receiver;
        try std.testing.expectError(error.IncorrectResultType, runVariant(&probe, &store, reserve, body));
        node.sequence_reserve.object = receiver;
        node.sequence_reserve.capacity = capacity;
    }

    // Sparse insertion checks the element type against the declared container.
    const insert = probe.function("keyedSlot") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, insert);
        defer allocator.free(body);
        try std.testing.expect(body[0] == .expr and body[1] == .local);
        const node = @constCast(body[0].expr);
        const index = node.sparse_insert.index;
        const value = node.sparse_insert.value;
        node.sparse_insert.index = value;
        node.sparse_insert.value = index;
        try std.testing.expectError(error.IncorrectResultType, runVariant(&probe, &store, insert, body));
        node.sparse_insert.index = index;
        node.sparse_insert.value = value;
    }

    // A take whose receiver and index are exchanged addresses a scalar.
    {
        const body = try copiedBody(allocator, insert);
        defer allocator.free(body);
        const take = @constCast(body[1].local.init);
        try std.testing.expect(take.* == .sparse_take);
        const receiver = take.sparse_take.object;
        const index = take.sparse_take.index;
        take.sparse_take.object = index;
        take.sparse_take.index = receiver;
        try std.testing.expectError(error.IncorrectResultType, runVariant(&probe, &store, insert, body));
        take.sparse_take.object = receiver;
        take.sparse_take.index = index;
    }

    // Short-circuit operands must both be checked booleans.
    const binary = probe.function("either") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, binary);
        defer allocator.free(body);
        try std.testing.expect(body[0] == .@"return");
        const node = @constCast(body[0].@"return" orelse return error.TestUnexpectedResult);
        try std.testing.expect(node.* == .binary);
        const operand = node.binary.right;
        node.binary.right = scalar_leaf;
        try std.testing.expectError(error.IncorrectResultType, runVariant(&probe, &store, binary, body));
        node.binary.right = operand;
    }
}

fn probeOutcome(
    allocator: std.mem.Allocator,
    lines: *std.ArrayListUnmanaged(u8),
    label: []const u8,
    outcome: (generic_origins.PreparedStraightLine.Error || error{TestUnexpectedResult})!?*const generic_origins.Fact,
) !void {
    try lines.appendSlice(allocator, label);
    if (outcome) |maybe| {
        if (maybe) |fact| {
            try lines.appendSlice(allocator, "ok ");
            try lines.appendSlice(allocator, @tagName(fact.receiver.*));
            for (fact.children) |child| {
                try lines.appendSlice(allocator, " ");
                try lines.appendSlice(allocator, @tagName(child.key));
            }
        } else {
            try lines.appendSlice(allocator, "null");
        }
    } else |err| {
        try lines.appendSlice(allocator, "error ");
        try lines.appendSlice(allocator, @errorName(err));
    }
    try lines.appendSlice(allocator, "\n");
}

const concurrency_source =
    \\import std.thread;
    \\import std.sync;
    \\import { TaskGroup } from std.thread;
    \\
    \\fn worker(value: i32): i32 { return value + 1; }
    \\fn sink(value: i32): void {}
    \\
    \\fn spawnReturn(payload: i32): Thread!ThreadError {
    \\    return thread.spawn(sink, payload);
    \\}
    \\fn sharedReturn(value: i32): Shared<i32> {
    \\    return sync.shared(value);
    \\}
    \\fn label(): string { return "checked"; }
    \\
    \\fn main(): i32 {
    \\    const group = TaskGroup.init(2 as u32) catch (problem) { return 4; };
    \\    const task = group.spawn(worker, 41) catch (problem) { group.cancel_and_wait(); return 3; };
    \\    const value = task.join() catch (problem) { group.cancel_and_wait(); return 2; };
    \\    group.finish();
    \\    return value;
    \\}
;

fn functionWithOwner(probe: *const origin_probe, name: []const u8, owner: []const u8) ?*const sir.Function {
    for (probe.module.functions) |*candidate| {
        if (!std.mem.eql(u8, candidate.name, name)) continue;
        if (candidate.owner) |candidate_owner| if (std.mem.eql(u8, candidate_owner, owner)) return candidate;
    }
    return null;
}

test "checked origin transfer accepts compiler produced concurrency payload transfers" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "concurrency_origins.cy", concurrency_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();

    // A boxed thread spawn keeps the payload origin beside the result cases.
    const thread_spawn = probe.function("spawnReturn") orelse return error.TestUnexpectedResult;
    const spawned = try probe.run(&store, thread_spawn) orelse return error.TestUnexpectedResult;
    try std.testing.expect(spawned.child(.result_ok) != null);
    try std.testing.expect(spawned.child(.result_err) != null);
    try std.testing.expect(spawned.child(.spawn_payload) != null);

    // A shared handle records the value it captured.
    const shared = probe.function("sharedReturn") orelse return error.TestUnexpectedResult;
    const shared_fact = try probe.run(&store, shared) orelse return error.TestUnexpectedResult;
    try std.testing.expect(shared_fact.child(.{ .type_argument = 0 }) != null);
    try std.testing.expect(shared_fact.child(.spawn_payload) != null);
    const shared_specialization = probe.function("shared<i32>") orelse return error.TestUnexpectedResult;
    _ = try probe.run(&store, shared_specialization);

    // The generated TaskGroup and Task specializations settle their boxed
    // transfer, extern call, and result take forms without a rejected tag.
    const group_spawn = functionWithOwner(&probe, "spawn<i32, i32>", "TaskGroup") orelse return error.TestUnexpectedResult;
    const group_fact = try probe.run(&store, group_spawn) orelse return error.TestUnexpectedResult;
    try std.testing.expect(group_fact.child(.result_ok) != null);
    try std.testing.expect(group_fact.child(.result_err) != null);

    const task_join = functionWithOwner(&probe, "join", "Task<i32>") orelse return error.TestUnexpectedResult;
    const joined = try probe.run(&store, task_join) orelse return error.TestUnexpectedResult;
    try std.testing.expect(joined.child(.result_ok) != null);
    try std.testing.expect(joined.child(.result_err) != null);
}

test "checked concurrency payload transfers reject corrupted identity and payload facts" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "concurrency_corruption.cy", concurrency_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();

    const scalar = probe.function("label") orelse return error.TestUnexpectedResult;
    try std.testing.expect(scalar.body[0] == .@"return");
    const wrong_leaf = @constCast(scalar.body[0].@"return" orelse return error.TestUnexpectedResult);
    try std.testing.expect(wrong_leaf.* == .string);

    // thread_spawn_boxed needs its trampoline identity and a typed payload.
    const thread_spawn = probe.function("spawnReturn") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, thread_spawn);
        defer allocator.free(body);
        try std.testing.expect(body[0] == .@"return");
        const node = @constCast(body[0].@"return" orelse return error.TestUnexpectedResult);
        try std.testing.expect(node.* == .thread_spawn_boxed);
        const payload = node.thread_spawn_boxed.payload;
        const trampoline = node.thread_spawn_boxed.trampoline.decl_id;
        node.thread_spawn_boxed.trampoline.decl_id = null;
        try std.testing.expectError(error.MissingIntrinsicIdentity, runVariant(&probe, &store, thread_spawn, body));
        node.thread_spawn_boxed.trampoline.decl_id = trampoline;
        node.thread_spawn_boxed.payload = wrong_leaf;
        try std.testing.expectError(error.IncorrectPayloadFactType, runVariant(&probe, &store, thread_spawn, body));
        node.thread_spawn_boxed.payload = payload;
    }

    // sync_share_boxed keeps its declaration identity and payload type.
    const share = probe.function("shared<i32>") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, share);
        defer allocator.free(body);
        var node: ?*sir.Expr = null;
        for (body) |*stmt| {
            if (stmt.* != .@"return") continue;
            const expr = stmt.@"return" orelse continue;
            if (expr.* == .sync_share_boxed) node = expr;
        }
        const boxed = node orelse return error.TestUnexpectedResult;
        try std.testing.expect(boxed.* == .sync_share_boxed);
        const payload = boxed.sync_share_boxed.payload;
        const decl = boxed.sync_share_boxed.decl_id;
        boxed.sync_share_boxed.decl_id = null;
        try std.testing.expectError(error.MissingIntrinsicIdentity, runVariant(&probe, &store, share, body));
        boxed.sync_share_boxed.decl_id = decl;
        boxed.sync_share_boxed.payload = wrong_leaf;
        try std.testing.expectError(error.IncorrectPayloadFactType, runVariant(&probe, &store, share, body));
        boxed.sync_share_boxed.payload = payload;
    }

    // task_group_spawn_boxed checks the group, entry, and payload origins.
    const group_spawn = functionWithOwner(&probe, "spawn<i32, i32>", "TaskGroup") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, group_spawn);
        defer allocator.free(body);
        try std.testing.expect(body[0] == .local);
        const node = @constCast(body[0].local.init);
        try std.testing.expect(node.* == .task_group_spawn_boxed);
        const payload = node.task_group_spawn_boxed.payload;
        const group = node.task_group_spawn_boxed.group_raw;
        node.task_group_spawn_boxed.group_raw = payload;
        node.task_group_spawn_boxed.payload = group;
        try std.testing.expectError(error.IncorrectPayloadFactType, runVariant(&probe, &store, group_spawn, body));
        node.task_group_spawn_boxed.group_raw = group;
        node.task_group_spawn_boxed.payload = payload;
        const intrinsic = node.task_group_spawn_boxed.intrinsic_id;
        node.task_group_spawn_boxed.intrinsic_id = null;
        try std.testing.expectError(error.MissingIntrinsicIdentity, runVariant(&probe, &store, group_spawn, body));
        node.task_group_spawn_boxed.intrinsic_id = intrinsic;
    }

    // task_result_take keeps its intrinsic identity and declared value type.
    const task_join = functionWithOwner(&probe, "join", "Task<i32>") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, task_join);
        defer allocator.free(body);
        var take: ?*sir.Expr = null;
        for (body) |*stmt| {
            if (stmt.* != .@"return") continue;
            const expr = stmt.@"return" orelse continue;
            if (expr.* == .task_result_take) take = expr;
        }
        const node = take orelse return error.TestUnexpectedResult;
        const value_type = node.task_result_take.value_type_id;
        node.task_result_take.intrinsic_id = null;
        try std.testing.expectError(error.MissingIntrinsicIdentity, runVariant(&probe, &store, task_join, body));
        node.task_result_take.intrinsic_id = .std_task_result_take_impl;
        node.task_result_take.value_type_id = null;
        try std.testing.expectError(error.MissingCallResult, runVariant(&probe, &store, task_join, body));
        node.task_result_take.value_type_id = value_type;
    }
}

const transfer_source =
    \\struct Bag {
    \\    values: [2]i32;
    \\    item: ?i32;
    \\    slots: [;]i32;
    \\}
    \\
    \\const counter: i32 = 7;
    \\
    \\fn apply(value: i32, f: (i32) => i32): i32 { return f(value); }
    \\
    \\fn namedAdd(value: i32): i32 { return value + 2; }
    \\fn callNamed(f: fn(i32): i32, value: i32): i32 { return f(value); }
    \\fn useNamed(): i32 { return callNamed(namedAdd, 3); }
    \\
    \\fn takeOptional(): ?i32 {
    \\    var opt: ?i32 = 42;
    \\    return take opt;
    \\}
    \\fn takeField(bag: &Bag): ?i32 { return take bag.item; }
    \\fn takeSlot(): ?i32 {
    \\    var slots: [;]i32 = [;]i32{ 0: 3, 2: 5 };
    \\    return take slots[0];
    \\}
    \\fn globalRead(): i32 { return counter + 1; }
    \\fn globalBorrow(): &const i32 { return &counter; }
    \\fn closureValue(): i32 {
    \\    const bias = 1;
    \\    return apply(41, |x| { return x + bias; });
    \\}
    \\fn rawHandle(): *Bag {
    \\    var bag = new Bag { values: [1, 2], item: none, slots: [;]i32{} };
    \\    unchecked {
    \\        return bag.ptr();
    \\    }
    \\}
    \\fn leakHandle(): *Bag {
    \\    var bag = new Bag { values: [5, 6], item: none, slots: [;]i32{} };
    \\    unchecked {
    \\        return bag.leak();
    \\    }
    \\}
    \\fn rawRead(): i32 {
    \\    var bag = new Bag { values: [3, 4], item: none, slots: [;]i32{} };
    \\    unchecked {
    \\        const ptr: *Bag = bag.ptr();
    \\        return (*ptr).values[0];
    \\    }
    \\}
    \\fn rawReadForeign(handle: *Bag): i32 {
    \\    unchecked {
    \\        return (*handle).values[0];
    \\    }
    \\}
    \\fn rawView(): &Bag {
    \\    var bag = new Bag { values: [7, 8], item: none, slots: [;]i32{} };
    \\    unchecked {
    \\        const ptr: *Bag = bag.ptr();
    \\        return &(*ptr);
    \\    }
    \\}
    \\fn asmValue(): i32 {
    \\    unchecked {
    \\        const value = asm(i32) {
    \\            "add {result}, {input}";
    \\            out reg result;
    \\            in reg input = 42;
    \\        };
    \\        return value;
    \\    }
    \\}
;

fn isConcreteCarrier(fact: *const generic_origins.Fact) bool {
    if (fact.receiver.* != .set) return false;
    if (fact.receiver.set.len != 1) return false;
    return std.mem.eql(u8, @tagName(fact.receiver.set[0]), "concrete");
}

fn firstExprWithBody(body: []const sir.Stmt, wanted: []const u8) ?*sir.Expr {
    for (body) |stmt| {
        const found = firstExprWithStmt(stmt, wanted);
        if (found) |expr| return expr;
    }
    return null;
}

fn firstExprWithStmt(stmt: sir.Stmt, wanted: []const u8) ?*sir.Expr {
    switch (stmt) {
        .@"return" => |expr| {
            if (expr) |value| {
                if (firstExprWithExpr(value, wanted)) |found| return found;
            }
        },
        .@"defer" => |expr| {
            if (firstExprWithExpr(expr, wanted)) |found| return found;
        },
        .@"try" => |attempt| {
            if (firstExprWithExpr(attempt.expr, wanted)) |found| return found;
        },
        .local => |local| {
            if (firstExprWithExpr(local.init, wanted)) |found| return found;
        },
        .expr => |expr| {
            if (firstExprWithExpr(expr, wanted)) |found| return found;
        },
        .unchecked => |inner| {
            for (inner) |nested| {
                if (firstExprWithStmt(nested, wanted)) |found| return found;
            }
        },
        else => {},
    }
    return null;
}

fn firstExprWithExpr(expr: *const sir.Expr, wanted: []const u8) ?*sir.Expr {
    if (std.mem.eql(u8, @tagName(expr.*), wanted)) return @constCast(expr);
    switch (expr.*) {
        .binary => |binary| {
            if (firstExprWithExpr(binary.left, wanted)) |found| return found;
            return firstExprWithExpr(binary.right, wanted);
        },
        .field => |field| return firstExprWithExpr(field.object, wanted),
        .raw_deref, .ref_raw_deref => |deref| return firstExprWithExpr(deref.expr, wanted),
        .ref_field_expr => |field| return firstExprWithExpr(field.object, wanted),
        .index, .borrowed_index => |index| {
            if (firstExprWithExpr(index.object, wanted)) |found| return found;
            return firstExprWithExpr(index.index, wanted);
        },
        .sparse_take => |take| {
            if (firstExprWithExpr(take.object, wanted)) |found| return found;
            return firstExprWithExpr(take.index, wanted);
        },
        .take_path_local => |path| {
            for (path.steps) |step| {
                switch (step) {
                    .index => |index| {
                        if (firstExprWithExpr(index, wanted)) |found| return found;
                    },
                    .field => {},
                }
            }
            return null;
        },
        .string_slice => |slice| {
            if (firstExprWithExpr(slice.object, wanted)) |found| return found;
            if (firstExprWithExpr(slice.start, wanted)) |found| return found;
            return firstExprWithExpr(slice.end, wanted);
        },
        .call => |call| {
            for (call.args) |arg| {
                if (firstExprWithExpr(arg.value, wanted)) |found| return found;
            }
            return null;
        },
        .@"try" => |attempt| return firstExprWithExpr(attempt.expr, wanted),
        .ref_load => |source| return firstExprWithExpr(source, wanted),
        .sequence_push => |push| {
            if (firstExprWithExpr(push.object, wanted)) |found| return found;
            return firstExprWithExpr(push.value, wanted);
        },
        .sequence_reserve => |reserve| {
            if (firstExprWithExpr(reserve.object, wanted)) |found| return found;
            return firstExprWithExpr(reserve.capacity, wanted);
        },
        .sparse_insert => |insert| {
            if (firstExprWithExpr(insert.object, wanted)) |found| return found;
            if (firstExprWithExpr(insert.index, wanted)) |found| return found;
            return firstExprWithExpr(insert.value, wanted);
        },
        .sparse_contains_index => |access| {
            if (firstExprWithExpr(access.object, wanted)) |found| return found;
            return firstExprWithExpr(access.index, wanted);
        },
        .sequence_clear, .sparse_clear => |object| return firstExprWithExpr(object, wanted),
        .sequence_len, .sparse_len, .string_len, .string_is_empty, .slice_len, .string_bytes, .sparse_indices, .string_from => |object| return firstExprWithExpr(object, wanted),
        .string_starts_with, .string_ends_with, .string_contains, .string_find, .string_rfind => |call| {
            if (firstExprWithExpr(call.object, wanted)) |found| return found;
            return firstExprWithExpr(call.value, wanted);
        },
        else => return null,
    }
    return null;
}

fn firstLocalStatement(body: []const sir.Stmt, name: []const u8) ?sir.Stmt {
    for (body) |stmt| {
        if (stmt == .local and std.mem.eql(u8, stmt.local.name, name)) return stmt;
    }
    return null;
}

fn exprPlaceMetadata(metadata: []const sir.ExprMetadataEntry, expr: *const sir.Expr) ?sir.ExprMetadata {
    for (metadata) |entry| {
        if (entry.expr == expr) return entry.metadata;
    }
    return null;
}

/// Mutable view of one expression's recorded semantics, used by corruption
/// probes that must restore the original identity after rejecting a forgery.
fn metadataEntry(metadata: []sir.ExprMetadataEntry, expr: *const sir.Expr) ?*sir.ExprMetadataEntry {
    for (metadata) |*entry| {
        if (entry.expr == expr) return entry;
    }
    return null;
}

/// The checked root a formal parameter's place expressions must name.
fn paramPlaceRoot(target: *const sir.Function, name: []const u8) ?sir.CheckedPlaceRoot {
    for (target.params) |param| {
        if (!std.mem.eql(u8, param.name, name)) continue;
        const id = param.binding_id orelse return null;
        return .{ .binding = id };
    }
    return null;
}

test "checked origin transfer accepts compiler produced global, closure, function, take, raw, and assembly places" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "transfer_origins.cy", transfer_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();

    // A checked global place yields a concrete carrier of the declared global type.
    const read = try probe.run(&store, probe.function("globalRead") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(read));
    const borrowed = try probe.run(&store, probe.function("globalBorrow") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expect(borrowed.child(.ref_target) != null);
    try std.testing.expect(borrowed.child(.ref_target).?.type_term == read.type_term);

    // Detaching an optional local, field, or sparse slot keeps the payload layer.
    for ([_]([]const u8){ "takeOptional", "takeField", "takeSlot" }) |name| {
        const fact = try probe.run(&store, probe.function(name) orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
        try std.testing.expect(fact.child(.optional_item) != null);
    }

    // A closure argument is checked, and its generated body reads the capture record.
    _ = try probe.run(&store, probe.function("closureValue") orelse return error.TestUnexpectedResult);
    const closure_body = probe.function("__cyna_fn_expr_0") orelse return error.TestUnexpectedResult;
    const captured = try probe.run(&store, closure_body) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(captured));

    // An indirect call through a callable parameter keeps its declared result layer.
    const apply = probe.function("apply") orelse return error.TestUnexpectedResult;
    const applied = try probe.run(&store, apply) orelse return error.TestUnexpectedResult;
    try std.testing.expect(applied.child(.call_result) != null);
    // A named function used as a callable place is checked against the declared
    // formal, and the call records the argument against that formal position.
    const named = try probe.run(&store, probe.function("useNamed") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(named));
    try std.testing.expect(named.child(.{ .call_parameter = 0 }) != null);

    // A raw handle or a leaked handle names the checked pointee layer it exposes.
    const address = try probe.run(&store, probe.function("rawHandle") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expect(address.child(.ref_target) != null);
    const leaked = try probe.run(&store, probe.function("leakHandle") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expect(leaked.child(.ref_target) != null);
    // A raw read of a place the flow constructed transfers the item origin the
    // construction recorded; a handle the flow cannot inspect stays conservative.
    const raw = try probe.run(&store, probe.function("rawRead") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expect(raw.receiver.* != .unresolved);
    const foreign = try probe.run(&store, probe.function("rawReadForeign") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expect(foreign.receiver.* == .unresolved);
    // A raw dereference used as a place names the checked pointee layer it exposes.
    const view = try probe.run(&store, probe.function("rawView") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(view));
    try std.testing.expect(view.child(.ref_target) != null);

    // Inline assembly transfers its declared operands against the declared result.
    const assembly = try probe.run(&store, probe.function("asmValue") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(assembly));
    try std.testing.expect(assembly.child(.{ .asm_input = 0 }) != null);
}

test "checked origin transfer rejects corrupted global, closure, capture, function, assembly, raw, and take place identities" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "transfer_corruption.cy", transfer_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();

    // The global place root must name the declaration the SIR references.
    const read = probe.function("globalRead") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, read);
        defer allocator.free(body);
        const leaf = firstExprWithBody(body, "global_ref") orelse return error.TestUnexpectedResult;
        const declared = leaf.global_ref.decl_id;
        leaf.global_ref.decl_id = null;
        try std.testing.expectError(error.MissingGlobalIdentity, runVariant(&probe, &store, read, body));
        leaf.global_ref.decl_id = @fromBackingInt(@intCast(99999));
        try std.testing.expectError(error.IncorrectGlobalIdentity, runVariant(&probe, &store, read, body));
        leaf.global_ref.decl_id = declared;
        _ = try runVariant(&probe, &store, read, body);
    }

    // A closure must keep its environment and function identities.
    const closure_value = probe.function("closureValue") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, closure_value);
        defer allocator.free(body);
        const closure = firstExprWithBody(body, "closure") orelse return error.TestUnexpectedResult;
        const env = closure.closure.env_decl_id;
        const function = closure.closure.function.decl_id;
        closure.closure.env_decl_id = null;
        try std.testing.expectError(error.MissingCaptureIdentity, runVariant(&probe, &store, closure_value, body));
        closure.closure.env_decl_id = env;
        closure.closure.function.decl_id = null;
        try std.testing.expectError(error.MissingCaptureIdentity, runVariant(&probe, &store, closure_value, body));
        closure.closure.function.decl_id = function;
        _ = try runVariant(&probe, &store, closure_value, body);
    }

    // Inline assembly must declare the type it writes.
    const assembly = probe.function("asmValue") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, assembly);
        defer allocator.free(body);
        const expr = firstExprWithBody(body, "asm_expr") orelse return error.TestUnexpectedResult;
        const declared = expr.asm_expr.target_type_id;
        expr.asm_expr.target_type_id = null;
        try std.testing.expectError(error.IncorrectResultType, runVariant(&probe, &store, assembly, body));
        expr.asm_expr.target_type_id = declared;
        _ = try runVariant(&probe, &store, assembly, body);
    }

    // A raw dereference must match the contract sema checked for it.
    const raw_read = probe.function("rawRead") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, raw_read);
        defer allocator.free(body);
        const expr = firstExprWithBody(body, "raw_deref") orelse return error.TestUnexpectedResult;
        const original = expr.raw_deref.is_volatile;
        expr.raw_deref.is_volatile = true;
        try std.testing.expectError(error.IncorrectDerefContract, runVariant(&probe, &store, raw_read, body));
        expr.raw_deref.is_volatile = original;
        _ = try runVariant(&probe, &store, raw_read, body);
    }

    // A function reference must name the declaration it resolved to.
    const use_named = probe.function("useNamed") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, use_named);
        defer allocator.free(body);
        const expr = firstExprWithBody(body, "function_ref") orelse return error.TestUnexpectedResult;
        const declared = expr.function_ref.decl_id;
        expr.function_ref.decl_id = null;
        try std.testing.expectError(error.MissingFunctionIdentity, runVariant(&probe, &store, use_named, body));
        expr.function_ref.decl_id = declared;
        _ = try runVariant(&probe, &store, use_named, body);
    }

    // The generated closure body must keep the declared type of each capture.
    const generated_body = probe.function("__cyna_fn_expr_0") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, generated_body);
        defer allocator.free(body);
        const expr = firstExprWithBody(body, "closure_capture") orelse return error.TestUnexpectedResult;
        const declared = expr.closure_capture.type_id;
        expr.closure_capture.type_id = null;
        try std.testing.expectError(error.IncorrectResultType, runVariant(&probe, &store, generated_body, body));
        expr.closure_capture.type_id = declared;
        _ = try runVariant(&probe, &store, generated_body, body);
    }

    // A detached field place must name the struct declaration that owns the field.
    const take_field = probe.function("takeField") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, take_field);
        defer allocator.free(body);
        const expr = firstExprWithBody(body, "take_path_local") orelse return error.TestUnexpectedResult;
        const steps = @constCast(expr.take_path_local.steps);
        try std.testing.expect(steps.len == 1 and steps[0] == .field);
        const owner = steps[0].field.struct_decl_id;
        steps[0].field.struct_decl_id = null;
        try std.testing.expectError(error.IncorrectFieldOwner, runVariant(&probe, &store, take_field, body));
        steps[0].field.struct_decl_id = @fromBackingInt(@intCast(99999));
        try std.testing.expectError(error.IncorrectFieldOwner, runVariant(&probe, &store, take_field, body));
        steps[0].field.struct_decl_id = owner;
        _ = try runVariant(&probe, &store, take_field, body);
    }

    // The checked local place a detach consumes must still name its binding.
    const take_slot = probe.function("takeSlot") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, take_slot);
        defer allocator.free(body);
        const place = firstExprWithBody(body, "local") orelse return error.TestUnexpectedResult;
        const metadata = @constCast(probe.module.expr_metadata);
        var checked = false;
        for (metadata) |*entry| {
            if (entry.expr != place) continue;
            const root = entry.metadata.checked_place_root;
            if (root == null) continue;
            entry.metadata.checked_place_root = .{ .binding = @fromBackingInt(@intCast(99999)) };
            try std.testing.expectError(error.IncorrectBindingIdentity, runVariant(&probe, &store, take_slot, body));
            entry.metadata.checked_place_root = root;
            checked = true;
            break;
        }
        try std.testing.expect(checked);
        _ = try runVariant(&probe, &store, take_slot, body);
    }

    // A detach form must keep the checked root of the binding whose place it
    // empties; without one the flow cannot tell which layer to clear.
    {
        const body = try copiedBody(allocator, take_field);
        defer allocator.free(body);
        const expr = firstExprWithBody(body, "take_path_local") orelse return error.TestUnexpectedResult;
        const metadata = @constCast(probe.module.expr_metadata);
        var located = false;
        for (metadata) |*entry| {
            if (entry.expr != expr) continue;
            const root = entry.metadata.checked_place_root;
            try std.testing.expect(root != null);
            entry.metadata.checked_place_root = null;
            try std.testing.expectError(error.MissingPlaceIdentity, runVariant(&probe, &store, take_field, body));
            entry.metadata.checked_place_root = .{ .binding = @fromBackingInt(@intCast(999999)) };
            try std.testing.expectError(error.IncorrectBindingIdentity, runVariant(&probe, &store, take_field, body));
            entry.metadata.checked_place_root = root;
            located = true;
            break;
        }
        try std.testing.expect(located);
        _ = try runVariant(&probe, &store, take_field, body);
    }

    // A raw or leaked handle names the binding whose owned place it exposes.
    for ([_]struct { name: []const u8, tag: []const u8 }{
        .{ .name = "rawHandle", .tag = "raw_owned_local" },
        .{ .name = "leakHandle", .tag = "leak_owned_local" },
    }) |shape| {
        const handle = probe.function(shape.name) orelse return error.TestUnexpectedResult;
        const body = try copiedBody(allocator, handle);
        defer allocator.free(body);
        const expr = firstExprWithBody(body, shape.tag) orelse return error.TestUnexpectedResult;
        const metadata = @constCast(probe.module.expr_metadata);
        var located = false;
        for (metadata) |*entry| {
            if (entry.expr != expr) continue;
            const root = entry.metadata.checked_place_root;
            try std.testing.expect(root != null);
            entry.metadata.checked_place_root = .{ .binding = @fromBackingInt(@intCast(999999)) };
            try std.testing.expectError(error.IncorrectBindingIdentity, runVariant(&probe, &store, handle, body));
            entry.metadata.checked_place_root = null;
            try std.testing.expectError(error.MissingBindingId, runVariant(&probe, &store, handle, body));
            entry.metadata.checked_place_root = root;
            located = true;
            break;
        }
        try std.testing.expect(located);
        _ = try runVariant(&probe, &store, handle, body);
    }
}

const detach_source =
    \\struct Bag {
    \\    values: [2]i32;
    \\    item: ?i32;
    \\    slots: [;]i32;
    \\}
    \\
    \\struct Outer {
    \\    bag: Bag;
    \\}
    \\
    \\fn writeOptionalField(): ?i32 {
    \\    var bag: Bag = { values: [1, 2], item: none, slots: [;]i32{} };
    \\    bag.item = 42;
    \\    return bag.item;
    \\}
    \\fn detachField(): ?i32 {
    \\    var bag: Bag = { values: [1, 2], item: none, slots: [;]i32{} };
    \\    bag.item = 42;
    \\    const moved = take bag.item;
    \\    return moved;
    \\}
    \\fn detachFieldThenRead(): ?i32 {
    \\    var bag: Bag = { values: [1, 2], item: none, slots: [;]i32{} };
    \\    bag.item = 42;
    \\    const moved = take bag.item;
    \\    return bag.item;
    \\}
    \\fn detachThenRefill(): ?i32 {
    \\    var bag: Bag = { values: [1, 2], item: none, slots: [;]i32{} };
    \\    bag.item = 42;
    \\    const moved = take bag.item;
    \\    bag.item = 7;
    \\    return bag.item;
    \\}
    \\fn detachNestedThenRead(): ?i32 {
    \\    var outer = Outer { bag: Bag { values: [1, 2], item: none, slots: [;]i32{} } };
    \\    outer.bag.item = 5;
    \\    const moved = take outer.bag.item;
    \\    return outer.bag.item;
    \\}
    \\fn detachSlotThenRead(): ?i32 {
    \\    var slots: [;]i32 = [;]i32{ 0: 3, 2: 5 };
    \\    const moved = take slots[0];
    \\    return slots[2];
    \\}
;

test "checked origin flow clears the place a detach consumes" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "detach_origins.cy", detach_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const concrete = try store.intern(&.{.concrete});

    // Writing a scalar into an optional place records it as that carrier's
    // payload, so the layer a later detach consumes names a real origin.
    const written = try probe.run(&store, probe.function("writeOptionalField") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(concrete, written.receiver);
    try std.testing.expectEqual(concrete, (written.child(.optional_item) orelse return error.TestUnexpectedResult).receiver);

    // The detached value keeps the origin the source place recorded.
    const detached = try probe.run(&store, probe.function("detachField") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(concrete, detached.receiver);
    try std.testing.expectEqual(concrete, (detached.child(.optional_item) orelse return error.TestUnexpectedResult).receiver);

    // Reading the same place afterwards names no origin: the field layer keeps
    // its declared type, but the value that lived there moved out.
    const emptied = try probe.run(&store, probe.function("detachFieldThenRead") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(&generic_origins.unresolved, emptied.receiver);
    try std.testing.expectEqual(&generic_origins.unresolved, (emptied.child(.optional_item) orelse emptied).receiver);

    // Clearing the place leaves its declared layer in place, so a later write
    // through the same checked path fills it again.
    const refilled = try probe.run(&store, probe.function("detachThenRefill") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(concrete, (refilled.child(.optional_item) orelse return error.TestUnexpectedResult).receiver);

    // The update travels the checked projection path, so a nested place is
    // emptied while the outer binding keeps its own origin.
    const nested = try probe.run(&store, probe.function("detachNestedThenRead") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(&generic_origins.unresolved, nested.receiver);
    try std.testing.expectEqual(&generic_origins.unresolved, (nested.child(.optional_item) orelse nested).receiver);

    // Sparse containers record one element origin layer, so a detach from any
    // index leaves that layer without an origin.
    const slot = try probe.run(&store, probe.function("detachSlotThenRead") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(&generic_origins.unresolved, slot.receiver);
    try std.testing.expectEqual(&generic_origins.unresolved, (slot.child(.optional_item) orelse slot).receiver);
}

const loop_edge_source =
    \\enum Failure { bad }
    \\fn source(problem: Failure): i32!Failure { throw problem; }
    \\fn fail(): i32!Failure { throw Failure.bad; }
    \\
    \\struct Bag {
    \\    item: ?i32;
    \\}
    \\
    \\fn joinLoopEdges(flag: bool, first: i32, second: i32): i32 {
    \\    var current: i32 = first;
    \\    var once: bool = flag;
    \\    while once {
    \\        if flag {
    \\            current = second;
    \\        } else {
    \\            current = first;
    \\        }
    \\        once = false;
    \\    }
    \\    return current;
    \\}
    \\fn joinContinueEdge(flag: bool, first: i32, second: i32): i32 {
    \\    var current: i32 = first;
    \\    var once: bool = flag;
    \\    while once {
    \\        if flag {
    \\            current = second;
    \\            continue;
    \\        }
    \\        current = first;
    \\        once = false;
    \\    }
    \\    return current;
    \\}
    \\fn joinForEdges(values: []const i32, seed: i32): i32 {
    \\    var current: i32 = seed;
    \\    for item in values {
    \\        current = item;
    \\    }
    \\    return current;
    \\}
    \\fn loopErrorExit(failure: Failure, flag: bool): i32!Failure {
    \\    var once: bool = flag;
    \\    while once {
    \\        const value = try source(failure);
    \\        once = false;
    \\    }
    \\    return 2;
    \\}
    \\fn definiteLoopExit(failure: Failure, first: i32, second: i32): i32!Failure {
    \\    var current: i32 = first;
    \\    var once: bool = true;
    \\    while once {
    \\        const carrier = fail();
    \\        const value = try carrier;
    \\        current = second;
    \\    }
    \\    return current;
    \\}
    \\fn loopDetachesPlace(flag: bool): ?i32 {
    \\    var bag: Bag = { item: none };
    \\    bag.item = 3;
    \\    var once: bool = flag;
    \\    while once {
    \\        const moved = take bag.item;
    \\        once = false;
    \\    }
    \\    return bag.item;
    \\}
;

test "checked origin flow joins every loop successor and clears a place the loop consumes" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "loop_edge_origins.cy", loop_edge_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    const concrete = try store.intern(&.{.concrete});
    const bottom = try store.intern(&.{});
    const first_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const second_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 1 } }});
    const both_origins = try store.join(first_origin, second_origin);

    // Every back edge joins into the loop header, so the value the header carries
    // after convergence is the union of the states each successor can arrive with.
    const joined = probe.function("joinLoopEdges") orelse return error.TestUnexpectedResult;
    const flag = try store.internFact(try adapter.term(joined.params[0].type_id.?), concrete, &.{});
    const first = try store.internFact(try adapter.term(joined.params[1].type_id.?), first_origin, &.{});
    const second = try store.internFact(try adapter.term(joined.params[2].type_id.?), second_origin, &.{});
    const outcome = try flowVariant(&probe, &store, joined, &.{ flag, first, second });
    defer outcome.deinit(allocator);
    try std.testing.expectEqual(both_origins, outcome.returned.?.receiver);

    // The `continue` edge is a successor of the body just like fall-through, so the
    // header sees both of its origins as well.
    const continued = probe.function("joinContinueEdge") orelse return error.TestUnexpectedResult;
    const continued_result = try flowVariant(&probe, &store, continued, &.{ flag, first, second });
    defer continued_result.deinit(allocator);
    try std.testing.expectEqual(both_origins, continued_result.returned.?.receiver);

    // The item fact of the iterable joins into the binding the loop body writes.
    const iterated = probe.function("joinForEdges") orelse return error.TestUnexpectedResult;
    const seed = try store.internFact(try adapter.term(iterated.params[1].type_id.?), concrete, &.{});
    const slice_type = try types.get(iterated.params[0].type_id.?);
    const item = try store.internFact(try adapter.term(slice_type.slice.item), first_origin, &.{});
    const iterable = try store.internFact(try adapter.term(iterated.params[0].type_id.?), concrete, &.{.{ .key = .sequence_item, .fact = item }});
    const looped = try flowVariant(&probe, &store, iterated, &.{ iterable, seed });
    defer looped.deinit(allocator);
    try std.testing.expectEqual(try store.join(concrete, first_origin), looped.returned.?.receiver);

    // A propagated error recorded inside the loop body reaches the function return.
    const error_exit = probe.function("loopErrorExit") orelse return error.TestUnexpectedResult;
    const failure = try store.internFact(try adapter.term(error_exit.params[0].type_id.?), second_origin, &.{});
    const propagated = try flowVariant(&probe, &store, error_exit, &.{ failure, flag });
    defer propagated.deinit(allocator);
    try std.testing.expect(propagated.did_return);
    try std.testing.expect(generic_origins.Origin.leq(second_origin, (propagated.returned.?.child(.result_err) orelse return error.TestUnexpectedResult).receiver));

    // A statically decided error edge leaves the body, so the loop exit edge is
    // unreachable and the statement after the loop never contributes a return.
    const definite = probe.function("definiteLoopExit") orelse return error.TestUnexpectedResult;
    const pruned = try flowVariant(&probe, &store, definite, &.{ failure, first, second });
    defer pruned.deinit(allocator);
    try std.testing.expect(pruned.did_return);
    try std.testing.expect(!pruned.reachable);
    try std.testing.expectEqual(bottom, (pruned.returned.?.child(.result_ok) orelse return error.TestUnexpectedResult).receiver);

    // A place the body detaches stays cleared at the loop exit: the read after the
    // loop names no origin even though the declared layer still exists.
    const detached = probe.function("loopDetachesPlace") orelse return error.TestUnexpectedResult;
    const cleared = try flowVariant(&probe, &store, detached, &.{flag});
    defer cleared.deinit(allocator);
    try std.testing.expectEqual(&generic_origins.unresolved, cleared.returned.?.receiver);
    try std.testing.expectEqual(&generic_origins.unresolved, (cleared.returned.?.child(.optional_item) orelse return error.TestUnexpectedResult).receiver);
}
const place_ref_source =
    \\struct Bag {
    \\    values: [2]i32;
    \\    item: ?i32;
    \\}
    \\
    \\struct Outer {
    \\    bag: Bag;
    \\}
    \\
    \\struct Item {
    \\    value: i32;
    \\
    \\    fn total(self: &Item): i32 { return self.value; }
    \\}
    \\
    \\fn useValue(value: &i32): i32 { return value; }
    \\fn useArray(items: &[2]i32): i32 { return items[0]; }
    \\fn useBag(bag: &Bag): i32 { return useArray(&bag.values); }
    \\
    \\fn localPlace(): i32 {
    \\    var value: i32 = 7;
    \\    return useValue(&value);
    \\}
    \\fn refFieldPlace(bag: &Bag): &[2]i32 { return &bag.values; }
    \\fn refIndexPathPlace(bag: &Bag): &i32 { return &bag.values[0]; }
    \\fn refPathPlace(outer: &Outer): &[2]i32 { return &outer.bag.values; }
    \\fn ownedFieldPlace(): i32 {
    \\    var bag = new Bag { values: [1, 2], item: none };
    \\    return useArray(&bag.values);
    \\}
    \\fn indexPlace(): i32 {
    \\    var items: [2]Item = [Item { value: 5 }, Item { value: 6 }];
    \\    return items[0].total();
    \\}
    \\
    \\fn aliasPlace(): i32 {
    \\    var value: i32 = 7;
    \\    const borrowed: &i32 = &value;
    \\    return useValue(borrowed);
    \\}
    \\fn ownedPlace(): i32 {
    \\    var bag = new Bag { values: [1, 2], item: none };
    \\    return useBag(bag);
    \\}
    \\fn fieldPlace(): i32 {
    \\    var bag = new Bag { values: [3, 4], item: none };
    \\    unchecked {
    \\        const pointer: *Bag = bag.ptr();
    \\        return useArray(&(*pointer).values);
    \\    }
    \\}
;

test "checked origin transfer accepts compiler produced alias, owned borrow, and projected field places" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "place_ref_origins.cy", place_ref_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();

    // A borrowed alias is a checked read of the binding it names: the shortcut
    // alias lowering records the same place identity an address-of records.
    const alias_function = probe.function("aliasPlace") orelse return error.TestUnexpectedResult;
    const alias = try probe.run(&store, alias_function) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(alias));
    const alias_place = firstExprWithBody(alias_function.body, "ref_alias_local") orelse return error.TestUnexpectedResult;
    const alias_owner = firstLocalStatement(alias_function.body, "borrowed") orelse return error.TestUnexpectedResult;
    const alias_metadata = exprPlaceMetadata(probe.module.expr_metadata, alias_place) orelse return error.TestUnexpectedResult;
    const alias_root = alias_metadata.checked_place_root orelse return error.TestUnexpectedResult;
    try std.testing.expect(alias_root == .binding);
    try std.testing.expect(alias_root.binding == alias_owner.local.binding_id.?);
    try std.testing.expect(alias_metadata.checked_place_projections == null);
    try std.testing.expect(alias_metadata.non_owning_place_origin);

    // An owned local borrowed for a `&T` formal keeps the binding it consumes.
    const owned_function = probe.function("ownedPlace") orelse return error.TestUnexpectedResult;
    const owned = try probe.run(&store, owned_function) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(owned));
    const owned_place = firstExprWithBody(owned_function.body, "ref_owned_local") orelse return error.TestUnexpectedResult;
    const owned_owner = firstLocalStatement(owned_function.body, "bag") orelse return error.TestUnexpectedResult;
    const owned_metadata = exprPlaceMetadata(probe.module.expr_metadata, owned_place) orelse return error.TestUnexpectedResult;
    const owned_root = owned_metadata.checked_place_root orelse return error.TestUnexpectedResult;
    try std.testing.expect(owned_root == .binding);
    try std.testing.expect(owned_root.binding == owned_owner.local.binding_id.?);
    try std.testing.expect(owned_metadata.non_owning_place_origin == false);

    // A field projected off a checked raw place transfers the projected layer,
    // and the dereference underneath it names the pointer binding it came from.
    const field_function = probe.function("fieldPlace") orelse return error.TestUnexpectedResult;
    const field = try probe.run(&store, field_function) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(field));
    const field_place = firstExprWithBody(field_function.body, "ref_field_expr") orelse return error.TestUnexpectedResult;
    const deref = field_place.ref_field_expr.object;
    const deref_metadata = exprPlaceMetadata(probe.module.expr_metadata, deref) orelse return error.TestUnexpectedResult;
    const pointer_place = firstExprWithExpr(deref, "local") orelse return error.TestUnexpectedResult;
    const pointer_root = exprPlaceMetadata(probe.module.expr_metadata, pointer_place).?.checked_place_root orelse return error.TestUnexpectedResult;
    try std.testing.expect(deref_metadata.checked_raw_deref != null);
    try std.testing.expect(std.meta.eql(deref_metadata.checked_raw_deref.?.pointer_source, pointer_root));
    try std.testing.expect(deref_metadata.checked_raw_deref.?.is_volatile == deref.ref_raw_deref.is_volatile);
}

test "checked origin alias, owned borrow, and field places reject forged binding and owner identities" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "place_ref_corruption.cy", place_ref_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();

    // Every local place transfer must still name the binding it reads.
    for ([_]([]const u8){ "aliasPlace", "ownedPlace" }) |name| {
        const function = probe.function(name) orelse return error.TestUnexpectedResult;
        const wanted = if (std.mem.eql(u8, name, "aliasPlace")) "ref_alias_local" else "ref_owned_local";
        const body = try copiedBody(allocator, function);
        defer allocator.free(body);
        const place = firstExprWithBody(body, wanted) orelse return error.TestUnexpectedResult;
        const metadata = @constCast(probe.module.expr_metadata);
        var forged = false;
        for (metadata) |*entry| {
            if (entry.expr != place) continue;
            const root = entry.metadata.checked_place_root;
            try std.testing.expect(root != null and root.? == .binding);
            entry.metadata.checked_place_root = .{ .binding = @fromBackingInt(@intCast(99999)) };
            try std.testing.expectError(error.IncorrectBindingIdentity, runVariant(&probe, &store, function, body));
            entry.metadata.checked_place_root = root;
            forged = true;
            break;
        }
        try std.testing.expect(forged);
        _ = try runVariant(&probe, &store, function, body);
    }

    // A projected field place must name the struct declaration that owns it.
    const field_function = probe.function("fieldPlace") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, field_function);
        defer allocator.free(body);
        const expr = firstExprWithBody(body, "ref_field_expr") orelse return error.TestUnexpectedResult;
        const declared = expr.ref_field_expr.struct_decl_id;
        expr.ref_field_expr.struct_decl_id = null;
        try std.testing.expectError(error.IncorrectFieldOwner, runVariant(&probe, &store, field_function, body));
        expr.ref_field_expr.struct_decl_id = @fromBackingInt(@intCast(99999));
        try std.testing.expectError(error.IncorrectFieldOwner, runVariant(&probe, &store, field_function, body));
        expr.ref_field_expr.struct_decl_id = declared;
        _ = try runVariant(&probe, &store, field_function, body);
    }

    // The raw dereference a field projection is built on keeps its deref contract.
    {
        const body = try copiedBody(allocator, field_function);
        defer allocator.free(body);
        const deref = firstExprWithBody(body, "ref_raw_deref") orelse return error.TestUnexpectedResult;
        const original = deref.ref_raw_deref.is_volatile;
        deref.ref_raw_deref.is_volatile = !original;
        try std.testing.expectError(error.IncorrectDerefContract, runVariant(&probe, &store, field_function, body));
        deref.ref_raw_deref.is_volatile = original;
        _ = try runVariant(&probe, &store, field_function, body);
    }

    // Every step of a reference path remains checked when origin flow reads it.
    for ([_]struct { name: []const u8, tag: []const u8, expected: anyerror }{
        .{ .name = "refPathPlace", .tag = "ref_path_local", .expected = error.IncorrectFieldOwner },
        .{ .name = "refIndexPathPlace", .tag = "ref_index_path_local", .expected = error.IncorrectBindingIdentity },
    }) |case| {
        const function = probe.function(case.name) orelse return error.TestUnexpectedResult;
        const body = try copiedBody(allocator, function);
        defer allocator.free(body);
        const place = firstExprWithBody(body, case.tag) orelse return error.TestUnexpectedResult;
        const metadata = @constCast(probe.module.expr_metadata);
        var checked = false;
        for (metadata) |*entry| {
            if (entry.expr != place) continue;
            const original = entry.metadata.checked_place_projections orelse return error.TestUnexpectedResult;
            const projections = try allocator.dupe(sir.CheckedPlaceProjection, original);
            defer allocator.free(projections);
            const last = projections.len - 1;
            if (case.expected == error.IncorrectFieldOwner) {
                projections[last].step.field.name = "forged";
            } else {
                projections[last].step.index = .{ .fixed = 999 };
            }
            entry.metadata.checked_place_projections = projections;
            try std.testing.expectError(case.expected, runVariant(&probe, &store, function, body));
            entry.metadata.checked_place_projections = original;
            checked = true;
            break;
        }
        try std.testing.expect(checked);
        _ = try runVariant(&probe, &store, function, body);
    }
}

test "checked origin transfer accepts compiler produced local, field, index, and path places" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "place_index_origins.cy", place_ref_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();

    // `&local` names the resolved binding it addresses, and the shortcut
    // address-of lowering records the same place identity a place expression
    // records through the general lowering path.
    const local_function = probe.function("localPlace") orelse return error.TestUnexpectedResult;
    const local_result = try probe.run(&store, local_function) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(local_result));
    const local_place = firstExprWithBody(local_function.body, "ref_local") orelse return error.TestUnexpectedResult;
    const local_owner = firstLocalStatement(local_function.body, "value") orelse return error.TestUnexpectedResult;
    const local_metadata = exprPlaceMetadata(probe.module.expr_metadata, local_place) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(local_metadata.checked_place_root, .{ .binding = local_owner.local.binding_id.? }));
    try std.testing.expect(local_metadata.checked_place_projections == null);
    try std.testing.expect(local_metadata.non_owning_place_origin);

    // A field projected off a borrowed formal keeps the formal's binding identity.
    const field_function = probe.function("refFieldPlace") orelse return error.TestUnexpectedResult;
    const field_result = try probe.run(&store, field_function) orelse return error.TestUnexpectedResult;
    try std.testing.expect(field_result.child(.ref_target) != null);
    const field_place = firstExprWithBody(field_function.body, "ref_field_local") orelse return error.TestUnexpectedResult;
    const field_metadata = exprPlaceMetadata(probe.module.expr_metadata, field_place) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(field_metadata.checked_place_root, paramPlaceRoot(field_function, "bag")));
    try std.testing.expectEqual(@as(usize, 1), field_metadata.checked_place_projections.?.len);
    try std.testing.expectEqualStrings("values", field_metadata.checked_place_projections.?[0].step.field.name);
    try std.testing.expect(field_metadata.non_owning_place_origin);
    try std.testing.expect(field_place.ref_field_local.struct_decl_id != null);

    // An owned local projected through a field keeps the owning binding identity.
    const owned_function = probe.function("ownedFieldPlace") orelse return error.TestUnexpectedResult;
    const owned_result = try probe.run(&store, owned_function) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(owned_result));
    const owned_place = firstExprWithBody(owned_function.body, "ref_field_owned_local") orelse return error.TestUnexpectedResult;
    const owned_owner = firstLocalStatement(owned_function.body, "bag") orelse return error.TestUnexpectedResult;
    const owned_metadata = exprPlaceMetadata(probe.module.expr_metadata, owned_place) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(owned_metadata.checked_place_root, .{ .binding = owned_owner.local.binding_id.? }));
    try std.testing.expectEqual(@as(usize, 1), owned_metadata.checked_place_projections.?.len);
    try std.testing.expectEqualStrings("values", owned_metadata.checked_place_projections.?[0].step.field.name);
    try std.testing.expect(owned_metadata.non_owning_place_origin);
    try std.testing.expect(owned_place.ref_field_owned_local.struct_decl_id != null);

    // A borrowed method receiver that indexes a checked array names the array
    // binding as its place root, and the index is checked as a leaf origin.
    const index_function = probe.function("indexPlace") orelse return error.TestUnexpectedResult;
    const index_result = try probe.run(&store, index_function) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(index_result));
    const index_place = firstExprWithBody(index_function.body, "ref_index_local") orelse return error.TestUnexpectedResult;
    const index_owner = firstLocalStatement(index_function.body, "items") orelse return error.TestUnexpectedResult;
    const index_metadata = exprPlaceMetadata(probe.module.expr_metadata, index_place) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(index_metadata.checked_place_root, .{ .binding = index_owner.local.binding_id.? }));
    try std.testing.expectEqual(@as(usize, 1), index_metadata.checked_place_projections.?.len);
    try std.testing.expect(index_metadata.checked_place_projections.?[0].step == .index);
    try std.testing.expect(index_place.ref_index_local.index.* == .int);
    try std.testing.expect(exprPlaceMetadata(probe.module.expr_metadata, index_place.ref_index_local.index) != null);

    // A path place records the struct that owns each projected field it crosses.
    const path_function = probe.function("refPathPlace") orelse return error.TestUnexpectedResult;
    const path_result = try probe.run(&store, path_function) orelse return error.TestUnexpectedResult;
    try std.testing.expect(path_result.child(.ref_target) != null);
    const path_place = firstExprWithBody(path_function.body, "ref_path_local") orelse return error.TestUnexpectedResult;
    const path_metadata = exprPlaceMetadata(probe.module.expr_metadata, path_place) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(path_metadata.checked_place_root, paramPlaceRoot(path_function, "outer")));
    try std.testing.expect(path_place.ref_path_local.steps.len == 2);
    try std.testing.expect(path_place.ref_path_local.steps[0] == .field);
    try std.testing.expect(path_place.ref_path_local.steps[0].field.struct_decl_id != null);
    try std.testing.expect(path_place.ref_path_local.steps[1] == .field);
    try std.testing.expect(path_place.ref_path_local.steps[1].field.struct_decl_id != null);
    try std.testing.expect(path_metadata.non_owning_place_origin);

    // A path place that ends in an index checks the path and the index together.
    const index_path_function = probe.function("refIndexPathPlace") orelse return error.TestUnexpectedResult;
    const index_path_result = try probe.run(&store, index_path_function) orelse return error.TestUnexpectedResult;
    try std.testing.expect(index_path_result.child(.ref_target) != null);
    const index_path_place = firstExprWithBody(index_path_function.body, "ref_index_path_local") orelse return error.TestUnexpectedResult;
    const index_path_metadata = exprPlaceMetadata(probe.module.expr_metadata, index_path_place) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(index_path_metadata.checked_place_root, paramPlaceRoot(index_path_function, "bag")));
    try std.testing.expect(index_path_place.ref_index_path_local.steps.len == 1);
    try std.testing.expect(index_path_place.ref_index_path_local.index.* == .int);
}

test "checked origin local, field, index, and path places reject forged or missing identity" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "place_index_corruption.cy", place_ref_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();

    // Each place form names the binding it reads; dropping or forging that root
    // is rejected before the transfer is accepted.
    const Case = struct { name: []const u8, tag: []const u8 };
    const cases = [_]Case{
        .{ .name = "localPlace", .tag = "ref_local" },
        .{ .name = "refFieldPlace", .tag = "ref_field_local" },
        .{ .name = "ownedFieldPlace", .tag = "ref_field_owned_local" },
        .{ .name = "indexPlace", .tag = "ref_index_local" },
        .{ .name = "refPathPlace", .tag = "ref_path_local" },
        .{ .name = "refIndexPathPlace", .tag = "ref_index_path_local" },
    };
    for (cases) |case| {
        const function = probe.function(case.name) orelse return error.TestUnexpectedResult;
        const body = try copiedBody(allocator, function);
        defer allocator.free(body);
        const place = firstExprWithBody(body, case.tag) orelse return error.TestUnexpectedResult;
        const metadata = @constCast(probe.module.expr_metadata);
        var forged = false;
        for (metadata) |*entry| {
            if (entry.expr != place) continue;
            const root = entry.metadata.checked_place_root;
            try std.testing.expect(root != null and root.? == .binding);
            entry.metadata.checked_place_root = null;
            try std.testing.expectError(error.MissingBindingId, runVariant(&probe, &store, function, body));
            entry.metadata.checked_place_root = .{ .binding = @fromBackingInt(@intCast(99999)) };
            try std.testing.expectError(error.IncorrectBindingIdentity, runVariant(&probe, &store, function, body));
            entry.metadata.checked_place_root = root;
            forged = true;
            break;
        }
        try std.testing.expect(forged);
        _ = try runVariant(&probe, &store, function, body);
    }

    // A projected field place must keep the declaration that owns the field.
    const field_function = probe.function("refFieldPlace") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, field_function);
        defer allocator.free(body);
        const place = firstExprWithBody(body, "ref_field_local") orelse return error.TestUnexpectedResult;
        const owner = place.ref_field_local.struct_decl_id orelse return error.TestUnexpectedResult;
        place.ref_field_local.struct_decl_id = null;
        try std.testing.expectError(error.IncorrectFieldOwner, runVariant(&probe, &store, field_function, body));
        place.ref_field_local.struct_decl_id = @fromBackingInt(@intCast(99999));
        try std.testing.expectError(error.IncorrectFieldOwner, runVariant(&probe, &store, field_function, body));
        place.ref_field_local.struct_decl_id = owner;
        _ = try runVariant(&probe, &store, field_function, body);
    }

    // A projected reference cannot claim a different field than its source.
    {
        const body = try copiedBody(allocator, field_function);
        defer allocator.free(body);
        const place = firstExprWithBody(body, "ref_field_local") orelse return error.TestUnexpectedResult;
        const projections = try allocator.alloc(sir.CheckedPlaceProjection, 1);
        defer allocator.free(projections);
        const metadata = @constCast(probe.module.expr_metadata);
        for (metadata) |*entry| {
            if (entry.expr != place) continue;
            const original = entry.metadata.checked_place_projections;
            projections[0] = original.?[0];
            projections[0].step.field.name = "forged";
            entry.metadata.checked_place_projections = projections;
            try std.testing.expectError(error.IncorrectFieldOwner, runVariant(&probe, &store, field_function, body));
            entry.metadata.checked_place_projections = original;
            break;
        }
        _ = try runVariant(&probe, &store, field_function, body);
    }
}

const handoff_source =
    \\struct Container {
    \\    values: [2]i32;
    \\
    \\    @syntax.index
    \\    fn read(self: &const Container, key: i32): &const i32 { return &self.values[key]; }
    \\}
    \\
    \\fn consume(items: [:]i32): i32 { return items[0]; }
    \\
    \\fn handoffPlace(): i32 {
    \\    var items: [:]i32 = [1, 2];
    \\    return consume(items);
    \\}
    \\
    \\fn loadPlace(container: Container): i32 {
    \\    return container[0];
    \\}
;

test "checked origin transfer accepts compiler produced handoff and index hook loads" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "handoff_origins.cy", handoff_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();

    // An implicit resource handoff rewrites a resolved local read in place, so
    // it must keep the identity of the binding whose ownership it transfers.
    const handoff_function = probe.function("handoffPlace") orelse return error.TestUnexpectedResult;
    const handoff = try probe.run(&store, handoff_function) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(handoff));
    const handoff_place = firstExprWithBody(handoff_function.body, "handoff_local") orelse return error.TestUnexpectedResult;
    const handoff_owner = firstLocalStatement(handoff_function.body, "items") orelse return error.TestUnexpectedResult;
    const handoff_metadata = exprPlaceMetadata(probe.module.expr_metadata, handoff_place) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(handoff_metadata.checked_place_root, .{ .binding = handoff_owner.local.binding_id.? }));
    try std.testing.expect(handoff_metadata.checked_place_projections == null);

    // A `@syntax.index` hook read lowers to a checked load that names the
    // callable it dispatches and the receiver place it borrows.
    const load_function = probe.function("loadPlace") orelse return error.TestUnexpectedResult;
    const loaded = try probe.run(&store, load_function) orelse return error.TestUnexpectedResult;
    // The hook borrows a container place whose element origin is not proven, so
    // the loaded value is deliberately unresolved rather than a concrete carrier.
    try std.testing.expect(loaded.receiver.* == .unresolved);
    const load_place = firstExprWithBody(load_function.body, "ref_load") orelse return error.TestUnexpectedResult;
    const hooked_call = firstExprWithExpr(load_place, "call") orelse return error.TestUnexpectedResult;
    try std.testing.expect(hooked_call.call.decl_id != null);
    const receiver = firstExprWithExpr(load_place, "ref_alias_local") orelse return error.TestUnexpectedResult;
    const receiver_metadata = exprPlaceMetadata(probe.module.expr_metadata, receiver) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(receiver_metadata.checked_place_root, paramPlaceRoot(load_function, "container")));
    // The shortcut receiver lowering records the place root only, so an owned
    // value parameter keeps `non_owning_place_origin` false; reconciling that
    // flag with the borrowed capability is tracked as a B2 condition.
    try std.testing.expect(receiver_metadata.checked_place_projections == null);
    try std.testing.expect(receiver_metadata.non_owning_place_origin == false);
}

test "checked origin handoff and index hook loads reject corrupted identity" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "handoff_corruption.cy", handoff_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();

    // A handoff whose binding identity is dropped or replaced is rejected.
    const handoff_function = probe.function("handoffPlace") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, handoff_function);
        defer allocator.free(body);
        const place = firstExprWithBody(body, "handoff_local") orelse return error.TestUnexpectedResult;
        const metadata = @constCast(probe.module.expr_metadata);
        var forged = false;
        for (metadata) |*entry| {
            if (entry.expr != place) continue;
            const root = entry.metadata.checked_place_root;
            try std.testing.expect(root != null and root.? == .binding);
            entry.metadata.checked_place_root = null;
            try std.testing.expectError(error.MissingBindingId, runVariant(&probe, &store, handoff_function, body));
            entry.metadata.checked_place_root = .{ .binding = @fromBackingInt(@intCast(99999)) };
            try std.testing.expectError(error.IncorrectBindingIdentity, runVariant(&probe, &store, handoff_function, body));
            entry.metadata.checked_place_root = root;
            forged = true;
            break;
        }
        try std.testing.expect(forged);
        _ = try runVariant(&probe, &store, handoff_function, body);
    }

    // The callable a hook load dispatches must remain a declared function.
    const load_function = probe.function("loadPlace") orelse return error.TestUnexpectedResult;
    {
        const body = try copiedBody(allocator, load_function);
        defer allocator.free(body);
        const load = firstExprWithBody(body, "ref_load") orelse return error.TestUnexpectedResult;
        const call = firstExprWithExpr(load, "call") orelse return error.TestUnexpectedResult;
        const declared = call.call.decl_id;
        try std.testing.expect(declared != null);
        call.call.decl_id = null;
        try std.testing.expectError(error.MissingCallTarget, runVariant(&probe, &store, load_function, body));
        call.call.decl_id = @fromBackingInt(@intCast(99999));
        try std.testing.expectError(error.MissingCallTarget, runVariant(&probe, &store, load_function, body));
        call.call.decl_id = declared;
        _ = try runVariant(&probe, &store, load_function, body);
    }

    // The place the hook borrows must still name the binding it reads.
    {
        const body = try copiedBody(allocator, load_function);
        defer allocator.free(body);
        const load = firstExprWithBody(body, "ref_load") orelse return error.TestUnexpectedResult;
        const receiver = firstExprWithExpr(load, "ref_alias_local") orelse return error.TestUnexpectedResult;
        const metadata = @constCast(probe.module.expr_metadata);
        var forged = false;
        for (metadata) |*entry| {
            if (entry.expr != receiver) continue;
            const root = entry.metadata.checked_place_root;
            try std.testing.expect(root != null and root.? == .binding);
            entry.metadata.checked_place_root = null;
            try std.testing.expectError(error.MissingBindingId, runVariant(&probe, &store, load_function, body));
            entry.metadata.checked_place_root = .{ .binding = @fromBackingInt(@intCast(99999)) };
            try std.testing.expectError(error.IncorrectBindingIdentity, runVariant(&probe, &store, load_function, body));
            entry.metadata.checked_place_root = root;
            forged = true;
            break;
        }
        try std.testing.expect(forged);
        _ = try runVariant(&probe, &store, load_function, body);
    }
}

const leaf_source =
    \\enum State { ready }
    \\
    \\fn leaves(): i32 {
    \\    var count: i32 = 7;
    \\    var ratio: f64 = 1.5;
    \\    var letter = 'a';
    \\    var text: string = "checked";
    \\    var flag: bool = true;
    \\    var missing: ?i32 = none;
    \\    var state: State = State.ready;
    \\    return count;
    \\}
;

test "checked origin typed leaves accept compiler produced payload types" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "leaf_origins.cy", leaf_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();

    const function = probe.function("leaves") orelse return error.TestUnexpectedResult;
    const returned = try probe.run(&store, function) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(returned));

    const types = probe.module.canonical_types orelse return error.TestUnexpectedResult;
    const Case = struct { tag: []const u8, kind: []const u8 };
    const cases = [_]Case{
        .{ .tag = "int", .kind = "integer" },
        .{ .tag = "float", .kind = "float" },
        .{ .tag = "rune", .kind = "primitive" },
        .{ .tag = "string", .kind = "primitive" },
        .{ .tag = "bool", .kind = "primitive" },
        .{ .tag = "none", .kind = "optional" },
        .{ .tag = "enum_case", .kind = "nominal" },
    };
    // Each neutral leaf is produced by the resolver with a declared type that
    // agrees with its payload form, and the adapter accepts each one separately.
    for (cases) |case| {
        const leaf = firstExprWithBody(function.body, case.tag) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(case.tag, @tagName(leaf.*));
        const metadata = exprPlaceMetadata(probe.module.expr_metadata, leaf) orelse return error.TestUnexpectedResult;
        const leaf_type = try types.get(metadata.type_id);
        try std.testing.expectEqualStrings(case.kind, @tagName(leaf_type.*));
    }
}

test "checked origin typed leaves reject corrupted declared type identity" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "leaf_corruption.cy", leaf_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const function = probe.function("leaves") orelse return error.TestUnexpectedResult;
    const metadata = @constCast(probe.module.expr_metadata);

    const int_leaf = firstExprWithBody(function.body, "int") orelse return error.TestUnexpectedResult;
    const int_id = exprPlaceMetadata(probe.module.expr_metadata, int_leaf).?.type_id;

    const Case = struct { tag: []const u8, wrong_tag: []const u8 };
    const cases = [_]Case{
        .{ .tag = "int", .wrong_tag = "float" },
        .{ .tag = "float", .wrong_tag = "int" },
        .{ .tag = "rune", .wrong_tag = "int" },
        .{ .tag = "string", .wrong_tag = "int" },
        .{ .tag = "bool", .wrong_tag = "int" },
        .{ .tag = "none", .wrong_tag = "int" },
        .{ .tag = "enum_case", .wrong_tag = "int" },
    };
    // A leaf keeps its origin only while the type the resolver recorded for it
    // still matches the payload form; a forged type is rejected.
    for (cases) |case| {
        const leaf = firstExprWithBody(function.body, case.tag) orelse return error.TestUnexpectedResult;
        const entry = metadataEntry(metadata, leaf) orelse return error.TestUnexpectedResult;
        const original = entry.metadata.type_id;
        const wrong = exprPlaceMetadata(probe.module.expr_metadata, firstExprWithBody(function.body, case.wrong_tag) orelse return error.TestUnexpectedResult).?.type_id;
        entry.metadata.type_id = if (wrong == original) int_id else wrong;
        // An enum leaf's declared type is checked through the declaration that
        // owns its cases, so a forged enum type is rejected as a bad owner.
        if (std.mem.eql(u8, case.tag, "enum_case")) {
            try std.testing.expectError(error.IncorrectCaseOwner, runVariant(&probe, &store, function, function.body));
        } else {
            try std.testing.expectError(error.IncorrectResultType, runVariant(&probe, &store, function, function.body));
        }
        entry.metadata.type_id = original;
        _ = try runVariant(&probe, &store, function, function.body);
    }

    // An enum case must keep the declaration that owns its cases.
    {
        const leaf = firstExprWithBody(function.body, "enum_case") orelse return error.TestUnexpectedResult;
        const owner = leaf.enum_case.decl_id orelse return error.TestUnexpectedResult;
        leaf.enum_case.decl_id = function.decl_id;
        try std.testing.expectError(error.IncorrectCaseOwner, runVariant(&probe, &store, function, function.body));
        leaf.enum_case.decl_id = null;
        try std.testing.expectError(error.IncorrectCaseOwner, runVariant(&probe, &store, function, function.body));
        leaf.enum_case.decl_id = owner;
        _ = try runVariant(&probe, &store, function, function.body);
    }
}

const intrinsic_source =
    \\fn measured(text: string): usize { return text.len(); }
    \\fn blank(text: string): bool { return text.is_empty(); }
    \\fn pair(text: string, needle: string): bool { return text.starts_with(needle) and text.ends_with(needle); }
    \\fn located(text: string, needle: string): ?usize { return text.find(needle); }
    \\fn window(text: string, start: usize, end: usize): string { return text.slice(start, end); }
    \\fn roundtrip(text: string): string { return string.from(text.bytes()); }
    \\fn hasSlot(slots: [;]i32, key: usize): bool { return slots.contains_index(key); }
    \\fn composed(items: [:]usize, text: string): usize {
    \\    items.push(text.len());
    \\    return items.len();
    \\}
;

test "checked origin read-only intrinsics accept nested compiler produced operands" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "intrinsic_origins.cy", intrinsic_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();

    const names = [_][]const u8{ "measured", "blank", "pair", "located", "window", "roundtrip", "hasSlot", "composed" };
    for (names) |name| {
        const function = probe.function(name) orelse return error.TestUnexpectedResult;
        const returned = try probe.run(&store, function) orelse return error.TestUnexpectedResult;
        try std.testing.expect(returned.receiver.* == .set);
    }

    // An intrinsic result is also checked as the payload of a container
    // mutation, so the nested transfer keeps receiver and value separately.
    const composed = probe.function("composed") orelse return error.TestUnexpectedResult;
    const push = firstExprWithBody(composed.body, "sequence_push") orelse return error.TestUnexpectedResult;
    try std.testing.expect(push.sequence_push.value.* == .string_len);
    const nested = firstExprWithExpr(push, "string_len") orelse return error.TestUnexpectedResult;
    try std.testing.expect(exprPlaceMetadata(probe.module.expr_metadata, nested) != null);
}

test "checked origin read-only intrinsic signatures reject corrupted result or operand identity" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "intrinsic_corruption.cy", intrinsic_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const metadata = @constCast(probe.module.expr_metadata);
    const measured = probe.function("measured") orelse return error.TestUnexpectedResult;
    const string_id = measured.params[0].type_id.?;
    const usize_id = probe.function("window").?.params[1].type_id.?;

    const Case = struct { name: []const u8, tag: []const u8 };
    const cases = [_]Case{
        .{ .name = "measured", .tag = "string_len" },
        .{ .name = "blank", .tag = "string_is_empty" },
        .{ .name = "pair", .tag = "string_starts_with" },
        .{ .name = "located", .tag = "string_find" },
        .{ .name = "window", .tag = "string_slice" },
        .{ .name = "roundtrip", .tag = "string_from" },
        .{ .name = "hasSlot", .tag = "sparse_contains_index" },
        .{ .name = "composed", .tag = "string_len" },
    };
    for (cases) |case| {
        const function = probe.function(case.name) orelse return error.TestUnexpectedResult;
        const place = firstExprWithBody(function.body, case.tag) orelse return error.TestUnexpectedResult;
        const entry = metadataEntry(metadata, place) orelse return error.TestUnexpectedResult;
        const original = entry.metadata.type_id;
        entry.metadata.type_id = if (original == string_id) usize_id else string_id;
        try std.testing.expectError(error.IncorrectResultType, runVariant(&probe, &store, function, function.body));
        entry.metadata.type_id = original;
        _ = try runVariant(&probe, &store, function, function.body);
    }

    // The operand an intrinsic traverses is checked as well: a borrowed string
    // cannot be re-declared as an integer place.
    {
        const function = probe.function("pair") orelse return error.TestUnexpectedResult;
        const place = firstExprWithBody(function.body, "string_ends_with") orelse return error.TestUnexpectedResult;
        const operand = firstExprWithExpr(place, "local") orelse return error.TestUnexpectedResult;
        const entry = metadataEntry(metadata, operand) orelse return error.TestUnexpectedResult;
        const original = entry.metadata.type_id;
        entry.metadata.type_id = usize_id;
        try std.testing.expectError(error.IncorrectResultType, runVariant(&probe, &store, function, function.body));
        entry.metadata.type_id = original;
        _ = try runVariant(&probe, &store, function, function.body);
    }
}

const defer_source =
    \\fn release(items: [:]i32): void { }
    \\fn deferExit(items: [:]i32): i32 {
    \\    defer release(items);
    \\    return 0;
    \\}
;

test "checked origin defers settle at exit and consume their handoff" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "defer_origins.cy", defer_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();

    const exit_function = probe.function("deferExit") orelse return error.TestUnexpectedResult;
    const body = try copiedBody(allocator, exit_function);
    defer allocator.free(body);
    try std.testing.expect(body[0] == .@"defer");
    const handoff = firstExprWithBody(body, "handoff_local") orelse return error.TestUnexpectedResult;
    try std.testing.expect(handoff.* == .handoff_local);
    const returned = try runVariant(&probe, &store, exit_function, body) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(returned));

    // A deferred handoff whose binding identity is forged no longer resolves to
    // a checked local read and is rejected when the defer is prepared.
    const forged = try copiedBody(allocator, exit_function);
    defer allocator.free(forged);
    const forged_handoff = firstExprWithBody(forged, "handoff_local") orelse return error.TestUnexpectedResult;
    forged_handoff.* = .{ .handoff_local = "missing" };
    try std.testing.expectError(error.IncorrectBindingIdentity, runVariant(&probe, &store, exit_function, forged));
}

const call_summary_source =
    \\enum Failure { bad }
    \\fn counter(depth: i32): i32 {
    \\    if depth == 0 {
    \\        return 1;
    \\    }
    \\    return counter(depth - 1) + 1;
    \\}
    \\fn even_(depth: i32): bool {
    \\    if depth == 0 {
    \\        return true;
    \\    }
    \\    return odd_(depth - 1);
    \\}
    \\fn odd_(depth: i32): bool {
    \\    if depth == 0 {
    \\        return false;
    \\    }
    \\    return even_(depth - 1);
    \\}
    \\fn selfCall(): i32 { return selfCall(); }
    \\fn recursiveTry(value: i32): i32!Failure {
    \\    const payload = try recursiveTry(value);
    \\    return payload;
    \\}
    \\fn identity(value: i32): i32 { return value; }
    \\fn forwarded(value: i32): i32 {
    \\    const copied = identity(value);
    \\    return copied;
    \\}
    \\fn alwaysFails(): i32!Failure { throw Failure.bad; }
    \\fn succeedsWith(left: i32, right: i32): i32!Failure {
    \\    const total = left + right;
    \\    return total;
    \\}
    \\fn liveCall(value: i32): i32!Failure {
    \\    const inner = try succeedsWith(value, 1);
    \\    return inner;
    \\}
    \\fn prunedCall(value: i32): i32!Failure {
    \\    const total = try succeedsWith((try alwaysFails()), value);
    \\    return total;
    \\}
;

test "checked origin call summaries use the declared contract for recursive callees" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "call_summary_origins.cy", call_summary_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };

    // A call already on the substitution stack cannot be expanded again, so it is
    // summarized by its declared return contract rather than rejected.
    const self_call = probe.function("selfCall") orelse return error.TestUnexpectedResult;
    const summary = try probe.run(&store, self_call) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(summary));

    const counter = probe.function("counter") orelse return error.TestUnexpectedResult;
    const counted = try probe.run(&store, counter) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(counted));

    // Mutual recursion terminates on each callee's declared contract.
    const even = probe.function("even_") orelse return error.TestUnexpectedResult;
    const parity = try probe.run(&store, even) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(parity));

    // The summary is a carrier, not a decided case: a `try` over a recursive call
    // keeps an unknown payload origin instead of inventing one.
    const recursive = probe.function("recursiveTry") orelse return error.TestUnexpectedResult;
    const value_fact = try adapter.unknownFact(&store, recursive.params[0].type_id.?);
    const outcome = try flowVariant(&probe, &store, recursive, &.{value_fact});
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome.did_return);
    const payload = outcome.returned.?.child(.result_ok) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(generic_origins.unresolved, payload.receiver.*);
}

test "checked origin nested call forwarding preserves the parameter origin" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "call_forward_origins.cy", call_summary_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };

    // `identity(value)` returns the checked actual, and `forwarded` copies it into
    // a local before returning it, so the parameter origin survives two hops.
    const forwarded = probe.function("forwarded") orelse return error.TestUnexpectedResult;
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const bound = try store.internFact(try adapter.term(forwarded.params[0].type_id.?), origin, &.{});
    const outcome = try flowVariant(&probe, &store, forwarded, &.{bound});
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome.did_return);
    try std.testing.expectEqual(origin, outcome.returned.?.receiver);
}

test "checked origin recursive call summaries reject a forged declared contract" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "call_summary_corruption.cy", call_summary_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const bool_type = (probe.function("odd_") orelse return error.TestUnexpectedResult).return_type_id orelse return error.TestUnexpectedResult;
    const functions = @constCast(probe.module.functions);
    var target: ?*sir.Function = null;
    for (functions[0..probe.module.functions.len]) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "selfCall")) target = candidate;
    }
    const self_call = target orelse return error.TestUnexpectedResult;
    const original = self_call.return_type_id;

    // The declared return type is the only summary a recursive callee can carry.
    self_call.return_type_id = null;
    try std.testing.expectError(error.MissingCallResult, flowVariant(&probe, &store, self_call, &.{}));
    self_call.return_type_id = bool_type;
    try std.testing.expectError(error.IncorrectCallSignature, flowVariant(&probe, &store, self_call, &.{}));
    self_call.return_type_id = original;
    const restored = try flowVariant(&probe, &store, self_call, &.{});
    defer restored.deinit(allocator);
    try std.testing.expect(isConcreteCarrier(restored.returned.?));
}

test "checked origin call evaluation prunes a callee body after a definite error edge" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "call_prune_origins.cy", call_summary_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    const value_fact = try adapter.unknownFact(&store, (probe.function("liveCall") orelse return error.TestUnexpectedResult).params[0].type_id.?);

    // With no static error edge, the callee body is substituted and its payload
    // origin is known.
    const live = probe.function("liveCall") orelse return error.TestUnexpectedResult;
    const live_result = try flowVariant(&probe, &store, live, &.{value_fact});
    defer live_result.deinit(allocator);
    try std.testing.expect(live_result.did_return);
    const live_ok = live_result.returned.?.child(.result_ok) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(live_ok));

    // The first argument of `succeedsWith` returns statically, so its callee body
    // never runs: the call contributes no payload and the enclosing `return` is
    // unreachable.
    const pruned = probe.function("prunedCall") orelse return error.TestUnexpectedResult;
    const pruned_result = try flowVariant(&probe, &store, pruned, &.{value_fact});
    defer pruned_result.deinit(allocator);
    try std.testing.expect(pruned_result.did_return);
    try std.testing.expect(!pruned_result.reachable);
    const pruned_ok = pruned_result.returned.?.child(.result_ok) orelse return error.TestUnexpectedResult;
    try std.testing.expect(pruned_ok.receiver.* == .set and pruned_ok.receiver.set.len == 0);
    const pruned_err = pruned_result.returned.?.child(.result_err) orelse return error.TestUnexpectedResult;
    // The propagated error still names the statically chosen case, so skipping
    // the callee body does not erase the origin carried by the error edge.
    try std.testing.expect(isConcreteCarrier(pruned_err));
}

test "checked origin place reads reject a name that disagrees with the checked binding" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "place_binding_corruption.cy", place_ref_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const alias_function = probe.function("aliasPlace") orelse return error.TestUnexpectedResult;
    const place = firstExprWithBody(alias_function.body, "ref_alias_local") orelse return error.TestUnexpectedResult;
    const metadata = metadataEntry(@constCast(probe.module.expr_metadata), place) orelse return error.TestUnexpectedResult;
    const value_owner = firstLocalStatement(alias_function.body, "value") orelse return error.TestUnexpectedResult;
    const original_root = metadata.metadata.checked_place_root;
    const original_name = place.ref_alias_local;
    try std.testing.expect(original_root != null);

    // The SIR spelling only cross-checks the resolved binding; renaming it cannot
    // move the read to the other in-scope local.
    place.* = .{ .ref_alias_local = "value" };
    try std.testing.expectError(error.IncorrectBindingIdentity, probe.run(&store, alias_function));
    place.* = .{ .ref_alias_local = "missing" };
    try std.testing.expectError(error.IncorrectBindingIdentity, probe.run(&store, alias_function));
    place.* = .{ .ref_alias_local = original_name };

    // A root naming a different declared binding is rejected even though the
    // spelling still matches.
    metadata.metadata.checked_place_root = .{ .binding = value_owner.local.binding_id.? };
    try std.testing.expectError(error.IncorrectBindingIdentity, probe.run(&store, alias_function));
    metadata.metadata.checked_place_root = original_root;
    _ = try probe.run(&store, alias_function);
}

const nested_write_source =
    \\struct Bag { values: [2]i32; }
    \\fn nestedWrite(value: i32): i32 {
    \\    var bag = Bag { values: [value, value] };
    \\    bag.values[0] = 3;
    \\    return bag.values[1];
    \\}
    \\fn copySlot(first: i32, seed: i32): i32 {
    \\    var local: [2]i32 = [first, first];
    \\    local[0] = seed;
    \\    return local[1];
    \\}
    \\fn bump(reference: &i32): void { reference = 1; }
    \\fn aliased(value: i32): i32 {
    \\    const view: &i32 = &value;
    \\    bump(view);
    \\    return value;
    \\}
    \\fn useValue(value: i32): i32 { return value; }
    \\fn unaliased(value: i32): i32 {
    \\    const other = useValue(1);
    \\    return value;
    \\}
    \\fn dropped(value: i32): i32 {
    \\    var items: [:]i32 = [value, value];
    \\    drop items;
    \\    return 1;
    \\}
;

test "checked origin flow joins a nested place write into the owning container" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "nested_place_origins.cy", nested_write_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    const parameter_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const concrete = try store.intern(&.{.concrete});

    // `bag.values[0] = 3` writes through the checked field prefix, so the item
    // origin the sibling read sees is the join of the container's earlier items
    // and the value the statement supplied.
    const nested = probe.function("nestedWrite") orelse return error.TestUnexpectedResult;
    const bound = try store.internFact(try adapter.term(nested.params[0].type_id.?), parameter_origin, &.{});
    const outcome = try flowVariant(&probe, &store, nested, &.{bound});
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome.did_return);
    try std.testing.expectEqual(try store.join(parameter_origin, concrete), outcome.returned.?.receiver);

    // The same rule holds for a container the function built itself: the item
    // origin written by the indexed place joins the origins the literal supplied.
    const copy = probe.function("copySlot") orelse return error.TestUnexpectedResult;
    const first = try store.internFact(try adapter.term(copy.params[0].type_id.?), parameter_origin, &.{});
    const seed = try store.internFact(try adapter.term(copy.params[1].type_id.?), concrete, &.{});
    const copied = try flowVariant(&probe, &store, copy, &.{ first, seed });
    defer copied.deinit(allocator);
    try std.testing.expect(copied.did_return);
    try std.testing.expectEqual(try store.join(parameter_origin, concrete), copied.returned.?.receiver);
}

test "checked origin flow rejects a nested place write with a forged place root" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "nested_place_corruption.cy", nested_write_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    const nested = probe.function("nestedWrite") orelse return error.TestUnexpectedResult;
    const parameter = try adapter.unknownFact(&store, nested.params[0].type_id.?);

    const object = nested.body[1].index_assign.object;
    const metadata = metadataEntry(@constCast(probe.module.expr_metadata), object) orelse return error.TestUnexpectedResult;
    const original_root = metadata.metadata.checked_place_root;
    try std.testing.expect(original_root != null);

    // A root naming a binding the function never declared cannot own the place.
    metadata.metadata.checked_place_root = .{ .binding = @fromBackingInt(@intCast(999999)) };
    try std.testing.expectError(error.InvalidCheckedPlaceRoot, probe.module.verifyCompilerIdentities());
    try std.testing.expectError(error.UnknownBinding, generic_origins.PreparedStraightLine.init(allocator, adapter, nested, probe.module.expr_metadata, probe.module.structs, probe.module.unions, &.{parameter}));

    // A root of the wrong kind is rejected even when some declared binding exists.
    metadata.metadata.checked_place_root = .{ .global = @fromBackingInt(@intCast(1)) };
    try std.testing.expectError(error.InvalidCheckedPlaceRoot, probe.module.verifyCompilerIdentities());
    try std.testing.expectError(error.IncorrectBindingIdentity, generic_origins.PreparedStraightLine.init(allocator, adapter, nested, probe.module.expr_metadata, probe.module.structs, probe.module.unions, &.{parameter}));

    metadata.metadata.checked_place_root = original_root;
    try probe.module.verifyCompilerIdentities();
    const restored = try flowVariant(&probe, &store, nested, &.{parameter});
    defer restored.deinit(allocator);
    try std.testing.expect(restored.did_return);
}

test "checked origin flow refreshes a binding a call received as a borrowed view" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "call_alias_origins.cy", nested_write_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const bound = try store.internFact(try adapter.term((probe.function("aliased") orelse return error.TestUnexpectedResult).params[0].type_id.?), origin, &.{});

    // A callee that holds a writable view of a checked local may write through it,
    // so the local's origin is refreshed to the conservative top of the lattice.
    const aliased = probe.function("aliased") orelse return error.TestUnexpectedResult;
    const outcome = try flowVariant(&probe, &store, aliased, &.{bound});
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome.did_return);
    try std.testing.expectEqual(&generic_origins.unresolved, outcome.returned.?.receiver);

    // A call that receives only copied values cannot reach the local, so its
    // origin survives unchanged.
    const unaliased = probe.function("unaliased") orelse return error.TestUnexpectedResult;
    const kept = try flowVariant(&probe, &store, unaliased, &.{bound});
    defer kept.deinit(allocator);
    try std.testing.expect(kept.did_return);
    try std.testing.expectEqual(origin, kept.returned.?.receiver);
}

test "checked origin flow resolves a drop target by its checked binding identity" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "drop_identity_origins.cy", nested_write_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const dropped = probe.function("dropped") orelse return error.TestUnexpectedResult;
    const summary = try probe.run(&store, dropped) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(summary));

    const copied = try copiedBody(allocator, dropped);
    defer allocator.free(copied);
    try std.testing.expect(copied[1] == .drop);
    const original_id = copied[1].drop.binding_id;

    // Without a checked identity the statement cannot select its owning slot.
    @constCast(copied)[1].drop.binding_id = null;
    try std.testing.expectError(error.MissingBindingId, runVariant(&probe, &store, dropped, copied));

    // The checked identity, not the display name, decides the slot, so naming a
    // different declared binding is rejected by the verifier and the flow.
    const statements = @constCast(dropped.body);
    statements[1].drop.binding_id = dropped.params[0].binding_id;
    try std.testing.expectError(error.InvalidBindingIdentity, probe.module.verifyCompilerIdentities());
    try std.testing.expectError(error.IncorrectBindingIdentity, runVariant(&probe, &store, dropped, statements));

    statements[1].drop.binding_id = original_id;
    try probe.module.verifyCompilerIdentities();
    const restored = try probe.run(&store, dropped) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isConcreteCarrier(restored));
}

const raw_place_source =
    \\struct Box { payload: i32; }
    \\fn rawWrite(pointer: *i32, value: i32): i32 {
    \\    unchecked { *pointer = value; return *pointer; }
    \\}
    \\fn fieldWrite(pointer: *Box, value: i32): i32 {
    \\    unchecked { (*pointer).payload = value; return (*pointer).payload; }
    \\}
    \\fn handleWrite(value: i32): i32 {
    \\    var box = new Box { payload: value };
    \\    const pointer: *Box = box.ptr();
    \\    unchecked { (*pointer).payload = 9; return (*pointer).payload; }
    \\}
    \\struct Holder { cell: *i32; }
    \\fn fieldPointerWrite(holder: Holder, value: i32): i32 {
    \\    unchecked { *holder.cell = value; return *holder.cell; }
    \\}
    \\fn bump(reference: &i32): void { reference = 1; }
    \\fn chained(value: i32): i32 {
    \\    const first: &i32 = &value;
    \\    const second: &i32 = first;
    \\    bump(second);
    \\    return value;
    \\}
    \\fn growView(): i32 {
    \\    var items: [:]i32 = [1, 2];
    \\    items.push(3);
    \\    const view: &i32 = &items[0];
    \\    return view;
    \\}
;

test "checked origin flow records a write through a dereferenced place" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "raw_place_origins.cy", raw_place_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 1 } }});
    const concrete = try store.intern(&.{.concrete});

    // A raw handle starts as a declared skeleton whose pointee layer is unknown.
    // Writing through it records the value's origin in that layer, so the read
    // that follows names the value the statement placed there.
    const raw_write = probe.function("rawWrite") orelse return error.TestUnexpectedResult;
    const handle = try adapter.unknownFact(&store, raw_write.params[0].type_id.?);
    const written_value = try store.internFact(try adapter.term(raw_write.params[1].type_id.?), origin, &.{});
    const outcome = try flowVariant(&probe, &store, raw_write, &.{ handle, written_value });
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome.did_return);
    const referent = outcome.returned.?.child(.ref_target) orelse return error.TestUnexpectedResult;
    try std.testing.expect(generic_origins.Origin.leq(origin, referent.receiver));
    try std.testing.expect(!generic_origins.Origin.leq(&generic_origins.unresolved, referent.receiver));

    // The same rule reaches a field layer of the pointee through the checked path.
    const field_write = probe.function("fieldWrite") orelse return error.TestUnexpectedResult;
    const box_handle = try adapter.unknownFact(&store, field_write.params[0].type_id.?);
    const boxed_value = try store.internFact(try adapter.term(field_write.params[1].type_id.?), origin, &.{});
    const placed = try flowVariant(&probe, &store, field_write, &.{ box_handle, boxed_value });
    defer placed.deinit(allocator);
    try std.testing.expect(placed.did_return);
    try std.testing.expect(generic_origins.Origin.leq(origin, placed.returned.?.receiver));
    try std.testing.expect(!generic_origins.Origin.leq(&generic_origins.unresolved, placed.returned.?.receiver));

    // A handle obtained from an owned place writes into the pointee layout the
    // flow recorded for it, and the read back sees the written literal.
    const handle_write = probe.function("handleWrite") orelse return error.TestUnexpectedResult;
    const owned_value = try store.internFact(try adapter.term(handle_write.params[0].type_id.?), origin, &.{});
    const owned = try flowVariant(&probe, &store, handle_write, &.{owned_value});
    defer owned.deinit(allocator);
    try std.testing.expect(owned.did_return);
    try std.testing.expect(generic_origins.Origin.leq(concrete, owned.returned.?.receiver));
}

test "checked origin flow rejects a place write whose path or target is not checked" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "raw_place_corruption.cy", raw_place_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };

    const functions = @constCast(probe.module.functions);
    var field_write: ?*sir.Function = null;
    var raw_write: ?*sir.Function = null;
    for (functions[0..probe.module.functions.len]) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "fieldWrite")) field_write = candidate;
        if (std.mem.eql(u8, candidate.name, "rawWrite")) raw_write = candidate;
    }
    const boxed = field_write orelse return error.TestUnexpectedResult;
    const pointer = raw_write orelse return error.TestUnexpectedResult;
    const handle_fact = try adapter.unknownFact(&store, boxed.params[0].type_id.?);
    const value_fact = try adapter.unknownFact(&store, boxed.params[1].type_id.?);

    // The path steps are resolved IDs: a step naming a different struct cannot
    // own the field the statement writes.
    const statements = @constCast(boxed.body);
    try std.testing.expect(statements[0] == .unchecked);
    const write = statements[0].unchecked[0];
    try std.testing.expect(write == .deref_field_assign);
    const steps = write.deref_field_assign.steps;
    try std.testing.expect(steps.len == 1 and steps[0].struct_decl_id != null);
    const original_owner = steps[0].struct_decl_id.?;
    @constCast(steps)[0].struct_decl_id = @fromBackingInt(@intCast(999999));
    try std.testing.expectError(error.IncorrectFieldOwner, flowVariant(&probe, &store, boxed, &.{ handle_fact, value_fact }));
    @constCast(steps)[0].struct_decl_id = original_owner;

    // A write whose target does not resolve to a declared binding has no checked
    // origin to update, so it is rejected rather than silently skipped.
    const holder_write = probe.function("fieldPointerWrite") orelse return error.TestUnexpectedResult;
    try std.testing.expectError(error.MissingPlaceIdentity, probe.run(&store, holder_write));

    // The pointer operand must name a place the flow can identify; substituting
    // the written value for it is rejected.
    const copied = try copiedBody(allocator, pointer);
    defer allocator.free(copied);
    const body = @constCast(copied);
    try std.testing.expect(body[0] == .unchecked);
    const scoped = body[0].unchecked;
    try std.testing.expect(scoped[0] == .deref_assign);
    const original_scope = body[0];
    const forged = try allocator.alloc(sir.Stmt, 2);
    defer allocator.free(forged);
    forged[0] = scoped[0];
    forged[0].deref_assign.pointer = forged[0].deref_assign.value;
    forged[1] = scoped[1];
    body[0] = .{ .unchecked = forged };
    try std.testing.expectError(error.UnsupportedStatement, runVariant(&probe, &store, pointer, copied));
    body[0] = original_scope;
    _ = try runVariant(&probe, &store, pointer, copied);
}

test "checked origin flow refreshes every place a chained view reaches" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "chained_view_origins.cy", raw_place_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const chained = probe.function("chained") orelse return error.TestUnexpectedResult;
    const bound = try store.internFact(try adapter.term(chained.params[0].type_id.?), origin, &.{});

    // `second` names `first`, which names `value`: a call that receives the outer
    // view can write through any link on the chain, so every binding on it is
    // refreshed, not just the end of the chain.
    const outcome = try flowVariant(&probe, &store, chained, &.{bound});
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome.did_return);
    try std.testing.expectEqual(&generic_origins.unresolved, outcome.returned.?.receiver);
}

test "checked origin flow invalidates a view taken from a mutated container" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "container_view_origins.cy", raw_place_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const grow = probe.function("growView") orelse return error.TestUnexpectedResult;

    // When the mutation precedes the borrow, the view still names the container's
    // recorded item origin.
    const natural = try flowVariant(&probe, &store, grow, &.{});
    defer natural.deinit(allocator);
    try std.testing.expect(natural.did_return);
    try std.testing.expect(natural.returned.?.receiver.* != .unresolved);

    // Handed a body where the borrow is taken before the mutation that can move
    // it, the flow must not let the older item origin survive inside the view.
    const copied = try copiedBody(allocator, grow);
    defer allocator.free(copied);
    const body = @constCast(copied);
    try std.testing.expect(body[1] == .expr and body[2] == .local);
    const moved = body[1];
    body[1] = body[2];
    body[2] = moved;
    const reordered = try runVariant(&probe, &store, grow, copied);
    try std.testing.expect(reordered != null);
    try std.testing.expect(reordered.?.receiver.* == .unresolved);
}

const scope_exit_source =
    \\fn blockReturn(value: i32): i32 {
    \\    unchecked {
    \\        const inner: i32 = value;
    \\        return inner;
    \\    }
    \\    return 0;
    \\}
    \\fn allocScope(value: i32): i32 {
    \\    using alloc = 0 {
    \\        const inner: i32 = value;
    \\        return inner;
    \\    }
    \\    return 0;
    \\}
    \\fn outerSurvivesBlock(value: i32): i32 {
    \\    const outer: i32 = value;
    \\    unchecked {
    \\        const inner: i32 = value;
    \\        return inner;
    \\    }
    \\    return outer;
    \\}
;

test "checked origin flow clears lexical slots when a scope exits" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "scope_exit_origins.cy", scope_exit_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    const parameter_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});

    // Slot 0 is the parameter, slot 1 the binding the block declared. The block's
    // return records the parameter origin, and its lexical slot is empty once the
    // scope has exited.
    const block = probe.function("blockReturn") orelse return error.TestUnexpectedResult;
    const bound = try store.internFact(try adapter.term(block.params[0].type_id.?), parameter_origin, &.{});
    const outcome = try flowVariant(&probe, &store, block, &.{bound});
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome.did_return);
    try std.testing.expectEqual(parameter_origin, outcome.returned.?.receiver);
    try std.testing.expectEqual(@as(usize, 2), outcome.values.len);
    try std.testing.expect(outcome.values[1] == null);

    // An allocator scope exits the same way.
    const alloc = probe.function("allocScope") orelse return error.TestUnexpectedResult;
    const scoped = try flowVariant(&probe, &store, alloc, &.{bound});
    defer scoped.deinit(allocator);
    try std.testing.expect(scoped.did_return);
    try std.testing.expect(scoped.values[1] == null);
    try std.testing.expectEqual(parameter_origin, scoped.returned.?.receiver);

    // A binding introduced before the scope keeps its origin across the exit.
    const outer = probe.function("outerSurvivesBlock") orelse return error.TestUnexpectedResult;
    const survived = try flowVariant(&probe, &store, outer, &.{bound});
    defer survived.deinit(allocator);
    try std.testing.expect(survived.did_return);
    try std.testing.expectEqual(parameter_origin, survived.returned.?.receiver);
    try std.testing.expect(survived.values[1] != null);
    try std.testing.expect(survived.values[2] == null);
}

const drop_view_source =
    \\fn viewsOf(value: i32): i32 {
    \\    var items: [:]i32 = [value, value];
    \\    const first: &i32 = &items[0];
    \\    const second: &i32 = first;
    \\    const direct: &i32 = &value;
    \\    return direct;
    \\}
    \\fn viewReader(value: i32): i32 {
    \\    var items: [:]i32 = [value, value];
    \\    const first: &i32 = &items[0];
    \\    const second: &i32 = first;
    \\    return second;
    \\}
    \\fn dropLocal(value: i32): i32 {
    \\    var items: [:]i32 = [value, value];
    \\    drop items;
    \\    return 1;
    \\}
;

/// Splice a legal drop statement into a body, retargeting it at that body's
/// first local, so the flow can be handed the ordering lowering would reject.
fn bodyWithDrop(allocator: std.mem.Allocator, target: *const sir.Function, donor: *const sir.Function) ![]const sir.Stmt {
    const forged = try allocator.alloc(sir.Stmt, target.body.len + 1);
    @memcpy(forged[0 .. target.body.len - 1], target.body[0 .. target.body.len - 1]);
    forged[target.body.len - 1] = donor.body[1];
    forged[target.body.len - 1].drop.binding_id = target.body[0].local.binding_id;
    forged[target.body.len - 1].drop.name = target.body[0].local.name;
    forged[target.body.len] = target.body[target.body.len - 1];
    return forged;
}

test "checked origin flow invalidates every view of a dropped place" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "drop_view_origins.cy", drop_view_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    const parameter_origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const donor = probe.function("dropLocal") orelse return error.TestUnexpectedResult;

    // Slots 1, 2, and 3 are the container, its view, and the view of that view.
    // Before the drop each of them names the parameter origin.
    const views = probe.function("viewsOf") orelse return error.TestUnexpectedResult;
    const bound = try store.internFact(try adapter.term(views.params[0].type_id.?), parameter_origin, &.{});
    const before = try flowVariant(&probe, &store, views, &.{bound});
    defer before.deinit(allocator);
    try std.testing.expect(before.did_return);
    try std.testing.expectEqual(@as(usize, 5), before.values.len);
    for (before.values[1..]) |fact| try std.testing.expect(fact != null);
    const item_fact = before.values[1].?.child(.sequence_item) orelse return error.TestUnexpectedResult;
    try std.testing.expect(generic_origins.Origin.leq(parameter_origin, item_fact.receiver));

    // With the container dropped, every binding whose checked view reaches it
    // is cleared transitively, while an unrelated view keeps its origin.
    const dropped = try bodyWithDrop(allocator, views, donor);
    defer allocator.free(dropped);
    const after = try flowBodyVariant(&probe, &store, views, &.{bound}, dropped);
    defer after.deinit(allocator);
    try std.testing.expect(after.did_return);
    try std.testing.expectEqual(parameter_origin, after.returned.?.receiver);
    try std.testing.expect(after.values[1] == null);
    try std.testing.expect(after.values[2] == null);
    try std.testing.expect(after.values[3] == null);
    try std.testing.expect(after.values[4] != null);

    // Reading a view whose place has been dropped has no checked origin, so the
    // flow rejects the statement instead of returning a stale capability.
    const reader = probe.function("viewReader") orelse return error.TestUnexpectedResult;
    const used = try bodyWithDrop(allocator, reader, donor);
    defer allocator.free(used);
    try std.testing.expectError(error.UninitializedBinding, flowBodyVariant(&probe, &store, reader, &.{bound}, used));

    // The drop's owning slot comes from the checked binding identity: a drop
    // with the right spelling but a different binding id is rejected.
    const corrupted = try bodyWithDrop(allocator, views, donor);
    defer allocator.free(corrupted);
    @constCast(corrupted)[views.body.len - 1].drop.binding_id = views.body[3].local.binding_id;
    try std.testing.expectError(error.IncorrectBindingIdentity, flowBodyVariant(&probe, &store, views, &.{bound}, corrupted));
}

const handle_source =
    \\struct Box { payload: i32; }
    \\
    \\fn handleRead(value: i32): i32 {
    \\    var box = new Box { payload: value };
    \\    unchecked {
    \\        const handle: *Box = box.ptr();
    \\        return (*handle).payload;
    \\    }
    \\}
    \\fn ownedFieldRead(value: i32): i32 {
    \\    var box = new Box { payload: value };
    \\    unchecked {
    \\        const handle: *Box = box.ptr();
    \\        return box.payload;
    \\    }
    \\}
    \\fn forgedHandleOwner(value: i32): i32 {
    \\    var box = new Box { payload: value };
    \\    var spare = new Box { payload: 1 };
    \\    unchecked {
    \\        const handle: *Box = box.ptr();
    \\        return (*handle).payload;
    \\    }
    \\}
;

test "checked origin flow keeps an owned place live when a handle borrows it" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "handle_origins.cy", handle_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});

    // `.ptr()` hands out a view rather than moving the owned place, so both the
    // handle and the binding it came from still name the origin the constructor
    // literal put in the payload layer.
    const view = probe.function("handleRead") orelse return error.TestUnexpectedResult;
    const seed = try store.internFact(try adapter.term(view.params[0].type_id.?), origin, &.{});
    const read = try flowVariant(&probe, &store, view, &.{seed});
    defer read.deinit(allocator);
    try std.testing.expect(read.did_return);
    try std.testing.expect(generic_origins.Origin.leq(origin, read.returned.?.receiver));
    try std.testing.expect(!generic_origins.Origin.leq(&generic_origins.unresolved, read.returned.?.receiver));

    // A projection of the owned binding walks through the ownership wrapper into
    // the layer the construction recorded, instead of failing to find a layout.
    const owner = probe.function("ownedFieldRead") orelse return error.TestUnexpectedResult;
    const kept = try flowVariant(&probe, &store, owner, &.{seed});
    defer kept.deinit(allocator);
    try std.testing.expect(kept.did_return);
    try std.testing.expect(generic_origins.Origin.leq(origin, kept.returned.?.receiver));
    try std.testing.expect(!generic_origins.Origin.leq(&generic_origins.unresolved, kept.returned.?.receiver));

    // The handle expression must still name the checked binding whose place it
    // exposes: the same spelling pointed at another owned binding is rejected.
    const corrupted = probe.function("forgedHandleOwner") orelse return error.TestUnexpectedResult;
    const body = try copiedBody(allocator, corrupted);
    defer allocator.free(body);
    const expr = firstExprWithBody(body, "raw_owned_local") orelse return error.TestUnexpectedResult;
    const spelling = expr.raw_owned_local;
    @constCast(expr).raw_owned_local = "spare";
    try std.testing.expectError(error.IncorrectBindingIdentity, runVariant(&probe, &store, corrupted, body));
    @constCast(expr).raw_owned_local = spelling;
    _ = try runVariant(&probe, &store, corrupted, body);
}

const assembly_source =
    \\struct Box { payload: i32; }
    \\
    \\fn opaqueAssembly(seed: i32): i32 {
    \\    unchecked {
    \\        const value = asm(i32) {
    \\            "add {acc}, {acc}";
    \\            inout reg acc = seed;
    \\        };
    \\        return value;
    \\    }
    \\}
    \\fn inoutClobbersView(value: i32): i32 {
    \\    var box = new Box { payload: value };
    \\    unchecked {
    \\        const handle: *Box = box.ptr();
    \\        const moved = asm(*Box) {
    \\            "mov {p}, {p}";
    \\            inout reg p = handle;
    \\        };
    \\        return (*handle).payload;
    \\    }
    \\}
    \\fn inoutClobbersOwner(value: i32): i32 {
    \\    var box = new Box { payload: value };
    \\    unchecked {
    \\        const handle: *Box = box.ptr();
    \\        const moved = asm(*Box) {
    \\            "mov {p}, {p}";
    \\            inout reg p = handle;
    \\        };
    \\        return box.payload;
    \\    }
    \\}
    \\fn outOnlyKeepsPlace(value: i32): i32 {
    \\    var box = new Box { payload: value };
    \\    unchecked {
    \\        const other = asm(i32) {
    \\            "mov {result}, {result}";
    \\            out reg result;
    \\        };
    \\        return box.payload;
    \\    }
    \\}
;

test "checked origin flow refreshes every place an assembly inout operand reaches" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "assembly_origins.cy", assembly_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});

    // The value an asm expression yields comes from the template rather than the
    // seed operand, so it names no proven origin even though the checked inout
    // child still records the operand the template received.
    const template = probe.function("opaqueAssembly") orelse return error.TestUnexpectedResult;
    const seed = try store.internFact(try adapter.term(template.params[0].type_id.?), origin, &.{});
    const result = try flowVariant(&probe, &store, template, &.{seed});
    defer result.deinit(allocator);
    try std.testing.expect(result.did_return);
    try std.testing.expect(result.returned.?.child(.asm_inout) != null);
    try std.testing.expectEqual(&generic_origins.unresolved, result.returned.?.receiver);

    // An `inout` operand is both read and written by the template, so neither the
    // handle naming the place nor the owned binding it came from keeps a proven
    // origin afterwards.
    const view = probe.function("inoutClobbersView") orelse return error.TestUnexpectedResult;
    const borrowed = try flowVariant(&probe, &store, view, &.{seed});
    defer borrowed.deinit(allocator);
    try std.testing.expect(borrowed.did_return);
    try std.testing.expectEqual(&generic_origins.unresolved, borrowed.returned.?.receiver);

    const owner = probe.function("inoutClobbersOwner") orelse return error.TestUnexpectedResult;
    const owned = try flowVariant(&probe, &store, owner, &.{seed});
    defer owned.deinit(allocator);
    try std.testing.expect(owned.did_return);
    try std.testing.expectEqual(&generic_origins.unresolved, owned.returned.?.receiver);

    // A template with only an output operand touches no place, so the origin a
    // construction recorded for it survives.
    const survivor = probe.function("outOnlyKeepsPlace") orelse return error.TestUnexpectedResult;
    const survived = try flowVariant(&probe, &store, survivor, &.{seed});
    defer survived.deinit(allocator);
    try std.testing.expect(survived.did_return);
    try std.testing.expect(generic_origins.Origin.leq(origin, survived.returned.?.receiver));
    try std.testing.expect(!generic_origins.Origin.leq(&generic_origins.unresolved, survived.returned.?.receiver));
}

const place_closure_source =
    \\fn bump(reference: &i32) {
    \\    reference = 1;
    \\}
    \\fn rootPlaceReachesItsViews(value: i32): i32 {
    \\    var cell: i32 = value;
    \\    const view: &i32 = &cell;
    \\    bump(&cell);
    \\    return view;
    \\}
    \\fn viewReachedByCall(value: i32): i32 {
    \\    var cell: i32 = value;
    \\    const view: &i32 = &cell;
    \\    bump(view);
    \\    return cell;
    \\}
    \\fn viewOnly(value: i32): i32 {
    \\    var cell: i32 = value;
    \\    const view: &i32 = &cell;
    \\    return view;
    \\}
;

test "checked origin flow refreshes every view of a place a call receives" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "place_closure_origins.cy", place_closure_source);
    defer probe.deinit();
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    const adapter = generic_origins.TypeAdapter{ .types = types };
    const origin = try store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
    const seed = try store.internFact(try adapter.term((probe.function("viewOnly") orelse return error.TestUnexpectedResult).params[0].type_id.?), origin, &.{});

    // A view taken from a place keeps the origin that place recorded while no
    // callee can reach it.
    const control = probe.function("viewOnly") orelse return error.TestUnexpectedResult;
    const untouched = try flowVariant(&probe, &store, control, &.{seed});
    defer untouched.deinit(allocator);
    try std.testing.expect(untouched.did_return);
    try std.testing.expect(generic_origins.Origin.leq(origin, untouched.returned.?.receiver));

    // The closure runs in both directions: a callee handed the place itself can
    // write through every view taken from it, so the view loses its proven origin.
    const viewed = probe.function("rootPlaceReachesItsViews") orelse return error.TestUnexpectedResult;
    const outcome = try flowVariant(&probe, &store, viewed, &.{seed});
    defer outcome.deinit(allocator);
    try std.testing.expectEqual(generic_origins.unresolved, outcome.returned.?.receiver.*);
    // The same closure reaches the other way: a callee handed the view can write
    // through the place it reaches, so reading the place back is unproven.
    const place_reached = probe.function("viewReachedByCall") orelse return error.TestUnexpectedResult;
    const owned = try flowVariant(&probe, &store, place_reached, &.{seed});
    defer owned.deinit(allocator);
    try std.testing.expectEqual(generic_origins.unresolved, owned.returned.?.receiver.*);
}

const exit_edge_source =
    \\enum Failure { bad }
    \\fn fail(): i32!Failure { throw Failure.bad; }
    \\fn failBool(): bool!Failure { throw Failure.bad; }
    \\fn uncertain(value: i32, problem: Failure): i32!Failure { if value == 0 { throw problem; } return value; }
    \\
    \\union Choice { active: i32; empty; }
    \\
    \\struct Bag {
    \\    item: ?i32;
    \\}
    \\
    \\fn release(items: [:]i32): void {}
    \\
    \\fn joinBranches(flag: bool, first: i32, second: i32): i32 {
    \\    var current: i32 = first;
    \\    if flag {
    \\        current = second;
    \\    } else {
    \\        current = first;
    \\    }
    \\    return current;
    \\}
    \\fn sameFactInBothArms(flag: bool, first: i32, second: i32): i32 {
    \\    var current: i32 = first;
    \\    if flag {
    \\        current = second;
    \\    } else {
    \\        current = second;
    \\    }
    \\    return current;
    \\}
    \\fn overwriteAfterJoin(flag: bool, first: i32, second: i32, third: i32): i32 {
    \\    var current: i32 = first;
    \\    if flag {
    \\        current = second;
    \\    } else {
    \\        current = third;
    \\    }
    \\    current = first;
    \\    return current;
    \\}
    \\fn joinDetachedPlace(bag: Bag, flag: bool): ?i32 {
    \\    bag.item = 7;
    \\    if flag {
    \\        const moved = take bag.item;
    \\    }
    \\    return bag.item;
    \\}
    \\fn convergeWhile(flag: bool, first: i32, second: i32): i32 {
    \\    var current: i32 = first;
    \\    var rounds: i32 = 3;
    \\    while rounds > 0 {
    \\        if flag {
    \\            current = second;
    \\        } else {
    \\            current = first;
    \\        }
    \\        rounds = rounds - 1;
    \\    }
    \\    return current;
    \\}
    \\fn prunedAfterDefiniteError(first: i32): i32!Failure {
    \\    const carrier = fail();
    \\    const value = try carrier;
    \\    return value + first;
    \\}
    \\fn joinAfterUncertainError(value: i32, problem: Failure, first: i32): i32!Failure {
    \\    const payload = try uncertain(value, problem);
    \\    return payload + first;
    \\}
    \\fn branchErrorExit(flag: bool, first: i32): i32!Failure {
    \\    if flag {
    \\        const carrier = fail();
    \\        const value = try carrier;
    \\        return value + first;
    \\    }
    \\    return first;
    \\}
    \\fn deferSettlesOnErrorExit(items: [:]i32): i32!Failure {
    \\    defer release(items);
    \\    const carrier = fail();
    \\    const value = try carrier;
    \\    return value;
    \\}
    \\fn scopeDeferKeepsOuterPlace(items: [:]i32, spare: [:]i32): usize {
    \\    unchecked {
    \\        defer release(spare);
    \\    }
    \\    return items.len();
    \\}
    \\fn assemblyStatementUsesCheckedPlace(value: i32): i32 {
    \\    unchecked {
    \\        asm {
    \\            "add {left}, {right}";
    \\            in left = value;
    \\            in right = 1;
    \\        }
    \\    }
    \\    return value;
    \\}
    \\fn joinSwitchArms(value: Choice, first: i32, second: i32): i32 {
    \\    var current: i32 = first;
    \\    switch value { .active(item) => { current = second; } .empty => { current = first; } }
    \\    return current;
    \\}
    \\fn switchElseArmIsOneSuccessor(value: Choice, first: i32, second: i32, third: i32): i32 {
    \\    var current: i32 = first;
    \\    switch value { .active(item) => { current = second; } _ => { current = third; } }
    \\    return current;
    \\}
    \\fn switchArmReturnJoinsFallthrough(value: Choice, first: i32): i32 {
    \\    switch value { .active(item) => { return item; } _ => { return first; } }
    \\}
    \\fn switchContinueEdgeJoinsLoopHeader(value: Choice, first: i32, second: i32): i32 {
    \\    var current: i32 = first;
    \\    var rounds: i32 = 2;
    \\    while rounds > 0 {
    \\        rounds = rounds - 1;
    \\        switch value { .active(item) => { continue; } .empty => { current = second; } }
    \\    }
    \\    return current;
    \\}
    \\fn switchArmErrorExitPrunesThatArm(value: Choice, first: i32): i32!Failure {
    \\    switch value {
    \\        .active(item) => {
    \\            const carrier = fail();
    \\            const inner = try carrier;
    \\            return inner + item;
    \\        }
    \\        .empty => {
    \\            return first;
    \\        }
    \\    }
    \\}
    \\fn loopConditionErrorPrunesAfterDefiniteError(first: i32): i32!Failure {
    \\    var current: i32 = first;
    \\    while try failBool() {
    \\        current = first;
    \\    }
    \\    return current;
    \\}
    \\fn deferSettlesOnReturnInsideScope(items: [:]i32): usize {
    \\    unchecked {
    \\        defer release(items);
    \\        return 1;
    \\    }
    \\    return 0;
    \\}
    \\fn deferSettlesOnContinueEdge(items: [:]i32, flag: bool): usize {
    \\    var rounds: i32 = 1;
    \\    while rounds > 0 {
    \\        var buffer: [:]i32 = [1, 2];
    \\        defer release(buffer);
    \\        rounds = rounds - 1;
    \\        if flag {
    \\            continue;
    \\        }
    \\    }
    \\    return items.len();
    \\}
    \\fn indirectViewCall(handler: (&i32) => i32, value: i32): i32 {
    \\    const result = handler(&value);
    \\    return value;
    \\}
    \\fn indirectValueCall(handler: (i32) => i32, value: i32): i32 {
    \\    const result = handler(value);
    \\    return value;
    \\}
    \\fn indirectCallPrunesArgumentsAfterDefiniteError(handler: (i32, [:]i32) => i32, items: [:]i32): i32!Failure {
    \\    const carrier = fail();
    \\    const value = handler(try carrier, items);
    \\    throw Failure.bad;
    \\}
    \\fn indirectCallSettlesItsOwnedArgument(handler: (i32, [:]i32) => i32, items: [:]i32): i32 {
    \\    const result = handler(1, items);
    \\    return result;
    \\}
    \\fn insertThenReserveKeepsElementOrigins(items: [:]i32, spare: i32): i32 {
    \\    items.push(spare);
    \\    items.reserve(4);
    \\    return items[0];
    \\}
    \\fn popSettlesTheElementLayer(items: [:]i32): i32 {
    \\    const popped = items.pop();
    \\    return popped;
    \\}
    \\fn clearSettlesTheElementLayer(items: [:]i32): usize {
    \\    items.clear();
    \\    return items.len();
    \\}
    \\fn sparseInsertKeepsElementOrigins(items: [;]i32, spare: i32): usize {
    \\    items.insert(1, spare);
    \\    return items.len();
    \\}
    \\fn sparseClearSettlesItsSlots(items: [;]i32): usize {
    \\    items.clear();
    \\    return items.len();
    \\}
    \\fn sparseTakeSettlesItsSlot(items: [;]i32, key: usize): usize {
    \\    const taken = items.take(key);
    \\    return items.len();
    \\}
;

/// Shared probe, store, and origin seeds for the exit-edge evidence below.
const ExitEdgeContext = struct {
    probe: origin_probe = undefined,
    store: generic_origins.Store = undefined,
    adapter: generic_origins.TypeAdapter = undefined,
    concrete: *const generic_origins.Origin = undefined,
    bottom: *const generic_origins.Origin = undefined,
    first: *const generic_origins.Origin = undefined,
    second: *const generic_origins.Origin = undefined,
    third: *const generic_origins.Origin = undefined,
    both: *const generic_origins.Origin = undefined,

    /// The adapter borrows the probe's interner, so the context must be filled
    /// in place: returning it by value would leave the recorded pointer
    /// pointing at the frame that held the probe.
    fn init(self: *ExitEdgeContext, allocator: std.mem.Allocator) !void {
        self.* = ExitEdgeContext{
            .probe = try origin_probe.load(allocator, "exit_edge_origins.cy", exit_edge_source),
            .store = generic_origins.Store.init(allocator),
            .adapter = undefined,
            .concrete = undefined,
            .bottom = undefined,
            .first = undefined,
            .second = undefined,
            .third = undefined,
            .both = undefined,
        };
        const types = if (self.probe.module.canonical_types) |*value| value else {
            self.probe.deinit();
            return error.TestUnexpectedResult;
        };
        self.adapter = generic_origins.TypeAdapter{ .types = types };
        self.concrete = try self.store.intern(&.{.concrete});
        self.bottom = try self.store.intern(&.{});
        self.first = try self.store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 0 } }});
        self.second = try self.store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 1 } }});
        self.third = try self.store.intern(&.{.{ .parameter = .{ .scope = @fromBackingInt(@intCast(0)), .ordinal = 2 } }});
        self.both = try self.store.join(self.first, self.second);
    }

    fn deinit(self: *ExitEdgeContext) void {
        self.store.deinit();
        self.probe.deinit();
    }

    /// Wrap an origin seed in the checked parameter's declared type so the flow
    /// can walk the body from a typed fact.
    fn typed(self: *ExitEdgeContext, target: *const sir.Function, index: usize, origin: *const generic_origins.Origin) (error{ OutOfMemory, DuplicateChild, InvalidTypeId } || error{TestUnexpectedResult})!*const generic_origins.Fact {
        const type_id = target.params[index].type_id orelse return error.TestUnexpectedResult;
        return try self.store.internFact(try self.adapter.term(type_id), origin, &.{});
    }

    fn untypedFact(self: *ExitEdgeContext, target: *const sir.Function, index: usize) (error{ OutOfMemory, DuplicateChild, InvalidTypeId } || error{TestUnexpectedResult})!*const generic_origins.Fact {
        const type_id = target.params[index].type_id orelse return error.TestUnexpectedResult;
        return try self.adapter.unknownFact(&self.store, type_id);
    }

    fn run(self: *ExitEdgeContext, target: *const sir.Function, params: []const *const generic_origins.Fact) (generic_origins.PreparedStraightLine.Error || error{TestUnexpectedResult})!generic_origins.StraightLineFlow.Result {
        return flowVariant(&self.probe, &self.store, target, params);
    }
};

test "checked origin flow joins branch successors in either arm order" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    const joiner = context.probe.function("joinBranches") orelse return error.TestUnexpectedResult;
    const flag = try context.typed(joiner, 0, context.concrete);
    const first = try context.typed(joiner, 1, context.first);
    const second = try context.typed(joiner, 2, context.second);

    // Both arms are successors of the same edge, so the fact carried after the
    // branch is the join of what each arm leaves in the binding.
    const joined = try context.run(joiner, &.{ flag, first, second });
    defer joined.deinit(allocator);
    try std.testing.expectEqual(context.both, joined.returned.?.receiver);

    // Reversing the arms visits the same successors, so the join is unchanged.
    var reversed_body = try allocator.dupe(sir.Stmt, joiner.body);
    defer allocator.free(reversed_body);
    var branch = reversed_body[1].@"if";
    const then_body = branch.then_body;
    branch.then_body = branch.else_body;
    branch.else_body = then_body;
    reversed_body[1] = .{ .@"if" = branch };
    const reversed = try flowBodyVariant(&context.probe, &context.store, joiner, &.{ flag, first, second }, reversed_body);
    defer reversed.deinit(allocator);
    try std.testing.expectEqual(context.both, reversed.returned.?.receiver);

    // When both arms agree, the join is that fact rather than a widening of the
    // binding's earlier origin.
    const agreed = context.probe.function("sameFactInBothArms") orelse return error.TestUnexpectedResult;
    const agreement = try context.run(agreed, &.{ flag, first, second });
    defer agreement.deinit(allocator);
    try std.testing.expectEqual(context.second, agreement.returned.?.receiver);

    // An assignment after the join replaces the joined fact with the origin the
    // statement supplies.
    const overwritten = context.probe.function("overwriteAfterJoin") orelse return error.TestUnexpectedResult;
    const third = try context.typed(overwritten, 3, context.third);
    const after_write = try context.run(overwritten, &.{ flag, first, second, third });
    defer after_write.deinit(allocator);
    try std.testing.expectEqual(context.first, after_write.returned.?.receiver);
}

test "checked origin flow joins an arm that detaches the place" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    const detached = context.probe.function("joinDetachedPlace") orelse return error.TestUnexpectedResult;
    const bag = try context.untypedFact(detached, 0);
    const flag = try context.typed(detached, 1, context.concrete);
    const detached_join = try context.run(detached, &.{ bag, flag });
    defer detached_join.deinit(allocator);
    try std.testing.expectEqual(&generic_origins.unresolved, detached_join.returned.?.receiver);
    try std.testing.expectEqual(&generic_origins.unresolved, (detached_join.returned.?.child(.optional_item) orelse detached_join.returned.?).receiver);
}

test "checked origin flow converges a loop header over every back edge" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    const converged = context.probe.function("convergeWhile") orelse return error.TestUnexpectedResult;
    const flag = try context.typed(converged, 0, context.concrete);
    const first = try context.typed(converged, 1, context.first);
    const second = try context.typed(converged, 2, context.second);
    const fixed_point = try context.run(converged, &.{ flag, first, second });
    defer fixed_point.deinit(allocator);
    try std.testing.expectEqual(context.both, fixed_point.returned.?.receiver);
    try std.testing.expectEqual(context.both, fixed_point.values[3].?.receiver);
}

test "checked origin flow prunes the exit edge after a definite error" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    const pruned = context.probe.function("prunedAfterDefiniteError") orelse return error.TestUnexpectedResult;
    const first_param = try context.typed(pruned, 0, context.first);
    const pruned_result = try context.run(pruned, &.{first_param});
    defer pruned_result.deinit(allocator);
    try std.testing.expect(pruned_result.did_return);
    try std.testing.expect(!pruned_result.reachable);
    try std.testing.expectEqual(context.bottom, (pruned_result.returned.?.child(.result_ok) orelse return error.TestUnexpectedResult).receiver);
    try std.testing.expectEqual(context.concrete, (pruned_result.returned.?.child(.result_err) orelse return error.TestUnexpectedResult).receiver);
}

test "checked origin flow joins the successors of an uncertain error edge" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    const forked = context.probe.function("joinAfterUncertainError") orelse return error.TestUnexpectedResult;
    const value = try context.typed(forked, 0, context.concrete);
    const problem = try context.typed(forked, 1, context.second);
    const first_param = try context.typed(forked, 2, context.first);
    const forked_result = try context.run(forked, &.{ value, problem, first_param });
    defer forked_result.deinit(allocator);
    try std.testing.expect(forked_result.did_return);
    try std.testing.expectEqual(context.concrete, (forked_result.returned.?.child(.result_ok) orelse return error.TestUnexpectedResult).receiver);
    try std.testing.expect(generic_origins.Origin.leq(context.second, (forked_result.returned.?.child(.result_err) orelse return error.TestUnexpectedResult).receiver));

    // Only the arm that can fail contributes the error payload; the arm that
    // returns successfully still contributes its own origin.
    const branch_error = context.probe.function("branchErrorExit") orelse return error.TestUnexpectedResult;
    const flag = try context.typed(branch_error, 0, context.concrete);
    const arm_origin = try context.typed(branch_error, 1, context.first);
    const branch_result = try context.run(branch_error, &.{ flag, arm_origin });
    defer branch_result.deinit(allocator);
    try std.testing.expect(branch_result.did_return);
    try std.testing.expectEqual(context.first, (branch_result.returned.?.child(.result_ok) orelse return error.TestUnexpectedResult).receiver);
    try std.testing.expectEqual(context.concrete, (branch_result.returned.?.child(.result_err) orelse return error.TestUnexpectedResult).receiver);
}

test "checked origin flow settles a defer on every exit edge of its scope" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    // A deferred call still settles when the segment exits through a propagated
    // error, consuming the origin its handoff names.
    const defer_error = context.probe.function("deferSettlesOnErrorExit") orelse return error.TestUnexpectedResult;
    const items = try context.untypedFact(defer_error, 0);
    const settled = try context.run(defer_error, &.{items});
    defer settled.deinit(allocator);
    try std.testing.expect(settled.did_return);
    try std.testing.expect(!settled.reachable);

    // Registering the same move twice is rejected because the defer settles at
    // exit and the binding it names is already consumed.
    var doubled_body = try allocator.alloc(sir.Stmt, defer_error.body.len + 1);
    defer allocator.free(doubled_body);
    doubled_body[0] = defer_error.body[0];
    try std.testing.expect(doubled_body[0] == .@"defer");
    doubled_body[1] = .{ .expr = defer_error.body[0].@"defer" };
    @memcpy(doubled_body[2..], defer_error.body[1..]);
    try std.testing.expectError(error.UninitializedBinding, flowBodyVariant(&context.probe, &context.store, defer_error, &.{items}, doubled_body));

    // A defer registered inside a scope settles at that scope's exit edge: once
    // the block ends the place its handoff names carries no checked origin, while
    // a binding the block never touches keeps the origin it was given.
    const scope_exit = context.probe.function("scopeDeferKeepsOuterPlace") orelse return error.TestUnexpectedResult;
    const outer_items = try context.typed(scope_exit, 0, context.first);
    const inner_spare = try context.typed(scope_exit, 1, context.second);
    const kept = try context.run(scope_exit, &.{ outer_items, inner_spare });
    defer kept.deinit(allocator);
    try std.testing.expect(kept.did_return);
    try std.testing.expectEqual(context.first, kept.values[0].?.receiver);
    try std.testing.expectEqual(null, kept.values[1]);
}

test "checked origin flow traverses a statement assembly template without taking its place" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    const assembly = context.probe.function("assemblyStatementUsesCheckedPlace") orelse return error.TestUnexpectedResult;
    const seed = try context.typed(assembly, 0, context.first);
    const survived = try context.run(assembly, &.{seed});
    defer survived.deinit(allocator);
    try std.testing.expect(survived.did_return);
    try std.testing.expect(generic_origins.Origin.leq(context.first, survived.returned.?.receiver));
    try std.testing.expect(!generic_origins.Origin.leq(&generic_origins.unresolved, survived.returned.?.receiver));

    const input = firstExprWithBody(assembly.body, "local") orelse return error.TestUnexpectedResult;
    const metadata = metadataEntry(@constCast(context.probe.module.expr_metadata), input) orelse return error.TestUnexpectedResult;
    const original_root = metadata.metadata.checked_place_root;
    try std.testing.expect(original_root != null);
    metadata.metadata.checked_place_root = .{ .binding = @fromBackingInt(@intCast(999999)) };
    try std.testing.expectError(error.IncorrectBindingIdentity, context.run(assembly, &.{seed}));
    metadata.metadata.checked_place_root = original_root;
    var restored = try context.run(assembly, &.{seed});
    restored.deinit(allocator);
}

/// A checked `Choice` parameter whose active case payload names a caller-supplied
/// origin, so a switch arm can project it without any source-name lookup.
fn checkedChoiceFact(
    context: *ExitEdgeContext,
    target: *const sir.Function,
    payload: *const generic_origins.Fact,
) (error{ OutOfMemory, DuplicateChild, InvalidTypeId } || error{TestUnexpectedResult})!*const generic_origins.Fact {
    const declared = target.params[0].type_id orelse return error.TestUnexpectedResult;
    const decl = for (context.probe.module.unions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "Choice")) break candidate;
    } else return error.TestUnexpectedResult;
    const payload_type = decl.fields[0].type_id orelse return error.TestUnexpectedResult;
    if (payload.type_term != try context.adapter.term(payload_type)) return error.TestUnexpectedResult;
    return try context.store.internFact(try context.adapter.term(declared), context.concrete, &.{.{ .key = .{ .case_payload = 0 }, .fact = payload }});
}

test "checked origin flow joins the exit edge of every switch arm" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    // Each arm is a successor of the switch edge, so the binding carries the join
    // of what every arm leaves behind, not just the arm the flow visited last.
    const joiner = context.probe.function("joinSwitchArms") orelse return error.TestUnexpectedResult;
    const arm_second = try context.typed(joiner, 2, context.second);
    const subject = try checkedChoiceFact(&context, joiner, arm_second);
    const arm_first = try context.typed(joiner, 1, context.first);
    const joined = try context.run(joiner, &.{ subject, arm_first, arm_second });
    defer joined.deinit(allocator);
    try std.testing.expect(joined.did_return);
    try std.testing.expect(!joined.reachable);
    try std.testing.expectEqual(context.both, joined.returned.?.receiver);

    // An `else` arm is one more successor: the entry fact is not joined because
    // the arms together leave no other way out of the switch.
    const elsed = context.probe.function("switchElseArmIsOneSuccessor") orelse return error.TestUnexpectedResult;
    const else_subject = try checkedChoiceFact(&context, elsed, try context.typed(elsed, 2, context.second));
    const else_first = try context.typed(elsed, 1, context.first);
    const else_second = try context.typed(elsed, 2, context.second);
    const else_third = try context.typed(elsed, 3, context.third);
    const else_join = try context.run(elsed, &.{ else_subject, else_first, else_second, else_third });
    defer else_join.deinit(allocator);
    try std.testing.expectEqual(try context.store.join(context.second, context.third), else_join.returned.?.receiver);
    try std.testing.expect(!generic_origins.Origin.leq(context.first, else_join.returned.?.receiver));

    // An arm that returns exits the function, so its value reaches the function
    // return while the fall-through edge keeps the fact the switch never took.
    const returned = context.probe.function("switchArmReturnJoinsFallthrough") orelse return error.TestUnexpectedResult;
    const returned_subject = try checkedChoiceFact(&context, returned, try context.typed(returned, 1, context.second));
    const returned_first = try context.typed(returned, 1, context.first);
    const arm_return = try context.run(returned, &.{ returned_subject, returned_first });
    defer arm_return.deinit(allocator);
    try std.testing.expect(arm_return.did_return);
    try std.testing.expect(!arm_return.reachable);
    try std.testing.expectEqual(context.both, arm_return.returned.?.receiver);
}

test "checked origin flow rejects a switch arm with a forged case owner" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    const joiner = context.probe.function("joinSwitchArms") orelse return error.TestUnexpectedResult;
    const subject = try checkedChoiceFact(&context, joiner, try context.typed(joiner, 2, context.second));
    const first = try context.typed(joiner, 1, context.first);
    const second = try context.typed(joiner, 2, context.second);

    var body = try allocator.dupe(sir.Stmt, joiner.body);
    defer allocator.free(body);
    var branch = body[1].@"switch";
    const original_owner = branch.subject_decl_id;
    branch.subject_decl_id = null;
    body[1] = .{ .@"switch" = branch };
    try std.testing.expectError(error.InvalidCapturePath, flowBodyVariant(&context.probe, &context.store, joiner, &.{ subject, first, second }, body));
    branch.subject_decl_id = original_owner;
    body[1] = .{ .@"switch" = branch };
    const restored = try flowBodyVariant(&context.probe, &context.store, joiner, &.{ subject, first, second }, body);
    restored.deinit(allocator);
}

test "checked origin flow joins a continue edge inside a switch arm with the loop header" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    const loop = context.probe.function("switchContinueEdgeJoinsLoopHeader") orelse return error.TestUnexpectedResult;
    const payload = try context.typed(loop, 2, context.second);
    const subject = try checkedChoiceFact(&context, loop, payload);
    const first = try context.typed(loop, 1, context.first);
    const second = try context.typed(loop, 2, context.second);
    const converged = try context.run(loop, &.{ subject, first, second });
    defer converged.deinit(allocator);
    try std.testing.expect(converged.did_return);
    try std.testing.expect(!converged.reachable);
    // The arm that continues and the arm that falls through both reach the header,
    // so the binding after the loop names the origins from both edges.
    try std.testing.expectEqual(context.both, converged.returned.?.receiver);
}

test "checked origin flow prunes only the switch arm that takes a definite error" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    const arm = context.probe.function("switchArmErrorExitPrunesThatArm") orelse return error.TestUnexpectedResult;
    const payload = try context.typed(arm, 1, context.second);
    const subject = try checkedChoiceFact(&context, arm, payload);
    const first = try context.typed(arm, 1, context.first);
    const forked = try context.run(arm, &.{ subject, first });
    defer forked.deinit(allocator);
    try std.testing.expect(forked.did_return);
    try std.testing.expect(!forked.reachable);
    // The failing arm's remaining statements never run, so nothing it would have
    // returned reaches the success payload; the arm that stays reachable does.
    try std.testing.expectEqual(context.first, (forked.returned.?.child(.result_ok) orelse return error.TestUnexpectedResult).receiver);
    try std.testing.expectEqual(context.concrete, (forked.returned.?.child(.result_err) orelse return error.TestUnexpectedResult).receiver);
}

test "checked origin flow routes an error edge taken in a loop condition" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    const loop = context.probe.function("loopConditionErrorPrunesAfterDefiniteError") orelse return error.TestUnexpectedResult;
    const first = try context.typed(loop, 0, context.first);
    const pruned = try context.run(loop, &.{first});
    defer pruned.deinit(allocator);
    try std.testing.expect(pruned.did_return);
    try std.testing.expect(!pruned.reachable);
    // The condition fails on the error edge before the body runs, and the loop's
    // exit edge is never taken, so no success payload is ever contributed.
    try std.testing.expectEqual(context.bottom, (pruned.returned.?.child(.result_ok) orelse return error.TestUnexpectedResult).receiver);
    try std.testing.expectEqual(context.concrete, (pruned.returned.?.child(.result_err) orelse return error.TestUnexpectedResult).receiver);
}

test "checked origin flow settles a defer on a return inside a lexical scope" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    const scope = context.probe.function("deferSettlesOnReturnInsideScope") orelse return error.TestUnexpectedResult;
    const items = try context.typed(scope, 0, context.first);
    const settled = try context.run(scope, &.{items});
    defer settled.deinit(allocator);
    try std.testing.expect(settled.did_return);
    try std.testing.expect(!settled.reachable);
    // The deferred move runs when the scope exits through the return, so the place
    // it names has no live origin afterwards.
    try std.testing.expectEqual(null, settled.values[0]);
}

test "checked origin flow settles a loop-body defer on its continue edge" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    const loop = context.probe.function("deferSettlesOnContinueEdge") orelse return error.TestUnexpectedResult;
    const items = try context.typed(loop, 0, context.first);
    const flag = try context.typed(loop, 1, context.concrete);
    const settled = try context.run(loop, &.{ items, flag });
    defer settled.deinit(allocator);
    try std.testing.expect(settled.did_return);
    try std.testing.expect(!settled.reachable);
    // The iteration-local place the defer moved is settled when the body exits
    // through `continue`, and the loop scope clears it before the next header test.
    try std.testing.expectEqual(null, settled.values[3]);
    try std.testing.expectEqual(context.first, settled.values[0].?.receiver);
}

/// A container parameter fact whose declared element layer names `element`, so a
/// mutation of that container has a live origin to settle.
fn containerElementFact(
    context: *ExitEdgeContext,
    target: *const sir.Function,
    index: usize,
    element: *const generic_origins.Origin,
) (error{ OutOfMemory, DuplicateChild, InvalidTypeId } || error{TestUnexpectedResult})!*const generic_origins.Fact {
    const type_id = target.params[index].type_id orelse return error.TestUnexpectedResult;
    const declared = try context.adapter.types.get(type_id);
    const item_type = switch (declared.*) {
        .array => |array| array.item,
        .dense_array, .sparse_array => |item| item,
        .slice => |slice| slice.item,
        else => return error.TestUnexpectedResult,
    };
    const item_fact = try context.store.internFact(try context.adapter.term(item_type), element, &.{});
    return try context.store.internFact(try context.adapter.term(type_id), element, &.{.{ .key = .sequence_item, .fact = item_fact }});
}

test "checked origin flow refreshes the place an indirect call receives as a view" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    // The callable runs, so every checked place its view argument reaches may
    // have been written through that view and keeps no proven origin.
    const viewed = context.probe.function("indirectViewCall") orelse return error.TestUnexpectedResult;
    const callable = try context.adapter.unknownFact(&context.store, viewed.params[0].type_id.?);
    const refreshed = try context.run(viewed, &.{ callable, try context.typed(viewed, 1, context.first) });
    defer refreshed.deinit(allocator);
    try std.testing.expect(refreshed.did_return);
    try std.testing.expectEqual(&generic_origins.unresolved, refreshed.returned.?.receiver);

    // A call that receives only copied values cannot reach a place, so the
    // origin the binding recorded survives it.
    const copied = context.probe.function("indirectValueCall") orelse return error.TestUnexpectedResult;
    const copied_callable = try context.adapter.unknownFact(&context.store, copied.params[0].type_id.?);
    const kept = try context.run(copied, &.{ copied_callable, try context.typed(copied, 1, context.first) });
    defer kept.deinit(allocator);
    try std.testing.expect(kept.did_return);
    try std.testing.expectEqual(context.first, kept.returned.?.receiver);
}

test "checked origin flow prunes an indirect call's arguments after a definite error" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    // Slots 0 and 1 are the callable and the slice; the carrier and the call
    // result follow them.
    const pruner = context.probe.function("indirectCallPrunesArgumentsAfterDefiniteError") orelse return error.TestUnexpectedResult;
    const callable = try context.adapter.unknownFact(&context.store, pruner.params[0].type_id.?);
    const items = try context.typed(pruner, 1, context.first);
    const pruned = try context.run(pruner, &.{ callable, items });
    defer pruned.deinit(allocator);
    try std.testing.expect(pruned.did_return);
    try std.testing.expect(!pruned.reachable);
    // The first argument returns through the error edge before the second is
    // read, so the slice the callable would have taken is never moved.
    try std.testing.expectEqual(context.first, (pruned.values[1] orelse return error.TestUnexpectedResult).receiver);
}

test "checked origin flow settles an owned argument a running indirect call takes" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    const taker = context.probe.function("indirectCallSettlesItsOwnedArgument") orelse return error.TestUnexpectedResult;
    const callable = try context.adapter.unknownFact(&context.store, taker.params[0].type_id.?);
    // The callable's declared parameter layer for a slice names an element, so
    // the seeded fact carries that layer too, matching the skeleton the flow
    // joins the argument with.
    const items = try containerElementFact(&context, taker, 1, context.first);
    const settled = try context.run(taker, &.{ callable, items });
    defer settled.deinit(allocator);
    try std.testing.expect(settled.did_return);
    // The callable ran, so the handoff its formal takes leaves the binding that
    // owned the slice with no live origin.
    try std.testing.expectEqual(null, settled.values[1]);
}

test "checked origin flow rejects a forged indirect call contract" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    const viewed = context.probe.function("indirectViewCall") orelse return error.TestUnexpectedResult;
    const callable = try context.adapter.unknownFact(&context.store, viewed.params[0].type_id.?);
    const value = try context.typed(viewed, 1, context.first);
    const body = try copiedBody(allocator, viewed);
    defer allocator.free(body);
    const call = firstExprWithBody(body, "indirect_call") orelse return error.TestUnexpectedResult;
    const declared_result = call.indirect_call.return_type_id orelse return error.TestUnexpectedResult;
    if (declared_result != viewed.params[1].type_id) return error.TestUnexpectedResult;

    // A declared result type that does not match the expression's own type is
    // rejected before any argument is transferred.
    call.indirect_call.return_type_id = viewed.params[0].type_id;
    try std.testing.expectError(error.IncorrectResultType, flowBodyVariant(&context.probe, &context.store, viewed, &.{ callable, value }, body));
    call.indirect_call.return_type_id = declared_result;

    // The operand evaluated as the callable must itself name a checked callable,
    // so a borrowed place cannot become the callee.
    // The argument list is `[]const`, so the probe swaps the callee pointer with
    // the pointer the first argument already owns rather than reallocating the
    // argument slice the flow lowered.
    const original_callee = call.indirect_call.callee;
    defer call.indirect_call.callee = original_callee;
    call.indirect_call.callee = call.indirect_call.args[0].value;
    try std.testing.expectError(error.IncorrectCallableContract, flowBodyVariant(&context.probe, &context.store, viewed, &.{ callable, value }, body));
}

test "checked origin flow settles the element layer a container pop or clear leaves" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    // An insertion joins the element origin and a reserve changes capacity only,
    // so the element layer still names both origins when the container is read.
    const grown = context.probe.function("insertThenReserveKeepsElementOrigins") orelse return error.TestUnexpectedResult;
    const inserted = try context.run(grown, &.{ try containerElementFact(&context, grown, 0, context.first), try context.typed(grown, 1, context.second) });
    defer inserted.deinit(allocator);
    try std.testing.expectEqual(context.both, inserted.returned.?.receiver);
    try std.testing.expectEqual(context.both, (inserted.values[0] orelse return error.TestUnexpectedResult).child(.sequence_item).?.receiver);

    // A pop hands the element origin to the binding that reads it and clears the
    // layer the container no longer holds.
    const popped = context.probe.function("popSettlesTheElementLayer") orelse return error.TestUnexpectedResult;
    const settled = try context.run(popped, &.{try containerElementFact(&context, popped, 0, context.first)});
    defer settled.deinit(allocator);
    try std.testing.expectEqual(context.first, settled.returned.?.receiver);
    const popped_layer = (settled.values[0] orelse return error.TestUnexpectedResult).child(.sequence_item) orelse return error.TestUnexpectedResult;
    try std.testing.expect(popped_layer.receiver.* == .unresolved);

    // A clear destroys the elements in place, so the container's element layer
    // stops naming the origins that left it.
    const cleared = context.probe.function("clearSettlesTheElementLayer") orelse return error.TestUnexpectedResult;
    const emptied = try context.run(cleared, &.{try containerElementFact(&context, cleared, 0, context.first)});
    defer emptied.deinit(allocator);
    const cleared_layer = (emptied.values[0] orelse return error.TestUnexpectedResult).child(.sequence_item) orelse return error.TestUnexpectedResult;
    try std.testing.expect(cleared_layer.receiver.* == .unresolved);
}

test "checked origin flow settles the slot layers sparse storage mutations leave" {
    const allocator = std.testing.allocator;
    var context: ExitEdgeContext = .{};
    try context.init(allocator);
    defer context.deinit();

    // A keyed insert occupies a slot, so the sparse element layer names both the
    // origins the container already held and the value that entered it.
    const inserter = context.probe.function("sparseInsertKeepsElementOrigins") orelse return error.TestUnexpectedResult;
    const grown = try context.run(inserter, &.{ try containerElementFact(&context, inserter, 0, context.first), try context.typed(inserter, 1, context.second) });
    defer grown.deinit(allocator);
    try std.testing.expectEqual(context.both, (grown.values[0] orelse return error.TestUnexpectedResult).child(.sequence_item).?.receiver);

    // A clear empties every slot in place, so the layer stops naming origins that
    // no longer occupy it.
    const clearer = context.probe.function("sparseClearSettlesItsSlots") orelse return error.TestUnexpectedResult;
    const emptied = try context.run(clearer, &.{try containerElementFact(&context, clearer, 0, context.first)});
    defer emptied.deinit(allocator);
    const cleared_layer = (emptied.values[0] orelse return error.TestUnexpectedResult).child(.sequence_item) orelse return error.TestUnexpectedResult;
    try std.testing.expect(cleared_layer.receiver.* == .unresolved);

    // A take moves one slot out of the container through the expression that
    // reads it, so the same layer is settled on that edge too.
    const taker = context.probe.function("sparseTakeSettlesItsSlot") orelse return error.TestUnexpectedResult;
    const settled = try context.run(taker, &.{ try containerElementFact(&context, taker, 0, context.first), try context.typed(taker, 1, context.second) });
    defer settled.deinit(allocator);
    const taken_layer = (settled.values[0] orelse return error.TestUnexpectedResult).child(.sequence_item) orelse return error.TestUnexpectedResult;
    try std.testing.expect(taken_layer.receiver.* == .unresolved);
}

fn instantiatedGeneric(module: sir.Module, prefix: []const u8) ?*const sir.Function {
    for (module.functions) |*candidate| {
        if (std.mem.startsWith(u8, candidate.name, prefix)) return candidate;
    }
    return null;
}

fn checkedBodyReport(
    allocator: std.mem.Allocator,
    probe: *const origin_probe,
    function: *const sir.Function,
    uses: *std.ArrayListUnmanaged(generic_origins.MethodUse),
) generic_origins.AnalyzeError!generic_origins.BodyReport {
    const types = generic_origins.TypeAdapter{ .types = &probe.module.canonical_types.? };
    return generic_origins.analyzeBody(allocator, types, probe.module.functions, function, probe.module.expr_metadata, probe.module.structs, probe.module.unions, uses);
}

test "checked origin flow settles the method use a sparse slot capability reaches" {
    const allocator = std.testing.allocator;
    const source =
        \\protocol Eq { fn eq(self: &const Self, other: &const Self): bool; }
        \\struct Item { key: i32; }
        \\impl Item: Eq { fn eq(self: &const Item, other: &const Item): bool { return self.key == other.key; } }
        \\fn lookup_index<T: Eq>(slots: &[;]T, key: &const T): ?usize {
        \\    for idx in slots.indices() {
        \\        if &slots[idx] is current {
        \\            if current.eq(key) {
        \\                return idx;
        \\            }
        \\        }
        \\    }
        \\    return none;
        \\}
        \\fn main(): i32 {
        \\    var slots = [; 1]Item;
        \\    slots.insert(0, Item { key: 1 });
        \\    var key = Item { key: 1 };
        \\    if lookup_index(&slots, &key) != none {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;
    var probe = try origin_probe.load(allocator, "slot_capability.cy", source);
    defer probe.deinit();

    // Sema already demands the checked flow for every body that records a
    // generic method use, so a successful load is the admission evidence.
    const lookup = instantiatedGeneric(probe.module, "lookup_index") orelse return error.TestUnexpectedResult;
    var uses: std.ArrayListUnmanaged(generic_origins.MethodUse) = .empty;
    defer uses.deinit(allocator);
    const report = try checkedBodyReport(allocator, &probe, lookup, &uses);

    try std.testing.expectEqual(@as(usize, 1), report.method_uses);
    try std.testing.expectEqual(lookup.return_type_id, report.returned_type);
    try std.testing.expect(report.did_return);
    try std.testing.expect(!report.reachable);
    // The body reaches exactly one witness call. The stored receiver fact
    // belongs to analyzeBody's temporary store and cannot be dereferenced here.
    try std.testing.expectEqual(@as(usize, 1), uses.items.len);
}

test "checked origin flow admits a mutable view at a const view formal" {
    const allocator = std.testing.allocator;
    const source =
        \\protocol Eq { fn eq(self: &const Self, other: &const Self): bool; }
        \\struct Item { key: i32; }
        \\impl Item: Eq { fn eq(self: &const Item, other: &const Item): bool { return self.key == other.key; } }
        \\fn twice<T: Eq>(value: T, expected: T): bool { return value.eq(&expected); }
        \\fn main(): i32 {
        \\    var first = Item { key: 1 };
        \\    if twice(first, Item { key: 2 }) {
        \\        return 7;
        \\    }
        \\    return 0;
        \\}
    ;
    var probe = try origin_probe.load(allocator, "const_view_formal.cy", source);
    defer probe.deinit();

    const twice = instantiatedGeneric(probe.module, "twice") orelse return error.TestUnexpectedResult;
    var uses: std.ArrayListUnmanaged(generic_origins.MethodUse) = .empty;
    defer uses.deinit(allocator);
    const report = try checkedBodyReport(allocator, &probe, twice, &uses);
    try std.testing.expectEqual(@as(usize, 1), report.method_uses);
    try std.testing.expectEqual(twice.return_type_id, report.returned_type);
}

test "checked origin flow rejects a method use whose receiver is proven empty" {
    const allocator = std.testing.allocator;
    const source =
        \\protocol Eq { fn eq(self: &const Self, other: &const Self): bool; }
        \\struct Item { key: i32; }
        \\impl Item: Eq { fn eq(self: &const Item, other: &const Item): bool { return self.key == other.key; } }
        \\fn compare<T: Eq>(left: T, right: T): bool { return left.eq(&right); }
        \\fn main(): i32 {
        \\    var a = Item { key: 1 };
        \\    var b = Item { key: 2 };
        \\    if compare(a, b) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;
    var probe = try origin_probe.load(allocator, "empty_receiver.cy", source);
    defer probe.deinit();

    const compare = instantiatedGeneric(probe.module, "compare") orelse return error.TestUnexpectedResult;
    const types = generic_origins.TypeAdapter{ .types = &probe.module.canonical_types.? };
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();

    // Same types, but every parameter place names no reachable value.
    var initial: std.ArrayListUnmanaged(*const generic_origins.Fact) = .empty;
    defer initial.deinit(allocator);
    for (compare.params) |param| {
        try initial.append(allocator, try store.internFact(try types.term(param.type_id.?), &generic_origins.bottom, &.{}));
    }

    var prepared = try generic_origins.PreparedStraightLine.init(allocator, types, compare, probe.module.expr_metadata, probe.module.structs, probe.module.unions, initial.items);
    defer prepared.deinit();
    prepared.expression.functions = probe.module.functions;
    var uses: std.ArrayListUnmanaged(generic_origins.MethodUse) = .empty;
    defer uses.deinit(allocator);
    prepared.expression.method_uses = &uses;

    try std.testing.expectError(error.UnverifiedMethodReceiver, prepared.run(&store));
    try std.testing.expectEqual(@as(usize, 0), uses.items.len);
}

test "checked origin consumer rejects a method use the body cannot reach" {
    const allocator = std.testing.allocator;
    const source =
        \\protocol Eq { fn eq(self: &const Self, other: &const Self): bool; }
        \\struct Item { key: i32; }
        \\impl Item: Eq { fn eq(self: &const Item, other: &const Item): bool { return self.key == other.key; } }
        \\fn dead<T: Eq>(value: T, other: T): bool {
        \\    if false {
        \\        return value.eq(&other);
        \\    }
        \\    return false;
        \\}
        \\fn main(): i32 {
        \\    var a = Item { key: 1 };
        \\    var b = Item { key: 2 };
        \\    if dead(a, b) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;
    // The body records a generic method use, and the checked flow proves the
    // branch holding it unreachable, so the declaration is not admitted.
    try std.testing.expectError(error.SemanticFailed, origin_probe.load(allocator, "dead_branch.cy", source));
}

const generated_iteration_source =
    \\struct Bag<T> {
    \\    items: [:]T;
    \\    @syntax.iter pub fn begin(self: &const Bag<T>): usize { return 0; }
    \\    @syntax.iter_has_next pub fn more(self: &const Bag<T>, state: &const usize): bool { return state < self.items.len(); }
    \\    @syntax.iter_next pub fn advance(self: &const Bag<T>, state: &usize): usize { const cursor: usize = state; state = state + 1; return cursor; }
    \\    @syntax.iter_item pub fn element(self: &const Bag<T>, cursor: usize): &const T { return &self.items[cursor]; }
    \\}
    \\protocol Readable { fn read(self: &const Self): i32; }
    \\struct Value { number: i32; }
    \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
    \\fn total<T: Readable>(values: &const Bag<T>): i32 {
    \\    var sum: i32 = 0;
    \\    for item in values { sum = sum + item.read(); }
    \\    return sum;
    \\}
    \\fn main(): i32 {
    \\    var values = Bag<Value> { items: [Value { number: 2 }, Value { number: 3 }] };
    \\    return total(&values);
    \\}
;

fn loopOf(body: []const sir.Stmt) ?*const sir.For {
    for (body, 0..) |statement, index| {
        if (statement == .@"for") return &body[index].@"for";
    }
    return null;
}

test "checked origin flow settles the method uses a protocol iterator generates" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "generated_iteration.cy", generated_iteration_source);
    defer probe.deinit();
    // The specialization is registered under the canonical module-qualified
    // type argument, so locate it by the generic's name prefix.
    const target = instantiatedGeneric(probe.module, "total<") orelse return error.TestUnexpectedResult;
    const loop = loopOf(target.body) orelse return error.TestUnexpectedResult;

    // Each `syntax.iter*` hook the loop desugars into carries its own checked
    // record: a distinct use id, the concrete hook declaration, and the type
    // that hook settles against the iterable's own receiver type.
    try std.testing.expectEqual(@as(usize, 4), loop.generated_method_uses.len);
    var ids: [4]u32 = undefined;
    for (loop.generated_method_uses, 0..) |use, index| {
        ids[index] = use.use_id;
        try std.testing.expect(use.use_id != 0);
        try std.testing.expect(use.receiver_type_id == use.subject_type_id);
        switch (index) {
            0 => {
                try std.testing.expectEqual(sir.GeneratedIterationRole.iterator_init, use.role);
                try std.testing.expect(use.method_declaration_id == loop.iterator_init_decl_id.?);
                try std.testing.expect(use.result_type_id == loop.iterator_state_type_id.?);
            },
            1 => {
                try std.testing.expectEqual(sir.GeneratedIterationRole.iterator_has_next, use.role);
                try std.testing.expect(use.method_declaration_id == loop.iterator_has_next_decl_id.?);
            },
            2 => {
                try std.testing.expectEqual(sir.GeneratedIterationRole.iterator_next, use.role);
                try std.testing.expect(use.method_declaration_id == loop.iterator_next_decl_id.?);
                try std.testing.expect(use.result_type_id == loop.iterator_cursor_type_id.?);
            },
            else => {
                try std.testing.expectEqual(sir.GeneratedIterationRole.iterable_item, use.role);
                try std.testing.expect(use.method_declaration_id == loop.iterable_index_decl_id.?);
            },
        }
    }
    for (ids, 0..) |id, index| {
        for (ids[0..index]) |prior| try std.testing.expect(prior != id);
    }

    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    var uses: std.ArrayListUnmanaged(generic_origins.MethodUse) = .empty;
    defer uses.deinit(allocator);
    const types = if (probe.module.canonical_types) |*value| value else return error.TestUnexpectedResult;
    _ = try generic_origins.analyzeBody(allocator, generic_origins.TypeAdapter{ .types = types }, probe.module.functions, target, probe.module.expr_metadata, probe.module.structs, probe.module.unions, &uses);
    // The flow reaches every generated hook, and each settles exactly once.
    for (loop.generated_method_uses) |generated| {
        var settled: usize = 0;
        for (uses.items) |use| {
            if (use.use_id == generated.use_id) settled += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), settled);
    }
}

test "checked origin flow rejects a forged generated iterator hook record" {
    const allocator = std.testing.allocator;
    var probe = try origin_probe.load(allocator, "generated_iteration_forged.cy", generated_iteration_source);
    defer probe.deinit();
    const target = instantiatedGeneric(probe.module, "total<") orelse return error.TestUnexpectedResult;
    var body = try allocator.dupe(sir.Stmt, target.body);
    defer allocator.free(body);
    var forged: []sir.GeneratedMethodUse = &.{};
    defer allocator.free(forged);
    for (body, 0..) |statement, index| {
        if (statement == .@"for") {
            // The `syntax.iter_item` hook settles a borrowed item view; claiming
            // it settles the cursor type instead is a forged signature.
            forged = try allocator.alloc(sir.GeneratedMethodUse, body[index].@"for".generated_method_uses.len);
            @memcpy(forged, body[index].@"for".generated_method_uses);
            forged[3].result_type_id = body[index].@"for".iterator_cursor_type_id.?;
            body[index].@"for".generated_method_uses = forged;
            break;
        }
    }
    var store = generic_origins.Store.init(allocator);
    defer store.deinit();
    try std.testing.expectError(error.IncorrectCallSignature, runVariant(&probe, &store, target, body));
}

const max_catch_shapes: usize = 8;

const CatchShape = struct {
    switches: [max_catch_shapes]?*const sir.Switch = .{ null, null, null, null, null, null, null, null },
    count: usize = 0,
};

const ThrowShape = struct {
    cases: [max_catch_shapes]?*const sir.UnionCaseExpr = .{ null, null, null, null, null, null, null, null },
    count: usize = 0,
};

// Source `catch` lowers to an internal result switch marked `catch_fallback`;
// its error arm holds the handler block. Preorder traversal names the outer
// catch entry before any catch nested inside that handler.
fn collectSwitchShapes(switch_ref: *const sir.Switch, catches: *CatchShape, throws: *ThrowShape) void {
    if (switch_ref.catch_fallback and catches.count < max_catch_shapes) {
        catches.switches[catches.count] = switch_ref;
        catches.count += 1;
    }
    for (switch_ref.cases) |case| collectStatementShapes(case.body, catches, throws);
    if (switch_ref.has_else) collectStatementShapes(switch_ref.else_body, catches, throws);
}

fn collectExpressionShapes(expr: *const sir.Expr, catches: *CatchShape, throws: *ThrowShape) void {
    switch (expr.*) {
        .union_case => {
            if (expr.union_case.from_throw and throws.count < max_catch_shapes) {
                throws.cases[throws.count] = &expr.union_case;
                throws.count += 1;
            }
            if (expr.union_case.value) |value| collectExpressionShapes(value, catches, throws);
        },
        .@"switch" => collectSwitchShapes(&expr.@"switch", catches, throws),
        else => {},
    }
}

fn collectStatementShapes(statements: []const sir.Stmt, catches: *CatchShape, throws: *ThrowShape) void {
    for (statements, 0..) |stmt, index| {
        switch (stmt) {
            .@"switch" => collectSwitchShapes(&statements[index].@"switch", catches, throws),
            .@"return" => |maybe_expr| if (maybe_expr) |expr| collectExpressionShapes(expr, catches, throws),
            .yield => |maybe_expr| if (maybe_expr) |expr| collectExpressionShapes(expr, catches, throws),
            else => {},
        }
    }
}

fn catchErrorCase(switch_ref: *const sir.Switch) ?sir.SwitchCase {
    for (switch_ref.cases) |case| {
        if (std.mem.eql(u8, case.case_name, "err")) return case;
    }
    return null;
}

fn findSirFunction(functions: []const sir.Function, name: []const u8) ?*const sir.Function {
    for (functions, 0..) |function, index| {
        if (std.mem.eql(u8, function.name, name)) return &functions[index];
    }
    return null;
}

fn findLoweredFunctionIndex(module: anytype, suffix: []const u8) ?usize {
    for (module.functions, 0..) |function, index| {
        if (std.mem.endsWith(u8, function.name, suffix)) return index;
    }
    return null;
}

// A block records `catch_failure` when it holds a catch entry whose internal
// result carrier the handler borrows. Blocks appear in lowering order, so the
// outer catch entry precedes any catch nested inside its handler.
fn catchEntryIndices(function: anytype, out: *[max_catch_shapes]usize) usize {
    var count: usize = 0;
    for (function.blocks, 0..) |block, index| {
        if (block.catch_failure == null) continue;
        if (count == max_catch_shapes) break;
        out[count] = index;
        count += 1;
    }
    return count;
}

fn instTagById(function: anytype, value: u32) ?[]const u8 {
    for (function.blocks) |block| {
        for (block.instructions) |inst| {
            if (inst.id != null and inst.id.? == value) return @tagName(inst.data);
        }
    }
    return null;
}

const CatchFixture = struct {
    sir_module: sir.Module,
    lir_module: lir.Module,
    sir_probe: *const sir.Function,
    lir_probe: *const lir.Function,
};

// Each fixture is a `probe` that catches the failure `inner` throws.
fn catchFixture(allocator: std.mem.Allocator, name: []const u8, source: []const u8) !CatchFixture {
    const tokens = try lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try parser.parse(allocator, name, source, tokens);
    defer program.deinit(allocator);
    const sir_module = try sema.buildSir(allocator, name, program);
    errdefer sir_module.deinit(allocator);
    const lir_module = try lower.lowerModuleWithOptions(allocator, sir_module, .{ .fallback_source_path = name });
    const sir_probe = findSirFunction(sir_module.functions, "probe") orelse return error.MissingSirProbe;
    const lir_index = findLoweredFunctionIndex(lir_module, "probe") orelse return error.MissingLoweredProbe;
    return .{
        .sir_module = sir_module,
        .lir_module = lir_module,
        .sir_probe = sir_probe,
        .lir_probe = &lir_module.functions[lir_index],
    };
}

fn blockAtIndex(function: *const lir.Function, index: usize) ?*const lir.BasicBlock {
    if (index >= function.blocks.len) return null;
    return &function.blocks[index];
}

fn instById(function: *const lir.Function, value: lir.ValueId) ?*const lir.Inst {
    for (function.blocks, 0..) |block, block_index| {
        for (block.instructions, 0..) |inst, inst_index| {
            if (inst.id != null and inst.id.? == value) {
                return &function.blocks[block_index].instructions[inst_index];
            }
        }
    }
    return null;
}

// The block whose instruction produced `value`; blocks appear in lowering order.
fn blockProducingInst(function: *const lir.Function, value: lir.ValueId) ?*const lir.BasicBlock {
    for (function.blocks, 0..) |block, block_index| {
        for (block.instructions) |inst| {
            if (inst.id != null and inst.id.? == value) return &function.blocks[block_index];
        }
    }
    return null;
}

fn returnedValue(block: *const lir.BasicBlock) ?lir.ValueId {
    if (block.terminator != .@"return") return null;
    return block.terminator.@"return";
}

fn terminatorTarget(block: *const lir.BasicBlock) ?lir.BlockId {
    if (block.terminator == .br) return block.terminator.br;
    return null;
}

// `ok`/`err` and payload of a block that ends with `return make_result ...`.
fn returnedResult(function: *const lir.Function, block: *const lir.BasicBlock) ?lir.MakeResult {
    const value = returnedValue(block) orelse return null;
    const inst = instById(function, value) orelse return null;
    if (inst.data != .make_result) return null;
    return inst.data.make_result;
}

// Stack slot the catch entry block stores the extracted error payload into.
fn caughtPayloadSlot(block: *const lir.BasicBlock, carrier: lir.ValueId) ?lir.ValueId {
    var extracted: ?lir.ValueId = null;
    for (block.instructions) |inst| {
        if (inst.data == .extract_result and inst.data.extract_result.is_err and inst.data.extract_result.value == carrier) {
            extracted = inst.id;
        }
        if (inst.data == .store and extracted != null and inst.data.store.value == extracted.?) {
            return inst.data.store.ptr;
        }
    }
    return null;
}

fn countReturns(function: *const lir.Function) usize {
    var count: usize = 0;
    for (function.blocks) |block| {
        if (block.terminator == .@"return") count += 1;
    }
    return count;
}

// The catch entry arm extracts the carrier and branches into the handler body.
fn handlerOfEntry(function: *const lir.Function, entry: *const lir.BasicBlock) ?*const lir.BasicBlock {
    const target = terminatorTarget(entry) orelse return null;
    return blockAtIndex(function, target);
}

test "nested catch records one distinct carrier per catch entry in source order" {
    const allocator = std.testing.allocator;
    const fixture = try catchFixture(allocator, "nested_catch.cy",
        \\enum Fault { bad; other; }
        \\fn inner(): i32!Fault { throw Fault.bad; }
        \\fn outer(): i32!Fault { throw Fault.other; }
        \\fn probe(): i32!Fault {
        \\    return inner() catch (code) { return outer() catch (nested) { throw code; }; };
        \\}
    );
    defer fixture.sir_module.deinit(allocator);
    defer fixture.lir_module.deinit(allocator);

    var sir_catches: CatchShape = .{};
    var sir_throws: ThrowShape = .{};
    collectStatementShapes(fixture.sir_probe.body, &sir_catches, &sir_throws);
    try std.testing.expect(sir_catches.count == 2);
    const outer_case = catchErrorCase(sir_catches.switches[0].?) orelse return error.MissingOuterCatchArm;
    const inner_case = catchErrorCase(sir_catches.switches[1].?) orelse return error.MissingInnerCatchArm;
    try std.testing.expectEqualStrings("code", outer_case.payload_name orelse "");
    try std.testing.expectEqualStrings("nested", inner_case.payload_name orelse "");
    const outer_binding = outer_case.payload_binding_id orelse return error.MissingOuterBinding;
    const inner_binding = inner_case.payload_binding_id orelse return error.MissingInnerBinding;
    try std.testing.expect(outer_binding != inner_binding);

    var entries: [max_catch_shapes]usize = std.mem.zeroes([max_catch_shapes]usize);
    const entry_count = catchEntryIndices(fixture.lir_probe, &entries);
    try std.testing.expect(entry_count == 2);
    const outer_entry = blockAtIndex(fixture.lir_probe, entries[0]) orelse return error.MissingOuterEntry;
    const inner_entry = blockAtIndex(fixture.lir_probe, entries[1]) orelse return error.MissingInnerEntry;
    const outer_carrier = outer_entry.catch_failure orelse return error.MissingOuterCarrier;
    const inner_carrier = inner_entry.catch_failure orelse return error.MissingInnerCarrier;
    try std.testing.expect(outer_carrier != inner_carrier);
    // Each carrier is the internal result of the call its catch is attached to.
    try std.testing.expectEqualStrings("call", instTagById(fixture.lir_probe, outer_carrier) orelse "");
    try std.testing.expectEqualStrings("call", instTagById(fixture.lir_probe, inner_carrier) orelse "");
    // The nested carrier is built inside the outer handler, so the inner catch
    // borrows a failure that only lives while the outer handler is live.
    const outer_handler = handlerOfEntry(fixture.lir_probe, outer_entry) orelse return error.MissingOuterHandler;
    const inner_carrier_block = blockProducingInst(fixture.lir_probe, inner_carrier) orelse return error.MissingInnerCarrierBlock;
    try std.testing.expectEqualStrings(outer_handler.name, inner_carrier_block.name);
    var found_nested_exit = false;
    for (fixture.lir_probe.blocks) |block| {
        if (block.catch_exits.len != 2) continue;
        try std.testing.expectEqual(inner_carrier, block.catch_exits[0].carrier);
        try std.testing.expectEqual(outer_carrier, block.catch_exits[1].carrier);
        try std.testing.expect(block.catch_exits[0].disposition == .handled);
        try std.testing.expect(block.catch_exits[1].disposition == .propagated_alias);
        found_nested_exit = true;
    }
    try std.testing.expect(found_nested_exit);
}

test "same-binding rethrow returns the payload slot the catch extracted" {
    const allocator = std.testing.allocator;
    const fixture = try catchFixture(allocator, "same_binding_rethrow.cy",
        \\enum Fault { bad; other; }
        \\fn inner(): i32!Fault { throw Fault.bad; }
        \\fn probe(): i32!Fault { return inner() catch (code) { throw code; }; }
    );
    defer fixture.sir_module.deinit(allocator);
    defer fixture.lir_module.deinit(allocator);

    var sir_catches: CatchShape = .{};
    var sir_throws: ThrowShape = .{};
    collectStatementShapes(fixture.sir_probe.body, &sir_catches, &sir_throws);
    try std.testing.expect(sir_catches.count == 1);
    try std.testing.expect(sir_throws.count == 1);
    const catch_case = catchErrorCase(sir_catches.switches[0].?) orelse return error.MissingCatchArm;
    const throw_case = sir_throws.cases[0].?;
    try std.testing.expect(throw_case.from_throw);
    const rethrow_binding = throw_case.throw_local_binding_id orelse return error.MissingRethrowBinding;
    const caught_binding = catch_case.payload_binding_id orelse return error.MissingCaughtBinding;
    try std.testing.expect(rethrow_binding == caught_binding);

    var entries: [max_catch_shapes]usize = std.mem.zeroes([max_catch_shapes]usize);
    try std.testing.expect(catchEntryIndices(fixture.lir_probe, &entries) == 1);
    const entry = blockAtIndex(fixture.lir_probe, entries[0]) orelse return error.MissingEntry;
    const carrier = entry.catch_failure orelse return error.MissingCarrier;
    const caught_slot = caughtPayloadSlot(entry, carrier) orelse return error.MissingCaughtSlot;
    const handler = handlerOfEntry(fixture.lir_probe, entry) orelse return error.MissingHandler;
    const result = returnedResult(fixture.lir_probe, handler) orelse return error.HandlerNotResultReturn;
    try std.testing.expect(result.is_err);
    try std.testing.expect(result.trace == .transfer);
    try std.testing.expectEqual(carrier, result.trace.transfer.carrier);
    try std.testing.expect(result.trace.transfer.append_site == null);
    const payload = result.payload orelse return error.MissingRethrowPayload;
    const payload_inst = instById(fixture.lir_probe, payload) orelse return error.MissingRethrowPayloadInst;
    try std.testing.expect(payload_inst.data == .load);
    try std.testing.expect(payload_inst.data.load == caught_slot);
    try std.testing.expectEqual(@as(usize, 1), handler.catch_exits.len);
    try std.testing.expectEqual(carrier, handler.catch_exits[0].carrier);
    try std.testing.expect(handler.catch_exits[0].disposition == .propagated_alias);
}

test "fresh throw inside a catch builds a new error payload" {
    const allocator = std.testing.allocator;
    const fixture = try catchFixture(allocator, "fresh_throw.cy",
        \\enum Fault { bad; other; }
        \\fn inner(): i32!Fault { throw Fault.bad; }
        \\fn probe(): i32!Fault { return inner() catch (code) { throw Fault.other; }; }
    );
    defer fixture.sir_module.deinit(allocator);
    defer fixture.lir_module.deinit(allocator);

    var sir_catches: CatchShape = .{};
    var sir_throws: ThrowShape = .{};
    collectStatementShapes(fixture.sir_probe.body, &sir_catches, &sir_throws);
    try std.testing.expect(sir_catches.count == 1);
    try std.testing.expect(sir_throws.count == 1);
    const throw_case = sir_throws.cases[0].?;
    try std.testing.expect(throw_case.from_throw);
    // The source `throw` lowers to the result `.err` wrapper; the enum case sits
    // one level below it as the error payload.
    try std.testing.expectEqualStrings("err", throw_case.case_name);
    const payload_expr = throw_case.value orelse return error.MissingThrowPayloadExpr;
    try std.testing.expect(payload_expr.* == .enum_case);
    try std.testing.expectEqualStrings("Fault", payload_expr.enum_case.type_name);
    try std.testing.expectEqualStrings("other", payload_expr.enum_case.case_name);
    try std.testing.expectEqual(payload_expr.enum_case.value, 1);
    // A qualified enum case is a distinct failure, not an alias of the caught code.
    try std.testing.expect(throw_case.throw_local_binding_id == null);

    var entries: [max_catch_shapes]usize = std.mem.zeroes([max_catch_shapes]usize);
    try std.testing.expect(catchEntryIndices(fixture.lir_probe, &entries) == 1);
    const entry = blockAtIndex(fixture.lir_probe, entries[0]) orelse return error.MissingEntry;
    const handler = handlerOfEntry(fixture.lir_probe, entry) orelse return error.MissingHandler;
    const result = returnedResult(fixture.lir_probe, handler) orelse return error.HandlerNotResultReturn;
    try std.testing.expect(result.is_err);
    try std.testing.expect(result.trace == .create);
    const payload = result.payload orelse return error.MissingFreshPayload;
    const payload_inst = instById(fixture.lir_probe, payload) orelse return error.MissingFreshPayloadInst;
    try std.testing.expect(payload_inst.data == .const_int);
    // `Fault.other` is enum code 1; the payload is not a load of the caught slot.
    try std.testing.expect(payload_inst.data.const_int == 1);
    try std.testing.expectEqual(@as(usize, 1), handler.catch_exits.len);
    try std.testing.expectEqual(entry.catch_failure.?, handler.catch_exits[0].carrier);
    try std.testing.expect(handler.catch_exits[0].disposition == .handled);
}

test "try propagation transfers the source carrier with one site" {
    const allocator = std.testing.allocator;
    const fixture = try catchFixture(allocator, "try_trace_transfer.cy",
        \\enum Fault { bad; }
        \\fn inner(): i32!Fault { throw Fault.bad; }
        \\fn probe(): i32!Fault { return try inner(); }
    );
    defer fixture.sir_module.deinit(allocator);
    defer fixture.lir_module.deinit(allocator);

    var transfers: usize = 0;
    for (fixture.lir_probe.blocks) |block| {
        for (block.instructions) |inst| {
            if (inst.data != .make_result or inst.data.make_result.trace != .transfer) continue;
            const transfer = inst.data.make_result.trace.transfer;
            if (transfer.append_site == null) continue;
            const source = instById(fixture.lir_probe, transfer.carrier) orelse return error.MissingTransferSource;
            try std.testing.expect(source.data == .call);
            transfers += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), transfers);
}

test "early return inside a catch handler ends the handler block" {
    const allocator = std.testing.allocator;
    const fixture = try catchFixture(allocator, "early_return.cy",
        \\enum Fault { bad; other; }
        \\fn inner(): i32!Fault { throw Fault.bad; }
        \\fn probe(): i32!Fault { return inner() catch (code) { return 5; }; }
    );
    defer fixture.sir_module.deinit(allocator);
    defer fixture.lir_module.deinit(allocator);

    var sir_catches: CatchShape = .{};
    var sir_throws: ThrowShape = .{};
    collectStatementShapes(fixture.sir_probe.body, &sir_catches, &sir_throws);
    try std.testing.expect(sir_catches.count == 1);
    try std.testing.expect(sir_throws.count == 0);

    var entries: [max_catch_shapes]usize = std.mem.zeroes([max_catch_shapes]usize);
    try std.testing.expect(catchEntryIndices(fixture.lir_probe, &entries) == 1);
    const entry = blockAtIndex(fixture.lir_probe, entries[0]) orelse return error.MissingEntry;
    const handler = handlerOfEntry(fixture.lir_probe, entry) orelse return error.MissingHandler;
    // The handler returns on its own instead of falling into the catch continuation.
    try std.testing.expect(terminatorTarget(handler) == null);
    const result = returnedResult(fixture.lir_probe, handler) orelse return error.HandlerNotResultReturn;
    try std.testing.expect(!result.is_err);
    const payload = result.payload orelse return error.MissingEarlyReturnPayload;
    const payload_inst = instById(fixture.lir_probe, payload) orelse return error.MissingEarlyReturnPayloadInst;
    try std.testing.expect(payload_inst.data == .const_int);
    try std.testing.expect(payload_inst.data.const_int == 5);
    // One return from the catch continuation, one from the handler.
    try std.testing.expect(countReturns(fixture.lir_probe) == 2);
    try std.testing.expectEqual(@as(usize, 1), handler.catch_exits.len);
    try std.testing.expectEqual(entry.catch_failure.?, handler.catch_exits[0].carrier);
    try std.testing.expect(handler.catch_exits[0].disposition == .handled);
}

test "yield inside a catch handler rejoins the catch continuation" {
    const allocator = std.testing.allocator;
    const fixture = try catchFixture(allocator, "catch_yield.cy",
        \\enum Fault { bad; other; }
        \\fn inner(): i32!Fault { throw Fault.bad; }
        \\fn probe(): i32!Fault { return inner() catch (code) { yield 1; }; }
    );
    defer fixture.sir_module.deinit(allocator);
    defer fixture.lir_module.deinit(allocator);

    var sir_catches: CatchShape = .{};
    var sir_throws: ThrowShape = .{};
    collectStatementShapes(fixture.sir_probe.body, &sir_catches, &sir_throws);
    try std.testing.expect(sir_catches.count == 1);
    try std.testing.expect(sir_throws.count == 0);

    var entries: [max_catch_shapes]usize = std.mem.zeroes([max_catch_shapes]usize);
    try std.testing.expect(catchEntryIndices(fixture.lir_probe, &entries) == 1);
    const entry = blockAtIndex(fixture.lir_probe, entries[0]) orelse return error.MissingEntry;
    const handler = handlerOfEntry(fixture.lir_probe, entry) orelse return error.MissingHandler;
    // A yield stores the value and branches onward; it does not terminate the handler.
    try std.testing.expect(returnedValue(handler) == null);
    const yielded_block = blockAtIndex(fixture.lir_probe, terminatorTarget(handler) orelse return error.MissingYieldTarget) orelse return error.MissingYieldBlock;
    var handled_exits: usize = 0;
    for (fixture.lir_probe.blocks) |block| {
        for (block.catch_exits) |catch_exit| {
            if (catch_exit.carrier != entry.catch_failure.?) continue;
            try std.testing.expect(catch_exit.disposition == .handled);
            handled_exits += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), handled_exits);
    var stored_yield_code: ?i64 = null;
    for (handler.instructions) |inst| {
        if (inst.data != .store) continue;
        const value_inst = instById(fixture.lir_probe, inst.data.store.value) orelse continue;
        if (value_inst.data == .const_int) stored_yield_code = value_inst.data.const_int;
    }
    try std.testing.expect(stored_yield_code == 1);
    // The yield path reaches the single success return of the catch continuation.
    var walk_block = yielded_block;
    var steps: usize = 0;
    while (steps < 6) {
        if (returnedResult(fixture.lir_probe, walk_block) != null) break;
        const next = terminatorTarget(walk_block) orelse return error.MissingYieldContinuation;
        walk_block = blockAtIndex(fixture.lir_probe, next) orelse return error.MissingYieldContinuationBlock;
        steps += 1;
    }
    const continuation_result = returnedResult(fixture.lir_probe, walk_block) orelse return error.MissingYieldContinuationReturn;
    try std.testing.expect(!continuation_result.is_err);
    try std.testing.expect(countReturns(fixture.lir_probe) == 1);
}

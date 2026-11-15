const std = @import("std");
const cyna = @import("cyna");
const sir = cyna.compiler.sir;

const helpers = @import("../helpers.zig");

test "switch payload shadows an outer local in expression resolution" {
    const source =
        \\union Value { int_value: i32; }
        \\fn main(): i32 {
        \\    var value: i32 = 9;
        \\    const loaded: Value = .int_value(4);
        \\    switch loaded {
        \\        .int_value(value) => { return value; }
        \\    }
        \\    return 0;
        \\}
    ;
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "switch_payload_shadows_outer", source, 4);
}

test "optional struct field assignment accepts its payload value" {
    const source =
        \\struct Reference { slot: usize; }
        \\struct Thing {
        \\    value: ?Reference;
        \\    fn set(self: &Thing, value: Reference): void { self.value = value; }
        \\}
        \\fn main(): i32 {
        \\    var thing = Thing { value: none };
        \\    thing.set(Reference { slot: 7 });
        \\    if thing.value is actual { return actual.slot as i32; }
        \\    return 0;
        \\}
    ;
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "optional_field_assignment", source, 7);
}

test "indexed list value field does not retain an invalid root place" {
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "indexed_list_field_value",
        \\struct Item { index: usize; }
        \\fn read(entries: &List<Item>, index: usize): usize {
        \\    return entries[index].index;
        \\}
    );
}

test "place matrix local value parameter has writable local storage" {
    const source =
        \\struct Item { value: i32; }
        \\
        \\fn overwrite(item: Item): void {
        \\    item.value = 42;
        \\    const field: &i32 = &item.value;
        \\    field = 7;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "place_matrix_value_parameter_writable_storage", source);
}

test "place matrix const global root forms read-only alias" {
    const source =
        \\const answer: i32 = 42;
        \\
        \\fn expose(): &const i32 {
        \\    return &answer;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "place_matrix_const_global_root_alias", source);
}

test "place matrix projected global alias preserves global access" {
    const source =
        \\struct Item { value: i32; }
        \\
        \\const item: Item = Item { value: 42 };
        \\
        \\fn expose(): &const i32 {
        \\    return &item.value;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "place_matrix_projected_global_alias", source);
}

test "place matrix projected global alias keeps its checked declaration root" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Item { value: i32; }
        \\const item: Item = Item { value: 42 };
        \\const other: Item = Item { value: 7 };
        \\fn expose(): &const i32 { return &item.value; }
    ;
    const tokens = try cyna.compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try cyna.compiler.parser.parse(allocator, "global_place_root.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try cyna.compiler.sema.buildSir(allocator, "global_place_root.cy", program);
    defer module.deinit(allocator);

    const projected = module.functions[0].body[0].@"return" orelse return error.TestUnexpectedResult;
    try std.testing.expect(projected.* == .ref_field_expr);
    const global_id = module.globals[0].decl_id orelse return error.TestUnexpectedResult;
    const other_id = module.globals[1].decl_id orelse return error.TestUnexpectedResult;
    const metadata = @constCast(module.expr_metadata);
    for (metadata) |*entry| {
        if (entry.expr != projected) continue;
        try std.testing.expect(entry.metadata.checked_place_root != null);
        try std.testing.expect(entry.metadata.checked_place_root.? == .global);
        try std.testing.expectEqual(global_id, entry.metadata.checked_place_root.?.global);
        const projections = entry.metadata.checked_place_projections orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), projections.len);
        try std.testing.expect(projections[0].step == .field);
        entry.metadata.checked_place_projections = null;
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        entry.metadata.checked_place_projections = projections;
        entry.metadata.checked_place_root = .{ .global = other_id };
        try std.testing.expectError(error.InvalidCheckedPlaceRoot, module.verifyCompilerIdentities());
        entry.metadata.checked_place_root = .{ .global = global_id };
        const mutable_projections = @constCast(projections);
        const saved_name = mutable_projections[0].step.field.name;
        mutable_projections[0].step.field.name = "wrong";
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        mutable_projections[0].step.field.name = saved_name;
        return;
    }
    return error.TestUnexpectedResult;
}

test "place matrix raw dereference alias preserves const capability" {
    const readonly_source =
        \\fn expose(ptr: *const i32): &const i32 {
        \\    unchecked {
        \\        return &(*ptr);
        \\    }
        \\}
    ;
    try helpers.expectSemanticSuccess(std.testing.allocator, "place_matrix_const_raw_deref_alias", readonly_source);

    const amplification_source =
        \\fn expose(ptr: *const i32): &i32 {
        \\    unchecked {
        \\        return &(*ptr);
        \\    }
        \\}
    ;
    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "place_matrix_const_raw_deref_no_amplification",
        amplification_source,
        "cannot use read-only access `&const i32` where writable access `&i32` is required",
    );
}

test "place matrix projected raw alias preserves pointer access" {
    const writable_source =
        \\struct Item { value: i32; }
        \\
        \\fn expose(ptr: *Item): &i32 {
        \\    unchecked {
        \\        return &(*ptr).value;
        \\    }
        \\}
    ;
    try helpers.expectSemanticSuccess(std.testing.allocator, "place_matrix_projected_raw_alias", writable_source);

    const readonly_source =
        \\struct Item { value: i32; }
        \\
        \\fn expose(ptr: *const Item): &const i32 {
        \\    unchecked {
        \\        return &(*ptr).value;
        \\    }
        \\}
    ;
    try helpers.expectSemanticSuccess(std.testing.allocator, "place_matrix_projected_const_raw_alias", readonly_source);

    const amplification_source =
        \\struct Item { value: i32; }
        \\
        \\fn expose(ptr: *const Item): &i32 {
        \\    unchecked {
        \\        return &(*ptr).value;
        \\    }
        \\}
    ;
    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "place_matrix_projected_const_raw_alias_no_amplification",
        amplification_source,
        "cannot use read-only access `&const i32` where writable access `&i32` is required",
    );
}

test "place matrix temporary field cannot form escaping alias" {
    const source =
        \\struct Item { value: i32; }
        \\
        \\fn make(): Item { return Item { value: 42 }; }
        \\
        \\fn expose(): &const i32 {
        \\    return &make().value;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "place_matrix_temporary_field_alias_rejected",
        source,
        "address-of requires an addressable place",
    );
}

test "place matrix union payload alias remains outside current addressable subset" {
    const source =
        \\union Choice {
        \\    value: i32;
        \\    empty;
        \\}
        \\
        \\fn expose(choice: &const Choice): &const i32 {
        \\    return &choice.value;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "place_matrix_union_payload_alias_current_rejection",
        source,
        "field access requires a struct value",
    );
}

test "place matrix compiler identity verifier rejects missing owned place and forged global root" {
    var types = cyna.compiler.semantic_types.TypeInterner.init(std.testing.allocator);
    defer types.deinit();
    const int_type = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const binding_id: cyna.compiler.identity.BindingId = @fromBackingInt(@intCast(41));
    const global_id: cyna.compiler.identity.DeclId = @fromBackingInt(@intCast(42));
    const other_global_id: cyna.compiler.identity.DeclId = @fromBackingInt(@intCast(43));
    var local: sir.Expr = .{ .local = "owner" };
    var global_ref: sir.Expr = .{ .global_ref = .{ .decl_id = global_id, .module_name = "sample", .name = "stored" } };
    var body = [_]sir.Stmt{ .{ .expr = &local }, .{ .expr = &global_ref } };
    const functions = [_]sir.Function{.{
        .module_name = "sample",
        .owner = null,
        .name = "use",
        .params = &.{.{ .name = "owner", .binding_id = binding_id }},
        .body = &body,
    }};
    var globals = [_]sir.Global{
        .{ .decl_id = global_id, .module_name = "sample", .name = "stored", .is_mutable = true, .init = null },
        .{ .decl_id = other_global_id, .module_name = "sample", .name = "other", .is_mutable = true, .init = null },
    };
    const owned_place: sir.ValueSemantics = .{ .category = .place, .ownership = .owned, .cleanup = .scope };
    var entries = [_]sir.ExprMetadataEntry{
        .{ .expr = &local, .metadata = .{ .type_id = int_type, .semantics = owned_place, .checked_place_root = .{ .binding = binding_id } } },
        .{ .expr = &global_ref, .metadata = .{ .type_id = int_type, .semantics = owned_place, .checked_place_root = .{ .global = global_id } } },
    };
    const module: sir.Module = .{
        .canonical_types = types,
        .expr_metadata = &entries,
        .globals = &globals,
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &functions,
    };

    try module.verifyCompilerIdentities();
    entries[0].metadata.checked_place_root = null;
    try std.testing.expectError(error.MissingPlaceIdentity, module.verifyCompilerIdentities());
    entries[0].metadata.checked_place_root = .{ .binding = binding_id };
    entries[1].metadata.checked_place_root = .{ .global = other_global_id };
    try std.testing.expectError(error.InvalidCheckedPlaceRoot, module.verifyCompilerIdentities());
    entries[1].metadata.checked_place_root = .{ .binding = binding_id };
    try std.testing.expectError(error.InvalidCheckedPlaceRoot, module.verifyCompilerIdentities());
    body[1] = .{ .expr = &local };
    globals[0].init = &global_ref;
    try std.testing.expectError(error.InvalidCheckedPlaceRoot, module.verifyCompilerIdentities());
}

test "switch expression capture projections retain checked owner and field identities" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Element { children: [:]i32; }
        \\union Payload { element: Element; text: i32; }
        \\fn inspect(values: &const [:]i32): i32 { return values[0]; }
        \\fn first(payload: &const Payload): i32 {
        \\    const result = switch payload {
        \\        .element(value) => {
        \\            const direct = inspect(&value.children);
        \\            const children = value.children;
        \\            yield direct + inspect(&children);
        \\        }
        \\        .text(value) => value;
        \\    };
        \\    return result;
        \\}
    ;
    const tokens = try cyna.compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try cyna.compiler.parser.parse(allocator, "switch_expression_capture_projection.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try cyna.compiler.sema.buildSir(allocator, "switch_expression_capture_projection.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();

    var parameter_id: ?@TypeOf(module.functions[0].params[0].binding_id.?) = null;
    for (module.functions) |function| {
        if (std.mem.eql(u8, function.name, "first")) parameter_id = function.params[0].binding_id;
    }
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .ref_field_local) continue;
        if (!std.mem.eql(u8, entry.expr.ref_field_local.field, "children")) continue;
        const original_root = entry.metadata.checked_place_root orelse return error.TestUnexpectedResult;
        entry.metadata.checked_place_root = .{ .binding = parameter_id orelse return error.TestUnexpectedResult };
        try std.testing.expectError(error.InvalidCheckedPlaceRoot, module.verifyCompilerIdentities());
        entry.metadata.checked_place_root = original_root;
        const projections = @constCast(entry.metadata.checked_place_projections orelse return error.TestUnexpectedResult);
        const original_name = projections[0].step.field.name;
        projections[0].step.field.name = "wrong";
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        projections[0].step.field.name = original_name;
        try module.verifyCompilerIdentities();
        return;
    }
    return error.TestUnexpectedResult;
}

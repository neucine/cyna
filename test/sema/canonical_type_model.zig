const std = @import("std");
const compiler = @import("cyna").compiler;
const ast = compiler.ast;
const identity = compiler.identity;
const lexer = compiler.lexer;
const semantic_types = compiler.semantic_types;
const sir = compiler.sir;
const sema = compiler.sema;

const SemaContext = sema.SemaContext;
const GlobalBinding = sema.GlobalBinding;
const canonical = sema.canonical;
const declarations = sema.declarations;
const lookup = sema.lookup;
const registeredOrGeneratedDeclId = sema.registeredOrGeneratedDeclId;
const package_manifest = sema.package_manifest;
const protocol_conformance = sema.protocol_conformance;
const value_semantics = sema.value_semantics;
const OwnershipClass = sema.OwnershipClass;
const initCanonicalTestProgram = sema.initCanonicalTestProgram;
const initCanonicalTestTypes = sema.initCanonicalTestTypes;
const deinitCanonicalTestProgram = sema.deinitCanonicalTestProgram;
const deinitCanonicalTestTypes = sema.deinitCanonicalTestTypes;
const isPackedStructType = sema.isPackedStructType;
const localBinding = sema.localBinding;
const makeTypedExpr = sema.makeTypedExpr;
const makeTypedExprWithProvenanceAndValueSemantics = sema.makeTypedExprWithProvenanceAndValueSemantics;
const ownershipClass = sema.ownershipClass;
const ownershipFeatures = sema.ownershipFeatures;
const packedStructBitWidth = sema.packedStructBitWidth;
const parseCanonicalType = sema.parseCanonicalType;
const parseType = sema.parseType;
const parseTypeWithBindings = sema.parseTypeWithBindings;
const parseTypeWithSelf = sema.parseTypeWithSelf;
const registerCanonicalAliasTypes = sema.registerCanonicalAliasTypes;
const typeEqual = sema.typeEqual;
const typeIsThreadTransferable = sema.typeIsThreadTransferable;
const typeMayCarryBorrowedProvenance = sema.typeMayCarryBorrowedProvenance;
const canonicalPrimitiveTypeId = canonical.primitiveType;
const canonicalInferredIntegerTypeId = canonical.inferredIntegerType;
const canonicalIntegerTypeId = canonical.integerType;
const canonicalFloatTypeId = canonical.floatType;
const canonicalOptionalTypeId = canonical.optionalType;
const canonicalResultTypeId = canonical.resultType;
const canonicalSliceTypeId = canonical.sliceType;
const canonicalRefTypeId = canonical.refType;
const canonicalOwnedTypeId = canonical.ownedType;
const canonicalRawTypeId = canonical.rawType;
const canonicalDenseArrayTypeId = canonical.denseArrayType;
const canonicalArrayTypeId = canonical.arrayType;
const canonicalNominalTypeId = canonical.nominalType;
const canonicalTypeKind = canonical.sirType;
const canonicalTypeNode = canonical.typeNode;
const canonicalRefTarget = canonical.refTargetType;
const canonicalOwnedTarget = canonical.ownedTargetType;

test "nominal ownership and packed layout queries use declaration identity" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    context.canonical.types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer {
        context.canonical.types.?.deinit();
        context.canonical.types = null;
    }

    const zero = std.mem.zeroes(lexer.Token);
    var plain_fields = [_]ast.FieldDecl{.{
        .name = "value",
        .type_name = .{ .name = "u8", .args = &.{}, .token = zero },
        .is_pub = true,
        .name_token = zero,
    }};
    var borrowed_fields = [_]ast.FieldDecl{.{
        .name = "value",
        .type_name = .{ .is_slice = true, .name = "u8", .args = &.{}, .token = zero },
        .is_pub = true,
        .name_token = zero,
    }};
    var structs = [_]ast.StructDecl{
        .{
            .module_name = "left",
            .name = "Holder",
            .type_params = &.{},
            .layout = .normal,
            .fields = plain_fields[0..],
            .methods = &.{},
            .is_pub = true,
            .name_token = zero,
        },
        .{
            .module_name = "right",
            .name = "Holder",
            .type_params = &.{},
            .layout = .normal,
            .fields = borrowed_fields[0..],
            .methods = &.{},
            .is_pub = true,
            .name_token = zero,
        },
        .{
            .module_name = "left",
            .name = "Bits",
            .type_params = &.{},
            .layout = .@"packed",
            .fields = plain_fields[0..],
            .methods = &.{},
            .is_pub = true,
            .name_token = zero,
        },
        .{
            .module_name = "right",
            .name = "Bits",
            .type_params = &.{},
            .layout = .normal,
            .fields = plain_fields[0..],
            .methods = &.{},
            .is_pub = true,
            .name_token = zero,
        },
    };
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = structs[0..],
        .functions = &.{},
        .tests = &.{},
    };

    context.declarations.registry = try declarations.registration.build(std.testing.allocator, "identity.cy", program);
    defer {
        context.declarations.registry.?.deinit();
        context.declarations.registry = null;
    }
    const left_holder = try canonicalNominalTypeId(context, .@"struct", try lookup.registeredDeclId(context, "left", null, "Holder", .@"struct"), null);
    const right_holder = try canonicalNominalTypeId(context, .@"struct", try lookup.registeredDeclId(context, "right", null, "Holder", .@"struct"), null);
    const left_bits = try canonicalNominalTypeId(context, .@"struct", try lookup.registeredDeclId(context, "left", null, "Bits", .@"struct"), null);
    const right_bits = try canonicalNominalTypeId(context, .@"struct", try lookup.registeredDeclId(context, "right", null, "Bits", .@"struct"), null);

    try std.testing.expectEqual(OwnershipClass.plain, try ownershipClass(context, "", program, "main", left_holder));
    try std.testing.expectEqual(OwnershipClass.borrowed, try ownershipClass(context, "", program, "main", right_holder));
    try std.testing.expect(!(try typeMayCarryBorrowedProvenance(context, "", program, "main", left_holder)));
    try std.testing.expect(try typeMayCarryBorrowedProvenance(context, "", program, "main", right_holder));
    try std.testing.expect(!(try ownershipFeatures(context, "", program, "main", left_holder)).anyBorrowed());
    try std.testing.expect((try ownershipFeatures(context, "", program, "main", right_holder)).has_borrowed_view);
    try std.testing.expect(try typeIsThreadTransferable(context, "", program, left_holder));
    try std.testing.expect(!(try typeIsThreadTransferable(context, "", program, right_holder)));
    try std.testing.expect(try isPackedStructType(context, program, left_bits));
    try std.testing.expect(!(try isPackedStructType(context, program, right_bits)));
    try std.testing.expectEqual(@as(?u16, 8), try packedStructBitWidth(context, program, left_bits));
    try std.testing.expectEqual(@as(?u16, null), try packedStructBitWidth(context, program, right_bits));
}

test "canonical parsing reuses recursive and nominal type identities" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    context.canonical.types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer {
        context.canonical.types.?.deinit();
        context.canonical.types = null;
    }

    const zero = std.mem.zeroes(lexer.Token);
    var structs = [_]ast.StructDecl{.{
        .module_name = "main",
        .name = "Record",
        .type_params = &.{},
        .layout = .normal,
        .fields = &.{},
        .methods = &.{},
        .is_pub = false,
        .name_token = zero,
    }};
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = structs[0..],
        .functions = &.{},
        .tests = &.{},
    };
    context.declarations.registry = try declarations.registration.build(std.testing.allocator, "canonical-parse.cy", program);
    defer {
        context.declarations.registry.?.deinit();
        context.declarations.registry = null;
    }

    const recursive_name = ast.TypeName{
        .is_optional = true,
        .array_len = 4,
        .name = "i32",
        .args = &.{},
        .token = zero,
    };
    const recursive_a = try parseCanonicalType(context, "canonical-parse.cy", program, "main", recursive_name);
    const recursive_b = try parseCanonicalType(context, "canonical-parse.cy", program, "main", recursive_name);
    try std.testing.expectEqual(recursive_a, recursive_b);
    const optional_node = try context.canonical.types.?.get(recursive_a);
    try std.testing.expect(optional_node.* == .optional);
    const array_node = try context.canonical.types.?.get(optional_node.optional);
    try std.testing.expectEqual(@as(usize, 4), array_node.array.len);

    const nominal_name = ast.TypeName{ .name = "Record", .args = &.{}, .token = zero };
    const nominal_a = try parseCanonicalType(context, "canonical-parse.cy", program, "main", nominal_name);
    const nominal_b = try parseCanonicalType(context, "canonical-parse.cy", program, "main", nominal_name);
    try std.testing.expectEqual(nominal_a, nominal_b);
    const nominal_node = try context.canonical.types.?.get(nominal_a);
    try std.testing.expectEqual(semantic_types.NominalKind.@"struct", nominal_node.nominal.kind);
    try std.testing.expectEqual(try lookup.registeredDeclId(context, "main", null, "Record", .@"struct"), nominal_node.nominal.decl_id);
}

test "post-registry legacy parse wrappers always populate canonical types" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    context.canonical.types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer {
        context.canonical.types.?.deinit();
        context.canonical.types = null;
    }

    const zero = std.mem.zeroes(lexer.Token);
    var structs = [_]ast.StructDecl{.{
        .module_name = "main",
        .name = "Record",
        .type_params = &.{},
        .layout = .normal,
        .fields = &.{},
        .methods = &.{},
        .is_pub = false,
        .name_token = zero,
    }};
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = structs[0..],
        .functions = &.{},
        .tests = &.{},
    };
    context.declarations.registry = try declarations.registration.build(std.testing.allocator, "canonical-wrapper.cy", program);
    defer {
        context.declarations.registry.?.deinit();
        context.declarations.registry = null;
    }

    const self_type = try canonicalNominalTypeId(context, .@"struct", try lookup.registeredDeclId(context, "main", null, "Record", .@"struct"), null);
    const recursive_name = ast.TypeName{
        .is_optional = true,
        .array_len = 3,
        .name = "Record",
        .args = &.{},
        .token = zero,
    };
    const recursive = try parseType(context, "canonical-wrapper.cy", program, "main", recursive_name);
    try std.testing.expectEqual(
        try canonicalOptionalTypeId(context, try canonicalArrayTypeId(context, 3, self_type)),
        recursive,
    );
    const count_after_parse = context.canonical.types.?.count();
    try std.testing.expectEqual(count_after_parse, context.canonical.types.?.count());

    const generic_params = [_]ast.GenericParam{.{
        .name = "T",
        .constraint = null,
        .name_token = zero,
    }};
    const generic_args = [_]semantic_types.GenericArgument{.{ .type = try canonicalInferredIntegerTypeId(context) }};
    const substituted = try parseTypeWithBindings(
        context,
        "canonical-wrapper.cy",
        program,
        "main",
        .{ .name = "T", .args = &.{}, .token = zero },
        null,
        &generic_params,
        &generic_args,
    );
    try std.testing.expectEqual(generic_args[0].type, substituted);
    const count_after_substitution = context.canonical.types.?.count();
    try std.testing.expectEqual(count_after_substitution, context.canonical.types.?.count());

    const resolved_self = try parseTypeWithSelf(
        context,
        "canonical-wrapper.cy",
        program,
        "main",
        .{ .name = "Self", .args = &.{}, .token = zero },
        self_type,
    );
    try std.testing.expectEqual(self_type, resolved_self);
    const count_after_self = context.canonical.types.?.count();
    try std.testing.expectEqual(count_after_self, context.canonical.types.?.count());
}

test "canonical alias table preserves transparent and distinct identity semantics" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    context.canonical.types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer {
        context.canonical.aliases.deinit(std.testing.allocator);
        context.canonical.aliases = .empty;
        context.canonical.types.?.deinit();
        context.canonical.types = null;
    }

    const zero = std.mem.zeroes(lexer.Token);
    var aliases = [_]ast.TypeAlias{
        .{
            .module_name = "main",
            .name = "Word",
            .type_params = &.{},
            .target = .{ .name = "i32", .args = &.{}, .token = zero },
            .is_pub = false,
            .is_distinct = false,
            .name_token = zero,
        },
        .{
            .module_name = "main",
            .name = "Count",
            .type_params = &.{},
            .target = .{ .name = "Word", .args = &.{}, .token = zero },
            .is_pub = false,
            .is_distinct = false,
            .name_token = zero,
        },
        .{
            .module_name = "left",
            .name = "Id",
            .type_params = &.{},
            .target = .{ .name = "i32", .args = &.{}, .token = zero },
            .is_pub = true,
            .is_distinct = true,
            .name_token = zero,
        },
        .{
            .module_name = "right",
            .name = "Id",
            .type_params = &.{},
            .target = .{ .name = "i32", .args = &.{}, .token = zero },
            .is_pub = true,
            .is_distinct = true,
            .name_token = zero,
        },
    };
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = aliases[0..],
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = &.{},
        .functions = &.{},
        .tests = &.{},
    };
    context.declarations.registry = try declarations.registration.build(std.testing.allocator, "canonical-alias.cy", program);
    defer {
        context.declarations.registry.?.deinit();
        context.declarations.registry = null;
    }

    try registerCanonicalAliasTypes(context, "canonical-alias.cy", program);

    const word_decl = try lookup.registeredDeclId(context, "main", null, "Word", .type_alias);
    const count_decl = try lookup.registeredDeclId(context, "main", null, "Count", .type_alias);
    const left_decl = try lookup.registeredDeclId(context, "left", null, "Id", .type_alias);
    const right_decl = try lookup.registeredDeclId(context, "right", null, "Id", .type_alias);
    const i32_id = try canonicalIntegerTypeId(context, "i32");
    const word_id = canonical.aliasType(context, word_decl).?;
    const count_id = canonical.aliasType(context, count_decl).?;
    const left_id = canonical.aliasType(context, left_decl).?;
    const right_id = canonical.aliasType(context, right_decl).?;

    try std.testing.expectEqual(i32_id, word_id);
    try std.testing.expectEqual(word_id, count_id);
    try std.testing.expect(left_id != i32_id);
    try std.testing.expect(right_id != i32_id);
    try std.testing.expect(left_id != right_id);

    const left_node = try context.canonical.types.?.get(left_id);
    const right_node = try context.canonical.types.?.get(right_id);
    try std.testing.expectEqual(semantic_types.NominalKind.type_alias, left_node.nominal.kind);
    try std.testing.expectEqual(left_decl, left_node.nominal.decl_id);
    try std.testing.expectEqual(right_decl, right_node.nominal.decl_id);
    try std.testing.expectEqual(i32_id, left_node.nominal.underlying.?);
    try std.testing.expectEqual(i32_id, right_node.nominal.underlying.?);
}

test "canonical generic substitution preserves type and const arguments" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    context.protocol_conformances = protocol_conformance.Registry.init(std.testing.allocator);
    defer {
        context.protocol_conformances.?.deinit();
        context.protocol_conformances = null;
    }
    context.canonical.types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer {
        context.canonical.deinitGenericAliases(context.allocator);
        for (context.generic.instantiated_structs.items) |decl| decl.deinit(std.testing.allocator);
        context.generic.instantiated_structs.deinit(std.testing.allocator);
        for (context.output.generated_strings.items) |value| std.testing.allocator.free(value);
        context.output.generated_strings.deinit(std.testing.allocator);
        context.canonical.types.?.deinit();
        context.canonical.types = null;
    }

    const zero = std.mem.zeroes(lexer.Token);
    var alias_params = [_]ast.GenericParam{
        .{ .name = "T", .constraint = null, .name_token = zero },
        .{ .name = "N", .constraint = null, .name_token = zero, .is_const_value = true },
    };
    var struct_params = [_]ast.GenericParam{
        .{ .name = "T", .constraint = null, .name_token = zero },
    };
    var aliases = [_]ast.TypeAlias{.{
        .module_name = "main",
        .name = "Buffer",
        .type_params = alias_params[0..],
        .target = .{
            .array_len_name = "N",
            .name = "T",
            .args = &.{},
            .token = zero,
        },
        .is_pub = false,
        .is_distinct = false,
        .name_token = zero,
    }};
    var structs = [_]ast.StructDecl{.{
        .module_name = "main",
        .name = "Box",
        .type_params = struct_params[0..],
        .layout = .normal,
        .fields = &.{},
        .methods = &.{},
        .is_pub = false,
        .name_token = zero,
    }};
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = aliases[0..],
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = structs[0..],
        .functions = &.{},
        .tests = &.{},
    };
    context.declarations.registry = try declarations.registration.build(std.testing.allocator, "canonical-generics.cy", program);
    defer {
        context.declarations.registry.?.deinit();
        context.declarations.registry = null;
    }

    var buffer_args_4 = [_]ast.TypeName{
        .{ .name = "i32", .args = &.{}, .token = zero },
        .{ .is_const_value_arg = true, .const_value = 4, .name = "4", .args = &.{}, .token = zero },
    };
    var buffer_args_5 = [_]ast.TypeName{
        .{ .name = "i32", .args = &.{}, .token = zero },
        .{ .is_const_value_arg = true, .const_value = 5, .name = "5", .args = &.{}, .token = zero },
    };
    const buffer_4_name = ast.TypeName{ .name = "Buffer", .args = buffer_args_4[0..], .token = zero };
    const buffer_5_name = ast.TypeName{ .name = "Buffer", .args = buffer_args_5[0..], .token = zero };
    const buffer_4_a = try parseCanonicalType(context, "canonical-generics.cy", program, "main", buffer_4_name);
    const buffer_4_b = try parseCanonicalType(context, "canonical-generics.cy", program, "main", buffer_4_name);
    const buffer_5 = try parseCanonicalType(context, "canonical-generics.cy", program, "main", buffer_5_name);
    try std.testing.expectEqual(buffer_4_a, buffer_4_b);
    try std.testing.expect(buffer_4_a != buffer_5);

    const alias_decl = try lookup.registeredDeclId(context, "main", null, "Buffer", .type_alias);
    const i32_id = try canonicalIntegerTypeId(context, "i32");
    const canonical_args = [_]semantic_types.GenericArgument{
        .{ .type = i32_id },
        .{ .const_usize = 4 },
    };
    try std.testing.expectEqual(buffer_4_a, canonical.genericAliasType(context, alias_decl, &canonical_args).?);

    var box_i32_args = [_]ast.TypeName{.{ .name = "i32", .args = &.{}, .token = zero }};
    var box_u32_args = [_]ast.TypeName{.{ .name = "u32", .args = &.{}, .token = zero }};
    const box_i32_name = ast.TypeName{ .name = "Box", .args = box_i32_args[0..], .token = zero };
    const box_u32_name = ast.TypeName{ .name = "Box", .args = box_u32_args[0..], .token = zero };
    const box_i32_a = try parseCanonicalType(context, "canonical-generics.cy", program, "main", box_i32_name);
    const box_i32_b = try parseCanonicalType(context, "canonical-generics.cy", program, "main", box_i32_name);
    const box_u32 = try parseCanonicalType(context, "canonical-generics.cy", program, "main", box_u32_name);
    try std.testing.expectEqual(box_i32_a, box_i32_b);
    try std.testing.expect(box_i32_a != box_u32);
    const box_node = try context.canonical.types.?.get(box_i32_a);
    try std.testing.expect(box_node.* == .generic_instance);
    try std.testing.expectEqual(try lookup.registeredDeclId(context, "main", null, "Box", .@"struct"), box_node.generic_instance.base_decl_id);
    try std.testing.expectEqual(try registeredOrGeneratedDeclId(context, "main", null, "Box<i32>", .@"struct"), box_node.generic_instance.decl_id.?);
    try std.testing.expectEqual(@as(usize, 1), box_node.generic_instance.args.len);
    try std.testing.expectEqual(i32_id, box_node.generic_instance.args[0].type);

    const inferred_int_a = try canonicalInferredIntegerTypeId(context);
    const inferred_int_b = try canonicalInferredIntegerTypeId(context);
    const inferred_float = try canonicalFloatTypeId(context, null);
    try std.testing.expectEqual(inferred_int_a, inferred_int_b);
    try std.testing.expect(inferred_int_a != i32_id);
    try std.testing.expect(inferred_int_a != inferred_float);
}

test "typed expr constructors default to plain value semantics" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    initCanonicalTestTypes(context);
    defer deinitCanonicalTestTypes(context);
    var expr: sir.Expr = .{ .bool = true };
    const typed = try makeTypedExpr(context, &expr, try canonicalPrimitiveTypeId(context, .bool));
    try std.testing.expectEqual(value_semantics.ValueSemantics.plainValue(), typed.value_semantics);
}

test "typed expr semantics can mark borrowed projection" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    initCanonicalTestTypes(context);
    defer deinitCanonicalTestTypes(context);
    var expr: sir.Expr = .{ .bool = true };
    const typed = try makeTypedExprWithProvenanceAndValueSemantics(context, &expr, try canonicalPrimitiveTypeId(context, .bool), .none(), .borrowedProjection());
    try std.testing.expectEqual(value_semantics.ValueSemantics.borrowedProjection(), typed.value_semantics);
}

test "semantic bindings and strict equality retain canonical type identity" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    context.canonical.types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer {
        context.canonical.types.?.deinit();
        context.canonical.types = null;
    }

    const empty_program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = &.{},
        .functions = &.{},
        .tests = &.{},
    };
    context.declarations.registry = try declarations.registration.build(std.testing.allocator, "canonical-bindings.cy", empty_program);
    defer {
        context.declarations.registry.?.deinit();
        context.declarations.registry = null;
    }

    const binding_type = try canonicalOptionalTypeId(context, try canonicalIntegerTypeId(context, "i32"));
    const local = try localBinding(context, "value", binding_type, false, true);
    try std.testing.expectEqual(local.type_id, try local.canonicalTypeId(context));

    var expr: sir.Expr = .{ .bool = true };
    const typed = try makeTypedExpr(context, &expr, binding_type);
    try std.testing.expectEqual(binding_type, typed.type_id);
    try std.testing.expectEqual(local.type_id, try typed.canonicalTypeId(context));

    const global = GlobalBinding{
        .id = @fromBackingInt(@intCast(1)),
        .name = "value",
        .module_name = "main",
        .is_pub = false,
        .is_mutable = false,
        .type_id = local.type_id,
    };
    try std.testing.expectEqual(local.type_id, try global.canonicalTypeId(context));

    try std.testing.expect(typeEqual(context, try canonicalIntegerTypeId(context, "i32"), try canonicalIntegerTypeId(context, "i32")));
    try std.testing.expect(!typeEqual(context, try canonicalIntegerTypeId(context, "i32"), try canonicalIntegerTypeId(context, "c_int")));
    try std.testing.expect(!typeEqual(context, try canonicalFloatTypeId(context, "f32"), try canonicalFloatTypeId(context, "c_float")));
    const same_decl: identity.DeclId = @fromBackingInt(@intCast(20));
    const other_decl: identity.DeclId = @fromBackingInt(@intCast(21));
    try std.testing.expect(typeEqual(
        context,
        try canonicalNominalTypeId(context, .@"struct", same_decl, null),
        try canonicalNominalTypeId(context, .@"struct", same_decl, null),
    ));
    try std.testing.expect(!typeEqual(
        context,
        try canonicalNominalTypeId(context, .@"struct", same_decl, null),
        try canonicalNominalTypeId(context, .@"struct", other_decl, null),
    ));
}

test "pointer and result accessors preserve nested aggregate shape" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    initCanonicalTestTypes(context);
    defer deinitCanonicalTestTypes(context);
    const u8_type = try canonicalIntegerTypeId(context, "u8");
    const slice = try canonicalSliceTypeId(context, u8_type, false);
    const dense_array = try canonicalDenseArrayTypeId(context, slice);
    const ref_target = canonicalRefTarget(context, try canonicalRefTypeId(context, dense_array));
    try std.testing.expect(canonicalTypeKind(context, ref_target) == .dense_array);
    try std.testing.expectEqual(slice, canonicalTypeNode(context, ref_target).dense_array);

    const value_result = try canonicalResultTypeId(context, dense_array, try canonicalPrimitiveTypeId(context, .bool));
    const ok_type = canonicalTypeNode(context, value_result).result.ok;
    try std.testing.expectEqual(dense_array, ok_type);

    const owned_target = canonicalOwnedTarget(context, try canonicalOwnedTypeId(context, dense_array));
    try std.testing.expectEqual(dense_array, owned_target);

    const raw_type = try canonicalRawTypeId(context, dense_array, true);
    const raw_node = canonicalTypeNode(context, raw_type).raw;
    try std.testing.expectEqual(dense_array, raw_node.target);
    try std.testing.expect(raw_node.is_volatile);
}

test "type equality recurses through nested aggregate payloads" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    initCanonicalTestTypes(context);
    defer deinitCanonicalTestTypes(context);
    const byte_type = try canonicalIntegerTypeId(context, "u8");
    const error_type = try canonicalPrimitiveTypeId(context, .bool);
    const same_lhs = try canonicalResultTypeId(context, try canonicalSliceTypeId(context, byte_type, false), error_type);
    const same_rhs = try canonicalResultTypeId(context, try canonicalSliceTypeId(context, byte_type, false), error_type);
    try std.testing.expect(typeEqual(context, same_lhs, same_rhs));

    const const_slice = try canonicalSliceTypeId(context, byte_type, true);
    const mutable_slice = try canonicalSliceTypeId(context, byte_type, false);
    try std.testing.expect(!typeEqual(context, const_slice, mutable_slice));
    try std.testing.expect(!typeEqual(
        context,
        try canonicalResultTypeId(context, const_slice, error_type),
        try canonicalResultTypeId(context, mutable_slice, error_type),
    ));
    try std.testing.expect(!typeEqual(
        context,
        try canonicalOptionalTypeId(context, try canonicalRawTypeId(context, try canonicalInferredIntegerTypeId(context), true)),
        try canonicalOptionalTypeId(context, try canonicalRawTypeId(context, try canonicalInferredIntegerTypeId(context), false)),
    ));
}

test "type display formats nested aggregate shape recursively" {
    const allocator = std.testing.allocator;
    var sema_context = SemaContext.init(allocator, .{});
    const context = &sema_context;
    defer {
        for (context.output.generated_strings.items) |value| allocator.free(value);
        context.output.generated_strings.deinit(allocator);
    }
    initCanonicalTestTypes(context);
    defer deinitCanonicalTestTypes(context);
    context.declarations.registry = identity.Registry.init(allocator);
    defer {
        context.declarations.registry.?.deinit();
        context.declarations.registry = null;
    }
    const source_id = try context.declarations.registry.?.registerSource("display.cy");
    const module_id = try context.declarations.registry.?.registerModule(source_id, "");
    const status_id = try context.declarations.registry.?.registerDecl(module_id, null, "Status", .@"enum");
    const byte_slice = try canonicalSliceTypeId(context, try canonicalIntegerTypeId(context, "u8"), false);
    const ty = try canonicalResultTypeId(
        context,
        try canonicalDenseArrayTypeId(context, try canonicalOptionalTypeId(context, byte_slice)),
        try canonicalNominalTypeId(context, .@"enum", status_id, null),
    );
    const rendered = try canonical.formatType(context, ty);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("[:]?[]u8!Status", rendered);
}

test "capitalized List Map and Set resolve through prelude generic structs" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    const saved_generated_strings = context.output.generated_strings;
    const saved_instantiated_structs = context.generic.instantiated_structs;
    const saved_instantiated_functions = context.generic.instantiated_functions;
    const saved_current_generic_params = context.function_state.current_generic_params;
    const saved_current_generic_args = context.function_state.current_generic_args;
    context.output.generated_strings = .empty;
    context.generic.instantiated_structs = .empty;
    context.generic.instantiated_functions = .empty;
    context.function_state.current_generic_params = &.{};
    context.function_state.current_generic_args = &.{};
    defer {
        for (context.output.generated_strings.items) |value| std.testing.allocator.free(value);
        context.output.generated_strings.deinit(std.testing.allocator);
        for (context.generic.instantiated_structs.items) |decl| decl.deinit(std.testing.allocator);
        context.generic.instantiated_structs.deinit(std.testing.allocator);
        for (context.generic.instantiated_functions.items) |function| function.deinit(std.testing.allocator);
        context.generic.instantiated_functions.deinit(std.testing.allocator);
        context.output.generated_strings = saved_generated_strings;
        context.generic.instantiated_structs = saved_instantiated_structs;
        context.generic.instantiated_functions = saved_instantiated_functions;
        context.function_state.current_generic_params = saved_current_generic_params;
        context.function_state.current_generic_args = saved_current_generic_args;
    }

    const zero = std.mem.zeroes(lexer.Token);
    var map_params = [_]ast.GenericParam{
        .{ .name = "K", .constraint = null, .name_token = zero },
        .{ .name = "V", .constraint = null, .name_token = zero },
    };
    var set_params = [_]ast.GenericParam{
        .{ .name = "T", .constraint = null, .name_token = zero },
    };
    var list_params = [_]ast.GenericParam{
        .{ .name = "T", .constraint = null, .name_token = zero },
    };
    var structs = [_]ast.StructDecl{
        .{
            .module_name = package_manifest.prelude_module_name,
            .name = "List",
            .type_params = list_params[0..],
            .layout = .normal,
            .fields = &.{},
            .methods = &.{},
            .is_pub = true,
            .name_token = zero,
        },
        .{
            .module_name = package_manifest.prelude_module_name,
            .name = "Map",
            .type_params = map_params[0..],
            .layout = .normal,
            .fields = &.{},
            .methods = &.{},
            .is_pub = true,
            .name_token = zero,
        },
        .{
            .module_name = package_manifest.prelude_module_name,
            .name = "Set",
            .type_params = set_params[0..],
            .layout = .normal,
            .fields = &.{},
            .methods = &.{},
            .is_pub = true,
            .name_token = zero,
        },
    };
    var map_args = [_]ast.TypeName{
        .{ .array_len = null, .name = "string", .args = &.{}, .token = zero },
        .{ .array_len = null, .name = "i32", .args = &.{}, .token = zero },
    };
    var set_args = [_]ast.TypeName{
        .{ .array_len = null, .name = "string", .args = &.{}, .token = zero },
    };
    var list_args = [_]ast.TypeName{
        .{ .array_len = null, .name = "string", .args = &.{}, .token = zero },
    };
    const program = ast.Program{
        .source = "",
        .tokens = &.{},
        .imports = &.{},
        .module_infos = &.{},
        .globals = &.{},
        .asm_consts = &.{},
        .aliases = &.{},
        .enums = &.{},
        .unions = &.{},
        .protocols = &.{},
        .impls = &.{},
        .structs = structs[0..],
        .functions = &.{},
        .tests = &.{},
    };

    try initCanonicalTestProgram(context, "canonical-prelude.cy", program);
    defer deinitCanonicalTestProgram(context);
    const list_ty = try parseType(context, "", program, "", .{
        .array_len = null,
        .name = "List",
        .args = list_args[0..],
        .token = zero,
    });
    try std.testing.expect(canonicalTypeKind(context, list_ty) == .@"struct");
    try std.testing.expect(std.mem.startsWith(u8, lookup.canonicalNominalDeclName(context, program, list_ty).?, "List<"));

    const map_ty = try parseType(context, "", program, "", .{
        .array_len = null,
        .name = "Map",
        .args = map_args[0..],
        .token = zero,
    });
    try std.testing.expect(canonicalTypeKind(context, map_ty) == .@"struct");
    try std.testing.expect(std.mem.startsWith(u8, lookup.canonicalNominalDeclName(context, program, map_ty).?, "Map<"));

    const set_ty = try parseType(context, "", program, "", .{
        .array_len = null,
        .name = "Set",
        .args = set_args[0..],
        .token = zero,
    });
    try std.testing.expect(canonicalTypeKind(context, set_ty) == .@"struct");
    try std.testing.expect(std.mem.startsWith(u8, lookup.canonicalNominalDeclName(context, program, set_ty).?, "Set<"));
}

const std = @import("std");
const compiler = @import("cyna").compiler;
const effects = compiler.effect_records;
const sir = compiler.sir;

fn place(id: u64, non_owning: bool) effects.Subject {
    return .{ .place = .{
        .root = .{ .binding = @fromBackingInt(@intCast(id)) },
        .projections = null,
        .non_owning = non_owning,
    } };
}

test "container clear settles only slots of its evaluated receiver" {
    var first: sir.Expr = .{ .local = "first" };
    var first_again: sir.Expr = .{ .local = "first" };
    var second: sir.Expr = .{ .local = "second" };
    const first_place: sir.CheckedPlacePath = .{ .root = .{ .binding = @fromBackingInt(@intCast(3)) }, .projections = null, .non_owning = false };
    const first_slot: effects.Subject = .{ .container_slot = .{
        .object = &first,
        .place = first_place,
        .item_type_id = @fromBackingInt(@intCast(1)),
        .position = .{ .indexed = .{ .fixed = 0 } },
    } };
    const second_slot: effects.Subject = .{ .container_slot = .{
        .object = &second,
        .item_type_id = @fromBackingInt(@intCast(1)),
        .position = .append,
    } };
    var state = effects.State{ .allocator = std.testing.allocator };
    defer state.deinit();
    try state.apply(.{ .effect = .{ .create = .{ .obligation_id = 1, .destination = first_slot } } }, .normal);
    try state.apply(.{ .effect = .{ .create = .{ .obligation_id = 2, .destination = second_slot } } }, .normal);
    try state.apply(.{ .effect = .{ .clear = .{ .container_slot = .{
        .object = &first_again,
        .place = first_place,
        .item_type_id = @fromBackingInt(@intCast(1)),
        .position = .all,
    } } } }, .normal);
    try std.testing.expectError(error.AlreadySettled, state.apply(.{ .effect = .{ .settle = .{
        .source = first_slot,
        .terminal_declaration_id = @fromBackingInt(@intCast(7)),
    } } }, .normal));
    try state.apply(.{ .effect = .{ .settle = .{
        .source = second_slot,
        .terminal_declaration_id = @fromBackingInt(@intCast(7)),
    } } }, .normal);
    try std.testing.expectError(error.InvalidEffectContract, (effects.Record{ .effect = .{
        .clear = first_slot,
    } }).validate());
}

test "explicit leak detaches one checked owner without settling another" {
    const escaping = place(1, false);
    const retained = place(2, false);
    var state = effects.State{ .allocator = std.testing.allocator };
    defer state.deinit();
    try state.apply(.{ .effect = .{ .create = .{ .obligation_id = 1, .destination = escaping } } }, .normal);
    try state.apply(.{ .effect = .{ .create = .{ .obligation_id = 2, .destination = retained } } }, .normal);
    try state.apply(.{ .effect = .{ .leak = escaping } }, .normal);
    try std.testing.expectEqual(@as(?u32, null), state.liveAt(escaping));
    try std.testing.expectEqual(@as(?u32, 2), state.liveAt(retained));
    try std.testing.expectError(error.AlreadySettled, state.apply(.{ .effect = .{ .leak = escaping } }, .normal));
    try std.testing.expectError(error.InvalidEffectContract, (effects.Record{ .effect = .{
        .leak = place(1, true),
    } }).validate());
}

test "checked effect contracts preserve whole-value ownership and reject borrowed transfers" {
    const source = place(1, false);
    const destination = place(2, false);
    try (effects.Record{ .effect = .{ .move = .{ .source = source, .destination = destination } } }).validate();
    try (effects.Record{ .effect = .{ .borrow = place(1, true) } }).validate();
    try (effects.Record{ .effect = .{ .take = .{ .source = source, .destination = destination } } }).validate();
    try (effects.Record{ .effect = .{ .settle = .{ .source = source, .terminal_declaration_id = @fromBackingInt(@intCast(30)) } } }).validate();
    try std.testing.expectError(error.InvalidEffectContract, (effects.Record{
        .effect = .{ .move = .{ .source = place(1, true), .destination = destination } },
    }).validate());
    try std.testing.expectError(error.InvalidEffectContract, (effects.Record{
        .effect = .{ .move = .{ .source = source, .destination = source } },
    }).validate());
    const projection = [_]sir.CheckedPlaceProjection{.{
        .step = .{ .field = .{ .owner_decl_id = @fromBackingInt(@intCast(9)), .name = "item" } },
        .result_type_id = @fromBackingInt(@intCast(4)),
    }};
    const projected: effects.Subject = .{ .place = .{
        .root = .{ .binding = @fromBackingInt(@intCast(1)) },
        .projections = &projection,
        .non_owning = false,
    } };
    try std.testing.expectError(error.InvalidEffectContract, (effects.Record{
        .effect = .{ .move = .{ .source = projected, .destination = destination } },
    }).validate());
    try (effects.Record{ .effect = .{ .take = .{ .source = projected, .destination = destination } } }).validate();
}

test "owner materialization does not invent a settlement obligation" {
    const destination: effects.Subject = .{ .temporary = @fromBackingInt(@intCast(12)) };
    const record: effects.Record = .{ .effect = .{ .materialize = destination } };
    try record.validate();
    var state = effects.State{ .allocator = std.testing.allocator };
    defer state.deinit();
    try state.apply(record, .normal);
    try std.testing.expect(state.liveAt(destination) == null);
    try std.testing.expectError(error.InvalidEffectContract, (effects.Record{
        .effect = .{ .materialize = place(1, true) },
    }).validate());
}

test "checked call contracts bind arguments and result edges to the resolved use" {
    const use_id: u32 = 7;
    const initializer: compiler.identity.DeclId = @fromBackingInt(@intCast(20));
    const finish: compiler.identity.DeclId = @fromBackingInt(@intCast(21));
    const cancel: compiler.identity.DeclId = @fromBackingInt(@intCast(22));
    const authority: effects.CallContract.TrustedAuthority = .{
        .initializer = initializer,
        .terminal_primary = finish,
        .terminal_secondary = cancel,
    };
    var argument_expr: sir.Expr = .{ .local = "owner" };
    const args = [_]sir.CallArg{.{ .value = &argument_expr }};
    var call: sir.Call = .{
        .decl_id = initializer,
        .checked_method_use = .{
            .use_id = use_id,
            .source_declaration_id = @fromBackingInt(@intCast(100)),
            .source_offset = 1,
            .callee_declaration_id = initializer,
            .result_type_id = @fromBackingInt(@intCast(4)),
        },
        .module_name = "std.thread",
        .owner = "TaskGroup",
        .callee = "init",
        .args = &args,
    };
    const source = place(1, false);
    const formal = place(2, false);
    const metadata = [_]sir.ExprMetadataEntry{.{ .expr = &argument_expr, .metadata = .{
        .type_id = @fromBackingInt(@intCast(3)),
        .semantics = .plainValue(),
        .checked_place_root = .{ .binding = @fromBackingInt(@intCast(1)) },
    } }};
    const callee: sir.Function = .{ .decl_id = initializer, .module_name = "std.thread", .owner = "TaskGroup", .name = "init", .params = &.{.{ .name = "owner", .binding_id = @fromBackingInt(@intCast(2)) }}, .body = &.{} };
    const arguments = [_]effects.Record{.{ .effect = .{ .call_argument = .{
        .use_id = use_id,
        .callee_declaration_id = initializer,
        .index = 0,
        .source = source,
        .destination = formal,
        .mode = .move,
    } } }};
    const results = [_]effects.Record{.{
        .edge = .{ .success = use_id },
        .effect = .{ .create = .{ .obligation_id = 1, .destination = .{ .temporary = @fromBackingInt(@intCast(5)) } } },
    }};
    var contract: effects.CallContract = .{
        .use_id = use_id,
        .callee_declaration_id = initializer,
        .result_type_id = @fromBackingInt(@intCast(4)),
        .trust = .trusted_initializer,
        .arguments = &arguments,
        .results = &results,
    };
    try contract.validate(call, &metadata, callee, authority);
    var state = effects.State{ .allocator = std.testing.allocator };
    defer state.deinit();
    try state.apply(.{ .effect = .{ .create = .{ .obligation_id = 11, .destination = source } } }, .normal);
    try state.applyCall(contract, call, &metadata, callee, authority, .{ .failure = use_id });
    try std.testing.expectEqual(@as(?u32, null), state.liveAt(source));
    try std.testing.expectEqual(@as(?u32, 11), state.liveAt(formal));
    try std.testing.expectEqual(@as(usize, 1), state.obligations.items.len);
    try state.applyCall(.{
        .use_id = use_id,
        .callee_declaration_id = initializer,
        .result_type_id = @fromBackingInt(@intCast(4)),
        .trust = .trusted_initializer,
        .arguments = &.{},
        .results = &results,
    }, call, &metadata, callee, authority, .{ .success = use_id });
    try std.testing.expectEqual(@as(?u32, 1), state.liveAt(.{ .temporary = @fromBackingInt(@intCast(5)) }));
    const failure_create = [_]effects.Record{.{
        .edge = .{ .failure = use_id },
        .effect = .{ .create = .{ .obligation_id = 2, .destination = .{ .temporary = @fromBackingInt(@intCast(6)) } } },
    }};
    contract.results = &failure_create;
    try std.testing.expectError(error.InvalidEffectContract, contract.validate(call, &metadata, callee, authority));
    contract.results = &results;
    try std.testing.expectError(error.InvalidEffectContract, contract.validate(call, &metadata, callee, null));
    contract.trust = .ordinary;
    try std.testing.expectError(error.InvalidEffectContract, contract.validate(call, &metadata, callee, authority));
    contract.trust = .trusted_initializer;
    contract.use_id = use_id + 1;
    try std.testing.expectError(error.InvalidEffectContract, contract.validate(call, &metadata, callee, authority));
    contract.use_id = use_id;
    contract.result_type_id = @fromBackingInt(@intCast(99));
    try std.testing.expectError(error.InvalidEffectContract, contract.validate(call, &metadata, callee, authority));
    contract.result_type_id = @fromBackingInt(@intCast(4));
    call.decl_id = finish;
    try std.testing.expectError(error.InvalidEffectContract, contract.validate(call, &metadata, callee, authority));
}

test "checked terminal effects settle once after argument handoff" {
    const finish: compiler.identity.DeclId = @fromBackingInt(@intCast(21));
    const source = place(1, false);
    const formal = place(2, false);
    var receiver: sir.Expr = .{ .local = "group" };
    const args = [_]sir.CallArg{.{ .value = &receiver }};
    const call: sir.Call = .{
        .decl_id = finish,
        .checked_method_use = .{
            .use_id = 3,
            .source_declaration_id = @fromBackingInt(@intCast(100)),
            .source_offset = 10,
            .callee_declaration_id = finish,
            .result_type_id = @fromBackingInt(@intCast(5)),
        },
        .module_name = "std.thread",
        .owner = "TaskGroup",
        .callee = "finish",
        .args = &args,
    };
    const arguments = [_]effects.Record{.{ .effect = .{ .call_argument = .{
        .use_id = 3,
        .callee_declaration_id = finish,
        .index = 0,
        .source = source,
        .destination = formal,
        .mode = .move,
    } } }};
    const metadata = [_]sir.ExprMetadataEntry{.{ .expr = &receiver, .metadata = .{
        .type_id = @fromBackingInt(@intCast(3)),
        .semantics = .plainValue(),
        .checked_place_root = .{ .binding = @fromBackingInt(@intCast(1)) },
    } }};
    const callee: sir.Function = .{ .decl_id = finish, .module_name = "std.thread", .owner = "TaskGroup", .name = "finish", .params = &.{.{ .name = "self", .binding_id = @fromBackingInt(@intCast(2)) }}, .body = &.{} };
    const terminal = [_]effects.Record{.{ .effect = .{ .settle = .{
        .source = formal,
        .terminal_declaration_id = finish,
    } } }};
    const authority: effects.CallContract.TrustedAuthority = .{
        .initializer = @fromBackingInt(@intCast(20)),
        .terminal_primary = finish,
        .terminal_secondary = @fromBackingInt(@intCast(22)),
    };
    const contract: effects.CallContract = .{
        .use_id = 3,
        .callee_declaration_id = finish,
        .result_type_id = @fromBackingInt(@intCast(5)),
        .trust = .trusted_terminal,
        .arguments = &arguments,
        .body_effects = &terminal,
        .results = &.{},
    };
    var state = effects.State{ .allocator = std.testing.allocator };
    defer state.deinit();
    try state.apply(.{ .effect = .{ .create = .{ .obligation_id = 1, .destination = source } } }, .normal);
    try state.applyCall(contract, call, &metadata, callee, authority, .normal);
    try std.testing.expectEqual(@as(?u32, null), state.liveAt(source));
    try std.testing.expectEqual(@as(?u32, null), state.liveAt(formal));
    try std.testing.expectError(error.AlreadySettled, state.apply(terminal[0], .normal));
    try state.apply(.{ .effect = .{ .create = .{ .obligation_id = 2, .destination = formal } } }, .normal);
    try std.testing.expectEqual(@as(?u32, 2), state.liveAt(formal));
    try std.testing.expectError(error.LiveReplacement, state.apply(.{ .effect = .{ .replace = formal } }, .normal));
    try std.testing.expectError(error.InvalidEffectContract, contract.validate(call, &metadata, callee, null));
    const missing_settle: effects.CallContract = .{
        .use_id = 3,
        .callee_declaration_id = finish,
        .result_type_id = @fromBackingInt(@intCast(5)),
        .trust = .trusted_terminal,
        .arguments = &arguments,
        .results = &.{},
    };
    try std.testing.expectError(error.InvalidEffectContract, missing_settle.validate(call, &metadata, callee, authority));
}

test "ordinary recursive call contract uses the checked callee and conserves its argument" {
    const recursive: compiler.identity.DeclId = @fromBackingInt(@intCast(50));
    var argument_expr: sir.Expr = .{ .local = "owner" };
    const args = [_]sir.CallArg{.{ .value = &argument_expr }};
    var call: sir.Call = .{
        .decl_id = recursive,
        .checked_method_use = .{
            .use_id = 8,
            .source_declaration_id = recursive,
            .source_offset = 17,
            .callee_declaration_id = recursive,
            .result_type_id = @fromBackingInt(@intCast(6)),
        },
        .module_name = "sample",
        .owner = null,
        .callee = "recur",
        .args = &args,
    };
    const source = place(1, false);
    const formal = place(2, false);
    const metadata = [_]sir.ExprMetadataEntry{.{ .expr = &argument_expr, .metadata = .{
        .type_id = @fromBackingInt(@intCast(3)),
        .semantics = .plainValue(),
        .checked_place_root = .{ .binding = @fromBackingInt(@intCast(1)) },
    } }};
    var callee: sir.Function = .{ .decl_id = recursive, .module_name = "sample", .owner = null, .name = "recur", .params = &.{.{ .name = "owner", .binding_id = @fromBackingInt(@intCast(2)) }}, .body = &.{} };
    const arguments = [_]effects.Record{.{ .effect = .{ .call_argument = .{
        .use_id = 8,
        .callee_declaration_id = recursive,
        .index = 0,
        .source = source,
        .destination = formal,
        .mode = .move,
    } } }};
    const contract: effects.CallContract = .{
        .use_id = 8,
        .callee_declaration_id = recursive,
        .result_type_id = @fromBackingInt(@intCast(6)),
        .arguments = &arguments,
        .results = &.{},
    };
    var state = effects.State{ .allocator = std.testing.allocator };
    defer state.deinit();
    try state.apply(.{ .effect = .{ .create = .{ .obligation_id = 10, .destination = source } } }, .normal);
    try state.applyCall(contract, call, &metadata, callee, null, .normal);
    try std.testing.expectEqual(@as(?u32, 10), state.liveAt(formal));
    try std.testing.expectEqual(@as(?u32, null), state.liveAt(source));
    callee.is_extern = true;
    try std.testing.expectError(error.InvalidEffectContract, contract.validate(call, &metadata, callee, null));
    callee.is_extern = false;
    call.checked_method_use = null;
    try std.testing.expectError(error.InvalidEffectContract, contract.validate(call, &metadata, callee, null));
}

test "ordinary call summaries preserve two owners on success and error exits" {
    const callee_id: compiler.identity.DeclId = @fromBackingInt(@intCast(70));
    var argument_expr: sir.Expr = .{ .local = "first" };
    const args = [_]sir.CallArg{.{ .value = &argument_expr }};
    const call: sir.Call = .{
        .decl_id = callee_id,
        .checked_method_use = .{ .use_id = 9, .source_declaration_id = @fromBackingInt(@intCast(71)), .source_offset = 4, .callee_declaration_id = callee_id, .result_type_id = @fromBackingInt(@intCast(8)) },
        .module_name = "sample",
        .owner = null,
        .callee = "relay",
        .args = &args,
    };
    const metadata = [_]sir.ExprMetadataEntry{.{ .expr = &argument_expr, .metadata = .{
        .type_id = @fromBackingInt(@intCast(3)),
        .semantics = .plainValue(),
        .checked_place_root = .{ .binding = @fromBackingInt(@intCast(1)) },
    } }};
    const callee: sir.Function = .{ .decl_id = callee_id, .module_name = "sample", .owner = null, .name = "relay", .params = &.{.{ .name = "first", .binding_id = @fromBackingInt(@intCast(2)) }}, .body = &.{} };
    const first = place(1, false);
    const formal = place(2, false);
    const second = place(3, false);
    const success_temp: effects.Subject = .{ .temporary = @fromBackingInt(@intCast(31)) };
    const error_temp: effects.Subject = .{ .temporary = @fromBackingInt(@intCast(32)) };
    const arguments = [_]effects.Record{.{ .effect = .{ .call_argument = .{
        .use_id = 9,
        .callee_declaration_id = callee_id,
        .index = 0,
        .source = first,
        .destination = formal,
        .mode = .move,
    } } }};
    const results = [_]effects.Record{
        .{ .edge = .{ .success = 9 }, .effect = .{ .@"return" = .{ .source = formal, .destination = success_temp } } },
        .{ .edge = .{ .failure = 9 }, .effect = .{ .@"return" = .{ .source = formal, .destination = error_temp } } },
    };
    const contract: effects.CallContract = .{ .use_id = 9, .callee_declaration_id = callee_id, .result_type_id = @fromBackingInt(@intCast(8)), .arguments = &arguments, .results = &results };
    try contract.validate(call, &metadata, callee, null);
    for ([_]effects.Outcome{ .{ .success = 9 }, .{ .failure = 9 } }) |outcome| {
        var state = effects.State{ .allocator = std.testing.allocator };
        defer state.deinit();
        try state.apply(.{ .effect = .{ .create = .{ .obligation_id = 1, .destination = first } } }, .normal);
        try state.apply(.{ .effect = .{ .create = .{ .obligation_id = 2, .destination = second } } }, .normal);
        try state.applyCall(contract, call, &metadata, callee, null, outcome);
        try std.testing.expectEqual(@as(?u32, 2), state.liveAt(second));
        try std.testing.expectEqual(@as(?u32, null), state.liveAt(first));
        try std.testing.expectEqual(@as(?u32, null), state.liveAt(formal));
        try std.testing.expectEqual(@as(?u32, 1), state.liveAt(if (outcome == .success) success_temp else error_temp));
        try std.testing.expectEqual(@as(usize, 2), state.obligations.items.len);
    }
}

test "trusted TaskGroup initializer authority requires a success owner result" {
    var types = compiler.semantic_types.TypeInterner.init(std.testing.allocator);
    defer types.deinit();
    const owner_id: compiler.identity.DeclId = @fromBackingInt(@intCast(10));
    const owner = try types.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = owner_id } });
    const failure = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    const result = try types.intern(.{ .result = .{ .ok = owner, .err = failure } });
    const void_type = try types.intern(.{ .primitive = .void });
    const init_id: compiler.identity.DeclId = @fromBackingInt(@intCast(11));
    const finish_id: compiler.identity.DeclId = @fromBackingInt(@intCast(12));
    const cancel_id: compiler.identity.DeclId = @fromBackingInt(@intCast(13));
    var functions = [_]sir.Function{
        .{ .decl_id = init_id, .module_name = "std.thread", .owner = "TaskGroup", .name = "init", .params = &.{.{ .name = "capacity", .type_id = failure }}, .return_type_id = result, .body = &.{} },
        .{ .decl_id = finish_id, .module_name = "std.thread", .owner = "TaskGroup", .name = "finish", .params = &.{.{ .name = "self", .type_id = owner }}, .return_type_id = void_type, .body = &.{} },
        .{ .decl_id = cancel_id, .module_name = "std.thread", .owner = "TaskGroup", .name = "cancel_and_wait", .params = &.{.{ .name = "self", .type_id = owner }}, .return_type_id = void_type, .body = &.{} },
    };
    const contract: compiler.resource_settlement.Contract = .{
        .owner_type = owner_id,
        .initializer = init_id,
        .terminal_primary = finish_id,
        .terminal_secondary = cancel_id,
    };
    try compiler.resource_settlement.validateContract(&types, &functions, contract);
    functions[0].return_type_id = owner;
    try std.testing.expectError(error.InvalidSettlementContract, compiler.resource_settlement.validateContract(&types, &functions, contract));
    functions[0].return_type_id = result;
    functions[0].is_extern = true;
    try std.testing.expectError(error.InvalidSettlementContract, compiler.resource_settlement.validateContract(&types, &functions, contract));
}

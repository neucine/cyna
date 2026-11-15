const std = @import("std");
const session = @import("session.zig");
const type_resolution = @import("type_resolution.zig");
const sir = @import("sir.zig");
const identity = @import("identity.zig");
const semantic_types = @import("types.zig");

pub fn Owner(comptime host: anytype) type {
    return struct {
        const SemaContext = host.SemaContext;
        const SemaError = host.SemaError;
        const canonical = type_resolution.Canonical(SemaContext);
        const canonicalTypeNode = canonical.typeNode;
        const semanticExprMetadata = host.semanticExprMetadata;
        const MethodUseKey = session.MethodUseKey;

        pub fn buildCheckedPlaceProjections(context: *SemaContext, allocator: std.mem.Allocator, expr: *const sir.Expr) SemaError!?[]const sir.CheckedPlaceProjection {
            var steps: std.ArrayListUnmanaged(sir.CheckedPlaceProjection) = .empty;
            defer steps.deinit(allocator);
            if (!try collectCheckedPlaceProjections(context, allocator, expr, &steps) or steps.items.len == 0) return null;
            return try steps.toOwnedSlice(allocator);
        }

        fn checkedRangeBound(expr: ?*sir.Expr) ?sir.CheckedRangeBound {
            const value = expr orelse return null;
            return if (value.* == .int and value.int.value >= 0)
                .{ .fixed = value.int.value }
            else
                .{ .dynamic = value };
        }

        fn collectCheckedPlaceProjections(context: *SemaContext, allocator: std.mem.Allocator, expr: *const sir.Expr, steps: *std.ArrayListUnmanaged(sir.CheckedPlaceProjection)) SemaError!bool {
            switch (expr.*) {
                .local, .handoff_local, .global_ref, .ref_local, .ref_global, .ref_alias_local, .ref_owned_local => return true,
                .ref_field_local, .ref_field_owned_local => |field| {
                    const owner_id = field.struct_decl_id orelse return false;
                    const metadata = semanticExprMetadata(context, expr) orelse return false;
                    try steps.append(allocator, .{ .step = .{ .field = .{
                        .owner_decl_id = owner_id,
                        .name = field.field,
                    } }, .result_type_id = metadata.type_id });
                    return true;
                },
                .ref_union_field_local => |field| {
                    const owner_id = field.union_decl_id orelse return false;
                    const metadata = semanticExprMetadata(context, expr) orelse return false;
                    try steps.append(allocator, .{ .step = .{ .union_payload = .{
                        .owner_decl_id = owner_id,
                        .name = field.field,
                    } }, .result_type_id = metadata.type_id });
                    return true;
                },
                .ref_index_local => |reference| {
                    const metadata = semanticExprMetadata(context, expr) orelse return false;
                    const index: sir.CheckedIndex = if (reference.index.* == .int and reference.index.int.value >= 0)
                        .{ .fixed = reference.index.int.value }
                    else
                        .{ .dynamic = reference.index };
                    try steps.append(allocator, .{ .step = .{ .index = index }, .result_type_id = metadata.type_id });
                    return true;
                },
                .ref_field_expr => |field| {
                    if (!try collectCheckedPlaceProjections(context, allocator, field.object, steps)) return false;
                    const owner_id = field.struct_decl_id orelse return false;
                    const metadata = semanticExprMetadata(context, expr) orelse return false;
                    try steps.append(allocator, .{ .step = .{ .field = .{ .owner_decl_id = owner_id, .name = field.field } }, .result_type_id = metadata.type_id });
                    return true;
                },
                .field, .borrowed_field => |field| {
                    if (!try collectCheckedPlaceProjections(context, allocator, field.object, steps)) return false;
                    const owner_id = field.struct_decl_id orelse return false;
                    const metadata = semanticExprMetadata(context, expr) orelse return false;
                    try steps.append(allocator, .{ .step = .{ .field = .{ .owner_decl_id = owner_id, .name = field.field } }, .result_type_id = metadata.type_id });
                    return true;
                },
                .tuple_field => |field| {
                    if (!try collectCheckedPlaceProjections(context, allocator, field.object, steps)) return false;
                    const metadata = semanticExprMetadata(context, expr) orelse return false;
                    try steps.append(allocator, .{
                        .step = .{ .index = .{ .fixed = std.math.cast(i64, field.index) orelse return false } },
                        .result_type_id = metadata.type_id,
                    });
                    return true;
                },
                .union_field, .borrowed_union_field => |field| {
                    if (!try collectCheckedPlaceProjections(context, allocator, field.object, steps)) return false;
                    const owner_id = field.union_decl_id orelse return false;
                    const metadata = semanticExprMetadata(context, expr) orelse return false;
                    try steps.append(allocator, .{ .step = .{ .union_payload = .{ .owner_decl_id = owner_id, .name = field.field } }, .result_type_id = metadata.type_id });
                    return true;
                },
                .index, .borrowed_index => |index| {
                    if (!try collectCheckedPlaceProjections(context, allocator, index.object, steps)) return false;
                    const metadata = semanticExprMetadata(context, expr) orelse return false;
                    const checked_index: sir.CheckedIndex = if (index.index.* == .int and index.index.int.value >= 0)
                        .{ .fixed = index.index.int.value }
                    else
                        .{ .dynamic = index.index };
                    try steps.append(allocator, .{ .step = .{ .index = checked_index }, .result_type_id = metadata.type_id });
                    return true;
                },
                .slice_range => |range| {
                    if (!try collectCheckedPlaceProjections(context, allocator, range.object, steps)) return false;
                    const metadata = semanticExprMetadata(context, expr) orelse return false;
                    try steps.append(allocator, .{ .step = .{ .range = .{
                        .start = checkedRangeBound(range.start),
                        .end = checkedRangeBound(range.end),
                    } }, .result_type_id = metadata.type_id });
                    return true;
                },
                else => return false,
            }
        }

        pub fn transferActionForExpr(expr: *const sir.Expr, semantics: sir.ValueSemantics) sir.TransferAction {
            return switch (expr.*) {
                .sparse_take, .take_index_local, .take_index_path_local, .take_path_local => .take,
                .handoff_local => .move,
                else => if (semantics.cleanup == .full_expression or semantics.cleanup == .transferred) .move else .copy,
            };
        }

        pub fn recordExprMetadata(context: *SemaContext, expr: *const sir.Expr, incoming: sir.ExprMetadata) SemaError!void {
            var metadata = incoming;
            if (!metadata.semantics.isValid()) return error.SemanticFailed;
            if (!metadata.consumption.isValid(metadata.semantics)) return error.SemanticFailed;
            if (context.expr_metadata_index.get(expr)) |index| {
                metadata.temporary_id = context.expr_metadata.items[index].metadata.temporary_id;
                if (metadata.semantics.category == .value and metadata.temporary_id == null) {
                    if (context.output.next_temporary_id >= (@as(u64, 1) << 62)) return error.SemanticFailed;
                    metadata.temporary_id = @fromBackingInt(@intCast(context.output.next_temporary_id));
                    context.output.next_temporary_id += 1;
                } else if (metadata.semantics.category != .value) {
                    metadata.temporary_id = null;
                }
                try emitCheckedExprEffect(context, expr, &metadata);
                if (context.expr_metadata.items[index].metadata.checked_place_projections) |old| {
                    const replacement = metadata.checked_place_projections;
                    if (replacement == null or replacement.?.ptr != old.ptr) context.allocator.free(old);
                }
                context.expr_metadata.items[index].metadata = metadata;
                return;
            }
            if (metadata.semantics.category == .value) {
                if (context.output.next_temporary_id >= (@as(u64, 1) << 62)) return error.SemanticFailed;
                metadata.temporary_id = @fromBackingInt(@intCast(context.output.next_temporary_id));
                context.output.next_temporary_id += 1;
            }
            try emitCheckedExprEffect(context, expr, &metadata);
            const index = context.expr_metadata.items.len;
            try context.expr_metadata.append(context.allocator, .{
                .expr = expr,
                .metadata = metadata,
            });
            errdefer _ = context.expr_metadata.pop();
            try context.expr_metadata_index.put(context.allocator, expr, index);
        }

        pub fn recordGeneratedBindingRoot(context: *SemaContext, expr: *const sir.Expr, binding_id: identity.BindingId, non_owning: bool) SemaError!void {
            var metadata = semanticExprMetadata(context, expr) orelse return error.SemanticFailed;
            metadata.checked_place_root = .{ .binding = binding_id };
            metadata.non_owning_place_origin = non_owning;
            try recordExprMetadata(context, expr, metadata);
        }

        /// Stable identity for one lowered call use. A source use lowered again under
        /// another specialization keeps the id it was first recorded with.
        fn stableCallUseId(context: *SemaContext, source_declaration_id: identity.DeclId, source_offset: usize) SemaError!u32 {
            const key = MethodUseKey{ .declaration_id = source_declaration_id, .offset = source_offset };
            if (context.generic.method_use_index.get(key)) |use_id| return use_id;
            const use_id = context.generic.next_generated_use_id;
            context.generic.next_generated_use_id += 1;
            try context.generic.method_use_index.put(context.allocator, key, use_id);
            return use_id;
        }

        /// Record the checked identity of an ordinary or generated call. The record
        /// names the concrete declaration the call settles to and the type that call
        /// produces, so lowering takes its callee from the record rather than resolving
        /// a name. Calls that settle to a protocol witness already carry a protocol
        /// authority and are left alone.
        pub fn attachCheckedCallUse(
            context: *SemaContext,
            expr: *sir.Expr,
            result_type_id: semantic_types.TypeId,
            source_declaration_id: ?identity.DeclId,
            source_offset: usize,
        ) SemaError!void {
            if (expr.* != .call or expr.call.checked_method_use != null) return;
            // A call expression without a resolved callee declaration is a compiler
            // gap: record nothing and let the verifier reject the missing authority.
            const callee_declaration_id = expr.call.decl_id orelse return;
            const source = source_declaration_id orelse callee_declaration_id;
            expr.call.checked_method_use = .{
                .use_id = try stableCallUseId(context, source, source_offset),
                .source_declaration_id = source,
                .source_offset = source_offset,
                .callee_declaration_id = callee_declaration_id,
                .result_type_id = result_type_id,
            };
        }

        fn emitCheckedExprEffect(context: *SemaContext, expr: *const sir.Expr, metadata: *sir.ExprMetadata) SemaError!void {
            if (expr.* == .raw_owned_local or expr.* == .leak_owned_local) {
                // The first metadata pass precedes place-root resolution. The update
                // after lowering supplies the checked binding and emits this effect.
                const place = metadata.checkedPlacePath() orelse return;
                if (place.root != .binding or place.projections != null or place.non_owning) return error.SemanticFailed;
                metadata.checked_effect = .{ .effect = if (expr.* == .raw_owned_local)
                    .{ .borrow = .{ .place = place } }
                else
                    .{ .leak = .{ .place = place } } };
                return;
            }
            if (expr.* == .string_bytes) {
                const source = semanticExprMetadata(context, expr.string_bytes) orelse return error.SemanticFailed;
                const subject: sir.Subject = if (source.checkedPlacePath()) |place|
                    .{ .place = place }
                else if (source.temporary_id) |temporary|
                    .{ .temporary = temporary }
                else
                    return error.SemanticFailed;
                metadata.checked_effect = .{ .effect = .{ .borrow = subject } };
                return;
            }
            if (expr.* == .ref_load) {
                metadata.checked_effect = .{ .effect = .{ .read = .{ .reference_target = .{
                    .reference = expr.ref_load,
                    .target_type_id = metadata.type_id,
                } } } };
                return;
            }
            if (expr.* == .ref_field_expr and metadata.checkedPlacePath() == null and
                expr.ref_field_expr.object.* != .ref_raw_deref)
            {
                const field = expr.ref_field_expr;
                const owner_id = field.struct_decl_id orelse return error.SemanticFailed;
                metadata.checked_effect = .{ .effect = .{ .borrow = .{ .reference_projection = .{
                    .reference = field.object,
                    .projection = .{ .step = .{ .field = .{
                        .owner_decl_id = owner_id,
                        .name = field.field,
                    } }, .result_type_id = metadata.type_id },
                } } } };
                return;
            }
            if (expr.* == .local or expr.* == .global_ref) {
                if (metadata.checkedPlacePath()) |place| {
                    metadata.checked_effect = .{ .effect = .{ .read = .{ .place = place } } };
                }
                return;
            }
            const projected_access: ?bool = switch (expr.*) {
                .field, .union_field, .index => false,
                .borrowed_field, .borrowed_union_field, .borrowed_index => true,
                .tuple_field => metadata.semantics.category == .borrowed_projection,
                else => null,
            };
            if (projected_access) |borrowed| {
                if (metadata.checkedPlacePath()) |place| {
                    metadata.checked_effect = .{ .effect = if (borrowed)
                        .{ .borrow = .{ .place = place } }
                    else
                        .{ .read = .{ .place = place } } };
                }
                return;
            }
            const borrow_access = switch (expr.*) {
                .ref_local, .ref_global, .ref_alias_local, .ref_owned_local, .ref_field_local, .ref_field_owned_local, .ref_index_local, .ref_path_local, .ref_index_path_local, .ref_field_expr, .ref_union_field_local, .slice_range => true,
                else => false,
            };
            if (borrow_access) {
                if (metadata.checkedPlacePath()) |place| {
                    metadata.checked_effect = .{ .effect = .{ .borrow = .{ .place = place } } };
                }
                return;
            }
            const owning_aggregate = metadata.semantics.ownership == .owned or metadata.semantics.ownership == .shared;
            const materializes = switch (expr.*) {
                .new_owned, .new_array, .new_sparse, .sparse_indices, .string, .string_from, .string_slice, .interpolated_string => true,
                .unary => |unary| unary.op == .copy_list,
                .struct_literal, .union_case, .array_literal, .tuple_literal, .array_default, .dense_array_literal, .sparse_literal, .sparse_keyed_literal => owning_aggregate,
                else => false,
            };
            const temporary = metadata.temporary_id orelse if (expr.* == .handoff_local or materializes)
                return error.SemanticFailed
            else
                return;
            const record: sir.Record = switch (expr.*) {
                .handoff_local => .{ .effect = .{ .move = .{
                    .source = .{ .place = metadata.checkedPlacePath() orelse return error.SemanticFailed },
                    .destination = .{ .temporary = temporary },
                } } },
                .new_owned, .new_array, .new_sparse, .sparse_indices, .string, .string_from, .string_slice, .interpolated_string => .{ .effect = .{ .materialize = .{ .temporary = temporary } } },
                .unary => |unary| if (unary.op == .copy_list)
                    .{ .effect = .{ .materialize = .{ .temporary = temporary } } }
                else
                    return,
                .struct_literal, .union_case, .array_literal, .tuple_literal, .array_default, .dense_array_literal, .sparse_literal, .sparse_keyed_literal => if (owning_aggregate)
                    .{ .effect = .{ .materialize = .{ .temporary = temporary } } }
                else
                    return,
                else => return,
            };
            record.validate() catch return error.SemanticFailed;
            metadata.checked_effect = record;
        }

        pub fn recordExprSink(context: *SemaContext, expr: *const sir.Expr, sink: sir.SinkAction) SemaError!void {
            var metadata = semanticExprMetadata(context, expr) orelse return error.SemanticFailed;
            metadata.consumption.sink = sink;
            if (sink == .@"return" and metadata.consumption.transfer == .move and
                (metadata.semantics.ownership == .owned or metadata.semantics.ownership == .shared))
            {
                const temporary = metadata.temporary_id orelse return error.SemanticFailed;
                const declaration = context.function_state.active_return_decl_id orelse context.function_state.active_source_decl_id orelse return error.SemanticFailed;
                const record: sir.Record = .{ .effect = .{ .@"return" = .{
                    .source = .{ .temporary = temporary },
                    .destination = .{ .return_slot = declaration },
                } } };
                record.validate() catch return error.SemanticFailed;
                metadata.checked_sink_effect = record;
            } else {
                metadata.checked_sink_effect = null;
            }
            try recordExprMetadata(context, expr, metadata);
        }

        pub fn emit(context: *SemaContext, allocator: std.mem.Allocator, module: *sir.Module) SemaError!void {
            var phase: @import("../session.zig").Scope = if (context.options.timing_session) |timing_session| timing_session.start("sema.effects.literal_fields", &.{}) else .{};
            defer phase.end();
            errdefer phase.endError();
            try emitCheckedLiteralFields(module);
            nextTiming(context, &phase, "sema.effects.array_items");
            try emitCheckedArrayItems(allocator, module);
            nextTiming(context, &phase, "sema.effects.tuple_items");
            try emitCheckedTupleItems(allocator, module);
            nextTiming(context, &phase, "sema.effects.sparse_literals");
            try emitCheckedSparseLiteralItems(allocator, module);
            nextTiming(context, &phase, "sema.effects.container_inserts");
            try emitCheckedContainerInserts(module);
            nextTiming(context, &phase, "sema.effects.container_pops");
            try emitCheckedContainerPops(module);
            nextTiming(context, &phase, "sema.effects.container_clears");
            try emitCheckedContainerClears(context, module);
            nextTiming(context, &phase, "sema.effects.try_payloads");
            try emitCheckedTryPayloads(module);
            nextTiming(context, &phase, "sema.effects.cast_payloads");
            try emitCheckedCastPayloads(context, module);
            nextTiming(context, &phase, "sema.effects.hosted_share");
            try emitCheckedHostedSharePayloads(module);
            nextTiming(context, &phase, "sema.effects.hosted_spawn");
            try emitCheckedHostedSpawnPayloads(module);
            nextTiming(context, &phase, "sema.effects.task_result_takes");
            try emitCheckedTaskResultTakes(module);
            nextTiming(context, &phase, "sema.effects.closure_captures");
            try emitCheckedClosureCaptures(allocator, module);
            nextTiming(context, &phase, "sema.effects.carrier_payloads");
            try emitCheckedCarrierPayloads(module);
            nextTiming(context, &phase, "sema.effects.takes");
            try emitCheckedTakes(module);
            nextTiming(context, &phase, "sema.effects.sparse_takes");
            try emitCheckedSparseTakes(allocator, module);
            nextTiming(context, &phase, "sema.effects.call_arguments");
            try emitCheckedCallArguments(allocator, module);
            nextTiming(context, &phase, "sema.effects.indirect_calls");
            try emitCheckedIndirectCalls(allocator, module);
            nextTiming(context, &phase, "sema.effects.collect_functions");
            for (@constCast(module.functions)) |*function| {
                function.effect_flow = flow.collectFunction(allocator, module, function) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.SemanticFailed,
                };
                function.effect_flow_owned = true;
            }
            nextTiming(context, &phase, "sema.effects.collect_globals");
            module.global_effect_flow = flow.collectGlobals(allocator, module) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.SemanticFailed,
            };
            module.global_effect_flow_owned = true;
            nextTiming(context, &phase, "sema.effects.verify");
            flow.verifyModule(allocator, module) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.SemanticFailed,
            };
            phase.end();
        }

        fn nextTiming(context: *SemaContext, phase: *@import("../session.zig").Scope, name: []const u8) void {
            phase.end();
            phase.* = if (context.options.timing_session) |timing_session| timing_session.start(name, &.{}) else .{};
        }

        fn emitCheckedLiteralFields(module: *sir.Module) SemaError!void {
            for (module.expr_metadata) |entry| {
                const literal: *sir.StructLiteral = switch (@constCast(entry.expr).*) {
                    .new_owned => |*value| value,
                    .struct_literal => |*value| value,
                    else => continue,
                };
                const parent = entry.metadata.temporary_id orelse continue;
                const declaration = literal.decl_id orelse continue;
                for (@constCast(literal.fields)) |*field| {
                    const child = module.metadataForExpr(field.value) orelse return error.SemanticFailed;
                    if (child.consumption.transfer != .move or
                        (child.semantics.ownership != .owned and child.semantics.ownership != .shared)) continue;
                    const source = child.temporary_id orelse return error.SemanticFailed;
                    field.checked_transfer = .{ .effect = .{ .move = .{
                        .source = .{ .temporary = source },
                        .destination = .{ .temporary_projection = .{
                            .root = parent,
                            .projection = .{
                                .step = .{ .field = .{ .owner_decl_id = declaration, .name = field.name } },
                                .result_type_id = child.type_id,
                            },
                        } },
                    } } };
                }
            }
        }

        fn emitCheckedArrayItems(allocator: std.mem.Allocator, module: *sir.Module) SemaError!void {
            for (module.expr_metadata) |entry| {
                const literal: *sir.ArrayLiteral = switch (@constCast(entry.expr).*) {
                    .array_literal => |*value| value,
                    .dense_array_literal => |*value| value,
                    else => continue,
                };
                var moving = false;
                for (literal.items) |item| {
                    const child = module.metadataForExpr(item) orelse return error.SemanticFailed;
                    if (child.consumption.transfer == .move and
                        (child.semantics.ownership == .owned or child.semantics.ownership == .shared)) moving = true;
                }
                if (!moving) continue;
                const parent = entry.metadata.temporary_id orelse return error.SemanticFailed;
                const transfers = try allocator.alloc(?sir.Record, literal.items.len);
                @memset(transfers, null);
                literal.checked_transfers = transfers;
                for (literal.items, 0..) |item, index| {
                    const child = module.metadataForExpr(item) orelse return error.SemanticFailed;
                    if (child.consumption.transfer != .move or
                        (child.semantics.ownership != .owned and child.semantics.ownership != .shared)) continue;
                    transfers[index] = .{ .effect = .{ .move = .{
                        .source = .{ .temporary = child.temporary_id orelse return error.SemanticFailed },
                        .destination = .{ .temporary_projection = .{
                            .root = parent,
                            .projection = .{
                                .step = .{ .index = .{ .fixed = std.math.cast(i64, index) orelse return error.SemanticFailed } },
                                .result_type_id = child.type_id,
                            },
                        } },
                    } } };
                }
            }
        }

        fn emitCheckedTupleItems(allocator: std.mem.Allocator, module: *sir.Module) SemaError!void {
            for (module.expr_metadata) |entry| {
                const literal: *sir.TupleLiteral = switch (@constCast(entry.expr).*) {
                    .tuple_literal => |*value| value,
                    else => continue,
                };
                var moving = false;
                for (literal.items) |item| {
                    const child = module.metadataForExpr(item) orelse return error.SemanticFailed;
                    if (child.consumption.transfer == .move and
                        (child.semantics.ownership == .owned or child.semantics.ownership == .shared)) moving = true;
                }
                if (!moving) continue;
                const parent = entry.metadata.temporary_id orelse return error.SemanticFailed;
                const transfers = try allocator.alloc(?sir.Record, literal.items.len);
                @memset(transfers, null);
                literal.checked_transfers = transfers;
                for (literal.items, 0..) |item, index| {
                    const child = module.metadataForExpr(item) orelse return error.SemanticFailed;
                    if (child.consumption.transfer != .move or
                        (child.semantics.ownership != .owned and child.semantics.ownership != .shared)) continue;
                    transfers[index] = .{ .effect = .{ .move = .{
                        .source = .{ .temporary = child.temporary_id orelse return error.SemanticFailed },
                        .destination = .{ .temporary_projection = .{
                            .root = parent,
                            .projection = .{
                                .step = .{ .index = .{ .fixed = std.math.cast(i64, index) orelse return error.SemanticFailed } },
                                .result_type_id = child.type_id,
                            },
                        } },
                    } } };
                }
            }
        }

        fn checkedSparseItemTransfer(module: *sir.Module, parent: identity.TemporaryId, value: *const sir.Expr, key: sir.CheckedIndex) SemaError!?sir.Record {
            const child = module.metadataForExpr(value) orelse return error.SemanticFailed;
            if (child.consumption.transfer != .move or
                (child.semantics.ownership != .owned and child.semantics.ownership != .shared)) return null;
            return .{ .effect = .{ .move = .{
                .source = .{ .temporary = child.temporary_id orelse return error.SemanticFailed },
                .destination = .{ .temporary_projection = .{
                    .root = parent,
                    .projection = .{ .step = .{ .index = key }, .result_type_id = child.type_id },
                } },
            } } };
        }

        fn emitCheckedSparseLiteralItems(allocator: std.mem.Allocator, module: *sir.Module) SemaError!void {
            for (module.expr_metadata) |entry| {
                switch (@constCast(entry.expr).*) {
                    .sparse_literal => |*literal| {
                        var moving = false;
                        for (literal.items) |item| {
                            const child = module.metadataForExpr(item) orelse return error.SemanticFailed;
                            moving = moving or (child.consumption.transfer == .move and
                                (child.semantics.ownership == .owned or child.semantics.ownership == .shared));
                        }
                        if (!moving) continue;
                        const parent = entry.metadata.temporary_id orelse return error.SemanticFailed;
                        const transfers = try allocator.alloc(?sir.Record, literal.items.len);
                        @memset(transfers, null);
                        literal.checked_transfers = transfers;
                        for (literal.items, 0..) |item, index| {
                            transfers[index] = try checkedSparseItemTransfer(module, parent, item, .{ .fixed = std.math.cast(i64, index) orelse return error.SemanticFailed });
                        }
                    },
                    .sparse_keyed_literal => |*literal| {
                        var moving = false;
                        for (literal.entries) |item| {
                            const child = module.metadataForExpr(item.value) orelse return error.SemanticFailed;
                            moving = moving or (child.consumption.transfer == .move and
                                (child.semantics.ownership == .owned or child.semantics.ownership == .shared));
                        }
                        if (!moving) continue;
                        const parent = entry.metadata.temporary_id orelse return error.SemanticFailed;
                        const transfers = try allocator.alloc(?sir.Record, literal.entries.len);
                        @memset(transfers, null);
                        literal.checked_transfers = transfers;
                        for (literal.entries, 0..) |item, index| {
                            const key: sir.CheckedIndex = if (item.index.* == .int and item.index.int.value >= 0)
                                .{ .fixed = item.index.int.value }
                            else
                                .{ .dynamic = item.index };
                            transfers[index] = try checkedSparseItemTransfer(module, parent, item.value, key);
                        }
                    },
                    else => {},
                }
            }
        }

        fn emitCheckedContainerInserts(module: *sir.Module) SemaError!void {
            for (module.expr_metadata) |entry| {
                switch (@constCast(entry.expr).*) {
                    .sequence_push => |*push| {
                        const child = module.metadataForExpr(push.value) orelse return error.SemanticFailed;
                        const receiver = module.metadataForExpr(push.object) orelse return error.SemanticFailed;
                        if (child.consumption.transfer != .move or
                            (child.semantics.ownership != .owned and child.semantics.ownership != .shared)) continue;
                        const destination: sir.Subject = .{ .container_slot = .{
                            .object = push.object,
                            .place = receiver.checkedPlacePath(),
                            .item_type_id = child.type_id,
                            .position = .append,
                        } };
                        push.checked_transfer = .{ .effect = .{ .move = .{
                            .source = .{ .temporary = child.temporary_id orelse return error.SemanticFailed },
                            .destination = destination,
                        } } };
                    },
                    .sparse_insert => |*insert| {
                        const child = module.metadataForExpr(insert.value) orelse return error.SemanticFailed;
                        const receiver = module.metadataForExpr(insert.object) orelse return error.SemanticFailed;
                        if (child.consumption.transfer != .move or
                            (child.semantics.ownership != .owned and child.semantics.ownership != .shared)) continue;
                        const destination: sir.Subject = .{ .container_slot = .{
                            .object = insert.object,
                            .place = receiver.checkedPlacePath(),
                            .item_type_id = child.type_id,
                            .position = .{ .indexed = if (insert.index.* == .int and insert.index.int.value >= 0)
                                .{ .fixed = insert.index.int.value }
                            else
                                .{ .dynamic = insert.index } },
                        } };
                        insert.checked_replace = .{ .effect = .{ .replace = destination } };
                        insert.checked_transfer = .{ .effect = .{ .move = .{
                            .source = .{ .temporary = child.temporary_id orelse return error.SemanticFailed },
                            .destination = destination,
                        } } };
                    },
                    else => {},
                }
            }
        }

        fn emitCheckedContainerPops(module: *sir.Module) SemaError!void {
            for (@constCast(module.expr_metadata)) |*entry| {
                if (entry.expr.* != .sequence_pop) continue;
                if (entry.metadata.semantics.ownership != .owned and
                    entry.metadata.semantics.ownership != .shared) continue;
                const destination = entry.metadata.temporary_id orelse return error.SemanticFailed;
                const receiver = module.metadataForExpr(entry.expr.sequence_pop) orelse return error.SemanticFailed;
                entry.metadata.checked_effect = .{ .effect = .{ .take = .{
                    .source = .{ .container_slot = .{
                        .object = entry.expr.sequence_pop,
                        .place = receiver.checkedPlacePath(),
                        .item_type_id = entry.metadata.type_id,
                        .position = .last,
                    } },
                    .destination = .{ .temporary = destination },
                } } };
            }
        }

        fn emitCheckedContainerClears(context: *SemaContext, module: *sir.Module) SemaError!void {
            for (@constCast(module.expr_metadata)) |*entry| {
                const object: *sir.Expr = switch (entry.expr.*) {
                    .sequence_clear => |value| value,
                    .sparse_clear => |value| value,
                    else => continue,
                };
                const object_metadata = module.metadataForExpr(object) orelse return error.SemanticFailed;
                const item_type: semantic_types.TypeId = switch (canonicalTypeNode(context, object_metadata.type_id).*) {
                    .dense_array => |item| if (entry.expr.* == .sequence_clear) item else return error.SemanticFailed,
                    .sparse_array => |item| if (entry.expr.* == .sparse_clear) item else return error.SemanticFailed,
                    else => return error.SemanticFailed,
                };
                entry.metadata.checked_effect = .{ .effect = .{ .clear = .{ .container_slot = .{
                    .object = object,
                    .place = object_metadata.checkedPlacePath(),
                    .item_type_id = item_type,
                    .position = .all,
                } } } };
            }
        }

        fn emitCheckedTryPayloads(module: *sir.Module) SemaError!void {
            for (@constCast(module.expr_metadata)) |*entry| {
                if (entry.expr.* != .@"try") continue;
                if (entry.metadata.semantics.ownership != .owned and
                    entry.metadata.semantics.ownership != .shared) continue;
                const attempt = entry.expr.@"try";
                const carrier = module.metadataForExpr(attempt.expr) orelse return error.SemanticFailed;
                const carrier_temp = carrier.temporary_id orelse return error.SemanticFailed;
                const result_temp = entry.metadata.temporary_id orelse return error.SemanticFailed;
                entry.metadata.checked_effect = .{
                    .edge = .{ .active_case = .{ .result = .ok } },
                    .effect = .{ .take = .{
                        .source = .{ .temporary_payload = .{
                            .root = carrier_temp,
                            .owner_decl_id = null,
                            .case_name = "ok",
                            .result_case = .ok,
                            .payload_type_id = entry.metadata.type_id,
                        } },
                        .destination = .{ .temporary = result_temp },
                    } },
                };
            }
        }

        fn emitCheckedCastPayloads(context: *SemaContext, module: *sir.Module) SemaError!void {
            for (@constCast(module.expr_metadata)) |*entry| {
                if (entry.expr.* != .cast) continue;
                const cast = entry.expr.cast;
                const carrier = module.metadataForExpr(cast.subject) orelse return error.SemanticFailed;
                const carrier_type = canonicalTypeNode(context, carrier.type_id);
                if (cast.reinterpret) continue;
                const payload_type_id = cast.target_type_id orelse return error.SemanticFailed;
                var owner_decl_id: ?identity.DeclId = null;
                var case_name: []const u8 = "some";
                const active_case: sir.CheckedPayloadCase = switch (carrier_type.*) {
                    .optional => |child| blk: {
                        if (child != payload_type_id) return error.SemanticFailed;
                        break :blk .optional_some;
                    },
                    .nominal => |nominal| blk: {
                        if (nominal.kind != .@"union") continue;
                        const declaration = cast.source_union_decl_id orelse return error.SemanticFailed;
                        if (declaration != nominal.decl_id) return error.SemanticFailed;
                        case_name = cast.union_case_name orelse return error.SemanticFailed;
                        var ordinal: ?u32 = null;
                        for (module.unions) |union_decl| {
                            if (union_decl.decl_id != declaration) continue;
                            for (union_decl.fields, 0..) |field, index| {
                                if (std.mem.eql(u8, field.name, case_name) and field.type_id == payload_type_id) {
                                    ordinal = @intCast(index);
                                    break;
                                }
                            }
                            break;
                        }
                        owner_decl_id = declaration;
                        break :blk .{ .union_field = .{ .owner_decl_id = declaration, .ordinal = ordinal orelse return error.SemanticFailed } };
                    },
                    else => continue,
                };
                if (entry.metadata.semantics.ownership != .owned and entry.metadata.semantics.ownership != .shared) continue;
                const carrier_temp = carrier.temporary_id orelse return error.SemanticFailed;
                const result_temp = entry.metadata.temporary_id orelse return error.SemanticFailed;
                entry.metadata.checked_effect = .{
                    .edge = .{ .active_case = active_case },
                    .effect = .{ .take = .{
                        .source = .{ .temporary_payload = .{
                            .root = carrier_temp,
                            .owner_decl_id = owner_decl_id,
                            .case_name = case_name,
                            .result_case = null,
                            .payload_type_id = payload_type_id,
                        } },
                        .destination = if (cast.fallible) .{ .temporary_payload = .{
                            .root = result_temp,
                            .owner_decl_id = null,
                            .case_name = "some",
                            .result_case = null,
                            .payload_type_id = payload_type_id,
                        } } else .{ .temporary = result_temp },
                    } },
                };
            }
        }

        fn emitCheckedHostedSharePayloads(module: *sir.Module) SemaError!void {
            for (module.expr_metadata) |entry| {
                if (entry.expr.* != .sync_share_boxed) continue;
                const share = &@constCast(entry.expr).sync_share_boxed;
                const declaration = share.decl_id orelse return error.SemanticFailed;
                const payload = module.metadataForExpr(share.payload) orelse return error.SemanticFailed;
                if (payload.type_id != (share.payload_type_id orelse return error.SemanticFailed)) return error.SemanticFailed;
                if (payload.consumption.transfer == .move and
                    (payload.semantics.ownership == .owned or payload.semantics.ownership == .shared))
                {
                    share.checked_payload_transfer = .{ .effect = .{ .move = .{
                        .source = .{ .temporary = payload.temporary_id orelse return error.SemanticFailed },
                        .destination = .{ .call_slot = .{ .function_decl_id = declaration, .index = 0 } },
                    } } };
                }
                if (entry.metadata.consumption.transfer == .move and
                    (entry.metadata.semantics.ownership == .owned or entry.metadata.semantics.ownership == .shared))
                {
                    share.checked_result_effect = .{ .effect = .{ .move = .{
                        .source = .{ .return_slot = declaration },
                        .destination = .{ .temporary = entry.metadata.temporary_id orelse return error.SemanticFailed },
                    } } };
                }
            }
        }

        fn emitCheckedHostedSpawnPayloads(module: *sir.Module) SemaError!void {
            for (module.expr_metadata) |entry| {
                const mutable_expr = @constCast(entry.expr);
                const payload_expr: *sir.Expr, const payload_type: ?sir.TypeId, const declaration: identity.DeclId, const argument_index: u32, const record: *?sir.Record = switch (mutable_expr.*) {
                    .thread_spawn_boxed => |*spawn| .{ spawn.payload, spawn.payload_type_id, spawn.decl_id orelse return error.SemanticFailed, 1, &spawn.checked_payload_transfer },
                    .task_group_spawn_boxed => |*spawn| .{ spawn.payload, spawn.payload_type_id, spawn.decl_id orelse return error.SemanticFailed, 3, &spawn.checked_payload_transfer },
                    else => continue,
                };
                const payload = module.metadataForExpr(payload_expr) orelse return error.SemanticFailed;
                if (payload.type_id != (payload_type orelse return error.SemanticFailed)) return error.SemanticFailed;
                if (payload.semantics.ownership != .shared and payload.semantics.ownership != .owned) continue;
                const source: sir.Subject = if (payload.temporary_id) |id|
                    .{ .temporary = id }
                else if (payload.checkedPlacePath()) |path|
                    .{ .place = path }
                else
                    return error.SemanticFailed;
                const destination: sir.Subject = .{ .call_slot = .{ .function_decl_id = declaration, .index = argument_index } };
                switch (payload.consumption.transfer) {
                    .copy => if (payload.semantics.ownership == .shared) {
                        record.* = .{ .effect = .{ .copy = .{ .source = source, .destination = destination } } };
                    },
                    .move => record.* = .{ .effect = .{ .move = .{ .source = source, .destination = destination } } },
                    .take => {},
                }
            }
        }

        fn emitCheckedTaskResultTakes(module: *sir.Module) SemaError!void {
            for (module.expr_metadata) |entry| {
                if (entry.expr.* != .task_result_take) continue;
                const take = &@constCast(entry.expr).task_result_take;
                if (entry.metadata.semantics.ownership != .owned and
                    entry.metadata.semantics.ownership != .shared) continue;
                const value_type = take.value_type_id orelse return error.SemanticFailed;
                const result_temp = entry.metadata.temporary_id orelse return error.SemanticFailed;
                take.checked_payload_take = .{ .effect = .{ .take = .{
                    .source = .{ .raw_pointee = .{ .pointer = take.pointer, .pointee_type_id = value_type } },
                    .destination = .{ .temporary_payload = .{
                        .root = result_temp,
                        .owner_decl_id = null,
                        .case_name = "ok",
                        .result_case = .ok,
                        .payload_type_id = value_type,
                    } },
                } } };
            }
        }

        fn emitCheckedClosureCaptures(allocator: std.mem.Allocator, module: *sir.Module) SemaError!void {
            for (module.expr_metadata) |entry| {
                if (entry.expr.* != .closure) continue;
                const closure = &@constCast(entry.expr).closure;
                if (closure.captures.len == 0) continue;
                const environment = closure.env_decl_id orelse return error.SemanticFailed;
                const transfers = try allocator.alloc(?sir.Record, closure.captures.len);
                @memset(transfers, null);
                closure.checked_transfers = transfers;
                for (closure.captures, transfers, 0..) |capture, *record, index| {
                    const metadata = module.metadataForExpr(capture) orelse return error.SemanticFailed;
                    if (metadata.semantics.ownership == .plain) continue;
                    const source: sir.Subject = if (metadata.temporary_id) |id|
                        .{ .temporary = id }
                    else if (metadata.checkedPlacePath()) |path|
                        .{ .place = path }
                    else
                        return error.SemanticFailed;
                    if (metadata.consumption.transfer != .copy) return error.SemanticFailed;
                    record.* = if (metadata.semantics.ownership == .shared)
                        .{ .effect = .{ .copy = .{
                            .source = source,
                            .destination = .{ .closure_slot = .{ .environment_decl_id = environment, .field_index = @intCast(index) } },
                        } } }
                    else
                        .{ .effect = .{ .borrow = source } };
                }
            }
        }

        fn emitCheckedCarrierPayloads(module: *sir.Module) SemaError!void {
            for (module.expr_metadata) |entry| {
                if (entry.expr.* != .union_case) continue;
                const case = &@constCast(entry.expr).union_case;
                const value = case.value orelse continue;
                const child = module.metadataForExpr(value) orelse return error.SemanticFailed;
                if (child.consumption.transfer != .move or
                    (child.semantics.ownership != .owned and child.semantics.ownership != .shared)) continue;
                const parent = entry.metadata.temporary_id orelse return error.SemanticFailed;
                const source = child.temporary_id orelse return error.SemanticFailed;
                case.checked_transfer = .{ .effect = .{ .move = .{
                    .source = .{ .temporary = source },
                    .destination = .{ .temporary_payload = .{
                        .root = parent,
                        .owner_decl_id = case.decl_id,
                        .case_name = case.case_name,
                        .result_case = case.result_case,
                        .payload_type_id = child.type_id,
                    } },
                } } };
            }
        }

        fn emitCheckedTakes(module: *sir.Module) SemaError!void {
            for (@constCast(module.expr_metadata)) |*entry| {
                const supported = switch (entry.expr.*) {
                    .take_path_local, .take_index_local, .take_index_path_local => true,
                    else => false,
                };
                if (!supported) continue;
                if (entry.metadata.semantics.ownership != .owned and entry.metadata.semantics.ownership != .shared) continue;
                const temporary = entry.metadata.temporary_id orelse return error.SemanticFailed;
                const source = entry.metadata.checkedPlacePath() orelse return error.SemanticFailed;
                const record: sir.Record = .{ .effect = .{ .take = .{
                    .source = .{ .place = source },
                    .destination = .{ .temporary = temporary },
                } } };
                record.validate() catch return error.SemanticFailed;
                entry.metadata.checked_effect = record;
            }
        }

        fn emitCheckedSparseTakes(allocator: std.mem.Allocator, module: *sir.Module) SemaError!void {
            for (@constCast(module.expr_metadata)) |*entry| {
                if (entry.expr.* != .sparse_take) continue;
                if (entry.metadata.semantics.ownership != .owned and entry.metadata.semantics.ownership != .shared) continue;
                const take = entry.expr.sparse_take;
                const object = module.metadataForExpr(take.object) orelse return error.SemanticFailed;
                const object_place = object.checkedPlacePath() orelse return error.SemanticFailed;
                const prefix = object_place.projections orelse &.{};
                const projections = try allocator.alloc(sir.CheckedPlaceProjection, prefix.len + 1);
                @memcpy(projections[0..prefix.len], prefix);
                projections[prefix.len] = .{
                    .step = .{ .index = if (take.index.* == .int and take.index.int.value >= 0)
                        .{ .fixed = take.index.int.value }
                    else
                        .{ .dynamic = take.index } },
                    .result_type_id = entry.metadata.type_id,
                };
                if (entry.metadata.checked_place_projections) |old| {
                    if (old.ptr != prefix.ptr) allocator.free(old);
                }
                entry.metadata.checked_place_root = object_place.root;
                entry.metadata.checked_place_projections = projections;
                entry.metadata.non_owning_place_origin = object_place.non_owning;
                const temporary = entry.metadata.temporary_id orelse return error.SemanticFailed;
                const source = entry.metadata.checkedPlacePath() orelse return error.SemanticFailed;
                const record: sir.Record = .{ .effect = .{ .take = .{
                    .source = .{ .place = source },
                    .destination = .{ .temporary = temporary },
                } } };
                record.validate() catch return error.SemanticFailed;
                entry.metadata.checked_effect = record;
            }
        }

        fn emitCheckedCallArguments(allocator: std.mem.Allocator, module: *sir.Module) SemaError!void {
            for (module.expr_metadata) |entry| {
                if (entry.expr.* != .call) continue;
                const call = &@constCast(entry.expr).call;
                const use = call.checked_method_use orelse continue;
                const callee_id = call.decl_id orelse continue;
                var callee: ?sir.Function = null;
                for (module.functions) |function| {
                    if (function.decl_id == callee_id) {
                        callee = function;
                        break;
                    }
                }
                const function = callee orelse continue;
                if (function.params.len != call.args.len) return error.SemanticFailed;
                var transfer_records: std.ArrayListUnmanaged(sir.Record) = .empty;
                defer transfer_records.deinit(allocator);
                var sites: std.ArrayListUnmanaged(sir.CallEvaluationSite) = .empty;
                defer sites.deinit(allocator);
                for (call.args, function.params, 0..) |arg, param, index| {
                    const expr = switch (arg) {
                        .value => |value| value,
                    };
                    try sites.append(allocator, .{ .argument_value = expr });
                    const metadata = module.metadataForExpr(expr) orelse return error.SemanticFailed;
                    if (metadata.semantics.ownership == .plain) continue;
                    // Some generated call operands have not acquired an O1 source yet.
                    // Keep them outside this direct-argument slice until that identity
                    // is represented; the verifier applies the same boundary.
                    const source: sir.Subject = if (metadata.temporary_id) |id|
                        .{ .temporary = id }
                    else if (metadata.checked_generated_payload_binding) |id|
                        .{ .generated_payload = id }
                    else if (metadata.checkedPlacePath()) |path|
                        .{ .place = path }
                    else
                        continue;
                    const moving = (metadata.consumption.transfer == .move or
                        metadata.checked_generated_payload_binding != null) and
                        (metadata.semantics.ownership == .owned or metadata.semantics.ownership == .shared);
                    const destination: ?sir.Subject = if (moving) .{ .place = .{
                        .root = .{ .binding = param.binding_id orelse return error.SemanticFailed },
                        .projections = null,
                        .non_owning = false,
                    } } else null;
                    const record: sir.Record = .{ .effect = .{ .call_argument = .{
                        .use_id = use.use_id,
                        .callee_declaration_id = callee_id,
                        .index = @intCast(index),
                        .source = source,
                        .destination = destination,
                        .mode = if (moving) .move else .borrow,
                    } } };
                    record.validate() catch return error.SemanticFailed;
                    try transfer_records.append(allocator, record);
                    try sites.append(allocator, .{ .effect = record });
                }
                if (transfer_records.items.len != 0) {
                    call.checked_arguments = try transfer_records.toOwnedSlice(allocator);
                    call.checked_arguments_owned = true;
                }
                const result = module.metadataForExpr(entry.expr) orelse return error.SemanticFailed;
                if ((result.semantics.ownership == .owned or result.semantics.ownership == .shared) and
                    result.temporary_id != null and !function.is_extern)
                {
                    const record: sir.Record = .{ .effect = .{ .move = .{
                        .source = .{ .return_slot = callee_id },
                        .destination = .{ .temporary = result.temporary_id.? },
                    } } };
                    record.validate() catch return error.SemanticFailed;
                    call.checked_result_effect = record;
                    try sites.append(allocator, .{ .effect = record });
                }
                if (sites.items.len != 0) {
                    call.checked_evaluation_sites = try sites.toOwnedSlice(allocator);
                    call.checked_evaluation_sites_owned = true;
                }
            }
        }

        fn emitCheckedIndirectCalls(allocator: std.mem.Allocator, module: *sir.Module) SemaError!void {
            for (module.expr_metadata) |entry| {
                if (entry.expr.* != .indirect_call) continue;
                const call = &@constCast(entry.expr).indirect_call;
                // Generated hosted trampolines have their own checked payload contract.
                if (call.checked_evaluation_sites_len != 0) continue;
                var transfer_records: ?[]?sir.Record = null;
                errdefer if (transfer_records) |owned| allocator.free(owned);
                for (call.args, 0..) |arg, index| {
                    const value = switch (arg) {
                        .value => |expr| expr,
                    };
                    const metadata = module.metadataForExpr(value) orelse return error.SemanticFailed;
                    if (metadata.semantics.ownership == .plain) continue;
                    const source: sir.Subject = if (metadata.temporary_id) |id|
                        .{ .temporary = id }
                    else if (metadata.checked_generated_payload_binding) |id|
                        .{ .generated_payload = id }
                    else if (metadata.checkedPlacePath()) |path|
                        .{ .place = path }
                    else
                        return error.SemanticFailed;
                    const moving = metadata.consumption.transfer == .move and
                        (metadata.semantics.ownership == .owned or metadata.semantics.ownership == .shared);
                    const record: sir.Record = .{ .effect = if (moving) .{ .move = .{
                        .source = source,
                        .destination = .{ .indirect_call_slot = .{ .call = entry.expr, .index = @intCast(index) } },
                    } } else .{ .borrow = source } };
                    record.validate() catch return error.SemanticFailed;
                    if (transfer_records == null) {
                        transfer_records = try allocator.alloc(?sir.Record, call.args.len);
                        @memset(transfer_records.?, null);
                    }
                    transfer_records.?[index] = record;
                }
                call.checked_arguments = transfer_records;
                transfer_records = null;
                if (entry.metadata.semantics.ownership == .owned or entry.metadata.semantics.ownership == .shared) {
                    const result = entry.metadata.temporary_id orelse return error.SemanticFailed;
                    call.checked_result_effect = .{ .effect = .{ .move = .{
                        .source = .{ .indirect_return_slot = entry.expr },
                        .destination = .{ .temporary = result },
                    } } };
                }
            }
        }
    };
}

pub const checked_records = struct {
    /// A checked storage location. Obligation identity is separate: a move changes
    /// this location without creating a new obligation.
    pub const Subject = sir.Subject;
    pub const Edge = sir.Edge;
    pub const CallArgument = sir.CallArgument;
    pub const Effect = sir.Effect;
    pub const Record = sir.Record;

    pub const CallContract = struct {
        use_id: u32,
        callee_declaration_id: identity.DeclId,
        result_type_id: sir.TypeId,
        trust: enum { ordinary, trusted_initializer, trusted_terminal } = .ordinary,
        arguments: []const Record,
        body_effects: []const Record = &.{},
        results: []const Record,

        /// A concrete call already has an identity record. The effect contract
        /// must name that exact use and callee; display names grant no authority.
        pub const TrustedAuthority = struct {
            initializer: identity.DeclId,
            terminal_primary: identity.DeclId,
            terminal_secondary: identity.DeclId,
        };

        pub fn validate(
            self: CallContract,
            call: sir.Call,
            metadata: []const sir.ExprMetadataEntry,
            callee: sir.Function,
            trusted: ?TrustedAuthority,
        ) error{InvalidEffectContract}!void {
            const use = call.checked_method_use orelse return error.InvalidEffectContract;
            if (self.use_id == 0 or self.use_id != use.use_id or
                self.callee_declaration_id != (use.callee_declaration_id orelse return error.InvalidEffectContract) or
                use.result_type_id != self.result_type_id or
                call.decl_id != self.callee_declaration_id or callee.decl_id != self.callee_declaration_id or
                call.args.len != callee.params.len)
            {
                return error.InvalidEffectContract;
            }
            // Ownership-bearing calls across an external boundary have no checked
            // Cyna body or trusted declaration contract to establish conservation.
            if (callee.is_extern and (self.arguments.len != 0 or self.body_effects.len != 0 or self.results.len != 0)) {
                return error.InvalidEffectContract;
            }
            for (self.arguments) |record| {
                try record.validate();
                if (record.effect != .call_argument) return error.InvalidEffectContract;
                const argument = record.effect.call_argument;
                if (argument.use_id != self.use_id or argument.callee_declaration_id != self.callee_declaration_id or
                    @as(usize, argument.index) >= call.args.len) return error.InvalidEffectContract;
                const argument_expr = switch (call.args[argument.index]) {
                    .value => |expr| expr,
                };
                const checked_source = subjectForExpr(metadata, argument_expr) orelse return error.InvalidEffectContract;
                if (!sameSubject(argument.source, checked_source) or argument.source.canOwn() != checked_source.canOwn()) {
                    return error.InvalidEffectContract;
                }
                if (argument.mode == .move) {
                    const destination = argument.destination.?;
                    if (destination != .place or destination.place.root != .binding or
                        destination.place.root.binding != (callee.params[argument.index].binding_id orelse return error.InvalidEffectContract) or
                        destination.place.projections != null)
                    {
                        return error.InvalidEffectContract;
                    }
                }
            }
            for (self.body_effects) |record| {
                try record.validate();
                if (record.edge != .always) return error.InvalidEffectContract;
            }
            for (self.results) |record| {
                try record.validate();
                if (record.edge == .always or record.edge == .active_case) return error.InvalidEffectContract;
                const edge_use_id = switch (record.edge) {
                    .success => |id| id,
                    .failure => |id| id,
                    else => unreachable,
                };
                if (edge_use_id != self.use_id) return error.InvalidEffectContract;
            }
            switch (self.trust) {
                .ordinary => if (trusted) |authority| {
                    if (self.callee_declaration_id == authority.initializer or
                        self.callee_declaration_id == authority.terminal_primary or
                        self.callee_declaration_id == authority.terminal_secondary) return error.InvalidEffectContract;
                },
                .trusted_initializer => {
                    const authority = trusted orelse return error.InvalidEffectContract;
                    if (self.callee_declaration_id != authority.initializer) return error.InvalidEffectContract;
                    var creates_on_success = false;
                    for (self.results) |record| if (record.effect == .create) {
                        if (record.edge != .success) return error.InvalidEffectContract;
                        creates_on_success = true;
                    };
                    if (!creates_on_success) return error.InvalidEffectContract;
                },
                .trusted_terminal => {
                    const authority = trusted orelse return error.InvalidEffectContract;
                    if (self.callee_declaration_id != authority.terminal_primary and
                        self.callee_declaration_id != authority.terminal_secondary) return error.InvalidEffectContract;
                    if (self.arguments.len == 0 or self.arguments[0].effect != .call_argument or
                        self.arguments[0].effect.call_argument.index != 0 or
                        self.arguments[0].effect.call_argument.mode != .move)
                    {
                        return error.InvalidEffectContract;
                    }
                    const formal = self.arguments[0].effect.call_argument.destination orelse return error.InvalidEffectContract;
                    var settles_receiver = false;
                    for (self.body_effects) |record| if (record.effect == .settle and
                        record.effect.settle.terminal_declaration_id == self.callee_declaration_id and
                        sameSubject(record.effect.settle.source, formal))
                    {
                        settles_receiver = true;
                    };
                    if (!settles_receiver) return error.InvalidEffectContract;
                },
            }
        }
    };

    pub const Outcome = union(enum) {
        normal,
        success: u32,
        failure: u32,
        active_case: sir.CheckedPayloadCase,
    };

    pub const TransitionError = error{
        OutOfMemory,
        InvalidEffectContract,
        DuplicateObligation,
        MissingObligation,
        DestinationOccupied,
        AlreadySettled,
        LiveReplacement,
    };

    /// Small checked transition model for a single evaluation path. `create`
    /// requires an unused identity and empty destination. Transfers require a
    /// live source and empty destination and retain the obligation identity.
    /// `settle` requires a live source and consumes it once. Replacement and drop
    /// require no live obligation at that location. Borrow and read leave the
    /// obligation unchanged. Branch and loop joins are F1 work.
    pub const State = struct {
        allocator: std.mem.Allocator,
        obligations: std.ArrayListUnmanaged(Obligation) = .empty,

        pub const Obligation = struct {
            id: u32,
            location: Subject,
            live: bool = true,
        };

        pub fn deinit(self: *State) void {
            self.obligations.deinit(self.allocator);
        }

        pub fn apply(self: *State, record: Record, outcome: Outcome) TransitionError!void {
            try record.validate();
            if (!edgeMatches(record.edge, outcome)) return;
            switch (record.effect) {
                .create => |create| {
                    for (self.obligations.items) |obligation| if (obligation.id == create.obligation_id) return error.DuplicateObligation;
                    if (self.liveAt(create.destination) != null) return error.DestinationOccupied;
                    try self.obligations.append(self.allocator, .{ .id = create.obligation_id, .location = create.destination });
                },
                // Ordinary owner construction changes availability, but introduces
                // no must-settle obligation in this obligation-only model.
                .materialize => |destination| if (self.liveAt(destination) != null) return error.DestinationOccupied,
                .move => |move| try self.transfer(move.source, move.destination),
                // Shared copies retain the source and introduce no must-settle
                // obligation in this obligation-only transition model.
                .copy => |copy| if (self.liveAt(copy.destination) != null) return error.DestinationOccupied,
                .take => |take| try self.transfer(take.source, take.destination),
                .@"return" => |return_effect| try self.transfer(return_effect.source, return_effect.destination),
                .call_argument => |argument| if (argument.mode == .move) try self.transfer(argument.source, argument.destination.?),
                .settle => |settle| {
                    const obligation = self.liveObligationAt(settle.source) orelse {
                        if (self.anyAt(settle.source) != null) return error.AlreadySettled;
                        return error.MissingObligation;
                    };
                    obligation.live = false;
                },
                .replace, .drop => |destination| if (self.liveAt(destination) != null) return error.LiveReplacement,
                .leak => |source| {
                    if (self.liveObligationAt(source)) |obligation| obligation.live = false else if (self.anyAt(source) != null) return error.AlreadySettled;
                },
                .clear => |target| {
                    for (self.obligations.items) |*obligation| {
                        if (!obligation.live or obligation.location != .container_slot) continue;
                        const slot = obligation.location.container_slot;
                        const cleared = target.container_slot;
                        if (slot.item_type_id != cleared.item_type_id) continue;
                        if (slot.place != null and cleared.place != null) {
                            if (sir.sameCheckedPlacePath(slot.place.?, cleared.place.?)) obligation.live = false;
                        } else if (slot.object == cleared.object) {
                            obligation.live = false;
                        }
                    }
                },
                .borrow, .read => {},
            }
        }

        pub fn applyCall(
            self: *State,
            contract: CallContract,
            call: sir.Call,
            metadata: []const sir.ExprMetadataEntry,
            callee: sir.Function,
            trusted: ?CallContract.TrustedAuthority,
            outcome: Outcome,
        ) TransitionError!void {
            try contract.validate(call, metadata, callee, trusted);
            for (contract.arguments) |record| try self.apply(record, .normal);
            for (contract.body_effects) |record| try self.apply(record, .normal);
            for (contract.results) |record| try self.apply(record, outcome);
        }

        pub fn liveAt(self: *State, subject: Subject) ?u32 {
            return if (self.liveObligationAt(subject)) |obligation| obligation.id else null;
        }

        fn anyAt(self: *State, subject: Subject) ?*Obligation {
            for (self.obligations.items) |*obligation| {
                if (sameSubject(obligation.location, subject)) return obligation;
            }
            return null;
        }

        fn liveObligationAt(self: *State, subject: Subject) ?*Obligation {
            for (self.obligations.items) |*obligation| {
                if (obligation.live and sameSubject(obligation.location, subject)) return obligation;
            }
            return null;
        }

        fn transfer(self: *State, source: Subject, destination: Subject) TransitionError!void {
            const obligation = self.liveObligationAt(source) orelse {
                if (self.anyAt(source) != null) return error.AlreadySettled;
                return error.MissingObligation;
            };
            if (self.liveAt(destination) != null) return error.DestinationOccupied;
            obligation.location = destination;
        }
    };

    fn subjectForExpr(metadata: []const sir.ExprMetadataEntry, expr: *const sir.Expr) ?Subject {
        for (metadata) |entry| {
            if (entry.expr != expr) continue;
            if (entry.metadata.temporary_id) |id| return .{ .temporary = id };
            if (entry.metadata.checked_generated_payload_binding) |id| return .{ .generated_payload = id };
            if (entry.metadata.checkedPlacePath()) |place| return .{ .place = place };
            return null;
        }
        return null;
    }

    fn edgeMatches(edge: Edge, outcome: Outcome) bool {
        return switch (edge) {
            .always => true,
            .success => |id| outcome == .success and outcome.success == id,
            .failure => |id| outcome == .failure and outcome.failure == id,
            .active_case => |case| outcome == .active_case and std.meta.eql(outcome.active_case, case),
        };
    }

    fn sameSubject(left: Subject, right: Subject) bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .temporary => |id| id == right.temporary,
            .temporary_projection => |projection| std.meta.eql(projection, right.temporary_projection),
            .temporary_payload => |payload| payload.root == right.temporary_payload.root and
                payload.owner_decl_id == right.temporary_payload.owner_decl_id and
                std.mem.eql(u8, payload.case_name, right.temporary_payload.case_name) and
                payload.result_case == right.temporary_payload.result_case and
                payload.payload_type_id == right.temporary_payload.payload_type_id,
            .return_slot => |id| id == right.return_slot,
            .generated_payload => |id| id == right.generated_payload,
            .call_slot => |slot| std.meta.eql(slot, right.call_slot),
            .indirect_call_slot => |slot| slot.call == right.indirect_call_slot.call and slot.index == right.indirect_call_slot.index,
            .indirect_return_slot => |call| call == right.indirect_return_slot,
            .reference_target => |target| target.reference == right.reference_target.reference and
                target.target_type_id == right.reference_target.target_type_id,
            .reference_projection => |projection| projection.reference == right.reference_projection.reference and
                std.meta.eql(projection.projection, right.reference_projection.projection),
            .closure_slot => |slot| std.meta.eql(slot, right.closure_slot),
            .raw_pointee => |pointee| blk: {
                const other = right.raw_pointee;
                if (pointee.pointer != other.pointer or pointee.pointee_type_id != other.pointee_type_id) break :blk false;
                const steps = pointee.projections orelse &.{};
                const other_steps = other.projections orelse &.{};
                if (steps.len != other_steps.len) break :blk false;
                for (steps, other_steps) |step, other_step| if (!std.meta.eql(step, other_step)) break :blk false;
                break :blk true;
            },
            .container_slot => |slot| blk: {
                const other = right.container_slot;
                if (slot.object != other.object or slot.item_type_id != other.item_type_id or
                    !std.meta.eql(slot.position, other.position) or
                    (slot.place == null) != (other.place == null)) break :blk false;
                if (slot.place) |place| {
                    if (!sir.sameCheckedPlacePath(place, other.place.?)) break :blk false;
                }
                break :blk true;
            },
            .place, .alias_pointee => |place| blk: {
                const other = switch (right) {
                    .place => |value| value,
                    .alias_pointee => |value| value,
                    else => unreachable,
                };
                if (!std.meta.eql(place.root, other.root) or place.non_owning != other.non_owning) break :blk false;
                const steps = place.projections orelse &.{};
                const other_steps = other.projections orelse &.{};
                if (steps.len != other_steps.len) break :blk false;
                for (steps, other_steps) |step, other_step| {
                    if (!std.meta.eql(step, other_step)) break :blk false;
                }
                break :blk true;
            },
        };
    }
};

pub const flow = struct {
    /// One evaluated expression, after its evaluated children. A neutral site is
    /// explicit: it cannot stand in for a missing child or a moving expression.
    pub const Site = sir.EffectSite;

    pub const VerifyError = error{
        MissingEvaluationSite,
        DuplicateEvaluationSite,
        WrongEvaluationOrder,
        InvalidEffectContract,
        InvalidEffectIdentity,
        MissingOwnershipEffect,
        UnsupportedControlFlow,
    };

    pub const FlowError = error{ OutOfMemory, MissingExpressionMetadata, InvalidEvaluationSites, InvalidEffectFlow };

    pub fn collectGlobals(allocator: std.mem.Allocator, module: *const sir.Module) FlowError![]const sir.EffectFlowEvent {
        var events: std.ArrayListUnmanaged(sir.EffectFlowEvent) = .empty;
        errdefer events.deinit(allocator);
        var defers: std.ArrayListUnmanaged(*const sir.Stmt) = .empty;
        defer defers.deinit(allocator);
        for (module.globals) |*global| {
            const init = global.init orelse continue;
            try appendEvent(allocator, &events, .{ .global = global });
            try appendExpr(allocator, module, &events, &defers, init);
        }
        return try events.toOwnedSlice(allocator);
    }

    pub fn verifyGlobals(allocator: std.mem.Allocator, module: *const sir.Module) FlowError!void {
        const expected = try collectGlobals(allocator, module);
        defer allocator.free(expected);
        if (expected.len != module.global_effect_flow.len) return error.InvalidEffectFlow;
        for (expected, module.global_effect_flow) |wanted, actual| {
            if (!std.meta.eql(wanted, actual)) return error.InvalidEffectFlow;
        }
    }

    /// The stored flow is a structural execution plan. Branch and loop markers
    /// delimit alternative paths; a defer body is a template reached on an exit.
    /// Each effect event copies the one record sema attached to its SIR site.
    pub fn collectFunction(allocator: std.mem.Allocator, module: *const sir.Module, function: *const sir.Function) FlowError![]const sir.EffectFlowEvent {
        var events: std.ArrayListUnmanaged(sir.EffectFlowEvent) = .empty;
        errdefer events.deinit(allocator);
        var defers: std.ArrayListUnmanaged(*const sir.Stmt) = .empty;
        defer defers.deinit(allocator);
        try appendStatements(allocator, module, &events, &defers, null, function.body);
        return try events.toOwnedSlice(allocator);
    }

    pub fn verifyFunction(allocator: std.mem.Allocator, module: *const sir.Module, function: *const sir.Function) FlowError!void {
        const expected = try collectFunction(allocator, module, function);
        defer allocator.free(expected);
        if (expected.len != function.effect_flow.len) return error.InvalidEffectFlow;
        for (expected, function.effect_flow) |wanted, actual| {
            if (!std.meta.eql(wanted, actual)) return error.InvalidEffectFlow;
        }
    }

    pub fn verifyModule(allocator: std.mem.Allocator, module: *const sir.Module) FlowError!void {
        try verifyGlobals(allocator, module);
        for (module.functions) |*function| try verifyFunction(allocator, module, function);
    }

    fn appendEvent(allocator: std.mem.Allocator, events: *std.ArrayListUnmanaged(sir.EffectFlowEvent), event: sir.EffectFlowEvent) FlowError!void {
        try events.append(allocator, event);
    }

    fn appendControl(allocator: std.mem.Allocator, events: *std.ArrayListUnmanaged(sir.EffectFlowEvent), stmt: *const sir.Stmt, phase: @FieldType(@FieldType(sir.EffectFlowEvent, "control"), "phase"), case_index: u32) FlowError!void {
        try appendEvent(allocator, events, .{ .control = .{ .statement = stmt, .phase = phase, .case_index = case_index } });
    }

    fn appendDeferredInvocations(allocator: std.mem.Allocator, events: *std.ArrayListUnmanaged(sir.EffectFlowEvent), defers: []const *const sir.Stmt) FlowError!void {
        var index = defers.len;
        while (index > 0) {
            index -= 1;
            try appendControl(allocator, events, defers[index], .defer_invoke, 0);
        }
    }

    fn appendStatements(allocator: std.mem.Allocator, module: *const sir.Module, events: *std.ArrayListUnmanaged(sir.EffectFlowEvent), defers: *std.ArrayListUnmanaged(*const sir.Stmt), loop_base: ?usize, statements: []const sir.Stmt) FlowError!void {
        const scope_base = defers.items.len;
        defer defers.items.len = scope_base;
        for (statements) |*stmt| {
            try appendEvent(allocator, events, .{ .statement = stmt });
            switch (stmt.*) {
                .local => |local| {
                    try appendExpr(allocator, module, events, defers, local.init);
                    if (local.checked_effect) |effect| try appendEvent(allocator, events, .{ .effect = effect });
                },
                .assign => |assign| {
                    try appendExpr(allocator, module, events, defers, assign.value);
                    if (assign.checked_replace) |effect| try appendEvent(allocator, events, .{ .effect = effect });
                    if (assign.checked_transfer) |effect| try appendEvent(allocator, events, .{ .effect = effect });
                },
                .field_assign => |assign| try appendMutationSites(allocator, module, events, defers, &assign.checked_evaluation_sites, assign.checked_evaluation_sites_len),
                .index_assign => |assign| try appendMutationSites(allocator, module, events, defers, &assign.checked_evaluation_sites, assign.checked_evaluation_sites_len),
                .deref_assign => |assign| {
                    try appendExpr(allocator, module, events, defers, assign.pointer);
                    try appendExpr(allocator, module, events, defers, assign.value);
                    if (assign.checked_replace) |effect| try appendEvent(allocator, events, .{ .effect = effect });
                    if (assign.checked_transfer) |effect| try appendEvent(allocator, events, .{ .effect = effect });
                },
                .deref_field_assign => |assign| {
                    try appendExpr(allocator, module, events, defers, assign.pointer);
                    try appendExpr(allocator, module, events, defers, assign.value);
                    if (assign.checked_replace) |effect| try appendEvent(allocator, events, .{ .effect = effect });
                    if (assign.checked_transfer) |effect| try appendEvent(allocator, events, .{ .effect = effect });
                },
                .using_alloc => |scope| {
                    try appendExpr(allocator, module, events, defers, scope.allocator_expr);
                    try appendControl(allocator, events, stmt, .scope_enter, 0);
                    try appendStatements(allocator, module, events, defers, loop_base, scope.body);
                    try appendControl(allocator, events, stmt, .scope_exit, 0);
                },
                .unchecked => |body| {
                    try appendControl(allocator, events, stmt, .scope_enter, 0);
                    try appendStatements(allocator, module, events, defers, loop_base, body);
                    try appendControl(allocator, events, stmt, .scope_exit, 0);
                },
                .asm_stmt => |assembly| for (assembly.inputs) |input| try appendExpr(allocator, module, events, defers, input.value),
                .@"if" => |branch| {
                    try appendExpr(allocator, module, events, defers, branch.condition);
                    try appendControl(allocator, events, stmt, .then_enter, 0);
                    try appendStatements(allocator, module, events, defers, loop_base, branch.then_body);
                    try appendControl(allocator, events, stmt, .else_enter, 0);
                    try appendStatements(allocator, module, events, defers, loop_base, branch.else_body);
                    try appendControl(allocator, events, stmt, .branch_join, 0);
                },
                .@"while" => |loop| {
                    try appendControl(allocator, events, stmt, .loop_header, 0);
                    try appendExpr(allocator, module, events, defers, loop.condition);
                    try appendControl(allocator, events, stmt, .loop_body, 0);
                    try appendStatements(allocator, module, events, defers, defers.items.len, loop.body);
                    try appendControl(allocator, events, stmt, .loop_back, 0);
                    try appendControl(allocator, events, stmt, .loop_exit, 0);
                },
                .@"for" => |loop| {
                    try appendExpr(allocator, module, events, defers, loop.iterable);
                    try appendControl(allocator, events, stmt, .loop_header, 0);
                    try appendControl(allocator, events, stmt, .loop_body, 0);
                    try appendStatements(allocator, module, events, defers, defers.items.len, loop.body);
                    try appendControl(allocator, events, stmt, .loop_back, 0);
                    try appendControl(allocator, events, stmt, .loop_exit, 0);
                },
                .@"switch" => |branch| {
                    try appendExpr(allocator, module, events, defers, branch.value);
                    for (branch.cases, 0..) |case, index| {
                        try appendControl(allocator, events, stmt, .switch_case, @intCast(index));
                        try appendStatements(allocator, module, events, defers, loop_base, case.body);
                    }
                    if (branch.has_else) {
                        try appendControl(allocator, events, stmt, .switch_else, 0);
                        try appendStatements(allocator, module, events, defers, loop_base, branch.else_body);
                    }
                    try appendControl(allocator, events, stmt, .switch_join, 0);
                },
                .@"try" => |attempt| {
                    try appendExpr(allocator, module, events, defers, attempt.expr);
                    if (attempt.expr.* != .@"try") try appendDeferredInvocations(allocator, events, defers.items);
                    try appendControl(allocator, events, stmt, .try_error, 0);
                },
                .@"defer" => |expr| {
                    try appendControl(allocator, events, stmt, .defer_register, 0);
                    try appendControl(allocator, events, stmt, .defer_body, 0);
                    try appendExpr(allocator, module, events, defers, expr);
                    try appendControl(allocator, events, stmt, .defer_end, 0);
                    try defers.append(allocator, stmt);
                },
                .@"continue", .@"break" => {
                    const base = loop_base orelse return error.InvalidEvaluationSites;
                    try appendDeferredInvocations(allocator, events, defers.items[base..]);
                    try appendControl(allocator, events, stmt, if (stmt.* == .@"break") .break_exit else .continue_exit, 0);
                },
                .drop => |drop| {
                    const effect = drop.checked_effect orelse return error.InvalidEvaluationSites;
                    try appendEvent(allocator, events, .{ .effect = effect });
                },
                .expr => |expr| try appendExpr(allocator, module, events, defers, expr),
                .@"return" => |maybe_expr| {
                    if (maybe_expr) |expr| {
                        try appendExpr(allocator, module, events, defers, expr);
                        if (module.metadataForExpr(expr)) |metadata| {
                            if (metadata.checked_sink_effect) |effect| try appendEvent(allocator, events, .{ .effect = effect });
                        }
                    }
                    try appendDeferredInvocations(allocator, events, defers.items);
                    try appendControl(allocator, events, stmt, .return_exit, 0);
                },
                .yield => |maybe_expr| if (maybe_expr) |expr| try appendExpr(allocator, module, events, defers, expr),
            }
        }
        try appendDeferredInvocations(allocator, events, defers.items[scope_base..]);
    }

    fn appendMutationSites(allocator: std.mem.Allocator, module: *const sir.Module, events: *std.ArrayListUnmanaged(sir.EffectFlowEvent), defers: *std.ArrayListUnmanaged(*const sir.Stmt), sites: []const ?sir.MutationEvaluationSite, active_len: u8) FlowError!void {
        if (active_len == 0 or active_len > sites.len) return error.InvalidEvaluationSites;
        for (sites[0..active_len]) |maybe_site| {
            const site = maybe_site orelse return error.InvalidEvaluationSites;
            switch (site) {
                .target_value, .index_value, .assigned_value => |expr| try appendExpr(allocator, module, events, defers, expr),
                .effect => |effect| try appendEvent(allocator, events, .{ .effect = effect }),
            }
        }
    }

    fn appendExpr(allocator: std.mem.Allocator, module: *const sir.Module, events: *std.ArrayListUnmanaged(sir.EffectFlowEvent), defers: *std.ArrayListUnmanaged(*const sir.Stmt), expr: *const sir.Expr) FlowError!void {
        switch (expr.*) {
            .call => |call| {
                if (call.checked_evaluation_sites.len == 0) {
                    for (call.args) |arg| try appendExpr(allocator, module, events, defers, arg.value);
                } else for (call.checked_evaluation_sites) |site| switch (site) {
                    .callee_value, .argument_value => |value| try appendExpr(allocator, module, events, defers, value),
                    .effect => |effect| {
                        if (call.checked_result_effect) |result| {
                            if (std.meta.eql(effect, result)) continue;
                        }
                        if (call.checked_terminal_effect) |terminal| {
                            if (std.meta.eql(effect, terminal)) continue;
                        }
                        try appendEvent(allocator, events, .{ .effect = effect });
                    },
                };
            },
            .indirect_call => |call| {
                if (call.checked_evaluation_sites_len == 0) {
                    try appendExpr(allocator, module, events, defers, call.callee);
                    if (call.checked_arguments) |arguments| {
                        if (arguments.len != call.args.len) return error.InvalidEvaluationSites;
                    }
                    for (call.args, 0..) |arg, index| {
                        try appendExpr(allocator, module, events, defers, arg.value);
                        if (call.checked_arguments) |arguments| {
                            if (arguments[index]) |effect| try appendEvent(allocator, events, .{ .effect = effect });
                        }
                    }
                } else {
                    if (call.checked_evaluation_sites_len > call.checked_evaluation_sites.len) return error.InvalidEvaluationSites;
                    for (call.checked_evaluation_sites[0..call.checked_evaluation_sites_len]) |maybe_site| {
                        const site = maybe_site orelse return error.InvalidEvaluationSites;
                        switch (site) {
                            .callee_value, .argument_value => |value| try appendExpr(allocator, module, events, defers, value),
                            .effect => |effect| try appendEvent(allocator, events, .{ .effect = effect }),
                        }
                    }
                }
            },
            .binary => |binary| {
                try appendExpr(allocator, module, events, defers, binary.left);
                if (binary.op == .@"and" or binary.op == .@"or")
                    try appendEvent(allocator, events, .{ .short_circuit_rhs = expr });
                try appendExpr(allocator, module, events, defers, binary.right);
                if (binary.op == .@"and" or binary.op == .@"or")
                    try appendEvent(allocator, events, .{ .short_circuit_join = expr });
            },
            .@"try" => |attempt| {
                try appendExpr(allocator, module, events, defers, attempt.expr);
                try appendEvent(allocator, events, .{ .try_error = expr });
                try appendDeferredInvocations(allocator, events, defers.items);
                try appendEvent(allocator, events, .{ .try_success = expr });
            },
            .new_owned, .struct_literal => |literal| {
                for (literal.fields) |field| {
                    try appendExpr(allocator, module, events, defers, field.value);
                    if (field.checked_transfer) |effect| try appendEvent(allocator, events, .{ .effect = effect });
                }
            },
            .array_literal, .dense_array_literal => |literal| {
                if (literal.checked_transfers) |transfers| {
                    if (transfers.len != literal.items.len) return error.InvalidEvaluationSites;
                }
                for (literal.items, 0..) |item, index| {
                    try appendExpr(allocator, module, events, defers, item);
                    if (literal.checked_transfers) |transfers| {
                        if (transfers[index]) |effect| try appendEvent(allocator, events, .{ .effect = effect });
                    }
                }
            },
            .tuple_literal => |literal| {
                if (literal.checked_transfers) |transfers| {
                    if (transfers.len != literal.items.len) return error.InvalidEvaluationSites;
                }
                for (literal.items, 0..) |item, index| {
                    try appendExpr(allocator, module, events, defers, item);
                    if (literal.checked_transfers) |transfers| {
                        if (transfers[index]) |effect| try appendEvent(allocator, events, .{ .effect = effect });
                    }
                }
            },
            .sparse_literal => |literal| {
                if (literal.checked_transfers) |transfers| {
                    if (transfers.len != literal.items.len) return error.InvalidEvaluationSites;
                }
                for (literal.items, 0..) |item, index| {
                    try appendExpr(allocator, module, events, defers, item);
                    if (literal.checked_transfers) |transfers| {
                        if (transfers[index]) |effect| try appendEvent(allocator, events, .{ .effect = effect });
                    }
                }
            },
            .sparse_keyed_literal => |literal| {
                if (literal.checked_transfers) |transfers| {
                    if (transfers.len != literal.entries.len) return error.InvalidEvaluationSites;
                }
                for (literal.entries, 0..) |entry, index| {
                    try appendExpr(allocator, module, events, defers, entry.index);
                    try appendExpr(allocator, module, events, defers, entry.value);
                    if (literal.checked_transfers) |transfers| {
                        if (transfers[index]) |effect| try appendEvent(allocator, events, .{ .effect = effect });
                    }
                }
            },
            .sequence_push => |push| {
                try appendExpr(allocator, module, events, defers, push.object);
                try appendExpr(allocator, module, events, defers, push.value);
                if (push.checked_transfer) |effect| try appendEvent(allocator, events, .{ .effect = effect });
            },
            .sparse_insert => |insert| {
                try appendExpr(allocator, module, events, defers, insert.object);
                try appendExpr(allocator, module, events, defers, insert.index);
                try appendExpr(allocator, module, events, defers, insert.value);
                if (insert.checked_replace) |effect| try appendEvent(allocator, events, .{ .effect = effect });
                if (insert.checked_transfer) |effect| try appendEvent(allocator, events, .{ .effect = effect });
            },
            .sync_share_boxed => |share| {
                try appendExpr(allocator, module, events, defers, share.payload);
                if (share.checked_payload_transfer) |effect| try appendEvent(allocator, events, .{ .effect = effect });
            },
            .thread_spawn_boxed => |spawn| {
                try appendExpr(allocator, module, events, defers, spawn.payload);
                if (spawn.checked_payload_transfer) |effect| try appendEvent(allocator, events, .{ .effect = effect });
            },
            .task_group_spawn_boxed => |spawn| {
                try appendExpr(allocator, module, events, defers, spawn.group_raw);
                try appendExpr(allocator, module, events, defers, spawn.entry);
                try appendExpr(allocator, module, events, defers, spawn.payload);
                if (spawn.checked_payload_transfer) |effect| try appendEvent(allocator, events, .{ .effect = effect });
            },
            .task_result_take => |take| {
                try appendExpr(allocator, module, events, defers, take.witness);
                try appendExpr(allocator, module, events, defers, take.pointer);
                if (take.checked_payload_take) |effect| try appendEvent(allocator, events, .{ .effect = effect });
            },
            .closure => |closure| {
                if (closure.checked_transfers) |transfers| {
                    if (transfers.len != closure.captures.len) return error.InvalidEvaluationSites;
                }
                for (closure.captures, 0..) |capture, index| {
                    try appendExpr(allocator, module, events, defers, capture);
                    if (closure.checked_transfers) |transfers| {
                        if (transfers[index]) |effect| try appendEvent(allocator, events, .{ .effect = effect });
                    }
                }
            },
            .union_case => |case| {
                if (case.value) |value| try appendExpr(allocator, module, events, defers, value);
                if (case.checked_transfer) |effect| try appendEvent(allocator, events, .{ .effect = effect });
            },
            inline else => |payload| try appendChildren(allocator, module, events, defers, @TypeOf(payload), payload),
        }
        try appendEvent(allocator, events, .{ .evaluate = expr });
        if (expr.* == .call) {
            if (expr.call.checked_terminal_effect) |effect| try appendEvent(allocator, events, .{ .effect = effect });
            if (expr.call.checked_result_effect) |effect| try appendEvent(allocator, events, .{ .effect = effect });
        }
        const metadata = module.metadataForExpr(expr) orelse return error.MissingExpressionMetadata;
        if (metadata.checked_effect) |effect| try appendEvent(allocator, events, .{ .effect = effect });
        if (expr.* == .indirect_call) {
            if (expr.indirect_call.checked_result_effect) |effect| try appendEvent(allocator, events, .{ .effect = effect });
        }
        if (expr.* == .sync_share_boxed) {
            if (expr.sync_share_boxed.checked_result_effect) |effect| try appendEvent(allocator, events, .{ .effect = effect });
        }
    }

    fn appendChildren(allocator: std.mem.Allocator, module: *const sir.Module, events: *std.ArrayListUnmanaged(sir.EffectFlowEvent), defers: *std.ArrayListUnmanaged(*const sir.Stmt), comptime T: type, value: T) FlowError!void {
        if (comptime T == *sir.Expr or T == *const sir.Expr) {
            try appendExpr(allocator, module, events, defers, value);
            return;
        }
        switch (@typeInfo(T)) {
            .pointer => |pointer| {
                if (comptime pointer.child == u8) return;
                if (pointer.size == .slice) {
                    for (value) |item| try appendChildren(allocator, module, events, defers, pointer.child, item);
                } else if (pointer.size == .one) {
                    try appendChildren(allocator, module, events, defers, pointer.child, value.*);
                }
            },
            .optional => |optional| if (value) |item| try appendChildren(allocator, module, events, defers, optional.child, item),
            .array => |array| for (value) |item| try appendChildren(allocator, module, events, defers, array.child, item),
            .@"struct" => |record| inline for (record.field_names, record.field_types) |name, field_type| try appendChildren(allocator, module, events, defers, field_type, @field(value, name)),
            .@"union" => switch (value) {
                inline else => |payload| try appendChildren(allocator, module, events, defers, @TypeOf(payload), payload),
            },
            else => {},
        }
    }

    /// Checks straight-line expression evaluation order. Control-flow forks and
    /// statement-level destinations are added as E1 advances.
    pub fn verifyLinearExpr(root: *const sir.Expr, metadata: []const sir.ExprMetadataEntry, sites: []const Site) VerifyError!void {
        var cursor: usize = 0;
        try verifyExpr(root, metadata, sites, &cursor);
        if (cursor != sites.len) return error.DuplicateEvaluationSite;
    }

    fn verifyExpr(expr: *const sir.Expr, metadata: []const sir.ExprMetadataEntry, sites: []const Site, cursor: *usize) VerifyError!void {
        switch (expr.*) {
            .binary => |binary| if (binary.op == .@"and" or binary.op == .@"or") return error.UnsupportedControlFlow,
            .@"try" => return error.UnsupportedControlFlow,
            else => {},
        }
        switch (expr.*) {
            inline else => |payload| try verifyChildren(@TypeOf(payload), payload, metadata, sites, cursor),
        }
        if (cursor.* >= sites.len) return error.MissingEvaluationSite;
        const site = sites[cursor.*];
        if (site.expr != expr) return error.WrongEvaluationOrder;
        cursor.* += 1;
        switch (site.action) {
            .neutral => {
                const facts = metadataFor(metadata, expr) orelse return error.MissingEvaluationSite;
                if (facts.consumption.transfer != .copy and facts.semantics.ownership != .plain and
                    facts.semantics.ownership != .borrowed) return error.MissingOwnershipEffect;
            },
            .effect => |record| {
                try record.validate();
                const source = switch (record.effect) {
                    .move => |move| move.source,
                    .take => |take| take.source,
                    .borrow, .read => |subject| subject,
                    else => null,
                };
                if (source) |subject| {
                    const facts = metadataFor(metadata, expr) orelse return error.MissingEvaluationSite;
                    if (!subjectMatchesMetadata(subject, facts, expr)) return error.InvalidEffectIdentity;
                }
            },
        }
    }

    fn verifyChildren(comptime T: type, value: T, metadata: []const sir.ExprMetadataEntry, sites: []const Site, cursor: *usize) VerifyError!void {
        if (comptime T == *sir.Expr or T == *const sir.Expr) {
            try verifyExpr(value, metadata, sites, cursor);
            return;
        }
        switch (@typeInfo(T)) {
            .pointer => |pointer| {
                if (comptime pointer.child == u8) return;
                if (pointer.size == .slice) {
                    for (value) |item| try verifyChildren(pointer.child, item, metadata, sites, cursor);
                } else if (pointer.size == .one) {
                    try verifyChildren(pointer.child, value.*, metadata, sites, cursor);
                }
            },
            .optional => |optional| if (value) |item| try verifyChildren(optional.child, item, metadata, sites, cursor),
            .array => |array| for (value) |item| try verifyChildren(array.child, item, metadata, sites, cursor),
            .@"struct" => |record| inline for (record.field_names, record.field_types) |name, field_type| try verifyChildren(field_type, @field(value, name), metadata, sites, cursor),
            .@"union" => switch (value) {
                inline else => |payload| try verifyChildren(@TypeOf(payload), payload, metadata, sites, cursor),
            },
            else => {},
        }
    }

    fn metadataFor(metadata: []const sir.ExprMetadataEntry, expr: *const sir.Expr) ?sir.ExprMetadata {
        for (metadata) |entry| if (entry.expr == expr) return entry.metadata;
        return null;
    }

    fn subjectMatchesMetadata(subject: checked_records.Subject, facts: sir.ExprMetadata, expr: *const sir.Expr) bool {
        return switch (subject) {
            .temporary => |id| facts.temporary_id == id,
            .temporary_projection => false,
            .temporary_payload => false,
            .return_slot => false,
            .generated_payload => |id| facts.checked_generated_payload_binding == id,
            .call_slot => false,
            .indirect_call_slot, .indirect_return_slot => false,
            .reference_target => |target| expr.* == .ref_load and target.reference == expr.ref_load and
                target.target_type_id == facts.type_id,
            .reference_projection => |projection| expr.* == .ref_field_expr and
                projection.reference == expr.ref_field_expr.object and
                projection.projection.result_type_id == facts.type_id,
            .closure_slot => false,
            .alias_pointee => false,
            .raw_pointee => false,
            .container_slot => false,
            .place => |place| blk: {
                const checked = facts.checkedPlacePath() orelse break :blk false;
                if (!std.meta.eql(place.root, checked.root) or place.non_owning != checked.non_owning) break :blk false;
                const steps = place.projections orelse &.{};
                const checked_steps = checked.projections orelse &.{};
                break :blk std.meta.eql(steps, checked_steps);
            },
        };
    }
};

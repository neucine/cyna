const std = @import("std");
const sir = @import("sir.zig");
const effects = @import("effects.zig");

pub fn Owner(comptime host: anytype) type {
    return struct {
        const SemaContext = host.SemaContext;
        const SemaError = host.SemaError;
        const CheckedEffects = effects.Owner(host);

        pub const Pending = struct {
            globals: *std.ArrayListUnmanaged(sir.Global),
            asm_consts: *std.ArrayListUnmanaged(sir.AsmConst),
            enums: *std.ArrayListUnmanaged(sir.EnumDecl),
            unions: *std.ArrayListUnmanaged(sir.UnionDecl),
            structs: *std.ArrayListUnmanaged(sir.StructDecl),
            functions: *std.ArrayListUnmanaged(sir.Function),
            tests: *std.ArrayListUnmanaged(sir.InlineTest),
        };

        pub fn finish(context: *SemaContext, allocator: std.mem.Allocator, pending: Pending) SemaError!sir.Module {
            var phase: @import("../session.zig").Scope = if (context.options.timing_session) |timing_session| timing_session.start("sema.finalize.validate", &.{}) else .{};
            defer phase.end();
            errdefer phase.endError();
            if (type_validation.validate(context.allocator, &context.canonical.types.?, pending.globals.items, pending.unions.items, pending.structs.items, pending.functions.items)) |_| {} else |err| {
                return err;
            }
            phase.end();
            phase = if (context.options.timing_session) |timing_session| timing_session.start("sema.finalize.retain", &.{}) else .{};

            var output = sir.Module{ .globals = &.{}, .enums = &.{}, .unions = &.{}, .structs = &.{}, .functions = &.{} };
            errdefer output.deinit(allocator);
            output.generic_requirements = try retainMethodUseRecords(allocator, context.generic.method_use_records.items);
            // Definition-site bodies are analyzed inside sema and never emitted, so the
            // contract stand-ins and trial bodies are released before the module leaves.
            context.generic.finishCheckedRequirements(allocator);
            output.globals = try pending.globals.toOwnedSlice(allocator);
            output.asm_consts = try pending.asm_consts.toOwnedSlice(allocator);
            output.enums = try pending.enums.toOwnedSlice(allocator);
            output.unions = try pending.unions.toOwnedSlice(allocator);
            output.structs = try pending.structs.toOwnedSlice(allocator);
            output.functions = try pending.functions.toOwnedSlice(allocator);
            output.tests = try pending.tests.toOwnedSlice(allocator);
            output.generated_strings = try context.output.generated_strings.toOwnedSlice(allocator);
            output.expr_metadata = try context.expr_metadata.toOwnedSlice(allocator);
            try retainLiveExprMetadata(allocator, &output);
            phase.end();
            phase = if (context.options.timing_session) |timing_session| timing_session.start("sema.finalize.effects", &.{}) else .{};
            try CheckedEffects.emit(context, allocator, &output);
            phase.end();
            phase = if (context.options.timing_session) |timing_session| timing_session.start("sema.finalize.clone_types", &.{}) else .{};
            output.canonical_types = context.canonical.types.?.clone(allocator) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidTypeId => return error.SemanticFailed,
            };
            phase.end();
            phase = if (context.options.timing_session) |timing_session| timing_session.start("sema.finalize.verify", &.{}) else .{};
            output.verifyRetainedGenericRequirementIdentities(&context.declarations.registry.?) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.SemanticFailed,
            };
            phase.end();
            return output;
        }

        /// The emitted module keeps its own copy of every method-use record. The
        /// spelling strings a record carries come from the declaration registry, which
        /// is released when the semantic pass ends, so the module cannot point at them.
        fn freeRequirementStrings(allocator: std.mem.Allocator, requirement: sir.GenericRequirement) void {
            allocator.free(requirement.module_name);
            if (requirement.owner) |owner| allocator.free(owner);
            allocator.free(requirement.declaration);
            allocator.free(requirement.parameter);
            if (requirement.declared_protocol) |protocol| {
                allocator.free(protocol.module_name);
                allocator.free(protocol.name);
            }
        }

        fn retainMethodUseRecords(allocator: std.mem.Allocator, records: []const sir.GenericRequirement) SemaError![]sir.GenericRequirement {
            const copy = try allocator.alloc(sir.GenericRequirement, records.len);
            var filled: usize = 0;
            errdefer {
                for (copy[0..filled]) |stored| freeRequirementStrings(allocator, stored);
                allocator.free(copy);
            }
            for (records, 0..) |requirement, index| {
                // The record is assembled field by field from empty strings, so every
                // string freed when a part-way failure unwinds this loop is one this
                // loop allocated, and every borrowed spelling stays untouched.
                var stored: sir.GenericRequirement = .{
                    .projected = requirement.projected,
                    .declaration_id = requirement.declaration_id,
                    .module_name = "",
                    .owner = null,
                    .declaration = "",
                    .parameter = "",
                    .parameter_definition_offset = requirement.parameter_definition_offset,
                    .parameter_id = requirement.parameter_id,
                    .operation = requirement.operation,
                    .source_offset = requirement.source_offset,
                    .use_id = requirement.use_id,
                    .declared_protocol = null,
                };
                errdefer freeRequirementStrings(allocator, stored);
                stored.module_name = try allocator.dupe(u8, requirement.module_name);
                if (requirement.owner) |owner| stored.owner = try allocator.dupe(u8, owner);
                stored.declaration = try allocator.dupe(u8, requirement.declaration);
                stored.parameter = try allocator.dupe(u8, requirement.parameter);
                if (requirement.declared_protocol) |protocol| {
                    var stored_protocol = protocol;
                    stored_protocol.module_name = try allocator.dupe(u8, protocol.module_name);
                    errdefer allocator.free(stored_protocol.module_name);
                    stored_protocol.name = try allocator.dupe(u8, protocol.name);
                    errdefer allocator.free(stored_protocol.name);
                    stored.declared_protocol = stored_protocol;
                }
                copy[index] = stored;
                filled += 1;
            }
            return copy;
        }

        fn retainLiveExprMetadata(allocator: std.mem.Allocator, module: *sir.Module) SemaError!void {
            const previous = module.expr_metadata;
            var live_exprs = try module.liveExprSet(allocator);
            defer live_exprs.deinit(allocator);
            var count: usize = 0;
            for (previous) |entry| if (live_exprs.contains(entry.expr)) {
                count += 1;
            };
            const live = try allocator.alloc(sir.ExprMetadataEntry, count);
            var cursor: usize = 0;
            for (previous) |entry| {
                if (live_exprs.contains(entry.expr)) {
                    live[cursor] = entry;
                    cursor += 1;
                } else if (entry.metadata.checked_place_projections) |projections| {
                    allocator.free(projections);
                }
            }
            module.expr_metadata = live;
            module.expr_metadata_retained = true;
            allocator.free(previous);
        }
    };
}
const semantic_types = @import("types.zig");

pub const type_validation = struct {
    pub const Error = error{ SemanticFailed, OutOfMemory };

    const State = struct {
        allocator: std.mem.Allocator,
        canonical_types: *const semantic_types.TypeInterner,
    };

    pub fn validate(
        allocator: std.mem.Allocator,
        canonical_types: *const semantic_types.TypeInterner,
        globals: []const sir.Global,
        unions: []const sir.UnionDecl,
        structs: []const sir.StructDecl,
        functions: []const sir.Function,
    ) Error!void {
        const state: State = .{ .allocator = allocator, .canonical_types = canonical_types };
        var visited: std.AutoHashMapUnmanaged(*const sir.Expr, SirExprVisitState) = .empty;
        defer visited.deinit(allocator);

        for (globals) |global| try validateSirTypeId(&state, global.type_id);
        for (unions) |decl| {
            for (decl.fields) |field| try validateSirTypeId(&state, field.type_id);
        }
        for (structs) |decl| {
            for (decl.fields) |field| try validateSirTypeId(&state, field.type_id);
        }
        for (functions) |function| {
            for (function.params) |param| try validateSirTypeId(&state, param.type_id);
            try validateSirTypeId(&state, function.return_type_id);
            try validateSirLocalTypeIds(&state, &visited, function.body);
        }
    }

    const SirExprVisitState = enum {
        visiting,
        complete,
    };

    fn validateSirLocalTypeIds(
        state: *const State,
        visited: *std.AutoHashMapUnmanaged(*const sir.Expr, SirExprVisitState),
        statements: []const sir.Stmt,
    ) Error!void {
        for (statements) |stmt| switch (stmt) {
            .local => |local| {
                try validateSirTypeId(state, local.type_id);
                try validateSirExprTypeIds(state, visited, local.init);
            },
            .assign => |assign| try validateSirExprTypeIds(state, visited, assign.value),
            .field_assign => |assign| {
                try validateSirExprTypeIds(state, visited, assign.value);
                if (assign.capture) |capture| try validateSirTypeId(state, capture.type_id);
            },
            .index_assign => |assign| {
                try validateSirExprTypeIds(state, visited, assign.object);
                try validateSirExprTypeIds(state, visited, assign.index);
                try validateSirExprTypeIds(state, visited, assign.value);
            },
            .deref_assign => |assign| {
                try validateSirExprTypeIds(state, visited, assign.pointer);
                try validateSirExprTypeIds(state, visited, assign.value);
            },
            .deref_field_assign => |assign| {
                try validateSirExprTypeIds(state, visited, assign.pointer);
                try validateSirExprTypeIds(state, visited, assign.value);
            },
            .using_alloc => |using_alloc| {
                try validateSirExprTypeIds(state, visited, using_alloc.allocator_expr);
                try validateSirLocalTypeIds(state, visited, using_alloc.body);
            },
            .unchecked => |body| try validateSirLocalTypeIds(state, visited, body),
            .@"if" => |if_stmt| {
                try validateSirExprTypeIds(state, visited, if_stmt.condition);
                if (if_stmt.capture_type_id != null) try validateSirTypeId(state, if_stmt.capture_type_id);
                try validateSirLocalTypeIds(state, visited, if_stmt.then_body);
                try validateSirLocalTypeIds(state, visited, if_stmt.else_body);
            },
            .@"while" => |while_stmt| {
                try validateSirExprTypeIds(state, visited, while_stmt.condition);
                try validateSirLocalTypeIds(state, visited, while_stmt.body);
            },
            .@"for" => |for_stmt| {
                try validateSirTypeId(state, for_stmt.item_type_id);
                try validateSirTypeId(state, for_stmt.iterator_state_type_id);
                if (for_stmt.iterator_cursor_type_id != null) try validateSirTypeId(state, for_stmt.iterator_cursor_type_id);
                try validateSirExprTypeIds(state, visited, for_stmt.iterable);
                try validateSirLocalTypeIds(state, visited, for_stmt.body);
            },
            .@"switch" => |switch_stmt| {
                try validateSirTypeId(state, switch_stmt.subject_type_id);
                try validateSirExprTypeIds(state, visited, switch_stmt.value);
                for (switch_stmt.cases) |case| try validateSirLocalTypeIds(state, visited, case.body);
                try validateSirLocalTypeIds(state, visited, switch_stmt.else_body);
            },
            .@"try" => |attempt| try validateSirExprTypeIds(state, visited, attempt.expr),
            .@"defer", .expr => |expr| try validateSirExprTypeIds(state, visited, expr),
            .@"return" => |maybe_expr| if (maybe_expr) |expr| try validateSirExprTypeIds(state, visited, expr),
            .asm_stmt => |asm_stmt| {
                for (asm_stmt.inputs) |input| try validateSirExprTypeIds(state, visited, input.value);
            },
            else => {},
        };
    }

    fn validateSirExprTypeIds(
        state: *const State,
        visited: *std.AutoHashMapUnmanaged(*const sir.Expr, SirExprVisitState),
        expr: *const sir.Expr,
    ) Error!void {
        const visit_entry = try visited.getOrPut(state.allocator, expr);
        if (visit_entry.found_existing) {
            return switch (visit_entry.value_ptr.*) {
                .visiting => error.SemanticFailed,
                .complete => {},
            };
        }
        visit_entry.value_ptr.* = .visiting;
        errdefer _ = visited.remove(expr);

        switch (expr.*) {
            .@"try" => |try_expr| {
                try validateSirTypeId(state, try_expr.result_ok_type_id);
                try validateSirTypeId(state, try_expr.result_err_type_id);
                try validateSirExprTypeIds(state, visited, try_expr.expr);
            },
            .union_case => |case| {
                if (case.result_ok_type_id != null) try validateSirTypeId(state, case.result_ok_type_id);
                if (case.result_err_type_id != null) try validateSirTypeId(state, case.result_err_type_id);
                if (case.value) |value| try validateSirExprTypeIds(state, visited, value);
            },
            .is_test => |is_test| try validateSirExprTypeIds(state, visited, is_test.subject),
            .cast => |cast| {
                try validateSirTypeId(state, cast.target_type_id);
                try validateSirExprTypeIds(state, visited, cast.subject);
            },
            .closure => |closure| for (closure.captures) |capture| try validateSirExprTypeIds(state, visited, capture),
            .thread_spawn_boxed => |spawn| {
                try validateSirTypeId(state, spawn.payload_type_id);
                try validateSirTypeId(state, spawn.return_type_id);
                try validateSirExprTypeIds(state, visited, spawn.payload);
            },
            .task_group_spawn_boxed => |spawn| {
                try validateSirTypeId(state, spawn.payload_type_id);
                try validateSirTypeId(state, spawn.result_type_id);
                try validateSirTypeId(state, spawn.return_type_id);
                try validateSirExprTypeIds(state, visited, spawn.group_raw);
                try validateSirExprTypeIds(state, visited, spawn.entry);
                try validateSirExprTypeIds(state, visited, spawn.payload);
            },
            .task_result_take => |take| {
                try validateSirTypeId(state, take.value_type_id);
                try validateSirTypeId(state, take.return_type_id);
                try validateSirExprTypeIds(state, visited, take.witness);
                try validateSirExprTypeIds(state, visited, take.pointer);
            },
            .sync_share_boxed => |share| {
                try validateSirTypeId(state, share.payload_type_id);
                try validateSirTypeId(state, share.return_type_id);
                try validateSirExprTypeIds(state, visited, share.payload);
            },
            .closure_capture => |capture| try validateSirTypeId(state, capture.type_id),
            .ref_field_expr => |field| try validateSirExprTypeIds(state, visited, field.object),
            .ref_index_local => |index| try validateSirExprTypeIds(state, visited, index.index),
            .ref_index_path_local => |path| {
                for (path.steps) |step| switch (step) {
                    .field => {},
                    .index => |index| try validateSirExprTypeIds(state, visited, index),
                };
                try validateSirExprTypeIds(state, visited, path.index);
            },
            .ref_path_local, .take_path_local => |path| {
                for (path.steps) |step| switch (step) {
                    .field => {},
                    .index => |index| try validateSirExprTypeIds(state, visited, index),
                };
            },
            .ref_load, .test_assert, .sequence_len, .sequence_clear, .sparse_len, .sparse_clear, .sparse_indices, .sequence_pop, .string_len, .string_is_empty, .string_bytes, .string_from, .slice_len => |child| try validateSirExprTypeIds(state, visited, child),
            .ref_raw_deref, .raw_deref => |deref| try validateSirExprTypeIds(state, visited, deref.expr),
            .unary => |unary| try validateSirExprTypeIds(state, visited, unary.expr),
            .binary => |binary| {
                try validateSirExprTypeIds(state, visited, binary.left);
                try validateSirExprTypeIds(state, visited, binary.right);
            },
            .call => |call| for (call.args) |arg| switch (arg) {
                .value => |value| try validateSirExprTypeIds(state, visited, value),
            },
            .indirect_call => |call| {
                try validateSirTypeId(state, call.return_type_id);
                try validateSirExprTypeIds(state, visited, call.callee);
                for (call.args) |arg| switch (arg) {
                    .value => |value| try validateSirExprTypeIds(state, visited, value),
                };
            },
            .builtin_print => |print| for (print.parts) |part| switch (part) {
                .literal => {},
                .value => |value| try validateSirExprTypeIds(state, visited, value.expr),
            },
            .interpolated_string => |parts| for (parts) |part| switch (part) {
                .literal => {},
                .value => |value| try validateSirExprTypeIds(state, visited, value.expr),
            },
            .sequence_push => |push| {
                try validateSirExprTypeIds(state, visited, push.object);
                try validateSirExprTypeIds(state, visited, push.value);
            },
            .sparse_insert => |insert| {
                try validateSirExprTypeIds(state, visited, insert.object);
                try validateSirExprTypeIds(state, visited, insert.index);
                try validateSirExprTypeIds(state, visited, insert.value);
            },
            .sparse_contains_index => |contains| {
                try validateSirExprTypeIds(state, visited, contains.object);
                try validateSirExprTypeIds(state, visited, contains.index);
            },
            .sparse_take => |take| {
                try validateSirExprTypeIds(state, visited, take.object);
                try validateSirExprTypeIds(state, visited, take.index);
            },
            .sequence_reserve => |reserve| {
                try validateSirExprTypeIds(state, visited, reserve.object);
                try validateSirExprTypeIds(state, visited, reserve.capacity);
            },
            .string_starts_with, .string_ends_with, .string_contains, .string_find, .string_rfind => |contains| {
                try validateSirExprTypeIds(state, visited, contains.object);
                try validateSirExprTypeIds(state, visited, contains.value);
            },
            .string_slice => |slice| {
                try validateSirExprTypeIds(state, visited, slice.object);
                try validateSirExprTypeIds(state, visited, slice.start);
                try validateSirExprTypeIds(state, visited, slice.end);
            },
            .slice_range => |slice| {
                try validateSirExprTypeIds(state, visited, slice.object);
                if (slice.start) |start| try validateSirExprTypeIds(state, visited, start);
                if (slice.end) |end| try validateSirExprTypeIds(state, visited, end);
            },
            .index, .borrowed_index => |index| {
                try validateSirExprTypeIds(state, visited, index.object);
                try validateSirExprTypeIds(state, visited, index.index);
            },
            .take_index_local => |index| try validateSirExprTypeIds(state, visited, index.index),
            .take_index_path_local => |path| {
                for (path.steps) |step| switch (step) {
                    .field => {},
                    .index => |index| try validateSirExprTypeIds(state, visited, index),
                };
                try validateSirExprTypeIds(state, visited, path.index);
            },
            .array_literal, .dense_array_literal => |literal| {
                try validateSirTypeId(state, literal.item_type_id);
                for (literal.items) |item| try validateSirExprTypeIds(state, visited, item);
            },
            .tuple_literal => |literal| {
                try validateSirTypeId(state, literal.type_id);
                for (literal.items) |item| try validateSirExprTypeIds(state, visited, item);
            },
            .array_default => |array| try validateSirTypeId(state, array.item_type_id),
            .new_array => |array| {
                try validateSirTypeId(state, array.item_type_id);
                try validateSirExprTypeIds(state, visited, array.len);
            },
            .new_sparse => |storage| {
                try validateSirTypeId(state, storage.item_type_id);
                try validateSirExprTypeIds(state, visited, storage.capacity);
            },
            .sparse_literal => |literal| {
                try validateSirTypeId(state, literal.item_type_id);
                for (literal.items) |item| try validateSirExprTypeIds(state, visited, item);
            },
            .sparse_keyed_literal => |literal| {
                try validateSirTypeId(state, literal.item_type_id);
                for (literal.entries) |entry| {
                    try validateSirExprTypeIds(state, visited, entry.index);
                    try validateSirExprTypeIds(state, visited, entry.value);
                }
            },
            .new_owned, .struct_literal => |literal| for (literal.fields) |field| try validateSirExprTypeIds(state, visited, field.value),
            .asm_expr => |asm_expr| {
                try validateSirTypeId(state, asm_expr.target_type_id);
                if (asm_expr.inout) |inout| try validateSirExprTypeIds(state, visited, inout.value);
                for (asm_expr.inputs) |input| try validateSirExprTypeIds(state, visited, input.value);
            },
            .field, .borrowed_field => |field| try validateSirExprTypeIds(state, visited, field.object),
            .tuple_field => |field| {
                try validateSirTypeId(state, field.tuple_type_id);
                try validateSirExprTypeIds(state, visited, field.object);
            },
            .union_field, .borrowed_union_field => |field| try validateSirExprTypeIds(state, visited, field.object),
            else => {},
        }
        visited.getPtr(expr).?.* = .complete;
    }

    fn validateSirTypeId(state: *const State, maybe_type_id: ?sir.TypeId) Error!void {
        const type_id = maybe_type_id orelse return error.SemanticFailed;
        _ = state.canonical_types.get(type_id) catch return error.SemanticFailed;
    }
};

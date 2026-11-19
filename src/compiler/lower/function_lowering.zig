const std = @import("std");
const sir = @import("../sema/sir.zig");
const identity = @import("../sema/identity.zig");
const language_contracts = @import("../language_contracts.zig");
const lir = @import("lir.zig");
const errors = @import("errors.zig");
const LowerError = errors.Error;

// Function and control-flow lowering interface.
pub fn lowerFunction(self: anytype, sir_fn: sir.Function) LowerError!lir.Function {
    defer self.deinit();
    self.current_module = sir_fn.module_name;

    const params = try lowerParams(self, sir_fn.params);
    const return_type = try lowerFunctionReturnType(self, sir_fn);

    self.func = .{
        .module_name = sir_fn.module_name,
        .name = try self.mb.emittedFunctionName(sir_fn.module_name, sir_fn.owner, sir_fn.name, sir_fn.abi_name, sir_fn.calling_convention == .c, sir_fn.is_test_entry),
        .abi_name = sir_fn.abi_name,
        .is_extern = sir_fn.is_extern,
        .is_export = sir_fn.is_export,
        .is_test_entry = sir_fn.is_test_entry,
        .calling_convention = switch (sir_fn.calling_convention) {
            .cyna => .cyna,
            .c => .c,
        },
        .params = params,
        .return_type = return_type,
        .locals = &.{},
        .ownership_trace = &.{},
        .blocks = &.{},
        .entry = 0,
        .debug_source_path = if (self.mb.resolveDebugSourcePath(sir_fn.module_name)) |path| try self.mb.allocator.dupe(u8, path) else null,
        .debug_line = @intCast(sir_fn.debug_token.line),
        .debug_column = @intCast(sir_fn.debug_token.column),
    };
    errdefer self.mb.allocator.free(self.func.params);
    errdefer if (self.func.debug_source_path) |path| self.mb.allocator.free(path);

    if (self.mb.types.items[return_type] == .result) {
        self.result_return_type = return_type;
        self.result_return_error_type_id = switch ((try self.mb.canonicalTypeNode(sir_fn.return_type_id)).*) {
            .result => |result| result.err,
            else => return error.LowerInvariantViolation,
        };
    }

    if (sir_fn.is_extern) {
        self.func.locals = try self.locals_list.toOwnedSlice(self.mb.allocator);
        self.func.ownership_trace = try self.ownership.takeTrace(self.mb.allocator);
        self.func.blocks = try self.blocks.toOwnedSlice(self.mb.allocator);
        return self.func;
    }

    const entry = try self.beginBlock("bb0");
    self.func.entry = entry;
    self.current_block = entry;

    try bindParams(self, sir_fn, params);
    try lowerStmtList(self, sir_fn.body);

    if (self.currentBlock().terminator == .none) {
        const implicit_void_result = switch (self.mb.types.items[return_type]) {
            .result => |result| self.mb.types.items[result.ok] == .void,
            else => false,
        };
        if (self.mb.types.items[return_type] == .void or implicit_void_result) {
            try @TypeOf(self.*).emitDefersFrom(self, 0, "return");
            try @TypeOf(self.*).emitAutoDropsFrom(self, 0, "return");
            const value = if (implicit_void_result)
                try self.emit(.{ .make_result = .{ .is_err = false, .payload = null } }, return_type)
            else
                null;
            try self.endBlock(.{ .@"return" = value });
        } else {
            return LowerError.UnterminatedBlock;
        }
    }

    self.func.locals = try self.locals_list.toOwnedSlice(self.mb.allocator);
    self.func.ownership_trace = try self.ownership.takeTrace(self.mb.allocator);
    self.func.blocks = try self.blocks.toOwnedSlice(self.mb.allocator);
    return self.func;
}

pub fn lowerFunctionReturnType(self: anytype, sir_fn: sir.Function) LowerError!lir.TypeId {
    return self.mb.lowerCanonicalType(sir_fn.return_type_id);
}

pub fn lowerParams(self: anytype, params: []const sir.Param) LowerError![]lir.Param {
    const out = try self.mb.allocator.alloc(lir.Param, params.len);
    errdefer self.mb.allocator.free(out);
    for (params, out) |param, *dst| {
        dst.* = .{
            .name = param.name,
            .ty = try lowerParamType(self, param),
        };
    }
    return out;
}

pub fn lowerParamType(self: anytype, param: sir.Param) LowerError!lir.TypeId {
    return self.mb.lowerCanonicalType(param.type_id);
}

pub fn bindParams(self: anytype, sir_fn: sir.Function, params: []const lir.Param) LowerError!void {
    for (sir_fn.params, params, 0..) |sir_param, param, i| {
        const local = try self.defineLocal(sir_param.name, param.ty);
        if ((try self.mb.canonicalTypeNode(sir_param.type_id)).* == .ref_) try self.setLocalReadThroughAlias(sir_param.name, true);
        const param_value = try self.emit(.{ .param_ref = @intCast(i) }, param.ty);
        try self.emitVoid(.{ .store = .{
            .ptr = local.ptr_value,
            .value = param_value,
        } });
        self.markCleanupActive(local);
    }
}

pub fn lowerStmtList(self: anytype, body: []const sir.Stmt) LowerError!void {
    const defer_start = self.defers.items.len;
    const cleanup_start = self.ownership.cleanup_entries.items.len;
    const restore_start = self.scope_restores.items.len;
    defer {
        self.restoreLocalsFrom(restore_start);
        self.scope_restores.items.len = restore_start;
        self.freeCleanupEntriesFrom(cleanup_start);
        self.ownership.cleanup_entries.items.len = cleanup_start;
        self.defers.items.len = defer_start;
    }

    for (body) |stmt| {
        if (self.currentBlock().terminator != .none) break;
        try lowerStmt(self, stmt);
    }

    if (self.currentBlock().terminator == .none) {
        try @TypeOf(self.*).emitDefersFrom(self, defer_start, "scope_exit");
        try @TypeOf(self.*).emitAutoDropsFrom(self, cleanup_start, "scope_exit");
    }
}

pub fn lowerStmt(self: anytype, stmt: sir.Stmt) LowerError!void {
    switch (stmt) {
        .local => |local| {
            _ = try self.mb.requireExprSink(local.init, .initialize);
            const ty = try @TypeOf(self.*).lowerLocalType(self, local);
            if (local.binding_mode == .projected) {
                const checked = local.projected_place orelse return error.LowerInvariantViolation;
                if (!checked.non_owning or local.checked_effect != null) return error.LowerInvariantViolation;
                const place = try @TypeOf(self.*).lowerAddressableBorrowedProjectionPlacePointer(self, local.init);
                if (!self.mb.typeIdsEqual(place.ty, ty)) return error.LowerInvariantViolation;
                try self.defineProjectedLocal(local.name, place.ty, place.ptr_value);
                return;
            }
            var slot = try self.defineLocal(local.name, ty);
            if ((try self.mb.canonicalTypeNode(local.type_id)).* == .ref_) try self.setLocalReadThroughAlias(local.name, true);
            if (local.init.* == .from_raw) {
                const raw = local.init.from_raw;
                const raw_ptr = try self.lowerExpr(raw.expr);
                const raw_ty = try @TypeOf(self.*).lowerExprType(self, raw.expr);
                switch (self.mb.types.items[raw_ty]) {
                    .pointer => |pointee| if (pointee != ty) return error.LowerInvariantViolation,
                    else => return error.LowerInvariantViolation,
                }
                const init_v = try self.emit(if (raw.is_volatile) .{ .volatile_load = raw_ptr } else .{ .load = raw_ptr }, ty);
                try self.emitVoid(.{ .store = .{ .ptr = slot.ptr_value, .value = init_v } });
                slot = try self.attachHeapCleanup(local.name, slot, raw_ptr);
            } else {
                const init_v = try @TypeOf(self.*).lowerExprForTarget(self, local.init, ty);
                try @TypeOf(self.*).captureExprValueInto(self, slot.ptr_value, local.init, init_v, ty);
            }
            self.markCleanupActive(slot);
        },
        .assign => |assign| {
            _ = try self.mb.requireExprSink(assign.value, .replace);
            if (self.getGlobalInfo(assign.name)) |global| {
                const global_ptr = try self.emitGlobalSymbolAddr(global, global.ty);
                const value = try @TypeOf(self.*).lowerExprForTarget(self, assign.value, global.ty);
                try @TypeOf(self.*).storeWithCleanup(self, global_ptr, assign.value, value, global.ty, false);
                return;
            }

            const slot = try self.getLocal(assign.name);
            const value = try @TypeOf(self.*).lowerExprForTarget(self, assign.value, slot.ty);
            if (slot.read_through_alias) {
                const pointee_ty = try self.pointerPointee(slot.ty) orelse return error.LowerInvariantViolation;
                const target_ptr = try self.emit(.{ .load = slot.ptr_value }, slot.ty);
                try @TypeOf(self.*).storeWithCleanup(self, target_ptr, assign.value, value, pointee_ty, false);
            } else {
                if (try @TypeOf(self.*).typeNeedsDrop(self, slot.ty)) {
                    try @TypeOf(self.*).recordOwnershipTrace(self, "rebind_drop {s}", .{assign.name});
                }
                try @TypeOf(self.*).storeWithCleanup(self, slot.ptr_value, assign.value, value, slot.ty, try @TypeOf(self.*).typeNeedsDrop(self, slot.ty));
                self.markCleanupActive(slot);
            }
        },
        .field_assign => |assign| {
            _ = try self.mb.requireExprSink(assign.value, .replace);
            try @TypeOf(self.*).lowerFieldAssignStmt(self, assign);
        },
        .index_assign => |assign| {
            _ = try self.mb.requireExprSink(assign.value, .replace);
            try @TypeOf(self.*).lowerIndexAssignStmt(self, assign);
        },
        .deref_assign => |assign| {
            _ = try self.mb.requireExprSink(assign.value, if (assign.is_init) .initialize else .replace);
            try @TypeOf(self.*).lowerDerefAssignStmt(self, assign);
        },
        .deref_field_assign => |assign| {
            _ = try self.mb.requireExprSink(assign.value, .replace);
            try @TypeOf(self.*).lowerDerefFieldAssignStmt(self, assign);
        },
        .unchecked => |body| {
            try lowerStmtList(self, body);
        },
        .asm_stmt => |asm_stmt| {
            const input_names = try self.mb.allocator.alloc([]const u8, asm_stmt.inputs.len);
            errdefer self.mb.allocator.free(input_names);
            const input_constraints = try self.mb.allocator.alloc(lir.AsmConstraint, asm_stmt.inputs.len);
            errdefer self.mb.allocator.free(input_constraints);
            const args = try self.mb.allocator.alloc(lir.ValueId, asm_stmt.inputs.len);
            errdefer self.mb.allocator.free(args);
            for (asm_stmt.inputs, 0..) |input, i| {
                input_names[i] = input.name;
                input_constraints[i] = @TypeOf(self.*).lowerAsmConstraint(input.constraint);
                args[i] = try self.lowerExpr(input.value);
            }
            const lines = try self.mb.allocator.alloc([]const u8, asm_stmt.lines.len);
            errdefer self.mb.allocator.free(lines);
            @memcpy(lines, asm_stmt.lines);
            const clobbers = try self.mb.allocator.alloc(lir.AsmClobber, asm_stmt.clobbers.len);
            var clobber_count: usize = 0;
            errdefer {
                for (clobbers[0..clobber_count]) |clobber| clobber.deinit(self.mb.allocator);
                self.mb.allocator.free(clobbers);
            }
            for (asm_stmt.clobbers, 0..) |clobber, i| {
                clobbers[i] = switch (clobber) {
                    .memory => .memory,
                    .flags => .flags,
                    .register => |name| .{ .register = try self.mb.allocator.dupe(u8, name) },
                };
                clobber_count = i + 1;
            }
            try self.emitVoid(.{ .inline_asm = .{
                .lines = lines,
                .output = null,
                .input_names = input_names,
                .input_constraints = input_constraints,
                .args = args,
                .clobbers = clobbers,
                .is_volatile = asm_stmt.is_volatile,
            } });
        },
        .expr => |expr| {
            const cleanup_start = self.ownership.cleanup_entries.items.len;
            _ = try self.lowerExpr(expr);
            if (sir.exprDefinitelyDiverges(expr)) {
                try self.endBlock(.{ .@"unreachable" = {} });
                return;
            }
            try @TypeOf(self.*).emitFullExpressionAutoDropsFrom(self, cleanup_start, "statement");
        },
        .@"return" => |maybe_expr| {
            if (maybe_expr) |expr| {
                if (self.func.return_type == self.mb.void_type and expr.* == .@"switch" and expr.@"switch".result_type_id != null) {
                    const switch_ty = try self.mb.lowerCanonicalType(expr.@"switch".result_type_id.?);
                    if (switch_ty == self.mb.void_type) {
                        try @TypeOf(self.*).lowerSwitchStmt(self, expr.@"switch");
                        try @TypeOf(self.*).emitDefersFrom(self, 0, "return");
                        try @TypeOf(self.*).emitAutoDropsFrom(self, 0, "return");
                        try recordCatchExits(self, 0, null);
                        try self.endBlock(.{ .@"return" = null });
                        return;
                    }
                }
                _ = try self.mb.requireExprSink(expr, .@"return");
                const lowered_value = try @TypeOf(self.*).lowerExprForTarget(self, expr, self.func.return_type);
                const value = try @TypeOf(self.*).prepareCapturedExprValue(self, expr, lowered_value, self.func.return_type);
                try @TypeOf(self.*).emitDefersFrom(self, 0, "return");
                try @TypeOf(self.*).emitAutoDropsFrom(self, 0, "return");
                try recordCatchExits(self, 0, directThrowBinding(expr));
                try self.endBlock(.{ .@"return" = value });
            } else {
                try @TypeOf(self.*).emitDefersFrom(self, 0, "return");
                try @TypeOf(self.*).emitAutoDropsFrom(self, 0, "return");
                try recordCatchExits(self, 0, null);
                try self.endBlock(.{ .@"return" = null });
            }
        },
        .yield => |maybe_expr| {
            const target = self.switch_stack.getLastOrNull() orelse return error.LowerInvariantViolation;
            if (maybe_expr) |expr| {
                if (target.result_ptr) |result_ptr| {
                    const result_ty = target.result_ty orelse return error.LowerInvariantViolation;
                    const lowered = try @TypeOf(self.*).lowerExprForTarget(self, expr, result_ty);
                    const captured = try @TypeOf(self.*).prepareCapturedExprValue(self, expr, lowered, result_ty);
                    try self.emitVoid(.{ .store = .{ .ptr = result_ptr, .value = captured } });
                } else {
                    _ = try self.lowerExpr(expr);
                }
            } else if (target.result_ptr != null) return error.LowerInvariantViolation;
            try @TypeOf(self.*).emitDefersFrom(self, target.defer_start, "yield");
            try @TypeOf(self.*).emitAutoDropsFrom(self, target.cleanup_start, "yield");
            try recordCatchExits(self, target.catch_depth, null);
            target.reached_continuation.* = true;
            try self.endBlock(.{ .br = target.continue_block });
        },
        .@"if" => |if_stmt| try lowerIfStmt(self, if_stmt),
        .@"while" => |while_stmt| try lowerWhileStmt(self, while_stmt),
        .@"for" => |for_stmt| try lowerForStmt(self, for_stmt),
        .@"continue" => {
            const loop = self.loop_stack.getLastOrNull() orelse return error.LowerInvariantViolation;
            try @TypeOf(self.*).emitDefersFrom(self, loop.defer_start, "continue");
            try @TypeOf(self.*).emitAutoDropsFrom(self, loop.cleanup_start, "continue");
            try self.endBlock(.{ .br = loop.continue_block });
        },
        .@"break" => {
            const loop = self.loop_stack.getLastOrNull() orelse return error.LowerInvariantViolation;
            try @TypeOf(self.*).emitDefersFrom(self, loop.defer_start, "break");
            try @TypeOf(self.*).emitAutoDropsFrom(self, loop.cleanup_start, "break");
            try recordCatchExits(self, loop.catch_depth, null);
            try self.endBlock(.{ .br = loop.break_block });
        },
        .@"switch" => |switch_stmt| try lowerSwitchStmt(self, switch_stmt),
        .@"try" => |attempt| {
            const metadata = try self.mb.exprMetadata(attempt.expr);
            _ = try lowerTryResultExpr(self, attempt.expr, metadata.try_widen_ordinal, attempt.site_line);
        },
        .@"defer" => |expr| {
            try self.defers.append(self.mb.allocator, expr);
        },
        .using_alloc => |using_alloc| {
            _ = try self.lowerExpr(using_alloc.allocator_expr);
            try lowerStmtList(self, using_alloc.body);
        },
        .drop => |drop| {
            const local = try self.getLocal(drop.name);
            const value = try self.emit(.{ .load = local.ptr_value }, local.ty);
            try @TypeOf(self.*).recordOwnershipTrace(self, "explicit_drop {s}", .{drop.name});
            try @TypeOf(self.*).emitDropValue(self, value, local.ty);
            self.markCleanupInactive(local);
        },
    }
}

pub fn lowerIfStmt(self: anytype, if_stmt: sir.If) LowerError!void {
    if (if_stmt.kind != .plain) {
        return switch (if_stmt.kind) {
            .optional_some, .optional_none => lowerOptionalIfStmt(self, if_stmt),
            .union_case => lowerUnionIfStmt(self, if_stmt),
            else => error.LowerInvariantViolation,
        };
    }

    const then_blk = try self.beginBlock("if_then");
    const else_blk = try self.beginBlock("if_else");
    const cont_blk = try self.beginBlock("if_cont");

    const cond = try self.lowerExpr(if_stmt.condition);
    try self.endBlock(.{ .cond_br = .{
        .condition = cond,
        .then_block = then_blk,
        .else_block = else_blk,
    } });

    self.current_block = then_blk;
    try lowerStmtList(self, if_stmt.then_body);
    const then_fell_through = self.currentBlock().terminator == .none;
    if (then_fell_through) {
        try self.endBlock(.{ .br = cont_blk });
    }

    self.current_block = else_blk;
    try lowerStmtList(self, if_stmt.else_body);
    const else_fell_through = self.currentBlock().terminator == .none;
    if (else_fell_through) {
        try self.endBlock(.{ .br = cont_blk });
    }

    if (then_fell_through or else_fell_through) {
        self.current_block = cont_blk;
        return;
    }

    self.blocks.items[cont_blk].terminator = .{ .@"unreachable" = {} };
    self.current_block = else_blk;
}

pub fn lowerOptionalIfStmt(self: anytype, if_stmt: sir.If) LowerError!void {
    const then_blk = try self.beginBlock("if_then");
    const else_blk = try self.beginBlock("if_else");
    const cont_blk = try self.beginBlock("if_cont");

    const borrowed_sparse = try @TypeOf(self.*).lowerBorrowedSparseOptionalSubject(self, if_stmt.condition);
    if (borrowed_sparse) |borrow| {
        const then_is_some = if_stmt.kind == .optional_some;
        try self.endBlock(.{ .cond_br = .{
            .condition = borrow.present,
            .then_block = if (then_is_some) then_blk else else_blk,
            .else_block = if (then_is_some) else_blk else then_blk,
        } });

        self.current_block = then_blk;
        if (then_is_some and if_stmt.capture_name != null) {
            try @TypeOf(self.*).lowerStmtListWithAliasedLocal(
                self,
                if_stmt.capture_name.?,
                borrow.payload_ty,
                borrow.payload_ptr,
                if_stmt.then_body,
            );
        } else {
            try lowerStmtList(self, if_stmt.then_body);
        }
        const then_fell_through = self.currentBlock().terminator == .none;
        if (then_fell_through) {
            try self.endBlock(.{ .br = cont_blk });
        }

        self.current_block = else_blk;
        try lowerStmtList(self, if_stmt.else_body);
        const else_fell_through = self.currentBlock().terminator == .none;
        if (else_fell_through) {
            try self.endBlock(.{ .br = cont_blk });
        }

        if (then_fell_through or else_fell_through) {
            self.current_block = cont_blk;
            return;
        }

        self.blocks.items[cont_blk].terminator = .{ .@"unreachable" = {} };
        self.current_block = else_blk;
        return;
    }

    const opt_v = try self.lowerExpr(if_stmt.condition);
    const opt_ty = try @TypeOf(self.*).lowerExprType(self, if_stmt.condition);
    const drop_opt_value = if (try @TypeOf(self.*).captureMatchSourceNeedsDrop(self, if_stmt.condition) and try @TypeOf(self.*).typeNeedsDrop(self, opt_ty))
        opt_v
    else
        null;
    const tag_v = try self.emit(.{ .extract_tag = opt_v }, self.mb.bool_type);
    const then_is_some = if_stmt.kind == .optional_some;
    try self.endBlock(.{ .cond_br = .{
        .condition = tag_v,
        .then_block = if (then_is_some) then_blk else else_blk,
        .else_block = if (then_is_some) else_blk else then_blk,
    } });

    self.current_block = then_blk;
    if (then_is_some and if_stmt.capture_name != null) {
        const capture_ty = try self.mb.lowerCanonicalType(if_stmt.capture_type_id);
        const payload_v = try self.emit(.{ .extract_payload = .{ .value = opt_v } }, capture_ty);
        const moves_payload = (try @TypeOf(self.*).captureMatchSourceMovesPayload(self, if_stmt.condition)) or
            (drop_opt_value != null and try @TypeOf(self.*).typeNeedsDrop(self, capture_ty) and
                !(try @TypeOf(self.*).typeHasSharedValueSemantics(self, capture_ty)));
        if (moves_payload) {
            try @TypeOf(self.*).lowerStmtListWithMovedCapturedLocal(
                self,
                if_stmt.capture_name.?,
                capture_ty,
                payload_v,
                if_stmt.then_body,
            );
        } else if (drop_opt_value) |owned_opt| {
            try @TypeOf(self.*).lowerStmtListWithCapturedLocalAndDrop(
                self,
                if_stmt.capture_name.?,
                capture_ty,
                payload_v,
                owned_opt,
                opt_ty,
                if_stmt.then_body,
            );
        } else {
            try @TypeOf(self.*).lowerStmtListWithCapturedLocal(
                self,
                if_stmt.capture_name.?,
                capture_ty,
                payload_v,
                if_stmt.then_body,
            );
        }
    } else {
        if (then_is_some) {
            if (drop_opt_value) |owned_opt| {
                try @TypeOf(self.*).emitDropValue(self, owned_opt, opt_ty);
            }
        }
        try lowerStmtList(self, if_stmt.then_body);
    }
    const then_fell_through = self.currentBlock().terminator == .none;
    if (then_fell_through) {
        try self.endBlock(.{ .br = cont_blk });
    }

    self.current_block = else_blk;
    try lowerStmtList(self, if_stmt.else_body);
    const else_fell_through = self.currentBlock().terminator == .none;
    if (else_fell_through) {
        try self.endBlock(.{ .br = cont_blk });
    }

    if (then_fell_through or else_fell_through) {
        self.current_block = cont_blk;
        return;
    }

    self.blocks.items[cont_blk].terminator = .{ .@"unreachable" = {} };
    self.current_block = else_blk;
}

pub fn lowerUnionIfStmt(self: anytype, if_stmt: sir.If) LowerError!void {
    const then_blk = try self.beginBlock("if_then");
    const else_blk = try self.beginBlock("if_else");
    const cont_blk = try self.beginBlock("if_cont");

    const union_v = try self.lowerExpr(if_stmt.condition);
    const union_ty = try @TypeOf(self.*).lowerExprType(self, if_stmt.condition);
    const drop_union_value = if (try @TypeOf(self.*).captureMatchSourceNeedsDrop(self, if_stmt.condition) and try @TypeOf(self.*).typeNeedsDrop(self, union_ty))
        union_v
    else
        null;
    const case_name = if_stmt.case_name orelse return error.LowerInvariantViolation;
    const result_case: ?sir.ResultCase = switch (self.mb.types.items[union_ty]) {
        .result => language_contracts.resolveResultCase(case_name) orelse return error.LowerInvariantViolation,
        else => null,
    };
    const union_name = switch (self.mb.types.items[union_ty]) {
        .result => language_contracts.result_type_name,
        .@"union" => try self.unionNameFromValue(union_v),
        else => return error.LowerInvariantViolation,
    };
    const tag_ty = if (result_case != null) self.mb.bool_type else self.mb.i64_type;
    const tag_v = try self.emit(.{ .extract_tag = union_v }, tag_ty);
    const want_tag = if (result_case) |kind|
        try self.emit(.{ .const_bool = kind == .err }, tag_ty)
    else
        try self.emit(.{ .const_int = try self.unionCaseTagResolved(if_stmt.union_decl_id, union_name, case_name) }, tag_ty);
    const match_v = try self.emit(.{ .int_cmp = .{
        .op = .eq,
        .lhs = tag_v,
        .rhs = want_tag,
    } }, self.mb.bool_type);
    try self.endBlock(.{ .cond_br = .{
        .condition = match_v,
        .then_block = then_blk,
        .else_block = else_blk,
    } });

    self.current_block = then_blk;
    if (if_stmt.capture_name != null) {
        const capture_ty = if (result_case) |kind| switch (self.mb.types.items[union_ty]) {
            .result => |result| switch (kind) {
                .ok => result.ok,
                .err => result.err,
            },
            else => return error.LowerInvariantViolation,
        } else try self.unionCasePayloadTypeResolved(if_stmt.union_decl_id, union_name, case_name);
        const payload_v = if (result_case) |kind|
            try emitExtractResultCaseValue(self, union_v, kind == .err, capture_ty)
        else
            try self.emit(.{ .extract_payload = .{
                .value = union_v,
                .union_tag = try self.unionCaseTagResolved(if_stmt.union_decl_id, union_name, case_name),
            } }, capture_ty);
        const moves_payload = (try @TypeOf(self.*).captureMatchSourceMovesPayload(self, if_stmt.condition)) or
            (drop_union_value != null and try @TypeOf(self.*).typeNeedsDrop(self, capture_ty) and
                !(try @TypeOf(self.*).typeHasSharedValueSemantics(self, capture_ty)));
        if (moves_payload) {
            try @TypeOf(self.*).lowerStmtListWithMovedCapturedLocal(
                self,
                if_stmt.capture_name.?,
                capture_ty,
                payload_v,
                if_stmt.then_body,
            );
        } else if (drop_union_value) |owned_union| {
            try @TypeOf(self.*).lowerStmtListWithCapturedLocalAndDrop(
                self,
                if_stmt.capture_name.?,
                capture_ty,
                payload_v,
                owned_union,
                union_ty,
                if_stmt.then_body,
            );
        } else {
            try @TypeOf(self.*).lowerStmtListWithCapturedLocal(
                self,
                if_stmt.capture_name.?,
                capture_ty,
                payload_v,
                if_stmt.then_body,
            );
        }
    } else {
        if (drop_union_value) |owned_union| {
            try @TypeOf(self.*).emitDropValue(self, owned_union, union_ty);
        }
        try lowerStmtList(self, if_stmt.then_body);
    }
    const then_fell_through = self.currentBlock().terminator == .none;
    if (then_fell_through) {
        try self.endBlock(.{ .br = cont_blk });
    }

    self.current_block = else_blk;
    try lowerStmtList(self, if_stmt.else_body);
    const else_fell_through = self.currentBlock().terminator == .none;
    if (else_fell_through) {
        try self.endBlock(.{ .br = cont_blk });
    }

    if (then_fell_through or else_fell_through) {
        self.current_block = cont_blk;
        return;
    }

    self.blocks.items[cont_blk].terminator = .{ .@"unreachable" = {} };
    self.current_block = else_blk;
}

pub fn lowerWhileStmt(self: anytype, while_stmt: sir.While) LowerError!void {
    const cond_blk = try self.beginBlock("while_cond");
    const body_blk = try self.beginBlock("while_body");
    const exit_blk = try self.beginBlock("while_exit");

    try self.endBlock(.{ .br = cond_blk });

    self.current_block = cond_blk;
    const cond = try self.lowerExpr(while_stmt.condition);
    const always_true = while_stmt.condition.* == .bool and while_stmt.condition.bool;
    if (always_true) {
        try self.endBlock(.{ .br = body_blk });
    } else {
        try self.endBlock(.{ .cond_br = .{
            .condition = cond,
            .then_block = body_blk,
            .else_block = exit_blk,
        } });
    }

    self.current_block = body_blk;
    try self.loop_stack.append(self.mb.allocator, .{
        .continue_block = cond_blk,
        .break_block = exit_blk,
        .catch_depth = self.catch_stack.items.len,
        .defer_start = self.defers.items.len,
        .cleanup_start = self.ownership.cleanup_entries.items.len,
    });
    defer _ = self.loop_stack.pop();
    try lowerStmtList(self, while_stmt.body);
    if (self.currentBlock().terminator == .none) {
        try self.endBlock(.{ .br = cond_blk });
    }

    self.current_block = exit_blk;
    if (always_true) {
        var has_break = false;
        for (self.blocks.items) |block| {
            if (block.terminator == .br and block.terminator.br == exit_blk) {
                has_break = true;
                break;
            }
        }
        if (!has_break) try self.endBlock(.{ .@"unreachable" = {} });
    }
}

/// Look up the checked record for one hook a `for` loop generates. Lowering
/// takes the callee from the record, so a missing, duplicated, or mismatched
/// record stops the lowering rather than falling back to a name lookup.
fn iterationHookRecord(
    for_stmt: sir.For,
    role: sir.GeneratedIterationRole,
    declared_decl_id: ?identity.DeclId,
) LowerError!sir.GeneratedMethodUse {
    var found: ?sir.GeneratedMethodUse = null;
    for (for_stmt.generated_method_uses) |record| {
        if (record.role != role) continue;
        if (found != null) return error.DuplicateGeneratedMethodUse;
        found = record;
    }
    const record = found orelse return error.MissingGeneratedMethodUse;
    // The record must name the hook declaration the loop is bound to: a record
    // for a hook the loop never reaches, or one naming a declaration the loop
    // does not have, is not lowering authority.
    if (declared_decl_id == null or record.method_declaration_id != declared_decl_id.?) {
        return error.IncorrectGeneratedMethodUse;
    }
    return record;
}

pub fn lowerForStmt(self: anytype, for_stmt: sir.For) LowerError!void {
    const iterable_ty = try @TypeOf(self.*).lowerExprType(self, for_stmt.iterable);
    const item_ty = try self.mb.lowerCanonicalType(for_stmt.item_type_id);

    if (for_stmt.generated_method_uses.len != 0) {
        if (for_stmt.generated_method_uses.len != 4) return error.MissingGeneratedMethodUse;
        return lowerIteratorHookForStmt(self, for_stmt, iterable_ty, item_ty);
    }

    const index_slot = try self.emit(.{ .stack_alloc = self.mb.i64_type }, self.mb.i64_type);
    const zero = try self.emit(.{ .const_int = 0 }, self.mb.i64_type);
    try self.emitVoid(.{ .store = .{
        .ptr = index_slot,
        .value = zero,
    } });

    const iterable_state = try captureForIterable(self, for_stmt.iterable, iterable_ty);
    // Sparse reads materialize copies; contiguous storage lends its element.
    const borrowed_item = iterable_state != .sparse_ptr;
    const item_local = if (borrowed_item) null else try self.defineLocal(for_stmt.name, item_ty);
    defer {
        if (item_local != null) _ = self.locals.remove(for_stmt.name);
    }
    const item_init_slot = if (!borrowed_item and try @TypeOf(self.*).typeNeedsDrop(self, item_ty)) blk: {
        const slot = try self.emit(.{ .stack_alloc = self.mb.bool_type }, self.mb.bool_type);
        const false_value = try self.emit(.{ .const_bool = false }, self.mb.bool_type);
        try self.emitVoid(.{ .store = .{ .ptr = slot, .value = false_value } });
        break :blk slot;
    } else null;

    const cond_blk = try self.beginBlock("for_cond");
    const body_blk = try self.beginBlock("for_body");
    const step_blk = try self.beginBlock("for_step");
    const exit_blk = try self.beginBlock("for_exit");

    try self.endBlock(.{ .br = cond_blk });

    self.current_block = cond_blk;
    const index_value = try self.emit(.{ .load = index_slot }, self.mb.i64_type);
    const len_value = try forIterableLen(self, iterable_state);
    const cond_value = try self.emit(.{ .int_cmp = .{
        .op = .lt,
        .lhs = index_value,
        .rhs = len_value,
    } }, self.mb.bool_type);
    try self.endBlock(.{ .cond_br = .{
        .condition = cond_value,
        .then_block = body_blk,
        .else_block = exit_blk,
    } });

    self.current_block = body_blk;
    const body_index = try self.emit(.{ .load = index_slot }, self.mb.i64_type);
    const item_value = try forIterableItem(self, iterable_state, body_index, item_ty);
    if (item_local) |local| {
        if (item_init_slot) |init_slot| {
            const was_init = try self.emit(.{ .load = init_slot }, self.mb.bool_type);
            const drop_blk = try self.beginBlock("for_item_drop");
            const store_blk = try self.beginBlock("for_item_store");
            try self.endBlock(.{ .cond_br = .{
                .condition = was_init,
                .then_block = drop_blk,
                .else_block = store_blk,
            } });

            self.current_block = drop_blk;
            const old_item = try self.emit(.{ .load = local.ptr_value }, item_ty);
            try @TypeOf(self.*).emitDropValue(self, old_item, item_ty);
            try self.endBlock(.{ .br = store_blk });

            self.current_block = store_blk;
            try @TypeOf(self.*).storeWithCleanup(self, local.ptr_value, null, item_value, item_ty, false);
            const true_value = try self.emit(.{ .const_bool = true }, self.mb.bool_type);
            try self.emitVoid(.{ .store = .{ .ptr = init_slot, .value = true_value } });
        } else {
            try @TypeOf(self.*).storeWithCleanup(self, local.ptr_value, null, item_value, item_ty, false);
        }
        self.markCleanupActive(local);
    }
    try self.loop_stack.append(self.mb.allocator, .{
        .continue_block = step_blk,
        .break_block = exit_blk,
        .catch_depth = self.catch_stack.items.len,
        .defer_start = self.defers.items.len,
        .cleanup_start = self.ownership.cleanup_entries.items.len,
    });
    defer _ = self.loop_stack.pop();
    if (borrowed_item) {
        try @TypeOf(self.*).lowerStmtListWithAliasedLocal(self, for_stmt.name, item_ty, item_value, for_stmt.body);
    } else {
        try lowerStmtList(self, for_stmt.body);
    }
    if (self.currentBlock().terminator == .none) {
        try self.endBlock(.{ .br = step_blk });
    }

    self.current_block = step_blk;
    const step_index = try self.emit(.{ .load = index_slot }, self.mb.i64_type);
    const one = try self.emit(.{ .const_int = 1 }, self.mb.i64_type);
    const next_index = try self.emit(.{ .int_binop = .{
        .op = .add,
        .lhs = step_index,
        .rhs = one,
    } }, self.mb.i64_type);
    try self.emitVoid(.{ .store = .{
        .ptr = index_slot,
        .value = next_index,
    } });
    try self.endBlock(.{ .br = cond_blk });

    self.current_block = exit_blk;
    if (item_init_slot != null) {
        const was_init = try self.emit(.{ .load = item_init_slot.? }, self.mb.bool_type);
        const drop_blk = try self.beginBlock("for_exit_drop");
        const cont_blk = try self.beginBlock("for_exit_cont");
        try self.endBlock(.{ .cond_br = .{
            .condition = was_init,
            .then_block = drop_blk,
            .else_block = cont_blk,
        } });

        self.current_block = drop_blk;
        if (item_local.?.cleanup_index) |_| {
            const final_item = try self.emit(.{ .load = item_local.?.ptr_value }, item_ty);
            try @TypeOf(self.*).emitDropValue(self, final_item, item_ty);
            self.markCleanupInactive(item_local.?);
        }
        try self.endBlock(.{ .br = cont_blk });
        self.current_block = cont_blk;
    }
}

pub fn lowerIteratorHookForStmt(self: anytype, for_stmt: sir.For, iterable_ty: lir.TypeId, item_ty: lir.TypeId) LowerError!void {
    // Each hook call is emitted from the checked record naming its concrete
    // declaration, so lowering never resolves a generated hook by name.
    for (for_stmt.generated_method_uses, 0..) |record, index| {
        for (for_stmt.generated_method_uses[0..index]) |prior| {
            if (prior.use_id == record.use_id) return error.DuplicateGeneratedMethodUse;
        }
    }
    const init_use = try iterationHookRecord(for_stmt, .iterator_init, for_stmt.iterator_init_decl_id);
    const has_next_use = try iterationHookRecord(for_stmt, .iterator_has_next, for_stmt.iterator_has_next_decl_id);
    const next_use = try iterationHookRecord(for_stmt, .iterator_next, for_stmt.iterator_next_decl_id);
    const item_use = if (for_stmt.iterable_index_decl_id != null)
        try iterationHookRecord(for_stmt, .iterable_item, for_stmt.iterable_index_decl_id)
    else
        null;
    if (for_stmt.iterator_init_intrinsic_id != .syntax_iter or
        for_stmt.iterator_has_next_intrinsic_id != .syntax_iter_has_next or
        for_stmt.iterator_next_intrinsic_id != .syntax_iter_next)
    {
        return LowerError.InvalidIdentity;
    }
    if (for_stmt.iterable_index_decl_id != null and for_stmt.iterable_index_intrinsic_id != .syntax_iter_item) {
        return LowerError.InvalidIdentity;
    }
    const source_local = try self.defineLocal("__iter_source", iterable_ty);
    const source_value = try self.lowerExpr(for_stmt.iterable);
    try @TypeOf(self.*).copyValueInto(self, source_local.ptr_value, source_value, iterable_ty);
    self.markCleanupActive(source_local);

    const iter_ty = try self.mb.lowerCanonicalType(for_stmt.iterator_state_type_id);
    const iter_local = try self.defineLocal("__iter_state", iter_ty);
    const iter_value = try emitIteratorInitCall(
        self,
        init_use.method_declaration_id,
        source_local.ptr_value,
        iterable_ty,
    );
    try @TypeOf(self.*).copyValueInto(self, iter_local.ptr_value, iter_value, iter_ty);
    if (try @TypeOf(self.*).typeNeedsDrop(self, iter_ty)) {
        try @TypeOf(self.*).emitDropValue(self, iter_value, iter_ty);
    }
    self.markCleanupActive(iter_local);

    const cursor_ty = try self.mb.lowerCanonicalType(for_stmt.iterator_cursor_type_id);
    const cursor_local = try self.defineLocal("__iter_cursor", cursor_ty);

    // Reference-returning item hooks lend the collection element to the body.
    // A shallow owning local would drop fields that still belong to the source.
    const borrowed_item = if (item_use) |record| blk: {
        const callee = try self.mb.functionById(record.method_declaration_id);
        break :blk (try self.mb.canonicalTypeNode(callee.return_type_id)).* == .ref_;
    } else false;
    const item_local = if (borrowed_item) null else try self.defineLocal(for_stmt.name, item_ty);
    defer {
        if (item_local != null) _ = self.locals.remove(for_stmt.name);
    }
    const item_init_slot = if (!borrowed_item and try @TypeOf(self.*).typeNeedsDrop(self, item_ty)) blk: {
        const slot = try self.emit(.{ .stack_alloc = self.mb.bool_type }, self.mb.bool_type);
        const false_value = try self.emit(.{ .const_bool = false }, self.mb.bool_type);
        try self.emitVoid(.{ .store = .{ .ptr = slot, .value = false_value } });
        break :blk slot;
    } else null;

    const cond_blk = try self.beginBlock("for_iter_cond");
    const body_blk = try self.beginBlock("for_iter_body");
    const step_blk = try self.beginBlock("for_iter_step");
    const exit_blk = try self.beginBlock("for_iter_exit");

    try self.endBlock(.{ .br = cond_blk });

    self.current_block = cond_blk;
    const has_next = try emitIteratorHasNextCall(
        self,
        has_next_use.method_declaration_id,
        source_local.ptr_value,
        iterable_ty,
        iter_local.ptr_value,
    );
    try self.endBlock(.{ .cond_br = .{
        .condition = has_next,
        .then_block = body_blk,
        .else_block = exit_blk,
    } });

    self.current_block = body_blk;
    const cursor_value = try emitIteratorNextCall(
        self,
        next_use.method_declaration_id,
        source_local.ptr_value,
        iterable_ty,
        iter_local.ptr_value,
        cursor_ty,
    );
    try @TypeOf(self.*).copyValueInto(self, cursor_local.ptr_value, cursor_value, cursor_ty);
    const item_value = if (item_use) |item_record|
        try emitIterableIndexHookCall(
            self,
            item_record.method_declaration_id,
            source_local.ptr_value,
            iterable_ty,
            cursor_local.ptr_value,
            cursor_ty,
        )
    else blk: {
        const cursor_value_for_index = try self.emit(.{ .load = cursor_local.ptr_value }, cursor_ty);
        break :blk try @TypeOf(self.*).lowerIndexFromPointerValue(self, source_local.ptr_value, iterable_ty, cursor_value_for_index);
    };
    if (item_local) |local| {
        if (item_init_slot) |init_slot| {
            const was_init = try self.emit(.{ .load = init_slot }, self.mb.bool_type);
            const drop_blk = try self.beginBlock("for_iter_item_drop");
            const store_blk = try self.beginBlock("for_iter_item_store");
            try self.endBlock(.{ .cond_br = .{
                .condition = was_init,
                .then_block = drop_blk,
                .else_block = store_blk,
            } });

            self.current_block = drop_blk;
            const old_item = try self.emit(.{ .load = local.ptr_value }, item_ty);
            try @TypeOf(self.*).emitDropValue(self, old_item, item_ty);
            try self.endBlock(.{ .br = store_blk });

            self.current_block = store_blk;
            try @TypeOf(self.*).storeWithCleanup(self, local.ptr_value, null, item_value, item_ty, false);
            const true_value = try self.emit(.{ .const_bool = true }, self.mb.bool_type);
            try self.emitVoid(.{ .store = .{ .ptr = init_slot, .value = true_value } });
        } else {
            try @TypeOf(self.*).storeWithCleanup(self, local.ptr_value, null, item_value, item_ty, false);
        }
        self.markCleanupActive(local);
    }
    try self.loop_stack.append(self.mb.allocator, .{
        .continue_block = step_blk,
        .break_block = exit_blk,
        .catch_depth = self.catch_stack.items.len,
        .defer_start = self.defers.items.len,
        .cleanup_start = self.ownership.cleanup_entries.items.len,
    });
    defer _ = self.loop_stack.pop();
    if (borrowed_item) {
        try @TypeOf(self.*).lowerStmtListWithAliasedLocal(self, for_stmt.name, item_ty, item_value, for_stmt.body);
    } else {
        try lowerStmtList(self, for_stmt.body);
    }
    if (self.currentBlock().terminator == .none) {
        try self.endBlock(.{ .br = step_blk });
    }

    self.current_block = step_blk;
    try self.endBlock(.{ .br = cond_blk });

    self.current_block = exit_blk;
    if (item_init_slot != null) {
        const was_init = try self.emit(.{ .load = item_init_slot.? }, self.mb.bool_type);
        const drop_blk = try self.beginBlock("for_iter_exit_drop");
        const cont_blk = try self.beginBlock("for_iter_exit_cont");
        try self.endBlock(.{ .cond_br = .{
            .condition = was_init,
            .then_block = drop_blk,
            .else_block = cont_blk,
        } });

        self.current_block = drop_blk;
        const final_item = try self.emit(.{ .load = item_local.?.ptr_value }, item_ty);
        try @TypeOf(self.*).emitDropValue(self, final_item, item_ty);
        self.markCleanupInactive(item_local.?);
        try self.endBlock(.{ .br = cont_blk });

        self.current_block = cont_blk;
    }
}

fn iteratorCallArgument(self: anytype, storage_ptr: lir.ValueId, value_type: lir.TypeId, parameter_type: lir.TypeId) LowerError!lir.ValueId {
    if (self.mb.types.items[parameter_type] == .pointer and self.mb.types.items[value_type] != .pointer) return storage_ptr;
    return self.emit(.{ .load = storage_ptr }, value_type);
}

pub fn emitIteratorInitCall(self: anytype, decl_id: identity.DeclId, self_ptr: lir.ValueId, self_value_ty: lir.TypeId) LowerError!lir.ValueId {
    const callee = try self.mb.functionById(decl_id);
    const params = try lowerParams(self, callee.params);
    defer self.mb.allocator.free(params);
    if (params.len != 1) return error.LowerInvariantViolation;
    const self_arg = try iteratorCallArgument(self, self_ptr, self_value_ty, params[0].ty);
    return self.emit(.{ .call = .{
        .name = try self.mb.emittedFunctionName(callee.module_name, callee.owner, callee.name, callee.abi_name, callee.calling_convention == .c, callee.is_test_entry),
        .args = try @TypeOf(self.*).dupeArgs(self, &.{self_arg}),
    } }, try lowerFunctionReturnType(self, callee));
}

pub fn emitIteratorHasNextCall(self: anytype, decl_id: identity.DeclId, source_ptr: lir.ValueId, source_value_ty: lir.TypeId, state_ptr: lir.ValueId) LowerError!lir.ValueId {
    const callee = try self.mb.functionById(decl_id);
    const params = try lowerParams(self, callee.params);
    defer self.mb.allocator.free(params);
    if (params.len != 2) return error.LowerInvariantViolation;
    const source_arg = try iteratorCallArgument(self, source_ptr, source_value_ty, params[0].ty);
    return self.emit(.{ .call = .{
        .name = try self.mb.emittedFunctionName(callee.module_name, callee.owner, callee.name, callee.abi_name, callee.calling_convention == .c, callee.is_test_entry),
        .args = try @TypeOf(self.*).dupeArgs(self, &.{ source_arg, state_ptr }),
    } }, try lowerFunctionReturnType(self, callee));
}

pub fn emitIteratorNextCall(self: anytype, decl_id: identity.DeclId, source_ptr: lir.ValueId, source_value_ty: lir.TypeId, state_ptr: lir.ValueId, cursor_ty: lir.TypeId) LowerError!lir.ValueId {
    _ = cursor_ty;
    const callee = try self.mb.functionById(decl_id);
    const params = try lowerParams(self, callee.params);
    defer self.mb.allocator.free(params);
    if (params.len != 2) return error.LowerInvariantViolation;
    const source_arg = try iteratorCallArgument(self, source_ptr, source_value_ty, params[0].ty);
    return self.emit(.{ .call = .{
        .name = try self.mb.emittedFunctionName(callee.module_name, callee.owner, callee.name, callee.abi_name, callee.calling_convention == .c, callee.is_test_entry),
        .args = try @TypeOf(self.*).dupeArgs(self, &.{ source_arg, state_ptr }),
    } }, try lowerFunctionReturnType(self, callee));
}

pub fn emitIterableIndexHookCall(
    self: anytype,
    decl_id: identity.DeclId,
    self_ptr: lir.ValueId,
    self_value_ty: lir.TypeId,
    cursor_ptr: lir.ValueId,
    cursor_value_ty: lir.TypeId,
) LowerError!lir.ValueId {
    const callee = try self.mb.functionById(decl_id);
    const params = try lowerParams(self, callee.params);
    defer self.mb.allocator.free(params);
    if (params.len != 2) return error.LowerInvariantViolation;
    const self_arg = try iteratorCallArgument(self, self_ptr, self_value_ty, params[0].ty);
    const cursor_arg = try iteratorCallArgument(self, cursor_ptr, cursor_value_ty, params[1].ty);
    const result_ty = try lowerFunctionReturnType(self, callee);
    const result = try self.emit(.{ .call = .{
        .name = try self.mb.emittedFunctionName(callee.module_name, callee.owner, callee.name, callee.abi_name, callee.calling_convention == .c, callee.is_test_entry),
        .args = try @TypeOf(self.*).dupeArgs(self, &.{ self_arg, cursor_arg }),
    } }, result_ty);
    return result;
}

const SwitchResult = struct { ptr: lir.ValueId, ty: lir.TypeId };

pub fn lowerSwitchStmt(self: anytype, switch_stmt: sir.Switch) LowerError!void {
    return lowerSwitch(self, switch_stmt, null);
}

pub fn lowerSwitchExpr(self: anytype, switch_expr: sir.Switch) LowerError!lir.ValueId {
    const result_type_id = switch_expr.result_type_id orelse return error.LowerInvariantViolation;
    const ty = try self.mb.lowerCanonicalType(result_type_id);
    if (ty == self.mb.void_type) {
        try lowerSwitch(self, switch_expr, null);
        return self.emit(.{ .const_int = 0 }, self.mb.i64_type);
    }
    const ptr = try self.emit(.{ .stack_alloc = ty }, ty);
    try lowerSwitch(self, switch_expr, .{ .ptr = ptr, .ty = ty });
    return self.emit(.{ .load = ptr }, ty);
}

fn lowerSwitch(self: anytype, switch_stmt: sir.Switch, result: ?SwitchResult) LowerError!void {
    return switch ((try self.mb.canonicalTypeNode(switch_stmt.subject_type_id)).*) {
        .integer, .inferred_integer => lowerScalarSwitchStmt(self, switch_stmt, result),
        .primitive => |primitive| if (primitive == .string) lowerScalarSwitchStmt(self, switch_stmt, result) else error.LowerInvariantViolation,
        .nominal => |nominal| switch (nominal.kind) {
            .@"enum" => lowerEnumSwitchStmt(self, switch_stmt, result),
            .@"union" => lowerTaggedSumSwitchStmt(self, switch_stmt, result),
            else => error.LowerInvariantViolation,
        },
        .result => lowerTaggedSumSwitchStmt(self, switch_stmt, result),
        .error_union => lowerTaggedSumSwitchStmt(self, switch_stmt, result),
        else => error.LowerInvariantViolation,
    };
}

fn pushSwitchArm(self: anytype, continuation: lir.BlockId, result: ?SwitchResult, reached_continuation: *bool) LowerError!void {
    try self.switch_stack.append(self.mb.allocator, .{
        .continue_block = continuation,
        .reached_continuation = reached_continuation,
        .result_ptr = if (result) |value| value.ptr else null,
        .result_ty = if (result) |value| value.ty else null,
        .defer_start = self.defers.items.len,
        .cleanup_start = self.ownership.cleanup_entries.items.len,
        .catch_depth = self.catch_stack.items.len,
    });
}

fn recordCatchExits(self: anytype, start: usize, propagated_binding: ?identity.BindingId) LowerError!void {
    const scopes = self.catch_stack.items[start..];
    if (scopes.len == 0) return;
    const exits = try self.mb.allocator.alloc(lir.CatchExit, scopes.len);
    for (scopes, 0..) |_, i| {
        const scope = scopes[scopes.len - 1 - i];
        exits[i] = .{
            .carrier = scope.carrier,
            .disposition = if (propagated_binding != null and scope.binding_id == propagated_binding)
                .propagated_alias
            else
                .handled,
        };
    }
    self.currentBlock().catch_exits = exits;
}

fn directThrowBinding(expr: *sir.Expr) ?identity.BindingId {
    return if (expr.* == .union_case and expr.union_case.from_throw and expr.union_case.throw_message == null)
        expr.union_case.throw_local_binding_id
    else
        null;
}

pub fn lowerScalarSwitchStmt(self: anytype, switch_stmt: sir.Switch, result: ?SwitchResult) LowerError!void {
    const subject = try self.lowerExpr(switch_stmt.value);
    const subject_ty = try @TypeOf(self.*).lowerExprType(self, switch_stmt.value);
    const drop_subject = if (try @TypeOf(self.*).captureMatchSourceNeedsDrop(self, switch_stmt.value) and try @TypeOf(self.*).typeNeedsDrop(self, subject_ty)) subject else null;
    const case_blocks = try self.mb.allocator.alloc(lir.BlockId, switch_stmt.cases.len);
    defer self.mb.allocator.free(case_blocks);
    for (case_blocks) |*block_id| block_id.* = try self.beginBlock("switch_case");
    const else_blk = try self.beginBlock("switch_else");
    const cont_blk = try self.beginBlock("switch_cont");

    if (switch_stmt.cases.len == 0) {
        try self.endBlock(.{ .br = else_blk });
    } else {
        var compare_block = self.current_block;
        for (switch_stmt.cases, 0..) |case, i| {
            self.current_block = compare_block;
            const pattern = case.scalar_pattern orelse return error.LowerInvariantViolation;
            const matched = switch (pattern) {
                .int => |number| blk: {
                    const target = try self.emit(.{ .const_int = number }, subject_ty);
                    break :blk try self.emit(.{ .int_cmp = .{ .op = .eq, .lhs = subject, .rhs = target } }, self.mb.bool_type);
                },
                .string => |text| blk: {
                    const target = try self.emit(.{ .const_string = try self.mb.allocator.dupe(u8, text) }, subject_ty);
                    break :blk try self.emit(.{ .string_cmp = .{ .op = .eq, .lhs = subject, .rhs = target } }, self.mb.bool_type);
                },
            };
            const next = if (i + 1 < switch_stmt.cases.len) try self.beginBlock("switch_next") else else_blk;
            try self.endBlock(.{ .cond_br = .{ .condition = matched, .then_block = case_blocks[i], .else_block = next } });
            compare_block = next;
        }
    }

    var fell_through = false;
    var reached_continuation = false;
    for (switch_stmt.cases, 0..) |case, i| {
        self.current_block = case_blocks[i];
        try pushSwitchArm(self, cont_blk, result, &reached_continuation);
        defer _ = self.switch_stack.pop();
        if (drop_subject) |owned| try @TypeOf(self.*).emitDropValue(self, owned, subject_ty);
        try lowerStmtList(self, case.body);
        if (self.currentBlock().terminator == .none) {
            try self.endBlock(.{ .br = cont_blk });
            fell_through = true;
        }
    }
    self.current_block = else_blk;
    try pushSwitchArm(self, cont_blk, result, &reached_continuation);
    defer _ = self.switch_stack.pop();
    if (drop_subject) |owned| try @TypeOf(self.*).emitDropValue(self, owned, subject_ty);
    try lowerStmtList(self, switch_stmt.else_body);
    if (self.currentBlock().terminator == .none) {
        try self.endBlock(.{ .br = cont_blk });
        fell_through = true;
    }
    if (fell_through or reached_continuation or result != null) {
        self.current_block = cont_blk;
    } else {
        self.blocks.items[cont_blk].terminator = .{ .@"unreachable" = {} };
        self.current_block = cont_blk;
    }
}

pub fn lowerEnumSwitchStmt(self: anytype, switch_stmt: sir.Switch, result: ?SwitchResult) LowerError!void {
    const subject_v = try self.lowerExpr(switch_stmt.value);
    const subject_ty = try @TypeOf(self.*).lowerExprType(self, switch_stmt.value);
    const case_count = switch_stmt.cases.len;
    const case_blocks = try self.mb.allocator.alloc(lir.BlockId, case_count);
    defer self.mb.allocator.free(case_blocks);
    for (case_blocks) |*block_id| {
        block_id.* = try self.beginBlock("switch_case");
    }
    const else_blk = try self.beginBlock("switch_else");
    const cont_blk = try self.beginBlock("switch_cont");

    if (case_count == 0) try self.endBlock(.{ .br = else_blk });
    var compare_block = self.current_block;
    for (switch_stmt.cases, 0..) |case, i| {
        self.current_block = compare_block;
        const want_tag = try emitEnumCaseValueResolved(self, switch_stmt.subject_decl_id, switch_stmt.subject_type_name, case.case_name, subject_ty);
        const match_v = try self.emit(.{ .int_cmp = .{
            .op = .eq,
            .lhs = subject_v,
            .rhs = want_tag,
        } }, self.mb.bool_type);
        const next_compare = if (i + 1 < case_count) try self.beginBlock("switch_next") else else_blk;
        try self.endBlock(.{ .cond_br = .{
            .condition = match_v,
            .then_block = case_blocks[i],
            .else_block = next_compare,
        } });
        compare_block = next_compare;
    }

    var fell_through = false;
    var reached_continuation = false;
    for (switch_stmt.cases, 0..) |case, i| {
        _ = case;
        self.current_block = case_blocks[i];
        try pushSwitchArm(self, cont_blk, result, &reached_continuation);
        defer _ = self.switch_stack.pop();
        try lowerStmtList(self, switch_stmt.cases[i].body);
        if (self.currentBlock().terminator == .none) {
            try self.endBlock(.{ .br = cont_blk });
            fell_through = true;
        }
    }

    self.current_block = else_blk;
    if (!switch_stmt.has_else) {
        self.blocks.items[else_blk].terminator = .{ .@"unreachable" = {} };
    } else {
        try pushSwitchArm(self, cont_blk, result, &reached_continuation);
        defer _ = self.switch_stack.pop();
        try lowerStmtList(self, switch_stmt.else_body);
        if (self.currentBlock().terminator == .none) {
            try self.endBlock(.{ .br = cont_blk });
            fell_through = true;
        }
    }

    if (fell_through or reached_continuation or result != null) {
        self.current_block = cont_blk;
        return;
    }

    self.blocks.items[cont_blk].terminator = .{ .@"unreachable" = {} };
    self.current_block = cont_blk;
}

pub fn lowerTaggedSumSwitchStmt(self: anytype, switch_stmt: sir.Switch, result: ?SwitchResult) LowerError!void {
    const sum_v = try self.lowerExpr(switch_stmt.value);
    const sum_ty = try @TypeOf(self.*).lowerExprType(self, switch_stmt.value);
    const drop_sum_value = if (try @TypeOf(self.*).captureMatchSourceNeedsDrop(self, switch_stmt.value) and try @TypeOf(self.*).typeNeedsDrop(self, sum_ty))
        sum_v
    else
        null;
    const subject_type = try self.mb.canonicalTypeNode(switch_stmt.subject_type_id);
    const sum_name = switch (subject_type.*) {
        .result => language_contracts.result_type_name,
        .error_union => "__inline_error_union",
        .nominal => |nominal| if (nominal.kind == .@"union") try self.unionNameFromValue(sum_v) else return error.LowerInvariantViolation,
        else => return error.LowerInvariantViolation,
    };
    const tag_ty = switch (subject_type.*) {
        .result => self.mb.bool_type,
        .error_union => self.mb.i64_type,
        .nominal => |nominal| if (nominal.kind == .@"union") self.mb.i64_type else return error.LowerInvariantViolation,
        else => return error.LowerInvariantViolation,
    };
    const case_count = switch_stmt.cases.len;
    const case_blocks = try self.mb.allocator.alloc(lir.BlockId, case_count);
    defer self.mb.allocator.free(case_blocks);
    for (case_blocks, 0..) |*block_id, i| {
        _ = i;
        block_id.* = try self.beginBlock("switch_case");
    }
    const else_blk = try self.beginBlock("switch_else");
    const cont_blk = try self.beginBlock("switch_cont");

    if (case_count == 0) try self.endBlock(.{ .br = else_blk });
    var compare_block = self.current_block;
    for (switch_stmt.cases, 0..) |case, i| {
        self.current_block = compare_block;
        const tag_v = try self.emit(.{ .extract_tag = sum_v }, tag_ty);
        const want_tag = try emitSumCaseTag(self, switch_stmt.subject_type_id, switch_stmt.subject_decl_id, sum_name, case.case_name, case.result_case, case.union_ordinal, tag_ty);
        const match_v = try self.emit(.{ .int_cmp = .{
            .op = .eq,
            .lhs = tag_v,
            .rhs = want_tag,
        } }, self.mb.bool_type);
        const next_compare = if (i + 1 < case_count) try self.beginBlock("switch_next") else else_blk;
        try self.endBlock(.{ .cond_br = .{
            .condition = match_v,
            .then_block = case_blocks[i],
            .else_block = next_compare,
        } });
        compare_block = next_compare;
    }

    var fell_through = false;
    var reached_continuation = false;
    for (switch_stmt.cases, 0..) |case, i| {
        self.current_block = case_blocks[i];
        const is_catch_error = switch_stmt.catch_fallback and case.result_case == .err;
        if (is_catch_error) {
            self.currentBlock().catch_failure = sum_v;
        }
        try pushSwitchArm(self, cont_blk, result, &reached_continuation);
        defer _ = self.switch_stack.pop();
        if (is_catch_error) try self.catch_stack.append(self.mb.allocator, .{
            .carrier = sum_v,
            .binding_id = case.payload_binding_id,
            .failure_binding_id = switch_stmt.failure_binding_id,
        });
        defer {
            if (is_catch_error) _ = self.catch_stack.pop();
        }
        if (case.payload_name) |payload_name| {
            const payload_ty = try sumCasePayloadType(self, switch_stmt.subject_type_id, switch_stmt.subject_decl_id, sum_name, sum_v, case.case_name, case.result_case, case.union_ordinal);
            const payload_v = try emitExtractSumCasePayload(self, switch_stmt.subject_type_id, switch_stmt.subject_decl_id, sum_name, sum_v, case.case_name, case.result_case, case.union_ordinal, payload_ty);
            const moves_payload = (try @TypeOf(self.*).captureMatchSourceMovesPayload(self, switch_stmt.value)) or
                (drop_sum_value != null and try @TypeOf(self.*).typeNeedsDrop(self, payload_ty) and
                    !(try @TypeOf(self.*).typeHasSharedValueSemantics(self, payload_ty)));
            if (moves_payload) {
                try @TypeOf(self.*).lowerStmtListWithMovedCapturedLocal(self, payload_name, payload_ty, payload_v, case.body);
            } else {
                try @TypeOf(self.*).lowerStmtListWithCapturedLocalAndDrop(
                    self,
                    payload_name,
                    payload_ty,
                    payload_v,
                    drop_sum_value,
                    sum_ty,
                    case.body,
                );
            }
        } else {
            if (drop_sum_value) |owned_sum| {
                try @TypeOf(self.*).emitDropValue(self, owned_sum, sum_ty);
            }
            try lowerStmtList(self, case.body);
        }
        if (self.currentBlock().terminator == .none) {
            if (is_catch_error) try recordCatchExits(self, self.catch_stack.items.len - 1, null);
            try self.endBlock(.{ .br = cont_blk });
            fell_through = true;
        }
    }

    self.current_block = else_blk;
    if (!switch_stmt.has_else) {
        self.blocks.items[else_blk].terminator = .{ .@"unreachable" = {} };
    } else {
        try pushSwitchArm(self, cont_blk, result, &reached_continuation);
        defer _ = self.switch_stack.pop();
        if (drop_sum_value) |owned_sum| {
            try @TypeOf(self.*).emitDropValue(self, owned_sum, sum_ty);
        }
        try lowerStmtList(self, switch_stmt.else_body);
        if (self.currentBlock().terminator == .none) {
            try self.endBlock(.{ .br = cont_blk });
            fell_through = true;
        }
    }

    if (fell_through or reached_continuation or result != null) {
        self.current_block = cont_blk;
        return;
    }

    self.blocks.items[cont_blk].terminator = .{ .@"unreachable" = {} };
    self.current_block = cont_blk;
}

pub fn emitSumCaseTag(
    self: anytype,
    subject_type_id: ?sir.TypeId,
    subject_decl_id: ?identity.DeclId,
    sum_name: []const u8,
    case_name: []const u8,
    result_case: ?sir.ResultCase,
    union_ordinal: ?u32,
    tag_ty: lir.TypeId,
) LowerError!lir.ValueId {
    return switch ((try self.mb.canonicalTypeNode(subject_type_id)).*) {
        .result => try self.emit(.{ .const_bool = (result_case orelse return LowerError.InvalidIdentity) == .err }, tag_ty),
        .error_union => try self.emit(.{ .const_int = union_ordinal orelse return LowerError.InvalidIdentity }, tag_ty),
        .nominal => |nominal| if (nominal.kind == .@"union")
            try self.emit(.{ .const_int = try self.unionCaseTagResolved(subject_decl_id, sum_name, case_name) }, tag_ty)
        else
            error.LowerInvariantViolation,
        else => error.LowerInvariantViolation,
    };
}

pub fn emitEnumCaseValueResolved(
    self: anytype,
    decl_id: ?identity.DeclId,
    enum_name: []const u8,
    case_name: []const u8,
    enum_ty: lir.TypeId,
) LowerError!lir.ValueId {
    _ = enum_name;
    const decl = try self.mb.enumById(decl_id orelse return LowerError.InvalidIdentity);
    for (decl.cases) |enum_case| {
        if (std.mem.eql(u8, enum_case.name, case_name)) {
            return self.emit(.{ .const_int = enum_case.value }, enum_ty);
        }
    }
    return error.LowerInvariantViolation;
}

pub fn sumCasePayloadType(
    self: anytype,
    subject_type_id: ?sir.TypeId,
    subject_decl_id: ?identity.DeclId,
    sum_name: []const u8,
    sum_v: lir.ValueId,
    case_name: []const u8,
    result_case: ?sir.ResultCase,
    union_ordinal: ?u32,
) LowerError!lir.TypeId {
    return switch ((try self.mb.canonicalTypeNode(subject_type_id)).*) {
        .result => switch (result_case orelse return LowerError.InvalidIdentity) {
            .ok => try resultOkTypeFromValue(self, sum_v),
            .err => try resultErrTypeFromValue(self, sum_v),
        },
        .error_union => |members| try self.mb.lowerCanonicalType(members[union_ordinal orelse return LowerError.InvalidIdentity]),
        .nominal => |nominal| if (nominal.kind == .@"union")
            try self.unionCasePayloadTypeResolved(subject_decl_id, sum_name, case_name)
        else
            error.LowerInvariantViolation,
        else => error.LowerInvariantViolation,
    };
}

pub fn emitExtractSumCasePayload(
    self: anytype,
    subject_type_id: ?sir.TypeId,
    subject_decl_id: ?identity.DeclId,
    sum_name: []const u8,
    sum_v: lir.ValueId,
    case_name: []const u8,
    result_case: ?sir.ResultCase,
    union_ordinal: ?u32,
    payload_ty: lir.TypeId,
) LowerError!lir.ValueId {
    return switch ((try self.mb.canonicalTypeNode(subject_type_id)).*) {
        .result => try emitExtractResultCaseValue(self, sum_v, (result_case orelse return LowerError.InvalidIdentity) == .err, payload_ty),
        .error_union => try self.emit(.{ .extract_payload = .{
            .value = sum_v,
            .union_tag = union_ordinal orelse return LowerError.InvalidIdentity,
        } }, payload_ty),
        .nominal => |nominal| if (nominal.kind == .@"union") try self.emit(.{ .extract_payload = .{
            .value = sum_v,
            .union_tag = try self.unionCaseTagResolved(subject_decl_id, sum_name, case_name),
        } }, payload_ty) else error.LowerInvariantViolation,
        else => error.LowerInvariantViolation,
    };
}

pub fn resultOkTypeFromValue(self: anytype, result_v: lir.ValueId) LowerError!lir.TypeId {
    const result_ty = try lowerExprTypeFromValue(self, result_v);
    return switch (self.mb.types.items[result_ty]) {
        .result => |result_decl| result_decl.ok,
        else => error.LowerInvariantViolation,
    };
}

pub fn resultErrTypeFromValue(self: anytype, result_v: lir.ValueId) LowerError!lir.TypeId {
    const result_ty = try lowerExprTypeFromValue(self, result_v);
    return switch (self.mb.types.items[result_ty]) {
        .result => |result_decl| result_decl.err,
        else => error.LowerInvariantViolation,
    };
}

pub fn lowerExprTypeFromValue(self: anytype, value_id: lir.ValueId) LowerError!lir.TypeId {
    for (self.blocks.items) |block| {
        for (block.instructions) |inst| {
            if (inst.id != null and inst.id.? == value_id) {
                return inst.ty orelse return error.LowerInvariantViolation;
            }
        }
    }
    return error.LowerInvariantViolation;
}

// Iterable and result control-flow interface.
pub const ForIterableState = union(enum) {
    array_ptr: struct {
        ptr: lir.ValueId,
        ty: lir.TypeId,
    },
    slice_ptr: struct {
        ptr: lir.ValueId,
        ty: lir.TypeId,
    },
    sequence_ptr: struct {
        ptr: lir.ValueId,
        ty: lir.TypeId,
    },
    sparse_ptr: struct {
        ptr: lir.ValueId,
        ty: lir.TypeId,
    },
};

pub fn captureForIterable(self: anytype, expr: *sir.Expr, iterable_ty: lir.TypeId) LowerError!ForIterableState {
    const is_place = try @TypeOf(self.*).exprIsPlace(self, expr);
    return switch (self.mb.types.items[iterable_ty]) {
        .array => if (is_place) blk: {
            const place = try @TypeOf(self.*).lowerAddressablePlacePointer(self, expr);
            break :blk .{ .array_ptr = .{
                .ptr = place.ptr_value,
                .ty = iterable_ty,
            } };
        } else blk: {
            const tmp_name = try std.fmt.allocPrint(self.mb.allocator, "__for_array_{d}", .{self.locals_list.items.len});
            try self.mb.generated_names.append(self.mb.allocator, tmp_name);
            const local = try self.defineLocal(tmp_name, iterable_ty);
            const value = try self.lowerExpr(expr);
            try @TypeOf(self.*).captureExprValueInto(self, local.ptr_value, expr, value, iterable_ty);
            self.markCleanupActive(local);
            break :blk .{ .array_ptr = .{ .ptr = local.ptr_value, .ty = iterable_ty } };
        },
        .slice => blk: {
            const value = try self.lowerExpr(expr);
            const tmp_ptr = try self.emit(.{ .stack_alloc = iterable_ty }, iterable_ty);
            try self.emitVoid(.{ .store = .{ .ptr = tmp_ptr, .value = value } });
            break :blk .{ .slice_ptr = .{ .ptr = tmp_ptr, .ty = iterable_ty } };
        },
        .dense_array => if (is_place) blk: {
            const place = try @TypeOf(self.*).lowerAddressablePlacePointer(self, expr);
            break :blk .{ .sequence_ptr = .{
                .ptr = place.ptr_value,
                .ty = iterable_ty,
            } };
        } else blk: {
            const tmp_name = try std.fmt.allocPrint(self.mb.allocator, "__for_sequence_{d}", .{self.locals_list.items.len});
            try self.mb.generated_names.append(self.mb.allocator, tmp_name);
            const local = try self.defineLocal(tmp_name, iterable_ty);
            const value = try @TypeOf(self.*).materializeSequenceValue(self, expr);
            try @TypeOf(self.*).captureExprValueInto(self, local.ptr_value, expr, value, iterable_ty);
            self.markCleanupActive(local);
            break :blk .{ .sequence_ptr = .{
                .ptr = local.ptr_value,
                .ty = iterable_ty,
            } };
        },
        .sparse_array => if (is_place) blk: {
            const place = try @TypeOf(self.*).lowerAddressablePlacePointer(self, expr);
            break :blk .{ .sparse_ptr = .{
                .ptr = place.ptr_value,
                .ty = iterable_ty,
            } };
        } else blk: {
            const tmp_name = try std.fmt.allocPrint(self.mb.allocator, "__for_sparse_{d}", .{self.locals_list.items.len});
            try self.mb.generated_names.append(self.mb.allocator, tmp_name);
            const local = try self.defineLocal(tmp_name, iterable_ty);
            const value = try self.lowerExpr(expr);
            try @TypeOf(self.*).captureExprValueInto(self, local.ptr_value, expr, value, iterable_ty);
            self.markCleanupActive(local);
            break :blk .{ .sparse_ptr = .{
                .ptr = local.ptr_value,
                .ty = iterable_ty,
            } };
        },
        else => error.LowerInvariantViolation,
    };
}

pub fn forIterableLen(self: anytype, state: ForIterableState) LowerError!lir.ValueId {
    return switch (state) {
        .array_ptr => |array_state| blk: {
            break :blk switch (self.mb.types.items[array_state.ty]) {
                .array => |array_ty| try self.emit(.{ .const_int = @intCast(array_ty.len) }, self.mb.i64_type),
                else => return error.LowerInvariantViolation,
            };
        },
        .slice_ptr => |slice_state| blk: {
            const slice_value = try self.emit(.{ .load = slice_state.ptr }, slice_state.ty);
            break :blk try self.emit(.{ .extract_slice_len = slice_value }, self.mb.i64_type);
        },
        .sequence_ptr => |sequence| blk: {
            const sequence_value = try self.emit(.{ .load = sequence.ptr }, sequence.ty);
            break :blk try @TypeOf(self.*).emitSequenceLenValue(self, sequence_value, sequence.ty, self.mb.i64_type);
        },
        .sparse_ptr => |sparse| blk: {
            const sparse_value = try self.emit(.{ .load = sparse.ptr }, sparse.ty);
            break :blk try self.emit(.{ .sparse_capacity = sparse_value }, self.mb.i64_type);
        },
    };
}

// Contiguous storage returns an element address; sparse storage returns an owned copy.
pub fn forIterableItem(
    self: anytype,
    state: ForIterableState,
    index_value: lir.ValueId,
    item_ty: lir.TypeId,
) LowerError!lir.ValueId {
    const item_ptr_ty = try self.mb.appendType(.{ .pointer = item_ty });
    return switch (state) {
        .array_ptr => |array_state| blk: {
            const item_ptr = try self.emit(.{ .index_ptr = .{
                .ptr = array_state.ptr,
                .index = index_value,
            } }, item_ptr_ty);
            break :blk item_ptr;
        },
        .slice_ptr => |slice_state| blk: {
            const slice_value = try self.emit(.{ .load = slice_state.ptr }, slice_state.ty);
            const base_ptr = try self.emit(.{ .extract_slice_ptr = slice_value }, item_ptr_ty);
            const item_ptr = try self.emit(.{ .index_ptr = .{
                .ptr = base_ptr,
                .index = index_value,
            } }, item_ptr_ty);
            break :blk item_ptr;
        },
        .sequence_ptr => |sequence| blk: {
            const sequence_value = try self.emit(.{ .load = sequence.ptr }, sequence.ty);
            const item_ptr = try @TypeOf(self.*).emitSequenceAtValue(self, sequence_value, sequence.ty, item_ty, index_value);
            break :blk item_ptr;
        },
        .sparse_ptr => |sparse| blk: {
            const payload_ty = switch (self.mb.types.items[item_ty]) {
                .optional => |payload| payload,
                else => return error.LowerInvariantViolation,
            };
            const sparse_value = try self.emit(.{ .load = sparse.ptr }, sparse.ty);
            const tmp_ptr = try self.emit(.{ .stack_alloc = payload_ty }, payload_ty);
            const found = try self.emit(.{ .sparse_get = .{
                .a = sparse_value,
                .b = index_value,
                .c = tmp_ptr,
                .d = try @TypeOf(self.*).emitTypeDesc(self, payload_ty),
            } }, self.mb.bool_type);
            const result_ptr = try self.emit(.{ .stack_alloc = item_ty }, item_ty);
            const some_blk = try self.beginBlock("for_sparse_some");
            const none_blk = try self.beginBlock("for_sparse_none");
            const cont_blk = try self.beginBlock("for_sparse_cont");
            try self.endBlock(.{ .cond_br = .{
                .condition = found,
                .then_block = some_blk,
                .else_block = none_blk,
            } });

            self.current_block = some_blk;
            const payload = try self.emit(.{ .load = tmp_ptr }, payload_ty);
            const some_value = try self.emit(.{ .make_some = payload }, item_ty);
            try self.emitVoid(.{ .store = .{ .ptr = result_ptr, .value = some_value } });
            try self.endBlock(.{ .br = cont_blk });

            self.current_block = none_blk;
            const none_value = try self.emit(.make_none, item_ty);
            try self.emitVoid(.{ .store = .{ .ptr = result_ptr, .value = none_value } });
            try self.endBlock(.{ .br = cont_blk });

            self.current_block = cont_blk;
            break :blk try self.emit(.{ .load = result_ptr }, item_ty);
        },
    };
}

pub fn lowerTryExprFromNode(self: anytype, try_expr: sir.TryExpr) LowerError!lir.ValueId {
    return lowerTryResultExpr(self, try_expr.expr, try_expr.widen_ordinal, try_expr.site_line);
}

pub fn lowerTryResultExpr(self: anytype, expr: *sir.Expr, widen_ordinal: ?u32, site_line: u32) LowerError!lir.ValueId {
    const result_ty = self.result_return_type orelse return error.LowerInvariantViolation;
    const source_type_id = (try self.mb.canonicalTypeNode((try self.mb.exprMetadata(expr)).type_id)).result.err;
    const result_v = try self.lowerExpr(expr);
    const lowered_result_ty = try @TypeOf(self.*).lowerExprType(self, expr);
    const payload_ty = switch (self.mb.types.items[lowered_result_ty]) {
        .result => |decl| decl.ok,
        else => return error.LowerInvariantViolation,
    };
    const ok_blk = try self.beginBlock("try_ok");
    const err_blk = try self.beginBlock("try_err");
    const cont_blk = try self.beginBlock("try_cont");

    const tag_v = try self.emit(.{ .extract_tag = result_v }, self.mb.bool_type);
    try self.endBlock(.{ .cond_br = .{
        .condition = tag_v,
        .then_block = err_blk,
        .else_block = ok_blk,
    } });

    self.current_block = ok_blk;
    if (payload_ty == self.mb.void_type) {
        try @TypeOf(self.*).emitDropValue(self, result_v, lowered_result_ty);
        try self.endBlock(.{ .br = cont_blk });
    } else {
        const tmp_ptr = try self.emit(.{ .stack_alloc = payload_ty }, payload_ty);
        const payload_v = try emitExtractResultCaseValue(self, result_v, false, payload_ty);
        try @TypeOf(self.*).copyValueInto(self, tmp_ptr, payload_v, payload_ty);
        try @TypeOf(self.*).emitDropValue(self, result_v, lowered_result_ty);
        try self.endBlock(.{ .br = cont_blk });

        self.current_block = err_blk;
        {
            const err_ty = try resultErrTypeFromValue(self, result_v);
            const err_v = try emitExtractResultCaseValue(self, result_v, true, err_ty);
            const propagated_err = try widenTryError(self, result_ty, err_v, widen_ordinal, source_type_id);
            const propagated = try lowerResultCaseValue(self, result_ty, .err, propagated_err, null, true, .{ .transfer = .{ .carrier = result_v, .append_site = site_line } });
            try @TypeOf(self.*).emitDropValue(self, result_v, lowered_result_ty);
            try @TypeOf(self.*).emitDefersFrom(self, 0, "return");
            try @TypeOf(self.*).emitAutoDropsFrom(self, 0, "return");
            try recordCatchExits(self, 0, null);
            try self.endBlock(.{ .@"return" = propagated });
        }

        self.current_block = cont_blk;
        return self.emit(.{ .load = tmp_ptr }, payload_ty);
    }

    self.current_block = err_blk;
    {
        const err_ty = try resultErrTypeFromValue(self, result_v);
        const err_v = try emitExtractResultCaseValue(self, result_v, true, err_ty);
        const propagated_err = try widenTryError(self, result_ty, err_v, widen_ordinal, source_type_id);
        const propagated = try lowerResultCaseValue(self, result_ty, .err, propagated_err, null, true, .{ .transfer = .{ .carrier = result_v, .append_site = site_line } });
        try @TypeOf(self.*).emitDropValue(self, result_v, lowered_result_ty);
        try @TypeOf(self.*).emitDefersFrom(self, 0, "return");
        try @TypeOf(self.*).emitAutoDropsFrom(self, 0, "return");
        try recordCatchExits(self, 0, null);
        try self.endBlock(.{ .@"return" = propagated });
    }

    self.current_block = cont_blk;
    return result_v;
}

fn widenTryError(self: anytype, result_ty: lir.TypeId, err_v: lir.ValueId, ordinal: ?u32, source_type_id: sir.TypeId) LowerError!lir.ValueId {
    const err_ty = switch (self.mb.types.items[result_ty]) {
        .result => |decl| decl.err,
        else => return error.LowerInvariantViolation,
    };
    if (ordinal == null) {
        const target_type_id = self.result_return_error_type_id orelse return error.LowerInvariantViolation;
        if (source_type_id == target_type_id) return err_v;
        const source_ty = try lowerExprTypeFromValue(self, err_v);
        const source_cases = switch (self.mb.types.items[source_ty]) {
            .@"union" => |decl| decl.payloads,
            else => return err_v,
        };
        const target_cases = switch (self.mb.types.items[err_ty]) {
            .@"union" => |decl| decl.payloads,
            else => return error.LowerInvariantViolation,
        };
        const source_tag = try self.emit(.{ .extract_tag = err_v }, self.mb.i64_type);
        const result_ptr = try self.emit(.{ .stack_alloc = err_ty }, err_ty);
        const cont_blk = try self.beginBlock("try_union_widen_cont");
        var compare_blk = self.current_block;
        for (source_cases, 0..) |maybe_payload_ty, source_ordinal| {
            const payload_ty = maybe_payload_ty orelse return error.LowerInvariantViolation;
            const source_member = try errorUnionMemberType(self, source_type_id, source_ordinal);
            const target_ordinal = for (target_cases, 0..) |_, index| {
                if (try errorUnionMemberType(self, target_type_id, index) == source_member) break @as(u32, @intCast(index));
            } else return error.LowerInvariantViolation;
            self.current_block = compare_blk;
            const case_blk = try self.beginBlock("try_union_widen_case");
            const next_blk = try self.beginBlock("try_union_widen_next");
            const want_tag = try self.emit(.{ .const_int = @intCast(source_ordinal) }, self.mb.i64_type);
            const matches = try self.emit(.{ .int_cmp = .{ .op = .eq, .lhs = source_tag, .rhs = want_tag } }, self.mb.bool_type);
            try self.endBlock(.{ .cond_br = .{ .condition = matches, .then_block = case_blk, .else_block = next_blk } });
            self.current_block = case_blk;
            const payload = try self.emit(.{ .extract_payload = .{ .value = err_v, .union_tag = @intCast(source_ordinal) } }, payload_ty);
            const widened = try self.emit(.{ .make_union = .{ .tag = target_ordinal, .payload = payload } }, err_ty);
            try self.emitVoid(.{ .store = .{ .ptr = result_ptr, .value = widened } });
            try self.endBlock(.{ .br = cont_blk });
            compare_blk = next_blk;
        }
        self.current_block = compare_blk;
        try self.endBlock(.{ .@"unreachable" = {} });
        self.current_block = cont_blk;
        return self.emit(.{ .load = result_ptr }, err_ty);
    }
    const tag = ordinal.?;
    const cases = switch (self.mb.types.items[err_ty]) {
        .@"union" => |decl| decl.payloads,
        else => return error.LowerInvariantViolation,
    };
    if (tag >= cases.len or cases[tag] == null) return error.LowerInvariantViolation;
    return self.emit(.{ .make_union = .{ .tag = tag, .payload = err_v } }, err_ty);
}

fn errorUnionMemberType(self: anytype, union_type_id: sir.TypeId, ordinal: usize) LowerError!sir.TypeId {
    return switch ((try self.mb.canonicalTypeNode(union_type_id)).*) {
        .error_union => |members| if (ordinal < members.len) members[ordinal] else error.LowerInvariantViolation,
        .nominal => |nominal| blk: {
            if (nominal.kind != .@"union") return error.LowerInvariantViolation;
            const decl = try self.mb.unionById(nominal.decl_id);
            if (ordinal >= decl.fields.len) return error.LowerInvariantViolation;
            break :blk decl.fields[ordinal].type_id orelse return error.LowerInvariantViolation;
        },
        else => error.LowerInvariantViolation,
    };
}

pub fn lowerResultCaseValue(
    self: anytype,
    result_ty: lir.TypeId,
    result_case: sir.ResultCase,
    payload: ?lir.ValueId,
    payload_expr: ?*sir.Expr,
    payload_is_aliased: bool,
    trace: lir.TraceAction,
) LowerError!lir.ValueId {
    return switch (result_case) {
        .ok => blk: {
            const ok_ty = switch (self.mb.types.items[result_ty]) {
                .result => |result_decl| result_decl.ok,
                else => return error.LowerInvariantViolation,
            };
            const result_payload = if (payload) |payload_value|
                if (payload_is_aliased)
                    try @TypeOf(self.*).captureAliasedValue(self, payload_value, ok_ty)
                else
                    try @TypeOf(self.*).prepareCapturedExprValue(self, payload_expr, payload_value, ok_ty)
            else
                null;
            break :blk self.emit(.{ .make_result = .{
                .is_err = false,
                .payload = result_payload,
            } }, result_ty);
        },
        .err => blk: {
            const err_ty = switch (self.mb.types.items[result_ty]) {
                .result => |result_decl| result_decl.err,
                else => return error.LowerInvariantViolation,
            };
            const result_payload = if (payload_is_aliased)
                try @TypeOf(self.*).captureAliasedValue(self, payload orelse return error.LowerInvariantViolation, err_ty)
            else
                try @TypeOf(self.*).prepareCapturedExprValue(self, payload_expr, payload orelse return error.LowerInvariantViolation, err_ty);
            break :blk self.emit(.{ .make_result = .{
                .is_err = true,
                .payload = result_payload,
                .trace = trace,
            } }, result_ty);
        },
    };
}

pub fn traceActionForResultCase(self: anytype, result_case: sir.ResultCase, case: sir.UnionCaseExpr) LowerError!lir.TraceAction {
    if (result_case != .err or !case.from_throw) return .none;
    if (case.throw_message == null) {
        if (case.throw_local_binding_id) |binding_id| {
            var i = self.catch_stack.items.len;
            while (i != 0) {
                i -= 1;
                const scope = self.catch_stack.items[i];
                if (scope.binding_id != null and scope.binding_id.? == binding_id) {
                    return .{ .transfer = .{ .carrier = scope.carrier } };
                }
            }
        }
    }
    const message_value = if (case.throw_message) |message| blk: {
        const copy = try self.mb.allocator.dupe(u8, message);
        errdefer self.mb.allocator.free(copy);
        break :blk try self.emit(.{ .const_string = copy }, self.mb.string_type);
    } else null;
    return .{ .create = .{ .origin = case.throw_source_line, .message = message_value } };
}

pub fn emitExtractResultCaseValue(self: anytype, result_v: lir.ValueId, is_err: bool, ty: lir.TypeId) LowerError!lir.ValueId {
    return self.emit(.{ .extract_result = .{
        .value = result_v,
        .is_err = is_err,
    } }, ty);
}

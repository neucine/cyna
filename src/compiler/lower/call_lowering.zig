const sir = @import("../sema/sir.zig");
const lir = @import("lir.zig");
const errors = @import("errors.zig");
const LowerError = errors.Error;

/// Resolve the callee of a call from its checked use record. Every lowered call
/// carries the concrete declaration it settles to, so lowering takes that
/// identity and never falls back to a name or an unverified declaration id.
fn callCalleeFunction(self: anytype, call: sir.Call) LowerError!sir.Function {
    const use = call.checked_method_use orelse return LowerError.InvalidIdentity;
    const declaration_id = use.callee_declaration_id orelse return LowerError.InvalidIdentity;
    return self.mb.functionById(declaration_id);
}

pub fn lowerCall(self: anytype, call: sir.Call) LowerError!lir.ValueId {
    const callee = try callCalleeFunction(self, call);
    const args = try self.mb.allocator.alloc(lir.ValueId, call.args.len);
    errdefer self.mb.allocator.free(args);
    const params = try @TypeOf(self.*).lowerParams(self, callee.params);
    defer self.mb.allocator.free(params);
    const cleanup_start = self.ownership.cleanup_entries.items.len;
    for (call.args, params, args) |arg, param, *dst| {
        dst.* = switch (arg) {
            .value => |expr| blk: {
                const arg_value = try @TypeOf(self.*).lowerExprForTarget(self, expr, param.ty);
                if (self.mb.types.items[param.ty] == .@"struct" and
                    self.mb.types.items[param.ty].@"struct".drop_runtime == .task_discard and expr.* == .local)
                {
                    self.markCleanupInactive(try self.getLocal(expr.local));
                }
                break :blk try @TypeOf(self.*).prepareCapturedExprValue(self, expr, arg_value, param.ty);
            },
        };
    }

    const result = try self.emit(.{ .call = .{
        .name = try self.mb.emittedFunctionName(callee.module_name, callee.owner, callee.name, callee.abi_name, callee.calling_convention == .c, callee.is_test_entry),
        .args = args,
    } }, try self.lowerCallReturnType(call));
    try @TypeOf(self.*).emitFullExpressionAutoDropsFrom(self, cleanup_start, "call");
    return result;
}

pub fn lowerThreadSpawnBoxed(self: anytype, spawn: sir.ThreadSpawnBoxed) LowerError!lir.ValueId {
    if (spawn.decl_id == null or spawn.trampoline.decl_id == null) return LowerError.InvalidIdentity;
    const callee = try self.mb.functionById(spawn.decl_id.?);
    const payload_ty = try self.mb.lowerCanonicalType(spawn.payload_type_id);
    const return_ty = try self.mb.lowerCanonicalType(spawn.return_type_id);
    const cleanup_start = self.ownership.cleanup_entries.items.len;

    const lowered_payload = try @TypeOf(self.*).lowerExprForTarget(self, spawn.payload, payload_ty);
    const payload_value = try @TypeOf(self.*).prepareCapturedExprValue(self, spawn.payload, lowered_payload, payload_ty);
    const payload_ptr = try @TypeOf(self.*).emitStoredTemp(self, payload_ty, payload_value);
    const desc = try @TypeOf(self.*).emitTypeDesc(self, payload_ty);

    const args = try self.mb.allocator.alloc(lir.ValueId, 3);
    errdefer self.mb.allocator.free(args);
    const trampoline_name = try self.mb.functionSymbol(spawn.trampoline);
    const ptr_ty = try self.mb.appendType(.{ .pointer = self.mb.void_type });
    args[0] = try self.emit(.{ .global_addr = try self.mb.allocator.dupe(u8, trampoline_name) }, ptr_ty);
    args[1] = payload_ptr;
    args[2] = desc;

    const result = try self.emit(.{ .call = .{
        .name = try self.mb.emittedFunctionName(callee.module_name, callee.owner, callee.name, callee.abi_name, callee.calling_convention == .c, callee.is_test_entry),
        .args = args,
    } }, return_ty);
    try @TypeOf(self.*).emitFullExpressionAutoDropsFrom(self, cleanup_start, "thread_spawn_boxed");
    return result;
}

pub fn lowerTaskGroupSpawnBoxed(self: anytype, spawn: sir.TaskGroupSpawnBoxed) LowerError!lir.ValueId {
    if (spawn.decl_id == null or spawn.trampoline.decl_id == null) return LowerError.InvalidIdentity;
    const callee = try self.mb.functionById(spawn.decl_id.?);
    const params = try @TypeOf(self.*).lowerParams(self, callee.params);
    defer self.mb.allocator.free(params);
    if (params.len != 6) return LowerError.InvalidIdentity;
    const payload_ty = try self.mb.lowerCanonicalType(spawn.payload_type_id);
    const result_payload_ty = try self.mb.lowerCanonicalType(spawn.result_type_id);
    const return_ty = try self.mb.lowerCanonicalType(spawn.return_type_id);
    const cleanup_start = self.ownership.cleanup_entries.items.len;

    const group_raw = try @TypeOf(self.*).lowerExprForTarget(self, spawn.group_raw, params[0].ty);
    const entry_ctx = try @TypeOf(self.*).lowerExprForTarget(self, spawn.entry, params[2].ty);
    const lowered_payload = try @TypeOf(self.*).lowerExprForTarget(self, spawn.payload, payload_ty);
    if (spawn.payload.* == .local and try @TypeOf(self.*).typeNeedsDrop(self, payload_ty)) {
        self.markCleanupInactive(try self.getLocal(spawn.payload.local));
    }
    const payload_ptr = try @TypeOf(self.*).emitStoredTemp(self, payload_ty, lowered_payload);

    const args = try self.mb.allocator.alloc(lir.ValueId, 6);
    errdefer self.mb.allocator.free(args);
    const trampoline_name = try self.mb.functionSymbol(spawn.trampoline);
    const ptr_ty = try self.mb.appendType(.{ .pointer = self.mb.void_type });
    args[0] = group_raw;
    args[1] = try self.emit(.{ .global_addr = try self.mb.allocator.dupe(u8, trampoline_name) }, ptr_ty);
    args[2] = entry_ctx;
    args[3] = payload_ptr;
    args[4] = try @TypeOf(self.*).emitTypeDesc(self, payload_ty);
    // A void task has no Cyna value to store. The native box still needs a
    // valid allocation descriptor, so reserve one inert byte for its result.
    const result_box_ty = if (result_payload_ty == self.mb.void_type)
        try self.mb.appendType(.{ .int = .{ .bits = 8, .signed = false } })
    else
        result_payload_ty;
    args[5] = try @TypeOf(self.*).emitTypeDesc(self, result_box_ty);
    const result = try self.emit(.{ .call = .{
        .name = try self.mb.emittedFunctionName(callee.module_name, callee.owner, callee.name, callee.abi_name, callee.calling_convention == .c, callee.is_test_entry),
        .args = args,
    } }, return_ty);
    try @TypeOf(self.*).emitFullExpressionAutoDropsFrom(self, cleanup_start, "task_group_spawn_boxed");
    return result;
}

pub fn lowerTaskResultTake(self: anytype, take: sir.TaskResultTake) LowerError!lir.ValueId {
    const value_ty = try self.mb.lowerCanonicalType(take.value_type_id);
    const return_ty = try self.mb.lowerCanonicalType(take.return_type_id);
    const pointer = try self.lowerExpr(take.pointer);
    const payload: ?lir.ValueId = if (value_ty == self.mb.void_type) null else blk: {
        const value_ptr_ty = try self.mb.appendType(.{ .pointer = value_ty });
        const casted = try self.emit(.{ .bitcast = pointer }, value_ptr_ty);
        break :blk try self.emit(.{ .load = casted }, value_ty);
    };
    _ = try self.emit(.{ .call = .{
        .name = "cyna_std_thread_task_result_free_raw",
        .args = try @TypeOf(self.*).dupeArgs(self, &.{pointer}),
    } }, self.mb.void_type);
    return self.emit(.{ .make_result = .{ .is_err = false, .payload = payload } }, return_ty);
}

pub fn lowerSyncShareBoxed(self: anytype, share: sir.SyncShareBoxed) LowerError!lir.ValueId {
    const callee = try self.mb.functionById(share.decl_id orelse return LowerError.InvalidIdentity);
    const payload_ty = try self.mb.lowerCanonicalType(share.payload_type_id);
    const return_ty = try self.mb.lowerCanonicalType(share.return_type_id);
    const cleanup_start = self.ownership.cleanup_entries.items.len;

    const lowered_payload = try @TypeOf(self.*).lowerExprForTarget(self, share.payload, payload_ty);
    const payload_value = try @TypeOf(self.*).prepareCapturedExprValue(self, share.payload, lowered_payload, payload_ty);
    const payload_ptr = try @TypeOf(self.*).emitStoredTemp(self, payload_ty, payload_value);
    const desc = try @TypeOf(self.*).emitTypeDesc(self, payload_ty);

    const args = try self.mb.allocator.alloc(lir.ValueId, 2);
    errdefer self.mb.allocator.free(args);
    args[0] = payload_ptr;
    args[1] = desc;

    const handle = try self.emit(.{ .call = .{
        .name = try self.mb.emittedFunctionName(callee.module_name, callee.owner, callee.name, callee.abi_name, callee.calling_convention == .c, callee.is_test_entry),
        .args = args,
    } }, try self.mb.lowerCanonicalType(callee.return_type_id));

    const fields = try self.mb.allocator.alloc(lir.ValueId, 1);
    errdefer self.mb.allocator.free(fields);
    fields[0] = handle;
    const result = try self.emit(.{ .make_struct = .{ .fields = fields } }, return_ty);
    try @TypeOf(self.*).emitFullExpressionAutoDropsFrom(self, cleanup_start, "sync_share_boxed");
    return result;
}

pub fn lowerClosure(self: anytype, closure: sir.Closure) LowerError!lir.ValueId {
    if (closure.function.decl_id == null) return LowerError.InvalidIdentity;
    const closure_ty = try self.mb.lowerArrowCallableType();
    const closure_decl = switch (self.mb.types.items[closure_ty]) {
        .@"struct" => |decl| decl,
        else => return error.LowerInvariantViolation,
    };
    const fields = try self.mb.allocator.alloc(lir.ValueId, 2);
    errdefer self.mb.allocator.free(fields);

    const symbol_name = try self.mb.functionSymbol(closure.function);
    fields[0] = try self.emit(.{ .global_addr = try self.mb.allocator.dupe(u8, symbol_name) }, closure_decl.fields[0].ty);
    fields[1] = if (closure.captures.len == 0) blk: {
        const zero = try self.emit(.{ .const_int = 0 }, self.mb.i64_type);
        break :blk try self.emit(.{ .int_to_ptr = zero }, closure_decl.fields[1].ty);
    } else blk: {
        const env_ty = try self.mb.lowerStructTypeById(closure.env_decl_id orelse return LowerError.InvalidIdentity);
        const env_decl = switch (self.mb.types.items[env_ty]) {
            .@"struct" => |decl| decl,
            else => return error.LowerInvariantViolation,
        };
        if (env_decl.fields.len != closure.captures.len) return error.LowerInvariantViolation;
        const env_fields = try self.mb.allocator.alloc(lir.ValueId, closure.captures.len);
        errdefer self.mb.allocator.free(env_fields);
        for (closure.captures, env_decl.fields, env_fields) |capture, field, *out_field| {
            const value = try @TypeOf(self.*).lowerExprForTarget(self, capture, field.ty);
            out_field.* = try @TypeOf(self.*).captureAliasedValue(self, value, field.ty);
        }
        const env_value = try self.emit(.{ .make_struct = .{ .fields = env_fields } }, env_ty);
        const env_ptr = try self.emit(.{ .stack_alloc = env_ty }, env_ty);
        try self.emitVoid(.{ .store = .{ .ptr = env_ptr, .value = env_value } });
        try self.registerCompilerTemporaryCleanup("closure_env", env_ptr, env_ty);
        break :blk env_ptr;
    };

    return self.emit(.{ .make_struct = .{ .fields = fields } }, closure_ty);
}

pub fn lowerClosureCapture(self: anytype, capture: sir.ClosureCapture) LowerError!lir.ValueId {
    const env_local = try self.getLocal(capture.env_name);
    const env_ptr = try self.emit(.{ .load = env_local.ptr_value }, env_local.ty);
    const env_ty = try self.mb.lowerStructTypeById(capture.env_decl_id);
    const env_decl = switch (self.mb.types.items[env_ty]) {
        .@"struct" => |decl| decl,
        else => return error.LowerInvariantViolation,
    };
    if (capture.field_index >= env_decl.fields.len) return error.LowerInvariantViolation;
    const env_value = try self.emit(.{ .load = env_ptr }, env_ty);
    const value = try self.emit(.{ .extract_field = .{
        .value = env_value,
        .field_index = capture.field_index,
    } }, env_decl.fields[capture.field_index].ty);
    return @TypeOf(self.*).captureAliasedValue(self, value, env_decl.fields[capture.field_index].ty);
}

pub fn lowerIndirectCall(self: anytype, call: sir.IndirectCall) LowerError!lir.ValueId {
    const cleanup_start = self.ownership.cleanup_entries.items.len;
    const callee = try self.lowerExpr(call.callee);
    const extra_arg_count: usize = if (call.is_arrow_callable) 1 else 0;
    const args = try self.mb.allocator.alloc(lir.ValueId, call.args.len + extra_arg_count);
    errdefer self.mb.allocator.free(args);
    const address_args = try self.mb.allocator.alloc(bool, args.len);
    errdefer self.mb.allocator.free(address_args);
    @memset(address_args, false);
    const callee_value = if (call.is_arrow_callable) blk: {
        const closure_ty = try self.mb.lowerArrowCallableType();
        const closure_decl = switch (self.mb.types.items[closure_ty]) {
            .@"struct" => |decl| decl,
            else => return error.LowerInvariantViolation,
        };
        const thunk = try self.emit(.{ .extract_field = .{
            .value = callee,
            .field_index = 0,
        } }, closure_decl.fields[0].ty);
        args[0] = try self.emit(.{ .extract_field = .{
            .value = callee,
            .field_index = 1,
        } }, closure_decl.fields[1].ty);
        break :blk thunk;
    } else callee;
    for (call.args, args[extra_arg_count..], address_args[extra_arg_count..]) |arg, *dst, *address_arg| {
        dst.* = switch (arg) {
            .value => |expr| blk: {
                address_arg.* = switch (expr.*) {
                    .ref_local, .ref_global, .ref_field_local, .ref_field_owned_local, .ref_field_expr, .ref_index_local, .ref_index_path_local, .ref_path_local, .ref_owned_local => true,
                    else => false,
                };
                const ty = try self.lowerExprType(expr);
                const value = try self.lowerExprForTarget(expr, ty);
                break :blk try @TypeOf(self.*).prepareCapturedExprValue(self, expr, value, ty);
            },
        };
    }

    const result = try self.emit(.{ .indirect_call = .{
        .callee = callee_value,
        .args = args,
        .address_args = address_args,
    } }, try self.mb.lowerCanonicalType(call.return_type_id));
    try @TypeOf(self.*).emitFullExpressionAutoDropsFrom(self, cleanup_start, "indirect_call");
    return result;
}

pub fn lowerCallReturnType(self: anytype, call: sir.Call) LowerError!lir.TypeId {
    const callee = try callCalleeFunction(self, call);
    return self.mb.lowerCanonicalType(callee.return_type_id);
}

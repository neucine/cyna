const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../../compat.zig");
const sir = @import("../sema/sir.zig");
const lexer = @import("../lexer/lexer.zig");
const runtime_symbols = @import("../../runtime/symbols.zig");
const generated_names = @import("../generated_names.zig");
const language_contracts = @import("../language_contracts.zig");
const identity = @import("../sema/identity.zig");
const semantic_types = @import("../sema/types.zig");
const lir = @import("lir.zig");
const lower_errors = @import("errors.zig");
const module_index = @import("module_index.zig");
const type_lowering = @import("type_lowering.zig");
const type_policy = @import("type_policy.zig");
const expression_lowering = @import("expression_lowering.zig");
const function_lowering = @import("function_lowering.zig");
const call_lowering = @import("call_lowering.zig");
const container_lowering = @import("container_lowering.zig");
const place_lowering = @import("place_lowering.zig");
const ownership_lowering = @import("ownership_lowering.zig");
const target_info = @import("../target.zig");

pub const LowerError = lower_errors.Error;

pub const DebugSourceMapEntry = struct {
    module_name: []const u8,
    source_path: []const u8,
};

pub const LowerOptions = struct {
    debug_source_map: []const DebugSourceMapEntry = &.{},
    fallback_source_path: ?[]const u8 = null,
    target: ?[]const u8 = null,
    /// When set, lower definitions for only this source module. Declarations
    /// from other modules remain available as externs so cross-module calls
    /// and global references keep resolving.
    module_name: ?[]const u8 = null,
};

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn lowerModule(allocator: std.mem.Allocator, sir_mod: sir.Module) LowerError!lir.Module {
    return lowerModuleWithOptions(allocator, sir_mod, .{});
}

pub fn lowerModuleWithOptions(allocator: std.mem.Allocator, sir_mod: sir.Module, options: LowerOptions) LowerError!lir.Module {
    try sir_mod.verify();
    var builder = ModuleBuilder.init(allocator, sir_mod, options);
    defer builder.deinit();

    try builder.initBuiltinTypes();
    try builder.buildExprMetadataIndex();
    try builder.buildDeclarationIndexes();
    try builder.lowerGlobals();
    try builder.lowerFunctions();

    return .{
        .types = try builder.types.toOwnedSlice(allocator),
        .globals = try builder.globals.toOwnedSlice(allocator),
        .functions = try builder.functions.toOwnedSlice(allocator),
        .generated_names = try builder.generated_names.toOwnedSlice(allocator),
        .target_abi = target_info.abiLayout(options.target),
    };
}

const ModuleBuilder = struct {
    allocator: std.mem.Allocator,
    sir_mod: sir.Module,
    options: LowerOptions,
    types: std.ArrayListUnmanaged(lir.TypeDecl) = .empty,
    globals: std.ArrayListUnmanaged(lir.Global) = .empty,
    functions: std.ArrayListUnmanaged(lir.Function) = .empty,
    generated_names: std.ArrayListUnmanaged([]const u8) = .empty,
    union_types: std.StringHashMapUnmanaged(lir.TypeId) = .empty,
    struct_types: std.StringHashMapUnmanaged(lir.TypeId) = .empty,
    indexes: module_index.Indexes = .{},
    expr_metadata: std.AutoHashMapUnmanaged(*const sir.Expr, sir.ExprMetadata) = .empty,
    arrow_callable_type: ?lir.TypeId = null,

    void_type: lir.TypeId = 0,
    bool_type: lir.TypeId = 0,
    i64_type: lir.TypeId = 0,
    f32_type: lir.TypeId = 0,
    f64_type: lir.TypeId = 0,
    string_type: lir.TypeId = 0,

    pub fn init(allocator: std.mem.Allocator, sir_mod: sir.Module, options: LowerOptions) ModuleBuilder {
        return .{ .allocator = allocator, .sir_mod = sir_mod, .options = options };
    }

    pub fn deinit(self: *ModuleBuilder) void {
        for (self.types.items) |ty| ty.deinit(self.allocator);
        self.types.deinit(self.allocator);
        for (self.globals.items) |global| global.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        for (self.functions.items) |function| function.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        for (self.generated_names.items) |name| self.allocator.free(name);
        self.generated_names.deinit(self.allocator);
        self.union_types.deinit(self.allocator);
        self.struct_types.deinit(self.allocator);
        self.indexes.deinit(self.allocator);
        self.expr_metadata.deinit(self.allocator);
    }

    pub fn initBuiltinTypes(self: *ModuleBuilder) LowerError!void {
        self.void_type = try self.appendType(.void);
        self.bool_type = try self.appendType(.bool);
        self.i64_type = try self.appendType(.{ .int = .{ .bits = 64, .signed = true } });
        self.f32_type = try self.appendType(.{ .float = .{ .bits = 32 } });
        self.f64_type = try self.appendType(.{ .float = .{ .bits = 64 } });
        self.string_type = try self.appendType(.string);
    }

    pub fn buildExprMetadataIndex(self: *ModuleBuilder) LowerError!void {
        try self.expr_metadata.ensureTotalCapacity(self.allocator, @intCast(self.sir_mod.expr_metadata.len));
        for (self.sir_mod.expr_metadata) |entry| {
            if (!entry.metadata.semantics.isValid()) return LowerError.InvalidIdentity;
            if (!entry.metadata.consumption.isValid(entry.metadata.semantics)) return LowerError.InvalidIdentity;
            _ = try self.canonicalTypeNode(entry.metadata.type_id);
            const result = self.expr_metadata.getOrPutAssumeCapacity(entry.expr);
            if (result.found_existing) return LowerError.InvalidIdentity;
            result.value_ptr.* = entry.metadata;
        }
    }

    pub fn emittedFunctionName(
        self: *ModuleBuilder,
        module_name: []const u8,
        owner: ?[]const u8,
        name: []const u8,
        abi_name: ?[]const u8,
        is_c_abi: bool,
        is_test_entry: bool,
    ) LowerError![]const u8 {
        if (abi_name) |symbol| return symbol;
        if (is_c_abi) return name;
        if (owner == null and std.mem.eql(u8, name, "main")) return name;
        if (is_test_entry) return name;

        var hasher = std.hash.Wyhash.init(0);
        hasher.update(module_name);
        hasher.update("::");
        if (owner) |owner_name| {
            hasher.update(owner_name);
            hasher.update("::");
        }
        hasher.update(name);
        const hash = hasher.final();
        const symbol = try std.fmt.allocPrint(self.allocator, "{s}{x}_{s}", .{ generated_names.function_symbol_prefix, hash, name });
        try self.generated_names.append(self.allocator, symbol);
        return symbol;
    }

    pub fn functionSymbol(self: *ModuleBuilder, ref: sir.FunctionRef) LowerError![]const u8 {
        const function = try self.functionById(ref.decl_id orelse return LowerError.InvalidIdentity);
        return self.emittedFunctionName(function.module_name, function.owner, function.name, function.abi_name, function.calling_convention == .c, function.is_test_entry);
    }

    pub fn buildDeclarationIndexes(self: *ModuleBuilder) LowerError!void {
        try self.indexes.buildDeclarations(self.allocator, self.sir_mod);
    }

    pub fn functionById(self: *const ModuleBuilder, id: identity.DeclId) LowerError!sir.Function {
        return self.indexes.function(self.sir_mod, id);
    }

    pub fn enumById(self: *const ModuleBuilder, id: identity.DeclId) LowerError!sir.EnumDecl {
        return self.indexes.enumDecl(self.sir_mod, id);
    }

    pub fn unionById(self: *const ModuleBuilder, id: identity.DeclId) LowerError!sir.UnionDecl {
        return self.indexes.unionDecl(self.sir_mod, id);
    }

    pub fn emittedGlobalName(
        self: *ModuleBuilder,
        module_name: []const u8,
        owner: ?[]const u8,
        name: []const u8,
        abi_name: ?[]const u8,
        is_extern: bool,
    ) LowerError![]const u8 {
        if (abi_name) |symbol| return symbol;
        if (is_extern) return name;

        var hasher = std.hash.Wyhash.init(0);
        hasher.update(module_name);
        hasher.update("::");
        if (owner) |owner_name| {
            hasher.update(owner_name);
            hasher.update("::");
        }
        hasher.update(name);
        const hash = hasher.final();
        const symbol = try std.fmt.allocPrint(self.allocator, "{s}{x}_{s}", .{ generated_names.global_symbol_prefix, hash, name });
        try self.generated_names.append(self.allocator, symbol);
        return symbol;
    }

    pub fn resolveDebugSourcePath(self: *ModuleBuilder, module_name: []const u8) ?[]const u8 {
        for (self.options.debug_source_map) |entry| {
            if (std.mem.eql(u8, entry.module_name, module_name)) return entry.source_path;
        }
        return self.options.fallback_source_path;
    }

    pub fn lowerGlobals(self: *ModuleBuilder) LowerError!void {
        for (self.sir_mod.globals) |global| {
            if (global.decl_id == null) return LowerError.InvalidIdentity;
            const is_local = self.options.module_name == null or
                std.mem.eql(u8, self.options.module_name.?, global.module_name);
            const ty = try self.lowerGlobalType(global);
            const global_init: ?lir.GlobalInit = if (!is_local)
                null
            else if (global.init) |global_expr|
                try self.lowerGlobalInit(global.module_name, global_expr)
            else
                null;
            const symbol_name = try self.emittedGlobalName(global.module_name, global.owner, global.name, global.abi_name, global.is_extern);
            try self.globals.append(self.allocator, .{
                .module_name = global.module_name,
                .owner = global.owner,
                .name = global.name,
                .is_mutable = global.is_mutable,
                .is_extern = global.is_extern or !is_local,
                .abi_name = symbol_name,
                .is_symbol_addr = global.is_symbol_addr,
                .ty = ty,
                .init = global_init,
            });
            try self.indexes.registerGlobal(self.allocator, global.decl_id.?, self.globals.items.len - 1);
        }
    }

    pub fn lowerGlobalType(self: *ModuleBuilder, global: sir.Global) LowerError!lir.TypeId {
        return self.lowerCanonicalType(global.type_id);
    }

    pub fn findGlobalInfo(self: *ModuleBuilder, module_name: []const u8, owner: ?[]const u8, name: []const u8) LowerError!lir.Global {
        for (self.globals.items) |global| {
            if (std.mem.eql(u8, global.module_name, module_name) and optionalEql(global.owner, owner) and std.mem.eql(u8, global.name, name)) return global;
        }
        return error.LowerInvariantViolation;
    }

    pub fn globalById(self: *const ModuleBuilder, id: identity.DeclId) LowerError!lir.Global {
        return self.globals.items[try self.indexes.globalIndex(id)];
    }

    pub fn typeLoweringContext(self: *ModuleBuilder) type_lowering.Context {
        return .{
            .allocator = self.allocator,
            .module = &self.sir_mod,
            .indexes = &self.indexes,
            .target = self.options.target,
            .types = &self.types,
            .generated_names = &self.generated_names,
            .union_types = &self.union_types,
            .struct_types = &self.struct_types,
            .arrow_callable_type = &self.arrow_callable_type,
            .builtins = .{
                .void_type = self.void_type,
                .bool_type = self.bool_type,
                .i64_type = self.i64_type,
                .f32_type = self.f32_type,
                .f64_type = self.f64_type,
                .string_type = self.string_type,
            },
        };
    }

    pub fn appendType(self: *ModuleBuilder, ty: lir.TypeDecl) LowerError!lir.TypeId {
        var context = self.typeLoweringContext();
        return type_lowering.appendType(&context, ty);
    }

    pub fn typeIdsEqual(self: *ModuleBuilder, a: lir.TypeId, b: lir.TypeId) bool {
        return lir.typeIdsEqual(self.types.items, a, b);
    }

    pub fn lowerCanonicalType(self: *ModuleBuilder, maybe_type_id: ?sir.TypeId) LowerError!lir.TypeId {
        var context = self.typeLoweringContext();
        return type_lowering.lowerCanonicalType(&context, maybe_type_id);
    }

    pub fn canonicalTypeNode(self: *const ModuleBuilder, maybe_type_id: ?sir.TypeId) LowerError!*const semantic_types.Type {
        var mutable_self: *ModuleBuilder = @constCast(self);
        var context = mutable_self.typeLoweringContext();
        return type_lowering.canonicalTypeNode(&context, maybe_type_id);
    }

    pub fn exprMetadata(self: *const ModuleBuilder, expr: *const sir.Expr) LowerError!sir.ExprMetadata {
        const metadata = self.expr_metadata.get(expr) orelse return LowerError.InvalidIdentity;
        if (!metadata.semantics.isValid()) return LowerError.InvalidIdentity;
        if (!metadata.consumption.isValid(metadata.semantics)) return LowerError.InvalidIdentity;
        return metadata;
    }

    pub fn requireExprSink(self: *const ModuleBuilder, expr: *const sir.Expr, expected: sir.SinkAction) LowerError!sir.ExprMetadata {
        const metadata = try self.exprMetadata(expr);
        if (metadata.consumption.sink != expected) return LowerError.InvalidIdentity;
        return metadata;
    }

    pub fn canonicalNominalDeclId(
        self: *ModuleBuilder,
        maybe_type_id: ?sir.TypeId,
        expected_kind: semantic_types.NominalKind,
    ) LowerError!identity.DeclId {
        var context = self.typeLoweringContext();
        return type_lowering.canonicalNominalDeclId(&context, maybe_type_id, expected_kind);
    }

    pub fn lowerType(self: *ModuleBuilder, kind: sir.Type, type_name: ?[]const u8) LowerError!lir.TypeId {
        var context = self.typeLoweringContext();
        return type_lowering.lowerType(&context, kind, type_name);
    }

    pub fn lowerArrowCallableType(self: *ModuleBuilder) LowerError!lir.TypeId {
        var context = self.typeLoweringContext();
        return type_lowering.lowerArrowCallableType(&context);
    }

    pub fn lowerSliceType(self: *ModuleBuilder, item_kind: sir.Type, item_name: ?[]const u8) LowerError!lir.TypeId {
        var context = self.typeLoweringContext();
        return type_lowering.lowerSliceType(&context, item_kind, item_name);
    }

    pub fn lowerArrayTypeFromCanonicalItem(
        self: *ModuleBuilder,
        len: usize,
        item_type_id: ?sir.TypeId,
    ) LowerError!lir.TypeId {
        var context = self.typeLoweringContext();
        return type_lowering.lowerArrayTypeFromCanonicalItem(&context, len, item_type_id);
    }

    pub fn lowerDenseArrayTypeFromCanonicalItem(
        self: *ModuleBuilder,
        item_type_id: ?sir.TypeId,
    ) LowerError!lir.TypeId {
        var context = self.typeLoweringContext();
        return type_lowering.lowerDenseArrayTypeFromCanonicalItem(&context, item_type_id);
    }

    pub fn lowerSparseArrayTypeFromCanonicalItem(
        self: *ModuleBuilder,
        item_type_id: ?sir.TypeId,
    ) LowerError!lir.TypeId {
        var context = self.typeLoweringContext();
        return type_lowering.lowerSparseArrayTypeFromCanonicalItem(&context, item_type_id);
    }

    pub fn lowerExactNamedIntType(self: *ModuleBuilder, type_name: []const u8) LowerError!lir.TypeId {
        var context = self.typeLoweringContext();
        return type_lowering.lowerExactNamedIntType(&context, type_name);
    }

    pub fn lowerEnumTypeById(self: *ModuleBuilder, decl_id: identity.DeclId) LowerError!lir.TypeId {
        var context = self.typeLoweringContext();
        return type_lowering.lowerEnumTypeById(&context, decl_id);
    }

    pub fn lowerStructTypeById(self: *ModuleBuilder, decl_id: identity.DeclId) LowerError!lir.TypeId {
        var context = self.typeLoweringContext();
        return type_lowering.lowerStructTypeById(&context, decl_id);
    }

    pub fn lowerOptionalType(self: *ModuleBuilder, payload_kind: sir.Type, payload_name: ?[]const u8) LowerError!lir.TypeId {
        var context = self.typeLoweringContext();
        return type_lowering.lowerOptionalType(&context, payload_kind, payload_name);
    }

    pub fn lowerUnionTypeById(self: *ModuleBuilder, decl_id: identity.DeclId) LowerError!lir.TypeId {
        var context = self.typeLoweringContext();
        return type_lowering.lowerUnionTypeById(&context, decl_id);
    }

    pub fn lowerFunctions(self: *ModuleBuilder) LowerError!void {
        for (self.sir_mod.functions) |sir_fn| {
            if (sir_fn.decl_id == null) return LowerError.InvalidIdentity;
            const is_local = self.options.module_name == null or
                std.mem.eql(u8, self.options.module_name.?, sir_fn.module_name);
            var lowered_source = sir_fn;
            if (!is_local) {
                lowered_source.is_extern = true;
                lowered_source.body = &.{};
            }
            if (try self.shouldSkipExternFunctionDeclaration(lowered_source)) continue;
            var lowerer = FunctionLowerer.init(self);
            const lowered = try lowerer.lowerFunction(lowered_source);
            try self.functions.append(self.allocator, lowered);
        }
    }

    pub fn shouldSkipExternFunctionDeclaration(self: *ModuleBuilder, sir_fn: sir.Function) LowerError!bool {
        if (!sir_fn.is_extern or sir_fn.calling_convention != .c) return false;
        const symbol_name = try self.emittedFunctionName(sir_fn.module_name, sir_fn.owner, sir_fn.name, sir_fn.abi_name, true, sir_fn.is_test_entry);

        for (self.sir_mod.functions) |candidate| {
            if (!candidate.is_export or candidate.calling_convention != .c) continue;
            if (self.options.module_name) |module_name| {
                if (!std.mem.eql(u8, candidate.module_name, module_name)) continue;
            }
            const candidate_symbol_name = try self.emittedFunctionName(candidate.module_name, candidate.owner, candidate.name, candidate.abi_name, true, candidate.is_test_entry);
            if (std.mem.eql(u8, symbol_name, candidate_symbol_name)) return true;
        }
        return false;
    }

    pub fn unionCaseTagById(self: *ModuleBuilder, decl_id: identity.DeclId, case_name: []const u8) LowerError!i64 {
        const decl = try self.unionById(decl_id);
        for (decl.fields, 0..) |field, i| {
            if (std.mem.eql(u8, field.name, case_name)) return @intCast(i);
        }
        return error.LowerInvariantViolation;
    }

    pub fn lowerExprType(self: *ModuleBuilder, current_module: []const u8, expr: *sir.Expr) LowerError!lir.TypeId {
        return switch (expr.*) {
            .@"switch" => |switch_expr| self.lowerCanonicalType(switch_expr.result_type_id orelse return error.LowerInvariantViolation),
            .failure_detail => self.lowerCanonicalType((try self.exprMetadata(expr)).type_id),
            .int => self.i64_type,
            .float => self.lowerType(.float, expr.float.type_name),
            .rune => self.lowerType(.rune, null),
            .bool => self.bool_type,
            .string => self.string_type,
            .interpolated_string => self.string_type,
            .none => error.LowerInvariantViolation,
            .enum_case => |case| self.lowerEnumTypeById(case.decl_id orelse return LowerError.InvalidIdentity),
            .local => |name| (try self.findGlobalInfo(current_module, null, name)).ty,
            .global_ref => |global_ref| (try self.globalById(global_ref.decl_id orelse return LowerError.InvalidIdentity)).ty,
            .unary => |unary| switch (unary.op) {
                .not => self.bool_type,
                .bit_not => try self.lowerExprType(current_module, unary.expr),
                .negate => try self.lowerExprType(current_module, unary.expr),
                else => return error.LowerInvariantViolation,
            },
            .binary => |binary| switch (binary.op) {
                .eq, .ne, .lt, .le, .gt, .ge, .@"and", .@"or" => self.bool_type,
                else => blk: {
                    const left_ty = try self.lowerExprType(current_module, binary.left);
                    const right_ty = try self.lowerExprType(current_module, binary.right);
                    if (self.types.items[left_ty] == .float) break :blk left_ty;
                    if (self.types.items[right_ty] == .float) break :blk right_ty;
                    break :blk self.i64_type;
                },
            },
            .array_literal => |literal| self.lowerArrayTypeFromCanonicalItem(literal.len, literal.item_type_id),
            .tuple_literal => |literal| self.lowerCanonicalType(literal.type_id),
            .struct_literal => |literal| self.lowerStructTypeById(literal.decl_id orelse return LowerError.InvalidIdentity),
            .@"try", .call, .indirect_call, .thread_spawn_boxed, .task_group_spawn_boxed, .task_result_take, .sync_share_boxed, .builtin_print, .field, .union_field, .union_case, .index, .new_owned, .slice_range, .new_array, .array_default, .take_index_local, .take_index_path_local, .take_path_local, .ref_local, .ref_global, .ref_field_local, .ref_field_owned_local, .ref_field_expr, .ref_index_local, .ref_owned_local, .raw_owned_local, .leak_owned_local, .handoff_local, .ref_raw_deref, .raw_deref, .is_test, .cast, .sequence_push, .sequence_len, .sequence_clear, .sparse_len, .sparse_clear, .sparse_insert, .sparse_contains_index, .sparse_take, .sequence_reserve, .sequence_pop, .string_len, .string_is_empty, .string_bytes, .string_from, .string_starts_with, .string_ends_with, .string_contains, .string_find, .string_rfind, .string_slice => error.LowerInvariantViolation,
        };
    }

    pub fn lowerGlobalInit(self: *ModuleBuilder, current_module: []const u8, expr: *sir.Expr) LowerError!lir.GlobalInit {
        _ = try self.requireExprSink(expr, .initialize);
        return self.lowerGlobalInitValue(current_module, expr);
    }

    pub fn lowerGlobalInitValue(self: *ModuleBuilder, current_module: []const u8, expr: *sir.Expr) LowerError!lir.GlobalInit {
        return switch (expr.*) {
            .int => |value| .{ .int = value.value },
            .string => |value| .{ .string = try self.allocator.dupe(u8, value) },
            .rune => |value| .{ .int = value },
            .float => |value| .{ .float = value.value },
            .bool => |value| .{ .bool = value },
            .enum_case => |value| .{ .enum_value = value.value },
            .none => .none,
            .union_case => |value| blk: {
                const decl_id = value.decl_id orelse return LowerError.InvalidIdentity;
                const union_ty = try self.lowerUnionTypeById(decl_id);
                const union_decl = switch (self.types.items[union_ty]) {
                    .@"union" => |decl| decl,
                    else => return error.LowerInvariantViolation,
                };
                const tag = try self.unionCaseTagById(decl_id, value.case_name);
                const payload_ty = union_decl.payloads[@intCast(tag)];
                const payload = if (value.value) |payload_expr| blk_payload: {
                    const lowered = try self.lowerGlobalInitValue(current_module, payload_expr);
                    const slot = try self.allocator.create(lir.GlobalInit);
                    slot.* = lowered;
                    break :blk_payload slot;
                } else null;
                if (payload_ty == null and payload != null) return error.LowerInvariantViolation;
                break :blk .{ .@"union" = .{
                    .tag = @intCast(tag),
                    .payload = payload,
                } };
            },
            .local => |name| try cloneGlobalInit(self.allocator, (try self.findGlobalInfo(current_module, null, name)).init orelse return error.LowerInvariantViolation),
            .global_ref => |global_ref| try cloneGlobalInit(self.allocator, (try self.globalById(global_ref.decl_id orelse return LowerError.InvalidIdentity)).init orelse return error.LowerInvariantViolation),
            .function_ref => |function_ref| blk: {
                const symbol_name = try self.functionSymbol(function_ref);
                break :blk .{ .symbol_addr = try self.allocator.dupe(u8, symbol_name) };
            },
            .unary => |unary| switch (unary.op) {
                .not => blk: {
                    const inner = try self.lowerGlobalInitValue(current_module, unary.expr);
                    defer inner.deinit(self.allocator);
                    break :blk .{ .bool = !switch (inner) {
                        .bool => |value| value,
                        else => return error.LowerInvariantViolation,
                    } };
                },
                .bit_not => blk: {
                    const inner = try self.lowerGlobalInitValue(current_module, unary.expr);
                    defer inner.deinit(self.allocator);
                    break :blk .{ .int = ~(try globalInitInt(inner)) };
                },
                .negate => blk: {
                    const inner = try self.lowerGlobalInitValue(current_module, unary.expr);
                    defer inner.deinit(self.allocator);
                    break :blk switch (inner) {
                        .int => |value| .{ .int = -value },
                        .float => |value| .{ .float = -value },
                        else => return error.LowerInvariantViolation,
                    };
                },
                else => error.LowerInvariantViolation,
            },
            .binary => |binary| try self.lowerGlobalBinary(current_module, binary),
            .array_default => |literal| blk: {
                const item_ty = try self.lowerCanonicalType(literal.item_type_id);
                const items = try self.allocator.alloc(lir.GlobalInit, literal.len);
                var item_count: usize = 0;
                errdefer {
                    for (items[0..item_count]) |item| item.deinit(self.allocator);
                    self.allocator.free(items);
                }
                for (items) |*item| {
                    item.* = try self.defaultGlobalInitForType(item_ty);
                    item_count += 1;
                }
                break :blk .{ .array = items };
            },
            .array_literal => |literal| blk: {
                const items = try self.allocator.alloc(lir.GlobalInit, literal.items.len);
                errdefer self.allocator.free(items);
                for (literal.items, items) |item, *out_item| {
                    out_item.* = try self.lowerGlobalInitValue(current_module, item);
                }
                break :blk .{ .array = items };
            },
            .tuple_literal => |literal| blk: {
                const fields = try self.allocator.alloc(lir.GlobalInit, literal.items.len);
                var initialized: usize = 0;
                errdefer {
                    for (fields[0..initialized]) |field| field.deinit(self.allocator);
                    self.allocator.free(fields);
                }
                for (literal.items, fields) |item, *field| {
                    field.* = try self.lowerGlobalInitValue(current_module, item);
                    initialized += 1;
                }
                break :blk .{ .@"struct" = fields };
            },
            .struct_literal => |literal| blk: {
                const struct_ty = try self.lowerStructTypeById(literal.decl_id orelse return LowerError.InvalidIdentity);
                const struct_decl = switch (self.types.items[struct_ty]) {
                    .@"struct" => |decl| decl,
                    else => return error.LowerInvariantViolation,
                };
                const fields = try self.allocator.alloc(lir.GlobalInit, literal.fields.len);
                const initialized = try self.allocator.alloc(bool, literal.fields.len);
                defer self.allocator.free(initialized);
                @memset(initialized, false);
                errdefer {
                    for (fields, initialized) |field, is_initialized| {
                        if (is_initialized) field.deinit(self.allocator);
                    }
                    self.allocator.free(fields);
                }
                for (literal.fields) |field| {
                    const field_index = for (struct_decl.fields, 0..) |struct_field, index| {
                        if (std.mem.eql(u8, struct_field.name, field.name)) break index;
                    } else return error.LowerInvariantViolation;
                    fields[field_index] = try self.lowerGlobalInitValue(current_module, field.value);
                    initialized[field_index] = true;
                }
                break :blk .{ .@"struct" = fields };
            },
            else => error.LowerInvariantViolation,
        };
    }

    pub fn defaultGlobalInitForType(self: *ModuleBuilder, ty: lir.TypeId) LowerError!lir.GlobalInit {
        return switch (self.types.items[ty]) {
            .int => .{ .int = 0 },
            .float => .{ .float = 0.0 },
            .bool => .{ .bool = false },
            .optional => .none,
            .array => |array_ty| blk: {
                const items = try self.allocator.alloc(lir.GlobalInit, array_ty.len);
                var item_count: usize = 0;
                errdefer {
                    for (items[0..item_count]) |item| item.deinit(self.allocator);
                    self.allocator.free(items);
                }
                for (items) |*item| {
                    item.* = try self.defaultGlobalInitForType(array_ty.elem);
                    item_count += 1;
                }
                break :blk .{ .array = items };
            },
            .@"struct" => |struct_ty| blk: {
                const fields = try self.allocator.alloc(lir.GlobalInit, struct_ty.fields.len);
                var field_count: usize = 0;
                errdefer {
                    for (fields[0..field_count]) |field| field.deinit(self.allocator);
                    self.allocator.free(fields);
                }
                for (struct_ty.fields, fields) |field, *out_field| {
                    out_field.* = try self.defaultGlobalInitForType(field.ty);
                    field_count += 1;
                }
                break :blk .{ .@"struct" = fields };
            },
            else => error.LowerInvariantViolation,
        };
    }

    pub fn lowerGlobalBinary(self: *ModuleBuilder, current_module: []const u8, binary: sir.Binary) LowerError!lir.GlobalInit {
        const left = try self.lowerGlobalInitValue(current_module, binary.left);
        defer left.deinit(self.allocator);
        const right = try self.lowerGlobalInitValue(current_module, binary.right);
        defer right.deinit(self.allocator);

        const has_float = switch (left) {
            .float => true,
            else => switch (right) {
                .float => true,
                else => false,
            },
        };
        if (has_float) {
            return switch (binary.op) {
                .add => .{ .float = (try globalInitFloat(left)) + (try globalInitFloat(right)) },
                .sub => .{ .float = (try globalInitFloat(left)) - (try globalInitFloat(right)) },
                .mul => .{ .float = (try globalInitFloat(left)) * (try globalInitFloat(right)) },
                .div => .{ .float = (try globalInitFloat(left)) / (try globalInitFloat(right)) },
                .mod => return LowerError.InvalidSir,
                .eq => .{ .bool = try globalInitEqual(left, right) },
                .ne => .{ .bool = !(try globalInitEqual(left, right)) },
                .lt => .{ .bool = try globalInitLess(left, right) },
                .le => .{ .bool = try globalInitLessEqual(left, right) },
                .gt => .{ .bool = try globalInitGreater(left, right) },
                .ge => .{ .bool = try globalInitGreaterEqual(left, right) },
                else => LowerError.InvalidSir,
            };
        }

        return switch (binary.op) {
            .add => .{ .int = (try globalInitInt(left)) + (try globalInitInt(right)) },
            .wrap_add => .{ .int = (try globalInitInt(left)) +% (try globalInitInt(right)) },
            .sub => .{ .int = (try globalInitInt(left)) - (try globalInitInt(right)) },
            .wrap_sub => .{ .int = (try globalInitInt(left)) -% (try globalInitInt(right)) },
            .mul => .{ .int = (try globalInitInt(left)) * (try globalInitInt(right)) },
            .wrap_mul => .{ .int = (try globalInitInt(left)) *% (try globalInitInt(right)) },
            .div => blk: {
                const divisor = try globalInitInt(right);
                if (divisor == 0) return LowerError.InvalidSir;
                const dividend = try globalInitInt(left);
                if (dividend == std.math.minInt(i64) and divisor == -1) return LowerError.InvalidSir;
                break :blk .{ .int = @divTrunc(dividend, divisor) };
            },
            .mod => blk: {
                const divisor = try globalInitInt(right);
                if (divisor == 0) return LowerError.InvalidSir;
                const dividend = try globalInitInt(left);
                break :blk .{ .int = if (dividend == std.math.minInt(i64) and divisor == -1) 0 else @rem(dividend, divisor) };
            },
            .shl => blk: {
                const shift = try globalInitInt(right);
                if (shift < 0 or shift >= 64) return LowerError.InvalidSir;
                break :blk .{ .int = (try globalInitInt(left)) << @as(u6, @intCast(shift)) };
            },
            .shr => blk: {
                const shift = try globalInitInt(right);
                if (shift < 0 or shift >= 64) return LowerError.InvalidSir;
                break :blk .{ .int = (try globalInitInt(left)) >> @as(u6, @intCast(shift)) };
            },
            .bit_and => .{ .int = (try globalInitInt(left)) & (try globalInitInt(right)) },
            .bit_or => .{ .int = (try globalInitInt(left)) | (try globalInitInt(right)) },
            .bit_xor => .{ .int = (try globalInitInt(left)) ^ (try globalInitInt(right)) },
            .eq => .{ .bool = try globalInitEqual(left, right) },
            .ne => .{ .bool = !(try globalInitEqual(left, right)) },
            .lt => .{ .bool = try globalInitLess(left, right) },
            .le => .{ .bool = try globalInitLessEqual(left, right) },
            .gt => .{ .bool = try globalInitGreater(left, right) },
            .ge => .{ .bool = try globalInitGreaterEqual(left, right) },
            .@"and" => .{ .bool = (try globalInitBool(left)) and (try globalInitBool(right)) },
            .@"or" => .{ .bool = (try globalInitBool(left)) or (try globalInitBool(right)) },
            else => LowerError.InvalidSir,
        };
    }
};

fn cloneGlobalInit(allocator: std.mem.Allocator, init: lir.GlobalInit) LowerError!lir.GlobalInit {
    return switch (init) {
        .int => |value| .{ .int = value },
        .string => |value| .{ .string = try allocator.dupe(u8, value) },
        .float => |value| .{ .float = value },
        .bool => |value| .{ .bool = value },
        .enum_value => |value| .{ .enum_value = value },
        .none => .none,
        .symbol_addr => |name| .{ .symbol_addr = try allocator.dupe(u8, name) },
        .some => |value| blk: {
            const payload = try allocator.create(lir.GlobalInit);
            payload.* = try cloneGlobalInit(allocator, value.*);
            break :blk .{ .some = payload };
        },
        .@"union" => |value| blk: {
            const payload = if (value.payload) |inner| payload: {
                const copied = try allocator.create(lir.GlobalInit);
                copied.* = try cloneGlobalInit(allocator, inner.*);
                break :payload copied;
            } else null;
            break :blk .{ .@"union" = .{
                .tag = value.tag,
                .payload = payload,
            } };
        },
        .array => |items| blk: {
            const copied = try allocator.alloc(lir.GlobalInit, items.len);
            for (items, copied) |item, *out_item| out_item.* = try cloneGlobalInit(allocator, item);
            break :blk .{ .array = copied };
        },
        .@"struct" => |fields| blk: {
            const copied = try allocator.alloc(lir.GlobalInit, fields.len);
            for (fields, copied) |field, *out_field| out_field.* = try cloneGlobalInit(allocator, field);
            break :blk .{ .@"struct" = copied };
        },
    };
}

fn globalInitInt(init: lir.GlobalInit) LowerError!i64 {
    return switch (init) {
        .int => |value| value,
        .enum_value => |value| value,
        else => error.LowerInvariantViolation,
    };
}

fn globalInitFloat(init: lir.GlobalInit) LowerError!f64 {
    return switch (init) {
        .float => |value| value,
        .int => |value| @floatFromInt(value),
        .enum_value => |value| @floatFromInt(value),
        else => error.LowerInvariantViolation,
    };
}

fn globalInitBool(init: lir.GlobalInit) LowerError!bool {
    return switch (init) {
        .bool => |value| value,
        else => error.LowerInvariantViolation,
    };
}

fn globalInitEqual(left: lir.GlobalInit, right: lir.GlobalInit) LowerError!bool {
    return switch (left) {
        .int => |value| switch (right) {
            .int => |rhs| value == rhs,
            .float => |rhs| @as(f64, @floatFromInt(value)) == rhs,
            else => return error.LowerInvariantViolation,
        },
        .float => |value| switch (right) {
            .int => |rhs| value == @as(f64, @floatFromInt(rhs)),
            .float => |rhs| value == rhs,
            else => return error.LowerInvariantViolation,
        },
        .bool => |value| switch (right) {
            .bool => |rhs| value == rhs,
            else => return error.LowerInvariantViolation,
        },
        .enum_value => |value| switch (right) {
            .enum_value => |rhs| value == rhs,
            else => return error.LowerInvariantViolation,
        },
        .none => switch (right) {
            .none => true,
            else => false,
        },
        else => error.LowerInvariantViolation,
    };
}

fn globalInitLess(left: lir.GlobalInit, right: lir.GlobalInit) LowerError!bool {
    return switch (left) {
        .int => |value| switch (right) {
            .float => @as(f64, @floatFromInt(value)) < (try globalInitFloat(right)),
            else => value < (try globalInitInt(right)),
        },
        .float => |value| value < (try globalInitFloat(right)),
        else => error.LowerInvariantViolation,
    };
}

fn globalInitLessEqual(left: lir.GlobalInit, right: lir.GlobalInit) LowerError!bool {
    return switch (left) {
        .int => |value| switch (right) {
            .float => @as(f64, @floatFromInt(value)) <= (try globalInitFloat(right)),
            else => value <= (try globalInitInt(right)),
        },
        .float => |value| value <= (try globalInitFloat(right)),
        else => error.LowerInvariantViolation,
    };
}

fn globalInitGreater(left: lir.GlobalInit, right: lir.GlobalInit) LowerError!bool {
    return switch (left) {
        .int => |value| switch (right) {
            .float => @as(f64, @floatFromInt(value)) > (try globalInitFloat(right)),
            else => value > (try globalInitInt(right)),
        },
        .float => |value| value > (try globalInitFloat(right)),
        else => error.LowerInvariantViolation,
    };
}

fn globalInitGreaterEqual(left: lir.GlobalInit, right: lir.GlobalInit) LowerError!bool {
    return switch (left) {
        .int => |value| switch (right) {
            .float => @as(f64, @floatFromInt(value)) >= (try globalInitFloat(right)),
            else => value >= (try globalInitInt(right)),
        },
        .float => |value| value >= (try globalInitFloat(right)),
        else => error.LowerInvariantViolation,
    };
}

const IntCastBounds = type_policy.IntCastBounds;
const FloatFiniteBounds = type_policy.FloatFiniteBounds;
const namedIntInfo = type_policy.namedIntInfo;
const isAbiIntTypeName = type_policy.isAbiIntTypeName;
const intCastBounds = type_policy.intCastBounds;
const intCastBoundsForInfo = type_policy.intCastBoundsForInfo;
const intTypeAlwaysFits = type_policy.intTypeAlwaysFits;
const floatFiniteBounds = type_policy.floatFiniteBounds;
const isArcSharedValueStruct = ownership_lowering.isArcSharedValueStruct;

const FunctionLowerer = struct {
    mb: *ModuleBuilder,
    func: lir.Function = undefined,
    blocks: std.ArrayListUnmanaged(lir.BasicBlock) = .empty,
    locals_list: std.ArrayListUnmanaged(lir.Local) = .empty,
    locals: std.StringHashMapUnmanaged(LocalState) = .empty,
    defers: std.ArrayListUnmanaged(*sir.Expr) = .empty,
    ownership: ownership_lowering.State = .{},
    scope_restores: std.ArrayListUnmanaged(ScopeRestore) = .empty,
    loop_stack: std.ArrayListUnmanaged(LoopContext) = .empty,
    switch_stack: std.ArrayListUnmanaged(SwitchContext) = .empty,
    catch_stack: std.ArrayListUnmanaged(CatchScope) = .empty,
    current_block: lir.BlockId = 0,
    next_value_id: lir.ValueId = 0,
    result_return_type: ?lir.TypeId = null,
    result_return_error_type_id: ?sir.TypeId = null,
    current_module: []const u8 = "",

    pub fn init(mb: *ModuleBuilder) FunctionLowerer {
        return .{ .mb = mb };
    }

    pub fn deinit(self: *FunctionLowerer) void {
        for (self.blocks.items) |block| block.deinit(self.mb.allocator);
        self.blocks.deinit(self.mb.allocator);
        self.locals_list.deinit(self.mb.allocator);
        self.locals.deinit(self.mb.allocator);
        self.defers.deinit(self.mb.allocator);
        self.ownership.deinit(self.mb.allocator);
        self.scope_restores.deinit(self.mb.allocator);
        self.loop_stack.deinit(self.mb.allocator);
        self.switch_stack.deinit(self.mb.allocator);
        self.catch_stack.deinit(self.mb.allocator);
    }

    pub const lowerFunction = function_lowering.lowerFunction;
    pub const lowerFunctionReturnType = function_lowering.lowerFunctionReturnType;
    pub const lowerParams = function_lowering.lowerParams;
    pub const lowerParamType = function_lowering.lowerParamType;
    pub const bindParams = function_lowering.bindParams;
    pub const lowerStmtList = function_lowering.lowerStmtList;
    pub const lowerStmt = function_lowering.lowerStmt;
    pub const lowerIfStmt = function_lowering.lowerIfStmt;
    pub const lowerOptionalIfStmt = function_lowering.lowerOptionalIfStmt;
    pub const lowerUnionIfStmt = function_lowering.lowerUnionIfStmt;
    pub const lowerWhileStmt = function_lowering.lowerWhileStmt;
    pub const lowerForStmt = function_lowering.lowerForStmt;
    pub const lowerIteratorHookForStmt = function_lowering.lowerIteratorHookForStmt;
    pub const emitIteratorInitCall = function_lowering.emitIteratorInitCall;
    pub const emitIteratorHasNextCall = function_lowering.emitIteratorHasNextCall;
    pub const emitIteratorNextCall = function_lowering.emitIteratorNextCall;
    pub const emitIterableIndexHookCall = function_lowering.emitIterableIndexHookCall;
    pub const lowerSwitchStmt = function_lowering.lowerSwitchStmt;
    pub const lowerSwitchExpr = function_lowering.lowerSwitchExpr;
    pub const lowerScalarSwitchStmt = function_lowering.lowerScalarSwitchStmt;
    pub const lowerEnumSwitchStmt = function_lowering.lowerEnumSwitchStmt;
    pub const lowerTaggedSumSwitchStmt = function_lowering.lowerTaggedSumSwitchStmt;
    pub const emitSumCaseTag = function_lowering.emitSumCaseTag;
    pub const emitEnumCaseValueResolved = function_lowering.emitEnumCaseValueResolved;
    pub const sumCasePayloadType = function_lowering.sumCasePayloadType;
    pub const emitExtractSumCasePayload = function_lowering.emitExtractSumCasePayload;
    pub const resultOkTypeFromValue = function_lowering.resultOkTypeFromValue;
    pub const resultErrTypeFromValue = function_lowering.resultErrTypeFromValue;
    pub const lowerExprTypeFromValue = function_lowering.lowerExprTypeFromValue;

    pub fn lowerExpr(self: *FunctionLowerer, expr: *sir.Expr) LowerError!lir.ValueId {
        return expression_lowering.lower(self, expr);
    }

    pub const lowerExprType = expression_lowering.lowerExprType;
    pub const lowerAsmExpr = expression_lowering.lowerAsmExpr;
    pub const lowerAsmConstraint = expression_lowering.lowerAsmConstraint;
    pub const lowerLocalType = expression_lowering.lowerLocalType;
    pub const lowerExprForTarget = expression_lowering.lowerExprForTarget;
    pub const lowerUnary = expression_lowering.lowerUnary;
    pub const lowerUnaryType = expression_lowering.lowerUnaryType;
    pub const lowerStringLenExpr = expression_lowering.lowerStringLenExpr;
    pub const lowerStringIsEmptyExpr = expression_lowering.lowerStringIsEmptyExpr;
    pub const lowerStringBytesExpr = expression_lowering.lowerStringBytesExpr;
    pub const lowerStringFromExpr = expression_lowering.lowerStringFromExpr;
    pub const lowerStringContainsExpr = expression_lowering.lowerStringContainsExpr;
    pub const lowerStringFindExpr = expression_lowering.lowerStringFindExpr;
    pub const lowerStringSliceExpr = expression_lowering.lowerStringSliceExpr;
    pub const lowerStringBuiltinReceiver = expression_lowering.lowerStringBuiltinReceiver;
    pub const dropTemporaryStringReceiver = expression_lowering.dropTemporaryStringReceiver;
    pub const lowerBuiltinPrintExpr = expression_lowering.lowerBuiltinPrintExpr;
    pub const lowerBuiltinPrintValue = expression_lowering.lowerBuiltinPrintValue;
    pub const lowerInterpolatedStringExpr = expression_lowering.lowerInterpolatedStringExpr;
    pub const lowerInterpolatedStringValue = expression_lowering.lowerInterpolatedStringValue;
    pub const lowerInterpolatedBoolAppend = expression_lowering.lowerInterpolatedBoolAppend;
    pub const emitPrintHelperCall = expression_lowering.emitPrintHelperCall;
    pub const emitRuntimeCall = expression_lowering.emitRuntimeCall;
    pub const materializeRuntimeArgument = expression_lowering.materializeRuntimeArgument;
    pub const emitStringResultAt = expression_lowering.emitStringResultAt;
    pub const appendRuntimeString = expression_lowering.appendRuntimeString;
    pub const stringRuntimeParts = expression_lowering.stringRuntimeParts;
    pub const lowerTestAssertExpr = expression_lowering.lowerTestAssertExpr;

    pub const BorrowedSequenceUse = container_lowering.BorrowedSequenceUse;
    pub const lowerReadableSequenceValue = container_lowering.lowerReadableSequenceValue;
    pub const lowerMutableSequencePlace = container_lowering.lowerMutableSequencePlace;
    pub const lowerArrayDefaultExpr = container_lowering.lowerArrayDefaultExpr;
    pub const lowerNewArrayExpr = container_lowering.lowerNewArrayExpr;
    pub const lowerDenseArrayLiteralExpr = container_lowering.lowerDenseArrayLiteralExpr;
    pub const lowerNewSparseExpr = container_lowering.lowerNewSparseExpr;
    pub const lowerSparseLiteralExpr = container_lowering.lowerSparseLiteralExpr;
    pub const lowerSparseKeyedLiteralExpr = container_lowering.lowerSparseKeyedLiteralExpr;
    pub const lowerValueForTargetType = container_lowering.lowerValueForTargetType;
    pub const lowerCalleeReturnType = container_lowering.lowerCalleeReturnType;
    pub const lowerSequenceLenExpr = container_lowering.lowerSequenceLenExpr;
    pub const lowerSparseLenExpr = container_lowering.lowerSparseLenExpr;
    pub const lowerSliceLenExpr = container_lowering.lowerSliceLenExpr;
    pub const lowerSequencePushExpr = container_lowering.lowerSequencePushExpr;
    pub const lowerSequenceClearExpr = container_lowering.lowerSequenceClearExpr;
    pub const lowerSparseClearExpr = container_lowering.lowerSparseClearExpr;
    pub const lowerSparseIndicesExpr = container_lowering.lowerSparseIndicesExpr;
    pub const lowerSparseContainsIndexExpr = container_lowering.lowerSparseContainsIndexExpr;
    pub const lowerSparseInsertExpr = container_lowering.lowerSparseInsertExpr;
    pub const lowerSparseTakeExpr = container_lowering.lowerSparseTakeExpr;
    pub const lowerSequenceReserveExpr = container_lowering.lowerSequenceReserveExpr;
    pub const lowerSequencePopExpr = container_lowering.lowerSequencePopExpr;
    pub const lowerListIndexExpr = container_lowering.lowerListIndexExpr;
    pub const emitSequencePushValue = container_lowering.emitSequencePushValue;
    pub const emitDenseArrayStorageNew = container_lowering.emitDenseArrayStorageNew;
    pub const emitDenseArrayStorageReserve = container_lowering.emitDenseArrayStorageReserve;
    pub const emitDenseArrayStoragePushValue = container_lowering.emitDenseArrayStoragePushValue;
    pub const emitSequenceAtValue = container_lowering.emitSequenceAtValue;
    pub const emitSequenceLenValue = container_lowering.emitSequenceLenValue;
    pub const emitSequenceClearValue = container_lowering.emitSequenceClearValue;
    pub const emitSequencePopValue = container_lowering.emitSequencePopValue;
    pub const emitDefaultValue = container_lowering.emitDefaultValue;
    pub const materializeSequenceValue = container_lowering.materializeSequenceValue;
    pub const sequenceStorageType = container_lowering.sequenceStorageType;
    pub const materializeSequenceValueFromValue = container_lowering.materializeSequenceValueFromValue;
    pub const sequenceItemType = container_lowering.sequenceItemType;
    pub const emitStoredTemp = container_lowering.emitStoredTemp;
    pub const emitElementSize = container_lowering.emitElementSize;
    pub const emitTypeDesc = container_lowering.emitTypeDesc;

    pub const lowerIndexAssignStmt = place_lowering.lowerIndexAssignStmt;
    pub const lowerDerefAssignStmt = place_lowering.lowerDerefAssignStmt;
    pub const lowerDerefFieldAssignStmt = place_lowering.lowerDerefFieldAssignStmt;
    pub const lowerFieldAssignStmt = place_lowering.lowerFieldAssignStmt;
    pub const rebuildStructValueWithFieldPath = place_lowering.rebuildStructValueWithFieldPath;
    pub const extractStructFieldPathValue = place_lowering.extractStructFieldPathValue;

    pub const emitDefersFrom = ownership_lowering.emitDefersFrom;
    pub const emitAutoDropsFrom = ownership_lowering.emitAutoDropsFrom;
    pub const emitFullExpressionAutoDropsFrom = ownership_lowering.emitFullExpressionAutoDropsFrom;
    pub const recordOwnershipTrace = ownership_lowering.recordOwnershipTrace;
    pub const recordOwnershipSiteTrace = ownership_lowering.recordOwnershipSiteTrace;
    pub const typeNeedsDrop = ownership_lowering.typeNeedsDrop;
    pub const emitDropValue = ownership_lowering.emitDropValue;
    pub const copyValueInto = ownership_lowering.copyValueInto;
    pub const lowerStmtListWithCapturedLocal = ownership_lowering.lowerStmtListWithCapturedLocal;
    pub const lowerStmtListWithAliasedLocal = ownership_lowering.lowerStmtListWithAliasedLocal;
    pub const lowerStmtListWithMovedCapturedLocal = ownership_lowering.lowerStmtListWithMovedCapturedLocal;
    pub const valueSemanticsNeedsMatchSourceDrop = ownership_lowering.valueSemanticsNeedsMatchSourceDrop;
    pub const captureMatchSourceMovesPayload = ownership_lowering.captureMatchSourceMovesPayload;
    pub const captureMatchSourceNeedsDrop = ownership_lowering.captureMatchSourceNeedsDrop;
    pub const lowerStmtListWithCapturedLocalAndDrop = ownership_lowering.lowerStmtListWithCapturedLocalAndDrop;
    pub const typeHasSharedValueSemantics = ownership_lowering.typeHasSharedValueSemantics;
    pub const valueSemanticsNeedsDropAfterContainerCopy = ownership_lowering.valueSemanticsNeedsDropAfterContainerCopy;
    pub const valueSemanticsNeedsStringCleanup = ownership_lowering.valueSemanticsNeedsStringCleanup;
    pub const valueSemanticsNeedsStringReceiverOwner = ownership_lowering.valueSemanticsNeedsStringReceiverOwner;
    pub const exprConsumptionCopiesValue = ownership_lowering.exprConsumptionCopiesValue;
    pub const prepareCapturedExprValue = ownership_lowering.prepareCapturedExprValue;
    pub const captureAliasedValue = ownership_lowering.captureAliasedValue;
    pub const captureExprValueInto = ownership_lowering.captureExprValueInto;
    pub const storeWithCleanup = ownership_lowering.storeWithCleanup;
    pub const dropEphemeralSharedAfterContainerCopy = ownership_lowering.dropEphemeralSharedAfterContainerCopy;
    pub const byteSizeOfType = ownership_lowering.byteSizeOfType;
    pub const dupeArgs = ownership_lowering.dupeArgs;

    pub const lowerBinary = expression_lowering.lowerBinary;
    pub const finishBinaryResult = expression_lowering.finishBinaryResult;
    pub const dropStringCompareTemporary = expression_lowering.dropStringCompareTemporary;
    pub const lowerSequenceCompare = expression_lowering.lowerSequenceCompare;
    pub const expectSequenceComparableElement = expression_lowering.expectSequenceComparableElement;
    pub const lowerContainsBinary = expression_lowering.lowerContainsBinary;
    pub const lowerCastExpr = expression_lowering.lowerCastExpr;
    pub const lowerCastTargetType = expression_lowering.lowerCastTargetType;
    pub const lowerOptionalPayloadCast = expression_lowering.lowerOptionalPayloadCast;
    pub const lowerIntToIntCast = expression_lowering.lowerIntToIntCast;
    pub const lowerIntToIntReinterpretCast = expression_lowering.lowerIntToIntReinterpretCast;
    pub const lowerBitcastReinterpretCast = expression_lowering.lowerBitcastReinterpretCast;
    pub const lowerPackedStructToIntCast = expression_lowering.lowerPackedStructToIntCast;
    pub const lowerRawPtrToIntCast = expression_lowering.lowerRawPtrToIntCast;
    pub const lowerIntToPackedStructCast = expression_lowering.lowerIntToPackedStructCast;
    pub const lowerIntToRawPtrCast = expression_lowering.lowerIntToRawPtrCast;
    pub const lowerIntToFloatCast = expression_lowering.lowerIntToFloatCast;
    pub const lowerFloatToFloatCast = expression_lowering.lowerFloatToFloatCast;
    pub const lowerFloatToIntCast = expression_lowering.lowerFloatToIntCast;
    pub const lowerIntToEnumCast = expression_lowering.lowerIntToEnumCast;
    pub const lowerUnionPayloadCast = expression_lowering.lowerUnionPayloadCast;
    pub const lowerPresenceCheckedCast = expression_lowering.lowerPresenceCheckedCast;
    pub const finishCheckedCast = expression_lowering.finishCheckedCast;
    pub const emitFloatFiniteCheck = expression_lowering.emitFloatFiniteCheck;
    pub const emitBoolAnd = expression_lowering.emitBoolAnd;
    pub const emitBoolOr = expression_lowering.emitBoolOr;
    pub const emitIntFitsType = expression_lowering.emitIntFitsType;
    pub const emitEnumCastCheckResolved = expression_lowering.emitEnumCastCheckResolved;
    pub const optionalTypeFromValue = expression_lowering.optionalTypeFromValue;
    pub const typeIdsEqual = expression_lowering.typeIdsEqual;
    pub const floatBits = expression_lowering.floatBits;
    pub const lowerShortCircuitBinary = expression_lowering.lowerShortCircuitBinary;
    pub const lowerOptionalNoneCompare = expression_lowering.lowerOptionalNoneCompare;
    pub const lowerUnionCaseExpr = expression_lowering.lowerUnionCaseExpr;
    pub const lowerResultTypeFromCaseExpr = expression_lowering.lowerResultTypeFromCaseExpr;
    pub const lowerStructLiteralExpr = expression_lowering.lowerStructLiteralExpr;
    pub const lowerTupleLiteralExpr = expression_lowering.lowerTupleLiteralExpr;
    pub const lowerTupleFieldExpr = expression_lowering.lowerTupleFieldExpr;
    pub const lowerArrayLiteralExpr = expression_lowering.lowerArrayLiteralExpr;
    pub const lowerSliceRangeExpr = expression_lowering.lowerSliceRangeExpr;

    pub const BorrowedSparseOptionalSubject = place_lowering.BorrowedSparseOptionalSubject;
    pub const PlacePointer = place_lowering.PlacePointer;
    pub const lowerResolvedPlacePath = place_lowering.lowerResolvedPlacePath;
    pub const lowerFieldExpr = place_lowering.lowerFieldExpr;
    pub const lowerBorrowedFieldExpr = place_lowering.lowerBorrowedFieldExpr;
    pub const lowerUnionFieldExpr = place_lowering.lowerUnionFieldExpr;
    pub const lowerBorrowedUnionFieldExpr = place_lowering.lowerBorrowedUnionFieldExpr;
    pub const lowerIndexExpr = place_lowering.lowerIndexExpr;
    pub const lowerBorrowedIndexExpr = place_lowering.lowerBorrowedIndexExpr;
    pub const lowerBorrowedSparseOptionalSubject = place_lowering.lowerBorrowedSparseOptionalSubject;
    pub const lowerIndexFromPointer = place_lowering.lowerIndexFromPointer;
    pub const lowerIndexFromPointerValue = place_lowering.lowerIndexFromPointerValue;
    pub const lowerSparseIndexFromPointer = place_lowering.lowerSparseIndexFromPointer;
    pub const lowerBorrowedProjectionValueFromPlace = place_lowering.lowerBorrowedProjectionValueFromPlace;
    pub const lowerBorrowedFieldPlacePointer = place_lowering.lowerBorrowedFieldPlacePointer;
    pub const lowerBorrowedIndexPlacePointer = place_lowering.lowerBorrowedIndexPlacePointer;
    pub const lowerBorrowedUnionFieldPlacePointer = place_lowering.lowerBorrowedUnionFieldPlacePointer;
    pub const lowerAddressableBorrowedProjectionPlacePointer = place_lowering.lowerAddressableBorrowedProjectionPlacePointer;
    pub const lowerAddressablePlacePointer = place_lowering.lowerAddressablePlacePointer;
    pub const exprIsPlace = place_lowering.exprIsPlace;
    pub const exprIsAddressableProjectionSource = place_lowering.exprIsAddressableProjectionSource;
    pub const lowerTakeIndexLocal = place_lowering.lowerTakeIndexLocal;
    pub const lowerTakeIndexPathLocal = place_lowering.lowerTakeIndexPathLocal;
    pub const lowerTakePathLocal = place_lowering.lowerTakePathLocal;
    pub const lowerTakeFromPlace = place_lowering.lowerTakeFromPlace;
    pub const lowerTakePlacePointer = place_lowering.lowerTakePlacePointer;
    pub const lowerTakeIndexedPlacePointer = place_lowering.lowerTakeIndexedPlacePointer;
    pub const lowerFieldPlacePointer = place_lowering.lowerFieldPlacePointer;
    pub const lowerIndexPlacePointer = place_lowering.lowerIndexPlacePointer;
    pub const lowerRefFieldLocal = place_lowering.lowerRefFieldLocal;
    pub const lowerRefFieldOwnedLocal = place_lowering.lowerRefFieldOwnedLocal;
    pub const lowerRefFieldExpr = place_lowering.lowerRefFieldExpr;
    pub const lowerRefUnionFieldLocal = place_lowering.lowerRefUnionFieldLocal;
    pub const lowerRefIndexLocal = place_lowering.lowerRefIndexLocal;
    pub const lowerRefIndexPathLocal = place_lowering.lowerRefIndexPathLocal;
    pub const lowerRefPathLocal = place_lowering.lowerRefPathLocal;
    pub const lowerIndexType = place_lowering.lowerIndexType;
    pub const lowerSliceTypeFromObject = place_lowering.lowerSliceTypeFromObject;

    pub const ForIterableState = function_lowering.ForIterableState;
    pub const captureForIterable = function_lowering.captureForIterable;
    pub const forIterableLen = function_lowering.forIterableLen;
    pub const forIterableItem = function_lowering.forIterableItem;

    pub fn lowerCall(self: *FunctionLowerer, call: sir.Call) LowerError!lir.ValueId {
        return call_lowering.lowerCall(self, call);
    }

    pub fn lowerThreadSpawnBoxed(self: *FunctionLowerer, spawn: sir.ThreadSpawnBoxed) LowerError!lir.ValueId {
        return call_lowering.lowerThreadSpawnBoxed(self, spawn);
    }

    pub fn lowerTaskGroupSpawnBoxed(self: *FunctionLowerer, spawn: sir.TaskGroupSpawnBoxed) LowerError!lir.ValueId {
        return call_lowering.lowerTaskGroupSpawnBoxed(self, spawn);
    }

    pub fn lowerTaskResultTake(self: *FunctionLowerer, take: sir.TaskResultTake) LowerError!lir.ValueId {
        return call_lowering.lowerTaskResultTake(self, take);
    }

    pub fn lowerSyncShareBoxed(self: *FunctionLowerer, share: sir.SyncShareBoxed) LowerError!lir.ValueId {
        return call_lowering.lowerSyncShareBoxed(self, share);
    }

    pub fn lowerClosure(self: *FunctionLowerer, closure: sir.Closure) LowerError!lir.ValueId {
        return call_lowering.lowerClosure(self, closure);
    }

    pub fn lowerClosureCapture(self: *FunctionLowerer, capture: sir.ClosureCapture) LowerError!lir.ValueId {
        return call_lowering.lowerClosureCapture(self, capture);
    }

    pub fn lowerIndirectCall(self: *FunctionLowerer, call: sir.IndirectCall) LowerError!lir.ValueId {
        return call_lowering.lowerIndirectCall(self, call);
    }

    pub fn lowerCallReturnType(self: *FunctionLowerer, call: sir.Call) LowerError!lir.TypeId {
        return call_lowering.lowerCallReturnType(self, call);
    }

    pub const lowerTryExprFromNode = function_lowering.lowerTryExprFromNode;
    pub const lowerTryResultExpr = function_lowering.lowerTryResultExpr;
    pub const lowerResultCaseValue = function_lowering.lowerResultCaseValue;
    pub const traceActionForResultCase = function_lowering.traceActionForResultCase;
    pub const emitExtractResultCaseValue = function_lowering.emitExtractResultCaseValue;

    pub fn unionNameFromValue(self: *FunctionLowerer, value_id: lir.ValueId) LowerError![]const u8 {
        const value_ty = try self.lowerExprTypeFromValue(value_id);
        return switch (self.mb.types.items[value_ty]) {
            .@"union" => |union_ty| union_ty.name,
            else => error.LowerInvariantViolation,
        };
    }

    pub fn structFieldTypeResolved(
        self: *FunctionLowerer,
        decl_id: ?identity.DeclId,
        struct_name: []const u8,
        field_name: []const u8,
    ) LowerError!lir.TypeId {
        _ = struct_name;
        const struct_ty = try self.mb.lowerStructTypeById(decl_id orelse return LowerError.InvalidIdentity);
        return switch (self.mb.types.items[struct_ty]) {
            .@"struct" => |decl| for (decl.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) return field.ty;
            } else error.LowerInvariantViolation,
            else => error.LowerInvariantViolation,
        };
    }

    pub fn structIsPackedResolved(self: *FunctionLowerer, decl_id: ?identity.DeclId, struct_name: []const u8) LowerError!bool {
        _ = struct_name;
        const struct_ty = try self.mb.lowerStructTypeById(decl_id orelse return LowerError.InvalidIdentity);
        return switch (self.mb.types.items[struct_ty]) {
            .@"struct" => |decl| decl.is_packed,
            else => error.LowerInvariantViolation,
        };
    }

    pub fn pointerPointee(self: *FunctionLowerer, ty: lir.TypeId) LowerError!?lir.TypeId {
        return switch (self.mb.types.items[ty]) {
            .pointer => |child| child,
            else => null,
        };
    }

    pub fn structFieldIndexResolved(
        self: *FunctionLowerer,
        decl_id: ?identity.DeclId,
        struct_name: []const u8,
        field_name: []const u8,
    ) LowerError!u32 {
        _ = struct_name;
        const struct_ty = try self.mb.lowerStructTypeById(decl_id orelse return LowerError.InvalidIdentity);
        return switch (self.mb.types.items[struct_ty]) {
            .@"struct" => |decl| for (decl.fields, 0..) |field, i| {
                if (std.mem.eql(u8, field.name, field_name)) return @intCast(i);
            } else error.LowerInvariantViolation,
            else => error.LowerInvariantViolation,
        };
    }

    pub fn unionCasePayloadTypeResolved(
        self: *FunctionLowerer,
        decl_id: ?identity.DeclId,
        union_name: []const u8,
        case_name: []const u8,
    ) LowerError!lir.TypeId {
        const union_ty = try self.mb.lowerUnionTypeById(decl_id orelse return LowerError.InvalidIdentity);
        return switch (self.mb.types.items[union_ty]) {
            .@"union" => |decl| blk: {
                const case_tag = try self.unionCaseTagResolved(decl_id, union_name, case_name);
                break :blk decl.payloads[@intCast(case_tag)] orelse return error.LowerInvariantViolation;
            },
            else => error.LowerInvariantViolation,
        };
    }

    pub fn unionCaseTagResolved(
        self: *FunctionLowerer,
        decl_id: ?identity.DeclId,
        union_name: []const u8,
        case_name: []const u8,
    ) LowerError!i64 {
        _ = union_name;
        const decl = try self.mb.unionById(decl_id orelse return LowerError.InvalidIdentity);
        for (decl.fields, 0..) |field, i| {
            if (std.mem.eql(u8, field.name, case_name)) return @intCast(i);
        }
        return error.LowerInvariantViolation;
    }

    pub fn defineLocal(self: *FunctionLowerer, name: []const u8, ty: lir.TypeId) LowerError!LocalState {
        const local_id: lir.LocalId = @intCast(self.locals_list.items.len);
        try self.scope_restores.append(self.mb.allocator, .{
            .name = name,
            .previous = self.locals.get(name),
        });
        try self.locals_list.append(self.mb.allocator, .{
            .name = name,
            .ty = ty,
        });

        const ptr = try self.emit(.{ .stack_alloc = ty }, ty);
        const cleanup_index = if (try self.typeNeedsDrop(ty)) blk: {
            const cleanup_name = try self.mb.allocator.dupe(u8, name);
            var owns_cleanup_name = true;
            errdefer if (owns_cleanup_name) self.mb.allocator.free(cleanup_name);
            const index = try self.ownership.appendCleanup(self.mb.allocator, .{
                .name = cleanup_name,
                .ptr_value = ptr,
                .ty = ty,
                .active = false,
            });
            owns_cleanup_name = false;
            try self.recordOwnershipTrace("owner {s}", .{name});
            break :blk index;
        } else null;
        const state = LocalState{
            .local_id = local_id,
            .ptr_value = ptr,
            .ty = ty,
            .cleanup_index = cleanup_index,
        };
        try self.locals.put(self.mb.allocator, name, state);
        return state;
    }

    pub fn defineProjectedLocal(self: *FunctionLowerer, name: []const u8, ty: lir.TypeId, ptr: lir.ValueId) LowerError!void {
        const local_id: lir.LocalId = @intCast(self.locals_list.items.len);
        try self.scope_restores.append(self.mb.allocator, .{
            .name = name,
            .previous = self.locals.get(name),
        });
        try self.locals_list.append(self.mb.allocator, .{ .name = name, .ty = ty });
        try self.locals.put(self.mb.allocator, name, .{
            .local_id = local_id,
            .ptr_value = ptr,
            .ty = ty,
        });
        try self.recordOwnershipTrace("projected {s}", .{name});
    }

    pub fn registerCompilerTemporaryCleanup(self: *FunctionLowerer, label: []const u8, ptr_value: lir.ValueId, ty: lir.TypeId) LowerError!void {
        if (!(try self.typeNeedsDrop(ty))) return;
        const cleanup_name = try std.fmt.allocPrint(self.mb.allocator, "{s}_{d}", .{ label, self.ownership.cleanup_entries.items.len });
        var owns_cleanup_name = true;
        errdefer if (owns_cleanup_name) self.mb.allocator.free(cleanup_name);
        _ = try self.ownership.appendCleanup(self.mb.allocator, .{
            .name = cleanup_name,
            .ptr_value = ptr_value,
            .ty = ty,
            .active = true,
        });
        owns_cleanup_name = false;
        try self.recordOwnershipTrace("owner {s}", .{cleanup_name});
    }

    pub fn getLocalIfPresent(self: *FunctionLowerer, name: []const u8) ?LocalState {
        return self.locals.get(name);
    }

    pub fn getLocal(self: *FunctionLowerer, name: []const u8) LowerError!LocalState {
        return self.locals.get(name) orelse LowerError.MissingLocal;
    }

    pub fn setLocalReadThroughAlias(self: *FunctionLowerer, name: []const u8, enabled: bool) LowerError!void {
        const local = self.locals.getPtr(name) orelse return LowerError.MissingLocal;
        local.read_through_alias = enabled;
    }

    pub fn getGlobalInfo(self: *FunctionLowerer, name: []const u8) ?lir.Global {
        return self.mb.findGlobalInfo(self.current_module, null, name) catch null;
    }

    pub fn getGlobalType(self: *FunctionLowerer, name: []const u8) ?lir.TypeId {
        if (self.getGlobalInfo(name)) |global| return global.ty;
        return null;
    }

    pub fn emitGlobalSymbolAddr(self: *FunctionLowerer, global: lir.Global, ty: lir.TypeId) LowerError!lir.ValueId {
        const ptr_ty = try self.mb.appendType(.{ .pointer = ty });
        return self.emit(.{ .global_addr = try self.mb.allocator.dupe(u8, global.abi_name orelse global.name) }, ptr_ty);
    }

    pub fn beginBlock(self: *FunctionLowerer, name: []const u8) LowerError!lir.BlockId {
        const id: lir.BlockId = @intCast(self.blocks.items.len);
        const block_name = try std.fmt.allocPrint(self.mb.allocator, "bb{}_{s}", .{ id, name });
        try self.blocks.append(self.mb.allocator, .{
            .name = block_name,
            .instructions = try self.mb.allocator.alloc(lir.Inst, 0),
            .terminator = .none,
        });
        return id;
    }

    pub fn currentBlock(self: *FunctionLowerer) *lir.BasicBlock {
        return &self.blocks.items[self.current_block];
    }

    pub fn appendInst(self: *FunctionLowerer, inst: lir.Inst) LowerError!void {
        const block = self.currentBlock();
        block.instructions = try self.mb.allocator.realloc(block.instructions, block.instructions.len + 1);
        block.instructions[block.instructions.len - 1] = inst;
    }

    pub fn emit(self: *FunctionLowerer, data: lir.InstData, ty: lir.TypeId) LowerError!lir.ValueId {
        const id = self.next_value_id;
        self.next_value_id += 1;
        try self.appendInst(.{
            .id = id,
            .ty = ty,
            .data = data,
        });
        return id;
    }

    pub fn emitVoid(self: *FunctionLowerer, data: lir.InstData) LowerError!void {
        try self.appendInst(.{
            .id = null,
            .ty = null,
            .data = data,
        });
    }

    pub fn endBlock(self: *FunctionLowerer, term: lir.Terminator) LowerError!void {
        self.currentBlock().terminator = term;
    }

    pub fn markCleanupInactive(self: *FunctionLowerer, local: LocalState) void {
        if (local.cleanup_index) |index| self.ownership.setCleanupActive(index, false);
    }

    pub fn markCleanupActive(self: *FunctionLowerer, local: LocalState) void {
        if (local.cleanup_index) |index| self.ownership.setCleanupActive(index, true);
    }

    pub fn attachHeapCleanup(
        self: *FunctionLowerer,
        name: []const u8,
        local: LocalState,
        heap_ptr: lir.ValueId,
    ) LowerError!LocalState {
        var updated = local;
        if (updated.cleanup_index) |index| {
            self.ownership.cleanup_entries.items[index].heap_ptr = heap_ptr;
            self.ownership.setCleanupActive(index, false);
        } else {
            const cleanup_name = try self.mb.allocator.dupe(u8, name);
            errdefer self.mb.allocator.free(cleanup_name);
            updated.cleanup_index = try self.ownership.appendCleanup(self.mb.allocator, .{
                .name = cleanup_name,
                .ptr_value = local.ptr_value,
                .ty = local.ty,
                .active = false,
                .heap_ptr = heap_ptr,
            });
            try self.recordOwnershipTrace("heap owner {s}", .{name});
            try self.locals.put(self.mb.allocator, name, updated);
        }
        return updated;
    }

    pub fn restoreLocalsFrom(self: *FunctionLowerer, start: usize) void {
        var i = self.scope_restores.items.len;
        while (i > start) {
            i -= 1;
            const restore = self.scope_restores.items[i];
            if (restore.previous) |previous| {
                self.locals.put(self.mb.allocator, restore.name, previous) catch unreachable;
            } else {
                _ = self.locals.remove(restore.name);
            }
        }
    }

    pub fn freeCleanupEntriesFrom(self: *FunctionLowerer, start: usize) void {
        self.ownership.freeCleanupEntriesFrom(self.mb.allocator, start);
    }
};

const LocalState = struct {
    local_id: lir.LocalId,
    ptr_value: lir.ValueId,
    ty: lir.TypeId,
    cleanup_index: ?usize = null,
    read_through_alias: bool = false,
};

const LoopContext = struct {
    break_block: lir.BlockId,
    catch_depth: usize,
    continue_block: lir.BlockId,
    defer_start: usize,
    cleanup_start: usize,
};

const SwitchContext = struct {
    continue_block: lir.BlockId,
    reached_continuation: *bool,
    result_ptr: ?lir.ValueId,
    result_ty: ?lir.TypeId,
    defer_start: usize,
    cleanup_start: usize,
    catch_depth: usize,
};

const CatchScope = struct {
    carrier: lir.ValueId,
    binding_id: ?identity.BindingId,
    failure_binding_id: ?identity.BindingId,
};

const ScopeRestore = struct {
    name: []const u8,
    previous: ?LocalState,
};

test "Arc runtime behavior follows typed identity rather than display name" {
    const arc_identity: lir.StructType = .{
        .name = "renamed-shared-value",
        .is_c_layout = false,
        .is_packed = false,
        .is_shared_value = true,
        .shared_runtime = .arc,
        .packed_bits = 0,
        .fields = &.{},
    };
    const arc_looking_name: lir.StructType = .{
        .name = "Arc<LooksLikeArc>",
        .is_c_layout = false,
        .is_packed = false,
        .is_shared_value = true,
        .packed_bits = 0,
        .fields = &.{},
    };

    try std.testing.expect(isArcSharedValueStruct(arc_identity));
    try std.testing.expect(!isArcSharedValueStruct(arc_looking_name));
}

test "capture and container-copy decisions follow cleanup responsibility" {
    const aliased: sir.ValueSemantics = .{
        .category = .place,
        .ownership = .shared,
        .cleanup = .none,
    };
    const temporary: sir.ValueSemantics = .{
        .category = .value,
        .ownership = .owned,
        .cleanup = .full_expression,
    };
    const scoped: sir.ValueSemantics = .{
        .category = .value,
        .ownership = .shared,
        .cleanup = .scope,
    };
    const transferred: sir.ValueSemantics = .{
        .category = .value,
        .ownership = .owned,
        .cleanup = .transferred,
    };

    try std.testing.expect(!FunctionLowerer.valueSemanticsNeedsDropAfterContainerCopy(aliased));
    try std.testing.expect(FunctionLowerer.valueSemanticsNeedsDropAfterContainerCopy(temporary));
    try std.testing.expect(!FunctionLowerer.valueSemanticsNeedsDropAfterContainerCopy(scoped));
    try std.testing.expect(!FunctionLowerer.valueSemanticsNeedsDropAfterContainerCopy(transferred));
}

test "match and string cleanup decisions follow value semantics" {
    const borrowed: sir.ValueSemantics = .{
        .category = .borrowed_projection,
        .ownership = .borrowed,
        .cleanup = .none,
    };
    const temporary: sir.ValueSemantics = .{
        .category = .value,
        .ownership = .shared,
        .cleanup = .full_expression,
    };
    const transferred: sir.ValueSemantics = .{
        .category = .value,
        .ownership = .owned,
        .cleanup = .transferred,
    };

    try std.testing.expect(!FunctionLowerer.valueSemanticsNeedsMatchSourceDrop(borrowed));
    try std.testing.expect(!FunctionLowerer.valueSemanticsNeedsStringCleanup(borrowed));
    try std.testing.expect(FunctionLowerer.valueSemanticsNeedsStringReceiverOwner(borrowed));
    try std.testing.expect(FunctionLowerer.valueSemanticsNeedsMatchSourceDrop(temporary));
    try std.testing.expect(FunctionLowerer.valueSemanticsNeedsStringCleanup(temporary));
    try std.testing.expect(FunctionLowerer.valueSemanticsNeedsStringReceiverOwner(temporary));
    try std.testing.expect(!FunctionLowerer.valueSemanticsNeedsMatchSourceDrop(transferred));
    try std.testing.expect(!FunctionLowerer.valueSemanticsNeedsStringCleanup(transferred));
    try std.testing.expect(FunctionLowerer.valueSemanticsNeedsStringReceiverOwner(transferred));
}

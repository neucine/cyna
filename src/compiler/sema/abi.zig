const std = @import("std");
const ast = @import("../parser/ast.zig");
const language_contracts = @import("../language_contracts.zig");
const generated_names = @import("../generated_names.zig");
const intrinsics = @import("../intrinsics.zig");
const lexer = @import("../lexer/lexer.zig");
const semantic_types = @import("types.zig");
const sir = @import("sir.zig");
const type_resolution = @import("type_resolution.zig");
const declarations = @import("declarations.zig");

pub fn Owner(comptime host: anytype) type {
    return struct {
        const SemaContext = host.SemaContext;
        const SemaError = host.SemaError;
        const lookup = declarations.Lookup(SemaContext);
        const TypedExpr = host.TypedExpr;
        const canonical = type_resolution.Canonical(SemaContext);
        const canonicalInferredIntegerTypeId = canonical.inferredIntegerType;
        const canonicalIntegerTypeId = canonical.integerType;
        const canonicalTypeKind = canonical.sirType;
        const canonicalTypeNode = canonical.typeNode;
        const findEnum = lookup.findEnum;
        const findStruct = lookup.findStruct;
        const findTypeAlias = lookup.findTypeAlias;
        const findUnion = lookup.findUnion;
        const isFixedWidthIntegerName = type_resolution.isFixedWidthIntegerName;
        const makeTypedExprFromId = host.makeTypedExprFromId;
        const namedIntBitWidth = canonical.intBitWidth;
        const allCanonicalAggregateFieldTypesSatisfy = host.allCanonicalAggregateFieldTypesSatisfy;
        const canonicalStructLookup = lookup.canonicalStructLookup;
        const lookupEnumDeclById = lookup.lookupEnumDeclById;
        const lookupUnionDeclById = lookup.lookupUnionDeclById;
        const sameTypeName = declarations.sameTypeName;
        const canonicalNominalDeclName = lookup.canonicalNominalDeclName;

        /// Validate the C ABI boundary a program publishes: every extern or export
        /// callable and global must have a legal convention, a non-empty symbol name,
        /// a unique symbol, and types the C ABI can carry.
        pub fn checkCallableBoundaryDecls(context: *SemaContext, path: []const u8, program: ast.Program) SemaError!void {
            const allocator = context.allocator;
            for (program.functions, 0..) |function, i| {
                if (function.return_type) |return_type| {
                    if (isPlainCStrTypeName(return_type)) {
                        try context.diagnostic_context.emitToken(path, return_type.token, "`c_str` cannot be returned because its borrow lifetime is not expressed; return `?*const c_char` or another explicit raw pointer", .{});
                        return SemaError.SemanticFailed;
                    }
                }
                if (!function.is_extern and !function.is_export and function.calling_convention == .cyna) continue;

                if (function.owner != null) {
                    try context.diagnostic_context.emitToken(path, function.name_token, "C ABI declarations must be top-level functions", .{});
                    return SemaError.SemanticFailed;
                }
                if (function.calling_convention != .c) {
                    try context.diagnostic_context.emitToken(path, function.name_token, "extern and export functions require the `c` calling convention", .{});
                    return SemaError.SemanticFailed;
                }
                if (function.type_params.len != 0) {
                    try context.diagnostic_context.emitToken(path, function.name_token, "C ABI declarations cannot be generic", .{});
                    return SemaError.SemanticFailed;
                }
                if (function.abi_name) |abi_name| {
                    if (abi_name.len == 0) {
                        try context.diagnostic_context.emitToken(path, function.name_token, "C ABI symbol names cannot be empty", .{});
                        return SemaError.SemanticFailed;
                    }
                }
                const symbol_name = try cAbiSymbolName(allocator, function.module_name, function.name, function.abi_name);
                defer allocator.free(symbol_name);
                for (program.functions[0..i]) |existing| {
                    if (!existing.is_extern and !existing.is_export and existing.calling_convention == .cyna) continue;
                    const existing_symbol_name = try cAbiSymbolName(allocator, existing.module_name, existing.name, existing.abi_name);
                    defer allocator.free(existing_symbol_name);
                    if (std.mem.eql(u8, symbol_name, existing_symbol_name)) {
                        if (isExternExportCAbiPair(existing, function)) {
                            if (!sameCAbiFunctionSignature(existing, function)) {
                                try context.diagnostic_context.emitToken(path, function.name_token, "C ABI symbol `{s}` has incompatible extern/export declarations", .{symbol_name});
                                return SemaError.SemanticFailed;
                            }
                            continue;
                        }
                        try context.diagnostic_context.emitToken(path, function.name_token, "duplicate C ABI symbol `{s}`", .{symbol_name});
                        return SemaError.SemanticFailed;
                    }
                }
                if (intrinsics.moduleHasCapability(function.module_name, .trusted_internal_abi)) continue;
                for (function.params) |param| {
                    try expectCallableBoundaryTypeName(context, path, program, function.module_name, param.type_name, false, false);
                }
                if (function.return_type) |return_type| {
                    try expectCallableBoundaryTypeName(context, path, program, function.module_name, return_type, true, false);
                }
            }

            for (program.globals, 0..) |global, i| {
                if (!global.is_extern) continue;
                if (global.calling_convention != .c) {
                    try context.diagnostic_context.emitToken(path, global.name_token, "extern globals require the `c` calling convention", .{});
                    return SemaError.SemanticFailed;
                }
                const type_name = global.type_name orelse {
                    try context.diagnostic_context.emitToken(path, global.name_token, "extern globals require an explicit type", .{});
                    return SemaError.SemanticFailed;
                };
                if (global.abi_name) |abi_name| {
                    if (abi_name.len == 0) {
                        try context.diagnostic_context.emitToken(path, global.name_token, "C ABI symbol names cannot be empty", .{});
                        return SemaError.SemanticFailed;
                    }
                }
                const symbol_name = try cAbiSymbolName(allocator, global.module_name, global.name, global.abi_name);
                defer allocator.free(symbol_name);
                for (program.globals[0..i]) |existing| {
                    if (!existing.is_extern) continue;
                    const existing_symbol_name = try cAbiSymbolName(allocator, existing.module_name, existing.name, existing.abi_name);
                    defer allocator.free(existing_symbol_name);
                    if (std.mem.eql(u8, symbol_name, existing_symbol_name)) {
                        try context.diagnostic_context.emitToken(path, global.name_token, "duplicate C ABI symbol `{s}`", .{symbol_name});
                        return SemaError.SemanticFailed;
                    }
                }
                if (!type_name.is_raw and !type_name.is_volatile_raw) {
                    try expectCLayoutAbiTypeName(context, path, program, global.module_name, type_name, false, false);
                }
            }
        }

        pub fn isExternExportCAbiPair(left: ast.Function, right: ast.Function) bool {
            return (left.is_extern and right.is_export) or (left.is_export and right.is_extern);
        }

        pub fn sameCAbiFunctionSignature(left: ast.Function, right: ast.Function) bool {
            if (left.params.len != right.params.len) return false;
            for (left.params, right.params) |left_param, right_param| {
                if (!sameTypeName(left_param.type_name, right_param.type_name)) return false;
            }
            return sameOptionalReturnTypeName(left.return_type, right.return_type);
        }

        fn sameOptionalReturnTypeName(left: ?ast.TypeName, right: ?ast.TypeName) bool {
            if (left) |left_type| {
                if (right) |right_type| return sameTypeName(left_type, right_type);
                return isVoidTypeName(left_type);
            }
            if (right) |right_type| return isVoidTypeName(right_type);
            return true;
        }

        fn isVoidTypeName(type_name: ast.TypeName) bool {
            return !type_name.is_ref and
                !type_name.is_owned and
                !type_name.is_raw and
                !type_name.is_volatile_raw and
                !type_name.is_optional and
                !type_name.is_function and
                !type_name.is_slice and
                type_name.array_len == null and
                type_name.args.len == 0 and
                std.mem.eql(u8, type_name.name, "void");
        }

        pub fn cAbiSymbolName(allocator: std.mem.Allocator, module_name: []const u8, name: []const u8, abi_name: ?[]const u8) SemaError![]const u8 {
            if (abi_name) |symbol| return allocator.dupe(u8, symbol);
            return defaultCAbiSymbolName(allocator, module_name, name);
        }

        pub fn loweredCAbiSymbolName(context: *SemaContext, allocator: std.mem.Allocator, module_name: []const u8, name: []const u8, abi_name: ?[]const u8) SemaError!?[]const u8 {
            if (abi_name) |symbol| return symbol;
            const symbol = try defaultCAbiSymbolName(allocator, module_name, name);
            errdefer allocator.free(symbol);
            try context.output.generated_strings.append(allocator, symbol);
            return symbol;
        }

        fn defaultCAbiSymbolName(allocator: std.mem.Allocator, module_name: []const u8, name: []const u8) SemaError![]const u8 {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, generated_names.c_abi_symbol_prefix);
            try appendCAbiSymbolPart(allocator, &out, module_name);
            try out.append(allocator, '_');
            try appendCAbiSymbolPart(allocator, &out, name);
            return out.toOwnedSlice(allocator);
        }

        fn appendCAbiSymbolPart(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) SemaError!void {
            if (value.len == 0) {
                try out.append(allocator, '_');
                return;
            }
            var previous_was_separator = false;
            for (value) |ch| {
                const next = if (std.ascii.isAlphanumeric(ch)) ch else '_';
                if (next == '_') {
                    if (previous_was_separator) continue;
                    previous_was_separator = true;
                } else {
                    previous_was_separator = false;
                }
                try out.append(allocator, next);
            }
            if (previous_was_separator) _ = out.pop();
        }

        pub fn emitCStructFieldTypeError(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            field_name: []const u8,
            token: lexer.Token,
            field_ty: semantic_types.TypeId,
        ) SemaError!void {
            _ = current_module;
            switch (canonicalTypeKind(context, field_ty)) {
                .string => {
                    try context.diagnostic_context.emitToken(path, token, "`c struct` field `{s}` cannot use `string`; adapt it to an explicit C representation", .{field_name});
                    return;
                },
                .slice => {
                    try context.diagnostic_context.emitToken(path, token, "`c struct` field `{s}` cannot use slice type `{s}`; use an explicit pointer-plus-length `c struct` instead", .{ field_name, "slice" });
                    return;
                },
                .dense_array, .sparse_array => {
                    try context.diagnostic_context.emitToken(path, token, "`c struct` field `{s}` cannot use Cyna storage type `{s}`; use an explicit C-layout wrapper instead", .{ field_name, if (canonicalTypeKind(context, field_ty) == .dense_array) "[:]" else "[;]" });
                    return;
                },
                .result => {
                    try context.diagnostic_context.emitToken(path, token, "`c struct` field `{s}` cannot use `result`; use an explicit tag-plus-payload `c struct` representation instead", .{field_name});
                    return;
                },
                .optional => {
                    try context.diagnostic_context.emitToken(path, token, "`c struct` field `{s}` cannot use optional type `{s}`; use an explicit tag-plus-payload C-layout representation instead", .{ field_name, "optional" });
                    return;
                },
                .@"struct" => {
                    const name = canonicalNominalDeclName(context, program, field_ty) orelse return;
                    if (std.mem.eql(u8, name, "List") or std.mem.eql(u8, name, "Map") or std.mem.eql(u8, name, "Set")) {
                        try context.diagnostic_context.emitToken(path, token, "`c struct` field `{s}` cannot use container type `{s}`; convert it to an explicit C-layout representation", .{ field_name, name });
                        return;
                    }
                    if (canonicalStructLookup(context, program, field_ty)) |decl| {
                        if (decl.layout != .c) {
                            try context.diagnostic_context.emitToken(path, token, "`c struct` field `{s}` cannot use ordinary struct type `{s}`; use a nested `c struct` instead", .{ field_name, name });
                            return;
                        }
                    }
                },
                .@"union" => {
                    const name = canonicalNominalDeclName(context, program, field_ty) orelse return;
                    if (if (canonical.nominalDecl(context, field_ty)) |decl_id| lookupUnionDeclById(context, program, decl_id) else null) |decl| {
                        if (decl.layout != .c) {
                            try context.diagnostic_context.emitToken(path, token, "`c struct` field `{s}` cannot use ordinary union type `{s}`; use `c union` or another explicit C-layout representation", .{ field_name, name });
                            return;
                        }
                    }
                },
                .@"enum" => {
                    const name = canonicalNominalDeclName(context, program, field_ty) orelse return;
                    if (if (canonical.nominalDecl(context, field_ty)) |decl_id| lookupEnumDeclById(context, program, decl_id) else null) |decl| {
                        if (decl.layout != .c) {
                            try context.diagnostic_context.emitToken(path, token, "`c struct` field `{s}` cannot use language enum `{s}`; use `c enum` or an explicit integer representation", .{ field_name, name });
                            return;
                        }
                    }
                },
                else => {},
            }

            try context.diagnostic_context.emitToken(path, token, "`c struct` field `{s}` must use a C-layout ABI type such as a plain scalar, fixed array, raw pointer, nested `c struct`, or `c enum` value", .{field_name});
        }

        pub fn canonicalTypeIsCStructFieldType(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
        ) SemaError!bool {
            return switch (canonicalTypeNode(context, type_id).*) {
                .inferred_integer, .inferred_float, .integer, .float, .callable => true,
                .primitive => |primitive| primitive == .bool,
                .nominal => |nominal| switch (nominal.kind) {
                    .@"enum" => blk: {
                        const decl = lookupEnumDeclById(context, program, nominal.decl_id) orelse break :blk false;
                        break :blk decl.layout == .c or decl.layout == .flags;
                    },
                    .@"struct" => blk: {
                        const decl = canonicalStructLookup(context, program, type_id) orelse break :blk false;
                        if (decl.layout != .c) break :blk false;
                        break :blk try allCanonicalAggregateFieldTypesSatisfy(context, path, program, type_id, canonicalTypeIsCStructFieldType);
                    },
                    .type_alias => if (nominal.underlying) |underlying|
                        try canonicalTypeIsCStructFieldType(context, path, program, underlying)
                    else
                        false,
                    else => false,
                },
                .generic_instance => |instance| switch (instance.kind) {
                    .@"struct" => blk: {
                        const decl = canonicalStructLookup(context, program, type_id) orelse break :blk false;
                        if (decl.layout != .c) break :blk false;
                        break :blk try allCanonicalAggregateFieldTypesSatisfy(context, path, program, type_id, canonicalTypeIsCStructFieldType);
                    },
                    else => false,
                },
                .optional => |payload| switch (canonicalTypeNode(context, payload).*) {
                    .raw => try canonicalTypeIsCStructFieldType(context, path, program, payload),
                    else => false,
                },
                .array => |array| try canonicalTypeIsCStructFieldType(context, path, program, array.item),
                .raw => |raw| switch (canonicalTypeNode(context, raw.target).*) {
                    .primitive => |primitive| primitive == .c_void,
                    else => try canonicalTypeIsCStructFieldType(context, path, program, raw.target),
                },
                else => false,
            };
        }

        fn emitAbiBoundaryTypeDiagnostic(
            context: *SemaContext,
            path: []const u8,
            token: lexer.Token,
            comptime fmt: []const u8,
            args: anytype,
        ) SemaError!void {
            try context.diagnostic_context.emitTokenWith(path, token, .{
                .code = .abi_boundary,
                .notes = &.{"callable C boundaries require an explicitly supported representation"},
                .help = "use a C-layout ABI type or an explicit raw pointer-plus-length representation",
            }, fmt, args);
        }

        fn emitCallableBoundaryTypeError(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
        ) SemaError!void {
            if (type_name.is_slice) {
                try emitAbiBoundaryTypeDiagnostic(context, path, type_name.token, "slice type `{s}` is not allowed at a callable C boundary; use an explicit pointer-plus-length `c struct`", .{type_name.name});
                return;
            }
            if (std.mem.eql(u8, type_name.name, "string")) {
                try emitAbiBoundaryTypeDiagnostic(context, path, type_name.token, "`string` is a Cyna runtime type, not a C-layout ABI type", .{});
                return;
            }
            if (std.mem.eql(u8, type_name.name, "List") or std.mem.eql(u8, type_name.name, "Map") or std.mem.eql(u8, type_name.name, "Set")) {
                try emitAbiBoundaryTypeDiagnostic(context, path, type_name.token, "container type `{s}` is not allowed at a callable C boundary; convert it to an explicit boundary representation", .{type_name.name});
                return;
            }
            if (findStruct(context, program, current_module, type_name.name)) |decl| {
                if (decl.layout != .c) {
                    try emitAbiBoundaryTypeDiagnostic(context, path, type_name.token, "ordinary struct type `{s}` is not allowed at a callable C boundary; use `c struct` or an explicit raw pointer", .{type_name.name});
                    return;
                }
            }
            if (findUnion(context, program, current_module, type_name.name)) |decl| {
                if (decl.layout != .c) {
                    try emitAbiBoundaryTypeDiagnostic(context, path, type_name.token, "ordinary union type `{s}` is not allowed at a callable C boundary; use `c union`, a pointer, or another explicit boundary representation", .{type_name.name});
                    return;
                }
            }
            try emitAbiBoundaryTypeDiagnostic(context, path, type_name.token, "type `{s}` is not allowed at a callable C boundary; use an explicit C-layout ABI type", .{type_name.name});
        }

        fn emitCLayoutBoundaryTypeError(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
        ) SemaError!void {
            if (type_name.is_slice) {
                try emitAbiBoundaryTypeDiagnostic(context, path, type_name.token, "slice type `{s}` is not a C-layout ABI type; use a pointer-plus-length `c struct` wrapper", .{type_name.name});
                return;
            }
            if (std.mem.eql(u8, type_name.name, "string")) {
                try emitAbiBoundaryTypeDiagnostic(context, path, type_name.token, "`string` is a Cyna runtime type, not a C-layout ABI type", .{});
                return;
            }
            if (std.mem.eql(u8, type_name.name, "List") or std.mem.eql(u8, type_name.name, "Map") or std.mem.eql(u8, type_name.name, "Set")) {
                try emitAbiBoundaryTypeDiagnostic(context, path, type_name.token, "container type `{s}` is not a C-layout ABI type; use a `c struct` wrapper or pointer-based boundary shape", .{type_name.name});
                return;
            }
            if (findStruct(context, program, current_module, type_name.name)) |decl| {
                if (decl.layout != .c) {
                    try emitAbiBoundaryTypeDiagnostic(context, path, type_name.token, "ordinary struct type `{s}` is not a C-layout ABI type; only non-generic `c struct` types may appear here", .{type_name.name});
                    return;
                }
            }
            if (findUnion(context, program, current_module, type_name.name)) |decl| {
                if (decl.layout != .c) {
                    try emitAbiBoundaryTypeDiagnostic(context, path, type_name.token, "ordinary union type `{s}` is not a C-layout ABI type; use `c union` or another explicit boundary representation", .{type_name.name});
                    return;
                }
            }
            try emitAbiBoundaryTypeDiagnostic(context, path, type_name.token, "type `{s}` is not a supported boundary type here", .{type_name.name});
        }

        const PublishedCallableCarrierKind = enum {
            none,
            string,
            dense,
            sparse,
            result,
        };

        const CLayoutAbiLeafKind = enum {
            none,
            void,
            c_void,
            c_str,
            scalar,
            cstruct,
            cenum,
        };

        const CAbiLayout = struct {
            size: usize,
            alignment: usize,
        };

        pub fn lowerComptimeExpr(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            out: *sir.Expr,
            expr: ast.ComptimeExpr,
        ) SemaError!TypedExpr {
            const value = try resolveComptimeMetadata(context, path, program, current_module, expr.expr, expr.token);
            out.* = .{ .int = .{
                .value = value.int_value,
                .type_name = value.int_type_name,
            } };
            return makeTypedExprFromId(out, value.type_id);
        }

        const ComptimeValue = struct {
            int_value: i64,
            int_type_name: ?[]const u8,
            type_id: semantic_types.TypeId,
        };

        pub fn resolveComptimeMetadata(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            expr: *ast.Expr,
            token: lexer.Token,
        ) SemaError!ComptimeValue {
            if (expr.* == .int) {
                return .{
                    .int_value = expr.int.value,
                    .int_type_name = null,
                    .type_id = try canonicalInferredIntegerTypeId(context),
                };
            }
            if (try cAbiMetadataQueryFromExpr(path, expr)) |query| {
                const value = switch (query.kind) {
                    .size => (try cAbiLayoutForTypeName(context, path, program, current_module, query.type_name, 0)).size,
                    .alignment => (try cAbiLayoutForTypeName(context, path, program, current_module, query.type_name, 0)).alignment,
                    .field_offset => |field_name| try cAbiFieldOffset(context, path, program, current_module, query.type_name, field_name),
                };
                if (value > @as(usize, @intCast(std.math.maxInt(i64)))) {
                    try context.diagnostic_context.emitToken(path, token, "comptime value does not fit compiler integer literal range", .{});
                    return SemaError.SemanticFailed;
                }
                return .{
                    .int_value = @intCast(value),
                    .int_type_name = "usize",
                    .type_id = try canonicalIntegerTypeId(context, "usize"),
                };
            }
            try context.diagnostic_context.emitToken(path, token, "unsupported comptime expression; use an integer literal or C ABI metadata path such as `comptime T.size`", .{});
            return SemaError.SemanticFailed;
        }

        const CAbiMetadataQueryKind = union(enum) {
            size,
            alignment,
            field_offset: []const u8,
        };

        const CAbiMetadataQuery = struct {
            type_name: ast.TypeName,
            kind: CAbiMetadataQueryKind,
        };

        fn cAbiMetadataQueryFromExpr(path: []const u8, expr: *ast.Expr) SemaError!?CAbiMetadataQuery {
            switch (expr.*) {
                .field => |field| {
                    if (field.object.* == .name) {
                        if (std.mem.eql(u8, field.field, "size")) {
                            return .{ .type_name = simpleMetadataTypeName(field.object.name.text, field.object.name.token), .kind = .size };
                        }
                        if (std.mem.eql(u8, field.field, "align")) {
                            return .{ .type_name = simpleMetadataTypeName(field.object.name.text, field.object.name.token), .kind = .alignment };
                        }
                    }
                    if (!std.mem.eql(u8, field.field, "offset")) return null;
                    if (field.object.* != .field) return null;
                    const field_expr = field.object.field;
                    if (field_expr.object.* != .enum_case) return null;
                    const root = field_expr.object.enum_case;
                    if (!std.mem.eql(u8, root.case_name, "field")) return null;
                    return .{
                        .type_name = simpleMetadataTypeName(root.type_name, root.token),
                        .kind = .{ .field_offset = field_expr.field },
                    };
                },
                .enum_case => |case| {
                    if (std.mem.eql(u8, case.case_name, "size")) {
                        return .{ .type_name = simpleMetadataTypeName(case.type_name, case.token), .kind = .size };
                    }
                    if (std.mem.eql(u8, case.case_name, "align")) {
                        return .{ .type_name = simpleMetadataTypeName(case.type_name, case.token), .kind = .alignment };
                    }
                    return null;
                },
                else => {
                    _ = path;
                    return null;
                },
            }
        }

        fn simpleMetadataTypeName(name: []const u8, token: lexer.Token) ast.TypeName {
            return .{
                .array_len = null,
                .name = name,
                .args = &.{},
                .token = token,
            };
        }

        fn cAbiFieldOffset(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
            field_name: []const u8,
        ) SemaError!usize {
            const decl = try resolveComptimeCStruct(context, path, program, current_module, type_name);
            var offset: usize = 0;
            for (decl.fields) |field| {
                const field_layout = try cAbiLayoutForTypeName(context, path, program, decl.module_name, field.type_name, 0);
                offset = alignUpLayout(offset, field_layout.alignment);
                if (std.mem.eql(u8, field.name, field_name)) return offset;
                offset += field_layout.size;
            }
            try context.diagnostic_context.emitToken(path, type_name.token, "`c struct` `{s}` has no field `{s}`", .{ decl.name, field_name });
            return SemaError.SemanticFailed;
        }

        fn resolveComptimeCStruct(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
        ) SemaError!ast.StructDecl {
            if (type_name.is_ref or type_name.is_owned or type_name.is_raw or type_name.is_optional or type_name.is_slice or type_name.array_len != null or type_name.is_function or type_name.args.len != 0) {
                try context.diagnostic_context.emitToken(path, type_name.token, "`comptime T.field.<name>.offset` requires a direct non-generic `c struct` type", .{});
                return SemaError.SemanticFailed;
            }
            if (findStruct(context, program, current_module, type_name.name)) |decl| {
                if (decl.layout == .c and decl.type_params.len == 0) return decl;
            }
            if (findTypeAlias(context, program, current_module, type_name.name)) |alias| {
                return resolveComptimeCStruct(context, path, program, alias.module_name, alias.target);
            }
            try emitCLayoutBoundaryTypeError(context, path, program, current_module, type_name);
            return SemaError.SemanticFailed;
        }

        fn cAbiLayoutForTypeName(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
            depth: usize,
        ) SemaError!CAbiLayout {
            if (depth > 64) {
                try context.diagnostic_context.emitToken(path, type_name.token, "C-layout metadata recursion is too deep", .{});
                return SemaError.SemanticFailed;
            }

            // This evaluator is intentionally C-layout-only. It exists for FFI and
            // kernel code that must compare C ABI offsets; it must not become the
            // definition of ordinary Cyna struct layout.
            if (type_name.is_function) {
                if (type_name.function_calling_convention != .c or type_name.is_ref or type_name.is_owned or type_name.is_raw or type_name.is_optional or type_name.is_slice or type_name.array_len != null) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "C ABI metadata supports only plain `c fn(...)` function pointer layout", .{});
                    return SemaError.SemanticFailed;
                }
                for (type_name.function_params) |param| {
                    _ = try cAbiLayoutForTypeName(context, path, program, current_module, param, depth + 1);
                }
                if (type_name.function_return_type) |return_type| {
                    _ = try cAbiLayoutForTypeName(context, path, program, current_module, return_type.*, depth + 1);
                }
                return pointerLayout(
                    context,
                );
            }

            if (type_name.is_ref or type_name.is_owned or type_name.is_slice) {
                try emitCLayoutBoundaryTypeError(context, path, program, current_module, type_name);
                return SemaError.SemanticFailed;
            }
            if (type_name.is_optional and !type_name.is_raw) {
                try context.diagnostic_context.emitToken(path, type_name.token, "C ABI metadata supports optional only for nullable raw pointers", .{});
                return SemaError.SemanticFailed;
            }
            if (type_name.array_len) |len| {
                var item_name = type_name;
                item_name.array_len = null;
                const item = try cAbiLayoutForTypeName(context, path, program, current_module, item_name, depth + 1);
                return .{ .size = item.size * len, .alignment = item.alignment };
            }
            if (type_name.is_raw) {
                const pointee = rawPointeeTypeName(type_name);
                _ = try cAbiLayoutForTypeName(context, path, program, current_module, pointee, depth + 1);
                return pointerLayout(
                    context,
                );
            }
            if (type_name.args.len != 0) {
                try emitCLayoutBoundaryTypeError(context, path, program, current_module, type_name);
                return SemaError.SemanticFailed;
            }

            if (std.mem.eql(u8, type_name.name, "void") or std.mem.eql(u8, type_name.name, "c_void")) return .{ .size = 0, .alignment = 1 };
            if (std.mem.eql(u8, type_name.name, "c_str")) return pointerLayout(
                context,
            );
            if (cAbiScalarLayout(context, type_name.name)) |layout| return layout;
            if (std.mem.eql(u8, type_name.name, "bool")) return .{ .size = 1, .alignment = 1 };
            if (std.mem.eql(u8, type_name.name, "f32")) return .{ .size = 4, .alignment = 4 };
            if (std.mem.eql(u8, type_name.name, "f64")) return .{ .size = 8, .alignment = 8 };
            if (isFixedWidthIntegerName(type_name.name)) {
                const bits = namedIntBitWidth(context, type_name.name).?;
                const size = @as(usize, bits + 7) / 8;
                return .{ .size = size, .alignment = @min(size, @as(usize, 8)) };
            }
            if (findStruct(context, program, current_module, type_name.name)) |decl| {
                if (decl.layout == .c and decl.type_params.len == 0) return cStructLayout(context, path, program, decl, depth + 1);
                try emitCLayoutBoundaryTypeError(context, path, program, current_module, type_name);
                return SemaError.SemanticFailed;
            }
            if (findEnum(context, program, current_module, type_name.name)) |decl| {
                if (decl.layout == .c) return cAbiScalarLayout(context, decl.repr_name orelse "c_int").?;
            }
            if (findTypeAlias(context, program, current_module, type_name.name)) |alias| {
                return cAbiLayoutForTypeName(context, path, program, alias.module_name, alias.target, depth + 1);
            }

            try emitCLayoutBoundaryTypeError(context, path, program, current_module, type_name);
            return SemaError.SemanticFailed;
        }

        fn cStructLayout(context: *SemaContext, path: []const u8, program: ast.Program, decl: ast.StructDecl, depth: usize) SemaError!CAbiLayout {
            var size: usize = 0;
            var max_align: usize = 1;
            for (decl.fields) |field| {
                const field_layout = try cAbiLayoutForTypeName(context, path, program, decl.module_name, field.type_name, depth + 1);
                size = alignUpLayout(size, field_layout.alignment);
                size += field_layout.size;
                max_align = @max(max_align, field_layout.alignment);
            }
            return .{ .size = alignUpLayout(size, max_align), .alignment = max_align };
        }

        fn cAbiScalarLayout(context: *SemaContext, name: []const u8) ?CAbiLayout {
            if (std.mem.eql(u8, name, "c_char")) return .{ .size = 1, .alignment = 1 };
            if (std.mem.eql(u8, name, "c_schar")) return .{ .size = 1, .alignment = 1 };
            if (std.mem.eql(u8, name, "c_uchar")) return .{ .size = 1, .alignment = 1 };
            if (std.mem.eql(u8, name, "c_short")) return .{ .size = @as(usize, context.abi_layout.short_bits) / 8, .alignment = @as(usize, context.abi_layout.short_bits) / 8 };
            if (std.mem.eql(u8, name, "c_ushort")) return .{ .size = @as(usize, context.abi_layout.short_bits) / 8, .alignment = @as(usize, context.abi_layout.short_bits) / 8 };
            if (std.mem.eql(u8, name, "c_int")) return .{ .size = @as(usize, context.abi_layout.int_bits) / 8, .alignment = @as(usize, context.abi_layout.int_bits) / 8 };
            if (std.mem.eql(u8, name, "c_uint")) return .{ .size = @as(usize, context.abi_layout.int_bits) / 8, .alignment = @as(usize, context.abi_layout.int_bits) / 8 };
            if (std.mem.eql(u8, name, "c_long")) return .{ .size = @as(usize, context.abi_layout.long_bits) / 8, .alignment = context.abi_layout.long_align };
            if (std.mem.eql(u8, name, "c_ulong")) return .{ .size = @as(usize, context.abi_layout.long_bits) / 8, .alignment = context.abi_layout.long_align };
            if (std.mem.eql(u8, name, "c_llong")) return .{ .size = @as(usize, context.abi_layout.longlong_bits) / 8, .alignment = context.abi_layout.longlong_align };
            if (std.mem.eql(u8, name, "c_ullong")) return .{ .size = @as(usize, context.abi_layout.longlong_bits) / 8, .alignment = context.abi_layout.longlong_align };
            if (std.mem.eql(u8, name, "c_float")) return .{ .size = 4, .alignment = 4 };
            if (std.mem.eql(u8, name, "c_double")) return .{ .size = 8, .alignment = context.abi_layout.double_align };
            if (std.mem.eql(u8, name, "c_ptrdiff_t")) return pointerLayout(
                context,
            );
            if (std.mem.eql(u8, name, "c_size_t")) return pointerLayout(
                context,
            );
            return null;
        }

        fn pointerLayout(context: *SemaContext) CAbiLayout {
            const size = @as(usize, context.abi_layout.ptr_bits) / 8;
            return .{ .size = size, .alignment = size };
        }

        fn alignUpLayout(value: usize, alignment: usize) usize {
            if (alignment == 0) return value;
            return (value + alignment - 1) & ~(alignment - 1);
        }

        fn publishedCallableCarrierKind(type_name: ast.TypeName) PublishedCallableCarrierKind {
            if (std.mem.eql(u8, type_name.name, "string")) return .string;
            if (std.mem.eql(u8, type_name.name, "[:]")) return .dense;
            if (std.mem.eql(u8, type_name.name, "[;]")) return .sparse;
            if (std.mem.eql(u8, type_name.name, language_contracts.result_type_name)) return .result;
            return .none;
        }

        pub fn isPlainCStrTypeName(type_name: ast.TypeName) bool {
            return type_resolution.isPlainCStrTypeName(type_name);
        }

        pub fn rawPointeeTypeName(type_name: ast.TypeName) ast.TypeName {
            return type_resolution.rawPointeeTypeName(type_name);
        }

        fn isPublishedCarrierPayloadScalarTypeName(name: []const u8) bool {
            return std.mem.eql(u8, name, "bool") or
                isBuiltinIntegerTypeName(name) or
                isBuiltinFloatTypeName(name) or
                isCAbiScalarTypeName(name);
        }

        fn classifyCLayoutAbiLeafTypeName(
            context: *const SemaContext,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
        ) CLayoutAbiLeafKind {
            if (std.mem.eql(u8, type_name.name, "void")) return .void;
            if (std.mem.eql(u8, type_name.name, "c_void")) return .c_void;
            if (std.mem.eql(u8, type_name.name, "c_str")) return .c_str;
            if (isCAbiScalarTypeName(type_name.name)) return .scalar;
            if (findStruct(context, program, current_module, type_name.name)) |decl| {
                if (decl.type_params.len == 0 and decl.layout == .c) return .cstruct;
            }
            if (findEnum(context, program, current_module, type_name.name)) |decl| {
                if (decl.layout == .c) return .cenum;
            }
            return .none;
        }

        fn expectPublishedCarrierPayloadTypeName(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
        ) SemaError!void {
            if (type_name.is_ref or type_name.is_owned or type_name.is_slice or type_name.array_len != null or type_name.is_function) {
                try emitCallableBoundaryTypeError(context, path, program, current_module, type_name);
                return SemaError.SemanticFailed;
            }
            if (type_name.is_raw) {
                const pointee = rawPointeeTypeName(type_name);
                try expectCLayoutAbiTypeName(context, path, program, current_module, pointee, false, true);
                return;
            }
            if (type_name.is_optional) {
                var payload = type_name;
                payload.is_optional = false;
                try expectPublishedCarrierPayloadTypeName(context, path, program, current_module, payload);
                return;
            }
            if (type_name.args.len != 0) {
                try emitCallableBoundaryTypeError(context, path, program, current_module, type_name);
                return SemaError.SemanticFailed;
            }
            if (std.mem.eql(u8, type_name.name, "string") or isPublishedCarrierPayloadScalarTypeName(type_name.name)) {
                return;
            }
            if (findEnum(context, program, current_module, type_name.name)) |decl| {
                if (decl.layout == .c) return;
            }
            try emitCallableBoundaryTypeError(context, path, program, current_module, type_name);
            return SemaError.SemanticFailed;
        }

        fn expectPublishedCallableCarrierTypeName(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
            allow_void: bool,
        ) SemaError!bool {
            switch (publishedCallableCarrierKind(type_name)) {
                .string => {
                    if (type_name.args.len != 0 or type_name.is_optional) {
                        try emitCallableBoundaryTypeError(context, path, program, current_module, type_name);
                        return SemaError.SemanticFailed;
                    }
                    return true;
                },
                .dense, .sparse => {
                    if (type_name.args.len != 1) {
                        try emitCallableBoundaryTypeError(context, path, program, current_module, type_name);
                        return SemaError.SemanticFailed;
                    }
                    try expectPublishedCarrierPayloadTypeName(context, path, program, current_module, type_name.args[0]);
                    return true;
                },
                .result => {
                    if (type_name.args.len != 2) {
                        try emitCallableBoundaryTypeError(context, path, program, current_module, type_name);
                        return SemaError.SemanticFailed;
                    }
                    try expectCallableBoundaryTypeName(context, path, program, current_module, type_name.args[0], true, false);
                    try expectCallableBoundaryTypeName(context, path, program, current_module, type_name.args[1], false, false);
                    return true;
                },
                .none => {},
            }
            if (type_name.is_optional and !type_name.is_raw) {
                var payload = type_name;
                payload.is_optional = false;
                if (!try expectPublishedCallableCarrierTypeName(context, path, program, current_module, payload, allow_void)) {
                    try emitCallableBoundaryTypeError(context, path, program, current_module, type_name);
                    return SemaError.SemanticFailed;
                }
                return true;
            }
            return false;
        }

        pub fn expectCallableBoundaryTypeName(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
            allow_void: bool,
            inside_pointer: bool,
        ) SemaError!void {
            if (isPlainCStrTypeName(type_name)) {
                if (allow_void) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "`c_str` cannot be returned because its borrow lifetime is not expressed; return `?*const c_char` or another explicit raw pointer", .{});
                    return SemaError.SemanticFailed;
                }
                return;
            }
            if (std.mem.eql(u8, type_name.name, "c_str")) {
                try context.diagnostic_context.emitToken(path, type_name.token, "`c_str` is an unwrapped borrowed parameter/local view; use `?*const c_char` for nullable C pointers and explicit raw-pointer types for stored forms", .{});
                return SemaError.SemanticFailed;
            }
            if (type_name.is_function) {
                if (type_name.function_calling_convention != .c) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "only `c fn(...)` types are allowed at a callable C boundary", .{});
                    return SemaError.SemanticFailed;
                }
                if (type_name.is_ref or type_name.is_owned or type_name.is_raw or type_name.is_slice or type_name.array_len != null or type_name.is_optional) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "callable-boundary function pointer types cannot combine pointer or optional modifiers", .{});
                    return SemaError.SemanticFailed;
                }
                for (type_name.function_params) |param| {
                    try expectCLayoutAbiTypeName(context, path, program, current_module, param, false, false);
                }
                if (type_name.function_return_type) |return_type| {
                    try expectCLayoutAbiTypeName(context, path, program, current_module, return_type.*, true, false);
                }
                return;
            }
            if (type_name.is_ref or type_name.is_owned or type_name.is_slice or type_name.array_len != null) {
                try emitCallableBoundaryTypeError(context, path, program, current_module, type_name);
                return SemaError.SemanticFailed;
            }
            if (type_name.is_raw) {
                const pointee = rawPointeeTypeName(type_name);
                try expectCLayoutAbiTypeName(context, path, program, current_module, pointee, false, true);
                return;
            }
            if (type_name.args.len != 0 or (type_name.is_optional and !type_name.is_raw) or publishedCallableCarrierKind(type_name) != .none) {
                try emitCallableBoundaryTypeError(context, path, program, current_module, type_name);
                return SemaError.SemanticFailed;
            }
            if (findStruct(context, program, current_module, type_name.name)) |decl| {
                if (decl.type_params.len == 0 and decl.layout != .c) {
                    try emitCallableBoundaryTypeError(context, path, program, current_module, type_name);
                    return SemaError.SemanticFailed;
                }
            }
            if (findUnion(context, program, current_module, type_name.name)) |decl| {
                if (decl.layout != .c) {
                    try emitCallableBoundaryTypeError(context, path, program, current_module, type_name);
                    return SemaError.SemanticFailed;
                }
            }
            return expectCLayoutAbiTypeName(context, path, program, current_module, type_name, allow_void, inside_pointer);
        }

        pub fn expectCLayoutAbiTypeName(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_name: ast.TypeName,
            allow_void: bool,
            inside_pointer: bool,
        ) SemaError!void {
            if (type_name.is_function) {
                if (type_name.function_calling_convention != .c) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "only `c fn(...)` types are allowed in C-layout ABI positions", .{});
                    return SemaError.SemanticFailed;
                }
                if (type_name.is_ref or type_name.is_owned or type_name.is_raw or type_name.is_slice or type_name.array_len != null or type_name.is_optional) {
                    try context.diagnostic_context.emitToken(path, type_name.token, "C-layout function pointer types cannot combine pointer or optional modifiers", .{});
                    return SemaError.SemanticFailed;
                }
                for (type_name.function_params) |param| {
                    try expectCLayoutAbiTypeName(context, path, program, current_module, param, false, false);
                }
                if (type_name.function_return_type) |return_type| {
                    try expectCLayoutAbiTypeName(context, path, program, current_module, return_type.*, true, false);
                }
                return;
            }
            if (type_name.is_ref or type_name.is_owned or type_name.is_slice or type_name.array_len != null) {
                try emitCLayoutBoundaryTypeError(context, path, program, current_module, type_name);
                return SemaError.SemanticFailed;
            }
            if (type_name.is_optional and !type_name.is_raw) {
                var payload = type_name;
                payload.is_optional = false;
                try expectCLayoutAbiTypeName(context, path, program, current_module, payload, false, false);
                return;
            }
            if (type_name.is_raw) {
                const pointee = rawPointeeTypeName(type_name);
                try expectCLayoutAbiTypeName(context, path, program, current_module, pointee, false, true);
                return;
            }
            if (type_name.args.len != 0) {
                try emitCLayoutBoundaryTypeError(context, path, program, current_module, type_name);
                return SemaError.SemanticFailed;
            }
            switch (classifyCLayoutAbiLeafTypeName(context, program, current_module, type_name)) {
                .void => {
                    if (allow_void) return;
                },
                .c_void => {
                    if (inside_pointer or allow_void) return;
                    try context.diagnostic_context.emitToken(path, type_name.token, "`c_void` is only allowed as a raw pointer target or explicit C-layout ABI return marker", .{});
                    return SemaError.SemanticFailed;
                },
                .c_str, .scalar, .cstruct, .cenum => return,
                .none => {},
            }
            if (findTypeAlias(context, program, current_module, type_name.name)) |alias| {
                return expectCLayoutAbiTypeName(context, path, program, current_module, alias.target, allow_void, inside_pointer);
            }

            try emitCLayoutBoundaryTypeError(context, path, program, current_module, type_name);
            return SemaError.SemanticFailed;
        }

        pub fn isCAbiScalarTypeName(name: []const u8) bool {
            return std.mem.eql(u8, name, "c_char") or
                std.mem.eql(u8, name, "c_schar") or
                std.mem.eql(u8, name, "c_uchar") or
                std.mem.eql(u8, name, "c_short") or
                std.mem.eql(u8, name, "c_ushort") or
                std.mem.eql(u8, name, "c_int") or
                std.mem.eql(u8, name, "c_uint") or
                std.mem.eql(u8, name, "c_long") or
                std.mem.eql(u8, name, "c_ulong") or
                std.mem.eql(u8, name, "c_llong") or
                std.mem.eql(u8, name, "c_ullong") or
                std.mem.eql(u8, name, "c_float") or
                std.mem.eql(u8, name, "c_double") or
                std.mem.eql(u8, name, "c_ptrdiff_t") or
                std.mem.eql(u8, name, "c_size_t");
        }

        pub fn isBuiltinIntegerTypeName(name: []const u8) bool {
            return isFixedWidthIntegerName(name) or
                isCAbiScalarTypeName(name) or
                std.mem.eql(u8, name, "isize") or
                std.mem.eql(u8, name, "usize");
        }

        pub fn isBuiltinFloatTypeName(name: []const u8) bool {
            return std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64");
        }
    };
}
